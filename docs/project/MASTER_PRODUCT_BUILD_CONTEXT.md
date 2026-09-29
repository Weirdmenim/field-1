# FieldOne Master Product Build Context & Phase Governance Handbook

**Durable context, phase-entry rules, implementation discipline, release governance, and market path for FieldOne ERP**

Version 1.0 — 25 September 2026

---

# 1. Purpose of This Document
This handbook is the durable program-control layer for the FieldOne product. It exists so a new chat, engineer, reviewer, or implementation phase can recover the project accurately without depending on conversational memory.

It does not replace the repository’s detailed context files. It tells future work how to interpret them, what must be true before a phase starts, how the phase must be executed, what evidence is required, and how the result must be handed off.

> **Operating rule:** A future phase is not allowed to start because the previous phase “looks done.” It starts only when the recorded entry gate is satisfied with reproducible evidence.

## What this handbook must prevent

- Context drift between chats or engineers.
- A new phase silently weakening an invariant established by an earlier phase.
- Feature work starting while the baseline, migrations, tests, or release evidence are uncertain.
- A frontend implementation becoming an accidental source of business truth.
- Premature expansion into generic ERP features before FieldOne’s warehouse and financial foundations are trustworthy.
- A phase being called complete because screens exist while data integrity, security, reconciliation, recovery, observability, or migration safety remain unproven.
- Marketing claims becoming stronger than the evidence supports.

## Who should use it

- Product owner / founder
- Engineering lead
- Database/backend engineer
- Frontend/mobile engineer
- QA / release engineer
- Security reviewer
- Accounting/finance reviewer
- Warehouse operations reviewer
- AI coding/review sessions used during development

# 2. Authoritative Context and Source-of-Truth Hierarchy

The existing repository continuity system remains authoritative for detailed implementation history. Future work must read the following in order before touching the product.

| Priority | Artifact | Purpose |
| --- | --- | --- |
| 1 | docs/project/PROJECT_STATE.json | Machine-readable current phase, branch/tag, gate status and next-phase disposition. |
| 2 | This handbook | Program strategy, phase protocol, target architecture, roadmap and market discipline. |
| 3 | docs/project/INVARIANTS.md | Non-negotiable rules accumulated from completed phases. |
| 4 | docs/project/DECISION_LOG.md | Architectural decisions and rationale. New decisions must append; old decisions are not silently overwritten. |
| 5 | docs/project/VERIFICATION_LEDGER.md | What actually ran, what passed, what failed, and what was blocked. |
| 6 | docs/project/PHASE_JOURNAL.md | Chronological implementation history and remaining constraints. |
| 7 | Most recent PHASE*_HANDOFF.md | Phase-specific implementation and restoration context. |
| 8 | Phase-specific plans/tests/evidence | Exact deliverables, commands, migrations, fixtures and runtime proof. |
| 9 | Git history/tags and immutable build artifacts | Exact source snapshots and forensic evidence. |

> **Conflict rule:** When documents disagree, do not pick the most optimistic status. Prefer reproducible runtime evidence, immutable source history, and the latest explicitly superseding decision. Record the conflict and resolve it in the current phase before building on the disputed assumption.

## Required startup reading for every new chat/phase

1. Read this handbook.
2. Read PROJECT_STATE.json.
3. Read INVARIANTS.md.
4. Read the latest phase handoff and verification ledger entry.
5. Read decision-log entries that affect the phase’s domains.
6. Inspect the actual code/migrations/tests for any invariant the phase will touch.
7. State the recovered baseline before proposing changes.

# 3. Current Program Baseline at the Start of the ERP Build

Repository status records Phase 10 as completed and all 186 remediation findings as CLOSED. The inventory remediation program established meaningful strengths: tenant-aware authorization, canonical inventory positions, authoritative warehouse documents, atomic stock commands, immutable movement history with compensating reversals, durable offline command processing, scanner/identifier support, stock-revision preconditions, and runtime-proof infrastructure.

However, the ERP program must not treat “186/186 closed” as sufficient evidence that the entire product is ready for unrestricted expansion. The supplied release archive contains status-file inconsistencies and does not itself contain the full preserved Phase 10 evidence bundle. Phase 11 therefore exists to reproduce, seal, and operationalize the baseline before new ERP domains depend on it.

## Claims that are prohibited until separately implemented and proven

| Do not claim | Use instead |
| --- | --- |
| Cryptographic inventory ledger | Append-only inventory movement ledger with controlled compensating reversals. |
| Double-entry inventory ledger | Authoritative inventory movement ledger. Reserve “double-entry” for balanced financial debit/credit posting. |
| Conflict-free synchronization | Durable offline synchronization with deterministic conflict detection, replay and recovery. |
| Full serial-number capability | Barcode/identifier resolution until serial-instance inventory is implemented. |
| Exhaustively tested product | Strong inventory/database verification plus explicitly listed remaining test scopes. |
| Fully production-hardened ERP | Production-oriented inventory/WMS kernel until platform, finance, operations, security and commercial gates are complete. |

