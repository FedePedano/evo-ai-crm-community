# Membresía usuario<->tenant (many-to-many desde el día uno).
class TenantMembership < ApplicationRecord
  self.table_name = 'public.tenant_memberships'

  belongs_to :tenant, class_name: 'Tenant'

  validates :user_id, presence: true
  validates :user_id, uniqueness: { scope: :tenant_id }
end
