# housekeeping
# remove contact inboxes that does not have any conversations
# and are older than 3 months

class Internal::RemoveStaleContactInboxesJob < ApplicationJob
  include TenantDispatch

  queue_as :scheduled_jobs

  def perform(tenant_schema: nil)
    if tenant_schema.nil? && multitenant_active?
      dispatch_to_each_tenant(self.class)
      return
    end

    Internal::RemoveStaleContactInboxesService.new.perform
  end
end
