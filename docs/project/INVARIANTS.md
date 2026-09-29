# FieldOne Non-Negotiable Invariants

These rules are cumulative. Later phases may add stricter requirements but must not weaken earlier ones.

## Phase 0 - preservation and traceability

- The original reviewed snapshot remains recoverable through Git tag `pre-inventory-remediation` and preservation artifacts.
- All 186 audit findings remain in `docs/remediation/REMEDIATION_MATRIX.csv`; findings are never deleted to make progress look better.
- Every phase records implementation, migration, regression test, and verification evidence separately.

## Phase 1 - identity, tenant, and authorization boundary

- Actor and tenant authority come from authenticated server identity (`auth.uid()`) plus server-side memberships.
- Client-provided `user_id` and `company_id` are never authorization facts.
- Warehouse/location selection is requested context, not authorization; server commands verify active membership and permission.
- Application roles do not directly write inventory balances, operations, or movement history.
- Tenant-scoped relationships remain tenant-safe.
- Tenant-sensitive React Query keys include company/location context and incompatible cache is invalidated on context changes.
- Offline command ownership is authenticated user + company + warehouse; ownerless legacy work is quarantined, never silently reassigned or deleted.

## Phase 2 - canonical inventory model

- Physical balance key is company + location + bin + product + inventory status.
- Physical on-hand is the sum of physical status buckets; AVAILABLE, DAMAGED, and BLOCKED are distinct authoritative buckets.
- Reservation truth is `inventory_reservations`; deprecated embedded reservation quantity remains zero.
- Available-to-promise = AVAILABLE physical - remaining active reservations.
- In-transit custody is separate from on-hand until an authoritative receipt transition completes.
- Every product has an active authoritative base UOM and default sale UOM; server conversion validates ownership, scale, step, and quantity.
- Movement rows carry bin/UOM/status structure and obey movement-type shape constraints.
- Negative stock is permitted only for AVAILABLE where the warehouse policy explicitly permits it; DAMAGED/BLOCKED never go negative.
- Production inventory reads use canonical views and never replace errors/empty tenants with fixture stock.
- `SYSTEM` bins and `LEGACY_BALANCE` reservation rows are compatibility artifacts; they are not deleted until a later reconciliation proves retirement safe.
- Direct COUNT mutation stays rejected until count observation/variance/approval commands exist.
- Generic ambiguous ADJUSTMENT stays rejected; explicit adjustment-in/out semantics are required.
- Undefined reversal semantics stay fail-closed until an explicit validated reversal command exists.

## Phase 3 entry constraints

- Authoritative warehouse documents must reference Phase 2 company/location/bin/product/UOM entities using tenant-safe relationships.
- Document/line state is server truth; React fixture state may not be promoted as authoritative.
- Stable document and line IDs must exist before Phase 4 idempotent commands are built.
- Phase 3 records workflow intent/state only; it must not reintroduce unsafe generic stock mutation.
- Posted/remaining quantities must be modeled explicitly so Phase 4 can calculate deltas without cumulative reposting.

## Phase 3 - authoritative warehouse documents

- Transfers, sales orders, count sessions/observations/approvals, and backorders are authoritative server entities with stable document/line identity and revision state.
- Captured transfer/sales line outcomes are immutable through normal recapture; corrections require later explicit correction/reversal semantics.
- Server-derived remaining quantities, not client arithmetic, are the basis for future stock deltas.
- Sales captured quantity plus authoritative backorder quantity cannot exceed requested quantity.
- Count observations are immutable evidence containing the authoritative expected snapshot/revision at observation time; explicit zero is valid evidence.
- Count approval/rejection/recount is a durable permission-gated state machine and does not itself rewrite observation history.
- Ordinary counting clients do not receive blind expected quantity before observation through the application API.
- Document capture/approval in Phase 3 never updates `inventory_balances` and never inserts `inventory_movements`.
- Reservations/transit/movements may link to authoritative document lines only when provenance is real; historical relationships are never invented.

## Phase 4 - atomic document commands and ledger posting

