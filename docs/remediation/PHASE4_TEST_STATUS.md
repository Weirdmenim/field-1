# Phase 4 Test Status

## Executed and passing in this environment

- `npm run verify` - PASS after final Phase 4 hardening.
  - project context continuity
  - Phase 0 controls
  - Phase 1 security assertions
  - Phase 2 canonical inventory assertions
  - Phase 3 authoritative-document assertions
  - Phase 4 atomic-command assertions
  - dependency-free TypeScript/TSX syntax transpilation (27 files)
- `npm run phase4:verify` - PASS.
- `git diff --check` - PASS before implementation freeze.
- Supplemental semantic TypeScript pass using temporary declarations for unavailable external packages - PASS, exit 0.
- SQL structural sanity - PASS:
  - balanced migration dollar quotes;
  - pgTAP plan = 36;
  - detected pgTAP assertions = 36;
  - no Phase 4 TODO/FIXME/HACK residue found in core implementation files.

## Regression suite authored but not executable locally

`supabase/tests/phase4_atomic_document_commands.sql` contains 36 pgTAP assertions covering command schema/privileges, transfer ship/receipt, replay protection, immutable idempotency content, reservation/bin provenance, reservation fulfillment, SALE movement provenance, stale revision conflict, approved count variance, and physical timestamp preservation.

True two-session simultaneous-first-submission concurrency is structurally addressed by the unique `(company_id, client_command_id)` key plus `INSERT ... ON CONFLICT`, but a genuine parallel-session harness has not executed in this sandbox. Do not describe that race as runtime-verified yet.

## External gates attempted and blocked

- `npm run phase4:db-test` -> exit 2: Supabase CLI is unavailable.
- `npm run typecheck` -> exit 2: `@types/node` is unavailable because project dependencies are not installed.
- `npm run build` -> exit 127: Vite is unavailable because project dependencies are not installed.

These are environment/tooling blocks, not passes and not evidence of code failure. They remain mandatory gates in a network/Docker-enabled CI environment.
