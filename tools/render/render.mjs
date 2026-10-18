// Usage: node render.mjs <outDir> [view ...]
// Serves this folder over HTTP, renders each camera in views.json with headless
// Chromium (SwiftShader WebGL), and writes <outDir>/<view>.png.
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright-core';

const here = path.dirname(fileURLToPath(import.meta.url));
const outDir = path.resolve(process.argv[2] || path.join(here, 'out'));
const only = process.argv.slice(3);
fs.mkdirSync(outDir, { recursive: true });

const types = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.json': 'application/json' };
const server = http.createServer((req, res) => {
  const url = decodeURIComponent(req.url.split('?')[0]);
  const file = path.join(here, url === '/' ? 'render.html' : url);
  if (!file.startsWith(here) || !fs.existsSync(file)) { res.writeHead(404); res.end(); return; }
  res.writeHead(200, { 'Content-Type': types[path.extname(file)] || 'application/octet-stream' });
  fs.createReadStream(file).pipe(res);
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const port = server.address().port;

const browser = await chromium.launch({
  executablePath: process.env.CHROMIUM || '/opt/pw-browsers/chromium_headless_shell-1194/chrome-linux/headless_shell',
  args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist', '--use-gl=angle'],
});
const page = await browser.newPage({ viewport: { width: 1280, height: 720 } });
page.on('console', (m) => { if (m.type() === 'error') console.error('[page]', m.text()); });
page.on('pageerror', (e) => console.error('[pageerror]', e.message));
await page.goto(`http://127.0.0.1:${port}/`, { waitUntil: 'load' });
await page.waitForFunction(() => window.ready === true, null, { timeout: 180000 });
const names = only.length ? only : await page.evaluate(() => window.viewNames);
for (const name of names) {
  const t0 = Date.now();
  await page.evaluate((n) => window.renderView(n), name);
  const file = path.join(outDir, `${name}.png`);
  await page.locator('canvas').screenshot({ path: file });
  console.log(`${name}.png  (${Date.now() - t0} ms)`);
}
await browser.close();
server.close();
