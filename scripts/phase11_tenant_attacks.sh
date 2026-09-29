#!/usr/bin/env bash
set -euo pipefail

SUPABASE_URL="${PHASE11_SUPABASE_URL:-http://127.0.0.1:54321}"
API_URL="$SUPABASE_URL/rest/v1"
ANON_KEY="${SUPABASE_ANON_KEY:-${VITE_SUPABASE_ANON_KEY:-eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0}}"
EVIDENCE="${PHASE11_EVIDENCE_DIR:-.phase11-evidence}/tenant-security"
mkdir -p "$EVIDENCE"

EMAIL="${PHASE11_TEST_EMAIL:-phase10-runtime@example.test}"
PASSWORD="${PHASE11_TEST_PASSWORD:-Phase10!Runtime123}"
CELAVI_COMPANY='22222222-2222-2222-2222-222222222222'
CELAVI_LOCATION='2b2b2b2b-2b2b-2b2b-2b2b-2b2b2b2b2b21'

AUTH_BODY=$(curl -fsS -X POST "$SUPABASE_URL/auth/v1/token?grant_type=password" \
  -H "apikey: $ANON_KEY" -H 'Content-Type: application/json' \
  --data "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\"}")
TOKEN=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])' <<<"$AUTH_BODY")

# 1. A Miro actor must not see a known Celavi location. RLS should return HTTP 200 with an empty set.
READ_TMP=$(mktemp)
READ_CODE=$(curl -sS -o "$READ_TMP" -w '%{http_code}' \
  "$API_URL/inventory_locations?id=eq.$CELAVI_LOCATION&select=id,company_id,name" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN")
READ_BODY=$(cat "$READ_TMP"); rm -f "$READ_TMP"
{
  echo "http_code=$READ_CODE"
  echo "body=$READ_BODY"
} > "$EVIDENCE/cross-tenant-read.log"
[[ "$READ_CODE" == "200" ]] || { echo 'result=FAIL unexpected HTTP status' >> "$EVIDENCE/cross-tenant-read.log"; exit 1; }
[[ "$READ_BODY" == "[]" ]] || { echo 'result=FAIL cross-tenant row visible' >> "$EVIDENCE/cross-tenant-read.log"; exit 1; }
echo 'result=PASS' >> "$EVIDENCE/cross-tenant-read.log"

# 2. Direct cross-tenant write must be rejected by grants/RLS.
WRITE_TMP=$(mktemp)
WRITE_CODE=$(curl -sS -o "$WRITE_TMP" -w '%{http_code}' -X POST "$API_URL/inventory_bins" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' -H 'Prefer: return=representation' \
  --data "{\"id\":\"fa110000-0000-4000-8000-000000000001\",\"company_id\":\"$CELAVI_COMPANY\",\"location_id\":\"$CELAVI_LOCATION\",\"code\":\"P11-ILLEGAL\",\"name\":\"Illegal cross tenant write\",\"is_active\":true}")
WRITE_BODY=$(cat "$WRITE_TMP"); rm -f "$WRITE_TMP"
{
  echo "http_code=$WRITE_CODE"
  echo "body=$WRITE_BODY"
} > "$EVIDENCE/cross-tenant-write.log"
if [[ "$WRITE_CODE" == "200" || "$WRITE_CODE" == "201" ]]; then
  echo 'result=FAIL cross-tenant write succeeded' >> "$EVIDENCE/cross-tenant-write.log"
  exit 1
fi
echo 'result=PASS' >> "$EVIDENCE/cross-tenant-write.log"

# 3. Authenticated RPC against a warehouse in another company must fail authorization.
RPC_TMP=$(mktemp)
RPC_CODE=$(curl -sS -o "$RPC_TMP" -w '%{http_code}' -X POST "$API_URL/rpc/resolve_inventory_identifier" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  --data "{\"p_location_id\":\"$CELAVI_LOCATION\",\"p_code\":\"CEL-001\",\"p_context\":\"browse\",\"p_document_id\":null}")
RPC_BODY=$(cat "$RPC_TMP"); rm -f "$RPC_TMP"
{
  echo "http_code=$RPC_CODE"
  echo "body=$RPC_BODY"
} > "$EVIDENCE/rpc-bypass.log"
if [[ "$RPC_CODE" == "200" ]]; then
  echo 'result=FAIL cross-tenant RPC succeeded' >> "$EVIDENCE/rpc-bypass.log"
  exit 1
fi
if ! grep -Eqi 'permission|authoriz|42501|warehouse' "$EVIDENCE/rpc-bypass.log"; then
  echo 'result=FAIL RPC failed for an unproven reason' >> "$EVIDENCE/rpc-bypass.log"
  exit 1
fi
echo 'result=PASS' >> "$EVIDENCE/rpc-bypass.log"

echo 'PASS Phase 11 tenant isolation attack suite'
