import asyncio, json, mimetypes, tempfile
from pathlib import Path
from urllib.parse import urlparse, parse_qs
from playwright.async_api import async_playwright

ROOT=Path('.phase9-browser').resolve(); calls={}; BASE='https://fieldone.test/index.html'

def cmd(cid, owner):
    return {'id':cid,'owner':owner,'kind':'unknown_scan_report','ref':'TEST','label':'Unknown scan','documentId':None,'clientRecordedAt':'2026-09-18T00:00:00.000Z','payload':{'rawCode':'X'+cid[-4:],'context':'browse'},'dependencyIds':[]}

async def install_routes(ctx):
    async def handler(route):
        u=urlparse(route.request.url)
        if u.path == '/rpc':
            cid=parse_qs(u.query).get('id',[''])[0]; await asyncio.sleep(.12); calls[cid]=calls.get(cid,0)+1
            await route.fulfill(status=200,content_type='application/json',body=json.dumps({'ok':True,'id':cid})); return
        rel=u.path.lstrip('/') or 'index.html'; f=(ROOT/rel).resolve()
        if ROOT not in f.parents and f != ROOT: await route.fulfill(status=403,body='forbidden'); return
        if not f.exists(): await route.fulfill(status=404,body='missing'); return
        ctype=mimetypes.guess_type(str(f))[0] or ('text/javascript' if f.suffix=='.js' else 'application/octet-stream')
        await route.fulfill(status=200,content_type=ctype,body=f.read_bytes())
    await ctx.route('https://fieldone.test/**',handler)

async def wait_ready(p):
    await p.goto(BASE); await p.wait_for_function('window.ready === true')

async def main():
    import subprocess; subprocess.run(['node','scripts/phase9_build_browser_harness.mjs'],check=True,stdout=subprocess.DEVNULL)
    owner={'authUserId':'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','companyId':'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','locationId':'cccccccc-cccc-4ccc-8ccc-cccccccccccc'}
    ids=['11111111-1111-4111-8111-111111111111','22222222-2222-4222-8222-222222222222','33333333-3333-4333-8333-333333333333']; restart_id='44444444-4444-4444-8444-444444444444'
    with tempfile.TemporaryDirectory(prefix='fieldone-p9-') as profile:
      async with async_playwright() as pw:
        ctx=await pw.chromium.launch_persistent_context(profile,headless=True,executable_path='/usr/bin/chromium',args=['--no-sandbox']); await install_routes(ctx)
        p1=ctx.pages[0]; p2=await ctx.new_page()
        try:
            await asyncio.gather(wait_ready(p1),wait_ready(p2))
        except Exception as exc:
            if 'ERR_BLOCKED_BY_ADMINISTRATOR' in str(exc):
                probe_page=await ctx.new_page()
                await probe_page.set_content('<!doctype html><title>FieldOne Phase 9 browser capability probe</title>')
                probe=await probe_page.evaluate('''async()=>{const out={locks:Boolean(navigator.locks),broadcast:typeof BroadcastChannel==='function'};try{await new Promise((ok,fail)=>{const r=indexedDB.open('phase9-capability-probe',1);r.onupgradeneeded=()=>r.result.createObjectStore('s');r.onsuccess=()=>{r.result.close();ok()};r.onerror=()=>fail(r.error)});out.indexedDB=true}catch(e){out.indexedDB=false;out.indexedDBError=String(e)}return out}''')
                print('BLOCKED Phase 9 real-browser runtime proof: managed Chromium policy blocks page navigation and about:blank IndexedDB is unavailable: '+json.dumps(probe), flush=True)
                await ctx.close()
                raise SystemExit(2)
            raise
        await asyncio.gather(p1.evaluate('(x)=>api.enqueueCommand(x)',cmd(ids[0],owner)),p2.evaluate('(x)=>api.enqueueCommand(x)',cmd(ids[1],owner)))
        t=asyncio.create_task(p1.evaluate('(o)=>api.processQueue(o)',owner)); await asyncio.sleep(.03)
        await p2.evaluate('(x)=>api.enqueueCommand(x)',cmd(ids[2],owner)); await p2.evaluate('(o)=>api.processQueue(o)',owner); await t; await p2.evaluate('(o)=>api.processQueue(o)',owner)
        q=await p1.evaluate('(o)=>api.getQueueForOwner(o)',owner); states={x['id']:x['state'] for x in q}
        assert all(states.get(i)=='confirmed' for i in ids),states; assert all(calls.get(i)==1 for i in ids),calls
        print('PASS F-153 real Chromium concurrent enqueue/drain: no lost or duplicate commands')

        await p1.evaluate('(x)=>api.enqueueCommand(x)',cmd(restart_id,owner))
        await p1.evaluate('''async (id)=>{const d=await new Promise((ok,fail)=>{const r=indexedDB.open('FieldOneHarness',1);r.onsuccess=()=>ok(r.result);r.onerror=()=>fail(r.error)});await new Promise((ok,fail)=>{const t=d.transaction('kv','readwrite'),s=t.objectStore('kv'),r=s.get('OutboxV2:'+id);r.onsuccess=()=>{const v=r.result;v.state='syncing';v.leaseOwner='dead-worker';v.leaseExpiresAt='2020-01-01T00:00:00.000Z';s.put(v,'OutboxV2:'+id)};t.oncomplete=()=>ok();t.onerror=()=>fail(t.error)});d.close()}''',restart_id)
        await ctx.close()
        ctx2=await pw.chromium.launch_persistent_context(profile,headless=True,executable_path='/usr/bin/chromium',args=['--no-sandbox']); await install_routes(ctx2)
        p=ctx2.pages[0]; await wait_ready(p); await p.evaluate('(o)=>api.processQueue(o)',owner)
        q2=await p.evaluate('(o)=>api.getQueueForOwner(o)',owner); r=[x for x in q2 if x['id']==restart_id][0]
        assert r['state']=='confirmed',r; assert calls.get(restart_id)==1,calls
        print('PASS F-154 real Chromium persistent-profile restart: expired syncing lease recovered with same command id')
        await ctx2.close()

if __name__=='__main__': asyncio.run(main())
