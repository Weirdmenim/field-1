# Phase 3 Handoff - Context for Phase 4

## Branch lineage

- Immutable reviewed baseline: `pre-inventory-remediation`
- Phase 1 trust-boundary tag: `phase1-authz-implemented`
- Phase 2 canonical-inventory tag: `phase2-inventory-model-implemented`
- Phase 3 branch: `phase3-authoritative-documents`
- Phase 3 implementation commit: `6226de9d2abc15110c40efa8f8088fb596cc29b6`

The Phase 3 traceability tag is created only after this handoff, the matrix, and project-state files are committed. Continue Phase 4 from that tag/head, never from an earlier workspace ZIP.

## Durable context system

The repository, not chat history, is the project memory. Read these before Phase 4 work:

1. `docs/project/PROJECT_STATE.json`
2. `docs/project/INVARIANTS.md`
3. `docs/project/DECISION_LOG.md`
4. `docs/project/PHASE_JOURNAL.md`
5. `docs/project/VERIFICATION_LEDGER.md`
6. `docs/project/NEXT_PHASE_CONTRACT.md`
7. `docs/remediation/REMEDIATION_MATRIX.csv`
8. `docs/remediation/PHASE3_AUTHORITATIVE_DOCUMENTS.md`
9. this handoff

Run `npm run context:verify` before substantive changes.

## Phase 1 invariants remain mandatory

- Actor/company authority derives from `auth.uid()` + server memberships.
- Client `user_id`/`company_id` never authorize a write.
- Warehouse selection is requested context, not authorization.
- Application roles cannot directly mutate balance/operation/movement tables.
- Tenant-safe relationships and tenant/location-aware client caches remain mandatory.
- Offline work ownership remains authenticated user + company + warehouse; ownerless legacy commands remain quarantined.

## Phase 2 invariants remain mandatory

- Balance key = company + location + bin + product + inventory status.
- Physical on-hand is status-bucket physical stock; reservations and transit are separate first-class state.
- ATP = AVAILABLE physical - remaining active reservation quantity.
- UOM conversion/scale/step and ownership are server-authoritative.
- Negative stock is allowed only according to the authoritative location policy.
- Canonical reads use Phase 2 stock views; production must not fall back to fixture stock.
- SYSTEM bins and LEGACY_BALANCE reservations are preserved compatibility artifacts.
- Generic COUNT, ambiguous ADJUSTMENT, undefined reversal, and old low-level mutation semantics remain fail-closed where already disabled.

## Phase 3 authoritative document invariants

1. Transfers, sales orders, count sessions, count observations/approvals and backorders are server-authoritative entities.
2. Every authoritative document/line has stable UUID identity and revision state.
3. Captured transfer/sales lines cannot be silently edited after capture through the normal command path.
4. Sales captured + backordered quantity cannot exceed requested quantity.
5. Remaining quantities are server-derived fields, not client arithmetic.
6. Count observations preserve expected snapshot + physical revision and allow explicit zero observations.
7. Count approval/reject/recount is a durable permission-gated state machine.
8. Blind count expected values remain hidden through application-facing RPCs until policy permits disclosure.
9. Reservations/transit can reference authoritative sales/transfer lines; future movements have explicit authoritative-line provenance columns.
10. Phase 3 document commands record workflow state only. They do **not** mutate balances or append movement rows.

## Data-preservation decisions

- Do not invent provenance for historical reservation/transit/movement rows.
- A Phase 2 transit row that does not truthfully match the reviewed transfer lines remains unlinked and must be reconciled rather than rewritten to a convenient document.
- Existing compatibility stock/reservation/history remains preserved until reconciliation proves retirement safe.
- Existing document fixtures may remain temporarily for UI compatibility, but must never become server authority.

## Findings implemented in Phase 3

Phase 3 moves these findings to `IMPLEMENTED`:

- F-083 - authoritative transfer persistence
- F-084 - authoritative sales order/dispatch persistence
- F-085 - authoritative count-session persistence
- F-086 - durable count-approval workflow
- F-087 - authoritative backorder entity/workflow

