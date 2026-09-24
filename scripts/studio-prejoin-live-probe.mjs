#!/usr/bin/env node
//
// studio-prejoin-live-probe.mjs — THE PRE-JOIN WINDOW, MEASURED ON A REAL DESK.
//
// task-c2dd40c6f433a787, criterion c0: the swallow reproduced as a property of
// the CODE, with the attribute arriving on its own and the window's width
// stated against a served sha. Three arms, one session:
//
//   ARM 1  PRE-JOIN    press `#item-paper` the first frame it exists, with the
//                      view demonstrably NOT joined. Count `"type":"click"`
//                      frames on /live/websocket.
//   ARM 2  SETTLED     the same button, the same page, joined. This is the
//                      CONTROL for arm 1: a frame counter that cannot count is
//                      not evidence, and an absence is never caught by
//                      inspection.
//   ARM 3  IN-FLIGHT   press once (LiveView stamps `data-phx-ref-src` ITSELF
//                      via putRef), then press again while that ref is
//                      outstanding. Nothing is hand-armed anywhere in this file.
//
// It also records every self-arriving `data-phx-ref-src` mutation from before
// the first byte of page script, which is what shows the attribute does NOT
// arrive in the pre-join window at all — the pre-join drop is
// `View.pushWithReply`'s `Promise.reject(new Error("no connection"))`, which
// runs BEFORE the ref generator, not `bindClick`'s early return.
//
//   node scripts/studio-prejoin-live-probe.mjs            # human table
//   node scripts/studio-prejoin-live-probe.mjs --json
//   node scripts/studio-prejoin-live-probe.mjs --with-fix  # arm 1 again, with
//     the BP-PREJOIN-QUEUE fence read out of THIS worktree's root.html.heex and
//     injected ahead of the served page's own scripts. The deployed host does
//     not carry the fix yet, so this is how arm 1 is answered ON THE SURFACE IT
//     WAS MEASURED ON rather than only in the offline fixture.
//
// Auth is the same one `tooling/studio-journey/journey.mjs` uses: the guerrilla
// admin token out of ~/.config/barkpark/config.json mints a login ticket. A
// mint that does not answer is an ENVIRONMENT failure (exit 2) and must never
// be converted into a product fact.
//
// Node 22. No dependencies beyond playwright.

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
import { execFileSync } from 'node:child_process';

const FENCE_BEGIN = 'BP-PREJOIN-QUEUE-BEGIN';
const FENCE_END = 'BP-PREJOIN-QUEUE-END';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '..');

class Guard extends Error {}
const guard = (m) => { throw new Guard(m); };

function resolvePlaywright() {
  const candidates = [];
  if (process.env.BP_PLAYWRIGHT_FROM) candidates.push(process.env.BP_PLAYWRIGHT_FROM);
  candidates.push(path.join(REPO, 'js', 'package.json'), path.join(REPO, 'package.json'));
  try {
    const common = execFileSync('git', ['rev-parse', '--path-format=absolute', '--git-common-dir'],
      { cwd: REPO, encoding: 'utf8' }).trim();
    candidates.push(path.join(path.dirname(common), 'js', 'package.json'));
  } catch { /* not a git checkout */ }
  for (const from of candidates) {
    try { return createRequire(from)('playwright'); } catch { /* next */ }
  }
  guard(`playwright could not be resolved (tried ${candidates.join(', ')})`);
}

function guerrilla() {
  const p = path.join(os.homedir(), '.config', 'barkpark', 'config.json');
  if (!fs.existsSync(p)) guard(`no barkpark config at ${p}`);
  const cfg = JSON.parse(fs.readFileSync(p, 'utf8'));
  const srv = (cfg.known_servers || []).find((s) => s.name === 'guerrilla');
  if (!srv?.token) guard(`no guerrilla entry with a token in ${p} — run \`bp login\``);
  return { base: srv.url || srv.base || 'https://guerrilla.barkpark.cloud', token: srv.token };
}