## What FieldOne is today

FieldOne is best treated as an inventory and warehouse-execution kernel with unusually strong transaction discipline and offline-work foundations. It is not yet a complete ERP. Procurement, accounting, inventory valuation, commercial sales, banking, localization, reporting, implementation tooling and broad integration capabilities remain to be built.

# 4. Product North Star and Market Wedge

FieldOne should not attempt to win by becoming a generic ERP with the largest feature checklist. Established ERP and distribution platforms already combine financials, purchasing, warehouse management, sales, lot/serial tracking, replenishment, reporting and integrations. FieldOne needs a sharper reason to exist.

> **North-star positioning:** FieldOne will become an operations-first ERP for inventory-heavy distributors, wholesalers and multi-location businesses where warehouse accuracy, unreliable connectivity, fast mobile execution, financial traceability and local operational/compliance requirements matter.

## Initial target customer profile

- Inventory-led distributors and wholesalers.
- Multi-location businesses with warehouses, stores or branches.
- Businesses currently coordinating stock, purchasing and finance through spreadsheets, paper, chat and disconnected accounting tools.
- Operations that suffer from weak connectivity, delayed synchronization, stock discrepancies, slow receiving/counting/dispatch, or poor cross-location visibility.
- Businesses that value fast implementation and strong local/regional support over a massive global feature catalogue.

## Primary differentiation to protect

- Warehouse execution that remains safe and usable under degraded connectivity.
- Inventory correctness enforced at the authoritative data layer rather than by optimistic frontend assumptions.
- Traceability from physical movement to valuation and eventually to financial posting.
- Fast mobile workflows for receiving, scanning, counting, picking and dispatch.
- Localization/integration for the first market rather than superficial currency changes.
- Implementation speed: getting a real distributor from spreadsheets to reconciled live operations quickly.

# 5. Program-Level Non-Negotiables

These principles supplement the detailed repository invariants. A phase may strengthen them but may not weaken them without an explicit architectural decision, migration plan, compatibility strategy and independent review.

1. The database/server remains authoritative for inventory, financial posting, authorization-sensitive transitions and other core business facts.
2. Each business fact has one authoritative domain. Inventory owns physical stock; Procurement owns supplier commitments; Sales owns customer commercial commitments; Finance owns monetary accounting truth.
3. Posted or historical ledgers are reversed/compensated, not rewritten to hide history.
4. Offline capability is selective. Warehouse/field workflows may earn it; finance administration and back-office configuration do not inherit offline complexity automatically.
5. The existing inventory kernel is a protected compatibility boundary. No broad rewrite is allowed merely to make the new architecture look cleaner.
6. New domains should be modular, but FieldOne remains a modular monolith until proven scaling/team/domain pressure justifies service extraction.
7. No feature is complete because the UI works. Completion includes invariants, authorization, migrations, failure recovery, tests, auditability, observability, documentation and reconciliation where applicable.
8. Every change to production data structures follows expand → migrate/backfill → verify/reconcile → cut over → contract/remove later.
9. Every externally retried command that can create irreversible or duplicate business effects must have deliberate idempotency semantics.
10. Marketing language must not outrun verification evidence.

# 6. Target Product Architecture Principles

## Product surfaces

| Surface | Primary users | Responsibility |
| --- | --- | --- |
| FieldOne Field | Warehouse/field workers | Receive, put away, scan, count, pick, pack, dispatch, transfer, work offline and resolve sync issues. |
| FieldOne Back Office | Managers, procurement, sales, finance, administrators | Master data, purchasing, commercial sales, finance, reporting, approvals, configuration and audit. |
| Application/API layer | All product surfaces and integrations | Cross-domain orchestration, authorization-aware services, background jobs, integration contracts and event handling. |
| PostgreSQL/Supabase | Authoritative persistence | Transactional truth, RLS/data integrity, atomic inventory commands, ledgers, durable domain state. |
| Worker/integration runtime | Background execution | Outbox processing, async workflows, imports, fiscalization, notifications, reconciliation, webhooks and external connectors. |

## Architecture stance

- React/TypeScript can remain for product surfaces, but the existing simulated phone-shell navigation is not the ERP shell.
- Introduce a real application-service boundary as cross-domain orchestration grows. NestJS is a strong candidate, not a dogma.
- Do not casually bypass RLS with unrestricted service credentials. Preserve authenticated actor/tenant context or perform explicit server-side authorization.
- Use domain boundaries in code and data. Do not create a single generic “documents” table for purchase orders, sales orders, invoices, counts and payments.
- Use domain events/outbox records to decouple important post-transaction effects without prematurely adding Kafka/microservices.
- Reporting should evolve toward read models/materialized projections instead of unbounded dashboard queries against transactional ledgers.

## Domain ownership map