- Document stock posting uses a company-scoped UUID `client_command_id` independent of command type; the server computes and owns the canonical fingerprint.
- Immutable command content includes command type, authoritative document, expected document revision, command options, and client-recorded physical-action timestamp.
- First command acquisition is atomic; same-key retries replay/inspect the existing command and same-key/different-content reuse fails closed.
- Document stock effects are atomic across all applicable lines; business mutations roll back together on validation/conflict/auth/transient failure while a typed command outcome remains auditable.
- Authoritative stock delta is always derived server-side from captured/expected state minus already shipped/posted state. A fresh idempotency key does not permit cumulative reposting.
- Generic application RECEIVE/DISPATCH/COUNT posting remains disabled; document stock changes go through Phase 4 business commands only.
- Transfer shipment moves source on-hand into explicit transit custody; transfer receipt consumes only linked remaining transit before increasing destination on-hand.
- Sales dispatch locks current stock/reservations, protects other work, fulfills/releases only the authoritative sales-line reservation, and fails closed on contradictory bin provenance.
- Count finalization applies only approved non-stale variance; zero variance creates no zero-quantity movement.
- Phase 4 movement rows carry document command id, authoritative line provenance, authenticated actor, and client physical-action timestamp.
- Current warehouse/bin activity and permission/policy are revalidated at command execution time.
- Document command audit access is actor-scoped; internal command/movement helpers remain unavailable to ordinary app roles.

## Phase 5 - append-only ledger and validated corrections

- Posted `inventory_movements` rows are append-only; normal correction never UPDATEs or DELETEs historical movement rows.
- Ordinary application and service-role access cannot directly INSERT/UPDATE/DELETE/TRUNCATE movement history; stock effects remain command-owned.
- Eligible standalone reversals use a company-scoped UUID command identity with server-computed immutable fingerprint, authenticated actor, explicit reason, and client physical-action timestamp.
- The original movement is locked before reversible quantity is calculated; full/partial reversal quantity is derived from already-appended compensating movements and cannot exceed the original.
- Reversal movement provenance includes the original movement and the Phase 5 ledger command; tenant/product consistency is database constrained.
- A generic reversal exactly inverts the original location/bin/status physical shape and must use a permitted inverse movement type.
- Reversal-of-reversal is prohibited through the generic command.
- Reversal source stock, active warehouse/bin state, and active reservations are revalidated under lock before stock is removed.
- Later non-reversal activity on an affected position blocks generic historical reversal; direct partial reversals of the same original remain eligible if no other downstream activity occurred.
- Document-linked transfer/sales/count movements never use generic movement reversal; they fail closed with `DOCUMENT_CORRECTION_REQUIRED` until a document-specific correction command reconciles both document and ledger state.
- Emergency repair never rewrites movement history and does not use a persistent admin bypass RPC; reviewed one-off compensating migrations follow the Phase 5 repair runbook.

## Phase 6 - durable offline execution and authoritative workflow cutover

- Durable workflow state is separated into versioned owner-scoped drafts, executable outbox commands, and persisted server snapshots/freshness; React component state is not the only copy of warehouse work.
- The executable outbox is record-per-command. Whole-array read/modify/write is not an accepted queue architecture.
- Every executable command belongs to authenticated user + company + warehouse. Ownerless legacy or malformed records are quarantined and never silently reassigned or auto-submitted.
- Persisted V2 commands are runtime validated before execution; corrupt/unknown command records are removed from the executable outbox only after preservation in quarantine.
- Stable business command UUID is created with the local action and reused through retry/reconnect; retry never invents a new identity for the same action.
- Causal dependencies are durable; successors cannot overtake failed/conflicted/unconfirmed prerequisites.
- In-flight work is lease claimed. Expired claims recover deterministically to retryable state with the same command identity.
- Multi-context execution is serialized through Web Locks where available or an atomic IndexedDB lease with renewal; an in-memory React flag is never treated as a mutex.
- Retry count, typed last error, next-attempt time, exponential backoff/jitter, lease metadata, server result, and confirmation time are durable command state.
- Conflict is blocked from ordinary retry. Resolution never deletes movement history or fabricates server state.
- RPC requests have bounded abortable timeouts; a hung request cannot leave an outbox command permanently syncing.
- Receive, Dispatch, and Count use authoritative Phase 3 documents and Phase 4 commands. Generic document stock posting remains disabled.
- Sync Center/freshness derives from persisted command state and confirmation timestamps; it never claims fully synced while relevant commands remain active/failed/conflicted/blocked.
- Blind count may persist a temporary `PENDING_REASON` only to preserve offline observation evidence; approval remains database-blocked until a real variance reason is recorded.
- Phase 6 offline orchestration never UPDATEs/DELETEs Phase 5 movement history and never weakens the Phase 1-5 server authority boundaries.

## Phase 7 - production identifier and scanner integrity

