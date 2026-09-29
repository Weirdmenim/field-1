# FieldOne Architecture Decision Log

## D-0001 - Preserve rather than rewrite the reviewed baseline
Status: Accepted
Phase: 0
Decision: All remediation proceeds from Git-preserved baseline history with additive migrations and explicit handoffs.
Rationale: Inventory systems cannot safely lose provenance while being repaired.

## D-0002 - Server identity is the trust anchor
Status: Accepted
Phase: 1
Decision: Actor/company authorization is derived from `auth.uid()` and memberships; client identity fields are not trusted.

## D-0003 - Inventory is modeled by physical status buckets plus separate reservations/transit
Status: Accepted
Phase: 2
Decision: Physical balance rows represent status buckets by bin. Reservations and transit are first-class separate records. ATP subtracts active reservations from AVAILABLE physical.

## D-0004 - Compatibility data is preserved explicitly
Status: Accepted
Phase: 2
Decision: Existing stock is backfilled to deterministic SYSTEM bins, legacy reservations become LEGACY_BALANCE reservations, and legacy UOMs are made explicit rather than discarded.

## D-0005 - Unsafe operations fail closed until their authoritative workflow exists
Status: Accepted
Phase: 2
Decision: COUNT, ambiguous ADJUSTMENT, and undefined transfer reversal semantics are rejected instead of guessing stock effects.

## D-0006 - Project context is repository-owned
Status: Accepted
Phase: 3 preparation
Decision: `docs/project/*`, phase handoffs, the remediation matrix, immutable tags, and verification evidence collectively form the durable project memory. Chat history is not required to continue safely.

## D-0007 - Warehouse documents are specialized authoritative entities
Status: Accepted
Phase: 3
Decision: Transfers, sales orders, counts/observations/approvals, and backorders use specialized server entities with stable IDs/revisions rather than one generic untyped document table.
Rationale: Each workflow has materially different lifecycle, quantity, approval, and custody invariants that should be constrained explicitly.

## D-0008 - Phase 3 records intent; Phase 4 owns stock effects
Status: Accepted
Phase: 3
Decision: Phase 3 capture/approval commands must not mutate balances or append movement history. Phase 4 will consume authoritative documents atomically with stock/reservation/transit.
Rationale: Separating evidence/document state from ledger mutation prevents partial fixes and makes the final transactional boundary explicit.

## D-0009 - Blind count is an API/data-access property
Status: Accepted
Phase: 3
Decision: Application roles cannot directly read count base tables, and the count RPC withholds expected quantity/revision before observation unless the actor has approval permission.
Rationale: A blind count cannot be technically enforced if expected quantities are already delivered to the ordinary counting client.

## D-0010 - Historical provenance is never invented
Status: Accepted
Phase: 3
Decision: Existing reservation/transit/history rows are linked to authoritative document lines only when the relationship is supported by reviewed data; unmatched legacy rows remain explicit reconciliation work.
Rationale: Convenient but fabricated links would damage the audit trail we are trying to repair.

## D-0011 - Business-document idempotency uses a separate authoritative command ledger
Status: Accepted
Phase: 4
Decision: Transfer, sales-dispatch, and count-finalization commands use `inventory_document_commands` with a company-scoped UUID command id independent of legacy `inventory_operations.operation_type` uniqueness.
Rationale: Idempotency must identify the business action, not a line RPC or operation-type tuple.

## D-0012 - Business failure rolls back stock while preserving typed command outcome
Status: Accepted
Phase: 4
Decision: Command acquisition is outside the PL/pgSQL business subtransaction; stock/document/reservation/transit effects are inside it. Caught business failures roll back those effects and persist a typed command outcome.
Rationale: Partial stock commits are unacceptable, while deterministic retry/conflict information must remain auditable.

## D-0013 - Authoritative posted/shipped state is the final duplicate defense
Status: Accepted
Phase: 4
Decision: Every stock delta is calculated from server-owned expected/captured quantity minus already shipped/posted quantity under lock.
Rationale: Stable idempotency protects retries, but a brand-new key must also be unable to reapply cumulative document state.

## D-0014 - Legacy document posting fails closed until durable command outbox/UI cutover
Status: Accepted
Phase: 4
Decision: RECEIVE, DISPATCH, and COUNT are rejected by the generic inventory posting path and legacy queue. The compatibility RPC remains only for explicitly supported non-document adjustments/status changes.
Rationale: Temporarily blocking an old workflow is safer than allowing it to bypass the new authoritative transaction boundary.

