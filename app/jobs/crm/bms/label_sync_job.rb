class Crm::Bms::LabelSyncJob < ApplicationJob
  queue_as :integrations

  def perform(label_id, action = 'sync')
    @label = Label.find_by(id: label_id)
    return unless @label

    @hook = find_bms_hook
    return unless @hook&.feature_allowed?
    return unless @hook.settings['enable_label_sync']

    case action
    when 'sync', 'create', 'update'
      sync_label
    when 'delete'
      delete_label
    else
      Rails.logger.warn("BMS Label Sync Job: Unknown action '#{action}'")
    end
  rescue StandardError => e
    Rails.logger.error("BMS Label Sync Job failed: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
    raise e
  end

  private

  def sync_label
    processor = Crm::Bms::ProcessorService.new(@hook)
    processor.handle_label_updated(label: @label)
  end

  def delete_label
    # Delete the tag in BMS if it exists
    stored_tag_id = get_label_external_id
    return unless stored_tag_id

    tag_client = Crm::Bms::Api::TagClient.new(@hook.settings['api_key'])
    tag_client.delete_tag(stored_tag_id)

    Rails.logger.info("BMS: Deleted tag #{stored_tag_id} for label #{@label.id}")
  rescue Crm::Bms::Api::BaseClient::ApiError => e
    Rails.logger.error("BMS: Failed to delete tag: #{e.message}")
  end

  def get_label_external_id
    TenantCache.read("bms_label_mapping_#{@label.id}")
  end

  def find_bms_hook
    Integrations::Hook.where(app_id: 'bms').first
  end
end
