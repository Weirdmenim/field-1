# Phase 11 Test and Evidence Plan

## Evidence principles

- Logs are evidence only when produced by the canonical command on the recorded commit.
- Static inspection cannot substitute for a runtime-only acceptance criterion.
- A PASS summary cannot override a failing underlying log.
- Missing evidence is not PASS.
- Failed runs are preserved and assigned a run identifier.
- The final sealed run must be self-contained and auditable without chat history.

## Mandatory final-run evidence

- runtime/tool versions;
- exact Git commit SHA and dirty-worktree status;
- `npm ci` output;
- context verification;
- cumulative static verification;
- typecheck;
- production build;
- migration/reset output;
- cumulative pgTAP output;
- F-147 concurrency proof;
- F-149 fault-injection proof;
- F-149 killed-client/retry proof;
- F-153 concurrent outbox proof;
- F-154 restart/persistent-queue proof;
- F-157 duplicate-SKU/bin database proof;
- F-157 real-browser proof;
- reconciliation before and after browser execution;
- application E2E smoke results;
- tenant/permission negative results;
- backup/restore proof;
- security scan results;
- performance baseline results;
- release manifest;
- final `RELEASE_GATE_PASSED.txt` generated only after every required assertion is green.

## Evidence audit rules

The automated audit must fail when:

- the release marker is absent;
- `release.log` lacks its terminal PASS signature;
- any required evidence file is absent;
- F-147/F-149/F-153/F-154/F-157 PASS signatures are absent;
- browser proof contains an unhandled traceback/timeout after its last PASS;
- post-browser reconciliation is absent;
- commit recorded by evidence conflicts with the release manifest;
- the final worktree was dirty unless the manifest explicitly records an approved exception.
