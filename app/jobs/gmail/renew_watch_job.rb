class Gmail::RenewWatchJob < ApplicationJob
  include TenantDispatch

  queue_as :low

  def perform(tenant_schema: nil)
    if tenant_schema.nil? && multitenant_active?
      dispatch_to_each_tenant(self.class)
      return
    end

    Rails.logger.info '[GMAIL_PUSH] Starting watch renewal for all Gmail channels'

    renewed_count = 0
    failed_count = 0

    Channel::Email.where(provider: 'google').find_each do |channel|
      next unless channel.push_enabled?

      renew_watch_for_channel(channel)
      renewed_count += 1
    rescue StandardError => e
      failed_count += 1
      Rails.logger.error "[GMAIL_PUSH] Failed to renew watch for #{channel.email}: #{e.message}"
      EvolutionExceptionTracker.new(e, account: nil).capture_exception
    end

    Rails.logger.info "[GMAIL_PUSH] Watch renewal completed: #{renewed_count} successful, #{failed_count} failed"
  end

  private

  def renew_watch_for_channel(channel)
    gmail_service = Gmail::ApiService.new(channel: channel)

    # Check if watch is about to expire (within 24 hours)
    expiration = channel.provider_config['watch_expiration']

    if expiration && Time.at(expiration / 1000) > 24.hours.from_now
      Rails.logger.debug "[GMAIL_PUSH] Watch for #{channel.email} still valid, skipping"
      return
    end

    # Renew watch
    response = gmail_service.watch_mailbox

    Rails.logger.info "[GMAIL_PUSH] Watch renewed for #{channel.email} - expires: #{Time.at(response.expiration.to_i / 1000)}"
  rescue OAuth2::Error => e
    Rails.logger.error "[GMAIL_PUSH] OAuth error for #{channel.email}: #{e.message}"
    channel.authorization_error!
    raise
  end
end
