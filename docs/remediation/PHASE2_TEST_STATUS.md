# Phase 2 Test Status

Implementation commit under test: `236f588bec728812b2b2ba2b3380f32c2b03f33a`

## Executed successfully in this environment

- `npm run phase0:verify` - PASS.
- `npm run phase1:verify` - PASS.
- `npm run phase2:verify` - PASS with 77 canonical-model/source assertions.
- `npm run syntax:check` - PASS; all 26 TypeScript/TSX source files transpile syntactically.
- `npm run verify` - PASS for the complete Phase 0 + Phase 1 + Phase 2 dependency-free verification chain.
- `git diff --check` - PASS before implementation freeze.
- Supplemental semantic TypeScript pass using temporary external-library declarations - PASS.

## Phase 2 database tests authored

`supabase/tests/phase2_inventory_model.sql` contains pgTAP assertions for:

- canonical tables/views;
- required bins and product base/default UOMs;
- canonical LED physical/ATP/transit math;
- fractional UOM acceptance and invalid scale/step rejection;
- configured base/default UOM activity;
- blank unit-code rejection;
- negative inventory policy enforcement;
- rejection of new embedded reservation data;
- preservation of seed products/bins.

Phase 1 authorization/RLS tests are run alongside Phase 2 tests by `npm run phase2:db-test`.

## CI database gate

`.github/workflows/database-tests.yml` installs the Supabase CLI, starts the local database, and runs the Phase 1 + Phase 2 pgTAP suites on push/pull request.

## Attempted but environment-blocked here

- `npm run phase2:db-test` - BLOCKED because Supabase CLI/PostgreSQL are not installed in this sandbox (exit 2).
- `npm run typecheck` - BLOCKED before project typechecking because `@types/node` is unavailable (exit 2).
- `npm run build` - BLOCKED because `vite` is unavailable without project dependencies (exit 127).

These blocked gates are not recorded as passed. Phase 2 findings must remain `IMPLEMENTED` until a network/Docker-enabled development or CI environment executes the real database tests, clean install, typecheck, and production build.

## Pre-migration database safety

Run `supabase/preflight/phase2_existing_data.sql` against every non-disposable database before migration. Resolve reported duplicate normalized unit codes, blank unit definitions, step/scale mismatches, policy-invalid negative balances, product/unit inconsistencies, and legacy reservation anomalies before applying Phase 2.
