#!/usr/bin/env bash
set -euo pipefail
source scripts/phase10_psql_common.sh
OUT_DIR=${PHASE10_EVIDENCE_DIR:-.phase10-evidence}
mkdir -p "$OUT_DIR"
RESULT="$OUT_DIR/f149_injected_result.txt"; POST="$OUT_DIR/f149_injected_post.txt"

cleanup_failure_trigger() {
  p10_psql -q -c 'DROP TRIGGER IF EXISTS phase10_fail_second_movement ON inventory_movements; DROP FUNCTION IF EXISTS phase10_test.fail_second_movement();' >/dev/null 2>&1 || true
}
trap cleanup_failure_trigger EXIT

# Fail specifically on the second movement. The first line has already touched stock inside
# the command subtransaction, so any surviving first-line mutation is a true partial commit.
p10_psql -q <<'SQL'
CREATE OR REPLACE FUNCTION phase10_test.fail_second_movement() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.source_document_id='f1200000-0000-4000-8000-000000000001'::uuid
     AND NEW.sales_order_line_id='f1200000-0000-4000-8000-000000000012'::uuid THEN
    RAISE EXCEPTION 'PHASE10_INJECTED_SECOND_LINE_FAILURE';
  END IF;
  RETURN NEW;
END; $$;
DROP TRIGGER IF EXISTS phase10_fail_second_movement ON inventory_movements;
CREATE TRIGGER phase10_fail_second_movement BEFORE INSERT ON inventory_movements
FOR EACH ROW EXECUTE FUNCTION phase10_test.fail_second_movement();
SQL

p10_psql -Atq >"$RESULT" 2>&1 <<'SQL'
SELECT set_config('request.jwt.claim.sub','f1000000-0000-4000-8000-000000000099',false);
SELECT set_config('request.jwt.claim.role','authenticated',false);
SET ROLE authenticated;
SELECT public.dispatch_sales_order_v2(
  'f1200000-0000-4000-8000-000000000001',1,'f1490000-0000-4000-8000-000000000001',
  (SELECT snapshot FROM phase10_test.snapshots WHERE name='fail_inject'),clock_timestamp()
)::text;
SQL

cleanup_failure_trigger
trap - EXIT

p10_psql -Atq >"$POST" <<'SQL'
SELECT jsonb_build_object(
  'a',(SELECT on_hand_base_qty FROM inventory_balances WHERE bin_id='f1000000-0000-4000-8000-000000000102' AND product_id='44444444-4444-4444-4444-444444444401' AND inventory_status='AVAILABLE'),
  'b',(SELECT on_hand_base_qty FROM inventory_balances WHERE bin_id='f1000000-0000-4000-8000-000000000103' AND product_id='44444444-4444-4444-4444-444444444402' AND inventory_status='AVAILABLE'),
  'movements',(SELECT count(*) FROM inventory_movements WHERE source_document_id='f1200000-0000-4000-8000-000000000001'),
  'posted',(SELECT sum(posted_base_quantity) FROM inventory_sales_order_lines WHERE sales_order_id='f1200000-0000-4000-8000-000000000001'),
  'orderRevision',(SELECT revision FROM inventory_sales_orders WHERE id='f1200000-0000-4000-8000-000000000001'),
  'orderStatus',(SELECT status::text FROM inventory_sales_orders WHERE id='f1200000-0000-4000-8000-000000000001'),
  'operations',(SELECT count(*) FROM inventory_operations WHERE source_document_id='f1200000-0000-4000-8000-000000000001')
)::text;
SQL

python3 - "$RESULT" "$POST" <<'PY'
import json, sys
def last_json(p):
    vals=[]
    for raw in open(p,encoding='utf-8'):
        s=raw.strip()
        if s.startswith('{'):
            try: vals.append(json.loads(s))
            except json.JSONDecodeError: pass
    if not vals: raise AssertionError(f'No JSON in {p}')
    return vals[-1]
r=last_json(sys.argv[1]); post=last_json(sys.argv[2])
assert r.get('success') is False and r.get('outcome')=='transient_error', r
assert 'PHASE10_INJECTED_SECOND_LINE_FAILURE' in r.get('message',''), r
assert float(post['a'])==5 and float(post['b'])==5, post
assert int(post['movements'])==0 and float(post['posted'] or 0)==0, post
assert int(post['orderRevision'])==1 and post['orderStatus']=='IN_PROGRESS', post
assert int(post['operations'])==0, post
print('PASS F-149 injected mid-batch failure: first-line balance/ledger/document work rolled back atomically')
PY
