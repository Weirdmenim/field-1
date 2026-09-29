import { chromium } from "playwright";
import fs from "fs";

(async () => {
  const browser = await chromium.launch({ headless: true, args: ["--no-sandbox"] });
  const context = await browser.newContext();
  const page = await context.newPage();

  page.on("pageerror", (err) => console.log("PAGE ERROR:", err));
  page.on("console", (msg) => {
    if (msg.type() === "error") console.log("CONSOLE ERROR:", msg.text());
  });
  page.on("response", (res) => {
    if (res.status() >= 400) console.log("RESPONSE:", res.status(), res.url());
  });

  await page.goto("http://127.0.0.1:4173");
  await page.getByLabel("Email").fill("phase10-runtime@example.test");
  await page.getByLabel("Password").fill("Phase10!Runtime123");
  await page.getByRole("button", { name: "Sign in" }).click();
  await page.getByText("Authenticated operational context").waitFor({ state: "attached", timeout: 15000 });
  
  await page.getByRole("button", { name: "Work" }).click();
  
  // wait 5 seconds for network
  await page.waitForTimeout(5000);
  
  const html = await page.content();
  fs.writeFileSync("work_tab_dump.html", html);
  
  await browser.close();
})();
