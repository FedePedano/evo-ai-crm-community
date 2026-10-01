class AddEmailToTenantMemberships < ActiveRecord::Migration[7.1]
  # La membresía se matchea por email (no por user_id): los users del CRM
  # viven en el schema del tenant y el servicio de auth (misma base, otro
  # modelo) no puede hacer FK contra ellos. El email es la llave compartida.
  def change
    add_column :tenant_memberships, :email, :string
    add_index :tenant_memberships, [:tenant_id, :email], unique: true,
              name: 'index_tenant_memberships_on_tenant_and_email'
  end
end