## D-0015 - Client physical-action time is immutable command content
Status: Accepted
Phase: 4
Decision: `client_recorded_at` is included in the server-computed command fingerprint and is propagated to movement history.
Rationale: Retry must not silently rewrite when the physical warehouse action occurred.

## D-0016 - Posted movement history is database-enforced append-only
Status: Accepted
Phase: 5
Decision: `inventory_movements` rejects UPDATE/DELETE through a database trigger; browser/application/service roles do not receive direct movement mutation privileges. Corrections append new compensating history.
Rationale: Audit history is not trustworthy if posted movement rows can be silently edited or deleted.

## D-0017 - Generic reversal is deliberately narrower than document correction
Status: Accepted
Phase: 5
Decision: `reverse_inventory_movement` supports only structurally safe standalone movements. Any movement linked to an authoritative transfer/order/count/document command returns `DOCUMENT_CORRECTION_REQUIRED`.
Rationale: Reversing only the ledger row would desynchronize document progress, reservations, transit, approvals, and stock history.

## D-0018 - No persistent administrative ledger bypass
Status: Accepted
Phase: 5
Decision: Exceptional repairs use a reviewed database-owner runbook and one-off compensating migration; Phase 5 does not create an always-available admin RPC that can edit/delete history or bypass document semantics.
Rationale: A permanent repair escape hatch would recreate the same integrity boundary the remediation is intended to remove.

## D-0019 - Conservative downstream-activity rule for historical reversal
Status: Accepted
Phase: 5
Decision: A generic historical reversal is blocked once later non-reversal movement activity touches an affected product/location/bin/status position. Direct partial reversals of the same original are excluded from this downstream test.
Rationale: After subsequent physical work has depended on a position, simply inverting an older movement can misrepresent custody and causality.

## D-0020 - Offline truth is drafts + record-per-command outbox + snapshots
Status: Accepted
Phase: 6
Decision: Workflow drafts, executable commands, and last-known server snapshots/freshness are separate durable stores. The outbox is record-per-command and owner scoped.
Rationale: A whole-array queue and React-only work-in-progress cannot safely survive concurrent enqueue/drain, crash, restart, or account/context switching.

## D-0021 - Cross-context processing uses Web Locks with atomic IndexedDB lease fallback
Status: Accepted
Phase: 6
Decision: Browser contexts coordinate through Web Locks where supported; fallback ownership is acquired/renewed in native IndexedDB transactions rather than LocalForage read/modify/write.
Rationale: Process-local flags and non-atomic storage locks do not serialize two tabs/windows/service-worker contexts.

## D-0022 - Stable command identity is local business-action identity
Status: Accepted
Phase: 6
Decision: A Phase 4/5 command UUID is created and persisted when the local action is created and reused for retry/reconnect/restart.
Rationale: Generating identity during posting/retry defeats idempotency and can reapply physical warehouse work.

## D-0023 - Blind count preserves observation first, reason second when offline
Status: Accepted
Phase: 6
Decision: A blind observation may temporarily store `PENDING_REASON` when the client cannot know variance before submission, but the database rejects approval until the operator records a real discrepancy reason.
Rationale: Blindness and durable offline evidence must coexist without allowing supervisor approval of unexplained variance.

## D-0024 - Malformed persisted commands are quarantined before removal from execution
Status: Accepted
Phase: 6
Decision: V2 outbox records undergo runtime shape/command validation. Invalid records are copied to quarantine and excluded from execution rather than trusted through TypeScript assertions or silently discarded.
Rationale: Persisted state crosses application versions and may be corrupt; the mutation boundary must fail closed without losing forensic/recovery evidence.

## D-0025 - Sync UI is a projection of durable command truth
Status: Accepted
Phase: 6
Decision: pending/syncing/failed/conflict/blocked/confirmed state and freshness come from persisted command outcomes. Conflict UI may show only real stored error/result data.
Rationale: Warehouse operators must not act on fabricated confirmation, timestamps, revisions, quantities, or actors.

## Phase 7 decisions

- Use one exact normalized identifier namespace per company across canonical SKU and active barcode/GTIN/alias values. Cross-product collisions fail at the database boundary.
- Keep SKU on `products`; keep alternate production identifiers in `product_identifiers`. Do not model a live barcode as `barcode = sku` in the client.
- Resolve transactional scans server-side to authoritative document lines. If more than one actionable line/bin matches the product, return `ambiguous`; never guess the first line.
- Support standards-based browser camera acquisition through `getUserMedia` + `BarcodeDetector` when available and keyboard-wedge scanners universally through key events. Unsupported camera decoding falls back to hardware scanner or exact manual entry.
- Unknown scans use the Phase 6 durable outbox with stable event UUIDs so offline reporting is replay-safe.
- Do not fabricate a damaged/wrong/unexpected receipt disposition merely to complete Phase 7. Phase 4 correctly blocks those stock effects; an explicit future document-correction/disposition command is required.

