# Phase 10 Release Candidate Checklist

Release candidate sign-off requires all items below. `scripts/phase10_release_candidate.sh` automates the executable gates.

## Repository/build
- [ ] Frozen project context verifies.
- [ ] Clean `npm ci` succeeds from lockfile.
- [ ] Full TypeScript `tsc --noEmit` succeeds.
- [ ] Production Vite build succeeds.
- [ ] Full Phase 0-9 verification succeeds.
- [ ] Phase 10 architecture-gap audit succeeds.

## Database
- [ ] Local/staging Supabase starts from clean state.
- [ ] All Phase 1-9 migrations and seed apply cleanly.
- [ ] Cumulative pgTAP Phase 1-9 suite passes.
- [ ] F-147 true concurrent-dispatch proof passes.
- [ ] F-149 injected second-line failure rollback proof passes.
- [ ] F-149 killed-client mid-transaction rollback + same-ID retry proof passes.
- [ ] F-157 PostgreSQL duplicate-SKU/two-bin ambiguity proof passes.
- [ ] Automated reconciliation passes.

## Browser/offline
- [ ] F-153 four-context concurrent enqueue/drain proof passes in unrestricted Chromium.
- [ ] F-154 persistent-profile restart/expired-lease recovery proof passes.
- [ ] F-157 actual application duplicate-line/bin selection flow passes.
- [ ] Browser console contains no unexpected uncaught errors during proofs.

## Final disposition
- [ ] Attach complete `.phase10-evidence` bundle.
- [ ] Update canonical 186-finding matrix only from captured runtime evidence.
- [ ] Re-run reconciliation after all tests.
- [ ] Confirm no unexplained stock/reservation/transit delta.
- [ ] Release owner, database owner and application owner sign off.
- [ ] Tag release candidate only after every mandatory gate is green.
