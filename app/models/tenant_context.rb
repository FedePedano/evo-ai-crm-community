# Tenant activo del request/job en curso. Se setea en TenantSwitcher
# (requests) y en el middleware de Sidekiq (jobs). Todo log/Sentry lo lee
# de acá para taggear con el tenant desde el primer middleware.
class TenantContext < ActiveSupport::CurrentAttributes
  attribute :slug, :schema_name

  def self.log_tag
    slug || 'no-tenant'
  end
end
