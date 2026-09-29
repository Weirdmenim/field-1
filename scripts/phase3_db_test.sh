#!/usr/bin/env bash
set -euo pipefail
if ! npx supabase --version >/dev/null 2>&1; then
  echo "Supabase CLI is required for Phase 3 DB tests." >&2
  exit 2
fi
npx supabase test db \
  supabase/tests/phase1_auth_rls.sql \
  supabase/tests/phase2_inventory_model.sql \
  supabase/tests/phase3_authoritative_documents.sql
