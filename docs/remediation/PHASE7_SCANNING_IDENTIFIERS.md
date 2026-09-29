# Phase 7 - Production Scanning, Identifier Integrity, and Workflow UX Hardening

## Scope
Phase 7 starts from the frozen Phase 6 tag and preserves every Phase 1-6 trust, stock, document, atomic-command, ledger, and durable-outbox invariant.

## Implemented
- Tenant-scoped normalized SKU uniqueness and a production `product_identifiers` table for BARCODE/GTIN/ALIAS values.
- Cross-namespace collision guards prevent one product's barcode/alias from colliding with another product's SKU.
- Exact server-side identifier resolution; transactional resolution never uses substring/partial matching.
- Transactional resolver returns actionable authoritative document lines and explicit `ambiguous` results when a product appears on multiple lines/bins.
- Camera acquisition abstraction using `getUserMedia` + `BarcodeDetector` when available, plus keyboard-wedge hardware scanner input.
- Permission/unsupported/background lifecycle, torch attempt, and duplicate-decode suppression.
- Durable owner-scoped `unknown_scan_report` outbox commands and server audit events containing actor, warehouse, task/document context, code, and physical timestamp.
- Live item display no longer treats SKU as the barcode value; barcode/GTIN comes from authoritative identifiers.
- Receive condition/identity exception entry remains available even when received quantity equals expected.
- Non-shortage receive condition/identity exceptions are blocked from ordinary receipt finalization; no unsafe disposition is fabricated.
- Dispatch cannot enter Review until every required line is accounted for.
- Count variance reasons have no default selection; recount clears stale local observed/reason command state.

## Deliberately not overclaimed
- Condition/identity receipt exceptions still require an explicit authoritative document disposition/correction command before they can be resolved and posted. F-112 remains OPEN.
- Duplicate-SKU/bin ambiguity has structural/static coverage, but real browser + database workflow integration execution remains pending. F-157 remains OPEN.
- PWA/cold-offline shell, storage failure recovery, legacy compatibility idempotency cleanup, catalog pagination, and external concurrency/device execution are outside Phase 7.

## Safety boundary
Identifier/scanner code may select an authoritative line and enqueue existing authoritative commands. It never mutates `inventory_balances` or `inventory_movements` directly.