// Armed before the first byte of page script, so the record starts at the page
// and not at whenever the driver happened to look.
function probeInit() {
  window.__probe = { t0: performance.now(), refEvents: [], clickFrames: [], press: null, joinedAt: null, itemAt: null };
  const P = window.__probe;
  const send = WebSocket.prototype.send;
  WebSocket.prototype.send = function (d) {
    try {
      if (typeof d === 'string' && d.indexOf('"type":"click"') !== -1) {
        P.clickFrames.push(Math.round(performance.now() - P.t0));
      }
    } catch { /* never let the recorder change the thing it records */ }
    return send.apply(this, arguments);
  };
  const mo = new MutationObserver((muts) => {
    for (const m of muts) {
      if (m.type !== 'attributes') continue;
      const el = m.target;
      if (m.attributeName === 'data-phx-ref-src') {
        P.refEvents.push({
          t: Math.round(performance.now() - P.t0),
          id: el.id || el.tagName,
          on: el.hasAttribute('data-phx-ref-src'),
        });
      }
      if (m.attributeName === 'class' && el.hasAttribute('data-phx-main') && P.joinedAt === null &&
          el.classList.contains('phx-connected')) {
        P.joinedAt = Math.round(performance.now() - P.t0);
      }
    }
  });
  // documentElement does not exist yet in an init script on every navigation,
  // and an exception here would take the press loop below down with it — which
  // is how a first draft of this probe reported "no press" and meant "no probe".
  const arm = () => mo.observe(document.documentElement,
    { attributes: true, subtree: true, attributeFilter: ['data-phx-ref-src', 'class'] });
  if (document.documentElement) arm();
  else document.addEventListener('readystatechange', arm, { once: true });
  const tick = () => {
    if (P.press) return;
    const el = document.getElementById('item-paper');
    if (!el) { requestAnimationFrame(tick); return; }
    P.itemAt = Math.round(performance.now() - P.t0);
    const main = document.querySelector('[data-phx-main]');
    P.press = {
      t: P.itemAt,
      joinedAtPress: !!main && main.classList.contains('phx-connected'),
      refAtPress: el.hasAttribute('data-phx-ref-src'),
      url: location.href,
    };
    el.click();
  };
  requestAnimationFrame(tick);
}

/** The queue, read out of THIS worktree by its fence. Never a hand-copy. */
function worktreeQueue() {
  const lines = fs.readFileSync(path.join(REPO, 'api/lib/barkpark_web/layouts/root.html.heex'), 'utf8').split('\n');
  const at = (m) => lines.reduce((acc, l, i) => (l.trim() === `// ${m}` ? acc.concat(i) : acc), []);
  const b = at(FENCE_BEGIN), e = at(FENCE_END);
  if (b.length !== 1 || e.length !== 1 || e[0] <= b[0]) {
    guard(`--with-fix needs exactly one well-formed ${FENCE_BEGIN}/${FENCE_END} fence in this worktree`);
  }
  return lines.slice(b[0] + 1, e[0]).join('\n');
}