- Transactional product resolution is exact, tenant scoped, and server authorized; substring/partial matching never selects a stock-mutating line.
- SKU and active BARCODE/GTIN/ALIAS namespaces cannot resolve to different products within the same company.
- Duplicate actionable product lines/bins produce explicit ambiguity and require exact line/bin selection.
- Scanner acquisition (camera or hardware wedge) is an input adapter only; it never writes balance or movement tables directly.
- Unknown scans are durable, owner/context scoped, idempotent by client event UUID, and retain raw/normalized code, actor, warehouse, document context, and physical timestamp.
- Successful production scanning does not rely on developer simulation controls.
- Non-shortage receipt condition/identity exceptions remain blocked from ordinary receipt finalization until an explicit authoritative disposition/correction exists.
- Count variance reasons are deliberately selected per attempt; recount clears stale local observation/reason state.

## Phase 8 - production hardening closure

- Backend reachability is established by an active bounded Supabase probe; `navigator.onLine` is only a scheduling hint.
- Durable storage errors are explicit and fail sync closed; recovery retries storage and never deletes pending warehouse work as a repair strategy.
- Cold offline operational context may be reused only for the same persisted authenticated user; owner-scoped snapshots remain tenant/location isolated.
- The service worker provides the application shell and observed same-origin build resources; production no longer depends on remote fonts or product placeholders.
- Catalog reads paginate until exhaustion and identifier reads batch large product sets.
- Conflict keep-local creates a new stable successor command UUID at the latest authoritative document revision; the old command remains cancelled audit history.
- Receipt condition/identity exceptions are business-complete only after an authoritative immutable disposition; rejected wrong/unexpected quantity never silently becomes AVAILABLE.
- The client-callable generic `post_inventory_operation(JSONB)` compatibility path remains revoked; executable idempotency/failure state lives in authoritative document/ledger command ledgers.
- New canonical inventory operation transaction IDs are UUID-shaped and company-unique; identity/fingerprint fields are immutable.
- At transaction commit, remaining active reservations cannot exceed non-negative AVAILABLE physical stock.


## Phase 9 - explicit stock/reservation revision preconditions

- Every public final stock command carries an explicit authoritative snapshot of physical-status revision plus bin-level and location-level active reservation revisions for every required stock position.
- A company-scoped stable command UUID has one immutable stock-precondition fingerprint; retries cannot rewrite the expected inventory snapshot.
- Balance and reservation writers acquire the same transaction-scoped position locks used by stock-precondition validation, including absent-row/new-reservation cases.
- A stale physical or reservation snapshot returns typed `STOCK_REVISION_CONFLICT`; it never silently posts against newer inventory.
- Conflict keep-local rebasing refreshes both authoritative document revision and stock/reservation revisions under a new stable command UUID.
- Legacy public final-stock RPCs remain revoked from application roles; clients use the revision-protected Phase 9 v2 command entry points.

## Phase 10 - external proof and release-gate discipline

- Runtime-only findings are promoted only from captured execution evidence; an authored harness, static audit, or environment-blocked run is never equivalent to a passing proof.
- The canonical Phase 10 gate runs clean install/typecheck/build, cumulative pgTAP, all five targeted runtime proofs, and invariant reconciliation as one fail-fast release workflow.
- F-147 concurrent-dispatch evidence must prove exactly one commit and one stale-stock conflict against a shared constrained position; mere absence of negative stock is insufficient.
- F-149 atomicity evidence must prove both deterministic mid-batch rollback and killed-client rollback, followed by safe same-command-id retry.
- F-153/F-154 browser evidence executes the actual production outbox module with real browser IndexedDB/Web Locks/BroadcastChannel/persistent-profile semantics; mocked in-memory queue behavior is not accepted.
- F-157 requires both authoritative PostgreSQL ambiguity and actual application line/bin selection; schema uniqueness alone is not accepted.
- Release reconciliation must be green after runtime proofs, and the five OPEN findings remain OPEN until the complete external evidence bundle is reviewed.


## Phase 11 - program truth and release evidence

- Historical remediation status and program-approved release status are distinct facts; one may not be inferred from the other.
- A release baseline is SEALED only when its canonical runtime gate and machine evidence audit both pass on the same recorded commit.
- Missing release evidence is never interpreted as PASS.
- Failed evidence is preserved; a subsequent run must not silently overwrite the forensic record.
- The canonical release runner is portable across its supported environment and may not depend on a developer-specific absolute path.
- Verification is read-only with respect to product source code; test execution may create evidence artifacts but may not generate or rewrite production/assertion source files.
- CI and supported local execution invoke the same canonical release command.
- Phase 12 ERP expansion is blocked until the Phase 11 truth gate seals the inventory baseline.
