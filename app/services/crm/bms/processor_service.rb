class Crm::Bms::ProcessorService < Crm::BaseProcessorService
  def self.crm_name
    'bms'
  end

  def initialize(hook)
    super(hook)
    @api_key = hook.settings['api_key']

    # Sync settings
    @enable_contact_sync = hook.settings['enable_contact_sync']
    @enable_label_sync = hook.settings['enable_label_sync']
    @enable_custom_attributes_sync = hook.settings['enable_custom_attributes_sync']
    @enable_campaign_sync = hook.settings['enable_campaign_sync']

    # Initialize API clients
    @contact_client = Crm::Bms::Api::ContactClient.new(@api_key)
    @tag_client = Crm::Bms::Api::TagClient.new(@api_key)
    @custom_field_client = Crm::Bms::Api::CustomFieldClient.new(@api_key)
    @contact_finder = Crm::Bms::ContactFinderService.new(@contact_client)
  end

  def handle_contact_created(event_data)
    Rails.logger.info "BMS: Processing contact.created event for contact ID #{event_data[:contact]&.id}"
    handle_contact(event_data[:contact])
  end

  def handle_contact_updated(event_data)
    contact = event_data[:contact]
    handle_contact(contact)

    # Handle label changes if label sync is enabled
    Rails.logger.info("BMS: enable_label_sync=#{@enable_label_sync}, saved_changes_include_labels=#{saved_changes_include_labels?(event_data)}")
    Rails.logger.info("BMS: event_data keys: #{event_data.keys.inspect}")

    if @enable_label_sync && saved_changes_include_labels?(event_data)
      Rails.logger.info('BMS: Starting label sync with changes')

      # Initialize cache if not exists with current labels BEFORE sync
      cache_key = "bms_contact_labels_#{contact.id}"
      unless TenantCache.exist?(cache_key)
        Rails.logger.info("BMS: Initializing cache for contact #{contact.id}")
        TenantCache.write(cache_key, contact.labels.pluck(:name), expires_in: 1.hour)
      end

      sync_contact_labels_with_changes(contact, event_data)
    else
      Rails.logger.info("BMS: Skipping label sync - enable_label_sync=#{@enable_label_sync}")
    end

    # Handle custom attributes changes if custom attributes sync is enabled
    return unless @enable_custom_attributes_sync && saved_changes_include_custom_attributes?(event_data)

    sync_contact_custom_attributes(contact)
  end

  def handle_conversation_created(_event_data)
    # For now, we focus on contact sync
    # Conversation activities can be implemented in future phases
    Rails.logger.info('BMS: Conversation activities not implemented yet')
  end

  def handle_conversation_resolved(_event_data)
    # For now, we focus on contact sync
    # Conversation activities can be implemented in future phases
    Rails.logger.info('BMS: Conversation activities not implemented yet')
  end

  # Label-specific event handlers
  def handle_label_created(event_data)
    Rails.logger.info "BMS: Processing label.created event for label ID #{event_data[:label]&.id}"
    return unless @enable_label_sync

    label = event_data[:label]
    sync_label_to_bms(label)
  end

  def handle_label_updated(event_data)
    return unless @enable_label_sync

    label = event_data[:label]
    sync_label_to_bms(label)
  end

  # Custom attribute definition event handlers
  def handle_custom_attribute_definition_created(event_data)
    return unless @enable_custom_attributes_sync

    custom_attribute = event_data[:custom_attribute_definition]
    sync_custom_field_to_bms(custom_attribute)
  end

  def handle_custom_attribute_definition_updated(event_data)
    return unless @enable_custom_attributes_sync

    custom_attribute = event_data[:custom_attribute_definition]
    sync_custom_field_to_bms(custom_attribute)
  end

  private

  def handle_contact(contact)
    return unless @enable_contact_sync

    contact.reload
    unless identifiable_contact?(contact)
      Rails.logger.info("Contact not identifiable. Skipping handle_contact for ##{contact.id}")
      return
    end

    stored_contact_id = get_external_id(contact)
    create_or_update_contact(contact, stored_contact_id)
  end

  def create_or_update_contact(contact, contact_id)
    contact_data = Crm::Bms::Mappers::ContactMapper.map(contact)

    # Debug: Log the exact payload being sent
    Rails.logger.info("BMS: Sending contact payload: #{contact_data.to_json}")

    if contact_id.present?
      @contact_client.update_contact(contact_data)
      Rails.logger.info("Updated BMS contact #{contact_id} for Evolution contact #{contact.id}")
    else
      new_contact_id = @contact_finder.find_or_create(contact)
      store_external_id(contact, new_contact_id)
      Rails.logger.info("Created/Found BMS contact #{new_contact_id} for Evolution contact #{contact.id}")
    end
  rescue Crm::Bms::Api::BaseClient::ApiError => e
    EvolutionExceptionTracker.new(e).capture_exception
    Rails.logger.error "BMS API error processing contact: #{e.message}"
  rescue StandardError => e
    EvolutionExceptionTracker.new(e).capture_exception
    Rails.logger.error "Error processing contact in BMS: #{e.message}"
  end

  def sync_contact_labels(contact)
    # Always sync ALL current labels to ensure consistency
    # This approach handles both additions and removals properly

    Rails.logger.info("BMS: Syncing all current labels for contact #{contact.id}")
    Rails.logger.info("BMS: Current labels: #{contact.labels.pluck(:name).inspect}")

    if contact.labels.any?
      contact.labels.each do |label|
        # Ensure label exists in BMS
        sync_label_to_bms(label)

        # Add tag to contact in BMS
        contact_data = Crm::Bms::Mappers::ContactMapper.map(contact)
        Rails.logger.info("BMS: Adding tag '#{label.name}' to contact")
        @contact_client.add_tag_to_contact(contact_data, label.name)
      end
    else
      # If no labels, send empty update to remove all tags
      Rails.logger.info('BMS: No labels found, updating contact without tags')
      contact_data = Crm::Bms::Mappers::ContactMapper.map(contact)
      @contact_client.update_contact(contact_data)
    end
  rescue Crm::Bms::Api::BaseClient::ApiError => e
    EvolutionExceptionTracker.new(e).capture_exception
    Rails.logger.error "BMS API error syncing contact labels: #{e.message}"
  rescue StandardError => e
    EvolutionExceptionTracker.new(e).capture_exception
    Rails.logger.error "Error syncing contact labels to BMS: #{e.message}"
  end

  def sync_contact_labels_with_removal_detection(contact, event_data = {})
    # Try to use EventDispatcherJob's changed_attributes first
    if event_data && event_data[:changed_attributes] && event_data[:changed_attributes]['label_list']
      Rails.logger.info('BMS: Using changed_attributes from EventDispatcherJob')
      previous_labels, current_labels = event_data[:changed_attributes]['label_list']
      Rails.logger.info("BMS: Previous labels from event: #{previous_labels.inspect}")
      Rails.logger.info("BMS: Current labels from event: #{current_labels.inspect}")
    else
      # Fallback to cache-based approach
      Rails.logger.info('BMS: Using cache-based approach - changed_attributes not available')
      cache_key = "bms_contact_labels_#{contact.id}"
      previous_labels = TenantCache.read(cache_key) || []
      current_labels = contact.labels.pluck(:name)

      Rails.logger.info("BMS: Previous labels from cache: #{previous_labels.inspect}")
      Rails.logger.info("BMS: Current labels from contact: #{current_labels.inspect}")
    end

    # Store current labels for next time (cache approach)
    cache_key = "bms_contact_labels_#{contact.id}"
    TenantCache.write(cache_key, current_labels, expires_in: 1.hour)

    # Handle removed labels
    removed_labels = previous_labels - current_labels
    removed_labels.each do |removed_label_name|
      Rails.logger.info("BMS: Removing tag '#{removed_label_name}' from contact using removeTag parameter")
      contact_data = Crm::Bms::Mappers::ContactMapper.map(contact)
      @contact_client.remove_tag_from_contact(contact_data, removed_label_name)
    end

    # Handle added labels
    added_labels = current_labels - previous_labels
    added_labels.each do |added_label_name|
      Rails.logger.info("BMS: Adding tag '#{added_label_name}' to contact")
      label = contact.labels.find { |l| l.name == added_label_name }
      next unless label

      sync_label_to_bms(label)
      contact_data = Crm::Bms::Mappers::ContactMapper.map(contact)
      @contact_client.add_tag_to_contact(contact_data, label.name)
    end

  rescue Crm::Bms::Api::BaseClient::ApiError => e
    EvolutionExceptionTracker.new(e).capture_exception
    Rails.logger.error "BMS API error syncing contact label changes: #{e.message}"
  rescue StandardError => e
    EvolutionExceptionTracker.new(e).capture_exception
    Rails.logger.error "Error syncing contact label changes to BMS: #{e.message}"
  end

  def sync_contact_labels_with_changes(contact, event_data)
    Rails.logger.info('BMS: Using removal detection with event_data')
    # Pass event_data to try to use changed_attributes from EventDispatcherJob
    sync_contact_labels_with_removal_detection(contact, event_data)
  rescue Crm::Bms::Api::BaseClient::ApiError => e
    EvolutionExceptionTracker.new(e).capture_exception
    Rails.logger.error "BMS API error syncing contact label changes: #{e.message}"
  rescue StandardError => e
    EvolutionExceptionTracker.new(e).capture_exception
    Rails.logger.error "Error syncing contact label changes to BMS: #{e.message}"
  end

  def sync_contact_custom_attributes(contact)
    return unless contact.custom_attributes.present? && contact.custom_attributes.any?

    # Get account custom attribute definitions for contact attributes only
    custom_attribute_definitions = CustomAttributeDefinition.contact_attribute

    # For each custom attribute that the contact has a value for,
    # ensure the corresponding field definition exists in BMS
    contact.custom_attributes.each_key do |attribute_key|
      definition = custom_attribute_definitions.find { |d| d.attribute_key == attribute_key }
      next unless definition # Skip if definition doesn't exist

      # Ensure custom field exists in BMS
      sync_custom_field_to_bms(definition)
    end

    # Update contact with custom attributes in BMS (the mapper will handle the custom attributes)
    contact_data = Crm::Bms::Mappers::ContactMapper.map(contact)
    @contact_client.update_contact(contact_data)

    Rails.logger.info("BMS: Synced custom attributes for contact #{contact.id}: #{contact.custom_attributes.keys.join(', ')}")
  rescue Crm::Bms::Api::BaseClient::ApiError => e
    EvolutionExceptionTracker.new(e).capture_exception
    Rails.logger.error "BMS API error syncing contact custom attributes: #{e.message}"
  rescue StandardError => e
    EvolutionExceptionTracker.new(e).capture_exception
    Rails.logger.error "Error syncing contact custom attributes to BMS: #{e.message}"
  end

  def sync_label_to_bms(label)
    tag_data = Crm::Bms::Mappers::LabelMapper.map(label)

    # Check if tag already exists in BMS (stored in additional_attributes)
    stored_tag_id = get_label_external_id(label)

    if stored_tag_id.present?
      @tag_client.update_tag(stored_tag_id, tag_data)
      Rails.logger.info("Updated BMS tag #{stored_tag_id} for Evolution label #{label.id}")
    else
      new_tag_id = @tag_client.create_tag(tag_data)
      store_label_external_id(label, new_tag_id)
      Rails.logger.info("Created BMS tag #{new_tag_id} for Evolution label #{label.id}")
    end
  rescue Crm::Bms::Api::BaseClient::ApiError => e
    EvolutionExceptionTracker.new(e).capture_exception
    Rails.logger.error "BMS API error syncing label: #{e.message}"
  rescue StandardError => e
    EvolutionExceptionTracker.new(e).capture_exception
    Rails.logger.error "Error syncing label to BMS: #{e.message}"
  end

  def sync_custom_field_to_bms(custom_attribute_definition)
    custom_field_data = Crm::Bms::Mappers::CustomAttributeMapper.map(custom_attribute_definition)

    # Check if custom field already exists in BMS
    stored_field_id = get_custom_attribute_external_id(custom_attribute_definition)

    if stored_field_id.present?
      @custom_field_client.update_custom_field(stored_field_id, custom_field_data)
      Rails.logger.info("Updated BMS custom field #{stored_field_id} for Evolution custom attribute #{custom_attribute_definition.id}")
    else
      new_field_id = @custom_field_client.create_custom_field(custom_field_data)
      store_custom_attribute_external_id(custom_attribute_definition, new_field_id)
      Rails.logger.info("Created BMS custom field #{new_field_id} for Evolution custom attribute #{custom_attribute_definition.id}")
    end
  rescue Crm::Bms::Api::BaseClient::ApiError => e
    EvolutionExceptionTracker.new(e).capture_exception
    Rails.logger.error "BMS API error syncing custom field: #{e.message}"
  rescue StandardError => e
    EvolutionExceptionTracker.new(e).capture_exception
    Rails.logger.error "Error syncing custom field to BMS: #{e.message}"
  end

  def saved_changes_include_labels?(event_data)
    # Check if the contact's labels were modified
    event_data[:saved_changes] || {}
    # This would need to be implemented based on how label changes are tracked
    # For now, we'll sync labels on every contact update if label sync is enabled
    true
  end

  def saved_changes_include_custom_attributes?(event_data)
    saved_changes = event_data[:saved_changes] || {}
    # Only check for custom_attributes changes since we only sync contact custom attributes
    saved_changes.key?('custom_attributes')
  end

  def get_label_external_id(label)
    # For now, store label mapping in a simple in-memory cache or use the label title as identifier
    # This can be improved when additional_attributes column is added to labels table
    TenantCache.read("bms_label_mapping_#{label.id}")
  end

  def store_label_external_id(label, external_id)
    # Store in cache for now - can be moved to DB additional_attributes later
    TenantCache.write("bms_label_mapping_#{label.id}", external_id, expires_in: 30.days)
    Rails.logger.info("BMS: Stored label mapping #{label.id} -> #{external_id}")
  end

  def get_custom_attribute_external_id(custom_attribute_definition)
    # Store custom field mapping in cache for now
    TenantCache.read("bms_custom_field_mapping_#{custom_attribute_definition.id}")
  end

  def store_custom_attribute_external_id(custom_attribute_definition, external_id)
    # Store in cache for now - can be moved to DB additional_attributes later
    TenantCache.write("bms_custom_field_mapping_#{custom_attribute_definition.id}", external_id, expires_in: 30.days)
    Rails.logger.info("BMS: Stored custom field mapping #{custom_attribute_definition.id} -> #{external_id}")
  end
end