| Domain | Owns | Must not own |
| --- | --- | --- |
| Core / Organization | Tenants, legal entities, branches, locations, shared configuration | Inventory balances, sales prices, journals |
| IAM / Policy | Users, memberships, roles, permissions, scopes, approval authority | Business transaction truth |
| Catalog | Products, UOM, identifiers, categories, variants, tracking/costing configuration | Physical balances or GL entries |
| Inventory / WMS | Physical stock, bins, statuses, reservations, transit, warehouse execution | Customer commercial terms or GL balances |
| Procurement | Suppliers, requisitions, RFQs, POs, expected receipts | Direct stock mutation or payment ledger truth |
| Sales | Customers, quotations, orders, pricing, commercial commitment | Direct stock mutation or journal mutation |
| Finance | Chart of accounts, journals, AP, AR, tax, payments, valuation/financial truth | Physical stock quantity |
| Workflow / Controls | Approval policies, delegations, SoD, comments, escalations | Owning business records themselves |
| Integration | API/webhook/connectors, external identifiers, retries | Becoming a second source of domain truth |
| Reporting | Read models, analytics, exports | Mutating operational truth |

# 7. The Product-Build Method

> **Method name:** Evidence-gated, vertical-slice, modular-monolith development with protected domain invariants and continuous market validation.

## Why vertical slices

FieldOne will not build six months of abstract infrastructure and then discover that the business workflow is wrong. After the shared foundations are ready, major domains are proven through complete business loops that cross UI, authorization, database, accounting/valuation, audit, tests and reporting.

Example Procure-to-Pay slice: Purchase Order → approval → goods receipt → inventory movement → valuation → supplier bill → AP → payment → reconciliation. Example Order-to-Cash slice: Sales Order → reservation → pick/dispatch → COGS → invoice → AR → payment → reconciliation.

## Dual-track execution

| Product/market track | Engineering/delivery track |
| --- | --- |
| Customer discovery, design partners and workflow observation | Architecture, domain modelling and protected implementation |
| Prototype validation and task usability tests | Vertical slice build and automated verification |
| Pilot onboarding and data migration rehearsal | Release hardening, observability and reconciliation |
| Pricing/packaging and buying-process validation | Security, scalability and operational readiness |
| Case studies and referenceability | General-availability release gates |

# 8. Mandatory Phase Lifecycle

Every Phase 11+ follows the same lifecycle. The exact technical deliverables vary, but the governance does not.

## 8.1 Entry Gate — what must be ready before work starts

1. Previous phase is reproducibly green or its explicitly accepted exceptions are recorded.
2. PROJECT_STATE.json points to the exact baseline commit/tag.
3. Current invariants are read and conflicts with the proposed phase are identified.
4. The phase problem statement and business outcome are explicit.
5. Affected domains and authoritative data ownership are identified.
6. Existing data/migration implications are understood using production-like fixtures.
7. Required external expertise is available (for example accounting/tax/warehouse/security review).
8. Phase acceptance criteria and evidence plan are written before implementation.
9. Known risks and “stop-the-line” conditions are recorded.
10. No unresolved blocker from the previous phase invalidates this phase’s assumptions.

## 8.2 Phase Contract — what the phase must define

| Field | Required content |
| --- | --- |
| Objective | The business/system capability that will be true when the phase ends. |
| Why now | Dependency reason. Why this phase precedes later work. |
| In scope | Explicit features, migrations, services, tests and operational work. |
| Out of scope | Tempting adjacent work that must not leak into this phase. |
| Protected invariants | Prior rules that cannot be broken. |
| New invariants | Rules this phase introduces. |
| Domain ownership | Which module owns each new business fact. |
| Data model | New/changed entities, relationships, constraints and migration approach. |
| Commands/events | Authoritative mutations, idempotency semantics and emitted events. |
| Authorization | Permissions, policies, scopes and SoD/approval requirements. |
| Failure model | Expected failures, retries, partial failures, crash/restart behaviour and recovery. |
| Test matrix | Unit, DB invariant, integration, E2E, concurrency, failure, security and performance tests relevant to the phase. |
| Observability | Logs, metrics, traces, alerts and reconciliation signals. |
| Evidence | Files/artifacts that prove acceptance criteria. |
| Exit gate | Binary criteria that permit the next phase to start. |

## 8.3 Implementation sequence

1. Model the business process and invariants before designing screens.
2. Design additive schema/API changes and migration/backfill strategy.
3. Create tests for invariants and failure cases before or alongside implementation.
4. Implement authoritative commands/services first; UI consumes them rather than inventing truth.
5. Add observability and audit evidence as part of the feature, not after it.
6. Implement UI/UX around real workflows with representative data and permissions.
7. Run migration rehearsal and reconciliation on production-like data.
8. Run normal-path, boundary, concurrency, retry, failure-injection and security scenarios as applicable.
9. Conduct domain review (accounting, warehouse, security, etc.).
10. Freeze the phase only after exit evidence is preserved.

## 8.4 Exit Gate — what must be proven before proceeding

