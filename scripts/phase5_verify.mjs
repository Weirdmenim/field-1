import fs from 'node:fs'

const failures = []
const pass = (name, condition, detail = '') => {
  const suffix = detail ? ` - ${detail}` : ''
  if (condition) console.log(`PASS ${name}${suffix}`)
  else { console.error(`FAIL ${name}${suffix}`); failures.push(name) }
}
const read = (path) => fs.readFileSync(path, 'utf8')
const migrationPath = 'supabase/migrations/20260918090000_phase5_ledger_reversals.sql'
pass('Phase 5 migration exists', fs.existsSync(migrationPath))
const migration = read(migrationPath)

const checks = [
  ['ledger correction command table exists', /CREATE TABLE inventory_ledger_commands/],
  ['ledger command uses UUID client identity', /client_command_id UUID NOT NULL/],
  ['ledger command id unique per company', /UNIQUE \(company_id, client_command_id\)/],
  ['source movement relation is tenant safe', /inventory_ledger_commands_source_movement_fk[\s\S]*FOREIGN KEY \(company_id, source_movement_id\)/],
  ['reversal original relation is tenant and product safe', /inventory_movements_reversal_original_fk[\s\S]*FOREIGN KEY \(company_id, product_id, reversal_of_movement_id\)/],
  ['self reversal is forbidden', /inventory_movements_reversal_not_self/],
  ['movement history has append-only trigger', /CREATE TRIGGER inventory_movements_append_only_trigger[\s\S]*BEFORE UPDATE OR DELETE ON inventory_movements/],
  ['append-only guard fails explicit update delete', /inventory_movements is append-only/],
  ['reversal row requires ledger command provenance', /A reversal movement requires an authoritative ledger command/],
  ['reversal of reversal fails closed', /A reversal movement cannot itself be reversed/],
  ['document-linked generic reversal fails closed', /Document-linked movement requires a document-specific correction command/],
  ['reversal type is derived from original type', /FUNCTION public\.phase5_expected_reversal_type/],
  ['reversal shape exactly inverts original', /Outbound reversal must return stock to the exact original source position[\s\S]*Inbound reversal must remove stock from the exact original destination position[\s\S]*Internal\/status reversal must exactly invert/],
  ['downstream activity eligibility rule exists', /FUNCTION public\.phase5_has_downstream_activity/],
  ['downstream activity returns conflict', /Movement has downstream activity on an affected inventory position[\s\S]*ERRCODE = '40001'/],
  ['aggregate reversed quantity is calculated', /sum\(m\.base_quantity\)[\s\S]*reversal_of_movement_id = v_original\.id/],
  ['over reversal is rejected', /Requested reversal exceeds remaining reversible quantity/],
  ['original row is locked before reversal', /WHERE id = p_movement_id FOR UPDATE/],
  ['reversal source balance is locked', /FROM inventory_balances b[\s\S]*FOR UPDATE/],
  ['active reservations are locked', /inventory_reservations r[\s\S]*ORDER BY r\.id FOR UPDATE/],
  ['reversal cannot consume reserved inventory', /Reversal would consume inventory reserved for active work/],
  ['inactive source and destination positions fail closed', /Reversal source warehouse\/bin is inactive[\s\S]*Reversal destination warehouse\/bin is inactive/],
  ['reversal command fingerprint is server computed', /FUNCTION public\.phase5_reversal_fingerprint/],
  ['fingerprint binds physical timestamp', /'client_recorded_at', p_client_recorded_at/],
  ['first reversal command acquisition is atomic', /INSERT INTO inventory_ledger_commands[\s\S]*ON CONFLICT \(company_id, client_command_id\) DO NOTHING/],
  ['same key different reversal content fails closed', /IDEMPOTENCY_KEY_REUSED/],
  ['transient reversal outcome can retry same command identity', /v_existing\.status = 'TRANSIENT_ERROR'[\s\S]*SET status='PROCESSING'/],
  ['matching in-flight command reports processing', /'outcome','processing'/],
  ['accepted reversal appends new movement', /INSERT INTO inventory_movements/],
  ['accepted reversal never updates historical movement row', !/UPDATE\s+inventory_movements\s+SET/i.test(migration)],
  ['reversal operation carries authenticated actor', /v_actor,'COMPLETED'/],
  ['reversal movement links original and ledger command', /v_operation_id,v_server_command_id,v_original\.id/],
  ['full and partial state are explicit', /'reversal_status',CASE WHEN v_remaining=0 THEN 'FULL' ELSE 'PARTIAL' END/],
  ['typed reversal result lookup exists', /FUNCTION public\.get_ledger_command_result/],
  ['reversal eligibility API exists', /FUNCTION public\.get_movement_reversal_state/],
  ['ledger command audit RLS is actor scoped', /initiating_actor=public\.current_profile_id\(\)/],
  ['authenticated direct movement insert update delete truncate revoked', /REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON TABLE inventory_movements FROM PUBLIC, anon, authenticated/],
  ['service role direct movement write revoked when present', /REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON TABLE public\.inventory_movements FROM service_role/],
  ['internal reversal helpers are not app callable', /REVOKE ALL ON FUNCTION public\.phase5_begin_ledger_command[\s\S]*FROM PUBLIC, anon, authenticated/],
  ['public reversal command only granted authenticated', /GRANT EXECUTE ON FUNCTION public\.reverse_inventory_movement[\s\S]*TO authenticated/],
]
for (const [name, check] of checks) pass(name, typeof check === 'boolean' ? check : check.test(migration))

