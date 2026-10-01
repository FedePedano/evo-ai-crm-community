# Registro global de tenants. Tabla calificada a `public` a propósito: este
# modelo debe resolverse igual sin importar el search_path activo.
class Tenant < ApplicationRecord
  self.table_name = 'public.tenants'

  has_many :memberships, class_name: 'TenantMembership', foreign_key: :tenant_id, dependent: :destroy

  validates :slug, presence: true, uniqueness: true,
                   format: { with: /\A[a-z0-9_]+\z/, message: 'solo minúsculas, números y guión bajo' }
  validates :schema_name, presence: true, uniqueness: true,
                          format: { with: /\A[a-z0-9_]+\z/, message: 'solo minúsculas, números y guión bajo' }

  scope :active, -> { where(status: 'active') }
end
