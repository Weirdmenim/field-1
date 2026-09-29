# Phase 5 Administrative Ledger Repair Runbook

This runbook is for exceptional inventory-ledger repair. It is not an application feature and must not be exposed to browser/mobile roles.

## Normal path first

1. If the movement is an eligible standalone movement, use `reverse_inventory_movement` with a stable UUID command id and explicit reason.
2. If the movement is linked to a transfer, sales order, count session, or Phase 4 document command, stop. The generic reversal must return `DOCUMENT_CORRECTION_REQUIRED`.
3. Do not bypass that result with direct SQL. A document-specific correction must reconcile both business-document state and stock state atomically.

## Emergency database-owner repair protocol

Use only for a proven ledger defect that cannot be corrected through an existing command.

1. Freeze affected warehouse/product operational work.
2. Take and verify a database backup/snapshot.
3. Record incident/ticket id, responsible approver, affected company/location/bin/product/status, current physical quantity, expected quantity, and supporting evidence.
4. Run all phase preflights and reconcile the movement chain for the affected position.
5. Produce a reviewed one-off migration that **appends** a compensating inventory operation/movement and adjusts the canonical balance in the same transaction. Never UPDATE/DELETE an existing movement.
6. Use an authenticated/approved operational actor or an explicitly approved system-actor model; never fabricate another user identity.
7. Include reason text and the incident/ticket id in the new audit rows.
8. Reconcile balance = opening + inbound - outbound + approved corrections after the repair.
9. Re-run affected integration/regression tests.
10. Unfreeze operations only after independent review confirms document, reservation, transit, balance, and movement history agree.

## Prohibited repair techniques

- disabling the append-only trigger merely to edit/delete a posted movement;
- deleting movement rows and rewriting balances;
- changing `reversal_of_movement_id` after posting;
- attaching fake document/line provenance;
- using `service_role` as a generic ledger-write bypass;
- correcting a document-linked movement without also reconciling its authoritative document state.

Persistent admin escape-hatch RPCs are intentionally not created in Phase 5. Exceptional repairs should be reviewable one-off migrations, not a standing bypass around the inventory command model.
