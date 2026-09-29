import fs from 'node:fs'

const failures=[]
const pass=(name,condition,detail='')=>{const suffix=detail?` - ${detail}`:''; if(condition) console.log(`PASS ${name}${suffix}`); else {console.error(`FAIL ${name}${suffix}`); failures.push(name)}}
const read=(p)=>fs.readFileSync(p,'utf8')
const migration=read('supabase/migrations/20260919090000_phase9_stock_revision_preconditions.sql')
const documents=read('src/lib/documents.ts')
const sync=read('src/lib/syncEngine.ts')
const dispatch=read('src/components/inventory/Dispatch.tsx')
const receive=read('src/components/inventory/ReceiveTransfer.tsx')
const count=read('src/components/inventory/CycleCount.tsx')

for (const [name,condition] of [
  ['stock-precondition ledger exists',migration.includes('CREATE TABLE IF NOT EXISTS inventory_document_command_stock_preconditions')],
  ['stock-precondition ledger is not app writable',migration.includes('REVOKE ALL ON inventory_document_command_stock_preconditions FROM PUBLIC, anon, authenticated')],
  ['physical balance mutation takes position lock',migration.includes('trg_phase9_balance_position_lock') && migration.includes("phase9_position_lock_key(OLD.company_id")],
  ['reservation mutation takes position lock',migration.includes('trg_phase9_reservation_position_lock') && migration.includes("OLD.bin_id IS NULL THEN 'LOCATION' ELSE 'BIN'")],
  ['trigger return handles DELETE explicitly',!migration.includes('RETURN COALESCE(NEW, OLD)') && migration.includes("IF TG_OP = 'DELETE' THEN\n    RETURN OLD;")],
  ['server exposes authoritative stock snapshot',migration.includes('phase9_get_document_stock_preconditions') && migration.includes("'physicalRevision'") && migration.includes("'binReservationRevision'") && migration.includes("'locationReservationRevision'")],
  ['server validates exact required position set',migration.includes('STOCK_PRECONDITION_SET_MISMATCH')],
  ['server returns typed stale-stock conflict',migration.includes('STOCK_REVISION_CONFLICT') && migration.includes("'outcome','conflict'")],
  ['stock preconditions are immutable per command id',migration.includes('precondition_fingerprint') && migration.includes('STOCK_PRECONDITION_IDEMPOTENCY_MISMATCH')],
  ['dispatch final command is revision protected',migration.includes('dispatch_sales_order_v2') && migration.includes("phase9_validate_stock_preconditions(v_doc.company_id,'SALES_DISPATCH'")],
  ['receipt final command is revision protected',migration.includes('receive_transfer_document_v2') && migration.includes("phase9_validate_stock_preconditions(v_doc.company_id,'TRANSFER_RECEIVE'")],
  ['transfer ship final command is revision protected',migration.includes('ship_transfer_document_v2') && migration.includes("phase9_validate_stock_preconditions(v_doc.company_id,'TRANSFER_SHIP'")],
  ['count finalization is revision protected',migration.includes('finalize_count_session_v2') && migration.includes("phase9_validate_stock_preconditions(v_doc.company_id,'COUNT_FINALIZE'")],
  ['legacy final stock RPCs are revoked from app role',migration.includes('REVOKE ALL ON FUNCTION public.dispatch_sales_order(UUID,BIGINT,UUID,TIMESTAMPTZ) FROM PUBLIC, anon, authenticated') && migration.includes('REVOKE ALL ON FUNCTION public.receive_transfer_document(UUID,BIGINT,UUID,BOOLEAN,TIMESTAMPTZ) FROM PUBLIC, anon, authenticated')],
  ['new v2 stock RPCs are authenticated entry points',migration.includes('GRANT EXECUTE ON FUNCTION public.dispatch_sales_order_v2') && migration.includes('GRANT EXECUTE ON FUNCTION public.receive_transfer_document_v2') && migration.includes('GRANT EXECUTE ON FUNCTION public.finalize_count_session_v2')],
  ['client document model carries stock preconditions',documents.includes('export type StockRevisionPrecondition') || documents.includes('export interface StockRevisionPrecondition') && documents.includes('stockPreconditions: StockRevisionPrecondition[]')],
  ['document fetch obtains authoritative stock snapshot',documents.includes('phase9_get_document_stock_preconditions') && documents.includes('fetchStockPreconditions("SALES_DISPATCH"') && documents.includes('fetchStockPreconditions("COUNT_FINALIZE"')],
  ['client uses v2 final stock RPCs',documents.includes('dispatch_sales_order_v2') && documents.includes('receive_transfer_document_v2') && documents.includes('finalize_count_session_v2')],
  ['outbox final commands require valid stock preconditions',sync.includes('validStockPreconditions') && sync.includes('stockPreconditions: StockRevisionPrecondition[]')],
  ['conflict rebase refreshes authoritative stock snapshot',sync.includes('authoritativeSnapshotFor') && sync.includes('payload.stockPreconditions = snapshot.stockPreconditions')],
  ['dispatch queues snapshot captured with business command',dispatch.includes('stockPreconditions: doc.stockPreconditions') && dispatch.includes('stockRevisionReady')],
  ['receive queues snapshot captured with business command',receive.includes('stockPreconditions: doc.stockPreconditions') && receive.includes('stockRevisionReady')],
  ['count queues snapshot captured with business command',count.includes('stockPreconditions: doc.stockPreconditions') && count.includes('stockRevisionReady')],
  ['Phase 9 preflight exists',fs.existsSync('supabase/preflight/phase9_existing_data.sql')],
  ['Phase 9 DB tests exist',fs.existsSync('supabase/tests/phase9_stock_revision_preconditions.sql')],
  ['Phase 9 DB runner executes cumulative Phase 1-9 suite',read('scripts/phase9_db_test.sh').includes('phase1_auth_rls.sql') && read('scripts/phase9_db_test.sh').includes('phase9_stock_revision_preconditions.sql')],
  ['database CI points at final Phase 9 suite',read('.github/workflows/database-tests.yml').includes('npm run phase9:db-test')],
]) pass(name,condition)

if (fs.existsSync('supabase/tests/phase9_stock_revision_preconditions.sql')) {
  const test=read('supabase/tests/phase9_stock_revision_preconditions.sql')
  const planned=Number((test.match(/SELECT plan\((\d+)\)/)||[])[1]||0)
  const assertions=(test.match(/SELECT\s+(?:ok|is|isnt|like|unlike|throws_ok|lives_ok|has_table|has_function|has_index)\s*\(/g)||[]).length
  pass('Phase 9 pgTAP plan matches authored assertions',planned>0 && planned===assertions,`${planned} planned / ${assertions} found`)
}

if (failures.length) { console.error(`\n${failures.length} Phase 9 verification check(s) failed.`); process.exit(1) }
console.log('\nPhase 9 stock-revision precondition checks passed.')
