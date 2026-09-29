# Phase 8 Handoff

Implementation commit: `4a74839f4e39718c98642f4fc9b1c3cf340cc0d9`

## Preserve all Phase 1-7 invariants
Do not weaken auth-derived identity, canonical stock/UOM/bin/reservation/transit rules, authoritative documents, atomic document commands, append-only ledger/reversal constraints, owner-scoped durable outbox/drafts, or exact scanner/identifier semantics.

## Phase 8 invariants to carry forward
1. Backend reachability is proven by an active bounded probe; `navigator.onLine` is never sufficient authority.
2. Durable storage failure is explicit, retryable, and fail-closed for sync; warehouse work is never silently discarded to recover storage.
3. Cold offline startup may reuse only same-authenticated-user cached operational context and owner-scoped snapshots.
4. The service worker caches the application shell and observed same-origin build resources; production does not depend on remote fonts/product placeholders.
5. Catalog retrieval paginates until exhaustion; configured API row limits cannot silently define the catalog.
6. Keep-local conflict resolution creates a new stable command UUID against the latest authoritative document revision and preserves the old conflict as audit history.
7. Receipt condition/identity exceptions are not business-complete until an authoritative disposition exists; rejected quantity never becomes AVAILABLE by convenience.
8. The client-callable generic inventory-operation compatibility path remains retired; active command idempotency/failures live in authoritative command ledgers.
9. New canonical inventory operation IDs are UUID-shaped/company-unique and identity/fingerprint fields are immutable.
10. Remaining active reservation quantity cannot exceed non-negative AVAILABLE physical stock at transaction commit.

## Phase 9 priorities
- Add explicit expected physical-balance and reservation revision preconditions to stock-sensitive command execution (F-042/F-043).
- Execute real concurrent-dispatch, crash-mid-batch, concurrent enqueue/drain, restart-with-pending-queue, and duplicate-SKU/bin integration tests (F-147/F-149/F-153/F-154/F-157).
- Run all accumulated pgTAP suites, clean `npm ci`, full `tsc --noEmit`, production Vite build, and browser/device runtime gates in a capable environment.
- Reconcile the audit matrix from IMPLEMENTED to TESTED/VERIFIED/CLOSED only from executed evidence.
