#!/usr/bin/env bash
set -euo pipefail
DB_URL="${PHASE11_DB_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
EVIDENCE="${PHASE11_EVIDENCE_DIR:-.phase11-evidence}/security"
mkdir -p "$EVIDENCE"

# Dependency audit: collect the real report even when npm returns non-zero, then apply our explicit policy.
set +e
npm audit --json > "$EVIDENCE/dependency-audit.json" 2> "$EVIDENCE/dependency-audit.stderr.log"
AUDIT_RC=$?
set -e
echo "npm_audit_exit=$AUDIT_RC" > "$EVIDENCE/dependency-audit-policy.log"
python3 - "$EVIDENCE/dependency-audit.json" <<'PY' >> "$EVIDENCE/dependency-audit-policy.log"
import json,sys
p=sys.argv[1]
data=json.load(open(p,encoding='utf-8'))
counts=((data.get('metadata') or {}).get('vulnerabilities') or {})
high=int(counts.get('high',0) or 0); critical=int(counts.get('critical',0) or 0)
print('high='+str(high)); print('critical='+str(critical))
if high or critical: raise SystemExit(1)
print('result=PASS')
PY

# High-signal source secret scan. Test fixtures/docs are excluded intentionally.
set +e
git grep -nIE '(AWS_SECRET_ACCESS_KEY|SUPABASE_SERVICE_ROLE_KEY\s*[:=]|-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----|sk_live_[A-Za-z0-9])' -- src .github > "$EVIDENCE/secrets-scan.log"
SECRET_RC=$?
set -e
if [[ "$SECRET_RC" == "0" ]]; then
  echo 'result=FAIL high-signal secret pattern found' >> "$EVIDENCE/secrets-scan.log"
  exit 1
elif [[ "$SECRET_RC" != "1" ]]; then
  echo "result=FAIL git grep error rc=$SECRET_RC" >> "$EVIDENCE/secrets-scan.log"
  exit 1
else
  echo 'result=PASS no high-signal source secrets found' >> "$EVIDENCE/secrets-scan.log"
fi

# Tenant-sensitive public tables must have RLS enabled.
psql "$DB_URL" -X -qAt <<'SQL' > "$EVIDENCE/rls-audit.log"
SELECT c.relname
FROM pg_class c
JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname='public'
  AND c.relkind='r'
  AND c.relname = ANY(ARRAY[
    'companies','profiles','company_memberships','inventory_locations','warehouse_memberships',
    'inventory_bins','products','product_units','inventory_balances','inventory_reservations',
    'inventory_movements','inventory_operations','inventory_transfer_documents','inventory_transfer_lines','inventory_sales_orders',
    'inventory_sales_order_lines','inventory_count_sessions','inventory_count_lines','inventory_count_observations',
    'product_identifiers','inventory_unknown_scan_events'
  ])
  AND NOT c.relrowsecurity
ORDER BY c.relname;
SQL
if [[ -s "$EVIDENCE/rls-audit.log" ]]; then
  echo 'FAIL: tenant-sensitive tables without RLS:' >&2
  cat "$EVIDENCE/rls-audit.log" >&2
  exit 1
fi
echo 'result=PASS all present tenant-sensitive tables have RLS' >> "$EVIDENCE/rls-audit.log"

# Every public SECURITY DEFINER function must pin search_path in proconfig.
psql "$DB_URL" -X -qAt <<'SQL' > "$EVIDENCE/security-definer-audit.log"
SELECT p.oid::regprocedure::text
FROM pg_proc p
JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public'
  AND p.prosecdef
  AND NOT EXISTS (
    SELECT 1 FROM unnest(COALESCE(p.proconfig, ARRAY[]::text[])) cfg
    WHERE cfg LIKE 'search_path=%'
  )
ORDER BY 1;
SQL
if [[ -s "$EVIDENCE/security-definer-audit.log" ]]; then
  echo 'FAIL: SECURITY DEFINER functions without pinned search_path:' >&2
  cat "$EVIDENCE/security-definer-audit.log" >&2
  exit 1
fi
echo 'result=PASS SECURITY DEFINER search_path pinned' >> "$EVIDENCE/security-definer-audit.log"

# Local Supabase config is development configuration. Record production-relevant settings without pretending they are production.
{
  echo 'scope=local-development-config-only'
  grep -E '^(enable_signup|minimum_password_length|site_url|jwt_expiry)[[:space:]]*=' supabase/config.toml || true
  echo 'result=RECORDED production deployment must be separately hardened before GA'
} > "$EVIDENCE/production-config-baseline.log"

echo 'PASS Phase 11 security baseline'
