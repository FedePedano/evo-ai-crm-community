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

      # Fail-closed: schema con formato inválido o tenant inexistente/
      # inactivo => el job NO corre (ni en public ni en otro tenant).
      # Además `public` queda FUERA del path: Postgres resuelve al primer
      # schema que tenga la tabla, y con public presente una tabla ausente
      # en el tenant se lee/escribe silenciosamente en public (staging
      # 2026-10-01). Sin public, ausente = error duro.
      validate_tenant!(schema)

      ActiveRecord::Base.connection.execute("SET search_path TO #{schema}, extensions")
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

    def validate_tenant!(schema)
      fmt_ok = schema.is_a?(String) && schema.match?(/\Acliente_[a-z0-9_]+\z/)
      active = fmt_ok && Tenant.active.exists?(schema_name: schema)
      return if active

      raise "SidekiqTenantMiddleware: tenant inválido o inactivo (#{schema.inspect}), job rechazado"
    rescue RuntimeError
      raise
    rescue StandardError
      raise "SidekiqTenantMiddleware: sin registro de tenants, job con tenant rechazado (#{schema.inspect})"
    end

    def explicit_tenant(job_payload)
      args = job_payload['args']
      return nil unless args.is_a?(Array)

      # 1) Push directo (sidekiq-cron legacy, perform_async con kwargs).
      direct = args.reverse.find { |a| a.is_a?(Hash) }
      found = direct && (direct['tenant_schema'] || direct[:tenant_schema])
      return found if found

      # 2) Wrapper de ActiveJob: los kwargs viajan anidados en
      #    job_data["arguments"] (no a nivel top). Sin esto, el middleware
      #    nunca ve el tenant y el worker corre en `public` (staging
      #    2026-10-01: el fan-out "verde" era vacuo).
      job_data = args.find { |a| a.is_a?(Hash) && a['arguments'].is_a?(Array) }
      return nil unless job_data

      nested = job_data['arguments'].reverse.find { |a| a.is_a?(Hash) }
      nested && (nested['tenant_schema'] || nested[:tenant_schema])
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
