import fs from 'node:fs'

const failures=[]
const pass=(name,condition,detail='')=>{const suffix=detail?` - ${detail}`:''; if(condition) console.log(`PASS ${name}${suffix}`); else {console.error(`FAIL ${name}${suffix}`); failures.push(name)}}
const read=(p)=>fs.readFileSync(p,'utf8')
const migrationEnum='supabase/migrations/20260918205900_phase8_command_enum.sql'
const migrationPath='supabase/migrations/20260918210000_phase8_production_hardening.sql'
pass('Phase 8 enum migration exists',fs.existsSync(migrationEnum))
pass('Phase 8 production-hardening migration exists',fs.existsSync(migrationPath))
const migration=read(migrationPath)
const sync=read('src/lib/syncEngine.ts')
const hook=read('src/lib/useSyncEngine.ts')
const store=read('src/lib/offlineStore.ts')
const durable=read('src/lib/durableStorage.ts')
const reach=read('src/lib/reachability.ts')
const docs=read('src/lib/documents.ts')
const receive=read('src/components/inventory/ReceiveTransfer.tsx')
const syncCenter=read('src/components/inventory/SyncCenter.tsx')
const queries=read('src/lib/queries.ts')
const auth=read('src/lib/auth.tsx')
const pwa=read('src/lib/pwa.ts')
const sw=read('public/sw.js')
const html=read('index.html')
const css=read('src/index.css')
const data=read('src/components/inventory/data.ts')

