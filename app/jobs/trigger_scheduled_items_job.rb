class TriggerScheduledItemsJob < ApplicationJob
  include TenantDispatch

  queue_as :scheduled_jobs

  def perform(tenant_schema: nil)
    # Auto-dispatch multitenant A2: sin tenant + con registro => fan-out.
    if tenant_schema.nil? && multitenant_active?
      dispatch_to_each_tenant(self.class)
      return
    end
    # trigger the scheduled campaign jobs - TEMPORARILY DISABLED (Campaign model removed)
    # Campaign.where(campaign_type: :one_off,
    #                campaign_status: :active).where(scheduled_at: 3.days.ago..Time.current).all.find_each(batch_size: 100) do |campaign|
    #   Campaigns::TriggerOneoffCampaignJob.perform_later(campaign)
    # end

    # Job to reopen snoozed conversations
    Conversations::ReopenSnoozedConversationsJob.perform_later

    # Job to reopen snoozed notifications
    Notification::ReopenSnoozedNotificationsJob.perform_later

    # Job to auto-resolve conversations
    Account::ConversationsResolutionSchedulerJob.perform_later

    # Job to sync whatsapp templates
    Channels::Whatsapp::TemplatesSyncSchedulerJob.perform_later

    # Job to clear notifications which are older than 1 month
    Notification::RemoveOldNotificationJob.perform_later
  end
end

TriggerScheduledItemsJob.prepend_mod_with('TriggerScheduledItemsJob')
