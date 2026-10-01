class AgentBots::InactivityCheckSchedulerJob < ApplicationJob
  include TenantDispatch

  queue_as :scheduled_jobs

  # Dispatcher multitenant A2: NO hace el trabajo inline (ver TenantDispatch).
  # Sin registro de tenants => UN worker legacy sin tenant (cero cambio).
  def perform
    Rails.logger.info '[InactivityScheduler] dispatching per-tenant workers'
    dispatch_to_each_tenant(AgentBots::InactivityCheckWorkerJob)
    Rails.logger.info '[InactivityScheduler] dispatch done'
  end
end
