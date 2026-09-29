#!/usr/bin/env bash
set -euo pipefail
: "${PHASE10_DB_URL:=postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
export PHASE10_DB_URL
if ! command -v psql >/dev/null 2>&1; then
  echo 'psql is required for Phase 10 PostgreSQL runtime proofs' >&2
  exit 2
fi
p10_psql() { psql "$PHASE10_DB_URL" -X -v ON_ERROR_STOP=1 "$@"; }
p10_auth_sql() {
  cat <<'SQL'
SELECT set_config('request.jwt.claim.sub','f1000000-0000-4000-8000-000000000099',false);
SELECT set_config('request.jwt.claim.role','authenticated',false);
SET ROLE authenticated;
SQL
}