- All phase acceptance criteria are green.
- No protected invariant regression.
- Migration succeeds from the previous frozen baseline and is recoverable/rollback-safe according to the phase plan.
- Reconciliation proves the new model against the previous source where applicable.
- Security/tenant/authorization tests pass.
- Failure and retry semantics are proven where the workflow can be interrupted or retried.
- Performance is measured against a declared budget for critical operations.
- Observability can identify and diagnose meaningful failures.
- Documentation and operator runbooks are updated.
- Evidence bundle is immutable/preserved and tied to the exact commit/build.
- PROJECT_STATE, DECISION_LOG, PHASE_JOURNAL and VERIFICATION_LEDGER are updated.
- A handoff document tells the next phase exactly what is safe to assume and what remains intentionally open.

> **No partial promotion:** If the exit gate is not green, the phase stays open. Do not create the next phase merely to move unresolved verification or cleanup out of sight.

# 9. Mandatory Phase Artifacts and File Contract

Every phase should leave a small, predictable context packet. The names can be automated later, but the information must exist.

| Artifact | Purpose |
| --- | --- |
| PHASEXX_CHARTER.md | Objective, scope, dependencies, protected/new invariants, business outcome. |
| PHASEXX_IMPLEMENTATION_PLAN.md | Workstreams, sequence, schema/API changes, migration plan, owners. |
| PHASEXX_TEST_AND_EVIDENCE_PLAN.md | Acceptance criteria, test matrix, runtime proof, performance/security checks. |
| PHASEXX_RISK_REGISTER.md | High-risk assumptions, data risks, operational risks, mitigations and stop conditions. |
| PHASEXX_HANDOFF.md | What changed, how to restore/run it, exact commands, what remains open, next-phase assumptions. |
| Evidence bundle | Build/test logs, DB test output, E2E results, migration/reconciliation reports, hashes/manifests. |
| Decision log entries | All durable decisions created or superseded during the phase. |
| Updated PROJECT_STATE.json | Exact final commit/tag, phase disposition, gate status and next-phase contract. |

## Release manifest minimum

```text
release_id
commit_sha
git_tag
database_migration_head
build_artifact_hash
node/runtime versions
test suite results
security scan result
DB verification result
E2E result
reconciliation result
known accepted exceptions
evidence bundle location/hash
```

# 10. New-Chat / New-Engineer Bootstrap Protocol

When work moves to a new ChatGPT conversation or a new engineer, do not paste random old conversations. Attach or expose the current repository context packet and use a deterministic bootstrap request.

## Minimum files to attach/share

- This handbook.
- Current PROJECT_STATE.json.
- INVARIANTS.md.
- DECISION_LOG.md.
- VERIFICATION_LEDGER.md.
- Latest PHASE*_HANDOFF.md.
- The new phase charter/contract if already created.
- Relevant source archive/repository snapshot when code changes are required.

## Canonical bootstrap prompt

```text
You are continuing the FieldOne ERP program. Treat the attached Master Product Build Context & Phase Governance Handbook as the program-level operating contract. Read PROJECT_STATE.json, INVARIANTS.md, DECISION_LOG.md, VERIFICATION_LEDGER.md and the latest phase handoff before proposing changes. Recover and state the current baseline, protected invariants, open risks and the exact entry gate for the requested phase. Do not weaken completed-phase invariants, do not invent evidence, and do not start implementation until the phase entry gate is satisfied. Build the phase through additive migrations, authoritative domain commands, explicit authorization, failure recovery, tests, observability, reconciliation and an evidence-backed exit gate. If documents conflict, prefer reproducible evidence and record the discrepancy before proceeding.
```

## What the new chat must answer before coding

1. What phase are we in?
2. What exact baseline commit/tag is authoritative?
3. What can this phase safely assume from previous phases?
4. Which invariants are protected?
5. Which risks or unresolved evidence affect the phase?
6. What is in scope and explicitly out of scope?
7. What does “done” mean in evidence, not prose?
8. What would cause us to stop rather than proceed?

# 11. Change Control and Anti-Drift Rules

## Decision classes

| Class | Examples | Required control |
| --- | --- | --- |
| A — Invariant / ledger / tenant boundary | Stock authority, RLS trust model, posted journal mutability, command idempotency | Architecture decision + independent review + migration/reconciliation + full regression gate. |
| B — Domain model | New supplier/order/valuation entities; permission model | Phase decision + migration tests + domain reviewer. |
| C — API/workflow | New commands, events, approval policies | Contract tests + authorization/failure tests. |
| D — UI/UX | Navigation, screen design, workflow layout | Usability validation + E2E tests; no authority moved to client. |
| E — Cosmetic/internal | Copy, non-behavioural refactor | Normal review; prove no affected invariant when touching protected code. |

## Stop-the-line conditions