async function main() {
  const json = process.argv.includes('--json');
  const withFix = process.argv.includes('--with-fix');
  const { base, token } = guerrilla();
  const mint = await fetch(`${base}/v1/auth/login-tickets`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: '{}',
  }).then((r) => r.json()).catch((e) => guard(`login-ticket mint failed: ${e.message}`));
  if (!mint?.ticket) guard(`login-ticket response carried no ticket: ${JSON.stringify(mint).slice(0, 200)}`);
  const sha = await fetch(`${base}/status.json`).then((r) => r.json()).then((x) => x.commit).catch(() => 'unknown');

  const pw = resolvePlaywright();
  const browser = await pw.chromium.launch();
  try {
    const ctx = await browser.newContext();
    const page = await ctx.newPage();
    await page.goto(`${base}/login/ticket/${encodeURIComponent(mint.ticket)}`);
    await page.addInitScript(probeInit);
    if (withFix) await page.addInitScript({ content: worktreeQueue() });

    await page.goto(`${base}/studio`, { waitUntil: 'load' });
    await page.waitForTimeout(6000);
    const arm1 = await page.evaluate(() => ({ ...window.__probe, url: location.href,
      says: (document.getElementById('bp-press-answer') || {}).textContent || '' }));

    const arm2 = await page.evaluate(async () => {
      const P = window.__probe, el = document.getElementById('item-paper');
      const n0 = P.clickFrames.length, u0 = location.href;
      el.click();
      const seen = [];
      for (let i = 0; i < 60; i++) { seen.push(el.hasAttribute('data-phx-ref-src')); await new Promise((r) => setTimeout(r, 25)); }
      return { n0, n1: P.clickFrames.length, u0, u1: location.href,
               refSelfArrived: seen[0], refClearedAfterMs: seen.indexOf(false) * 25 };
    });

    await page.goto(`${base}/studio`, { waitUntil: 'load' });
    await page.waitForTimeout(4000);
    const arm3 = await page.evaluate(async () => {
      const P = window.__probe, el = document.getElementById('item-paper');
      const n0 = P.clickFrames.length, t0 = performance.now();
      el.click();
      const n1 = P.clickFrames.length;
      const refSelfArrived = el.hasAttribute('data-phx-ref-src');
      el.click();                                   // SECOND press, ref still on
      const n2 = P.clickFrames.length;
      let cleared = null;
      for (let i = 0; i < 400; i++) {
        if (!el.hasAttribute('data-phx-ref-src')) { cleared = Math.round(performance.now() - t0); break; }
        await new Promise((r) => setTimeout(r, 5));
      }
      return { n0, n1, n2, refSelfArrived, inflightWindowMs: cleared };
    });

  const out = { host: base, served: sha, withFix, at: new Date().toISOString(), arm1, arm2, arm3 };
    if (json) { console.log(JSON.stringify(out, null, 2)); return 0; }

    const w = arm1.joinedAt - arm1.itemAt;
    console.log(`host ${base}  served ${sha}${withFix ? '  + WORKTREE BP-PREJOIN-QUEUE injected' : ''}`);
    console.log(`ARM 1 PRE-JOIN   #item-paper pressable @${arm1.itemAt}ms · view joined @${arm1.joinedAt}ms` +
                `  → WINDOW ${w}ms · press @${arm1.press.t}ms (joined=${arm1.press.joinedAtPress}, ref=${arm1.press.refAtPress})` +
                `  → ${arm1.clickFrames.length} click frame(s) · ${arm1.clickFrames.length ? 'SENT' : 'SWALLOWED'}`);
    console.log(`      self-arriving data-phx-ref-src before the join: ` +
                `${arm1.refEvents.filter((e) => e.on && e.t < arm1.joinedAt).length}` +
                `  (all: ${arm1.refEvents.map((e) => `${e.id}${e.on ? '+' : '-'}@${e.t}`).join(' ') || 'none'})`);
    console.log(`ARM 2 SETTLED    frames ${arm2.n0}→${arm2.n1} · url ${arm2.u0 === arm2.u1 ? 'UNCHANGED' : '→ ' + arm2.u1}` +
                ` · ref arrived by itself=${arm2.refSelfArrived}, cleared after ~${arm2.refClearedAfterMs}ms`);
    console.log(`ARM 3 IN-FLIGHT  frames ${arm3.n0}→${arm3.n1}→${arm3.n2} (second press ` +
                `${arm3.n2 > arm3.n1 ? 'SENT' : 'SWALLOWED'}) · ref self-arrived=${arm3.refSelfArrived}` +
                ` · window ${arm3.inflightWindowMs}ms`);
    return 0;
  } finally {
    await browser.close();
  }
}

try {
  process.exitCode = await main();
} catch (e) {
  if (e instanceof Guard) { console.error(`GUARD: ${e.message}`); process.exitCode = 2; }
  else throw e;
}
