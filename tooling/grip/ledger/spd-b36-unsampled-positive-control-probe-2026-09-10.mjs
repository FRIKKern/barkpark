// Live positive control for occlusion.unsampled_occluder_census: run the
// SHIPPED PAGE_MEASURE on a real paper doc, first clean, then with the format
// bubble actually open, and print the census both times.
import { createRequire } from 'node:module';
import fs from 'node:fs'; import os from 'node:os'; import path from 'node:path';
const WT = process.argv[2], DOC = process.argv[3];
const { PAGE_MEASURE } = await import(path.join(WT, 'scripts/studio-desk-measure.mjs'));
const require_ = createRequire('/Volumes/SATECHI/github/barkpark/js/x.js');
const { chromium } = require_('playwright');
const cfg = JSON.parse(fs.readFileSync(path.join(os.homedir(), '.config/barkpark/config.json'), 'utf8'));
const srv = (cfg.known_servers || []).find((s) => s.name === 'guerrilla');
const base = String(srv.server).replace(/\/+$/, '');
const r = await fetch(`${base}/v1/auth/login-tickets`, { method: 'POST', headers: { Authorization: `Bearer ${srv.token}`, 'Content-Type': 'application/json' }, body: '{}' });
const { ticket } = await r.json();
const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
const out = {};
try {
  await page.goto(`${base}/login/ticket/${ticket}`, { waitUntil: 'domcontentloaded' });
  await page.goto(base + DOC, { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('.bp-paper-surface', { timeout: 20000 });
  await page.waitForTimeout(2500);
  const run = async (label) => {
    const rec = await page.evaluate(`(${PAGE_MEASURE})(null)`);
    out[label] = {
      fatal: rec.fatal || null,
      visible_content_px: rec.visible_content_px,
      content_px: rec.content_px,
      unsampled: rec.occlusion && rec.occlusion.unsampled_occluder_census,
      invisible: rec.occlusion && rec.occlusion.invisible_occluder_census,
    };
  };
  await run('clean');
  await page.locator('.bp-paper-surface').first().click({ button: 'right', timeout: 6000 }).catch(e => { out.rightclick_error = String(e.message).slice(0,150); });
  await page.waitForTimeout(600);
  await page.evaluate(() => {
    const s = document.querySelector('.bp-paper-surface');
    const p = s && s.querySelector('p, h1, h2, li');
    if (!p) return;
    const rng = document.createRange(); rng.selectNodeContents(p);
    const sel = getSelection(); sel.removeAllRanges(); sel.addRange(rng);
    p.dispatchEvent(new MouseEvent('mouseup', { bubbles: true }));
    document.dispatchEvent(new Event('selectionchange'));
  });
  await page.waitForTimeout(1200);
  out.format_bubble_present = await page.evaluate(() => {
    const e = document.querySelector('.bp-paper-format');
    if (!e) return null;
    const b = e.getBoundingClientRect(); const c = getComputedStyle(e);
    return { w: b.width, h: b.height, top: b.top, left: b.left, pe: c.pointerEvents, z: c.zIndex, pos: c.position };
  });
  await run('with_format_bubble');
} catch (e) { out.fatal = String(e.stack).slice(0, 800); }
finally { await browser.close(); console.log(JSON.stringify(out, null, 2)); }
