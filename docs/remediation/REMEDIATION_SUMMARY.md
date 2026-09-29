# FieldOne Remediation Register

Canonical scope: **186 findings** from the Master Merged Audit.

## Status model

`OPEN -> DESIGNED -> IMPLEMENTED -> TESTED -> VERIFIED -> CLOSED`

## Severity counts

- Build blocker: 1
- Build/repro: 2
- P0: 31
- P0/P1: 4
- P1: 104
- P1/P2: 8
- P2: 36

## Epic allocation

- E00 Build & reproducibility: 5
- E01 Auth, tenant & permissions: 15
- E02 Canonical inventory model: 24
- E03 Authoritative documents: 10
- E04 Atomic posting & idempotency: 15
- E05 Concurrency & conflict protocol: 9
- E05 RPC result/state protocol: 4
- E06 Offline outbox & sync: 37
- E07 Cycle Count workflow: 6
- E07 Dispatch workflow: 8
- E07 Receive workflow: 9
- E07 Workflow state machines: 7
- E08 Product identifiers & scanning: 14
- E09 Queries, cache & fixture removal: 7
- E10 Ledger integrity & reversals: 4
- E11 Regression safety net: 12

## Current implementation state

- Phase 0 controls: implemented.
- Phase 1 authorization/tenant boundary: implemented, external DB/build verification pending.
- Phase 2 canonical inventory model: implemented at `236f588bec728812b2b2ba2b3380f32c2b03f33a`, external DB/build verification pending.
- Phase 3 authoritative warehouse documents: implemented at `6226de9d2abc15110c40efa8f8088fb596cc29b6`, external DB/build verification pending.
- Phase 4 atomic document commands: delivered workspace restored for Phase 5; original implementation hash recorded as `8e8e74038fe6d9defc99a6036122135280fe6c8e`.
- Phase 5 append-only ledger and validated reversals: implemented at `485a76d355b0e48fbeb370eee2272b05a8dda658`, external DB/build verification pending.
- Current matrix status after Phase 5: 76 `IMPLEMENTED`, 110 `OPEN`, 0 `VERIFIED`, 0 `CLOSED`.

## Closure rule

A finding may move to `CLOSED` only when its implementation, data migration (if applicable), regression test, and verification evidence are all recorded in `REMEDIATION_MATRIX.csv`.
