#!/usr/bin/env node
//
// spd-b11-subxs-shot.mjs — the BEFORE/AFTER density recorder for spd-b11.
//
// spd-b11 added two rungs below `xs` to the chrome type scale (type.chrome.2xs
// = 11px, 3xs = 10px) and swept 102 hand-stamped sub-12px `font-size` literals
// in api/lib/barkpark_web/layouts/root.html.heex onto var(--text-2xs) /
// var(--text-3xs). The row that filed it says the reason a rung was needed at
// all is that force-mapping those sites onto the old floor (--text-xs: 12px)
// would be "a 1-3px visible density bump across roughly a third of desk chrome
// that NO gate can see". The rung exists so the sweep costs ZERO pixels — and
// that claim is exactly the one no gate in this repo can check. Hence a shot.
//
// ── Why the AFTER is produced IN THE PAGE, not by a second server ────────────
//
// The deployed guerrilla Studio serves root.html.heex blob
// f4f19129cb24d8b6cc613991805fc53b17e218e8 — BYTE-IDENTICAL to the blob at this
// branch's base commit (159ea0412a3772cb34b0f07910e9f3eb4e0a7ae2). So the
// deployed page IS the "before" state of the changed file, with no rebuild and
// no sha ambiguity. The "after" is then produced by replaying THIS BRANCH'S
// DIFF onto that live stylesheet, in the page:
//
//   1. insert the two emitted rungs after the --text-xs pair;
//   2. `font-size: 11px` -> `font-size: var(--text-2xs)`;
//   3. `font-size: 10px` -> `font-size: var(--text-3xs)`.
//
// That is the whole diff to the served CSS. The substitution counts are
// ASSERTED against the numbers the branch actually changed (82 and 20): if the
// live sheet were not this branch's base, the counts would not match and the
// run HALTS rather than shooting a pair of pictures of the wrong thing.
//
// Usage:
//   node scripts/measurements/spd-b11-subxs-shot.mjs --out docs/evidence/spd-b11-subxs-type-scale
//
// Auth is the instrument's own login-ticket flow (D24e): the guerrilla admin
// token is read from ~/.config/barkpark/config.json and never written anywhere.

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createRequire } from 'node:module';
import { spawnSync } from 'node:child_process';

const EXPECT_11PX = 82;
const EXPECT_10PX = 20;
const VIEWPORT = { width: 1440, height: 1000 };

const outDir = (() => {
  const i = process.argv.indexOf('--out');
  return i >= 0 ? process.argv[i + 1] : 'docs/evidence/spd-b11-subxs-type-scale';
})();

const die = (m) => { console.error(`spd-b11-subxs-shot: ${m}`); process.exit(1); };

function server() {
  const p = path.join(os.homedir(), '.config/barkpark/config.json');
  if (!fs.existsSync(p)) die(`no barkpark config at ${p}`);
  const cfg = JSON.parse(fs.readFileSync(p, 'utf8'));
  const srv = (cfg.known_servers || []).find((s) => s.name === 'guerrilla');
  if (!srv?.token) die(`no guerrilla entry with a token in ${p}`);
  const base = String(srv.server || '').replace(/\/+$/, '');
  if (!base.startsWith('https://')) die(`guerrilla base must be https:// (got ${base})`);
  return { base, token: srv.token };
}

async function mintTicket({ base, token }) {
  const res = await fetch(`${base}/v1/auth/login-tickets`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: '{}',
  });
  if (!res.ok) die(`login-ticket mint failed: HTTP ${res.status} ${await res.text()}`);
  const body = await res.json();
  if (!body.ticket) die(`login-ticket response carried no ticket`);
  return body.ticket;
}

