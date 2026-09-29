#!/usr/bin/env python3
import asyncio
import os
import sys
from pathlib import Path
from playwright.async_api import async_playwright

APP = os.environ.get('PHASE11_APP_URL', 'http://127.0.0.1:4173')
EMAIL = os.environ.get('PHASE11_TEST_EMAIL', 'phase10-runtime@example.test')
PASSWORD = os.environ.get('PHASE11_TEST_PASSWORD', 'Phase10!Runtime123')
CENTRAL = '33333333-3333-3333-3333-333333333331'
DOWNTOWN = '1a1a1a1a-1a1a-1a1a-1a1a-1a1a1a1a1a11'
EVIDENCE = Path(os.environ.get('PHASE11_EVIDENCE_DIR', '.phase11-evidence')) / 'e2e'
EVIDENCE.mkdir(parents=True, exist_ok=True)

def access_summary(page):
    # The authenticated-context text lives inside a collapsed <details> panel and
    # is intentionally hidden until the user opens it. The summary itself is the
    # stable, visible authenticated-shell signal.
    return page.locator('summary').filter(has_text='Access').first

async def wait_for_authenticated_shell(page, timeout=15000):
    await access_summary(page).wait_for(state='visible', timeout=timeout)

async def authenticate(page):
    await page.goto(APP, wait_until='domcontentloaded')
    summary = access_summary(page)
    if await summary.count() and await summary.is_visible():
        return
    await page.get_by_label('Email address').fill(EMAIL)
    await page.get_by_label('Password').fill(PASSWORD)
    await page.get_by_role('button', name='Sign in securely').click()
    await wait_for_authenticated_shell(page)

async def select_warehouse(page, warehouse_id):
    summary = page.locator('summary')
    if await summary.count():
        await summary.first.click()
    select = page.get_by_label('Active warehouse')
    await select.select_option(warehouse_id)
    # Do not race the warehouse-scoped React Query. First prove the UI context
    # actually accepted the requested warehouse, then allow the query to settle.
    for _ in range(30):
        if await select.input_value() == warehouse_id:
            break
        await page.wait_for_timeout(100)
    if await select.input_value() != warehouse_id:
        raise RuntimeError(f'warehouse selection did not switch to {warehouse_id}')
    await page.wait_for_timeout(800)
    if await summary.count():
        await summary.first.click()

async def open_work(page):
    await page.get_by_role('button', name='Work').click()
    await page.get_by_text('My Work').wait_for(timeout=10000)

async def click_work_task(page, ref):
    # TaskRow renders the reference as part of the button accessible name
    # (for example, "Receive TR-00291"), not as a standalone text node.
    # Match the actual interactive task row by role + contained reference.
    task = page.get_by_role('button').filter(has_text=ref).first
    await task.wait_for(state='visible', timeout=30000)
    await task.click()

async def run_flow(name, func, browser):
    log_file = EVIDENCE / f'{name}.log'
    screenshot = EVIDENCE / f'{name}-failure.png'
    ctx = await browser.new_context()
    page = await ctx.new_page()
    errors = []
    page.on('console', lambda msg: errors.append(f'console:{msg.type}: {msg.text}') if msg.type == 'error' else None)
    page.on('pageerror', lambda exc: errors.append(f'pageerror: {exc}'))
    status = 'PASS'
    try:
        await func(page, ctx)
    except Exception as exc:
        status = f'FAIL: {exc}'
        errors.append(str(exc))
        try:
            await page.screenshot(path=str(screenshot), full_page=True)
        except Exception:
            pass
    finally:
        log_file.write_text(
            f'Flow: {name}\nStatus: {status}\nURL: {page.url}\nErrors:\n' + '\n'.join(errors) + '\n',
            encoding='utf-8',
        )
        await ctx.close()
    print(f'E2E Flow {name}: {status}')
    if status != 'PASS':
        raise RuntimeError(f'{name} failed')

async def auth_flow(page, ctx):
    await authenticate(page)
    summary = access_summary(page)
    await summary.click()
    await page.get_by_label('Active company').wait_for(state='visible', timeout=5000)
    await page.get_by_label('Active warehouse').wait_for(state='visible', timeout=5000)

async def receive_flow(page, ctx):
    await authenticate(page)
    await select_warehouse(page, DOWNTOWN)
    await open_work(page)
    await click_work_task(page, 'TR-00291')
    await page.get_by_role('button', name='Scan to receive').wait_for(timeout=10000)
    await page.get_by_role('button', name='Scan to receive').click()
    await page.get_by_role('button', name='Manual').click()
    await page.get_by_placeholder('Exact SKU / barcode / GTIN').fill('MIRO-LAP-14')
    await page.get_by_role('button', name='Resolve exact').click()
    if await page.get_by_text('Choose the exact document line').count():
        await page.get_by_text('Line 4', exact=False).first.click()
    await page.get_by_role('button', name='Receive line').click()
    await page.get_by_role('button', name='Save as accepted').click()
    await page.get_by_text('Saved', exact=True).first.wait_for(timeout=10000)

async def dispatch_flow(page, ctx):
    await authenticate(page)
    await select_warehouse(page, CENTRAL)
    await open_work(page)
    await click_work_task(page, 'SO-18420')
    await page.get_by_text('MIRO-LAP-14', exact=False).first.click()
    await page.get_by_role('button', name='Save pick').click()
    await page.get_by_text('Saved', exact=True).first.wait_for(timeout=10000)

async def count_flow(page, ctx):
    await authenticate(page)
    await select_warehouse(page, CENTRAL)
    await open_work(page)
    await click_work_task(page, 'CC-0093')
    await page.get_by_role('button', name='Continue counting').click()
    qty = page.locator('input[inputmode="decimal"]').first
    await qty.fill('10')
    await page.get_by_role('button', name='Save observation').click()
    await page.get_by_text('Saved', exact=True).first.wait_for(timeout=10000)

async def recovery_flow(page, ctx):
    await authenticate(page)
    await select_warehouse(page, CENTRAL)
    await ctx.set_offline(True)
    await page.evaluate("window.dispatchEvent(new Event('offline'))")
    await page.get_by_role('button', name='Scan').click()
    await page.get_by_role('button', name='Manual').click()
    await page.get_by_placeholder('Exact SKU / barcode / GTIN').fill('P11-OFFLINE-UNKNOWN')
    await page.get_by_role('button', name='Resolve exact').click()
    await page.get_by_role('button', name='Report unknown').click()
    await page.get_by_text('Unknown scan saved').wait_for(timeout=10000)
    await ctx.set_offline(False)
    await page.evaluate("window.dispatchEvent(new Event('online'))")
    await page.get_by_role('button', name='Home').click()
    await page.get_by_role('button', name='Sync').click()
    await page.get_by_role('button', name='Process pending commands').click()
    await page.get_by_text('All commands confirmed').wait_for(timeout=30000)

async def main():
    async with async_playwright() as pw:
        browser = await pw.chromium.launch(headless=True, args=['--no-sandbox'])
        try:
            for name, fn in [
                ('auth', auth_flow),
                ('receive', receive_flow),
                ('dispatch', dispatch_flow),
                ('count', count_flow),
                ('recovery', recovery_flow),
            ]:
                await run_flow(name, fn, browser)
        finally:
            await browser.close()

if __name__ == '__main__':
    try:
        asyncio.run(main())
    except Exception as exc:
        print(f'Phase 11 E2E FAILED: {exc}', file=sys.stderr)
        sys.exit(1)
