// spd-b36 browser census probe. Read-only against deployed guerrilla.
// Drills to a paper document, then for each named occluder family records
// whether it can be present with the surface open, whether it overlaps the
// measured band, and whether the D112 hit-test / the invisible-occluder
// census would see it.
import { createRequire } from 'node:module';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';

const REPO = execFileSync('git', ['rev-parse', '--path-format=absolute', '--git-common-dir'],
  { cwd: process.argv[2] || process.cwd(), encoding: 'utf8' }).trim().replace(/\/\.git$/, '');
const require_ = createRequire(path.join(REPO, 'js', 'x.js'));
const { chromium } = require_('playwright');

const cfg = JSON.parse(fs.readFileSync(path.join(os.homedir(), '.config/barkpark/config.json'), 'utf8'));
const srv = (cfg.known_servers || []).find((s) => s.name === 'guerrilla');
const base = String(srv.server).replace(/\/+$/, '');

const mint = async () => {
  const r = await fetch(`${base}/v1/auth/login-tickets`, {
    method: 'POST', headers: { Authorization: `Bearer ${srv.token}`, 'Content-Type': 'application/json' }, body: '{}',
  });
  if (!r.ok) throw new Error(`ticket mint HTTP ${r.status} ${await r.text()}`);
  return (await r.json()).ticket;
};

// The band + hit-test, verbatim in spirit with scripts/studio-desk-measure.mjs.
const PROBE = `(selectors) => {
  const surface = document.querySelector('.bp-paper-surface');
  if (!surface) return { fatal: 'no .bp-paper-surface' };
  const cs = getComputedStyle(surface);
  const r = surface.getBoundingClientRect();
  const px = (v) => { const n = parseFloat(v); return Number.isFinite(n) ? n : 0; };
  const contentLeft = r.left + px(cs.borderLeftWidth) + px(cs.paddingLeft);
  const contentRight = r.right - px(cs.borderRightWidth) - px(cs.paddingRight);
  const bandTop = Math.max(r.top + px(cs.borderTopWidth) + px(cs.paddingTop), 0);
  const bandBottom = Math.min(r.bottom - px(cs.borderBottomWidth) - px(cs.paddingBottom), innerHeight - 1);
  const bandH = bandBottom - bandTop;
  const ys = [0.1,0.3,0.5,0.7,0.9].map(f => bandTop + f * bandH);
  const xs = []; for (let i=0;i<48;i++) xs.push(contentLeft + ((i+0.5)*(contentRight-contentLeft))/48);

  // occluded fraction of the band by the ancestry test (what visible_content_px does)
  let vis=0, occ=0, off=0; const topNames = new Set();
  for (const y of ys) for (const x of xs) {
    if (x<0||y<0||x>innerWidth-1||y>innerHeight-1) { off++; continue; }
    const top = document.elementsFromPoint(x,y)[0];
    if (!top) { off++; continue; }
    if (top===surface || surface.contains(top)) vis++;
    else { occ++; topNames.add(top.tagName.toLowerCase()+(typeof top.className==='string'?'.'+top.className.trim().split(/\\s+/).slice(0,3).join('.'):'')); }
  }

  // the invisible-occluder census, same predicate as the instrument
  const census = [];
  for (const el of document.querySelectorAll('*')) {
    const b = el.getBoundingClientRect();
    if (b.width<=0||b.height<=0) continue;
    const ox = Math.min(contentRight,b.right)-Math.max(contentLeft,b.left);
    const oy = Math.min(bandBottom,b.bottom)-Math.max(bandTop,b.top);
    if (ox<=0||oy<=0) continue;
    if (el.contains(surface)||surface.contains(el)||el===surface) continue;
    const c = getComputedStyle(el);
    if (c.pointerEvents!=='none') continue;
    if (c.visibility==='hidden'||c.display==='none') continue;
    if (parseFloat(c.opacity)===0) continue;
    census.push({ tag: el.tagName.toLowerCase(), class_name: typeof el.className==='string'?el.className.slice(0,120):null, position:c.position, z_index:c.zIndex, overlap_over_content_px: Math.round(ox*1000)/1000, overlap_height_px: Math.round(oy*1000)/1000 });
  }

  const fams = {};
  for (const sel of selectors) {
    const els = Array.from(document.querySelectorAll(sel));
    const painting = els.filter(e => { const c=getComputedStyle(e); const b=e.getBoundingClientRect();
      return b.width>0 && b.height>0 && c.display!=='none' && c.visibility!=='hidden' && parseFloat(c.opacity)!==0; });
    if (painting.length===0) { fams[sel] = { present: els.length>0, painting: 0 }; continue; }
    const e = painting[0]; const c = getComputedStyle(e); const b = e.getBoundingClientRect();
    const ox = Math.min(contentRight,b.right)-Math.max(contentLeft,b.left);
    const oy = Math.min(bandBottom,b.bottom)-Math.max(bandTop,b.top);
    // is it topmost at any sampled point?
    let topmostHits = 0;
    for (const y of ys) for (const x of xs) {
      if (x<0||y<0||x>innerWidth-1||y>innerHeight-1) continue;
      const t = document.elementsFromPoint(x,y)[0];
      if (t && (t===e || e.contains(t))) topmostHits++;
    }
    fams[sel] = {
      present: true, painting: painting.length,
      position: c.position, z_index: c.zIndex, pointer_events: c.pointerEvents,
      rect: { top: Math.round(b.top), left: Math.round(b.left), w: Math.round(b.width), h: Math.round(b.height) },
      overlaps_band: ox>0 && oy>0,
      overlap_over_content_px: Math.round(ox*1000)/1000, overlap_height_px: Math.round(oy*1000)/1000,
      hit_test_topmost_samples: topmostHits,
      in_census: census.some(x => x.class_name && sel.replace(/^\\./,'').split('.').every(k => x.class_name.includes(k))),
    };
  }
  return {
    band: { contentLeft: Math.round(contentLeft), contentRight: Math.round(contentRight), bandTop: Math.round(bandTop), bandBottom: Math.round(bandBottom) },
    samples: { visible: vis, occluded: occ, offscreen: off, total: vis+occ+off },
    occluder_names: [...topNames],
    census_count: census.length, census: census.slice(0,12),
    families: fams,
  };
}`;

