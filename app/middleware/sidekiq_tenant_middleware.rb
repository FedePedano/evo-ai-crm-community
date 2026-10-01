# Middleware de Sidekiq para multitenant A2.
#
# Patrón dispatcher/fan-out: los schedulers NO iteran tenants haciendo el
# trabajo inline (retendrían la conexión con el search_path fijado y un
# tenant pesado demoraría al resto). Encolan un job liviano por tenant con
# `tenant_schema` en los argumentos; este middleware restaura el
# search_path al ejecutar y lo resetea al terminar.
module SidekiqTenantMiddleware
  class Server
    def call(job_instance, job_payload, _queue)
      schema = job_payload['args']&.first.is_a?(Hash) ? job_payload['args'].first['tenant_schema'] : nil
      schema ||= job_payload['tenant_schema']
      return yield unless schema

      ActiveRecord::Base.connection.execute("SET search_path TO #{schema}, public, extensions")
      TenantContext.schema_name = schema
      tag_sentry(schema)
      yield
    ensure
      begin
        ActiveRecord::Base.connection.execute('RESET search_path')
      rescue StandardError
        nil
      end
      TenantContext.reset
    end

    private

    def tag_sentry(schema)
      return unless defined?(Sentry)

      Sentry.set_context('tenant', { schema: schema })
    rescue StandardError
      nil
    end
  end

  class Client
    # Propaga el tenant del contexto actual a los jobs encolados.
    def call(_worker_class, job_payload, _queue, _redis_pool)
      if TenantContext.schema_name && job_payload['args']&.first.is_a?(Hash)
        job_payload['args'].first['tenant_schema'] ||= TenantContext.schema_name
      end
      yield
    end
  end
end
