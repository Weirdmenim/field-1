#!/usr/bin/env bash
set -euo pipefail
if ! npx supabase --version >/dev/null 2>&1; then
  echo "Supabase CLI is required for Phase 1 database integration tests." >&2
  exit 2
fi
npx supabase test db
