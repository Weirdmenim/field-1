# Phase 9 - Stock Revision Preconditions and Runtime Proof Harnesses

## Scope
Phase 9 closes the remaining stale-inventory execution gap without weakening the Phase 1-8 boundaries. Final stock commands now carry explicit expected physical and reservation revisions captured from the authoritative document snapshot.

## Implemented boundary
- `inventory_document_command_stock_preconditions` binds a company-scoped command UUID to one immutable precondition fingerprint.
- Each required company/location/bin/product/status position carries `physicalRevision`, `binReservationRevision`, and `locationReservationRevision`.
- Final SALES_DISPATCH, TRANSFER_SHIP, TRANSFER_RECEIVE, and COUNT_FINALIZE commands validate those revisions before posting.
- Balance and reservation mutations take the same transaction-scoped advisory position locks used by validation, protecting both existing rows and absent-row/new-reservation races.
- Stale snapshots return typed `STOCK_REVISION_CONFLICT` results instead of silently executing against newer inventory.
- Conflict rebasing creates a new stable command identity and refreshes both document revision and stock/reservation snapshot.
- Legacy public final-stock RPCs are revoked from `authenticated`; revision-protected v2 RPCs are the app entry points.
- Old persisted final commands without the Phase 9 snapshot fail runtime validation/quarantine rather than posting stale.

## Runtime proof boundary
The cumulative Phase 1-9 pgTAP runner was prepared, and a browser harness exercises the actual transpiled production `syncEngine.ts` using real IndexedDB/Web Locks/BroadcastChannel when the browser allows it. In this environment:
- Supabase CLI/PostgreSQL are unavailable, so database runtime/concurrency tests cannot execute.
- Managed Chromium blocks all page navigation and denies IndexedDB on `about:blank`, so browser multi-context/restart proofs cannot execute.

Those findings remain OPEN rather than being inferred from architecture.
