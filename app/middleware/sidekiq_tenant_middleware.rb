# Middleware de Sidekiq para multitenant A2 (revisado: propagación total).
#
# Patrón dispatcher/fan-out: los schedulers NO iteran tenants haciendo el
# trabajo inline (retendrían la conexión con el search_path fijado y un
# tenant pesado demoraría al resto). Encolan un job liviano por tenant y
# este middleware restaura el search_path al ejecutar.
#
# Propagación en dos niveles (cierra la fuga de enqueues anidados: un worker
# que encola hijos con args posicionales, p.ej. `perform_later(id1, id2)`,
# perdería el tenant si solo miráramos hashes):
#   - Client: si hay tenant en contexto y el payload no trae uno explícito,
#     lo inyecta en `job_payload['tenant_schema']` (clave custom, sobrevive
#     la serialización; Sidekiq la ignora).
#   - Server: prefiere `tenant_schema` explícito en los args (kwargs del
#     dispatcher), si no usa el top-level inyectado. Sin ninguno => legacy.
module SidekiqTenantMiddleware
  class Server
    def call(job_instance, job_payload, _queue)
      schema = explicit_tenant(job_payload) || job_payload['tenant_schema']
      return yield unless schema

      ActiveRecord::Base.connection.execute("SET search_path TO #{schema}, public, extensions")
      TenantContext.schema_name = schema
      tag_sentry(schema)
      yield
    ensure
      # Tolerante: si la conexión murió, el RESET no debe enmascarar el error.
      begin
        ActiveRecord::Base.connection.execute('RESET search_path')
      rescue StandardError
        nil
      end
      TenantContext.reset
    end

    private

    def explicit_tenant(job_payload)
      args = job_payload['args']
      return nil unless args.is_a?(Array)

      hash = args.reverse.find { |a| a.is_a?(Hash) }
      hash && (hash['tenant_schema'] || hash[:tenant_schema])
    end

    def tag_sentry(schema)
      return unless defined?(Sentry)

      Sentry.set_context('tenant', { schema: schema })
    rescue StandardError
      nil
    end
  end

  class Client
    # Hereda el tenant del contexto a TODOS los jobs encolados, salvo que
    # traigan uno explícito (dispatcher apuntando a otro tenant).
    def call(_worker_class, job_payload, _queue, _redis_pool)
      if TenantContext.schema_name && !explicit_present?(job_payload)
        job_payload['tenant_schema'] = TenantContext.schema_name
      end
      yield
    end

    private

    def explicit_present?(job_payload)
      args = job_payload['args']
      return false unless args.is_a?(Array)

      args.any? { |a| a.is_a?(Hash) && (a.key?('tenant_schema') || a.key?(:tenant_schema)) }
    end
  end
end
