# Phase 2 Handoff - Context for the Next Implementation

## Branch lineage

- Immutable baseline tag: `pre-inventory-remediation`
- Phase 1 tag: `phase1-authz-implemented`
- Phase 2 working branch: `phase2-inventory-model`
- Phase 2 implementation commit: `236f588bec728812b2b2ba2b3380f32c2b03f33a`

Continue the next phase from the Phase 2 branch/head after its external database/build verification gate is green. Do not rewrite or remove the Phase 0/1 history tags.

## Non-negotiable Phase 1 invariants that still apply

1. Actor and tenant authority come from `auth.uid()` + server-side memberships. Never reintroduce trusted client `user_id` or `company_id`.
2. Warehouse selection is requested context, not authorization. Every server command verifies active warehouse membership/permission.
3. Application roles do not directly write `inventory_balances`, `inventory_operations`, or `inventory_movements`.
4. New tenant-scoped relationships must remain tenant-safe.
5. Tenant-sensitive React Query keys remain company/location scoped and are invalidated on context switch.
6. Offline command ownership remains authenticated user + company + warehouse. Ownerless legacy commands remain quarantined, not deleted.

## Canonical Phase 2 inventory invariants

1. Physical balance key is `company + location + bin + product + inventory_status`.
2. Physical on-hand is the sum of physical status buckets; `AVAILABLE`, `DAMAGED`, and `BLOCKED` are separate authoritative buckets.
3. Reservation truth is `inventory_reservations`. `inventory_balances.reserved_base_qty` is deprecated and must remain zero.
4. Available-to-promise is `AVAILABLE physical - remaining active reservations`.
5. In-transit stock is separate custody in `inventory_transit_lots` and is not on-hand until an authoritative receipt transition completes.
6. Every product has an authoritative active base UOM and default sale UOM. Server-side conversion validates quantity scale/step and product/company ownership.
7. Movement rows carry UOM and bin identity and obey movement-type source/destination/status structure.
8. Negative physical stock is allowed only for `AVAILABLE` when the warehouse explicitly permits it. `DAMAGED` and `BLOCKED` cannot become negative.
9. Canonical warehouse reads use `inventory_location_positions`; bin reads use `inventory_bin_positions`.
10. Production inventory queries never silently replace database errors or an empty tenant with fixture stock.
11. The `SYSTEM` bin is a migration/compatibility bin. Future operational document lines should carry the actual authoritative bin where known.
12. The Phase 2 compatibility JSON RPC is temporary. Final document commands must preserve all auth/bin/UOM/status/locking invariants while removing generic line-oriented posting.

## Fail-closed decisions that must not be undone

- Direct `COUNT` stock mutation is rejected. Do not re-enable it as an adjustment. Counts must become observations followed by server-calculated variance and approval policy.
- Generic `ADJUSTMENT` is rejected. Use explicit adjustment-in/out semantics.
- Undefined `TRANSFER_REVERSAL` movement semantics are rejected for new rows until the reversal phase defines a validated reversal command.
- The old Phase 0/1 low-level inventory primitive is disabled and revoked.

## Data preservation decisions

- Existing balances are backfilled into a deterministic per-location `SYSTEM` bin rather than discarded.
- Existing non-zero embedded reservations become `LEGACY_BALANCE` reservation rows before the old column is zeroed.
- Existing movements without an entered UOM are backfilled to the product base UOM.
- Existing products without a declared base unit get a synthetic 1:1 legacy base unit. No unknown conversion factor is invented.
- Existing rows that may violate newly introduced positive/semantic checks are preserved through `NOT VALID` constraints; new writes must satisfy the constraints.

Do not delete `LEGACY_BALANCE` reservations, compatibility bins, old columns, or preserved historical movement rows until a later reconciliation/cutover explicitly proves they can be retired.

## Findings implemented by Phase 2

Primary implemented findings:

F-003, F-004, F-005, F-007, F-008, F-010, F-011, F-012, F-013, F-014, F-016, F-017, F-018, F-019, F-020, F-022, F-023, F-131, F-132, F-133, F-146, F-156, F-177, F-178, F-179, F-180, F-184.

These remain `IMPLEMENTED`, not `VERIFIED/CLOSED`, until the real Supabase pgTAP suite and clean dependency build/typecheck run successfully.

## Important findings only partially mitigated in Phase 2

- **F-001/F-002:** COUNT corruption is blocked, but count observation/variance/approval is still missing.
- **F-006:** reservation model exists, but dispatch does not yet fulfill/release reservations atomically.
- **F-009:** many structural invariants now exist; reservation/document business invariants remain.
- **F-015:** transit model exists; authoritative transfer dispatch/receive commands remain.
- **F-021:** UOM technical precision/step validation exists; authoritative document remaining-quantity/business-policy limits remain.
- **F-152:** reservation fulfillment test awaits the fulfillment command.
- **F-157:** bin model exists; duplicate-SKU document/scanner flow still awaits later phases.
- **F-185:** catalog pagination/server-side search remains open.

## Phase 3 direction - authoritative warehouse documents

Phase 3 should introduce server-authoritative entities and line lifecycle for at least:

- transfers / receipts;
- sales orders / dispatches;
- count sessions / count observations;
- count variance approvals;
- backorders / partial completion state.

Document lines should have stable IDs, requested/expected quantities, accepted/picked/count observations, authoritative bin/UOM, posted/remaining state, lifecycle status, and revision. The server document model should become the source that later Phase 4 atomic commands validate.

Phase 3 should attach first-class reservations/transit provenance to authoritative document/line IDs without deleting legacy provenance rows.

## Phase 4 dependencies already visible

Atomic commands must later:

- lock the authoritative document and relevant balance/reservation rows;
- validate document revision and remaining line quantity;
- calculate server-side deltas from authoritative posted/remaining state;
- consume/release exact reservations during dispatch;
- advance transit custody during transfer receipt;
- use stable document-level idempotency keys;
- compute canonical request fingerprints server-side;
- eliminate the existing first-submission idempotency race;
- return typed accepted/duplicate/conflict/validation/authorization/transient outcomes.

## Verification limitations in this environment

The local sandbox has no Supabase CLI/PostgreSQL runtime and project npm dependencies are not installed. Static model assertions, dependency-free TS/TSX transpilation, and a supplemental semantic TypeScript pass run here. Real pgTAP, full project `tsc --noEmit`, and Vite production build remain mandatory external gates.

The repository now includes `.github/workflows/database-tests.yml` so the Phase 1 + Phase 2 pgTAP suites run automatically on a normal GitHub runner with the Supabase CLI.
