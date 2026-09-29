# Phase 1 - Authentication, Tenant Isolation, and Authorization

## Purpose

Phase 1 establishes the trust boundary that every later inventory fix must use. The client may request a warehouse action, but it is no longer authoritative for actor identity or company membership.

## Security invariants introduced

1. `auth.uid()` is the root authenticated identity.
2. `profiles.auth_user_id` uniquely binds a FieldOne operational profile to a Supabase user.
3. Company access is represented by `company_memberships`.
4. Warehouse access and operation permissions are represented by `warehouse_memberships`.
5. The server derives the actor and company for inventory mutations; client `user_id`/`company_id` are not authorization facts.
6. Tenant-sensitive tables have RLS enabled.
7. Application roles have read-only table access to inventory ledger/balance tables; mutation is routed through authorized RPCs.
8. The low-level inventory mutation primitive is not executable by `anon` or `authenticated`.
9. Tenant-safe composite foreign keys prevent company/product/location/actor mismatches in current inventory tables.
10. New balance-changing operations/movements require actor attribution without rewriting legacy unattributed history.
11. Client query cache keys include company and warehouse context.
12. Local queued commands carry user/company/warehouse ownership and a different operational context cannot see or process them.

## Main implementation files

- `supabase/migrations/20260917090000_phase1_auth_membership_rls.sql`
- `supabase/seed.sql`
- `src/lib/auth.tsx`
- `src/components/auth/AuthGate.tsx`
- `src/lib/supabase.ts`
- `src/lib/queries.ts`
- `src/lib/syncEngine.ts`
- `src/lib/useSyncEngine.ts`
- `src/App.tsx`
- Receive/Dispatch/CycleCount workflow payload construction
- `supabase/tests/phase1_auth_rls.sql`
- `scripts/phase1_verify.mjs`

## Provisioning rule

The migration deliberately does not guess which Supabase user owns an existing profile. After creating/authenticating a user, an administrator must bind that user explicitly and ensure memberships are correct, for example:

```sql
UPDATE profiles
SET auth_user_id = '<supabase-auth-user-uuid>'
WHERE id = '<fieldone-profile-uuid>';
```

The seeded company/warehouse memberships are demo authorization data only; `auth_user_id` remains unbound until an administrator provisions it. This is fail-closed by design.

## Current permission set

- `inventory.read`
- `inventory.receive`
- `inventory.dispatch`
- `inventory.count`
- `inventory.count.approve`
- `inventory.adjust`
- `inventory.reverse`

These permissions are intentionally explicit booleans in Phase 1. Later phases may replace this with a more normalized permission model if needed, but server-side enforcement must remain.

## Operational context switching

The authenticated context RPC returns active company and warehouse memberships. The frontend only accepts selections present in that response. Company/warehouse switches invalidate tenant-sensitive query caches. The selected context is stored in `sessionStorage` under the authenticated user ID, not as a global unscoped value.

## Offline ownership rule carried into Phase 6

The current LocalForage queue is still the legacy whole-array design. Phase 1 adds ownership metadata (`authUserId`, `companyId`, `locationId`) and filters visibility/processing by exact owner context. Legacy ownerless records are preserved but cannot be submitted under a newly authenticated user.

Phase 6 must replace this with record-per-command, versioned, cross-tab-safe storage. Do not remove the Phase 1 ownership invariant when redesigning the outbox.

## Important non-goals

Phase 1 does **not** correct the stock formula, count variance semantics, reservations, bin model, UOM conversion, authoritative documents, atomic document posting, retry/backoff, scanner implementation, or fixture data model. The temporary JSON posting wrapper still maps existing operation types to the legacy stock mutation semantics. Later phases must replace that business logic without weakening the Phase 1 authorization boundary.

## Verification commands

Dependency-free checks that run in the current sandbox:

```bash
npm run verify
```

Database integration tests (requires a running Supabase CLI/local database):

```bash
npm run phase1:db-test
```

Full compiler/build gate (requires dependency installation):

```bash
npm ci --no-audit --no-fund
npm run check
```

## Database test scenarios

`supabase/tests/phase1_auth_rls.sql` verifies:

- authenticated cannot insert balances directly;
- authenticated cannot update movement history directly;
- low-level mutation RPC execution is denied;
- authorized JSON wrapper execution is allowed;
- `auth.uid()` maps to the expected profile;
- operational context derives from authenticated identity;
- another tenant company/product is invisible under RLS;
- unassigned warehouses are invisible;
- spoofed `company_id`/`user_id` do not change server actor/company;
- movement attribution uses the authenticated profile;
- a cross-tenant product is rejected by the wrapper.

## Exit condition

Phase 1 code is IMPLEMENTED when dependency-free verification passes. It is not VERIFIED/CLOSED until the SQL integration tests and clean `npm ci -> typecheck -> build` pass on an environment with Supabase and npm dependency access.

## Rollout preflight for existing databases

Before applying the Phase 1 migration to a non-disposable database, run:

```sql
\i supabase/preflight/phase1_existing_data.sql
```

Every `*_mismatch` count must be zero. If a mismatch exists, stop and reconcile the data rather than disabling the new tenant-safe constraint. The preflight also lists `is_active` and `allow_direct_sales` for every location because Phase 1 starts enforcing those flags; an incorrectly configured existing warehouse can therefore be intentionally blocked after rollout.

Existing `NULL` actor history is reported but not deleted or rewritten. The migration uses `NOT VALID` actor checks so legacy history remains intact while new balance-changing rows must be attributed.
