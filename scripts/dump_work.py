import asyncio, os
from playwright.async_api import async_playwright

APP=os.environ.get('PHASE10_APP_URL','http://127.0.0.1:4173')
EMAIL=os.environ.get('PHASE10_TEST_EMAIL','phase10-runtime@example.test')
PASSWORD=os.environ.get('PHASE10_TEST_PASSWORD','Phase10!Runtime123')

async def main():
    async with async_playwright() as pw:
        launch_args={'headless':True,'args':['--no-sandbox']}
        browser=await pw.chromium.launch(**launch_args)
        ctx=await browser.new_context()
        page=await ctx.new_page()
        
        await page.goto(APP,wait_until='domcontentloaded')
        await page.get_by_label('Email').fill(EMAIL)
        await page.get_by_label('Password').fill(PASSWORD)
        await page.get_by_role('button',name='Sign in').click()
        await page.get_by_text('Authenticated operational context').wait_for(timeout=15000)
        
        await page.get_by_role('button',name='Work').click()
        await page.wait_for_timeout(3000)
        
        print(await page.content())
        await browser.close()

if __name__=='__main__': asyncio.run(main())
