# Phase 7 Handoff

Frozen implementation base: `bcc69fdc79b9400ca4202bb2020bbc3c782e3c7b` (traceability tag is created after this handoff update).

## Preserve all Phase 1-6 invariants
Do not weaken auth-derived identity, canonical stock/bin/UOM/reservation/transit rules, authoritative documents, atomic server commands/idempotency, append-only ledger/reversal rules, or durable owner-scoped outbox/draft semantics.

## Phase 7 invariants to carry forward
1. Transactional identifier matching is exact and tenant scoped; partial matching is never sufficient to select a stock-mutating document line.
2. SKU and active barcode/GTIN/alias namespaces cannot ambiguously identify different products inside one company.
3. Multiple actionable lines/bins are an explicit ambiguity requiring line/bin selection.
4. Scanner acquisition is an adapter; scanner output selects work but never mutates stock directly.
5. Unknown scans are durable owner-scoped audit events and may be replayed offline using a stable client event UUID.
6. Production does not depend on developer simulation controls for successful scans.
7. A non-shortage receipt condition/identity exception cannot masquerade as a finalizable normal receipt.
8. Count discrepancy reason is deliberate per attempt; recount does not inherit stale local reason/observation state.

## Remaining high-value work
- Explicit document correction/disposition command for damaged/wrong/unexpected receipt outcomes (F-112 remains OPEN).
- PWA/service-worker application shell and cold-offline assets (F-079/F-080/F-081/F-082).
- Storage failure recovery/UX (F-070).
- Reachability semantics beyond `navigator.onLine` (F-064).
- Conflict keep-mine/compensation workflow (F-048).
- Retire/harden legacy inventory-operation idempotency/state compatibility paths (F-034/F-036/F-037/F-137/F-138/F-182).
- Catalog pagination/server search above API row limits (F-185).
- Execute true DB/browser/device concurrency/restart/scanner integration tests (F-147/F-149/F-153/F-154/F-157 and pending external gates).
