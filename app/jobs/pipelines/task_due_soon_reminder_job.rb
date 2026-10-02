class Pipelines::TaskDueSoonReminderJob < ApplicationJob
  include TenantDispatch

  queue_as :scheduled_jobs

  def perform(tenant_schema: nil)
    if tenant_schema.nil? && multitenant_active?
      dispatch_to_each_tenant(self.class)
      return
    end

    Rails.logger.info '[TaskDueSoonReminderJob] Starting due soon reminders check...'

    # Find tasks due in next 1 hour
    due_soon_tasks = PipelineTask.pending.due_soon

    Rails.logger.info "[TaskDueSoonReminderJob] Found #{due_soon_tasks.count} tasks due soon"

    due_soon_tasks.find_each do |task|
      process_due_soon_task(task)
    end

    Rails.logger.info '[TaskDueSoonReminderJob] Completed due soon reminders check'
  end

  private

  def process_due_soon_task(task)
    # Only send if not already notified
    unless notification_sent?(task)
      PipelineTasks::NotificationService.new(
        task: task,
        notification_type: :pipeline_task_due_soon
      ).perform

      # Track notification
      # rubocop:disable Rails/SkipsModelValidations
      task.update_column(:metadata, task.metadata.merge(
                                      due_soon_notification_sent_at: Time.current
                                    ))
      # rubocop:enable Rails/SkipsModelValidations
    end
  rescue StandardError => e
    Rails.logger.error "[TaskDueSoonReminderJob] Error processing task #{task.id}: #{e.message}"
    Sentry.capture_exception(e) if defined?(Sentry)
  end

  def notification_sent?(task)
    task.metadata['due_soon_notification_sent_at'].present?
  end
end
