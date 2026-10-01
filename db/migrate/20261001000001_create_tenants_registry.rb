class CreateTenantsRegistry < ActiveRecord::Migration[7.1]
  # Registro global de tenants (Fase 0 multitenant A2). Vive SIEMPRE en el
  # schema `public` y se accede con tabla calificada, nunca via search_path.
  # El resto de las tablas del CRM vive replicado en un schema por tenant.
  def change
    create_table :tenants, id: :uuid, default: -> { 'gen_random_uuid()' } do |t|
      t.string :slug, null: false
      t.string :schema_name, null: false
      t.string :status, null: false, default: 'active'
      t.string :plan, null: false, default: 'free'
      t.timestamps
    end
    add_index :tenants, :slug, unique: true
    add_index :tenants, :schema_name, unique: true

    # Membresía many-to-many usuario<->tenant desde el día uno (aunque hoy
    # el caso de uso sea 1:1): cambiarlo después es mucho más doloroso.
    create_table :tenant_memberships, id: :uuid, default: -> { 'gen_random_uuid()' } do |t|
      t.uuid :tenant_id, null: false
      t.uuid :user_id, null: false
      t.string :role, null: false, default: 'owner'
      t.timestamps
    end
    add_index :tenant_memberships, [:tenant_id, :user_id], unique: true
    add_foreign_key :tenant_memberships, :tenants
  end
end
