# FieldOne Project Context Continuity System

This directory is the durable project memory for the FieldOne remediation program. It exists so that a later phase, engineer, model session, or CI run can recover the project's authoritative state without relying on chat history.

## Source-of-truth hierarchy

1. `docs/project/MASTER_PRODUCT_BUILD_CONTEXT.md` - program-level build strategy, phase governance, market path, entry/exit gate rules, and new-chat bootstrap.
2. `docs/project/PROJECT_STATE.json` - machine-readable current phase, branch, commits, tags, counts, gates, and next-phase contract.
3. `docs/project/INVARIANTS.md` - non-negotiable rules established by completed phases. Later phases may strengthen them but must not violate them.
4. `docs/project/DECISION_LOG.md` - durable architectural decisions and their rationale.
5. `docs/project/PHASE_JOURNAL.md` - chronological phase history, what changed, and what deliberately remains open.
6. `docs/project/VERIFICATION_LEDGER.md` - which verification gates actually ran, which passed, and which are blocked by environment.
7. `docs/remediation/REMEDIATION_MATRIX.csv` - all 186 audit findings and their exact implementation/test/verification disposition.
8. `docs/remediation/PHASE*_HANDOFF.md` - detailed phase-specific handoffs.
9. Git history and immutable phase tags - exact source snapshots.

## Update protocol for every phase

Before implementation:
- read `PROJECT_STATE.json`, `INVARIANTS.md`, the most recent phase handoff, and all matrix rows allocated to the phase;
- create the next phase branch from the recorded `current_head`;
- do not modify prior immutable phase tags.

During implementation:
- record new architectural decisions in `DECISION_LOG.md`;
- preserve existing data additively unless a separately verified migration/cutover authorizes removal;
- update matrix rows only with evidence actually produced;
- never mark a finding VERIFIED/CLOSED from static inspection alone.

Before phase freeze:
- update `PROJECT_STATE.json` with the exact implementation commit and traceability commit;
- append the phase entry to `PHASE_JOURNAL.md`;
- append executed/blocked test gates to `VERIFICATION_LEDGER.md`;
- create/update the phase handoff;
- run `npm run context:verify` and the phase verification chain;
- tag the traceability/handoff commit with the phase tag;
- package workspace + Git bundle + matrix + handoff + test evidence.

## Closure discipline

Finding lifecycle:

`OPEN -> DESIGNED -> IMPLEMENTED -> TESTED -> VERIFIED -> CLOSED`

`IMPLEMENTED` means code/migration exists and local static/semantic checks support the change.

`VERIFIED` requires the relevant runtime/database/build/integration evidence.

`CLOSED` requires implementation, migration/data handling if applicable, regression test, verification evidence, and no remaining acceptance gap.