- The prior baseline cannot be reproduced.
- A migration can lose or silently reinterpret production data.
- A new feature requires bypassing authorization/RLS to function.
- A business transaction can partially commit without deliberate compensating semantics.
- The same retried command can produce duplicate financial/inventory effects.
- Inventory/valuation/GL reconciliation cannot be explained.
- A security review finds plausible cross-tenant data access or privileged-function abuse.
- Performance on the critical operational path exceeds the agreed budget with no mitigation.
- The team cannot state which domain owns the new business fact.
- The phase’s evidence contradicts its status record.

# 12. Cross-Cutting Quality Gates

## Testing layers

| Layer | Minimum purpose |
| --- | --- |
| Unit/domain | Pure calculations, policy logic, state transitions, edge/boundary cases. |
| Database invariant | Constraints, RLS, transactions, ledger/posting rules, reconciliation. |
| Service/integration | Cross-domain orchestration, idempotency, external boundaries and error mapping. |
| Browser/E2E | Critical real-user journeys with real authorization and backend state. |
| Concurrency/failure | Races, retries, crashes, timeouts, duplicate requests, partial external failure. |
| Security | Tenant escape, permission bypass, privilege escalation, unsafe function exposure. |
| Performance | Warehouse command latency, query/index budgets, queue backlog, high-volume posting/import. |
| Migration/restore | Upgrade from prior baseline, backfill correctness, backup restore, disaster recovery. |

## Production operations baseline

- Structured logs with correlation/command/document IDs.
- Metrics and traces for critical workflows.
- Actionable alerts, not log noise.
- Database backup/PITR and tested restoration.
- RTO/RPO targets before commercial GA.
- Runbooks for sync failure, stuck jobs, integration outages, migration rollback/recovery and reconciliation.
- Environment separation and secrets management.
- Release canary/rollback process once real customer traffic exists.

# 13. Master Roadmap: Phase 11 Through Market-Ready ERP

The roadmap is a dependency order, not a feature vanity list. Some foundational integration/reporting work will start earlier, but a phase is considered complete only when its stated business capability is end-to-end trustworthy.

| Phase | Outcome | Core work | Entry | Exit | Market track |
| --- | --- | --- | --- | --- | --- |
| 11 | Truth Gate & Inventory Baseline | Reproduce/seal Phase 10; fix release/evidence portability; benchmark and protect inventory kernel. | Phase 10 source available. | Clean-machine release is reproducible and evidence-backed. | Recruit/confirm warehouse design partners; document current workflows and pain baselines. |
| 12 | ERP Platform Foundation | Product shell, back office, routing, service boundary, observability, worker/outbox, environment/release platform. | Phase 11 green. | Existing inventory workflows run unchanged through the new platform; no kernel regression. | Prototype back-office IA with design partners; validate product positioning and implementation expectations. |
| 13 | Organization, IAM & Master Data | Legal entities/branches, policy-based IAM, customers/suppliers, product master, import framework. | Platform foundation stable. | A representative distributor can be configured and master data imported without DB surgery. | Run real anonymized customer data imports; measure onboarding friction. |
| 14 | WMS Excellence & Traceability | Serial/lot/batch/expiry, putaway, replenishment, pick/pack, quality/quarantine, stronger scanner/offline workflows. | Master data/tracking configuration exists. | A warehouse can complete a degraded-connectivity shift with accurate traceability and reconciliation. | Pilot with warehouse operators; benchmark task time/error rate against current process. |
| 15 | Financial Core & Inventory Valuation | COA, journals, periods, currency, tax primitives, valuation ledger, costing, reconciliation. | Product/stock semantics stable; finance reviewer engaged. | Balanced immutable posting; inventory valuation reconciles to GL control account. | Validate COA, costing and reporting with accountant/CFO design partners. |
| 16 | Procure-to-Pay | Supplier sourcing/PO/approval/receipt/bill/3-way match/payment, landed cost and supplier returns. | Finance + WMS foundations green. | Real purchase flows from PO through warehouse, AP and payment with reconciliation. | Paid/controlled pilot begins with selected distributors using purchasing + inventory. |
| 17 | Order-to-Cash | Quotation/order/pricing/credit/reservation/fulfilment/invoice/payment/returns. | P2P and finance stable enough for shared controls. | Revenue, AR, COGS, stock and cash reconcile through one traceable chain. | Expand pilot to daily sales operations; validate pricing/credit/returns workflows. |
| 18 | Banking, Tax & Localization | Banking/reconciliation and first-market localization/fiscalization (e.g., Nigeria) behind localization layer. | Core finance/business loops green. | Target-market business can run compliant financial operations without parallel spreadsheets for supported scope. | Compliance sandbox/UAT; local implementation partners and accountant review. |
| 19 | Workflow, Controls & Enterprise Audit | Conditional approvals, delegation, SoD, thresholds, reauthentication, audit export. | Real business flows reveal approval patterns. | Sensitive transactions have explainable authority, history and segregation controls. | Move from owner-led pilot to multi-role organizations; validate management controls. |
| 20 | Reporting, Analytics & Planning | Operational/financial read models, KPI reporting, aging, valuation, replenishment/planning. | Transactional truth stable. | Management reports reconcile to source ledgers and remain performant at target scale. | Use pilot KPI data to quantify ROI and create case studies. |
| 21 | Integration Platform | Public API, webhooks, connector framework and highest-value local/commerce/logistics/payment integrations. | Domain contracts mature. | Integrations are retry-safe, observable and do not create duplicate domain truth. | Launch integration partnerships and remove blockers to switching from incumbent tools. |
| 22 | Commercial & Operational Hardening | Onboarding, templates, opening balances, help/support, subscriptions, DR/SLOs, pentest, deployment/runbooks. | Core ERP workflows validated in pilots. | Repeatable customer implementation and support; production reliability/security gates satisfied. | Convert design partners/pilots to paid references; finalize packaging, pricing and GA criteria. |
| 23+ | Demand-Led Expansion | CRM, assets, expenses, projects, HR/payroll, manufacturing, POS, service/fleet only from validated market demand. | Core product has repeatable retention and sales motion. | Each extension has its own business case and phase contract. | Land-and-expand based on customer evidence, not generic ERP checklist pressure. |

