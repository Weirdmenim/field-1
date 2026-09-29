
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
r=last_json('.phase10-evidence/f149_injected_result.txt')
post=last_json('.phase10-evidence/f149_injected_post.txt')
assert r.get('success') is False and r.get('outcome')=='transient_error', r
assert 'PHASE10_INJECTED_SECOND_LINE_FAILURE' in r.get('message',''), r
assert float(post['a'])==5 and float(post['b'])==5, post
assert int(post['movements'])==0 and float(post['posted'] or 0)==0, post
assert int(post['orderRevision'])==1 and post['orderStatus']=='IN_PROGRESS', post
assert int(post['operations'])==0, post
print('PASS F-149 injected mid-batch failure: first-line balance/ledger/document work rolled back atomically')
    