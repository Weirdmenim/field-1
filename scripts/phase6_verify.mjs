import fs from 'node:fs'

const failures=[]
const pass=(name,condition,detail='')=>{const suffix=detail?` - ${detail}`:'';if(condition)console.log(`PASS ${name}${suffix}`);else{console.error(`FAIL ${name}${suffix}`);failures.push(name)}}
const read=(path)=>fs.readFileSync(path,'utf8')

const sync=read('src/lib/syncEngine.ts')
const hook=read('src/lib/useSyncEngine.ts')
const store=read('src/lib/offlineStore.ts')
const draft=read('src/lib/useDurableWorkflowDraft.ts')
const docs=read('src/lib/documents.ts')
const app=read('src/App.tsx')
const home=read('src/components/inventory/InventoryHome.tsx')
const work=read('src/components/inventory/Work.tsx')
const receive=read('src/components/inventory/ReceiveTransfer.tsx')
const dispatch=read('src/components/inventory/Dispatch.tsx')
const count=read('src/components/inventory/CycleCount.tsx')
const scan=read('src/components/inventory/Scan.tsx')
const center=read('src/components/inventory/SyncCenter.tsx')
const migrationPath='supabase/migrations/20260918130000_phase6_offline_workflow_support.sql'
pass('Phase 6 migration exists',fs.existsSync(migrationPath))
const migration=read(migrationPath)

