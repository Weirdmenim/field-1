import asyncio, json, mimetypes, os, tempfile
from pathlib import Path
from urllib.parse import urlparse, parse_qs
from playwright.async_api import async_playwright

ROOT=Path('.phase9-browser').resolve()
BASE='https://fieldone.test/index.html'
TOTAL=40


def command(cid, owner, n):
    return {
        'id':cid,'owner':owner,'kind':'unknown_scan_report','ref':f'P10-{n:02d}','label':'Unknown scan',
        'documentId':None,'clientRecordedAt':'2026-09-23T08:00:00.000Z',
        'payload':{'rawCode':f'UNKNOWN-{n:02d}','context':'browse'},'dependencyIds':[]
    }

async def run():
    import subprocess
    subprocess.run(['node','scripts/phase9_build_browser_harness.mjs'],check=True,stdout=subprocess.DEVNULL)
    calls={}
    browser_errors=[]
    owner={'authUserId':'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','companyId':'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','locationId':'cccccccc-cccc-4ccc-8ccc-cccccccccccc'}
    ids=[f'{i:08x}-1111-4111-8111-{i:012x}' for i in range(1,TOTAL+1)]
    restart_ids=['f1540000-0000-4000-8000-000000000001','f1540000-0000-4000-8000-000000000002','f1540000-0000-4000-8000-000000000003']

    async def install_routes(ctx):
        async def handler(route):
            u=urlparse(route.request.url)
            if u.path=='/rpc':
                cid=parse_qs(u.query).get('id',[''])[0]
                await asyncio.sleep(.025)
                calls[cid]=calls.get(cid,0)+1
                await route.fulfill(status=200,content_type='application/json',body=json.dumps({'ok':True,'id':cid}))
                return
            rel=u.path.lstrip('/') or 'index.html'; f=(ROOT/rel).resolve()
            if ROOT not in f.parents and f!=ROOT:
                await route.fulfill(status=403,body='forbidden'); return
            if not f.exists():
                await route.fulfill(status=404,body='missing'); return
            ctype=mimetypes.guess_type(str(f))[0] or ('text/javascript' if f.suffix=='.js' else 'application/octet-stream')
            await route.fulfill(status=200,content_type=ctype,body=f.read_bytes())
        await ctx.route('https://fieldone.test/**',handler)

    def watch(page):
        page.on('pageerror', lambda exc: browser_errors.append('pageerror: '+str(exc)))
        page.on('console', lambda msg: browser_errors.append('console.error: '+msg.text) if msg.type=='error' else None)

    async def ready(page):
        watch(page)
        await page.goto(BASE)
        await page.wait_for_function('window.ready === true')

    with tempfile.TemporaryDirectory(prefix='fieldone-p10-') as profile:
        async with async_playwright() as pw:
            browser_path=os.environ.get('PHASE10_CHROMIUM_PATH')
            launch_args={'headless':True,'args':['--no-sandbox']}
            if browser_path: launch_args['executable_path']=browser_path
            ctx=await pw.chromium.launch_persistent_context(profile,**launch_args)
            await install_routes(ctx)
            pages=[ctx.pages[0]]+[await ctx.new_page() for _ in range(3)]
            try:
                await asyncio.gather(*(ready(p) for p in pages))
            except Exception as exc:
                print('BLOCKED F-153/F-154 browser runtime: '+str(exc), flush=True)
                await ctx.close()
                raise SystemExit(2)

            # F-153: four tabs enqueue disjoint records simultaneously while two tabs drain.
            batches=[ids[i::4] for i in range(4)]
            await asyncio.gather(*[
                asyncio.gather(*[p.evaluate('(x)=>api.enqueueCommand(x)',command(cid,owner,idx)) for idx,cid in enumerate(batch)])
                for p,batch in zip(pages,batches)
            ])
            await asyncio.gather(pages[0].evaluate('(o)=>api.processQueue(o)',owner), pages[1].evaluate('(o)=>api.processQueue(o)',owner))
            await asyncio.gather(pages[2].evaluate('(o)=>api.processQueue(o)',owner), pages[3].evaluate('(o)=>api.processQueue(o)',owner))
            q=await pages[0].evaluate('(o)=>api.getQueueForOwner(o)',owner)
            print("QUEUE LENGTH:", len(q))
            if len(q) > 0: print("FIRST ITEM:", q[0])
            target=[x for x in q if x['id'] in ids]
            if browser_errors: print("BROWSER ERRORS:", browser_errors)
            assert len(target)==TOTAL, (len(target),TOTAL)
            assert all(x['state']=='confirmed' for x in target), {x['id']:x['state'] for x in target}
            assert all(calls.get(i)==1 for i in ids), {i:calls.get(i) for i in ids if calls.get(i)!=1}
            assert len({x['id'] for x in target})==TOTAL
            print(f'PASS F-153 real Chromium multi-context race: {TOTAL} commands preserved and each executed exactly once across four tabs')

            # F-154: persist three commands, strand one in syncing with expired lease, close entire browser context.
            for n,cid in enumerate(restart_ids):
                await pages[0].evaluate('(x)=>api.enqueueCommand(x)',command(cid,owner,100+n))
            await pages[0].evaluate('''async (id)=>{const d=await new Promise((ok,fail)=>{const r=indexedDB.open('FieldOneHarness',1);r.onsuccess=()=>ok(r.result);r.onerror=()=>fail(r.error)});await new Promise((ok,fail)=>{const t=d.transaction('kv','readwrite'),s=t.objectStore('kv'),r=s.get('OutboxV2:'+id);r.onsuccess=()=>{const v=r.result;v.state='syncing';v.leaseOwner='dead-worker';v.leaseExpiresAt='2020-01-01T00:00:00.000Z';s.put(v,'OutboxV2:'+id)};t.oncomplete=()=>ok();t.onerror=()=>fail(t.error)});d.close()}''',restart_ids[0])
            before=await pages[0].evaluate('(o)=>api.getQueueForOwner(o)',owner)
            assert {x['id'] for x in before if x['id'] in restart_ids}==set(restart_ids)
            await ctx.close()

            ctx2=await pw.chromium.launch_persistent_context(profile,**launch_args)
            await install_routes(ctx2)
            p=ctx2.pages[0]; await ready(p)
            await p.evaluate('(o)=>api.processQueue(o)',owner)
            q2=await p.evaluate('(o)=>api.getQueueForOwner(o)',owner)
            after=[x for x in q2 if x['id'] in restart_ids]
            assert len(after)==3 and all(x['state']=='confirmed' for x in after), after
            assert all(calls.get(i)==1 for i in restart_ids), {i:calls.get(i) for i in restart_ids}
            assert not browser_errors, browser_errors
            print('PASS F-154 real Chromium persistent-profile restart: queued plus expired-syncing commands recovered with original stable ids and executed once')
            print('PASS Phase 10 outbox browser proof: no uncaught page errors or console.error messages')
            await ctx2.close()

if __name__=='__main__': asyncio.run(run())
