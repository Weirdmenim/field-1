import asyncio
import os
from pathlib import Path
from playwright.async_api import async_playwright

APP = os.environ.get('PHASE10_APP_URL', 'http://127.0.0.1:4173')
EMAIL = os.environ.get('PHASE10_TEST_EMAIL', 'phase10-runtime@example.test')
PASSWORD = os.environ.get('PHASE10_TEST_PASSWORD', 'Phase10!Runtime123')
TEST_WAREHOUSE_ID = os.environ.get('PHASE10_TEST_WAREHOUSE_ID', '33333333-3333-3333-3333-333333333331')
EVIDENCE = Path(os.environ.get('PHASE10_EVIDENCE_DIR', '.phase10-evidence'))

async def capture_failure(page, browser_errors):
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    try:
        await page.screenshot(path=str(EVIDENCE / 'browser-duplicate-bin-failure.png'), full_page=True)
    except Exception:
        pass
    try:
        body = await page.locator('body').inner_text()
        (EVIDENCE / 'browser-duplicate-bin-visible-text.txt').write_text(body, encoding='utf-8')
    except Exception:
        pass
    try:
        (EVIDENCE / 'browser-duplicate-bin-url.txt').write_text(page.url, encoding='utf-8')
    except Exception:
        pass
    (EVIDENCE / 'browser-duplicate-bin-console.txt').write_text('\n'.join(browser_errors), encoding='utf-8')

async def main():
    async with async_playwright() as pw:
        browser_path = os.environ.get('PHASE10_CHROMIUM_PATH')
        launch_args = {'headless': True, 'args': ['--no-sandbox']}
        if browser_path:
            launch_args['executable_path'] = browser_path
        browser = await pw.chromium.launch(**launch_args)
        ctx = await browser.new_context()
        page = await ctx.new_page()
        browser_errors = []
        page.on('pageerror', lambda exc: browser_errors.append('pageerror: ' + str(exc)))
        page.on('console', lambda msg: browser_errors.append('console.error: ' + msg.text) if msg.type == 'error' else None)
        try:
            await page.goto(APP, wait_until='domcontentloaded')
            await page.get_by_label('Email').fill(EMAIL)
            await page.get_by_label('Password').fill(PASSWORD)
            await page.get_by_role('button', name='Sign in').click()
            await page.get_by_text('Authenticated operational context').wait_for(timeout=15000)

            # Do not depend on alphabetical warehouse ordering or persisted browser selection.
            # The F-157 fixtures are created in the canonical Phase 10 warehouse.
            summary = page.locator('summary').filter(has_text='Access').first
            await summary.click()
            await page.get_by_label('Active warehouse').select_option(TEST_WAREHOUSE_ID)
            await page.get_by_text('Authenticated operational context').wait_for(timeout=5000)
            await summary.click()

            work_buttons = page.get_by_role('button', name='Work', exact=True)
            if await work_buttons.count() == 0:
                raise AssertionError('Work navigation button not found')
            await work_buttons.last.click()

            task = page.get_by_text('Dispatch P10-DUP-BIN', exact=False)
            await task.wait_for(timeout=20000)
            await task.click()
            await page.get_by_role('button', name='Scan to pick').click()
            await page.get_by_role('button', name='Manual').click()
            await page.get_by_placeholder('Exact SKU / barcode / GTIN').fill(' MIRO-LAP-14 ')
            await page.get_by_role('button', name='Resolve exact').click()
            await page.get_by_text('Choose the exact document line').wait_for(timeout=10000)
            a = page.get_by_role('button', name='Line 1 · Bin P10-DUP-A', exact=False)
            b = page.get_by_role('button', name='Line 2 · Bin P10-DUP-B', exact=False)
            assert await a.count() == 1 and await b.count() == 1
            await b.click()
            await page.get_by_text('Exact match').wait_for()
            await page.get_by_text('Bin P10-DUP-B', exact=False).wait_for()
            await page.get_by_role('button', name='Confirm pick').click()
            await page.get_by_text('Bin P10-DUP-B', exact=False).wait_for(timeout=10000)
            assert not browser_errors, browser_errors
            print('PASS F-157 real browser workflow: exact duplicate SKU required line/bin disambiguation and selected bin B flowed into Dispatch')
            print('PASS F-157 browser proof: no uncaught page errors or console.error messages')
        except Exception:
            await capture_failure(page, browser_errors)
            raise
        finally:
            await browser.close()

if __name__ == '__main__':
    asyncio.run(main())