# 14. Detailed Phase Guidance

## Phase 11 — Truth Gate & Inventory Baseline

Create a trustworthy, reproducible frozen baseline before ERP expansion.

### Entry readiness

Phase 10 source, migrations, context records and all available verification artifacts are present.

### Must deliver

- Reconcile Phase 10 status contradictions and evidence mapping.
- Make all release/runtime runners cross-platform and CI-reproducible.
- Generate/preserve immutable release manifest and evidence bundle.
- Add missing frontend/component/E2E/security/performance/restore tests needed for the baseline.
- Benchmark critical inventory operations and offline queue behaviour.

### Implementation approach

Change as little business logic as possible. Treat defects as Phase 11 baseline defects; fix authoritatively, add regression proof, rerun the complete gate.

### Exit gate

- Clean-machine provision/migrate/test/build/run passes.
- All evidence is tied to exact source/migration/build identifiers.
- No disputed status remains in context files.
- Inventory benchmark and restoration baseline recorded.

### Do not

- Do not start Procurement/Finance features.
- Do not rewrite the inventory model for aesthetics.

## Phase 12 — ERP Platform Foundation

Create the product/application platform around the protected inventory kernel.

### Entry readiness

Phase 11 release baseline is reproducible and sealed.

### Must deliver

- Separate Field and Back Office application shells.
- Introduce proper routing, shared contracts/design system and authorization-aware navigation.
- Establish application-service/worker boundary, transactional outbox pattern and integration conventions.
- Add structured logs/metrics/tracing, feature flags and environment/release practices.
- Define dedicated API exposure strategy without breaking existing inventory commands.

### Implementation approach

Strangle/encapsulate rather than rewrite. Move responsibility behind new interfaces while preserving proven inventory contracts.

### Exit gate

- Existing warehouse flows pass unchanged.
- Back-office shell can authenticate/authorize and navigate real server data.
- Observability and release pipeline cover both applications.

### Do not

- Do not introduce microservices.
- Do not route everything through privileged service-role access.

## Phase 13 — Organization, IAM & Master Data

Build the shared business identity and master-data layer every later ERP domain depends on.

### Entry readiness

Product platform and authorization integration are stable.

### Must deliver

- Organization/legal entity/branch/location hierarchy.
- RBAC + scopes + policy conditions/approval limits.
- Business-party model for customers/suppliers.
- Full product/UOM/category/variant/tracking/costing configuration.
- Robust CSV/Excel import with dry-run, mapping, validation and reconciliation.

### Implementation approach

Migrate additively from warehouse membership booleans; preserve existing permissions until equivalent policies are proven.

### Exit gate

- Representative customer setup succeeds without manual SQL.
- Cross-tenant and scope tests pass.
- Imports are repeatable/idempotent with actionable errors.

### Do not

- Do not delete existing authorization columns until cutover is proven.
- Do not over-generalize the party/product model beyond validated needs.

## Phase 14 — WMS Excellence & Traceability

Turn the existing warehouse kernel into a market-level execution product.

### Entry readiness

Product tracking configuration, locations and users are available from Phase 13.

### Must deliver

- Serial/lot/batch/expiry model and history.
- Quality/quarantine and inventory-status controls.
- Receiving/putaway/replenishment/picking/packing/shipping workflows.
- Guided scanner UX and hardware/browser testing.
- Offline stress, multi-device conflict and queue recovery.

### Implementation approach

Preserve existing position/ledger authority. Add traceability dimensions deliberately and test migration/performance impact before broad adoption.

### Exit gate

- End-to-end tracked-item genealogy.
- Degraded-connectivity warehouse shift passes.
- Critical task-time/error metrics meet pilot targets.

### Do not

- Do not claim serial/batch support before per-instance/lot history is authoritative.
- Do not make all back-office domains offline.

