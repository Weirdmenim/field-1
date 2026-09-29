#!/usr/bin/env bash
set -euo pipefail
if ! npx supabase --version >/dev/null 2>&1; then echo 'Supabase CLI is required for Phase 9 DB tests' >&2; exit 2; fi
npx supabase test db \
  supabase/tests/phase1_auth_rls.sql \
  supabase/tests/phase2_inventory_model.sql \
  supabase/tests/phase3_authoritative_documents.sql \
  supabase/tests/phase4_atomic_document_commands.sql \
  supabase/tests/phase5_ledger_reversals.sql \
  supabase/tests/phase6_offline_workflow_support.sql \
  supabase/tests/phase7_identifiers_scanning.sql \
  supabase/tests/phase8_production_hardening.sql \
  supabase/tests/phase9_stock_revision_preconditions.sql
