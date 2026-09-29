# Phase 10 Runtime Harness Audit

Phase 10 does not close the five remaining findings by static reasoning. It prepares runtime proofs that must execute successfully on an unrestricted runner.

| Finding | Previous proof gap | Phase 10 strengthened proof | False-positive guard |
|---|---|---|---|
| F-147 concurrent dispatch | No real parallel PostgreSQL sessions | Two distinct captured orders start behind a shared advisory barrier, both carry the same stock revision, and both compete for 10 units while each requests 7 | Requires exactly one accepted command, exactly one `STOCK_REVISION_CONFLICT`, final on-hand 3, exactly one SALE movement, and exactly one completed order |
| F-149 crash/partial commit | Atomicity inferred from PL/pgSQL structure only | (1) test-only trigger fails on the second movement after first-line work has begun; (2) separate client is killed while an AFTER movement trigger sleeps | Requires unchanged balances, zero movements, zero posted quantities and unchanged document state after failure/crash; killed-client case also requires no command/precondition residue and successful retry using the same stable command id |
| F-153 concurrent enqueue/sync | Existing harness used only three commands/two tabs | Four real Chromium contexts concurrently enqueue 40 distinct commands while multiple contexts drain the production `syncEngine.ts` | Requires all 40 durable records, all terminal `confirmed`, unique IDs, and exactly one RPC execution per command |
| F-154 restart pending outbox | Existing harness covered one stranded command | Persistent Chromium profile stores three commands including an expired `syncing` lease; entire browser context closes and reopens | Requires all original IDs to survive, stale lease recovery, all three confirmations, and exactly one execution per ID |
| F-157 duplicate SKU/bin workflow | Schema uniqueness and static ambiguity UI only | PostgreSQL resolver fixture contains the same exact SKU on two actionable order lines in two bins; full Vite app browser flow signs in, resolves exact SKU, chooses bin B, and enters Dispatch with bin B | DB proof requires `ambiguous` + exact two line/bin candidates; browser proof requires both bin choices visible and selected bin B carried into the execution screen |

## Harness authority

- Database proofs call the production Phase 9 `*_v2` command functions and production Phase 7 identifier resolver.
- Browser queue proofs transpile and execute the production `src/lib/syncEngine.ts`; only external RPC/storage service dependencies are deterministic test stubs.
- The F-157 browser proof runs the actual Vite application against local Supabase; no production test-mode shortcut is introduced.
- Test-only database triggers/functions are created by the harness and removed before release reconciliation.

## Runtime requirements

Docker, Supabase CLI, PostgreSQL client (`psql`), Node 22, npm network access, Python Playwright, and unrestricted Chromium are mandatory. A missing capability is a blocked gate, never a pass.