## Phase 15 — Financial Core & Inventory Valuation

Create monetary truth and a provable bridge between physical stock and the books.

### Entry readiness

WMS movement semantics are stable; accounting reviewer and target costing requirements are available.

### Must deliver

- COA/journals/journal lines/periods/currency/dimensions.
- Balanced immutable posting and reversal semantics.
- Inventory valuation ledger and cost application/adjustment rules.
- Posting rules from inventory events to financial effects.
- Subledger-to-GL reconciliation and accounting reports needed to verify the kernel.

### Implementation approach

Build the smallest correct accounting kernel, then validate it through real inventory events. Do not build an abstract finance cathedral disconnected from business flows.

### Exit gate

- Every journal balances.
- Posted periods/entries follow lock/reversal rules.
- Inventory valuation reconciles to GL control accounts under tested scenarios.

### Do not

- Do not reuse the inventory movement table as the GL.
- Do not select costing methods without ICP/accounting validation.

# 15. Phase 16–23 Execution Rules

## Phase 16 — Procure-to-Pay

- Implement PO/receipt/bill/payment as one traceable vertical slice.
- Goods receipt invokes inventory authority; Procurement never writes stock directly.
- Support partial receipt, tolerance, backorder, return and landed-cost scenarios before calling P2P complete.
- Three-way match and supplier balance must be explainable and reconcilable.

## Phase 17 — Order-to-Cash

- Separate commercial sales order from warehouse fulfilment documents.
- Pricing/discount/tax/credit decisions belong to Sales/Finance policies; stock reservation/fulfilment remains Inventory.
- Prove revenue, AR, COGS, inventory reduction and payment reconciliation from one order.

## Phase 18 — Banking/Tax/Localization

- Keep tax/local compliance behind localization contracts.
- Implement first-market requirements against official specifications and sandbox/UAT where available.
- Bank import/matching/reconciliation must preserve source statement evidence and controlled adjustments.

## Phase 19 — Workflow/Controls

- Build conditional approval policies from observed needs rather than generic BPMN complexity.
- Add delegation, thresholds, SoD, escalation, comments/attachments and sensitive-action reauthentication.

## Phase 20 — Reporting/Planning

- Reports are derived read models; they do not become transaction truth.
- Every financial report must reconcile to authoritative ledgers.
- Add forecasting/planning only after underlying stock/sales/purchase data quality is demonstrated.

## Phase 21 — Integrations

- Prioritize connectors that unblock sales or operations for the chosen ICP.
- Use idempotency, external IDs, retry/dead-letter handling and integration audit trails.
- Do not let an external connector bypass authoritative commands.

## Phase 22 — Commercial Hardening

- Optimize onboarding, imports, opening balances, templates, support and tenant administration.
- Complete pentest/DR/SLO/runbooks and production incident/release processes.
- Prove repeatable implementation with customers other than the original design partners.

## Phase 23+ — Expansion

- Only add modules with validated demand and a clear domain owner.
- Each extension receives its own phase contract and cannot weaken the core ledgers/authorization model.

# 16. Market Delivery Strategy — Build With the Market, Not Then for the Market

Engineering phases and market validation run in parallel. We do not wait until Phase 22 to discover whether customers will buy FieldOne, and we do not let early pilot requests override architectural invariants.

## Commercial stages

| Stage | When | Customer scope | Goal / evidence |
| --- | --- | --- | --- |
| Design partners | Phases 11–14 | 3–5 inventory-heavy businesses; at least one with difficult connectivity/multi-location operations | Observe workflows, obtain anonymized data, validate WMS wedge, baseline task time/error/stock discrepancy pain. |
| Technical alpha | Phase 14 | Internal + 1–2 cooperative warehouses | Run real warehouse shifts; prove offline/scanner reliability without depending on finance. |
| Controlled paid pilot | Phases 15–18 | 2–5 businesses with strong executive sponsor | Use P2P/O2C/finance on bounded live scope; reconcile daily; measure business outcome and support burden. |
| Private beta | Phases 18–21 | Small cohort in chosen segment | Repeat onboarding and operations across different businesses; validate integrations/localization/pricing. |
| GA readiness | Phase 22 | Reference customers plus new customers not involved in design | Demonstrate repeatable implementation, reliability, security, support, migration and sales motion. |
| Land and expand | Phase 23+ | Existing customer base + adjacent verticals | Add modules/integrations based on observed demand and retention/expansion economics. |

## Pilot discipline

- Do not use an unbounded “pilot” as disguised custom software development.
- Define the exact live business scope, data set, users, locations and reconciliation procedure.
- Keep a parallel recovery process until the relevant FieldOne module passes agreed stability/reconciliation gates.
- Log every workaround and classify it as product gap, implementation/configuration issue, data issue or customer-specific request.
- Require measurable success criteria: stock accuracy, receiving/picking/count time, order cycle time, reconciliation effort, stockout/backorder rate, user adoption and support incidents.
- Convert repeatable pain into product features; keep one-off customer peculiarities out of the core unless they reveal a general domain need.

