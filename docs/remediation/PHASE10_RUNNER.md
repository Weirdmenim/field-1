# Phase 10 Portable Release-Candidate Runner

Run from the repository root on an unrestricted Linux runner with Docker.

## Prerequisites
- Node 22.12-22.x and npm
- Docker daemon
- Supabase CLI
- PostgreSQL client (`psql`)
- Python 3 + `playwright`
- Playwright Chromium (`python -m playwright install --with-deps chromium`)
- curl

## One command

```bash
npm run phase10:release-candidate
```

The runner performs a clean dependency install, cumulative verification, typecheck/build, clean local Supabase reset, cumulative pgTAP, all five remaining runtime proofs, and release reconciliation. Evidence is written to `.phase10-evidence/`.

The command exits non-zero on any failure. Missing runtime capability returns a blocked/failure exit; it is never converted into a pass.
