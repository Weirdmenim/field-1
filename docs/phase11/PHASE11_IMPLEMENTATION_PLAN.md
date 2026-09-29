# Phase 11 Implementation Plan

## Workstream A — Truth reconciliation

1. Inventory every Phase 10 evidence file and classify it PASS / FAIL / INCOMPLETE / STALE.
2. Compare evidence to `PROJECT_STATE.json`, `VERIFICATION_LEDGER.md`, `PHASE10_TEST_STATUS.md`, `PHASE10_HANDOFF.md`, and remediation matrix claims.
3. Preserve historical text, but remove stale documents from the active source-of-truth path or mark them explicitly historical.
4. Add machine-readable program approval state.
5. Require evidence audit before release status can be promoted.

## Workstream B — Portable release harness

1. Remove machine-specific PostgreSQL/Git PATH injection from the canonical runner.
2. Prefer the already-authored portable Bash DB proof runners over workstation-specific Node wrappers.
3. Resolve Python via an explicit supported command/environment.
4. Ensure each release run gets a clean evidence directory while preserving prior failed runs.
5. Make CI and local execution invoke the exact same canonical command.
6. Ensure the runner never generates or rewrites source assertions during execution.

## Workstream C — Browser proof repair

1. Reproduce the F-157 browser failure.
2. Make test warehouse/location selection deterministic.
3. Add diagnostic capture on failure: screenshot, current URL, visible text, console errors and page errors.
4. Assert the authoritative task is returned before UI interaction.
5. Prove exact SKU ambiguity, explicit line/bin choice and propagation of selected bin into dispatch.
6. Keep browser proof against the real application; do not replace it with component mocks.

## Workstream D — Evidence seal

1. Add `phase11_evidence_audit.mjs`.
2. Require exact PASS signatures for each runtime finding.
3. Require terminal release PASS marker and post-browser reconciliation.
4. Generate release manifest and hashes.
5. Refuse to seal when logs contain terminal traceback/timeout conditions.

## Workstream E — Missing test layers

Add tests incrementally without weakening the existing DB/runtime suite:

- React unit/component tests for critical state transformations and error handling;
- Playwright E2E smoke: sign-in, operational context, work list, inventory lookup, one receive/dispatch/count happy path;
- tenant isolation negative tests;
- permission boundary negative tests;
- migration-from-clean and migration-from-representative-data tests;
- backup/restore smoke;
- outbox long-queue/restart/multi-context stress;
- baseline performance measurements for common stock/document queries and command latency.

## Workstream F — Security and operations baseline

- dependency vulnerability scan;
- secret scan;
- privileged PostgreSQL function review;
- exposed API/RLS review;
- development-vs-production Supabase setting checklist;
- recovery runbook;
- release rollback runbook;
- SLO/observability requirements for Phase 12.

## Implementation order

1. Entry audit and state correction.
2. Release-runner portability and evidence-directory discipline.
3. F-157 harness determinism/diagnostics.
4. Evidence validator.
5. Clean canonical release rerun on supported environment.
6. Application test-layer expansion.
7. Security/backup/load gates.
8. Final reconciliation and Phase 11 handoff.

No business-domain expansion is mixed into this phase.
