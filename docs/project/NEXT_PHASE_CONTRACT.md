# Current Phase Contract — Phase 11 Truth Gate and Inventory Baseline

## Restore context

Read in this order:

1. `docs/project/MASTER_PRODUCT_BUILD_CONTEXT.md`
2. `docs/project/PROJECT_STATE.json`
3. `docs/project/INVARIANTS.md`
4. `docs/phase11/PHASE11_CHARTER.md`
5. `docs/phase11/PHASE11_ENTRY_AUDIT.md`
6. `docs/phase11/PHASE11_IMPLEMENTATION_PLAN.md`
7. `docs/phase11/PHASE11_TEST_EVIDENCE_PLAN.md`
8. `docs/phase11/PHASE11_RISK_REGISTER.md`
9. `docs/project/DECISION_LOG.md`
10. `docs/project/VERIFICATION_LEDGER.md`

## Current program state

Phase 10 is recorded historically as complete, but the supplied release evidence is contradictory and the program baseline is **NOT SEALED**. Phase 11 is in progress to establish a reproducible release truth gate.

## What may change in Phase 11

- release/CI/test harnesses;
- evidence validation and release manifests;
- test diagnostics;
- application-level test coverage;
- security/recovery/load verification assets;
- project-state and handoff documentation needed to make status truthful.

## What must not change casually

- Phase 1–10 inventory authority semantics;
- tenant/RLS trust boundaries;
- canonical balance/reservation/transit model;
- authoritative document semantics;
- idempotent command identity;
- append-only movement history and controlled reversals;
- offline durable outbox ownership, lease and conflict semantics;
- stock-revision preconditions and locking rules.

## Phase 11 completion command set

The final supported environment must successfully execute the canonical release gate and then:

```sh
npm run phase11:evidence-audit
npm run phase11:verify
```

A green Phase 11 handoff additionally requires the non-release gates defined in `PHASE11_TEST_EVIDENCE_PLAN.md`.

## Next phase

Phase 12 — ERP Platform Foundation — is forbidden until Phase 11 exit evidence is complete and `PROJECT_STATE.json` records the program baseline as SEALED.
