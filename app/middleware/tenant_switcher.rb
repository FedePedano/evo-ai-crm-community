# Middleware Rack que resuelve el tenant por subdominio y fija el
# `search_path` de Postgres para todo el request (multitenant A2,
# schema-per-tenant). Diseñado para Supavisor en session-mode, donde el
# SET sobrevive en la conexión del pool; ante cada request se fija y al
# salir se resetea (higiene del pool compartido).
#
# Fail-closed: subdominio desconocido => 404, jamás se sirve el schema
# `public` ni el de otro tenant por omisión.
class TenantSwitcher
  # Paths que no necesitan tenant (health checks, rails internas).
  EXCLUDED_PATHS = ['/health', '/rails/'].freeze

  def initialize(app)
    @app = app
  end

  def call(env)
    request = ActionDispatch::Request.new(env)
    # Sin tabla de registro (deployment single-tenant actual) el middleware
    # es totalmente transparente: no toca search_path ni contexto.
    # En test se fuerza transparencia (suite legacy con DB fresca; ver
    # TenantDispatch#multitenant_active?). Override: MULTITENANT_FORCE=1.
    return @app.call(env) if excluded?(request) || test_bypass? || !registry_present?

    slug = tenant_slug(request)
    tenant = slug && Tenant.active.find_by(slug: slug)
    return not_found unless tenant

    switch_to(tenant) do
      tag_current(tenant)
      @app.call(env)
    end
  ensure
    TenantContext.reset
  end

  private

  def excluded?(request)
    EXCLUDED_PATHS.any? { |p| request.path.start_with?(p) }
  end

  def test_bypass?
    ENV['MULTITENANT_FORCE'] != '1' && defined?(Rails) && Rails.env.test?
  rescue StandardError
    false
  end

  # La existencia de la tabla es global (no depende del tenant): se memoiza
  # el positivo y se re-chequea el negativo por si la migración corre después.
  def registry_present?
    return true if @registry_present

    @registry_present = ActiveRecord::Base.connection.table_exists?('public.tenants')
  rescue StandardError
    false
  end

  def tenant_slug(request)
    # Override explícito para desarrollo/test (nunca en producción).
    return ENV['TENANT_SLUG'] if ENV['TENANT_SLUG'].present?
    return request.headers['X-Tenant-Slug'] if request.headers['X-Tenant-Slug'].present?

    request.subdomains.first
  end

  def switch_to(tenant)
    # `public` DELIBERADAMENTE fuera del path (staging 2026-10-01): Postgres
    # resuelve al primer schema que TENGA la tabla, no al primero del path —
    # con `public` presente, una tabla ausente en el tenant lee/escribe
    # SILENCIOSAMENTE en public (fuga). Sin public, tabla ausente = error
    # duro (fail-closed real). `extensions` aporta pgcrypto/uuid-ossp/pg_trgm
    # sin instalarlas por schema. Lecturas globales usan tabla calificada
    # (`public.tenants` en los modelos del registry).
    search_path = [tenant.schema_name, 'extensions'].join(', ')
    ActiveRecord::Base.connection.execute("SET search_path TO #{search_path}")
    TenantContext.slug = tenant.slug
    TenantContext.schema_name = tenant.schema_name
    yield
  ensure
    # Tolerante a propósito: si la conexión murió, el RESET no debe
    # enmascarar el error original (el pool descarta esa conexión igual).
    begin
      ActiveRecord::Base.connection.execute('RESET search_path')
    rescue StandardError
      nil
    end
  end

  def tag_current(tenant)
    return unless defined?(Sentry)

    Sentry.set_context('tenant', { slug: tenant.slug, schema: tenant.schema_name })
  rescue StandardError
    nil
  end

  def not_found
    [404, { 'Content-Type' => 'application/json' }, ['{"error":"unknown tenant"}']]
  end
end
