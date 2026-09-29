# Phase 4 - Atomic Document Commands, Idempotency, and Server Deltas

## Purpose

Phase 4 turns the Phase 3 authoritative warehouse documents into the only supported stock-posting boundary for transfer shipment/receipt, sales dispatch, and count finalization. It preserves the Phase 1 authentication/tenant boundary and Phase 2 canonical stock model while removing line-oriented document stock posting from the legacy generic inventory RPC.

Implementation commit: `8e8e74038fe6d9defc99a6036122135280fe6c8e`
Migration: `supabase/migrations/20260917200000_phase4_atomic_document_commands.sql`

## Command ledger and idempotency

`inventory_document_commands` is the durable document-command ledger. Its stable client command key is a UUID unique within the company and is independent of command type. The server computes the request fingerprint from command type, authoritative document id, expected document revision, command options, and the immutable client-recorded timestamp. A client does not supply the fingerprint.

First submission uses `INSERT ... ON CONFLICT DO NOTHING`, so simultaneous calls with the same company + client command id converge on one command record. Reuse with different canonical content returns `IDEMPOTENCY_KEY_REUSED`. Completed/terminal commands return a duplicate/replayed result rather than reapplying stock. Transient outcomes may be retried with the same stable command id and same canonical payload.

## Transaction boundary

Each public business command acquires/identifies the durable command first, then performs document locks, validations, stock/reservation/transit mutation, movement append, and document-state advancement inside one PL/pgSQL exception subtransaction. If any business mutation fails, that subtransaction rolls back as a unit while the outer command record receives a typed terminal outcome.

Typed outcomes are:

- `accepted`
- `duplicate`
- `conflict`
- `validation_error`
- `authorization_error`
- `transient_error`

## Transfer shipment

`ship_transfer_document`:

- derives actor/company from the authenticated server context;
- locks the transfer document and non-cancelled lines;
- validates assignment, source warehouse permission, revision, current warehouse/bin activity, and reservation protection;
- calculates the only permitted delta as `expected_base_quantity - shipped_base_quantity`;
- deducts AVAILABLE stock under lock;
- appends one `TRANSFER_OUT` movement with transfer-line and document-command provenance;
- creates/advances authoritative in-transit custody;
- advances shipped quantity and document revision atomically.

A fresh command cannot ship quantity already represented by `shipped_base_quantity`.

## Transfer receipt

`receive_transfer_document`:

- locks the transfer and validates destination receive permission and revision;
- blocks uncaptured required lines by default; explicit partial posting is possible only with `allow_partial=true`, and unresolved lines remain authoritative outstanding state;
- calculates delta as `captured_received_base_quantity - posted_base_quantity`;
- requires linked in-transit custody and rejects receipt above remaining transit;
- refuses condition/identity exceptions that do not have a safe stock disposition model;
- posts accepted quantity to destination AVAILABLE stock;
- appends `TRANSFER_IN` movement with line provenance and client physical-action timestamp;
- advances transit received state, posted quantity, and transfer status atomically.

A fresh command id cannot reapply already-posted receipt quantity.

## Sales dispatch

`dispatch_sales_order`:

- locks the order and lines;
- validates revision, assignment, dispatch permission, current source warehouse/bin activity, and `allow_direct_sales`;
- requires every non-cancelled line to account for the complete request through captured pick + durable backorder;
- calculates stock delta as `captured_picked_base_quantity - posted_base_quantity`;
- locks active reservations and AVAILABLE balance;
- protects other documents' reservations, including location-level reservations;
- rejects contradictory reservation provenance where a reservation linked to the line points at a different physical bin;
- fulfills the order line's own reservation deterministically and releases only its remaining authoritative reservation after the line is fully accounted;
- appends `SALE` movement with authoritative order-line provenance;
- advances order lines and order state atomically.

## Count finalization

`finalize_count_session`:

- requires every applicable count line to be resolved/ready;
- loads the latest immutable observation;
- requires durable supervisor approval for every non-zero variance;
- locks current physical stock and verifies the expected physical snapshot/revision still matches;
- writes only the approved variance using `STOCK_COUNT_VARIANCE_IN` or `STOCK_COUNT_VARIANCE_OUT`;
- writes no zero-quantity movement for a zero variance;
- preserves observation client-recorded time and approving actor in movement history;
- finalizes count lines and session only after stock mutation succeeds.

## Movement provenance

Phase 4 movements carry:

- `document_command_id`;
- authoritative transfer/order/count line id;
- source document type/id/reference;
- authenticated performed-by actor;
- approving actor where applicable;
- client physical-action timestamp.

Free-form reference numbers remain human labels rather than the primary relationship.

## Legacy path cut-off

The Phase 2 generic JSON stock function is retained internally for non-document adjustment/status operations, but application RECEIVE, DISPATCH, and COUNT through `post_inventory_operation` now fail closed. The legacy LocalForage queue also refuses these operation types. This prevents old line-oriented posting from bypassing Phase 4 while the later offline/workflow phases migrate the UI to durable document commands.

## Security hardening

- Internal Phase 4 movement/idempotency helpers are revoked from ordinary app roles.
- The command ledger is read-only to authenticated clients and RLS-scoped to the initiating actor.
- Command-status lookup requires an explicitly requested company plus current actor membership and command ownership.
- Current source/destination warehouse and bin activity is revalidated at execution time rather than trusting stale document references.

## Verification assets

- Static verifier: `scripts/phase4_verify.mjs`
- Existing-data preflight: `supabase/preflight/phase4_existing_data.sql`
- pgTAP regression suite: `supabase/tests/phase4_atomic_document_commands.sql` (36 assertions)
- DB runner: `scripts/phase4_db_test.sh`
- CI database job: `.github/workflows/database-tests.yml`

## Deliberate remaining boundaries

Phase 4 does not yet redesign the LocalForage outbox or migrate the legacy workflow screens to durable document-command records. Those paths fail closed for document stock mutation. Stable command creation/persistence, crash recovery, conflict UX, causal ordering, and reconciliation with workflow UI remain future phases.

Phase 4 also does not implement a general movement reversal/correction command. Undefined reversal semantics remain fail closed for Phase 5.