// The in-page transform: find the Studio's inline stylesheet, replay the diff,
// and report the counts. Returns {ok,...} — never throws a picture.
const APPLY_AFTER = () => {
  // root.html.heex carries TWO <style> blocks — the sheet is SPLIT around the
  // <link rel=stylesheet href=/assets/bp-paper-editor-shell.css> so the public
  // paper reader can load the same bytes. Transforming only the first one is a
  // trap the first run of this script fell into (67/19 instead of 82/20), so
  // every inline <style> is rewritten and the counts are summed.
  const styles = [...document.querySelectorAll('style')];
  const anchorSheet = styles.find((s) => s.textContent.includes('--text-xs: 12px; --text-xs-lh: 1.4;'));
  if (!anchorSheet) return { ok: false, why: 'no inline <style> carrying the --text-xs pair' };
  const anchor = '--text-xs: 12px; --text-xs-lh: 1.4;';
  if (anchorSheet.textContent.split(anchor).length - 1 !== 1) return { ok: false, why: 'the --text-xs anchor is not unique' };
  anchorSheet.textContent = anchorSheet.textContent.replace(
    anchor, anchor + '\n      --text-2xs: 11px; --text-2xs-lh: 1.4;\n      --text-3xs: 10px; --text-3xs-lh: 1.4;');
  let n11 = 0, n10 = 0, blocks = 0;
  for (const el of styles) {
    let css = el.textContent;
    const a = (css.match(/font-size:\s*11px/g) || []).length;
    const b = (css.match(/font-size:\s*10px/g) || []).length;
    if (a === 0 && b === 0) continue;
    n11 += a; n10 += b; blocks++;
    el.textContent = css.replace(/font-size:\s*11px/g, 'font-size: var(--text-2xs)')
                        .replace(/font-size:\s*10px/g, 'font-size: var(--text-3xs)');
  }
  return { ok: true, n11, n10, blocks, style_tags: styles.length };
};

// `--recompare` re-derives the pixel statistics over an EXISTING run's PNGs and
// rewrites run.json, without a browser and without a login ticket. It exists so
// the delta numbers in the artifact can be reproduced (or corrected — the first
// stamping of this run used `compare -metric AE`, whose Q16-scaled 0.713725 is
// not a pixel count) by anyone holding the committed images.
if (process.argv.includes('--recompare')) {
  const rp = path.join(outDir, 'run.json');
  const prev = JSON.parse(fs.readFileSync(rp, 'utf8'));
  for (const c of prev.surfaces) {
    c.identical = fs.readFileSync(c.before).equals(fs.readFileSync(c.after));
    Object.assign(c, diffStats(c.before, c.after));
    console.log(`  ${c.id}: ${c.differing_pixels} differing px, max channel delta ${c.max_channel_delta}, at ${c.difference_bbox}`);
  }
  prev.recompared_at = new Date().toISOString();
  fs.writeFileSync(rp, JSON.stringify(prev, null, 2) + '\n');
  console.log(`spd-b11-subxs-shot: recompared ${prev.surfaces.length} pair(s) in ${rp}`);
  process.exit(0);
}

const require_ = createRequire(import.meta.url);
let pw;
for (const from of [process.env.BP_PLAYWRIGHT_FROM, 'playwright',
                    path.join(process.cwd(), 'js/node_modules/playwright'),
                    path.join(process.cwd(), 'node_modules/playwright')].filter(Boolean)) {
  try { pw = require_(from); break; } catch { /* next */ }
}
if (!pw) die('playwright could not be resolved; set BP_PLAYWRIGHT_FROM');

