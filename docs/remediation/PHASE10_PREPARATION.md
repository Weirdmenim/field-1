# Phase 10 - External Runtime Proof / Release-Candidate Preparation

Phase 10 preparation begins from frozen Phase 9 tag `phase9-final-verification-implemented`. It does not redesign inventory authority. Its purpose is to make the five remaining runtime-proof findings executable, reproducible, and fail-closed on an unrestricted Docker/PostgreSQL/Chromium runner.

## Prepared proof gates

- **F-147 concurrent dispatch:** two independent PostgreSQL sessions are released from an observed advisory-lock barrier onto the same 10-unit position; each order requires seven units. The proof requires exactly one accepted command, one typed `STOCK_REVISION_CONFLICT`, final stock of three, one SALE movement, and one completed order.
- **F-149 partial/crash atomicity:** one test injects a failure on the second movement after first-line work has begun; a second test kills the client while an AFTER-movement trigger keeps the transaction open. Both require zero partial stock/ledger/document residue. The killed-client path then retries with the same stable command UUID and requires success.
- **F-153 concurrent outbox execution:** the actual transpiled production `src/lib/syncEngine.ts` runs in four Chromium contexts. Forty commands are enqueued concurrently and multiple contexts drain them. All forty must remain durable, confirm once, have unique IDs, and execute exactly one RPC per ID.
- **F-154 restart recovery:** a persistent Chromium profile stores three commands, including an intentionally stranded expired `syncing` lease. The entire browser context is closed/reopened and must recover all original IDs exactly once.
- **F-157 duplicate SKU/bin workflow:** PostgreSQL creates one sales document with the same exact product/SKU on two actionable lines in two different bins. The production resolver must return explicit ambiguity with both line/bin candidates; the actual Vite application must require the operator to choose the exact bin and carry that choice into Dispatch.

## Release-candidate runner

`scripts/phase10_release_candidate.sh` is the one-command release gate. It requires Node 22.12-22.x, npm/network access, Docker, Supabase CLI, `psql`, Python Playwright, Chromium, Git, curl and GNU `timeout`. It records exact tool versions before execution.

The runner performs, in order: clean `npm ci`, context verification, cumulative Phase 0-10 static verification, full TypeScript, production build, clean Supabase reset/migrations/seed, cumulative Phase 1-9 pgTAP, Phase 10 runtime fixture setup, F-147, both F-149 proofs, F-157 database proof, reconciliation, actual-app/browser F-153/F-154/F-157 proofs, final reconciliation, and only then writes `RELEASE_GATE_PASSED.txt`.

## Local preparation evidence

Repository-level preparation checks pass in this environment. Full external execution remains blocked here:

- release-candidate runner: exit 2 because Docker executable is unavailable;
- database runtime proofs: exit 2 because `psql` is unavailable (Supabase CLI/PostgreSQL are also unavailable);
- browser runtime proof: exit 2 because managed Chromium returns `ERR_BLOCKED_BY_ADMINISTRATOR`;
- full TypeScript: exit 2 because installed project `@types/node` is unavailable;
- Vite build: exit 127 because project Vite dependencies are unavailable.

These blocker outcomes are not passes and do not change the five OPEN findings.
