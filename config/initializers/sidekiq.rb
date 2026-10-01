require Rails.root.join('lib/redis/config')
# Multitenant A2: require explícito (los initializers corren antes de que
# Zeitwerk gestione app/middleware).
require_relative '../../app/middleware/sidekiq_tenant_middleware'

schedule_file = 'config/schedule.yml'

Sidekiq.configure_client do |config|
  config.redis = Redis::Config.app
  # Multitenant A2: propaga el tenant del contexto a los jobs encolados.
  config.client_middleware do |chain|
    chain.add SidekiqTenantMiddleware::Client
  end
end

Sidekiq.configure_server do |config|
  config.redis = Redis::Config.app
  # Multitenant A2: restaura el search_path del tenant al ejecutar.
  config.server_middleware do |chain|
    chain.add SidekiqTenantMiddleware::Server
  end

  # Poll scheduled jobs more frequently (default is 5-15s which delays debounce jobs)
  config[:average_scheduled_poll_interval] = 1

  # skip the default start stop logging
  if Rails.env.production?
    config.logger.formatter = Sidekiq::Logger::Formatters::JSON.new
    config[:skip_default_job_logging] = true
    config.logger.level = Logger.const_get(ENV.fetch('LOG_LEVEL', 'info').upcase.to_s)
  end
end

# https://github.com/ondrejbartas/sidekiq-cron
Rails.application.reloader.to_prepare do
  Sidekiq::Cron::Job.load_from_hash YAML.load_file(schedule_file) if File.exist?(schedule_file) && Sidekiq.server?
end
