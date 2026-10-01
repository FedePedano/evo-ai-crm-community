# Fan-out multitenant para schedulers (Fase 0, rama exp/multitenant-a2).
#
# Regla: un scheduler NUNCA itera tenants haciendo el trabajo inline (retendría
# la conexión con el search_path fijado y un tenant pesado demoraría al resto).
# El scheduler es un dispatcher liviano: encola un job por tenant con
# `tenant_schema` y termina. El middleware de Sidekiq restaura el search_path
# al ejecutar cada hijo. Jitter aleatorio evita thundering herd contra el pool.
module TenantDispatch
  extend ActiveSupport::Concern

  # Encola `worker_class` una vez por tenant activo. Sin tabla de registro
  # (deployment single-tenant actual) encola UNA vez sin tenant (= legacy).
  def dispatch_to_each_tenant(worker_class, *args, max_jitter_seconds: 20)
    schemas = tenant_schemas
    return worker_class.perform_later(*args) if schemas.empty?

    schemas.each do |schema|
      kwargs = args.last.is_a?(Hash) ? args.pop : {}
      worker_class
        .set(wait: rand(0..max_jitter_seconds).seconds)
        .perform_later(*args, **kwargs.merge(tenant_schema: schema))
    end
  end

  private

  def tenant_schemas
    return [] unless ActiveRecord::Base.connection.table_exists?('public.tenants')

    Tenant.active.pluck(:schema_name)
  rescue StandardError
    []
  end
end
