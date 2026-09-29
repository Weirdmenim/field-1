# Phase 11 Hardened Candidate — Repair Record

This candidate supersedes the earlier Phase 11B packages that could produce false-positive evidence.

## Repairs

- Removed synthetic evidence generation from the Python runner; it now delegates to the canonical Bash runner.
- Replaced the permissive `phase11_test_all.sh` path with a fail-closed delegate.
- Added `phase11_release_candidate.sh` as the canonical end-to-end executor.
- Only `phase11_final_evidence_audit.mjs` may create `PHASE11_GATE_PASSED.txt`.
- The final auditor validates evidence semantics, source Git provenance, and SHA-256 hashes rather than checking file existence alone.
- E2E flows now attempt real auth, receiving, dispatch capture, count observation, and offline recovery actions.
- Tenant tests use the real Supabase REST/RPC endpoints and known cross-company resources.
- Backup/restore now operates on the real `public.inventory_balances` table with `pg_dump`, destructive mutation, `pg_restore`, and before/after fingerprints.
- Offline stress now uses the actual `FieldOneOffline` / `OutboxV2` IndexedDB schema with schemaVersion 2 records, persistent Chromium profile restart, and real sync confirmation.
- Performance results are measured from real authenticated API requests and the measured offline sync run. No sub-50ms or other SLA is predeclared.
- Security baseline now collects a real npm audit, high-signal source secret scan, RLS audit, and SECURITY DEFINER search_path audit.
- `PROJECT_STATE.json` remains Phase 11 IN_PROGRESS / NOT_SEALED until a real run passes.
- The release-manifest document is a pending template, not a completion declaration.

## Canonical command

Run from a clean, committed FieldOne Git repository with Docker, PostgreSQL client tools, Node 22.12–22.x, Python Playwright, and Chromium available:

```bash
npm run phase11:release-candidate
```

A successful run must create `.phase11-evidence/PHASE11_GATE_PASSED.txt` only after the independent final auditor passes.

## Diagnostic patch — authenticated-shell visibility

A real Phase 11 execution on 2026-09-25 correctly failed closed during the first E2E flow. The captured screenshot proved authentication itself had succeeded, but the E2E harness waited for `Authenticated operational context`, which is rendered inside a collapsed `<details>` panel and is therefore hidden by design. The harness now treats the visible Access `<summary>` control as the authenticated-shell readiness signal and only asserts the company/warehouse controls after explicitly opening that panel. No inventory/application business logic was changed by this patch.
