Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Staging espeja producción (no dev): eager load para que sidekiq-cron
  # resuelva las clases de jobs al encolar (con lazy-load, constantize falla
  # con NameError y encola el payload crudo => `undefined method 'jid='`).
  config.cache_classes = true

  config.eager_load = true

  # Show full error reports.
  config.consider_all_requests_local = true

  # Allow all hosts for MCP development
  config.hosts.clear

  # Allow CORS for MCP endpoints
  config.action_dispatch.default_headers = {
    'Access-Control-Allow-Origin' => '*',
    'Access-Control-Allow-Methods' => 'GET, POST, PUT, DELETE, OPTIONS',
    'Access-Control-Allow-Headers' => '*'
  }

  # Enable/disable caching. By default caching is disabled.
  # Run rails dev:cache to toggle caching.
  # Staging espeja producción (no dev): cache en Redis compartido.
  config.action_controller.perform_caching = true
  config.cache_store = :redis_cache_store, { url: ENV.fetch('REDIS_URL') }
  config.public_file_server.enabled = true

  # Store uploaded files on the local file system (see config/storage.yml for options).
  config.active_storage.service = ENV.fetch('ACTIVE_STORAGE_SERVICE', 'local').to_sym
  # Attachments are served by the app (ActiveStorage proxy) so the internal
  # S3/MinIO endpoint never reaches the browser (EVO-2006).
  # ATTACHMENT_DELIVERY=redirect rolls back to storage redirects.
  config.active_storage.resolve_model_to_route =
    ENV.fetch('ATTACHMENT_DELIVERY', 'proxy').casecmp('redirect').zero? ? :rails_storage_redirect : :rails_storage_proxy

  config.active_job.queue_adapter = :sidekiq

  # Use BACKEND_URL for Active Storage and route URLs
  backend_url = URI.parse(ENV.fetch('BACKEND_URL', 'http://localhost:3000'))
  Rails.application.routes.default_url_options = {
    host: backend_url.host,
    port: backend_url.port,
    protocol: backend_url.scheme
  }

  # Como producción: nunca dumpear schema (los hijos de tenants:replay/
  # migrate_all corren con search_path de tenant y contaminarían db/schema.rb
  # con el dump del tenant — staging 2026-10-01).
  config.active_record.dump_schema_after_migration = false

  # Print deprecation notices to the Rails logger.
  config.active_support.deprecation = :log

  # Raise an error on page load if there are pending migrations.
  config.active_record.migration_error = :page_load

  # Highlight code that triggered database queries in logs.
  config.active_record.verbose_query_logs = true

  # API mode: sin sprockets en este servicio (los assets los sirve el frontend).
  # staging.rb arrastraba config.assets del template; se desactiva.
  # config.assets.debug = true
  # config.assets.quiet = true

  # Raises error for missing translations.
  # config.action_view.raise_on_missing_translations = true

  # Use an evented file watcher to asynchronously detect changes in source code,
  # routes, locales, etc. This feature depends on the listen gem.
  config.file_watcher = ActiveSupport::EventedFileUpdateChecker

  # Disable host check during development
  config.hosts = nil

  # GitHub Codespaces configuration
  if ENV['CODESPACES']
    # Allow web console access from any IP
    config.web_console.allowed_ips = %w(0.0.0.0/0 ::/0)
    # Allow CSRF from codespace URLs
    config.force_ssl = false
    config.action_controller.forgery_protection_origin_check = false
  end

  # customize using the environment variables
  config.log_level = ENV.fetch('LOG_LEVEL', 'debug').to_sym

  # Use a different logger for distributed setups.
  # require 'syslog/logger'
  config.logger = ActiveSupport::Logger.new(Rails.root.join('log', "#{Rails.env}.log"), 1, ENV.fetch('LOG_SIZE', '1024').to_i.megabytes)

  # Bullet configuration to fix the N+1 queries
  config.after_initialize do
    if defined?(Bullet)
      Bullet.enable = true
      Bullet.bullet_logger = true
      Bullet.rails_logger = true
    end
  end
end
