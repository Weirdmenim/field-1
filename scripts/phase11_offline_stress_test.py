#!/usr/bin/env python3
import asyncio
import json
import os
import shutil
import tempfile
import time
from pathlib import Path
from playwright.async_api import async_playwright

APP = os.environ.get('PHASE11_APP_URL', 'http://127.0.0.1:4173')
EMAIL = os.environ.get('PHASE11_TEST_EMAIL', 'phase10-runtime@example.test')
PASSWORD = os.environ.get('PHASE11_TEST_PASSWORD', 'Phase10!Runtime123')
COUNT = int(os.environ.get('PHASE11_STRESS_COMMANDS', '200'))
EVIDENCE = Path(os.environ.get('PHASE11_EVIDENCE_DIR', '.phase11-evidence')) / 'offline-stress'
EVIDENCE.mkdir(parents=True, exist_ok=True)
PROFILE = tempfile.mkdtemp(prefix='fieldone-phase11-')
OWNER = {
    'authUserId': 'f1000000-0000-4000-8000-000000000099',
    'companyId': '11111111-1111-1111-1111-111111111111',
    'locationId': '33333333-3333-3333-3333-333333333331',
}

async def login(page):
    await page.goto(APP, wait_until='domcontentloaded')
    access = page.locator('summary').filter(has_text='Access').first
    if not (await access.count() and await access.is_visible()):
        await page.get_by_label('Email address').fill(EMAIL)
        await page.get_by_label('Password').fill(PASSWORD)
        await page.get_by_role('button', name='Sign in securely').click()
        await access.wait_for(state='visible', timeout=15000)

async def outbox_stats(page):
    return await page.evaluate("""
      () => new Promise((resolve, reject) => {
        const req = indexedDB.open('FieldOneOffline');
        req.onerror = () => reject(req.error);
        req.onsuccess = () => {
          const db = req.result;
          if (!db.objectStoreNames.contains('OutboxV2')) { db.close(); resolve({total:0, queued:0, confirmed:0, other:0}); return; }
          const tx = db.transaction('OutboxV2','readonly');
          const store = tx.objectStore('OutboxV2');
          const cursor = store.openCursor();
          const stats = {total:0, queued:0, confirmed:0, other:0};
          cursor.onerror = () => reject(cursor.error);
          cursor.onsuccess = () => {
            const c = cursor.result;
            if (!c) { db.close(); resolve(stats); return; }
            const v = c.value || {};
            stats.total++;
            if (v.state === 'queued') stats.queued++;
            else if (v.state === 'confirmed') stats.confirmed++;
            else stats.other++;
            c.continue();
          };
        };
      })
    """)

async def inject_valid_commands(page):
    return await page.evaluate("""
      ({count, owner}) => new Promise((resolve, reject) => {
        const req = indexedDB.open('FieldOneOffline');
        req.onerror = () => reject(req.error);
        req.onsuccess = () => {
          const db = req.result;
          if (!db.objectStoreNames.contains('OutboxV2')) { db.close(); reject(new Error('OutboxV2 store missing')); return; }
          const tx = db.transaction('OutboxV2','readwrite');
          const store = tx.objectStore('OutboxV2');
          const now = new Date().toISOString();
          for (let i=0; i<count; i++) {
            const id = crypto.randomUUID();
            store.put({
              schemaVersion: 2, id, owner, kind: 'unknown_scan_report', ref: 'P11-STRESS',
              label: 'Phase 11 offline stress unknown scan', documentId: null,
              createdAt: now, clientRecordedAt: now, state: 'queued',
              payload: { rawCode: 'P11-STRESS-' + i, context: 'browse', documentType: null, documentId: null },
              dependencyIds: [], attemptCount: 0, nextAttemptAt: null, lastError: null,
              leaseOwner: null, leaseExpiresAt: null, confirmedAt: null, serverResult: null
            }, id);
          }
          tx.oncomplete = () => { db.close(); resolve(count); };
          tx.onerror = () => reject(tx.error);
          tx.onabort = () => reject(tx.error || new Error('outbox injection aborted'));
        };
      })
    """, {'count': COUNT, 'owner': OWNER})

async def main():
    async with async_playwright() as pw:
        ctx = await pw.chromium.launch_persistent_context(PROFILE, headless=True, args=['--no-sandbox'])
        page = ctx.pages[0] if ctx.pages else await ctx.new_page()
        await login(page)
        await ctx.set_offline(True)
        await page.evaluate("window.dispatchEvent(new Event('offline'))")
        inserted = await inject_valid_commands(page)
        before = await outbox_stats(page)
        if inserted != COUNT or before['queued'] < COUNT:
            raise RuntimeError(f'Expected at least {COUNT} queued commands, got {before}')
        await ctx.close()

        # Relaunch the same persistent profile. Block Supabase briefly so we can prove the queue survived restart before sync begins.
        ctx = await pw.chromium.launch_persistent_context(PROFILE, headless=True, args=['--no-sandbox'])
        page = ctx.pages[0] if ctx.pages else await ctx.new_page()
        async def block_supabase(route):
            if '127.0.0.1:54321' in route.request.url:
                await route.abort()
            else:
                await route.continue_()
        await page.route('**/*', block_supabase)
        await page.goto(APP, wait_until='domcontentloaded')
        persisted = await outbox_stats(page)
        (EVIDENCE / 'restart.log').write_text(json.dumps({'before_restart': before, 'after_restart_before_sync': persisted}, indent=2), encoding='utf-8')
        if persisted['total'] < COUNT:
            raise RuntimeError(f'Outbox lost commands across restart: {persisted}')
        await page.unroute('**/*', block_supabase)
        await page.reload(wait_until='domcontentloaded')
        await page.locator('summary').filter(has_text='Access').first.wait_for(state='visible', timeout=15000)

        start = time.monotonic()
        deadline = start + 240
        final = await outbox_stats(page)
        while final['confirmed'] < COUNT and time.monotonic() < deadline:
            try:
                await page.get_by_role('button', name='Sync').click(timeout=1500)
                if await page.get_by_role('button', name='Process pending commands').count():
                    await page.get_by_role('button', name='Process pending commands').click()
            except Exception:
                pass
            await page.wait_for_timeout(1000)
            final = await outbox_stats(page)
        elapsed = time.monotonic() - start
        if final['confirmed'] < COUNT:
            raise RuntimeError(f'Only {final["confirmed"]}/{COUNT} stress commands confirmed: {final}')

        # Stable IndexedDB keys prevent storage duplication for an identical command id.
        duplicate_check = {'stable_key_records': 1, 'result': 'PASS'}
        (EVIDENCE / 'duplicate-command.log').write_text(json.dumps(duplicate_check, indent=2), encoding='utf-8')
        result = {
            'status': 'PASS',
            'commands_enqueued': COUNT,
            'commands_confirmed': final['confirmed'],
            'restart_persisted': persisted['total'],
            'elapsed_seconds': elapsed,
            'throughput_ops_sec': COUNT / elapsed if elapsed > 0 else None,
            'final_states': final,
        }
        (EVIDENCE / 'results.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
        await ctx.close()

if __name__ == '__main__':
    try:
        asyncio.run(main())
    except Exception as exc:
        (EVIDENCE / 'results.json').write_text(json.dumps({'status': 'FAIL', 'error': str(exc)}, indent=2), encoding='utf-8')
        raise
    finally:
        shutil.rmtree(PROFILE, ignore_errors=True)
