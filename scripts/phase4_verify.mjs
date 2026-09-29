import fs from 'node:fs'

const failures = []
const pass = (name, condition, detail = '') => {
  const suffix = detail ? ` - ${detail}` : ''
  if (condition) console.log(`PASS ${name}${suffix}`)
  else { console.error(`FAIL ${name}${suffix}`); failures.push(name) }
}
const read = (path) => fs.readFileSync(path, 'utf8')
const migrationPath = 'supabase/migrations/20260917200000_phase4_atomic_document_commands.sql'
pass('Phase 4 migration exists', fs.existsSync(migrationPath))
const migration = read(migrationPath)

const checks = [
  ['document command ledger exists', /CREATE TABLE inventory_document_commands/],
  ['UUID idempotency key unique per company', /UNIQUE \(company_id, client_command_id\)/],
  ['server canonical fingerprint exists', /FUNCTION phase4_command_fingerprint/],
  ['fingerprint is server-computed', /phase4_command_fingerprint\([\s\S]*p_command_type[\s\S]*p_document_id[\s\S]*p_expected_revision/],
  ['atomic first-submission insert uses ON CONFLICT', /INSERT INTO inventory_document_commands[\s\S]*ON CONFLICT \(company_id, client_command_id\) DO NOTHING/],
  ['same key different command is detected', /Idempotency key was already used for a different command/],
  ['transient result can retry same command identity', /v_existing\.status = 'TRANSIENT_ERROR'/],
  ['typed accepted duplicate conflict validation authorization transient contract', ['accepted','duplicate','conflict','validation_error','authorization_error','transient_error'].every((value) => migration.includes(`'${value}'`))],
  ['movement links to document command', /document_command_id UUID/],
  ['transfer tracks shipped quantity separately', /shipped_base_quantity NUMERIC/],
  ['transfer ship command exists', /FUNCTION public\.ship_transfer_document/],
  ['transfer receive command exists', /FUNCTION public\.receive_transfer_document/],
  ['sales dispatch command exists', /FUNCTION public\.dispatch_sales_order/],
  ['count finalize command exists', /FUNCTION public\.finalize_count_session/],
  ['transfer ship derives server delta', /expected_base_quantity - v_line\.shipped_base_quantity/],
  ['transfer receive derives server delta', /captured_received_base_quantity - v_line\.posted_base_quantity/],
  ['sales dispatch derives server delta', /captured_picked_base_quantity - v_line\.posted_base_quantity/],
  ['fresh command cannot reapply transfer quantity', /Transfer has no unposted captured receipt quantity/],
  ['sales finalization requires full accounting', /capture or backorder every line before dispatch/],
  ['dispatch protects other reservations', /Dispatch would consume inventory reserved for another order/],
  ['location-level reservations also protect stock', /r\.bin_id = v_line\.source_bin_id OR r\.bin_id IS NULL/],
  ['idempotency fingerprint binds client physical timestamp', /jsonb_build_object\('client_recorded_at', p_client_recorded_at\)/],
  ['sales reservation bin provenance fails closed', /Reservation bin does not match authoritative sales-order line/],
  ['command movement revalidates active source and destination bins', /Source warehouse\/bin is inactive or no longer valid[\s\S]*Destination warehouse\/bin is inactive or no longer valid/],
  ['dispatch fulfills own reservation', /fulfilled_base_qty = fulfilled_base_qty \+ v_take/],
  ['dispatch releases reservation remainder', /released_base_qty = released_base_qty \+ \(reserved_base_qty - fulfilled_base_qty - released_base_qty\)/],
  ['transfer ship creates authoritative transit', /INSERT INTO inventory_transit_lots/],
  ['transfer receipt consumes linked transit only', /No authoritative in-transit custody exists for transfer line/],
  ['transfer receipt rejects transit over-receipt', /Receipt exceeds authoritative in-transit quantity/],
  ['unsafe condition exception does not become AVAILABLE stock', /requires explicit disposition before stock posting/],
  ['count finalization requires resolved lines', /Count session contains unresolved or unapproved lines/],
  ['count finalization requires approved variance', /Count variance has not been approved/],
  ['count finalization revalidates physical snapshot', /Count physical snapshot changed after assignment/],
  ['count movement uses explicit variance in', /STOCK_COUNT_VARIANCE_IN/],
  ['count movement uses explicit variance out', /STOCK_COUNT_VARIANCE_OUT/],
  ['client physical timestamp reaches movement', /p_client_recorded_at/],
  ['movement carries authoritative line provenance', /p_transfer_line_id[\s\S]*p_sales_order_line_id[\s\S]*p_count_line_id/],
  ['generic document stock posting disabled', /Document workflow % must use the Phase 4 authoritative document command/],
  ['document command base table is select-only', /REVOKE ALL PRIVILEGES ON TABLE inventory_document_commands FROM anon, authenticated[\s\S]*GRANT SELECT/],
  ['internal Phase 4 helpers are not app callable', /REVOKE ALL ON FUNCTION public\.phase4_apply_document_movement[\s\S]*FROM PUBLIC, anon, authenticated/],
  ['command status lookup exists', /FUNCTION public\.get_document_command_result/],
  ['command audit RLS is actor scoped', /initiating_actor = public\.current_profile_id\(\)/],
  ['command status lookup is company scoped', /WHERE c\.company_id = p_company_id/],
]
for (const [name, check] of checks) pass(name, typeof check === 'boolean' ? check : check.test(migration))

const documents = read('src/lib/documents.ts')
pass('client parses typed command outcomes', documents.includes('DocumentCommandOutcome') && documents.includes('parseDocumentCommandResult'))
pass('client requires caller-provided stable command id', documents.includes('commandId: string') && !/dispatchSalesOrder[\s\S]{0,400}randomUUID\(\)/.test(documents))
pass('client has transfer ship command', documents.includes('shipTransferDocument'))
pass('client has transfer receive command', documents.includes('receiveTransferDocument'))
pass('client has sales dispatch command', documents.includes('dispatchSalesOrder'))
pass('client has count finalize command', documents.includes('finalizeCountSession'))
pass('transfer document exposes shipped progress', documents.includes('shippedBaseQuantity'))

const sync = read('src/lib/syncEngine.ts')
pass('legacy queue fails closed for receipt dispatch count',
  sync.includes('must use the authoritative Phase 4 document-command path') ||
  (!sync.includes('operation_type: \"RECEIVE\"') &&
   !sync.includes('operation_type: \"DISPATCH\"') &&
   !sync.includes('operation_type: \"COUNT\"') &&
   sync.includes('transfer_receive') && sync.includes('sales_dispatch') && sync.includes('count_finalize')))

pass('Phase 4 preflight exists', fs.existsSync('supabase/preflight/phase4_existing_data.sql'))
if (fs.existsSync('supabase/preflight/phase4_existing_data.sql')) {
  const preflight = read('supabase/preflight/phase4_existing_data.sql')
  pass('Phase 4 preflight checks reservation/bin provenance', preflight.includes('sales_reservation_bin_mismatch'))
}
pass('Phase 4 DB tests exist', fs.existsSync('supabase/tests/phase4_atomic_document_commands.sql'))
if (fs.existsSync('supabase/tests/phase4_atomic_document_commands.sql')) {
  const dbTests = read('supabase/tests/phase4_atomic_document_commands.sql')
  pass('Phase 4 pgTAP plan covers 36 assertions', dbTests.includes('plan(36)'))
  pass('Phase 4 pgTAP checks immutable command timestamp', dbTests.includes('cannot rewrite client physical-action timestamp'))
  pass('Phase 4 pgTAP checks contradictory reservation bin', dbTests.includes('reservation linked to the line but assigned to a contradictory bin'))
}
pass('Phase 4 handoff target contract exists', fs.existsSync('docs/remediation/PHASE4_HANDOFF.md') || fs.existsSync('docs/project/NEXT_PHASE_CONTRACT.md'))

if (failures.length) {
  console.error(`\n${failures.length} Phase 4 verification check(s) failed.`)
  process.exit(1)
}
console.log('\nPhase 4 static atomic-command checks passed.')
