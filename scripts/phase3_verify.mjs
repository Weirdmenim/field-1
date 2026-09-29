import fs from 'node:fs'

const failures = []
const pass = (name, condition, detail = '') => {
  const suffix = detail ? ` - ${detail}` : ''
  if (condition) console.log(`PASS ${name}${suffix}`)
  else { console.error(`FAIL ${name}${suffix}`); failures.push(name) }
}
const read = (path) => fs.readFileSync(path, 'utf8')
const migrationPath = 'supabase/migrations/20260917160000_phase3_authoritative_documents.sql'
pass('Phase 3 migration exists', fs.existsSync(migrationPath))
const migration = read(migrationPath)

const sqlChecks = [
  ['transfer documents exist', /CREATE TABLE inventory_transfer_documents/],
  ['transfer lines exist', /CREATE TABLE inventory_transfer_lines/],
  ['sales orders exist', /CREATE TABLE inventory_sales_orders/],
  ['sales-order lines exist', /CREATE TABLE inventory_sales_order_lines/],
  ['count sessions exist', /CREATE TABLE inventory_count_sessions/],
  ['count lines exist', /CREATE TABLE inventory_count_lines/],
  ['count observations exist', /CREATE TABLE inventory_count_observations/],
  ['count approvals exist', /CREATE TABLE inventory_count_approvals/],
  ['backorders exist', /CREATE TABLE inventory_backorders/],
  ['transfer stable tenant line identity', /UNIQUE \(company_id, transfer_id, line_number\)/],
  ['sales-order stable tenant line identity', /UNIQUE \(company_id, sales_order_id, line_number\)/],
  ['count stable tenant line identity', /UNIQUE \(company_id, count_session_id, line_number\)/],
  ['document revisions exist', /revision BIGINT NOT NULL DEFAULT 1 CHECK \(revision > 0\)/],
  ['transfer remaining quantity is server derived', /remaining_expected_base_quantity[\s\S]*GENERATED ALWAYS AS \(GREATEST\(expected_base_quantity - posted_base_quantity, 0\)\)/],
  ['sales remaining quantity is server derived', /remaining_base_quantity[\s\S]*GENERATED ALWAYS AS \(GREATEST\(requested_base_quantity - posted_base_quantity - backordered_base_quantity, 0\)\)/],
  ['sales over-pick constrained', /inventory_sales_order_capture_within_requested/],
  ['captured transfer quantity cannot post beyond capture', /inventory_transfer_line_posted_within_capture/],
  ['count observation stores expected snapshot', /expected_snapshot_base_quantity NUMERIC\(28, 6\) NOT NULL/],
  ['count observation stores client physical action time', /client_recorded_at TIMESTAMPTZ NOT NULL/],
  ['count approval decision is durable', /decision count_approval_decision NOT NULL/],
  ['reservation has authoritative sales-order line link', /inventory_reservations[\s\S]*ADD COLUMN IF NOT EXISTS sales_order_line_id UUID/],
  ['transit has authoritative transfer-line link', /inventory_transit_lots[\s\S]*ADD COLUMN IF NOT EXISTS transfer_line_id UUID/],
  ['movements have authoritative line link columns', /ADD COLUMN IF NOT EXISTS transfer_line_id UUID,[\s\S]*sales_order_line_id UUID,[\s\S]*count_line_id UUID/],
  ['record transfer capture command exists', /FUNCTION public\.record_transfer_receipt_line/],
  ['captured transfer lines are immutable', /Transfer line is already captured and immutable/],
  ['record sales pick command exists', /FUNCTION public\.record_sales_order_pick_line/],
  ['server rejects picked quantity above request', /Picked quantity exceeds authoritative requested quantity/],
  ['backorder command exists', /FUNCTION public\.create_sales_order_backorder/],
  ['backorder cannot exceed request', /Backorder would exceed authoritative remaining requested quantity/],
  ['count observation command exists', /FUNCTION public\.record_count_observation/],
  ['zero count is allowed explicitly', /p_observed_entered_quantity < 0/],
  ['variance requires structured reason', /Variance reason is required/],
  ['count approval command exists', /FUNCTION public\.decide_count_variance/],
  ['count approval permission enforced', /inventory\.count\.approve/],
  ['optimistic document revision conflict enforced', /Document revision conflict/],
  ['count session revision conflict enforced', /Count session revision conflict/],
  ['authoritative work list RPC exists', /FUNCTION public\.list_my_warehouse_work/],
  ['transfer read RPC exists', /FUNCTION public\.get_transfer_document/],
  ['sales-order read RPC exists', /FUNCTION public\.get_sales_order_document/],
  ['count read RPC exists', /FUNCTION public\.get_count_session_document/],
  ['blind count expected is hidden until observation', /CASE WHEN v_can_approve OR obs\.id IS NOT NULL THEN l\.expected_snapshot_base_quantity ELSE NULL END/],
  ['document tables have RLS', /ALTER TABLE inventory_transfer_documents ENABLE ROW LEVEL SECURITY[\s\S]*ALTER TABLE inventory_count_approvals ENABLE ROW LEVEL SECURITY/],
  ['document base tables are not directly exposed', /REVOKE ALL PRIVILEGES ON TABLE[\s\S]*inventory_count_approvals[\s\S]*FROM PUBLIC, anon, authenticated/],
  ['capture commands granted only to authenticated', /GRANT EXECUTE ON FUNCTION public\.record_transfer_receipt_line[\s\S]*TO authenticated/],
]
for (const [name, pattern] of sqlChecks) pass(name, pattern.test(migration))