const SELECTORS = ['.modal-backdrop','.modal-card','.image-picker-overlay','.bp-ab-overlay',
  '.bp-ae-modal','.history-modal','.delete-modal','.profile-modal',
  '.bp-slash-menu','.bp-paper-format','.bp-paper-context-menu',
  '.bp-ae-toast','.bp-bulk-action-bar','.bp-press-answer','.presence-tooltip','.presence-dots'];


const settle = async (page, ms=900) => { await page.waitForTimeout(ms); };
const DOC = process.argv[4];
const out = { base, started: new Date().toISOString(), doc_path: DOC, steps: [] };
const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
const snap = async (label) => {
  const r = await page.evaluate(`(${PROBE})(${JSON.stringify(SELECTORS)})`);
  out.steps.push({ label, ...r }); return r;
};
try {
  const t = await mint();
  await page.goto(`${base}/login/ticket/${t}`, { waitUntil: 'domcontentloaded' });
  await page.goto(base + DOC, { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('.bp-paper-surface', { timeout: 20000 });
  await settle(page, 1800);
  await snap('baseline');

  // context menu — right-click inside the surface
  try {
    await page.locator('.bp-paper-surface').first().click({ button: 'right', timeout: 6000 });
    await settle(page, 900); await snap('right-click');
    await page.keyboard.press('Escape'); await settle(page, 600);
  } catch (e) { out.steps.push({ label: 'right-click:ERROR', error: String(e.message).slice(0,200) }); }

  // format bubble — select text inside the surface
  try {
    await page.evaluate(() => {
      const s = document.querySelector('.bp-paper-surface');
      const p = s && s.querySelector('p, h1, h2, li');
      if (!p) return;
      const rng = document.createRange(); rng.selectNodeContents(p);
      const sel = getSelection(); sel.removeAllRanges(); sel.addRange(rng);
      p.dispatchEvent(new MouseEvent('mouseup', { bubbles: true }));
      document.dispatchEvent(new Event('selectionchange'));
    });
    await settle(page, 1000); await snap('text-selection');
  } catch (e) { out.steps.push({ label: 'selection:ERROR', error: String(e.message).slice(0,200) }); }

  // SYNTHETIC arm: shipped class, shipped CSS decides geometry + pointer-events
  for (const cls of ['bp-ae-toast','bp-ae-modal','bp-ab-overlay','bp-bulk-action-bar','modal-backdrop','bp-slash-menu','bp-paper-format','bp-paper-context-menu']) {
    await page.evaluate((c) => {
      document.querySelectorAll('[data-b36-synthetic]').forEach(e => e.remove());
      const d = document.createElement('div');
      d.className = c; d.setAttribute('data-b36-synthetic','1'); d.textContent = 'synthetic occluder';
      if (c === 'bp-ae-modal') d.innerHTML = '<div class="bp-ae-modal-backdrop"></div><div class="bp-ae-modal-card">x</div>';
      document.body.appendChild(d);
    }, cls);
    await settle(page, 500);
    await snap('SYNTHETIC:.' + cls);
  }
  await page.evaluate(() => document.querySelectorAll('[data-b36-synthetic]').forEach(e => e.remove()));
  await settle(page, 500); await snap('cleanup');
} catch (e) { out.fatal = String(e.stack || e.message); }
finally {
  await browser.close();
  fs.writeFileSync(process.argv[3], JSON.stringify(out, null, 2));
  console.log('wrote', process.argv[3], out.fatal ? 'FATAL: '+out.fatal.split('\n')[0] : 'ok');
}
