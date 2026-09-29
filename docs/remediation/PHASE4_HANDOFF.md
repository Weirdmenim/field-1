# Phase 4 Handoff

## Frozen implementation

Phase 4 implementation commit: `8e8e74038fe6d9defc99a6036122135280fe6c8e`
Target tag after traceability freeze: `phase4-atomic-document-commands-implemented`

Start all later work from the Phase 4 tagged state, not from an older ZIP or Phase 3 branch.

## What Phase 4 made authoritative

- Company-scoped UUID document command identity independent of command type.
- Server-computed immutable command fingerprint, including client-recorded timestamp.
- Atomic first-command acquisition with `ON CONFLICT`.
- Typed terminal command outcomes and command result lookup.
- Atomic transfer ship: on-hand -> transit.
- Atomic transfer receipt: transit -> destination on-hand.
- Atomic sales dispatch: reservation + stock + SALE movement + order state.
- Atomic count finalization: approved variance -> explicit movement.
- Movement -> command -> authoritative document-line provenance.
- Server-side delta calculation from authoritative shipped/posted quantities.
- Generic RECEIVE/DISPATCH/COUNT stock posting is no longer a supported bypass.

## Non-negotiable invariants carried into Phase 5

1. Actor/company authority stays server-derived from Phase 1 authentication and membership.
2. Direct application writes to balances, movements, operations, document commands, reservation/transit rows remain prohibited.
3. Phase 2 bin/UOM/status/reservation/transit invariants remain authoritative.
4. Phase 3 document/line/revision/observation/approval evidence remains immutable normal workflow state.
5. Every document stock mutation uses a stable UUID command key and server-computed fingerprint.
6. Retrying the same command may never create another stock movement.
7. A fresh command key may not reapply an already-posted document quantity; authoritative delta state is the final defense.
8. Client-recorded physical-action time is immutable command content and may not change on retry.
9. Transfer custody is on-hand -> transit -> destination on-hand, never a direct source/destination fiction.
10. Dispatch protects reservations for other work and only fulfills/releases the authoritative order line's reservations.
11. Count changes stock only through approved, snapshot-safe variance finalization.
12. Document movements must carry durable command + line provenance.
13. Legacy line-oriented document posting remains fail closed until later UI/outbox cutover is complete.
14. Historical provenance is never invented to make migrations convenient.

## Known work deliberately left open

- Durable document-command outbox and draft persistence.
- Stable command id creation/persistence inside the actual Receive/Dispatch/Count UI lifecycle.
- Startup recovery, processing leases, multi-tab coordination, backoff, causal ordering.
- Conflict UI and compensating conflict resolution.
- Workflow completion/task state driven by server-confirmed command outcomes.
- Explicit movement reversal/correction command and full reversal integrity.
- Final deprecation/migration of legacy `inventory_operations` text transaction identity and compatibility adjustment RPC.
- Real runtime Supabase pgTAP execution and clean dependency typecheck/build in an environment with the required tooling.

## Phase 5 recommended target

**Phase 5 - Ledger immutability, validated reversals, and controlled corrections.**

Phase 5 should:

- implement an explicit server reversal/correction command that locks the original movement;
- enforce same tenant/product/document/location semantics and reversible quantity remaining;
- support full/partial reversal without double reversal;
- prohibit direct UPDATE/DELETE of posted movement history for all application roles and define tightly controlled administrative repair procedures;
- link reversal movements durably to original movement and command;
- define downstream-activity rules (what can/cannot be reversed after later movements);
- migrate/document legacy `reversal_of_movement_id` into a validated relationship;
- test full, partial, repeated, cross-tenant, wrong-product, over-reversal, and downstream-dependency cases;
- preserve every Phase 1-4 invariant.

The offline/outbox redesign remains the following phase after ledger/reversal integrity unless a later project-state decision explicitly reorders it.