// THE SUBJECT COMES FIRST. A pair of screenshots of a surface that paints no
// sub-12px chrome is a green with no subject — the first run of this script shot
// two "IDENTICAL" pairs of a `Studio could not open this document.` error page
// and would have reported them as approval. Every surface below therefore
// declares a MINIMUM count of elements the browser actually resolves to 11px /
// 10px, measured BEFORE the transform, and the run HALTS if the page is under it.
// The desk's rail is client-routed, so `/studio/<section>` deep links all land on
// the bare desk: the panes are reached by CLICK, with a settle long enough for
// the pane's rows to stream in (at 2.5s the Papers pane still measured 1 x 10px;
// at 5s it measures 101).
// ── the pixel delta, as a NUMBER and a PLACE ─────────────────────────────────
//
// `compare -metric AE` is the obvious tool and it is the wrong one twice over:
// it writes to STDERR and exits non-zero (an earlier run of this script recorded
// an empty string where the count should have been), and on a Q16 build the
// number it prints is QUANTUM-SCALED — "0.713725" for a pair that differs in 440
// pixels. So the count is computed directly: difference-composite, threshold at
// zero, and read back mean x w x h, which is the exact number of pixels that
// differ at all. `-trim` then reports WHERE they are, which is the whole
// question: a 1px type change moves glyph baselines the full height of the
// content, while a live status footer or an antialiased thumbnail edge does not.
function diffStats(before, after) {
  const mg = (args) => {
    const r = spawnSync('magick', args, { encoding: 'utf8' });
    return r.status === 0 ? (r.stdout || '').trim() : null;
  };
  const n = mg([before, after, '-compose', 'difference', '-composite', '-colorspace', 'Gray',
                '-threshold', '0', '-format', '%[fx:int(mean*w*h+0.5)]', 'info:']);
  const mx = mg([before, after, '-compose', 'difference', '-composite',
                 '-format', '%[fx:int(maxima*255+0.5)]', 'info:']);
  const box = mg([before, after, '-compose', 'difference', '-composite', '-colorspace', 'Gray',
                  '-threshold', '0', '-trim', '-format', '%wx%h+%X+%Y of %[fx:page.width]x%[fx:page.height]', 'info:']);
  return { differing_pixels: n === null ? null : Number(n),
           max_channel_delta: mx === null ? null : Number(mx),
           difference_bbox: box };
}

const SURFACES = [
  { id: '1-media', label: 'Media library (the densest 11px cluster: cards, size lines, format chips)',
    path: '/w/default/p/default/d/production/studio/media', steps: [], settle: 5000, min11: 40, min10: 3 },
  { id: '2-papers-pane', label: 'Papers desk pane (100 rows of list chrome — the densest 10px cluster)',
    path: '/w/default/p/default/d/production/studio', steps: ['text=Papers'], settle: 6000, min11: 5, min10: 60 },
  { id: '3-tasks-pane', label: 'Tasks desk pane (row meta, lifecycle chips, uppercase eyebrows)',
    path: '/w/default/p/default/d/production/studio', steps: ['text=Tasks'], settle: 6000, min11: 5, min10: 60 },
];

// Counts VISIBLE elements the browser resolved to each sub-12px size. Run before
// the transform it is the subject assertion; run after it, both counts must be
// UNCHANGED — that is the pixel-neutrality claim stated as a number rather than
// as a picture, and it is checked on every surface.
const COUNT_SUBJECT = () => {
  let n11 = 0, n10 = 0;
  for (const el of document.querySelectorAll('*')) {
    if (el.offsetParent === null && el.tagName !== 'BODY') continue;
    const f = getComputedStyle(el).fontSize;
    if (f === '11px') n11++; else if (f === '10px') n10++;
  }
  return { n11, n10 };
};

const srv = server();
fs.mkdirSync(outDir, { recursive: true });
const run = { tool: 'scripts/measurements/spd-b11-subxs-shot.mjs', base: srv.base, viewport: VIEWPORT,
              measured_at: new Date().toISOString(), surfaces: [] };

