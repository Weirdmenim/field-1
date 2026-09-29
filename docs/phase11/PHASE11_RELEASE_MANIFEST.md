# Phase 11 Release Manifest

**Phase:** 11 — Truth Gate and Inventory Baseline  
**Status:** PENDING EXECUTION  
**Canonical executor:** `npm run phase11:release-candidate`

This file is intentionally **not** a declaration that Phase 11 passed. The canonical release run must generate `.phase11-evidence/manifest.json` and `.phase11-evidence/PHASE11_GATE_PASSED.txt` only after the independent final evidence auditor verifies real runtime evidence.

## Required gates

- Phase 10 canonical evidence remains valid.
- Application E2E: auth, receiving, dispatch capture, count observation, offline recovery.
- Cross-tenant read/write/RPC attack proofs.
- Real `pg_dump` / destructive mutation / `pg_restore` fingerprint proof for inventory balances.
- At least 200 schema-valid `OutboxV2` commands persisted across browser restart and confirmed by the real sync engine.
- Measured API/read and identifier-resolution performance baseline plus measured offline sync throughput.
- Dependency, high-signal secret, RLS, and SECURITY DEFINER audits.
- Clean Git commit provenance and SHA-256 hashes for raw evidence.

## Seal rule

No document may mark Phase 11 `SEALED` and Phase 12 may not start until the generated Phase 11 evidence bundle passes `scripts/phase11_final_evidence_audit.mjs` and the resulting evidence is independently reviewed.
