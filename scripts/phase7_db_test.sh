#!/usr/bin/env bash
set -euo pipefail
if ! npx supabase --version >/dev/null 2>&1; then echo 'Supabase CLI is required for Phase 7 DB tests' >&2; exit 2; fi
npx supabase test db supabase/tests/phase7_identifiers_scanning.sql
