#!/usr/bin/env bash
set -euo pipefail
source scripts/phase10_psql_common.sh
OUT_DIR=${PHASE10_EVIDENCE_DIR:-.phase10-evidence}
mkdir -p "$OUT_DIR"
A="$OUT_DIR/f147_dispatch_a.txt"; B="$OUT_DIR/f147_dispatch_b.txt"; POST="$OUT_DIR/f147_post_state.txt"
LOCK_KEY=94147001

# Hold an exclusive advisory lock briefly so both workers reach the same start barrier.
p10_psql -Atq -c "SELECT pg_advisory_lock($LOCK_KEY); SELECT pg_sleep(1.2); SELECT pg_advisory_unlock($LOCK_KEY);" >"$OUT_DIR/f147_barrier.txt" 2>&1 &
barrier_pid=$!

# Do not rely on a timing sleep to prove the controller owns the barrier. Poll
# pg_locks until the exclusive advisory lock is granted; fail loudly if the
# controller exits early or the lock is not observable within the deadline.
barrier_ready=0
for _ in $(seq 1 100); do
  if ! kill -0 "$barrier_pid" 2>/dev/null; then
    wait "$barrier_pid" || true
    echo 'F-147 barrier controller exited before acquiring the advisory lock' >&2
    exit 1
  fi
  held=$(p10_psql -Atq -c "SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND granted AND mode='ExclusiveLock' AND classid=0 AND objid=$LOCK_KEY;")
  if [[ "$held" == "1" ]]; then barrier_ready=1; break; fi
  sleep 0.02
done
if [[ "$barrier_ready" != 1 ]]; then
  kill "$barrier_pid" >/dev/null 2>&1 || true
  wait "$barrier_pid" >/dev/null 2>&1 || true
  echo 'F-147 barrier controller did not acquire the advisory lock before timeout' >&2
  exit 1
fi

run_worker() {
  local snap_name=$1 doc_id=$2 command_id=$3 output=$4
  p10_psql -Atq >"$output" 2>&1 <<SQL
SELECT set_config('request.jwt.claim.sub','f1000000-0000-4000-8000-000000000099',false);
SELECT set_config('request.jwt.claim.role','authenticated',false);
SET ROLE authenticated;
SELECT pg_advisory_lock_shared($LOCK_KEY);
SELECT public.dispatch_sales_order_v2(
  '$doc_id',
  1,
  '$command_id',
  (SELECT snapshot FROM phase10_test.snapshots WHERE name='$snap_name'),
  clock_timestamp()
)::text;
SELECT pg_advisory_unlock_shared($LOCK_KEY);
SQL
}

run_worker race_a f1100000-0000-4000-8000-000000000001 f1470000-0000-4000-8000-000000000001 "$A" & p1=$!
run_worker race_b f1100000-0000-4000-8000-000000000002 f1470000-0000-4000-8000-000000000002 "$B" & p2=$!
wait "$barrier_pid"
wait "$p1"
wait "$p2"

p10_psql -Atq >"$POST" <<'SQL'
SELECT jsonb_build_object(
  'onHand',(SELECT on_hand_base_qty FROM inventory_balances WHERE company_id='11111111-1111-1111-1111-111111111111' AND location_id='33333333-3333-3333-3333-333333333331' AND bin_id='f1000000-0000-4000-8000-000000000101' AND product_id='44444444-4444-4444-4444-444444444401' AND inventory_status='AVAILABLE'),
  'saleMovements',(SELECT count(*) FROM inventory_movements WHERE sales_order_line_id IN ('f1100000-0000-4000-8000-000000000011','f1100000-0000-4000-8000-000000000012')),
  'completedOrders',(SELECT count(*) FROM inventory_sales_orders WHERE id IN ('f1100000-0000-4000-8000-000000000001','f1100000-0000-4000-8000-000000000002') AND status='COMPLETED'),
  'openOrders',(SELECT count(*) FROM inventory_sales_orders WHERE id IN ('f1100000-0000-4000-8000-000000000001','f1100000-0000-4000-8000-000000000002') AND status<>'COMPLETED')
)::text;
SQL

python3 - "$A" "$B" "$POST" <<'PY'
import json, sys

def last_json(path):
    vals=[]
    for raw in open(path, encoding='utf-8'):
        s=raw.strip()
        if s.startswith('{'):
            try: vals.append(json.loads(s))
            except json.JSONDecodeError: pass
    if not vals: raise AssertionError(f'No JSON result in {path}')
    return vals[-1]

a,b,post=map(last_json,sys.argv[1:])
results=[a,b]
accepted=[r for r in results if r.get('success') is True and r.get('outcome')=='accepted']
conflicts=[r for r in results if r.get('success') is False and r.get('outcome')=='conflict' and r.get('code')=='STOCK_REVISION_CONFLICT']
assert len(accepted)==1, results
assert len(conflicts)==1, results
assert float(post['onHand'])==3.0, post
assert int(post['saleMovements'])==1, post
assert int(post['completedOrders'])==1 and int(post['openOrders'])==1, post
print('PASS F-147 true parallel PostgreSQL dispatch: exactly one command committed; the stale competitor conflicted; stock and ledger changed once')
PY