They are not `VERIFIED` or `CLOSED` until pgTAP and clean full build/typecheck gates run in a suitable environment.

## Important partial findings that remain OPEN

- F-001/F-002 - count observation/approval exists, but approved variance is not yet applied atomically to stock and legacy UI is not cut over.
- F-006 - reservation provenance exists, but final dispatch does not fulfill/release it atomically.
- F-015 - transit provenance exists, but transfer ship/receipt custody commands do not yet mutate transit/on-hand.
- F-021/F-158 - document capture enforces request bounds, but stock mutation must enforce them again under locks.
- F-088/F-089 - capture RPCs validate docs/lines; final stock command path is not yet bound to them.
- F-090/F-091/F-092 - provenance/timestamps are modeled but not yet populated by the final movement command.
- F-122/F-123 - authoritative/revisioned blind count model exists; legacy UI/session creation still needs cutover.
- F-160/F-161/F-162/F-163/F-164 - server lifecycle is improved but legacy local workflow/sync presentation remains.
- F-183 - posted/remaining quantities are modeled; cumulative repost prevention becomes real only when Phase 4 computes deltas under lock.

## Phase 4 objective - atomic document commands

Replace the line-oriented compatibility stock path with business commands that atomically consume Phase 3 documents and Phase 2 stock state.

Each command must:

1. authenticate actor from server session;
2. authorize company/warehouse/action;
3. atomically acquire a stable document-level idempotency record;
4. compute a canonical server-side fingerprint;
5. lock document + relevant lines;
6. validate expected document/line revisions and lifecycle states;
7. derive the unposted delta from authoritative posted/remaining quantities;
8. validate bins/UOM/status and server-convert entered quantities;
9. lock relevant stock/reservation/transit rows;
10. enforce authoritative availability/negative-stock/document remaining policy;
11. apply all document lines in one database transaction;
12. append movements with authoritative document-line provenance and client physical-action time;
13. update reservations/transit/count state as part of the same transaction;
14. advance document/line posted/remaining/lifecycle state;
15. return a typed result: accepted, duplicate, conflict, validation_error, authorization_error, or transient_error.

## Command-specific Phase 4 requirements

### Receive transfer
- Do not repost already-posted captured quantity.
- Represent accepted quantity separately from shortage/overage/damage/wrong-item exception state.
- Advance authoritative transit custody to destination stock only for the accepted amount/policy.
- Refuse final completion with unresolved required lines unless an explicit partial/exception policy permits it.

### Dispatch sales order
- Consume/release the exact reservation tied to the order line.
- Reject total fulfillment above authoritative requested/remaining quantity.
- Lock source stock and reservation together.
- Create/advance backorder state atomically for approved partial fulfillment.

### Finalize count
- Treat observation as evidence, not delta.
- Compute variance server-side against the authoritative snapshot/revision.
- Require approval according to policy.
- Apply only the approved variance with explicit adjustment-in/out movement semantics.
- Preserve observation/decision history unchanged.

## Idempotency requirements

- Stable command identity is created with the business action, not each retry.
- Uniqueness cannot be weakened by operation type.
- First concurrent submission must resolve deterministically with atomic insert/on-conflict semantics.
- Server computes the canonical request fingerprint.
- Same key + same command returns the existing authoritative result.
- Same key + different command is rejected.
- A fresh key still cannot reapply already-posted document quantity because the document line is authoritative.

## Phase 4 verification minimum

Add real database tests for:

- same command retry;
- concurrent first submission;
- same idempotency key/different payload;
- partial document failure -> zero partial stock commit;
- cumulative receive/dispatch repost;
- concurrent dispatch against same stock;
- exact reservation consumption/release;
- transfer transit -> destination receipt;
- approved count variance only;
- stale document revision conflict;
- pending/unresolved line finalization denial;
- movement provenance/client action timestamp;
- typed error/result contract.

Preserve all existing Phase 1-3 pgTAP suites and static verifiers.
