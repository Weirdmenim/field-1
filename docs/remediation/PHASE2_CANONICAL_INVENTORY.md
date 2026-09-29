# Phase 2 - Canonical Inventory Model

## Purpose

Phase 2 establishes one authoritative model for physical stock, reservations, bins, units of measure, and in-transit custody while preserving every Phase 1 authentication and tenant-isolation invariant.

This phase deliberately does **not** complete authoritative warehouse documents, reservation fulfillment commands, transfer lifecycle commands, or Cycle Count approval. Those belong to later phases. Unsafe legacy paths are made fail-closed where a correct business command does not yet exist.

## Canonical quantity model

For a company + warehouse + product:

- `physical_on_hand_base_qty` = sum of all physical inventory status buckets (`AVAILABLE + DAMAGED + BLOCKED`).
- `available_physical_base_qty` = physical quantity in the `AVAILABLE` status bucket only.
- `reserved_base_qty` = remaining quantity on active/partially fulfilled first-class reservations.
- `available_to_promise_base_qty` = `available_physical_base_qty - reserved_base_qty`.
- `in_transit_inbound_base_qty` is separate custody and is never counted as on-hand before receipt.

This resolves the legacy ambiguity where status-bucket rows and `reserved_base_qty` embedded in balances were mixed into incompatible formulas.

## Authoritative stock key

Physical balances are keyed by:

`company + warehouse/location + bin + product + inventory status`

Every existing warehouse receives a deterministic compatibility `SYSTEM` bin. Existing balance and movement rows are backfilled to that bin. New operational workflows should send the actual bin whenever one is known; `SYSTEM` exists to preserve legacy data and compatibility, not as the long-term operational substitute for bin identity.

## Units of measure

Every product now requires:

- an authoritative `base_unit_id`;
- an authoritative `default_sale_unit_id`;
- an active base unit with `conversion_to_base = 1`;
- a normalized unique unit code per company/product.

Each unit defines allowed decimal scale, quantity step, and optionally a transaction maximum. Quantity conversion and validation occurs server-side through `convert_product_quantity`. Client workflow quantities are serialized as decimal strings to avoid integer-only truncation.

Legacy products without a declared base unit receive a synthetic 1:1 base unit. The migration does not invent an unknown conversion factor.

## Reservations

`inventory_reservations` is now the source of reservation truth. It records ownership/provenance and tracks reserved, fulfilled, and released quantities independently from physical balances.

Legacy non-zero `inventory_balances.reserved_base_qty` is preserved by creating `LEGACY_BALANCE` reservation rows and then zeroing the deprecated balance column. New writes to that column are prohibited.

Phase 2 does not yet implement document-authoritative reservation create/fulfill/release commands; dispatch reservation consumption remains a later dependency.

## In-transit custody

`inventory_transit_lots` makes stock between warehouses explicit. It tracks source/destination warehouse/bin, quantity, received/lost progress, status, and provenance. Transit remains separate from on-hand until a future authoritative transfer/receipt command receives it.

## Movement integrity

New movement rows must:

- use positive entered/base quantities;
- record an entered UOM;
- carry bin identity whenever a source/destination location exists;
- carry source/destination status whenever that side exists;
- follow movement-type source/destination semantics;
- preserve bin identity during same-bin status changes/damage operations.

Undefined `TRANSFER_REVERSAL` semantics fail closed until the dedicated reversal phase defines an authoritative command.

## Negative stock

Physical source deductions now materialize/lock the authoritative balance row, re-read the current quantity under lock, then apply the deduction. Negative stock is permitted only for the `AVAILABLE` bucket when the warehouse explicitly has `allow_negative_inventory=true`. `DAMAGED` and `BLOCKED` buckets cannot become negative.

This is a stock-level safety rule only. Authoritative document remaining-quantity and reservation ownership checks still require later document commands.

## Canonical read model

`inventory_location_positions` is the warehouse-level stock truth used by product/search/detail queries.

`inventory_bin_positions` is the bin-level stock truth. Its key set is the union of physical balances, bin-scoped reservations, and bin-scoped inbound transit so reservation-only/transit-only positions cannot disappear merely because no physical balance row exists yet.

Production queries no longer replace errors or legitimate empty tenants with fixture stock.

## Compatibility mutation wrapper

The authenticated Phase 1 JSON RPC wrapper remains temporary but is upgraded so that it:

- derives actor/company server-side;
- validates warehouse permission;
- resolves active authoritative bins;
- validates/converts UOM server-side;
- maps dispatch to `SALE`;
- locks/rechecks source stock;
- enforces negative-stock policy;
- supports explicit adjustment-in/adjustment-out;
- supports controlled status changes and damage transitions;
- rejects generic `ADJUSTMENT`;
- rejects direct `COUNT` stock mutation.

The old low-level primitive is explicitly disabled and remains revoked from application roles. The new internal primitive is also revoked from application roles.

## Deliberately unresolved dependencies

The following are **not** claimed complete in Phase 2:

- Cycle Count observation/variance/approval (F-001/F-002).
- Reservation fulfillment/release atomically with dispatch (F-006).
- Full reservation-vs-document/stock business invariants (F-009/F-021).
- Authoritative in-transit dispatch/receive lifecycle commands (F-015).
- Document remaining-quantity validation (covered later by authoritative document commands).
- Idempotency first-submission race/canonical fingerprint semantics (Phase 4).
- Reversal semantics and reversal command (later ledger/reversal phase).
- Product catalog pagination over Supabase row limits (F-185).

## Rollout safety

Run `supabase/preflight/phase2_existing_data.sql` against any non-disposable database before applying the migration. Resolve duplicate normalized unit codes, invalid unit precision, cross-product unit references, negative-stock policy violations, and other reported data issues first.

Database tests live in `supabase/tests/phase2_inventory_model.sql`. They must run against the real Supabase/PostgreSQL boundary before Phase 2 findings move from IMPLEMENTED to VERIFIED/CLOSED.
