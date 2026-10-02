class Internal::DeleteAccountsJob < ApplicationJob
  include TenantDispatch

  queue_as :scheduled_jobs

  def perform(tenant_schema: nil)
    # Auto-dispatch multitenant A2 (hoy no-op; si se implementa, corre por tenant).
    if tenant_schema.nil? && multitenant_active?
      dispatch_to_each_tenant(self.class)
      return
    end
  end
end
