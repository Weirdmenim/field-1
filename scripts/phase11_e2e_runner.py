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


async def locator_visible(locator):
    try:
        return await locator.count() > 0 and await locator.first.is_visible()
    except Exception:
        return False


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
    summary = access_summary(page)
    if await summary.count():
        await summary.click()
    select = page.get_by_label('Active warehouse')
    await select.wait_for(state='visible', timeout=5000)
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
        await summary.click()


async def open_work(page):
    await page.get_by_role('button', name='Work').click()
    await page.get_by_text('My Work').wait_for(timeout=10000)


async def click_work_task(page, ref):
    # TaskRow renders the reference as part of the button accessible name
    # (for example, "Receive TR-00291"), not as a standalone text node.
    task = page.get_by_role('button').filter(has_text=ref).first
    await task.wait_for(state='visible', timeout=30000)
    await task.click()


async def open_document_line(page, sku):
    """Open a line from an overview screen, or accept an already-open execution state."""
    qty = page.locator('input[inputmode="decimal"]').first
    if await locator_visible(qty):
        return qty
    line = page.get_by_role('button').filter(has_text=sku).first
    await line.wait_for(state='visible', timeout=15000)
    await line.click()
    await qty.wait_for(state='visible', timeout=10000)
    return qty


async def sync_current_commands(page):
    # Completion screens expose View in Sync Center. Recovery and fallback paths
    # may already be elsewhere, so fall back to the bottom navigation Sync button.
    view_sync = page.get_by_role('button', name='View in Sync Center')
    if await locator_visible(view_sync):
        await view_sync.click()
    else:
        sync_nav = page.get_by_role('button', name='Sync')
        if await locator_visible(sync_nav):
            await sync_nav.click()
    await page.get_by_text('Sync Center', exact=True).first.wait_for(timeout=10000)

    confirmed = page.get_by_text('All commands confirmed', exact=True)
    if await locator_visible(confirmed):
        return

    process = page.get_by_role('button', name='Process pending commands')
    await process.wait_for(state='visible', timeout=10000)
    await process.click()
    await confirmed.wait_for(state='visible', timeout=30000)


async def run_flow(name, func, browser):
    log_file = EVIDENCE / f'{name}.log'
    screenshot = EVIDENCE / f'{name}-failure.png'
    ctx = await browser.new_context()
    page = await ctx.new_page()
    errors = []
    visible_ui = ''
    page.on('console', lambda msg: errors.append(f'console:{msg.type}: {msg.text}') if msg.type == 'error' else None)
    page.on('pageerror', lambda exc: errors.append(f'pageerror: {exc}'))
    status = 'PASS'
    try:
        await func(page, ctx)
    except Exception as exc:
        status = f'FAIL: {exc}'
        errors.append(str(exc))
        try:
            visible_ui = (await page.locator('body').inner_text())[:12000]
        except Exception:
            visible_ui = '<unable to capture body text>'
        try:
            await page.screenshot(path=str(screenshot), full_page=True)
        except Exception:
            pass
    finally:
        log_file.write_text(
            f'Flow: {name}\nStatus: {status}\nURL: {page.url}\nErrors:\n' + '\n'.join(errors) +
            (f'\nVisible UI at failure:\n{visible_ui}\n' if visible_ui else '\n'),
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
    await page.get_by_text('Receive Transfer', exact=True).first.wait_for(timeout=10000)

    # Phase 10 already proves scanner ambiguity/resolution. Phase 11 proves the
    # complete authoritative receipt workflow without coupling the test to a
    # particular overview-vs-post-scan presentation state.
    qty = await open_document_line(page, 'MIRO-LAP-14')
    await qty.fill('5')
    save = page.get_by_role('button', name='Save as accepted')
    await save.wait_for(state='visible', timeout=10000)
    await save.click()

    await page.get_by_text('Review & queue', exact=True).first.wait_for(timeout=10000)
    await page.get_by_text('Ready to queue authoritative receipt', exact=True).wait_for(timeout=10000)
    await page.get_by_role('button', name='Queue receipt').click()
    await sync_current_commands(page)


async def dispatch_flow(page, ctx):
    await authenticate(page)
    await select_warehouse(page, CENTRAL)
    await open_work(page)
    await click_work_task(page, 'SO-18420')
    await page.get_by_text('Dispatch', exact=True).first.wait_for(timeout=10000)

    # The seeded order contains two open lines. Capture both at their requested
    # quantity so the document can reach its authoritative dispatch gate.
    for _ in range(2):
        qty = await open_document_line(page, 'MIRO-LAP-14')
        await qty.fill('5')
        save = page.get_by_role('button', name='Save pick')
        await save.wait_for(state='visible', timeout=10000)
        await save.click()

    await page.get_by_text('Review dispatch', exact=True).first.wait_for(timeout=10000)
    await page.get_by_text('Ready to queue authoritative dispatch', exact=True).wait_for(timeout=10000)
    await page.get_by_role('button', name='Queue dispatch').click()
    await sync_current_commands(page)


async def count_flow(page, ctx):
    await authenticate(page)
    await select_warehouse(page, CENTRAL)
    await open_work(page)
    await click_work_task(page, 'CC-0093')
    await page.get_by_text('Cycle Count', exact=True).first.wait_for(timeout=10000)
    await page.get_by_role('button', name='Continue counting').click()
    qty = page.locator('input[inputmode="decimal"]').first
    await qty.wait_for(state='visible', timeout=10000)
    await qty.fill('10')
    await page.get_by_role('button', name='Save observation').click()
    await page.get_by_text('Observations queued', exact=True).first.wait_for(timeout=10000)
    await sync_current_commands(page)


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
