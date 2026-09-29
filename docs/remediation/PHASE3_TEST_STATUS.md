# Phase 3 Test Status

## Final local verification

The dependency-free verification chain passes:

- `npm run context:verify` - PASS
- `npm run phase0:verify` - PASS
- `npm run phase1:verify` - PASS
- `npm run phase2:verify` - PASS
- `npm run phase3:verify` - PASS
- `npm run syntax:check` - PASS (27 TS/TSX files)
- `npm run verify` - PASS
- `git diff --check` - PASS before freeze
- supplemental semantic TypeScript pass using external-library stubs - PASS
- Phase 3 SQL dollar-quote delimiter sanity - PASS
- Phase 3 migration contains no direct balance update or movement insert - PASS

## Phase 3 static assertions

The Phase 3 verifier covers the authoritative transfer, sales-order, backorder, count-session, count-observation and count-approval model; stable IDs/revisions; server-derived remaining quantities; capture immutability; over-pick/backorder bounds; optimistic conflicts; blind count response behavior; provenance links; RLS/table privilege boundary; runtime RPC parsing; context-scoped query keys; seed fixtures; preflight; and DB tests.

## Database tests authored

`supabase/tests/phase3_authoritative_documents.sql` adds pgTAP coverage for:

- authoritative tables and RPC grants;
- direct-table denial for count/session data;
- seeded authoritative work;
- reservation/transit provenance;
- blind expected quantity before observation;
- over-pick rejection;
- transfer capture and captured-line immutability;
- optimistic revision conflicts;
- explicit zero count;
- variance -> pending approval;
- count-approval authorization;
- approved count remaining document-only (no stock mutation);
- backorder creation and bounds.

`.github/workflows/database-tests.yml` runs Phase 1 + Phase 2 + Phase 3 pgTAP on a normal Supabase-capable CI runner.

## External gates blocked in this sandbox

These were attempted and are not represented as passes:

- `npm run phase3:db-test` -> exit 2: Supabase CLI is unavailable.
- `npm run typecheck` -> exit 2: project `@types/node` dependency is unavailable because dependencies cannot be installed here.
- `npm run build` -> exit 127: Vite is unavailable for the same dependency-install limitation.

The corresponding gates remain mandatory before findings can move from IMPLEMENTED to VERIFIED/CLOSED.