// Browser policy mirrors studio-desk-measure.mjs: the pinned Chromium first, the
// system Chrome channel as the recorded fallback. BP_DESK_BROWSER=chrome forces it.
const wantChannel = (process.env.BP_DESK_BROWSER || '').trim() === 'chrome';
let browserChannel = wantChannel ? 'chrome' : 'bundled';
let browser;
try {
  browser = await pw.chromium.launch(wantChannel ? { channel: 'chrome' } : {});
} catch (err) {
  if (wantChannel || !/Executable doesn't exist|playwright install/i.test(String(err?.message))) throw err;
  browserChannel = 'chrome (fallback: no pinned Chromium build for this playwright)';
  browser = await pw.chromium.launch({ channel: 'chrome' });
}
run.browser = { channel: browserChannel, playwright: pw._playwrightVersion || 'unknown' };
try {
  const ctx = await browser.newContext({ viewport: VIEWPORT, deviceScaleFactor: 2 });
  const page = await ctx.newPage();
  const ticket = await mintTicket(srv);
  await page.goto(`${srv.base}/login/ticket/${ticket}`, { waitUntil: 'domcontentloaded' });

  run.served_sha = await (await fetch(`${srv.base}/status.json`)).json().then((j) => j.commit).catch(() => null);

  for (const s of SURFACES) {
    await page.goto(srv.base + s.path, { waitUntil: 'domcontentloaded' });
    await page.waitForTimeout(s.settle);
    for (const sel of s.steps) { await page.click(sel, { timeout: 10_000 }); await page.waitForTimeout(s.settle); }

    const subjectBefore = await page.evaluate(COUNT_SUBJECT);
    if (subjectBefore.n11 < s.min11 || subjectBefore.n10 < s.min10)
      die(`${s.id}: NO SUBJECT — the page paints ${subjectBefore.n11} element(s) at 11px and ` +
          `${subjectBefore.n10} at 10px, under the declared floor (${s.min11}/${s.min10}). ` +
          `Shooting it would record a comparison of chrome that is not on screen. HALT.`);

    const before = path.join(outDir, `${s.id}-before-1440.png`);
    await page.screenshot({ path: before });
    const applied = await page.evaluate(APPLY_AFTER);
    if (!applied.ok) die(`${s.id}: could not apply the AFTER stylesheet — ${applied.why}`);
    if (applied.n11 !== EXPECT_11PX || applied.n10 !== EXPECT_10PX)
      die(`${s.id}: the served stylesheet is NOT this branch's base — expected ${EXPECT_11PX} x 11px and ` +
          `${EXPECT_10PX} x 10px font-size literals, saw ${applied.n11} and ${applied.n10}. HALT.`);
    await page.waitForTimeout(600);
    const subjectAfter = await page.evaluate(COUNT_SUBJECT);
    const after = path.join(outDir, `${s.id}-after-1440.png`);
    await page.screenshot({ path: after });

    const cmp = { id: s.id, label: s.label, url: s.path, clicks: s.steps, before, after,
                  stylesheet_substitutions: { '11px->var(--text-2xs)': applied.n11, '10px->var(--text-3xs)': applied.n10 },
                  resolved_sizes_before: subjectBefore, resolved_sizes_after: subjectAfter,
                  resolved_sizes_unchanged: subjectBefore.n11 === subjectAfter.n11 && subjectBefore.n10 === subjectAfter.n10,
                  bytes_before: fs.statSync(before).size, bytes_after: fs.statSync(after).size };
    cmp.identical = fs.readFileSync(before).equals(fs.readFileSync(after));
    Object.assign(cmp, diffStats(before, after));
    run.surfaces.push(cmp);
    console.log(`  ${s.id}: ${cmp.identical ? 'byte-IDENTICAL' : 'differs by ' + cmp.differing_pixels + ' px'}` +
                `  | subject ${subjectBefore.n11} x 11px + ${subjectBefore.n10} x 10px -> ` +
                `${subjectAfter.n11} / ${subjectAfter.n10} after` +
                `  | sheet rewrote ${applied.n11}+${applied.n10} literal(s) across ${applied.blocks} <style> block(s)`);
  }
} finally {
  await browser.close();
}
fs.writeFileSync(path.join(outDir, 'run.json'), JSON.stringify(run, null, 2) + '\n');
console.log(`spd-b11-subxs-shot: wrote ${run.surfaces.length} pair(s) to ${outDir} (served ${run.served_sha})`);