## Commercial proof before broad GA

- At least several referenceable customers completing real end-to-end workflows.
- Repeatable onboarding with bounded professional-services effort.
- Documented migration templates from spreadsheets/common incumbent systems.
- A support model that does not require founders to inspect the database for normal operations.
- Pricing/packaging customers understand and can buy without bespoke engineering quotes for standard use cases.
- Evidence of retention/expansion value, not merely successful demos.

# 17. Product and Engineering Scorecard

The program should track both correctness and market usefulness. A technically elegant ERP that is slow to implement or painful to use is not exceptional.

| Category | Illustrative measures |
| --- | --- |
| Integrity | Inventory reconciliation variance; duplicate-command incidents; ledger/GL reconciliation breaks; cross-tenant/security incidents. |
| Warehouse UX | Receiving/pick/count time; scan success; task error/rework; offline recovery success; training time. |
| Reliability | Command latency; availability; sync backlog/age; job failure/retry; error budget; restore success. |
| Finance | Unreconciled subledger/GL items; close time; bank-reconciliation effort; posting exception rate. |
| Implementation | Time to configure tenant; data import error rate; days to first live workflow; professional-services hours. |
| Customer | Active users, workflow completion, support tickets, retention, expansion, referenceability, NPS/qualitative task satisfaction. |
| Commercial | Pilot-to-paid conversion; sales cycle; implementation margin; ARR/MRR; integration-driven wins/losses. |

# 18. Definition of an “Extraordinary” FieldOne Release

FieldOne is not extraordinary because it has more modules. It becomes extraordinary when the complete operating loop is unusually trustworthy and easy to run.

- A warehouse can receive, count, pick and dispatch quickly with intermittent connectivity without creating ambiguous stock truth.
- A manager can trace a physical movement to the business document, valuation effect and financial posting.
- A CFO/accountant can reconcile inventory, AP, AR, bank and GL without hidden database repairs.
- A customer can migrate from spreadsheets and begin operating without months of bespoke implementation.
- A security review cannot turn a frontend mistake into cross-tenant or privileged mutation access.
- A release is reproducible from source and produces evidence that another engineer can independently verify.
- The product solves a narrow target segment exceptionally well before expanding into adjacent ERP categories.

# 19. Immediate Next Action

> **Next phase:** Start Phase 11 — Truth Gate & Inventory Baseline. Do not begin Procurement, Finance or ERP feature expansion until the current inventory baseline can be reproduced and sealed under the new release/evidence standard.

## Phase 11 first-session checklist

1. Restore the exact Phase 10 source baseline and inventory context files.
2. Inventory every claimed Phase 10 evidence artifact and identify missing/non-portable pieces.
3. Reconcile PROJECT_STATE, VERIFICATION_LEDGER, PHASE10_TEST_STATUS, handoff and remediation-matrix status.
4. Repair the release runner so the same canonical command works in the declared CI environment.
5. Create the Phase 11 charter, test/evidence plan and risk register before changing business logic.
6. Run the full clean-machine baseline; preserve the complete evidence bundle and release manifest.
7. Only after Phase 11 passes, create the Phase 12 contract for ERP Platform Foundation.

# Appendix A — Phase Charter Template

```text
Phase: [XX — Name]
Baseline commit/tag: [...]
Business outcome: [...]
Why this phase now: [...]
Entry gate: [...]
In scope: [...]
Out of scope: [...]
Protected invariants: [...]
New invariants: [...]
Affected domains / owners: [...]
Data model changes: [...]
Authoritative commands/events: [...]
Authorization/policy changes: [...]
Migration/backfill/reconciliation: [...]
Failure/retry model: [...]
Observability: [...]
Test/evidence matrix: [...]
Risks/stop conditions: [...]
Exit gate: [...]
Next-phase assumptions: [...]
```

# Appendix B — Phase Handoff Template

```text
Phase: [XX — Name]
Final commit/tag: [...]
Release/evidence manifest: [...]
What changed: [...]
What did not change: [...]
New invariants: [...]
Decisions added/superseded: [...]
Migrations applied: [...]
How to restore/run locally: [...]
How to run verification: [...]
Evidence produced: [...]
Known accepted limitations: [...]
Operational/runbook changes: [...]
Market/pilot findings: [...]
Safe assumptions for next phase: [...]
Things next phase must not assume: [...]
Exact next-phase entry gate: [...]
```

# Appendix C — Context Update Rule

This handbook is a controlled living document. Update it only when the product strategy, phase governance, domain ownership, roadmap dependency or market approach changes materially. Routine implementation details belong in phase artifacts and the existing repository context system.

At the end of each phase, review this handbook for drift. If no program-level change occurred, leave it unchanged and update only PROJECT_STATE, decision/verification/journal records and the phase handoff. If a program-level decision changes, increment the handbook version and record the superseding decision in DECISION_LOG.md.
