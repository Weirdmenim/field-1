# Phase 3 - Authoritative Warehouse Documents

## Purpose

Phase 3 establishes server-authoritative business documents and line lifecycle on top of the Phase 1 trust boundary and Phase 2 canonical inventory model. It records warehouse intent, captured outcomes, revisions, exceptions, approvals, and remaining quantities without mutating physical stock. Phase 4 will atomically consume these records and apply inventory deltas.

## Inherited invariants

- Actor and tenant authority derive from `auth.uid()` and server-side memberships.
- Warehouse selection is requested context, not authorization.
- Application roles do not directly write balances, operations, or movement history.
- Physical inventory is bin + product + status; reservations and transit remain first-class separate state.
- UOM conversion is server-authoritative.
- COUNT, ambiguous ADJUSTMENT, and undefined reversal semantics remain fail-closed outside authoritative workflows.
- Compatibility data such as SYSTEM bins and LEGACY_BALANCE reservations is preserved until explicit reconciliation.

## Authoritative entities

Phase 3 adds specialized entities instead of one generic document table:

- `inventory_transfer_documents`
- `inventory_transfer_lines`
- `inventory_sales_orders`
- `inventory_sales_order_lines`
- `inventory_backorders`
- `inventory_count_sessions`
- `inventory_count_lines`
- `inventory_count_observations`
- `inventory_count_approvals`

Every document/line has stable UUID identity, tenant-safe relationships, lifecycle status, and optimistic revision state.

## Transfer / receipt model

Transfer lines carry authoritative source/destination warehouse and bin identity, product, entered UOM, expected entered/base quantity, captured received quantity, posted quantity, remaining expected quantity, exceptions, timestamps, and revision.

`record_transfer_receipt_line(...)`:

1. derives the actor from authentication;
2. locks the document and line;
3. verifies the expected document revision;
4. checks receive permission and assignment;
5. validates authoritative destination bin and UOM;
6. accepts partial, overage, damage/wrong-item style outcomes only with structured exception state where required;
7. freezes the captured line against ordinary recapture;
8. advances document/line revisions;
9. does **not** change stock.

## Sales / dispatch model

Sales-order lines carry authoritative source bin, product/UOM, requested quantity, captured picked quantity, posted quantity, backordered quantity, server-derived remaining quantity, exception state, and revision.

`record_sales_order_pick_line(...)` rejects captured quantity above the requested quantity and requires a structured exception for zero/partial capture. Backorders are first-class records and cannot make captured + backordered quantity exceed the authoritative request.

These controls capture correct document intent, but Phase 4 must still make final stock posting validate these same constraints atomically under stock/document locks.

## Count model

Count sessions and lines store the authoritative expected physical snapshot and physical revision. Observations are separate immutable attempts carrying:

- observed entered/base quantity;
- expected snapshot/revision copied at observation time;
- variance;
- discrepancy reason/notes;
- observing actor;
- client physical action timestamp.

Zero is a valid explicit observation. It is no longer necessary to overload numeric zero as "untouched" at the server boundary.

Variance decisions are persisted in `inventory_count_approvals` and require `inventory.count.approve`. Approval, rejection, and recount are explicit states. Phase 3 deliberately does not apply an approved variance to stock; that becomes an atomic Phase 4 command.

## Blind count boundary

Count base tables are not directly exposed to the application role. `get_count_session_document(...)` hides expected quantity/revision until an observation exists, unless the caller has count-approval permission. This makes the new authoritative API capable of enforcing blind counting rather than relying on CSS/UI hiding.

The existing legacy CycleCount screen still needs to be migrated to this API before the original UI finding can be closed.

## Provenance

Phase 3 extends existing canonical state so future stock commands can be traced to authoritative document lines:

- reservations -> sales-order line;
- transit lots -> transfer line;
- movements -> transfer line / sales-order line / count line;
- operations -> source document line.

No historical relationship is invented. Seeded transit rows that cannot be truthfully matched to the reviewed document fixture remain preserved and are surfaced for reconciliation.

## Client access layer

`src/lib/documents.ts` provides runtime-validated RPC access and tenant/location-scoped TanStack Query keys for:

- warehouse work;
- transfer documents;
- sales-order documents;
- count sessions;
- capture/exception commands;
- backorders;
- count observations and decisions.

Tenant/account/warehouse context changes invalidate the new document caches.

## Explicit non-goals in Phase 3

Phase 3 does not:

- mutate `inventory_balances`;
- append `inventory_movements`;
- consume/release sales reservations;
- advance transfer transit custody to on-hand;
- apply approved count variance;
- provide final document-level idempotency/fingerprints;
- eliminate the old line-oriented stock posting path;
- reconcile sync success/failure with local workflow completion.

Those are Phase 4 dependencies and remain open in the audit matrix.

## Safety rules for Phase 4

Phase 4 must never treat a captured quantity as an inventory delta by itself. It must lock the authoritative document/line, calculate the unposted delta from server state, verify current revision/remaining quantity, lock stock/reservations/transit, and commit document + stock + movement state atomically under one stable document command identity.
