class Crm::Bms::CustomAttributeSyncJob < ApplicationJob
  queue_as :integrations

  def perform(custom_attribute_definition_id, action = 'sync')
    @custom_attribute_definition = CustomAttributeDefinition.find_by(id: custom_attribute_definition_id)
    return unless @custom_attribute_definition

    @hook = find_bms_hook
    return unless @hook&.feature_allowed?
    return unless @hook.settings['enable_custom_attributes_sync']

    case action
    when 'sync', 'create', 'update'
      sync_custom_attribute
    when 'delete'
      delete_custom_attribute
    else
      Rails.logger.warn("BMS Custom Attribute Sync Job: Unknown action '#{action}'")
    end
  rescue StandardError => e
    Rails.logger.error("BMS Custom Attribute Sync Job failed: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
    raise e
  end

  private

  def sync_custom_attribute
    processor = Crm::Bms::ProcessorService.new(@hook)
    processor.handle_custom_attribute_definition_updated(custom_attribute_definition: @custom_attribute_definition)
  end

  def delete_custom_attribute
    # Delete the custom field in BMS if it exists
    stored_field_id = get_custom_attribute_external_id
    return unless stored_field_id

    custom_field_client = Crm::Bms::Api::CustomFieldClient.new(@hook.settings['api_key'])
    custom_field_client.delete_custom_field(stored_field_id)

    Rails.logger.info("BMS: Deleted custom field #{stored_field_id} for custom attribute #{@custom_attribute_definition.id}")
  rescue Crm::Bms::Api::BaseClient::ApiError => e
    Rails.logger.error("BMS: Failed to delete custom field: #{e.message}")
  end

  def get_custom_attribute_external_id
    TenantCache.read("bms_custom_field_mapping_#{@custom_attribute_definition.id}")
  end

  def find_bms_hook
    Integrations::Hook.where(app_id: 'bms').first
  end
end
