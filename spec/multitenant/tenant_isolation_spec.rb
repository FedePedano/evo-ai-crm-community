require 'rails_helper'

# Leak-harness multitenant A2 (Fase 0): red de seguridad continua contra
# fuga de datos entre tenants. Corre en CI desde el día uno, ANTES del
# middleware y los satélites, para que cada fase siguiente herede la
# protección en vez de auditarse al final.
#
# Se autocontiene: crea sus propios schemas exp_spec_* en la DB de test y
# los elimina al terminar. No depende de tenants provisionados.
RSpec.describe 'Aislamiento entre tenants (schema-per-tenant)', type: :model do
  SCHEMAS = ['exp_spec_a', 'exp_spec_b'].freeze

  before(:all) do
    conn = ActiveRecord::Base.connection
    SCHEMAS.each { |s| conn.execute("CREATE SCHEMA IF NOT EXISTS #{s}") }
    conn.execute('CREATE TABLE IF NOT EXISTS exp_spec_a.widgets (id serial primary key, v text)')
    conn.execute('CREATE TABLE IF NOT EXISTS exp_spec_b.widgets (id serial primary key, v text)')
    conn.execute("INSERT INTO exp_spec_a.widgets (v) VALUES ('solo-A')")
    conn.execute("INSERT INTO exp_spec_b.widgets (v) VALUES ('solo-B')")
  end

  after(:all) do
    conn = ActiveRecord::Base.connection
    SCHEMAS.each { |s| conn.execute("DROP SCHEMA IF EXISTS #{s} CASCADE") }
  end

  def with_search_path(schema)
    conn = ActiveRecord::Base.connection
    conn.execute("SET search_path TO #{schema}, public")
    yield
  ensure
    ActiveRecord::Base.connection.execute('RESET search_path')
  end

  it 'el tenant A solo ve sus propias filas' do
    rows = with_search_path('exp_spec_a') do
      ActiveRecord::Base.connection.exec_query('SELECT v FROM widgets').to_a
    end
    expect(rows).to eq([{ 'v' => 'solo-A' }])
  end

  it 'el tenant B solo ve sus propias filas' do
    rows = with_search_path('exp_spec_b') do
      ActiveRecord::Base.connection.exec_query('SELECT v FROM widgets').to_a
    end
    expect(rows).to eq([{ 'v' => 'solo-B' }])
  end

  it 'fail-closed: sin search_path la tabla del tenant ni siquiera resuelve' do
    expect do
      ActiveRecord::Base.connection.exec_query('SELECT v FROM widgets')
    end.to raise_error(ActiveRecord::StatementInvalid)
  end

  it 'el search_path queda reseteado después de cada bloque (higiene del pool)' do
    with_search_path('exp_spec_a') { |_| nil }
    path = ActiveRecord::Base.connection.exec_query('SHOW search_path').to_a.first['search_path']
    expect(path).not_to include('exp_spec_a')
  end

  it 'TenantContext taggea "no-tenant" cuando no hay tenant activo' do
    TenantContext.reset
    expect(TenantContext.log_tag).to eq('no-tenant')
  end
end
