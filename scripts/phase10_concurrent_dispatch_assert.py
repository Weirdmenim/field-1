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

a = last_json('.phase10-evidence/f147_a.json')
b = last_json('.phase10-evidence/f147_b.json')
post = last_json('.phase10-evidence/f147_post.json')

results=[a,b]
accepted=[r for r in results if r.get('success') is True and r.get('outcome')=='accepted']
conflicts=[r for r in results if r.get('success') is False and r.get('outcome')=='conflict' and r.get('code')=='STOCK_REVISION_CONFLICT']

print("Accepted:", len(accepted))
print("Conflicts:", len(conflicts))
print("Post:", post)

assert len(accepted)==1, results
assert len(conflicts)==1, results
assert float(post['onHand'])==3.0, post
assert int(post['saleMovements'])==1, post
assert int(post['completedOrders'])==1 and int(post['openOrders'])==1, post
print('PASS F-147 true parallel PostgreSQL dispatch: exactly one command committed; the stale competitor conflicted; stock and ledger changed once')
