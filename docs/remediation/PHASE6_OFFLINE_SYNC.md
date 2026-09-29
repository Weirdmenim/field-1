# Phase 6 - Durable Offline Workflows, Outbox Recovery, and Authoritative Workflow Cutover

## Objective

Phase 6 replaces transient React workflow state and the legacy whole-array LocalForage queue with durable, owner-scoped workflow drafts and a record-per-command outbox. Receive, Dispatch, and Cycle Count now execute against the Phase 3 authoritative documents and the Phase 4 stable command APIs while preserving every Phase 1-5 trust, stock, document, idempotency, and ledger invariant.

## Core rules

1. Offline work is durable before the UI claims it is saved/queued.
2. Workflow drafts and command records are scoped by authenticated user + company + warehouse.
3. Ownerless/legacy queue records are quarantined and never silently reassigned or auto-submitted.
4. The outbox is record-per-command, schema-versioned, runtime-validated, and malformed records are quarantined.
5. Stable command UUIDs are created when the local business action is created and reused across retries.
6. Commands may declare causal dependencies; successors do not overtake unresolved prerequisites.
7. Processing uses leases with stale-claim recovery. A crash cannot make `syncing` permanent.
8. Cross-context processing prefers Web Locks and uses an atomic IndexedDB lease fallback with renewal.
9. Retry count, typed last error, next-attempt timestamp, exponential backoff, and jitter are durable.
10. Conflict is blocked from normal retry and remains durable for operator resolution.
11. Backend timeouts use abort signals and return commands to the transient retry lifecycle.
12. Sync success invalidates authoritative inventory, document, bin, movement, and warehouse-work caches.
13. Sync Center is derived from durable command state and never fabricates server revisions, quantities, users, or success.
14. Last-confirmed/freshness timestamps come from persisted confirmation state, never hard-coded text.
15. Receive/Dispatch/Count no longer post document stock through the legacy generic inventory queue.
16. Receive and Dispatch use authoritative document lines and stable Phase 4 final commands.
17. Count uses authoritative blind observations; explicit zero requires operator interaction and variance reason is finalized before approval.
18. The small Phase 6 database migration supports blind-count reason completion only; it does not mutate stock.
19. Phase 5 movement history remains append-only; offline conflict/retry logic never edits ledger history.
20. Production scanner simulation remains development-only; a real camera/hardware acquisition path is deliberately not claimed in Phase 6.

## Durable stores

Phase 6 introduces independent durable stores for:

- workflow drafts (`WorkflowDraftsV1`);
- server snapshots (`ServerSnapshotsV1`);
- sync freshness (`SyncFreshnessV1`);
- record-per-command outbox (`OutboxV2`);
- legacy/malformed quarantine (`LegacyQuarantineV1`).

Drafts preserve entered quantities, reasons/notes, local workflow state, authoritative document revision, stable final command id, and owner scope across remount/reload. Server snapshots are separate from drafts and from executable commands.

## Outbox lifecycle

Executable states are:

`queued -> syncing -> confirmed`

with durable terminal/blocked alternatives:

`failed | conflict | blocked | cancelled`

Transient failures update attempt count, typed last error, and next-attempt time. Validation/authorization/conflict outcomes do not blindly retry. Dependency failure/conflict/cancellation prevents causally dependent work from overtaking the prerequisite.

## Crash and multi-context recovery

Each claimed command stores lease ownership/expiry. Startup processing recovers stale claims back to a safe queued state with the same command identity. Cross-tab/window execution uses Web Locks where available. The fallback lock is a native IndexedDB read/write transaction with heartbeat renewal so two contexts cannot safely claim the same processing lease through a non-atomic LocalForage read/write race.

## Authoritative workflow cutover

### Receive

Receive loads Phase 3 transfer documents, persists line work durably, queues authoritative line-capture commands, and queues the stable Phase 4 transfer-receive command only when required lines are accounted for. Completed/terminal lines are not normally editable.

### Dispatch

Dispatch loads authoritative sales-order documents, captures picked outcomes durably, persists authoritative backorder commands, enforces requested quantity locally for usability, and queues the stable Phase 4 sales-dispatch command only when the local/server line state is accounted for. Server-side Phase 4 validation remains final authority.

### Cycle Count

Count uses authoritative sessions and blind observations. The UI tracks explicit operator interaction so untouched default zero is not submitted. A temporary `PENDING_REASON` sentinel can preserve a blind variance observation without revealing expected stock before submission, but database approval is blocked until the actual discrepancy reason is recorded.

## Sync truth

`All synced` is true only when there are no active pending/syncing/failed/conflict/blocked commands in the current owner context. Confirmed time is persisted from real command confirmation. Conflict presentation comes from stored typed server/local result data. Accepting server state cancels/preserves the local command as audit history rather than deleting it.

## Implementation assets

- Durable storage: `src/lib/offlineStore.ts`
- Outbox processor: `src/lib/syncEngine.ts`
- Sync hook: `src/lib/useSyncEngine.ts`
- Durable draft hook: `src/lib/useDurableWorkflowDraft.ts`
- Authoritative RPC client/timeouts: `src/lib/documents.ts`
- Phase 6 migration: `supabase/migrations/20260918130000_phase6_offline_workflow_support.sql`
- Preflight: `supabase/preflight/phase6_existing_data.sql`
- pgTAP: `supabase/tests/phase6_offline_workflow_support.sql`
- Static verifier: `scripts/phase6_verify.mjs`
- DB runner: `scripts/phase6_db_test.sh`

## Deliberately open after Phase 6

Phase 6 does not claim completion of the production scanner/barcode model, duplicate-line/bin disambiguation, durable unknown-scan reporting, PWA application shell/cold-offline boot, exhaustive storage-failure UX, real browser multi-tab/restart execution tests, compensating `keep mine` conflict commands, legacy operation-id retirement, or product-catalog pagination.

## Verification boundary

Dependency-free repository verification and targeted semantic checks pass. Final VERIFIED/CLOSED status still requires real Supabase/PostgreSQL execution, clean dependency installation, full TypeScript compilation, production Vite build, and browser/device concurrency/offline execution where applicable.
