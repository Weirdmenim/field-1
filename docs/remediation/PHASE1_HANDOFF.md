# Phase 1 Handoff - Context for the Next Implementation

## Branch lineage

- Immutable baseline tag: `pre-inventory-remediation`
- Phase 0 branch/head preceded this phase.
- Phase 1 working branch: `phase1-authz`
- Phase 1 implementation commit: `d986c86c67dd39b439b3ac649da59058c94cfa1a`

Do not rewrite or delete the baseline tag. Continue later phases from the Phase 1 branch after its verification gate is green.

## Decisions that must carry forward

1. **Never trust client `user_id` or `company_id` for authorization.** New RPCs derive actor/tenant from `auth.uid()` and server-side memberships.
2. **Location is a requested context, not proof of permission.** Every future server command must validate active warehouse membership and the required permission.
3. **Do not reintroduce direct application writes** to `inventory_balances`, `inventory_operations`, or `inventory_movements`.
4. **Keep tenant-safe relationships.** New tables should either carry `company_id` with composite integrity or derive tenant through an authoritative parent document.
5. **All tenant-sensitive React Query keys must include company/location context** or be invalidated on context changes.
   Auth context loads are generation-guarded so a slow response from a previous session cannot repopulate state after sign-out/account switch.
6. **Offline records are owned by auth user + company + warehouse.** Phase 6 can redesign storage but must preserve this isolation.
7. **Legacy ownerless queue records are quarantined, not deleted.** A later migration/reconciliation flow must decide how to recover them.
8. **Existing inventory business semantics are still unsafe.** Authorization hardening must not be mistaken for stock correctness.
9. **The generic JSON inventory wrapper is temporary.** Phase 4 should replace it with business-document commands while retaining auth-derived context and restricted internal primitives.
10. **Existing profile UUIDs are preserved.** `auth_user_id` is an additive binding; do not regenerate profiles merely to integrate Supabase Auth.

## Findings directly implemented in Phase 1

Primary: F-093 through F-103, F-171, F-181.

Security-adjacent implementation also touches: F-024, F-025, F-057, F-065, F-067, F-068, F-141, F-172, F-174, and F-175.

These remain `IMPLEMENTED` rather than `VERIFIED/CLOSED` until the database integration and clean build gates run successfully.

## Known dependencies for Phase 2

Phase 2 (canonical inventory model) may change keys and constraints around balances, product units, statuses, reservations, bins, and in-transit inventory. When doing so:

- preserve RLS on every replacement table;
- preserve server-derived actor/company semantics;
- extend `warehouse_memberships` checks to new bin/reservation/document commands;
- keep direct app writes revoked;
- add tenant-safe FKs for every new company-scoped relationship;
- update `get_my_operational_context` only if new warehouse capabilities are introduced;
- update the remediation matrix rather than deleting/renumbering findings.

## Verification limitation in this environment

`npm ci` cannot complete because package-network access times out, and no Supabase CLI/PostgreSQL runtime is installed. Static security verification and dependency-free TS/TSX transpilation run here; full typecheck/build and SQL policy execution remain mandatory external gates.
