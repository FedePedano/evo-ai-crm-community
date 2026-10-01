# Tareas Fase 2 multitenant A2 (rama exp/multitenant-a2).
#
# tenants:replay[slug] — corre las 86 migraciones del CRM dentro del schema
#   del tenant. La tabla `schema_migrations` queda LOCAL al schema (cada
#   tenant trackea sus migraciones; `public` intacto).
# tenants:seed_business[slug,email] — seed mínimo: admin (Devise) + equipo +
#   membresía por email.
#
# Mecanismo: el adapter PG resetea `search_path` en cada checkout, así que un
# SET manual no sobrevive al pool. Se delega a un proceso hijo con
# TENANT_SCHEMA_SEARCH_PATH (soportado en database.yml) — todo su pool
# nace con el schema del tenant primero. Riel anti-public incluido.

namespace :tenants do
  def lookup_tenant!(slug)
    abort 'sin registro public.tenants: nada que replicar' unless ActiveRecord::Base.connection.table_exists?('public.tenants')

    tenant = Tenant.active.find_by(slug: slug)
    abort "tenant desconocido o inactivo: #{slug}" unless tenant
    abort "schema inseguro: #{tenant.schema_name}" unless tenant.schema_name =~ /\Acliente_[a-z0-9_]+\z/

    tenant
  end

  def with_tenant_env!(tenant)
    # Sin `public` a propósito (ver middleware): fail-closed real.
    env = { 'TENANT_SCHEMA_SEARCH_PATH' => "#{tenant.schema_name}, extensions" }
    yield env
  end

  # Las tablas de bookkeeping DEBEN pre-existir en el schema del tenant:
  # si no, resuelven a las de `public` (fallback silencioso) y el replay
  # cree que está al día (0 pendientes). Espejan el DDL de Rails 7.1.
  def ensure_tenant_bookkeeping!(tenant)
    conn = ActiveRecord::Base.connection
    conn.execute(<<~SQL)
      CREATE TABLE IF NOT EXISTS #{tenant.schema_name}.schema_migrations
        (version character varying NOT NULL PRIMARY KEY)
    SQL
    conn.execute(<<~SQL)
      CREATE TABLE IF NOT EXISTS #{tenant.schema_name}.ar_internal_metadata
        ("key" character varying NOT NULL PRIMARY KEY, value character varying,
         created_at timestamp(6) NOT NULL, updated_at timestamp(6) NOT NULL)
    SQL
  end

  # Las migraciones están incompletas (drift: `users`, `roles`,
  # `active_storage_*` solo existen vía schema:load — staging 2026-10-01).
  # El replay es un schema:load FILTRADO al schema del tenant:
  # - fuera `create_schema` (el tenant ya existe; el resto es de Supabase),
  # - fuera `enable_extension` (resuelven por path vía `extensions`),
  # - fuera residuo de experimento (`_provision_log` lo crea provision),
  # - `public.X` -> `X` (el tenant debe ser autocontenido, sin tocar public).
  def filtered_tenant_schema!
    out = []
    skip_block = false
    File.readlines(Rails.root.join('db/schema.rb')).each do |line|
      if line =~ /^\s*create_table "_provision_log"/
        skip_block = true
        next
      end
      if skip_block
        skip_block = false if line.strip == 'end'
        next
      end
      next if line =~ /^\s*create_schema /
      next if line =~ /^\s*enable_extension /
      out << line.gsub('"public.', '"')
    end
    path = Rails.root.join('tmp/tenant_schema.rb')
    File.write(path, out.join)
    path
  end

  desc 'Replica el schema del CRM (schema:load filtrado) en el schema del tenant'
  task :replay, [:slug] => :environment do |_, args|
    tenant = lookup_tenant!(args[:slug])
    ensure_tenant_bookkeeping!(tenant)
    schema_file = filtered_tenant_schema!
    with_tenant_env!(tenant) do |env|
      puts "replay #{tenant.slug} -> #{tenant.schema_name} (schema:load filtrado)..."
      ok = system(env.merge('SCHEMA' => schema_file.to_s), 'bundle', 'exec', 'rails', 'db:schema:load')
      abort 'replay falló' unless ok
    end
    # schema:load registra una versión vieja: se fija a la del schema actual
    # para que los futuros `db:migrate` por tenant sean no-op hasta la
    # próxima migración real.
    file_version = File.read(Rails.root.join('db/schema.rb'))[/define\(version: (\d[\d_]+)\)/, 1].delete('_')
    conn = ActiveRecord::Base.connection
    conn.execute("DELETE FROM #{tenant.schema_name}.schema_migrations")
    conn.execute("INSERT INTO #{tenant.schema_name}.schema_migrations (version) VALUES ('#{file_version}')")
    count = ActiveRecord::Base.connection.execute(
      "SELECT count(*) FROM information_schema.tables WHERE table_schema = '#{tenant.schema_name}'"
    ).getvalue(0, 0)
    puts "OK: #{count} tablas en #{tenant.schema_name}"
  end

  desc 'Seed mínimo de negocio: admin + equipo + membresía (password aleatorio)'
  task :seed_business, %i[slug email] => :environment do |_, args|
    abort 'falta email' if args[:email].blank?

    tenant = lookup_tenant!(args[:slug])
    with_tenant_env!(tenant) do |env|
      script = <<~RUBY
        # Auth real vive en evo-auth (externo): aquí solo identidad + rol.
        # El login por password se cablea con la integración auth (Fase 2).
        user = User.find_or_create_by!(email: '#{args[:email]}') do |u|
          u.name = 'Admin Tenant'
        end
        team = Team.find_or_create_by!(name: 'Comercial')
        team.update!(description: 'Equipo inicial del tenant (seed experimento A2)')
        TenantMembership.find_or_create_by!(tenant_id: '#{tenant.id}', user_id: user.id) do |m|
          m.email = '#{args[:email]}'
          m.role = 'owner'
        end
        puts "OK seed #{tenant.slug}: user=\#{user.email} team=\#{team.name}"
      RUBY
      ok = system(env, 'bundle', 'exec', 'rails', 'runner', '-e', Rails.env, script)
      abort 'seed falló' unless ok
    end
  end
end
