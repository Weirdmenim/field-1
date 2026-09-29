
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
post=last_json('.phase10-evidence/f153_killed_client_post.txt')
assert float(post['onHand'])==5 and int(post['movements'])==0 and float(post['posted'] or 0)==0, post
assert int(post['orderRevision'])==1 and int(post['commands'])==0, post
print('PASS F-153 killed-client rollback: interrupted connection left no partial stock, ledger, document, command, or precondition commit')
    