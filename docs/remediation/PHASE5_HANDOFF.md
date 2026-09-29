# Phase 5 Handoff

## Frozen implementation

Phase 5 implementation commit: `485a76d355b0e48fbeb370eee2272b05a8dda658`
Target tag after traceability freeze: `phase5-ledger-reversals-implemented`

### Phase 4 history recovery note

The delivered Phase 4 workspace and context artifacts were available, but a Phase 4 Git bundle was not among the supplied Phase 4 deliverables at Phase 5 restore time. Authentic Phase 0-3 history was restored from the Phase 3 bundle, and the exact delivered Phase 4 workspace tree was committed as recovery commit `131806f753468186588f198c767263c35d19b3b0`. The original Phase 4 implementation hash recorded by its handoff remains `8e8e74038fe6d9defc99a6036122135280fe6c8e`; the recovery commit must not be misrepresented as that unavailable original history.

## What Phase 5 made authoritative

- `inventory_movements` is database-enforced append-only after insertion.
- Ordinary application roles and service-role application access cannot directly INSERT/UPDATE/DELETE/TRUNCATE movement history.
- Eligible standalone movements are corrected only by `reverse_inventory_movement`.
- Reversal commands have company-scoped UUID identity, server-computed immutable fingerprint, authenticated actor, explicit reason, and durable typed outcome.
- The original movement is locked before reversible quantity is calculated.
- Full/partial reversal accounting is based on existing compensating movement quantity; aggregate reversal cannot exceed the original.
- A reversal row must point to the original through a company+product-safe relationship and to the authoritative Phase 5 ledger command.
- The compensating movement exactly inverts the original location/bin/status shape and uses an allowed inverse movement type.
- Reversal source stock, active warehouse/bin state, and reservations are revalidated under lock.
- Later non-reversal activity on an affected inventory position makes generic historical reversal ineligible.
- Reversal-of-reversal is prohibited.
- Phase 3/4 document-linked movements fail closed with `DOCUMENT_CORRECTION_REQUIRED`; generic reversal cannot desynchronize document/reservation/transit/count state.
- Exceptional repair has a written database-owner runbook; no standing admin bypass RPC was introduced.

## Non-negotiable invariants carried into Phase 6

1. Preserve every Phase 1 authentication/tenant/permission invariant.
2. Preserve every Phase 2 bin/UOM/status/reservation/transit/stock invariant.
3. Preserve every Phase 3 authoritative document/line/observation/approval invariant.
4. Preserve every Phase 4 atomic document-command/idempotency/delta/provenance invariant.
5. Posted movement history remains append-only; never repair history by UPDATE/DELETE.
6. Corrections append compensating movement history and retain authenticated actor, reason, original movement, and command provenance.
7. Partial/full reversal quantity is authoritative server state derived under an original-row lock.
8. Document-linked movements may not use the generic reversal command.
9. Direct movement table mutation remains unavailable to browser/application/service roles.
10. Historical provenance is never invented.

## Known work deliberately left open

- Document-specific correction commands for already-posted transfer, sales-order, and count movements.
- Conflict-resolution UI/commands that choose and execute a compensating action.
- Durable drafts and record-per-command offline outbox.
- Stable command-id creation/persistence at the moment the warehouse action is created locally.
- Startup drain, retry/backoff metadata, processing leases, crash recovery, causal ordering, and multi-tab/service-worker coordination.
- Truthful Sync Center/last-synced/task completion driven by durable server outcomes.
- Final retirement of legacy `inventory_operations.client_transaction_id` / `inventory_movements.client_transaction_id` TEXT compatibility identity.
- Real Supabase pgTAP execution and clean npm/typecheck/build gates.

## Phase 6 target

**Durable offline drafts/outbox, crash recovery, multi-context coordination, typed retry/conflict handling, and authoritative workflow cutover.**

Phase 6 should move command identity and workflow drafts out of transient React state into durable, versioned, user/company/warehouse-scoped storage. It must use record-per-command persistence, startup recovery, cross-tab single-writer coordination, durable retry/error metadata, causal ordering, and stable Phase 4/5 command ids. It must not reintroduce generic stock posting or bypass the Phase 5 append-only correction boundary.
