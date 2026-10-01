# Prefijo de tenant para Rails.cache (multitenant A2, exp/multitenant-a2).
#
# Todas las keys pasan por acá: `tenant:<schema>:<key>` con tenant activo,
# `global:<key>` sin tenant (deployment single-tenant actual: las keys
# resultantes son `global:...`, distintas de las legacy sin prefijo — el
# primer deploy con este helper invalida la caché una vez, efecto
# autolimitado por los TTL cortos).
#
# Deliberadamente sin dependencias de Rails (solo TenantContext): testeable
# con ruby pelado. Rails.cache se resuelve en cada llamada para no romper
# en contextos donde aún no está cargado.
module TenantCache
  def self.key(key)
    schema = defined?(TenantContext) ? TenantContext.schema_name : nil
    schema = nil if schema.respond_to?(:empty?) && schema.empty?
    schema ? "tenant:#{schema}:#{key}" : "global:#{key}"
  end

  def self.fetch(key, **opts, &block)
    Rails.cache.fetch(self.key(key), **opts, &block)
  end

  def self.read(key, **opts)
    Rails.cache.read(self.key(key), **opts)
  end

  def self.write(key, value, **opts)
    Rails.cache.write(self.key(key), value, **opts)
  end

  def self.delete(key, **opts)
    Rails.cache.delete(self.key(key), **opts)
  end

  def self.exist?(key, **opts)
    Rails.cache.exist?(self.key(key), **opts)
  end
end
