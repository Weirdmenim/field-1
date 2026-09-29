# FieldOne Phase 11 Charter — Truth Gate and Inventory Baseline

## Purpose

Phase 11 exists to convert the repository-recorded Phase 10 completion into a **reproducible, evidence-backed, program-approved baseline** before any ERP expansion begins.

Phase 11 does **not** redesign the inventory domain and does **not** add procurement, finance, CRM, HR, or other ERP business functionality.

## Entry state

Repository records report Phase 10 complete and 186/186 legacy findings CLOSED. The uploaded Phase 10 archive, however, contains contradictory release evidence:

- `.phase10-evidence/` exists and contains substantial successful runtime output.
- `.phase10-evidence/RELEASE_GATE_PASSED.txt` is absent.
- `.phase10-evidence/release.log` has the run header but no terminal PASS line.
- `.phase10-evidence/browser-duplicate-bin.log` ends in a Playwright `TimeoutError`.
- `.phase10-evidence/reconciliation-after-browser.log` is absent.
- `PROJECT_STATE.json` and `VERIFICATION_LEDGER.md` nevertheless record Phase 10 as complete/passed.
- the canonical release runner contains Windows-specific PATH assumptions while CI declares `ubuntu-latest`.
- older Node runtime runners contain hard-coded Windows PostgreSQL paths and mutate assertion files during execution.

These contradictions are the Phase 11 starting defect. They do not automatically reopen all legacy findings; they prevent the Phase 10 release candidate from being accepted as the program baseline until a clean gate is reproduced.

## Non-negotiable constraints

1. Preserve every Phase 1–10 inventory invariant in `docs/project/INVARIANTS.md`.
2. Do not replace the authoritative inventory command model.
3. Do not weaken RLS, tenant checks, idempotency, revision preconditions, ledger append-only semantics, or durable offline guarantees to make tests pass.
4. Preserve failed evidence. A failed run is forensic data, not trash.
5. A release status may only become PASS when the evidence bundle independently proves it.
6. Phase 12 may not start until the Phase 11 exit gate is green.

## Phase 11 objectives

### O1 — Establish one truthful project state
Create a machine-checkable distinction between repository-recorded historical status and program-approved release status. Eliminate contradictory handoffs and stale status language from the active context path.

### O2 — Make the release gate reproducible
A clean checkout on a supported runner must be able to install dependencies, provision the local Supabase/PostgreSQL runtime, apply migrations, run all static/database/browser/runtime checks, reconcile state, build production assets, and produce an immutable release evidence bundle.

### O3 — Make release tooling portable and non-mutating
Remove hard-coded workstation paths from canonical runners. Canonical verification must not rewrite source files as a side effect.

### O4 — Make evidence self-validating
Introduce a programmatic evidence audit that fails if required proof files, terminal PASS markers, runtime assertions, or post-run reconciliation are missing or contradictory.

### O5 — Expand the quality baseline beyond database proofs
Add/establish the missing application-level test layers required for future ERP development: component/unit tests, browser E2E smoke coverage, security checks, backup/restore proof, load/performance baselines, cross-tenant attack cases, and prolonged offline/outbox stress coverage.

## Exit gate

Phase 11 is complete only when all of the following are true:

- clean dependency install succeeds from lockfile;
- `npm run context:verify` passes;
- cumulative static verification passes;
- TypeScript typecheck passes;
- production build passes;
- clean database reset/migration passes;
- cumulative pgTAP suite passes;
- F-147, F-149, F-153, F-154 and F-157 runtime proofs pass in one canonical release run;
- browser tests run against the real application and real local database;
- final reconciliation passes after browser/runtime tests;
- evidence audit passes;
- a release manifest records commit SHA, runtime versions, migration set, artifact/evidence hashes and completion time;
- backup/restore smoke proof passes;
- tenant-isolation attack regression suite passes;
- minimum application E2E smoke suite passes;
- no P0/P1 Phase 11 defect remains open;
- `PROJECT_STATE.json`, `VERIFICATION_LEDGER.md`, handoff and evidence all agree;
- the Phase 11 baseline is tagged/sealed in the real Git repository.

## Phase 12 entry prohibition

No ERP platform restructuring or business module expansion starts while `program_approval.phase10_program_baseline != SEALED` or while the Phase 11 exit gate is red.
