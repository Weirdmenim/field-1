#!/usr/bin/env bash
set -euo pipefail
source scripts/phase10_psql_common.sh
OUT_DIR=${PHASE10_EVIDENCE_DIR:-.phase10-evidence}
mkdir -p "$OUT_DIR"
WORKER="$OUT_DIR/f149_killed_client_worker.txt"; POST="$OUT_DIR/f149_killed_client_post.txt"; RETRY="$OUT_DIR/f149_killed_client_retry.txt"

cleanup_sleep_trigger() {
  p10_psql -q -c 'DROP TRIGGER IF EXISTS phase10_sleep_after_movement ON inventory_movements; DROP FUNCTION IF EXISTS phase10_test.sleep_after_kill_movement();' >/dev/null 2>&1 || true
}
trap cleanup_sleep_trigger EXIT

p10_psql -q <<'SQL'
CREATE OR REPLACE FUNCTION phase10_test.sleep_after_kill_movement() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.source_document_id='f1210000-0000-4000-8000-000000000001'::uuid THEN
    PERFORM pg_sleep(20);
  END IF;
  RETURN NEW;
END; $$;
DROP TRIGGER IF EXISTS phase10_sleep_after_movement ON inventory_movements;
CREATE TRIGGER phase10_sleep_after_movement AFTER INSERT ON inventory_movements
FOR EACH ROW EXECUTE FUNCTION phase10_test.sleep_after_kill_movement();
SQL

set +e
timeout --signal=KILL 2 psql "$PHASE10_DB_URL" -X -Atq -v ON_ERROR_STOP=1 >"$WORKER" 2>&1 <<'SQL'
SELECT set_config('request.jwt.claim.sub','f1000000-0000-4000-8000-000000000099',false);
SELECT set_config('request.jwt.claim.role','authenticated',false);
SET ROLE authenticated;
SELECT public.dispatch_sales_order_v2(
  'f1210000-0000-4000-8000-000000000001',1,'f1490000-0000-4000-8000-000000000002',
  (SELECT snapshot FROM phase10_test.snapshots WHERE name='kill_client'),clock_timestamp()
)::text;
SQL
rc=$?
set -e
if [[ $rc -eq 0 ]]; then echo 'Expected killed-client dispatch to be interrupted, but it completed' >&2; exit 1; fi
if [[ $rc -ne 124 && $rc -ne 137 ]]; then echo "Killed-client proof failed for an unexpected reason (exit $rc), not the intentional timeout/KILL" >&2; exit 1; fi
sleep 1
cleanup_sleep_trigger
trap - EXIT

p10_psql -Atq >"$POST" <<'SQL'
SELECT jsonb_build_object(
  'onHand',(SELECT on_hand_base_qty FROM inventory_balances WHERE bin_id='f1000000-0000-4000-8000-000000000106' AND product_id='44444444-4444-4444-4444-444444444401' AND inventory_status='AVAILABLE'),
  'movements',(SELECT count(*) FROM inventory_movements WHERE source_document_id='f1210000-0000-4000-8000-000000000001'),
  'posted',(SELECT sum(posted_base_quantity) FROM inventory_sales_order_lines WHERE sales_order_id='f1210000-0000-4000-8000-000000000001'),
  'orderRevision',(SELECT revision FROM inventory_sales_orders WHERE id='f1210000-0000-4000-8000-000000000001'),
  'commands',(SELECT count(*) FROM inventory_document_commands WHERE client_command_id='f1490000-0000-4000-8000-000000000002'),
  'preconditions',(SELECT count(*) FROM inventory_document_command_stock_preconditions WHERE client_command_id='f1490000-0000-4000-8000-000000000002')
)::text;
SQL

python3 - "$POST" <<'PY'
import json,sys
p=json.loads([x.strip() for x in open(sys.argv[1]) if x.strip().startswith('{')][-1])
assert float(p['onHand'])==5 and int(p['movements'])==0 and float(p['posted'] or 0)==0, p
assert int(p['orderRevision'])==1 and int(p['commands'])==0 and int(p['preconditions'])==0, p
print('PASS F-149 killed-client rollback: interrupted connection left no partial stock, ledger, document, command, or precondition commit')
PY

# The exact same stable command id must remain safe to retry after the crash.
p10_psql -Atq >"$RETRY" 2>&1 <<'SQL'
SELECT set_config('request.jwt.claim.sub','f1000000-0000-4000-8000-000000000099',false);
SELECT set_config('request.jwt.claim.role','authenticated',false);
SET ROLE authenticated;
SELECT public.dispatch_sales_order_v2(
  'f1210000-0000-4000-8000-000000000001',1,'f1490000-0000-4000-8000-000000000002',
  (SELECT snapshot FROM phase10_test.snapshots WHERE name='kill_client'),clock_timestamp()
)::text;
SQL
python3 - "$RETRY" <<'PY'
import json,sys
r=json.loads([x.strip() for x in open(sys.argv[1]) if x.strip().startswith('{')][-1])
assert r.get('success') is True and r.get('outcome')=='accepted', r
print('PASS F-149 post-crash same-id retry: stable command safely completed after rollback')
PY