const ledger = read('src/lib/ledger.ts')
pass('client runtime parses reversal state', ledger.includes('Invalid reversal eligibility') && ledger.includes('parseReversalState'))
pass('client runtime parses reversal command result', ledger.includes('parseCommand') && ledger.includes('Invalid ledger command success field'))
pass('client requires stable caller-provided command id', ledger.includes('clientCommandId: string') && !ledger.includes('randomUUID'))
pass('client requires explicit physical timestamp', ledger.includes('clientRecordedAt: string'))
pass('client requires explicit reason', ledger.includes('reason: string'))

pass('Phase 5 preflight exists', fs.existsSync('supabase/preflight/phase5_existing_data.sql'))
pass('Phase 5 DB tests exist', fs.existsSync('supabase/tests/phase5_ledger_reversals.sql'))
if (fs.existsSync('supabase/tests/phase5_ledger_reversals.sql')) {
  const dbTests = read('supabase/tests/phase5_ledger_reversals.sql')
  const plan = dbTests.match(/SELECT plan\((\d+)\)/)?.[1]
  const assertionCount = (dbTests.match(/SELECT\s+(?:is|isnt|ok|throws_ok|lives_ok|has_table|has_function|col_type_is|has_trigger)\s*\(/g) ?? []).length
  pass('Phase 5 pgTAP plan matches authored assertions', Number(plan) === assertionCount, `${plan ?? 'none'} planned / ${assertionCount} found`)
  for (const phrase of [
    'partial reversal leaves authoritative remainder',
    'second partial reversal can complete the original quantity',
    'over reversal is rejected',
    'reversal of a reversal is rejected',
    'cross-tenant reversal is denied',
    'wrong-product reversal row is rejected',
    'downstream activity makes original ineligible',
    'document-linked movement requires document correction',
    'append-only trigger rejects UPDATE',
    'append-only trigger rejects DELETE',
  ]) pass(`pgTAP covers ${phrase}`, dbTests.includes(phrase))
}
pass('Phase 5 handoff/next phase contract exists', fs.existsSync('docs/project/NEXT_PHASE_CONTRACT.md'))

if (failures.length) {
  console.error(`\n${failures.length} Phase 5 verification check(s) failed.`)
  process.exit(1)
}
console.log('\nPhase 5 static ledger/reversal checks passed.')
