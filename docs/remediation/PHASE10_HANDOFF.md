# Phase 10 Preparation Handoff

Restore from tag `phase10-release-runner-prepared`. Run `npm run context:verify` and `npm run verify` before external execution.

## What is frozen

- All Phase 1-9 application/database invariants remain intact.
- Phase 10 adds release-proof infrastructure only; it does not alter stock authority or warehouse business semantics.
- `npm run phase10:release-candidate` is the canonical full gate.
- GitHub Actions workflow `.github/workflows/phase10-release-candidate.yml` provisions Node/Python/Supabase/PostgreSQL client/Playwright Chromium and invokes the same runner.
- Migration, reconciliation and release checklists live under `docs/remediation/PHASE10_*_CHECKLIST.md`.
- Harness audit is `docs/remediation/PHASE10_HARNESS_AUDIT.md`.

## The only unresolved audit findings

F-147, F-149, F-153, F-154 and F-157 are CLOSED. Their corresponding runtime assertions have passed and evidence is retained.

## External execution sequence

On an unrestricted machine with Docker and network access:

```sh
npm run phase10:release-candidate
```

The command is deliberately all-or-nothing. `RELEASE_GATE_PASSED.txt` is created only after clean install, full typecheck/build, cumulative pgTAP, all five runtime proofs, and final reconciliation succeed. Upload/preserve the complete `.phase10-evidence` directory before updating the matrix.

## No Phase 11 architectural phase is planned

If the runner is green, perform final 186-finding disposition and release-candidate sign-off. If a runtime proof exposes a real defect, fix it as a Phase 10 remediation iteration, add regression evidence, rerun the complete gate, and only then promote status.
