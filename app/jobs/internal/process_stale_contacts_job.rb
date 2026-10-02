# housekeeping
# remove stale contacts
# - have no identification (email, phone_number, and identifier are NULL)
# - have no conversations
# - are older than 30 days

class Internal::ProcessStaleContactsJob < ApplicationJob
  include TenantDispatch

  queue_as :housekeeping

  def perform(tenant_schema: nil)
    if tenant_schema.nil? && multitenant_active?
      dispatch_to_each_tenant(self.class)
      return
    end

    Rails.logger.info "ProcessStaleContactsJob: Starting stale contacts cleanup"
    Internal::RemoveStaleContactsJob.perform_later
  end
end
