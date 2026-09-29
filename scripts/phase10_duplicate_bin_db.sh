#!/usr/bin/env bash
set -euo pipefail
source scripts/phase10_psql_common.sh
OUT_DIR=${PHASE10_EVIDENCE_DIR:-.phase10-evidence}
mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/f157_duplicate_bin_resolver.txt"

p10_psql -Atq >"$OUT" 2>&1 <<'SQL'
SELECT set_config('request.jwt.claim.sub','f1000000-0000-4000-8000-000000000099',false);
SELECT set_config('request.jwt.claim.role','authenticated',false);
SET ROLE authenticated;
SELECT public.resolve_inventory_identifier(
  '33333333-3333-3333-3333-333333333331',
  ' MIRO-LAP-14 ',
  'dispatch',
  'f1300000-0000-4000-8000-000000000001'
)::text;
SQL

python3 - "$OUT" <<'PY'
import json,sys
vals=[]
for raw in open(sys.argv[1],encoding='utf-8'):
    s=raw.strip()
    if s.startswith('{'):
        try: vals.append(json.loads(s))
        except json.JSONDecodeError: pass
if not vals: raise AssertionError('No resolver JSON output')
r=vals[-1]
assert r.get('status')=='ambiguous', r
c=r.get('candidates') or []
assert len(c)==2, r
lines={x['line_id'] for x in c}; bins={x['bin_code'] for x in c}
assert lines=={'f1300000-0000-4000-8000-000000000011','f1300000-0000-4000-8000-000000000012'}, c
assert bins=={'P10-DUP-A','P10-DUP-B'}, c
assert all(x.get('sku')=='MIRO-LAP-14' for x in c), c
print('PASS F-157 PostgreSQL resolver: exact SKU maps to two actionable lines in two bins and returns explicit ambiguity')
PY
