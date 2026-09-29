
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
r=last_json('.phase10-evidence/f153_killed_client_retry.txt')
assert r.get('success') is True and r.get('outcome')=='accepted', r
print('PASS F-153 post-crash same-id retry: stable command safely completed after rollback')
    