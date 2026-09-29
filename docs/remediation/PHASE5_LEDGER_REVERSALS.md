# Phase 5 - Ledger Immutability, Validated Reversals, and Controlled Corrections

## Objective

Phase 5 closes the unsafe gap between an auditable inventory ledger and a merely append-oriented implementation. Posted movement history becomes database-enforced append-only, ordinary application/service roles lose direct mutation rights, and eligible standalone movements are corrected only through an idempotent server reversal command that appends compensating history.

## Core rules

1. `inventory_movements` is immutable after insert. UPDATE and DELETE are rejected by a database trigger.
2. Application roles and `service_role` do not receive direct INSERT/UPDATE/DELETE/TRUNCATE privileges on movement history.
3. A reversal is a new movement linked to both the original movement and the authoritative correction command.
4. The original movement is locked before reversible quantity is calculated.
5. Full and partial reversal are supported; aggregate reversal quantity may never exceed the original base quantity.
6. A reversal movement cannot itself be reversed through the generic command.
7. Tenant and product identity are enforced by a composite movement relationship.
8. Physical source/destination/bin/status shape must exactly invert the original movement.
9. If the reversal removes current stock, the source balance is locked, current physical stock is re-read, active reservations are protected, and inactive warehouse/bin positions fail closed.
10. Later inventory activity on an affected position makes a generic historical reversal ineligible because replaying an older physical event would make the ledger ambiguous.
11. Phase 3/4 document-linked movements are not generically reversible. They return `DOCUMENT_CORRECTION_REQUIRED` so transfer/order/count state cannot diverge from the ledger.
12. Reversal identity uses a company-scoped UUID client command id and a server-generated immutable fingerprint that includes movement, quantity, reason, and client physical-action timestamp.
13. Same-key/same-content retry reuses the authoritative command result; same-key/different-content reuse fails closed.
14. Correction reason and authenticated actor are mandatory.

## Reversal eligibility

The generic command is intentionally narrow. It supports movements whose inverse can be represented safely without rewriting an authoritative business document, including eligible standalone adjustments, sales, returns/receipts, count variances, expiry, damage, and status changes.

Transfer/document-command movements are not eligible. Their correction must be implemented as a document-specific command in a later phase so document progress, transit, reservations, approvals, and ledger history remain mutually consistent.

## Downstream-activity rule

A movement may be generically reversed only while no later non-reversal movement has touched the same affected product/location/bin/status position. Direct partial reversals of the same original are excluded from that downstream test, allowing a safe sequence such as 4 units reversed now and the remaining 6 later, provided no intervening inventory activity has occurred.

This rule is deliberately conservative. It prevents a historical reversal from pretending that a past physical event can simply be erased after later warehouse work has relied on the resulting position.

## Administrative repair boundary

Phase 5 does not add a hidden application bypass. Emergency repair must follow the controlled runbook in `docs/remediation/PHASE5_ADMIN_REPAIR_RUNBOOK.md`.

The core rule is: **never UPDATE or DELETE posted movement history to make numbers match**. Repairs are appended as new, explicitly authorized corrections after reconciliation and backup. Document-linked corrections remain blocked until an appropriate document-specific correction command exists.

## Implementation assets

- Migration: `supabase/migrations/20260918090000_phase5_ledger_reversals.sql`
- Preflight: `supabase/preflight/phase5_existing_data.sql`
- pgTAP: `supabase/tests/phase5_ledger_reversals.sql`
- Static verifier: `scripts/phase5_verify.mjs`
- DB runner: `scripts/phase5_db_test.sh`
- Client boundary: `src/lib/ledger.ts`

## Verification boundary

Repository/static verification can prove the presence of the safety structures and regression scenarios. Final VERIFIED/CLOSED status still requires a real Supabase/PostgreSQL execution environment, clean dependency installation, full TypeScript, and production Vite build.