pass('Phase 3 document capture does not mutate balances', !/UPDATE\s+inventory_balances/i.test(migration))
pass('Phase 3 document capture does not append movement rows', !/INSERT\s+INTO\s+inventory_movements/i.test(migration))

const docs = read('src/lib/documents.ts')
pass('client reads authoritative work through RPC', docs.includes('list_my_warehouse_work'))
pass('client reads authoritative transfer through RPC', docs.includes('get_transfer_document'))
pass('client reads authoritative sales order through RPC', docs.includes('get_sales_order_document'))
pass('client reads authoritative count through RPC', docs.includes('get_count_session_document'))
pass('document RPC responses are runtime parsed', docs.includes('Invalid authoritative document response') && docs.includes('parseCountSession'))
pass('document query keys include tenant/location context', docs.includes('["warehouse-work", activeCompanyId, activeLocationId]'))

const auth = read('src/lib/auth.tsx')
for (const key of ['warehouse-work', 'transfer-document', 'sales-order-document', 'count-session-document']) {
  pass(`context switch clears ${key} cache`, auth.includes(`"${key}"`))
}

const seed = read('supabase/seed.sql')
pass('seed contains authoritative transfers', seed.includes("'TR-00291'") && seed.includes('INSERT INTO inventory_transfer_documents'))
pass('seed contains authoritative sales orders', seed.includes("'SO-18420'") && seed.includes('INSERT INTO inventory_sales_orders'))
pass('seed contains authoritative count sessions', seed.includes("'CC-0093'") && seed.includes('INSERT INTO inventory_count_sessions'))
pass('count seed derives expected quantity from balances', seed.includes('COALESCE(sum(on_hand_base_qty),0)'))
pass('seed links reservations to order lines', seed.includes('sales_order_line_id ='))
pass('seed links transit to transfer lines', seed.includes('transfer_line_id ='))

pass('Phase 3 preflight exists', fs.existsSync('supabase/preflight/phase3_existing_data.sql'))
pass('Phase 3 DB tests exist', fs.existsSync('supabase/tests/phase3_authoritative_documents.sql'))
pass('Phase 3 handoff target contract exists', fs.existsSync('docs/project/NEXT_PHASE_CONTRACT.md'))

if (failures.length) {
  console.error(`\n${failures.length} Phase 3 verification check(s) failed.`)
  process.exit(1)
}
console.log('\nPhase 3 static authoritative-document checks passed.')
