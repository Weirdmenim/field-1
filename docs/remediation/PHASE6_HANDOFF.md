# Phase 6 Handoff

## Frozen implementation

Phase 6 implementation commit: `1b503cb59649c5e304aaecc7bc1942b4789e2f57`
Target frozen tag after traceability commit: `phase6-offline-sync-implemented`

## Phase 4 history recovery note carried forward

The original Phase 4 Git bundle was unavailable at the Phase 5 restore boundary. Authentic Phase 0-3 history was retained and the exact delivered Phase 4 workspace was reconstructed as commit `131806f753468186588f198c767263c35d19b3b0`. The original Phase 4 implementation hash remains `8e8e74038fe6d9defc99a6036122135280fe6c8e` in its handoff. Never represent the recovery commit as the unavailable original Phase 4 history.

## What Phase 6 made durable

- Receive/Dispatch/Count workflow drafts survive component remount/reload in versioned owner-scoped storage.
- The old executable whole-array queue is replaced by record-per-command `OutboxV2`.
- Legacy/ownerless queue records and malformed V2 records are quarantined, not silently reassigned or deleted.
- Stable command ids are created with the local business action and reused across retry.
- Durable command records contain ownership, schema version, dependencies, retry metadata, typed error, lease, confirmation, and server result.
- Startup processing recovers stale leases and drains eligible queued work while online.
- Web Locks plus an atomic IndexedDB fallback lease coordinate multiple browser execution contexts.
- RPC calls have abortable timeouts and transient retry semantics.
- Receive/Dispatch/Count now use Phase 3 authoritative documents and Phase 4 command APIs instead of generic document stock posting.
- Sync Center and freshness indicators reflect persisted command confirmation, not fabricated state.
- Blind count observations can be captured offline without exposing expected quantity; approval remains blocked until the operator records the real discrepancy reason.

## Non-negotiable invariants carried into Phase 7

1. Preserve every Phase 1 authenticated identity, tenant, RLS, membership, and permission invariant.
2. Preserve every Phase 2 bin/UOM/status/reservation/transit/ATP invariant.
3. Preserve every Phase 3 authoritative document, stable line, blind count, observation, approval, and backorder invariant.
4. Preserve every Phase 4 stable UUID command, server fingerprint, atomic delta, reservation/transit, and provenance invariant.
5. Preserve every Phase 5 append-only movement and validated reversal invariant.
6. Ownerless/malformed offline work is quarantined; never silently delete or reassign it.
7. Offline workflow truth is durable draft + durable outbox + persisted server snapshot, not fixture/React state.
8. Stable command identity is not regenerated on retry.
9. Conflict remains blocked from ordinary retry until an explicit resolution action exists.
10. Cross-context processing remains serialized through Web Locks or an atomic durable lease.
11. Receive/Dispatch/Count may not return to the legacy generic stock-posting path.
12. Sync UI may not fabricate confirmation, freshness, server state, or actor information.
13. Phase 5 movement history remains append-only; offline reconciliation never edits movement history.
14. Production scanner simulation remains development-only and must not be mistaken for a real scanner.

## Known work deliberately left open

- Normalized production barcode/identifier table and tenant-safe SKU/barcode uniqueness.
- Exact identifier-only transactional matching and duplicate SKU line/bin disambiguation.
- Real camera/hardware scanning adapter and device lifecycle.
- Durable unknown-scan report/exception workflow.
- Receive same-quantity damaged/wrong-item exception entry and exception-resolution lifecycle.
- Dispatch Review UX still needs stricter gating before entering Review (the final command is already blocked).
- Count discrepancy reason/recount UX cleanup.
- PWA/service-worker application shell and true cold-offline startup.
- Comprehensive storage-failure recovery UX.
- Real browser tests for simultaneous tabs, crash/restart, and concurrent enqueue/drain.
- `keep mine` compensating conflict command and document-specific correction flows.
- Legacy operation/idempotency compatibility cleanup.
- Catalog pagination beyond Supabase row cap.
- Real external Supabase/typecheck/build gates.

## Phase 7 target

**Production scanning, identifier integrity, exception workflow hardening, and workflow UX closure.**

Phase 7 should introduce an authoritative identifier/barcode model, normalized tenant-safe SKU/barcode constraints, exact actionable-line/bin resolution, a real scanner abstraction, durable unknown-scan reporting, and close the remaining Receive/Dispatch/Count exception UX gaps. It must preserve Phase 6 durable drafts/outbox and all Phase 1-5 server invariants.
