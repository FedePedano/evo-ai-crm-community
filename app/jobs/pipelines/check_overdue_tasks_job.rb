class Pipelines::CheckOverdueTasksJob < ApplicationJob
  include TenantDispatch

  queue_as :scheduled_jobs

  def perform(tenant_schema: nil)
    if tenant_schema.nil? && multitenant_active?
      dispatch_to_each_tenant(self.class)
      return
    end

    Rails.logger.info '[CheckOverdueTasksJob] Starting overdue tasks check...'

    # Find all pending tasks that are past due
    overdue_tasks = PipelineTask.pending.past_due

    Rails.logger.info "[CheckOverdueTasksJob] Found #{overdue_tasks.count} overdue tasks"

    overdue_tasks.find_each do |task|
      process_overdue_task(task)
    end

    Rails.logger.info '[CheckOverdueTasksJob] Completed overdue tasks check'
  end

  private

  def process_overdue_task(task)
    # Mark as overdue
    task.mark_as_overdue

    # Send notification (only if not already sent today)
    unless notification_sent_today?(task)
      PipelineTasks::NotificationService.new(
        task: task,
        notification_type: :pipeline_task_overdue
      ).perform

      # Track notification in metadata
      # rubocop:disable Rails/SkipsModelValidations
      task.update_column(:metadata, task.metadata.merge(
                                      last_overdue_notification_at: Time.current
                                    ))
      # rubocop:enable Rails/SkipsModelValidations
    end
  rescue StandardError => e
    Rails.logger.error "[CheckOverdueTasksJob] Error processing task #{task.id}: #{e.message}"
    Sentry.capture_exception(e) if defined?(Sentry)
  end

  def notification_sent_today?(task)
    last_sent = task.metadata['last_overdue_notification_at']
    return false if last_sent.blank?

    Time.zone.parse(last_sent).to_date == Date.current
  end
end
