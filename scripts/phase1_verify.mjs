import fs from 'node:fs'

const failures = []
const pass = (name, condition, detail = '') => {
  const suffix = detail ? ` - ${detail}` : ''
  if (condition) console.log(`PASS ${name}${suffix}`)
  else {
    console.error(`FAIL ${name}${suffix}`)
    failures.push(name)
  }
}

const read = (path) => fs.readFileSync(path, 'utf8')
const migrationPath = 'supabase/migrations/20260917090000_phase1_auth_membership_rls.sql'
pass('Phase 1 migration exists', fs.existsSync(migrationPath))
const migration = read(migrationPath)

const requiredSql = [
  ['profiles bind to auth.users', /auth_user_id UUID REFERENCES auth\.users\(id\)/],
  ['company memberships exist', /CREATE TABLE IF NOT EXISTS company_memberships/],
  ['warehouse memberships exist', /CREATE TABLE IF NOT EXISTS warehouse_memberships/],
  ['tenant-safe balance location FK', /inventory_balances_company_location_fk/],
  ['tenant-safe balance product FK', /inventory_balances_company_product_fk/],
  ['tenant-safe movement actor FK', /inventory_movements_company_performed_by_fk/],
  ['actor required on new operations', /CHECK \(initiating_actor IS NOT NULL\) NOT VALID/],
  ['actor required on new movements', /CHECK \(performed_by IS NOT NULL\) NOT VALID/],
  ['current profile derives from auth.uid', /WHERE p\.auth_user_id = auth\.uid\(\)/],
  ['warehouse permission helper exists', /FUNCTION has_warehouse_permission/],
  ['operational context RPC exists', /FUNCTION get_my_operational_context/],
  ['products RLS enabled', /ALTER TABLE products ENABLE ROW LEVEL SECURITY/],
  ['balances RLS enabled', /ALTER TABLE inventory_balances ENABLE ROW LEVEL SECURITY/],
  ['movements RLS enabled', /ALTER TABLE inventory_movements ENABLE ROW LEVEL SECURITY/],
  ['application table privileges revoked before SELECT-only grant', /REVOKE ALL PRIVILEGES ON TABLE[\s\S]*inventory_movements[\s\S]*FROM anon, authenticated/],
  ['low-level mutation execute revoked', /REVOKE ALL ON FUNCTION public\.post_inventory_operation\([\s\S]*\) FROM PUBLIC, anon, authenticated/],
  ['authorized wrapper requires auth', /IF auth\.uid\(\) IS NULL THEN/],
  ['authorized wrapper derives actor', /v_actor := public\.current_profile_id\(\)/],
  ['authorized wrapper derives company from location', /SELECT l\.company_id, l\.is_active, l\.allow_direct_sales/],
  ['inactive locations rejected', /IF NOT v_location_active THEN/],
  ['direct-sales flag enforced', /IF NOT v_allow_direct_sales THEN/],
  ['warehouse permission enforced', /has_warehouse_permission\(v_location, v_permission\)/],
  ['JSON wrapper only granted to authenticated', /GRANT EXECUTE ON FUNCTION public\.post_inventory_operation\(JSONB\) TO authenticated/],
]
for (const [name, pattern] of requiredSql) pass(name, pattern.test(migration))

const sourceFiles = [
  'src/App.tsx',
  'src/components/inventory/ReceiveTransfer.tsx',
  'src/components/inventory/Dispatch.tsx',
  'src/components/inventory/CycleCount.tsx',
  'src/lib/syncEngine.ts',
].map(read).join('\n')
for (const id of [
  '11111111-1111-1111-1111-111111111111',
  '22222222-2222-2222-2222-222222222221',
  '33333333-3333-3333-3333-333333333331',
]) {
  pass(`production source does not contain demo authorization ID ${id.slice(0, 8)}`, !sourceFiles.includes(id))
}

const auth = read('src/lib/auth.tsx')
pass('frontend listens to Supabase auth state', auth.includes('supabase.auth.onAuthStateChange'))
pass('frontend loads server operational context', auth.includes('get_my_operational_context'))
pass('context selection is validated against memberships', auth.includes('companies.some') && auth.includes('warehouses.find'))
pass('logout clears tenant query cache', auth.includes('queryClient.clear()'))
pass('stale auth-context requests are invalidated on account switch', auth.includes('contextRequestId.current') && auth.includes('requestId !== contextRequestId.current'))

const main = read('src/main.tsx')
pass('application is auth gated', main.includes('<AuthProvider>') && main.includes('<AuthGate>'))
const authGate = read('src/components/auth/AuthGate.tsx')
pass('operational context controls are available on mobile', authGate.includes('<details className="fixed right-3 top-3 z-50">'))

const queries = read('src/lib/queries.ts')
pass('items query key includes company and warehouse', queries.includes("queryKey: ['items', activeCompanyId, activeLocationId]"))
pass('item query key includes company and warehouse', queries.includes("queryKey: ['item', activeCompanyId, activeLocationId, id]"))
pass('product reads are company scoped', queries.includes(".eq('company_id', activeCompanyId)"))
pass('balance reads are warehouse scoped', queries.includes(".eq('location_id', activeLocationId)"))

const sync = read('src/lib/syncEngine.ts')
pass('queue commands carry owner context', sync.includes('export type QueueOwner'))
pass('queue processor checks owner context', sync.includes('sameOwner(operation, owner)'))
pass('legacy demo queue seeding removed', !sync.includes('seedSyncOps'))
pass('sync payload does not trust company_id', !/company_id\s*:/.test(sync))
pass('sync payload does not trust user_id', !/user_id\s*:/.test(sync))
pass('unknown product no longer maps to LED demo ID', !sync.includes('44444444-4444-4444-4444-444444444441'))

const seed = read('supabase/seed.sql')
pass('seed creates company memberships before locations', seed.indexOf('INSERT INTO company_memberships') < seed.indexOf('INSERT INTO inventory_locations'))
pass('seed creates warehouse memberships', seed.includes('INSERT INTO warehouse_memberships'))

if (failures.length) {
  console.error(`\n${failures.length} Phase 1 verification check(s) failed.`)
  process.exit(1)
}
console.log('\nPhase 1 static security checks passed.')
