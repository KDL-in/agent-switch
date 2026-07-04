import { chromium } from 'playwright';

const BASE = 'http://localhost:3000';

const browser = await chromium.launch({ headless: true });
const context = await browser.newContext();
const page = await context.newPage();

const errors = [];
const apiCalls = [];
page.on('pageerror', (err) => errors.push(`pageerror: ${err.message}`));
page.on('console', (msg) => {
  if (msg.type() === 'error') errors.push(`console: ${msg.text()}`);
});
page.on('requestfailed', (req) => {
  errors.push(`requestfailed: ${req.url()} -> ${req.failure()?.errorText}`);
});
page.on('response', (resp) => {
  const url = resp.url();
  if (url.includes('/api/')) {
    apiCalls.push({ url, status: resp.status() });
  }
});

const checks = [];

try {
  const resp = await page.goto(BASE, { waitUntil: 'networkidle', timeout: 30000 });
  checks.push({ name: 'homepage', ok: resp?.status() === 200 });

  await page.waitForSelector('#root', { timeout: 10000 });
  checks.push({ name: 'root-mounted', ok: true });

  const title = await page.title();
  checks.push({ name: 'title', ok: title.includes('Claude Code') || title.includes('CC Switch'), value: title });

  const addBtn = page.getByRole('button', { name: /添加供应商/ });
  checks.push({ name: 'add-provider-button', ok: (await addBtn.count()) > 0 });

  const navItems = ['MCP', 'Skills', '用量'];
  for (const item of navItems) {
    const el = page.getByText(item, { exact: false }).first();
    checks.push({ name: `nav-${item}`, ok: (await el.count()) > 0 });
  }

  const failedApis = apiCalls.filter((c) => c.status >= 400);
  checks.push({ name: 'api-calls', ok: failedApis.length === 0, value: apiCalls, failed: failedApis });

  const ok = checks.every((c) => c.ok) && errors.length === 0;
  console.log(JSON.stringify({ ok, checks, errors }, null, 2));
  if (!ok) process.exitCode = 1;
} catch (err) {
  console.log(JSON.stringify({ ok: false, error: String(err), checks, errors }, null, 2));
  process.exitCode = 1;
} finally {
  await browser.close();
}