for (const [name,condition] of [
  ['outbox is record per command',sync.includes('storeName: "OutboxV2"') && sync.includes('storageSet(outbox, operation.id, operation)')],
  ['whole-array queue write path removed',!sync.includes('saveQueue(') && !sync.includes('queue.push(newOperation)')],
  ['outbox schema is versioned',sync.includes('schemaVersion: 2')],
  ['persisted outbox records are runtime validated',sync.includes('parseOutboxRecord') && sync.includes('validPayload') && sync.includes('quarantineInvalidV2')],
  ['malformed V2 outbox records are quarantined, not executed',sync.includes('Malformed or incompatible OutboxV2 record failed runtime validation') && sync.includes('storageRemove(outbox, key)')],
  ['outbox owner includes user company warehouse',sync.includes('authUserId') && sync.includes('companyId') && sync.includes('locationId') && sync.includes('sameOwner')],
  ['legacy whole-array records are quarantined',sync.includes('LegacyQuarantineV1') && sync.includes('cannot prove authoritative document-command identity')],
  ['legacy queue is never auto submitted',sync.includes('never auto-submitted') && sync.includes('storageRemove(legacyQueueStore, LEGACY_QUEUE_KEY)')],
  ['stable outbox id is caller supplied',sync.includes('id: string') && sync.includes('Outbox command id must be a stable UUID')],
  ['causal dependencies are durable',sync.includes('dependencyIds: string[]') && sync.includes('DEPENDENCY_BLOCKED')],
  ['attempt count persisted',sync.includes('attemptCount: number') && sync.includes('attemptCount: current.attemptCount + 1')],
  ['next attempt persisted',sync.includes('nextAttemptAt: string | null')],
  ['typed last error persisted',sync.includes('lastError: OutboxLastError | null') && sync.includes('OutboxErrorKind')],
  ['processing lease persisted',sync.includes('leaseOwner: string | null') && sync.includes('leaseExpiresAt: string | null')],
  ['stale syncing records recover after lease expiry',sync.includes('recoverStaleClaims') && sync.includes('STALE_LEASE')],
  ['cross tab coordination uses Web Locks',sync.includes('navigator') && sync.includes('locks.request') && sync.includes('fieldone-outbox:')],
  ['durable fallback owner lease exists',sync.includes('processWithDurableLease') && sync.includes('owner-lease:')],
  ['fallback lease acquisition is atomic in IndexedDB transaction',sync.includes('indexedDB.open(LEASE_DB_NAME') && sync.includes('db.transaction(LEASE_STORE_NAME, "readwrite")') && sync.includes('acquireDurableLease')],
  ['fallback lease is renewed while processing',sync.includes('renewDurableLease') && sync.includes('setInterval') && sync.includes('releaseDurableLease')],
  ['BroadcastChannel notifies other contexts',sync.includes('BroadcastChannel("fieldone-outbox-v2")') && sync.includes('subscribeOutbox')],
  ['retry uses exponential backoff and jitter',sync.includes('2 ** exponent') && sync.includes('Math.random()') && sync.includes('MAX_RETRY_DELAY_MS')],
  ['conflict cannot blind retry',sync.includes('Conflict commands require explicit reconciliation')],
  ['accept server preserves cancelled command record',sync.includes('state: "cancelled"') && sync.includes('acceptServerVersion')],
  ['server command result reconciles stable id',sync.includes('getDocumentCommandResult') && sync.includes('reconcileDocumentCommand')],
  ['ambiguous line capture reconciles against authoritative document',sync.includes('reconcileCapture') && sync.includes('fetchTransferDocument') && sync.includes('fetchSalesOrderDocument') && sync.includes('fetchCountSessionDocument')],
  ['generic document stock posting remains absent from outbox kinds',!sync.includes('operation_type: "RECEIPT"') && !sync.includes('operation_type: "DISPATCH"') && !sync.includes('operation_type: "COUNT"')],
  ['last confirmed timestamp is persisted',sync.includes('setLastConfirmedAt') && store.includes('SyncFreshnessV1')],
  ['sync starts on cold startup after durable storage check and reachability probe',hook.includes('checkOfflineStorageHealth()') && hook.includes('loadQueue().then(() => void runSync())')],
  ['sync hook no longer exposes manual online toggle',!hook.includes('toggleOnline') && !app.includes('toggleOnline')],
  ['sync hook listens cross context',hook.includes('subscribeOutbox')],
  ['authoritative RPCs use abortable timeouts',docs.includes('RPC_TIMEOUT_MS') && docs.includes('.abortSignal(controller.signal)')],
  ['legacy adjustment RPC is retired or uses abortable timeout',!sync.includes('legacyAdjustmentRpc') || sync.includes('.abortSignal(controller.signal)')],
  ['confirmed sync invalidates movement and bin caches',hook.includes('item-bins') && hook.includes('item-movements')],
  ['authoritative query snapshots persist for offline reload',docs.includes('snapshotFallback') && store.includes('ServerSnapshotsV1')],
  ['workflow drafts persist separately',store.includes('WorkflowDraftsV1') && draft.includes('saveWorkflowDraft')],
  ['draft server revision can advance without discarding local state',draft.includes('input.serverRevision <= currentRef.current.revision')],
  ['Home uses authoritative work',app.includes('useWarehouseWork') && home.includes('nav.workItems')],
  ['Work uses authoritative work',work.includes('nav.workItems') && !work.includes('tasks.filter')],
  ['Receive uses authoritative transfer document',receive.includes('useTransferDocument') && receive.includes('transfer_line_capture') && receive.includes('transfer_receive')],
  ['Dispatch uses authoritative sales order',dispatch.includes('useSalesOrderDocument') && dispatch.includes('sales_line_capture') && dispatch.includes('sales_dispatch')],
  ['Dispatch creates durable backorder command',dispatch.includes('sales_backorder')],
  ['Count uses authoritative session',count.includes('useCountSessionDocument') && count.includes('count_observation') && count.includes('count_finalize')],
  ['Count requires explicit touched/confirmed zero',count.includes('touched') && count.includes('Enter or confirm a count first')],
  ['blind count uses pending reason sentinel until server reveals variance',count.includes('PENDING_REASON') && migration.includes('PENDING_REASON')],
  ['variance reason follow-up exists',sync.includes('count_variance_reason') && migration.includes('set_count_variance_reason')],
  ['approval cannot bypass final reason',migration.includes('phase6_require_final_count_reason') && migration.includes('Count variance requires a final operator reason before approval')],
  ['Phase 6 migration does not mutate stock balances',!/UPDATE\s+inventory_balances/i.test(migration) && !/INSERT\s+INTO\s+inventory_movements/i.test(migration)],
  ['scanner resolves authoritative document lines',scan.includes('useTransferDocument') && scan.includes('useSalesOrderDocument')],
  ['production scanner simulation cannot appear in production success path',(!scan.includes('DEV simulate') && !scan.includes('simulate')) || (scan.includes('import.meta.env.DEV') && scan.includes('DEV simulate'))],
  ['Home has no hard coded last synced clock',!home.includes('Last synced 08:14')],
  ['Sync Center all-synced requires zero active commands',center.includes('pending === 0') && center.includes('fullySynced')],
  ['Sync Center uses real persisted freshness',center.includes('nav.lastConfirmedAt')],
  ['Sync Center no longer fabricates server quantity/revision/user',!center.includes('serverMag') && !center.includes('Updated by S. Okafor') && !center.includes('transactions.find')],
  ['conflict keep-server action preserves audit state',center.includes('acceptServerVersion') && sync.includes('state: "cancelled"')],
  ['Receive fixture document source removed',!receive.includes('nav.docs') && !receive.includes('transferDocs')],
  ['Dispatch fixture document source removed',!dispatch.includes('nav.docs') && !dispatch.includes('orderDocs')],
  ['Count fixture document source removed',!count.includes('nav.docs') && !count.includes('countDocs')],
]) pass(name,condition)

pass('Phase 6 preflight exists',fs.existsSync('supabase/preflight/phase6_existing_data.sql'))
pass('Phase 6 DB tests exist',fs.existsSync('supabase/tests/phase6_offline_workflow_support.sql'))
if(fs.existsSync('supabase/tests/phase6_offline_workflow_support.sql')){
  const tests=read('supabase/tests/phase6_offline_workflow_support.sql')
  const plan=Number(tests.match(/SELECT plan\((\d+)\)/)?.[1]??0)
  const assertions=(tests.match(/SELECT\s+(?:is|isnt|ok|throws_ok|lives_ok|has_function|has_trigger)\s*\(/g)??[]).length
  pass('Phase 6 pgTAP plan matches assertions',plan===assertions,`${plan} planned / ${assertions} found`)
}

if(failures.length){console.error(`\n${failures.length} Phase 6 verification check(s) failed.`);process.exit(1)}
console.log('\nPhase 6 static offline/outbox/workflow checks passed.')
