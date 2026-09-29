# Phase 9 Handoff

Phase 9 must be restored from tag `phase9-final-verification-implemented` and verified with `npm run context:verify` followed by `npm run verify` before further changes.

## New non-negotiable invariants
1. Every public final stock command requires an explicit authoritative physical + reservation revision snapshot.
2. A stable command UUID cannot be reused with different stock preconditions.
3. Balance/reservation writers and stock-precondition validators use the same transaction-scoped position locks.
4. Stale stock/reservation snapshots return typed conflict; they never silently post.
5. Conflict keep-local rebasing refreshes both document revision and stock snapshot under a new command UUID.
6. Legacy Phase 4 final-stock RPCs remain internal; application callers use the Phase 9 v2 entry points.

## Remaining audit work
Only five runtime-proof findings remain OPEN: F-147, F-149, F-153, F-154, and F-157. Do not close them from static reasoning. Execute them against real PostgreSQL/Supabase and an unrestricted browser runtime, then promote status only from captured evidence.