## Phase 8 decisions

- Use active backend probing instead of treating browser network state as server reachability.
- Fail closed when durable storage is unhealthy and surface the condition globally; never clear pending data as automatic recovery.
- Cache only same-user operational context for cold offline startup; authentication identity remains the trust anchor.
- Cache the real post-build same-origin resource set through service-worker messages instead of guessing Vite hashed asset names.
- Resolve receipt exceptions through explicit authoritative dispositions rather than mapping UI exception labels directly to arbitrary stock mutations.
- Preserve legacy non-UUID transaction IDs as historical data while constraining all new canonical operation identities.
- Retire the generic JSON stock posting path instead of attempting another compatibility-layer idempotency patch.
- Keep F-042/F-043 open: document revision rebasing is not equivalent to explicit physical-balance/reservation revision preconditions.


## Phase 9 decisions

- Use explicit per-position physical and reservation revisions rather than a client-computed availability number. Availability is derived; revisions are conflict preconditions.
- Use transaction-scoped advisory position locks shared by validators and writers so an absent balance/new reservation cannot race between validation and mutation.
- Preserve Phase 4 command UUID as business identity and store Phase 9 preconditions in a companion immutable ledger instead of changing historical command semantics.
- Revoke legacy app-facing final-stock RPCs after introducing v2 wrappers; do not leave a bypass around revision validation.
- Keep runtime-test findings OPEN when infrastructure blocks execution. Authored harnesses and static controls are not substitutes for the requested concurrency/restart/browser evidence.

## D-0026 - Phase 10 is an evidence phase, not an architectural rewrite
Status: Accepted
Phase: 10
Decision: Preserve all Phase 1-9 authority boundaries and add only test fixtures, proof harnesses, CI/release automation, reconciliation and handoff material unless an executed runtime proof demonstrates a real defect.
Rationale: The only remaining findings are runtime-proof gaps; changing production architecture without evidence would create avoidable risk.

## D-0027 - Release proof is all-or-nothing and evidence-producing
Status: Accepted
Phase: 10
Decision: `scripts/phase10_release_candidate.sh` is the canonical release gate and writes `RELEASE_GATE_PASSED.txt` only after clean install, cumulative static/database verification, all five runtime proofs, browser/app proof and final reconciliation succeed.
Rationale: Partial green checks must not be mistaken for release readiness.

## D-0028 - Fault injection must prove rollback after business mutation has begun
Status: Accepted
Phase: 10
Decision: F-149 uses both a second-movement injected database failure and a killed client while an AFTER-movement trigger holds the transaction open; both must leave zero partial business residue.
Rationale: Failing before the first mutation does not prove mid-batch atomicity or crash rollback.

## D-0029 - No Phase 11 is created merely for external execution
Status: Accepted
Phase: 10
Decision: External execution and final release disposition remain Phase 10. A later architectural phase is created only if runtime evidence exposes a genuinely new design problem.
Rationale: Phase numbering should represent substantive remediation scope, not the machine on which evidence is collected.


## ADR-P11-001 — Separate historical closure from program baseline approval

**Decision:** Preserve the historical 186-finding remediation matrix while introducing an explicit program-approval state. Phase 10 can remain historically recorded as completed, but the ERP program baseline remains `NOT_SEALED` until a clean canonical release run is independently validated by the Phase 11 evidence audit.

**Why:** The supplied archive contains successful Phase 10 evidence and a failed F-157 browser log at the same time. Rewriting history would destroy traceability; blindly accepting the summary would destroy audit integrity.

## ADR-P11-002 — Canonical release execution uses portable Bash proofs

**Decision:** The Phase 10 release-candidate runner uses the existing portable Bash/PostgreSQL proof scripts for F-147/F-149/F-157 instead of workstation-specific Node wrappers. Compatibility Node wrappers may remain but delegate to the canonical shell proof.

**Why:** The previous Node wrappers embedded a Windows PostgreSQL path and some wrote assertion source files during execution, while CI runs on Ubuntu.

## ADR-P11-003 — Failed evidence is preserved between release attempts

**Decision:** Before a new canonical release attempt, an existing evidence directory is moved to a timestamped sibling rather than reused.

**Why:** Reusing a directory can mix stale PASS artifacts with a later failed run and produce an ambiguous evidence bundle.