for (const [name,condition] of [
  ['receipt disposition enum exists',/CREATE TYPE transfer_receipt_disposition_type/.test(migration)],
  ['receipt disposition table exists',/CREATE TABLE inventory_transfer_receipt_dispositions/.test(migration)],
  ['receipt disposition is immutable per transfer line',/UNIQUE \(company_id, transfer_line_id\)/.test(migration)],
  ['receipt disposition command is authoritative and idempotent',/FUNCTION public\.resolve_transfer_receipt_exception/.test(migration) && /phase4_begin_document_command/.test(migration)],
  ['receipt disposition requires explicit reason',/Disposition reason is required/.test(migration)],
  ['damaged receipt posts to damaged status',/destination_location_id, v_line\.destination_bin_id, NULL, 'DAMAGED'/.test(migration)],
  ['wrong and unexpected receipt never silently become available',/REJECT_WRONG_ITEM/.test(migration) && /REJECT_UNEXPECTED/.test(migration) && /v_rejected := v_line\.captured_received_base_quantity/.test(migration)],
  ['receipt finalization requires disposition for condition exception',/requires an authoritative disposition before stock posting/.test(migration)],
  ['receipt disposition is marked applied only with final command',/applied_document_command_id = v_server_command_id/.test(migration)],
  ['warehouse work does not count unresolved receipt exception as done',/l\.line_status = 'EXCEPTION'[\s\S]*rd\.id IS NOT NULL/.test(migration)],
  ['receipt UI separates capture-terminal from business-resolved',receive.includes('lineBusinessResolved') && receive.includes('Disposition needed')],
  ['receipt UI queues explicit disposition successor command',receive.includes('transfer_exception_disposition') && receive.includes('dispositionCommandId')],
  ['legacy generic JSON inventory posting is revoked',/REVOKE ALL ON FUNCTION public\.post_inventory_operation\(JSONB\) FROM PUBLIC, anon, authenticated/.test(migration)],
  ['legacy adjustment outbox kind removed',!sync.includes('legacy_adjustment') && !sync.includes('enqueueOperation(')],
  ['canonical operation transaction identity is UUID shaped',/inventory_operations_new_transaction_id_uuid/.test(migration) && /inventory_operations_canonical_transaction_identity_idx/.test(migration)],
  ['operation identity and server fingerprint are immutable',/guard_inventory_operation_identity_immutability/.test(migration) && /request_fingerprint IS DISTINCT FROM OLD\.request_fingerprint/.test(migration)],
  ['durable command ledgers replace inventory_operations failure semantics',/Internal successful-operation audit rows only/.test(migration)],
  ['cross-table reservation integrity is deferred',/CREATE CONSTRAINT TRIGGER inventory_reservation_integrity_reservation[\s\S]*DEFERRABLE INITIALLY DEFERRED/.test(migration)],
  ['reservation remainder cannot exceed non-negative available physical',/v_reserved > GREATEST\(v_available, 0\)/.test(migration)],
  ['backend reachability uses active Supabase probe',reach.includes('/auth/v1/health') && reach.includes('AbortController')],
  ['navigator.onLine is only a hint and not reachability authority',!reach.includes('navigator.onLine') && !hook.includes('if (navigator.onLine)')],
  ['sync processing requires successful backend probe',hook.includes('probeBackendReachability') && hook.includes('if (!reachable) return')],
  ['durable storage has structured health and retry',durable.includes('StorageHealth') && durable.includes('retryOnce') && durable.includes('DurableStorageError')],
  ['storage failure fails sync closed',hook.includes('!storageHealth.available') && hook.includes('checkOfflineStorageHealth')],
  ['storage recovery is periodically retried',hook.includes('5_000') && hook.includes('checkOfflineStorageHealth().then')],
  ['global UI surfaces durable storage failure',read('src/App.tsx').includes('Durable storage unavailable')],
  ['PWA manifest is linked',html.includes('manifest.webmanifest')],
  ['service worker app shell exists',fs.existsSync('public/sw.js') && sw.includes('fieldone-shell-v1') && sw.includes('request.mode === "navigate"')],
  ['service worker warms current same-origin build resources',pwa.includes('performance') && pwa.includes('CACHE_URLS') && sw.includes('CACHE_URLS')],
  ['cold offline auth context is cached per authenticated user',store.includes('OperationalContextV1') && auth.includes('saveOperationalContextSnapshot') && auth.includes('cached?.value.profile?.authUserId === nextSession.user.id')],
  ['offline snapshots are chosen before slow RPC timeout when backend unreachable',docs.includes('if (owner && !(await probeBackendReachability()))') && queries.includes('if (owner && !(await probeBackendReachability()))')],
  ['inventory list/item/bin/movement snapshots persist for cold offline use',store.includes('"inventory-items"') && store.includes('"inventory-item"') && store.includes('"item-bins"') && store.includes('"item-movements"')],
  ['remote product images removed from production data path',!queries.includes('unsplash') && data.includes('/product-placeholder.svg')],
  ['remote Google font dependency removed',!html.includes('fonts.googleapis') && !css.includes('fonts.googleapis') && css.includes('system-ui')],
  ['catalog reads paginate beyond API max rows',queries.includes('CATALOG_PAGE_SIZE') && queries.includes('.range(from, from + CATALOG_PAGE_SIZE - 1)')],
  ['identifier reads batch large product sets',queries.includes('IDENTIFIER_BATCH_SIZE') && queries.includes('productIds.slice')],
  ['conflict keep-local creates new stable successor identity',sync.includes('const successorId = crypto.randomUUID()') && sync.includes('authoritativeSnapshotFor')],
  ['conflict keep-local preserves old command as cancelled audit history',sync.includes('resolution: "rebased"') && sync.includes('state: "cancelled"')],
  ['conflict successor updates durable workflow command references',store.includes('replaceWorkflowCommandReference') && sync.includes('replaceWorkflowCommandReference(owner, operation.documentId, operation.id, successorId)')],
  ['Sync Center exposes explicit keep-local rebase action',syncCenter.includes('Keep my work as new revision')],
  ['local assets exist for product/avatar/icon',fs.existsSync('public/product-placeholder.svg') && fs.existsSync('public/avatar-placeholder.svg') && fs.existsSync('public/fieldone-icon.svg')],
  ['Phase 8 migration does not weaken direct ledger write revocations',!migration.includes('GRANT INSERT ON TABLE inventory_movements') && !migration.includes('GRANT UPDATE ON TABLE inventory_movements')],
  ['Phase 8 preflight exists',fs.existsSync('supabase/preflight/phase8_existing_data.sql')],
  ['Phase 8 DB tests exist',fs.existsSync('supabase/tests/phase8_production_hardening.sql')],
]) pass(name,condition)

if (fs.existsSync('supabase/tests/phase8_production_hardening.sql')) {
  const test=read('supabase/tests/phase8_production_hardening.sql')
  const planned=Number((test.match(/SELECT plan\((\d+)\)/)||[])[1]||0)
  const assertions=(test.match(/SELECT\s+(?:ok|is|isnt|like|unlike|throws_ok|lives_ok|has_table|has_function|has_index)\s*\(/g)||[]).length
  pass('Phase 8 pgTAP plan matches authored assertions',planned>0 && planned===assertions,`${planned} planned / ${assertions} found`)
}

if (failures.length) { console.error(`\n${failures.length} Phase 8 verification check(s) failed.`); process.exit(1) }
console.log('\nPhase 8 static production-hardening checks passed.')
