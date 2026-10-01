# Worker por-tenant del chequeo de inactividad (fan-out multitenant A2).
# El scheduler encola uno de estos por tenant con `tenant_schema`; el
# middleware de Sidekiq fija el search_path antes de `perform`.
# Con `tenant_schema = nil` corre en modo legacy single-tenant (sin cambios).
class AgentBots::InactivityCheckWorkerJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform(tenant_schema: nil)
    Rails.logger.info "[InactivityWorker] tenant=#{tenant_schema || 'legacy'} starting"

    agent_bots_with_actions = AgentBot.where("bot_config -> 'inactivity_actions' IS NOT NULL")
                                      .where("jsonb_array_length(bot_config -> 'inactivity_actions') > 0")

    agent_bots_with_actions.find_each do |agent_bot|
      inbox_ids = agent_bot.agent_bot_inboxes.active.pluck(:inbox_id)
      next if inbox_ids.empty?

      min_time_ago = 1.minute.ago
      conversations = Conversation.where(inbox_id: inbox_ids)
                                  .where(status: [:open, :pending])
                                  .where('last_activity_at < ?', min_time_ago)

      conversations.find_each(batch_size: 100) do |conversation|
        AgentBots::ProcessInactivityActionsJob.perform_later(conversation.id, agent_bot.id)
      end
    end

    Rails.logger.info "[InactivityWorker] tenant=#{tenant_schema || 'legacy'} completed"
  end
end
