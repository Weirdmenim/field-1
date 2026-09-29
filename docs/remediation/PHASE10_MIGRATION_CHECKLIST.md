# Phase 10 Migration Checklist

Use this checklist on the staging/production-like environment before release verification.

- [ ] Restore from `phase9-final-verification-implemented` or the Phase 10 prepared tag; verify artifact SHA-256 values.
- [ ] Take database backup/snapshot and record PostgreSQL version, Supabase CLI version, application commit, and migration ledger.
- [ ] Run `npm run context:verify` and `npm run verify` before database change.
- [ ] Run every applicable read-only preflight in phase order; investigate every non-zero mismatch before migration.
- [ ] Confirm Phase 1 tenant/auth bindings and membership data are reconciled; never disable tenant-safe constraints to force a migration.
- [ ] Confirm Phase 2 UOM/bin/reservation data has no duplicate normalized UOM/bin keys or invalid negative status balances.
- [ ] Confirm Phase 3 document provenance and legacy transit mismatches are explicitly reconciled, not fabricated.
- [ ] Confirm Phase 4-5 command/ledger history is preserved; no history rows are rewritten or deleted.
- [ ] Confirm Phase 6 durable browser records are not wiped as part of deployment instructions.
- [ ] Confirm Phase 7 SKU/identifier namespace preflight has zero collisions.
- [ ] Confirm Phase 8 receipt-disposition preflight findings have an explicit reconciliation decision.
- [ ] Confirm Phase 9 stock-precondition migration is present and old app-callable final stock RPCs remain revoked.
- [ ] Apply migrations in repository order only; do not edit historical migration files.
- [ ] Run cumulative `npm run phase9:db-test` after migration.
- [ ] Run `scripts/phase10_reconcile.sh` and retain its output as release evidence.
- [ ] Record migration start/end, operator, backup identifier, and rollback decision point.
