#!/usr/bin/env node
// d175-compound-repro.mjs — THE COMPOUND-STATE REPRO for charter D175: the
// standard-bucket scrim that STILL PAINTS, in a cell the instrument cannot look
// at.
//
// WHY THIS FILE EXISTS. `scripts/studio-desk-measure.mjs` drills root -> Papers
// -> paper and never opens a secondary pane, so no row it can ever emit
// contains this state. Read alone, its matrix says "no scrim renders anywhere
// post-ladder", which is demonstrably false. This script is the demonstration —
// and it is a DEFECT REPRO, not a gate: it exits ZERO only when the defect is
// still there, and NON-ZERO the moment the compound state cannot be reached or
// the scrim stops painting. A red run here is either a broken drill or good
// news, and it says which.
//
// THE STATE, reached through REAL affordances only — no DOM injection, no env
// override, no synthetic fixture:
//
//   root desk
//     -> Tasks                        (a type pane on the root desk)
//     -> open a task document         ([phx-click="select"] row)
//     -> "Open another"               ([data-test-id="open-secondary-picker"])
//     -> pick a candidate             (.bp-secondary-candidate  ->  .bp-secondary-pane)
//     -> expand the 44px root strip   (.pane-column--collapsed[phx-click="expand-pane"])
//     -> Papers -> a paper            (pinned by --doc)
//     -> open the inspector           (a real click, through the live socket)
//
// `Scope.select/2` is push_patch, not push_navigate, so the LiveView never
// remounts and `secondary_doc` SURVIVES the cross-surface navigation. That
// survival is asserted as its own leg (L9), because it is the whole mechanism —
// and it REFUTES charter D96 ("D76's pressure case needs a cross-surface
// navigation no affordance offers"). The affordance offers it.
//
// WHAT THAT COSTS THE READER, at standard / innerWidth 1024:
//
//   .editor-panel clientWidth == 620   ==   1024 - 44 (yielded rail) - 360 (secondary pane)
//
// 620 is under the `@container panel (max-width: 860px)` threshold, so the
// scrim generator matches. None of the three suppressions reach it: the b29
// guard needs `:not([data-user-opened])`, the Tier-3 suppression needs bucket
// narrow/phone, and the D170 abolition needs bucket wide. The state is standard
// AND user-opened, so the scrim renders — 55% black over prose the reader is
// actively reading.
//
// The 620px geometry is CHROME-ONLY (44 + 360 + viewport) and therefore
// document-independent, so any paper works. The paper is nonetheless pinned
// with `--doc` rather than taken from the first Papers row: that list is
// ordered newest-first and concurrent waves rewrite it live, so "the first row"
// is a moving target (D97) and a run that drilled somewhere else must not be
// able to look like a run that drilled here.
//
// Run:
//   BP_PLAYWRIGHT_FROM=/Volumes/SATECHI/github/barkpark/js/package.json \
//     node scripts/measurements/d175-compound-repro.mjs
//
// Flags:
//   --doc=<slug>            the paper to land on (default: DEFAULT_DOC below)
//   --task=<slug>           the task document to open the secondary pane from
//                           (default: the first task row that opens)
//   --simulate-fixed-build  INSTRUMENT SELF-TEST, not a measurement — see the
//                           note above simulateFixedBuild()
//   --keep-shots=<dir>      write the two PNGs for eyeballing
//
// Requires the same playwright the instrument uses (chromium via
// resolvePlaywright), an ssh key for the guerrilla box, and a `guerrilla` entry
// with a token in ~/.config/barkpark/config.json.

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import zlib from 'node:zlib';
import { execFileSync } from 'node:child_process';

import { resolvePlaywright, compareProvenance, openInspectorByRealClick }
  from '../studio-desk-measure.mjs';

// ── the state under test ─────────────────────────────────────────────────────

const VIEWPORT_W = 1024;         // the standard bucket
const ENTRY_W = 1440;            // the width-bucket dead band is widen-only, so
                                 // we enter wide and descend (D80). An ASCENDING
                                 // approach to 1024 stamps `narrow`, and the
                                 // Tier-3 suppression would then eat the scrim.
const RAIL_PX = 44;              // the yielded root strip
const SECONDARY_PANE_PX = 360;   // .bp-secondary-pane, rigid
const EXPECTED_PANEL_PX = VIEWPORT_W - RAIL_PX - SECONDARY_PANE_PX;   // 620

const EXPECTED_SCRIM = {
  content: '""',
  backgroundColor: 'rgba(0, 0, 0, 0.55)',
  position: 'absolute',
  zIndex: '4',
};

// The same committed default `studio-desk-measure.mjs` carries, so both
// instruments describe the same document unless told otherwise.
const DEFAULT_DOC = 'studio-space-priority-desk-browser-2026-07-19';

// The published figures from the first execution of this state (charter D187),
// kept for COMPARISON ONLY and never asserted: they were measured on one build,
// at one clip height, under one luma formula, and a repro that hard-failed on
// them would be asserting a screenshot rather than a defect.
const OBSERVED = { scrim_suppressed: 240.493, scrim_present: 175.104, delta: 65.389 };

const SSH_HOST = 'root@157.180.90.121';
const SSH = ['-i', path.join(os.homedir(), '.ssh/barkpark_indx'), '-o', 'ConnectTimeout=15',
             '-o', 'StrictHostKeyChecking=accept-new', SSH_HOST];

// ── failure ──────────────────────────────────────────────────────────────────

class ReproError extends Error {}
const die = (msg) => { throw new ReproError(msg); };

/** A drill that never arrives says NOTHING about the desk (D97). The wording is
 *  load-bearing: a timeout read as a desk fact is how a non-measurement gets
 *  recorded as a measurement. */
const legDie = (leg, msg, seen) =>
  die(`INSTRUMENT FAILURE at ${leg} — the harness never reached the compound state, so this run ` +
      `says NOTHING about whether the scrim paints. It is not evidence that D175 is fixed.\n\n  ${msg}` +
      (seen ? `\n\n  What the drill saw:\n${seen}` : ''));

const arg = (name, fallback = null) => {
  const hit = process.argv.find((a) => a.startsWith(`--${name}=`));
  return hit ? hit.slice(name.length + 3).trim() : fallback;
};
const flag = (name) => process.argv.includes(`--${name}`);

// ── provenance (queried, never assumed — D71/D97) ────────────────────────────
//
// Duplicated from `studio-desk-measure.mjs` rather than imported: these helpers
// are module-private there, and this slice must not edit that file (it is owned
// by another slice this wave). The read METHOD is printed with the value, so a
// reader can re-run it by hand instead of trusting this file.

const ssh = (cmd) => execFileSync('ssh', [...SSH, cmd], { encoding: 'utf8', timeout: 45_000 }).trim();

function readProvenance() {
  let servedSha, slotRaw;
  try {
    servedSha = ssh('cd /opt/barkpark && git rev-parse HEAD');
  } catch (e) {
    die(`could not read the served SHA over ssh — refusing to publish a defect repro with no ` +
        `provenance (D47). ${e.message}`);
  }
  try {
    slotRaw = ssh(`systemctl list-units 'barkpark-slot@*' --all --no-legend`);
  } catch (e) {
    die(`could not query the live slot over ssh (D71 forbids assuming it). ${e.message}`);
  }
  const loaded = slotRaw.split('\n').map((l) => l.trim()).filter(Boolean);
  return {
    read_at: new Date().toISOString(),
    served_sha: servedSha,
    slot_active: loaded
      .filter((l) => /\bactive\b/.test(l) && /\brunning\b/.test(l))
      .map((l) => (l.match(/barkpark-slot@(\w+)\.service/) || [null, 'unknown'])[1]),
    sha_read_method: `ssh ${SSH_HOST} "cd /opt/barkpark && git rev-parse HEAD"`,
    slot_read_method: `ssh ${SSH_HOST} "systemctl list-units 'barkpark-slot@*' --all --no-legend"`,
  };
}

// ── auth (the D24e login-ticket flow) ────────────────────────────────────────

function readGuerrillaServer() {
  const p = path.join(os.homedir(), '.config/barkpark/config.json');
  if (!fs.existsSync(p)) die(`no barkpark config at ${p} — cannot read the guerrilla admin token`);
  const cfg = JSON.parse(fs.readFileSync(p, 'utf8'));
  const srv = (cfg.known_servers || []).find((s) => s.name === 'guerrilla');
  if (!srv?.token) die(`no guerrilla entry with a token in ${p} (known_servers[] where name=="guerrilla")`);
  const base = String(srv.server || '').replace(/\/+$/, '');
  // The session cookie is Secure: an http:// or bare-IP base is silently
  // dropped and the whole run measures a login page.
  if (!base.startsWith('https://')) {
    die(`guerrilla server must be an https:// hostname (got ${base || '<empty>'}) — the session ` +
        `cookie carries Secure and an http/IP form is dropped`);
  }
  return { base, token: srv.token };
}

/** Single-use, 60s TTL — minted immediately before navigating. An `email` in the
 *  body mints a USER-shaped ticket, so the body must stay empty. */
async function mintTicket({ base, token }) {
  const res = await fetch(`${base}/v1/auth/login-tickets`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: '{}',
  });
  if (!res.ok) die(`login-ticket mint failed: HTTP ${res.status} ${await res.text()}`);
  const body = await res.json();
  if (!body.ticket) die(`login-ticket response carried no ticket: ${JSON.stringify(body)}`);
  return body.ticket;
}

// ── settling ─────────────────────────────────────────────────────────────────
//
// The desk patches over the socket, so "the click returned" is not "the desk
// arrived". Same signature shape the instrument uses: hold still AND report the
// LiveView socket connected.

const SETTLE_SIGNATURE = () => JSON.stringify({
  b: document.documentElement.getAttribute('data-width-bucket'),
  n: document.querySelectorAll('.pane-column').length,
  s: document.querySelectorAll('.bp-secondary-pane').length,
  p: Math.round(document.querySelector('.editor-panel')?.getBoundingClientRect().width || -1),
  connected: !!document.querySelector('[data-phx-main].phx-connected'),
});

async function settle(page, { quietMs = 700, timeoutMs = 20_000 } = {}) {
  const started = Date.now();
  let last = null, lastChange = Date.now(), connected = false;
  while (Date.now() - started < timeoutMs) {
    const sig = await page.evaluate(SETTLE_SIGNATURE);
    if (JSON.parse(sig).connected) connected = true;
    if (sig !== last) { last = sig; lastChange = Date.now(); }
    else if (connected && Date.now() - lastChange >= quietMs) return { settled: true, signature: last };
    await page.waitForTimeout(100);
  }
  return { settled: false, live_socket_connected: connected, signature: last };
}

// ── PNG luminance, dependency-free ───────────────────────────────────────────
//
// Playwright hands back a PNG buffer and this repo has no pngjs/sharp. Rather
// than add a dependency to a one-file repro — or, worse, compare the ENCODED
// bytes and call that a pixel proof — the buffer is decoded here: 8-bit
// non-interlaced RGB/RGBA is a chunk walk, one inflate and the five PNG filter
// undos. Returns the raw samples so the two shots can be diffed PIXEL-wise, and
// a mean under Rec.709 luma, NAMED in the output because a mean is meaningless
// without the formula that produced it.

const LUMA = 'Rec.709 luma: 0.2126R + 0.7152G + 0.0722B, alpha ignored (both shots are opaque)';

function paeth(a, b, c) {
  const p = a + b - c, pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c);
  return pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
}

function decodePng(buf) {
  if (buf.readUInt32BE(0) !== 0x89504e47) die('screenshot was not a PNG — cannot decode it');
  let off = 8, w = 0, h = 0, bitDepth = 0, colorType = 0;
  const idat = [];
  while (off + 8 <= buf.length) {
    const len = buf.readUInt32BE(off);
    const type = buf.toString('ascii', off + 4, off + 8);
    const data = buf.subarray(off + 8, off + 8 + len);
    if (type === 'IHDR') {
      w = data.readUInt32BE(0); h = data.readUInt32BE(4);
      bitDepth = data[8]; colorType = data[9];
      if (data[12] !== 0) die('interlaced PNG — this decoder handles only interlace method 0');
    } else if (type === 'IDAT') idat.push(data);
    else if (type === 'IEND') break;
    off += 12 + len;
  }
  if (bitDepth !== 8 || (colorType !== 6 && colorType !== 2)) {
    die(`unsupported PNG (bitDepth ${bitDepth}, colorType ${colorType}) — expected 8-bit RGB or RGBA`);
  }
  const bpp = colorType === 6 ? 4 : 3;
  const stride = w * bpp;
  const raw = zlib.inflateSync(Buffer.concat(idat));
  if (raw.length < h * (stride + 1)) die('PNG IDAT is short — the screenshot decoded incompletely');

  const out = Buffer.alloc(h * stride);
  let p = 0, sum = 0;
  for (let y = 0; y < h; y++) {
    const filter = raw[p++];
    const line = out.subarray(y * stride, (y + 1) * stride);
    raw.copy(line, 0, p, p + stride); p += stride;
    const prev = y === 0 ? null : out.subarray((y - 1) * stride, y * stride);
    for (let i = 0; i < stride; i++) {
      const a = i >= bpp ? line[i - bpp] : 0;
      const b = prev ? prev[i] : 0;
      const c = prev && i >= bpp ? prev[i - bpp] : 0;
      switch (filter) {
        case 0: break;
        case 1: line[i] = (line[i] + a) & 0xff; break;
        case 2: line[i] = (line[i] + b) & 0xff; break;
        case 3: line[i] = (line[i] + ((a + b) >> 1)) & 0xff; break;
        case 4: line[i] = (line[i] + paeth(a, b, c)) & 0xff; break;
        default: die(`unknown PNG filter type ${filter} on row ${y}`);
      }
    }
    for (let x = 0; x < stride; x += bpp) {
      sum += 0.2126 * line[x] + 0.7152 * line[x + 1] + 0.0722 * line[x + 2];
    }
  }
  const pixels = w * h;
  return { width: w, height: h, pixels, bpp, stride, samples: out, mean: sum / pixels };
}

/** Pixel-wise difference between two decodes of the SAME clip. */
function diffPixels(a, b) {
  if (a.width !== b.width || a.height !== b.height || a.bpp !== b.bpp) {
    die(`the two shots are not the same clip (${a.width}x${a.height} vs ${b.width}x${b.height}) — ` +
        `a before/after pair over different geometry proves nothing`);
  }
  let differing = 0, maxDelta = 0;
  for (let i = 0; i < a.pixels; i++) {
    const o = i * a.bpp;
    const d = Math.max(
      Math.abs(a.samples[o] - b.samples[o]),
      Math.abs(a.samples[o + 1] - b.samples[o + 1]),
      Math.abs(a.samples[o + 2] - b.samples[o + 2]));
    if (d > 0) { differing++; if (d > maxDelta) maxDelta = d; }
  }
  return { differing, differing_pct: (differing / a.pixels) * 100, max_channel_delta: maxDelta };
}

// ── the suppression used for the AFTER shot ──────────────────────────────────
//
// ⚠ HONESTY NOTE — READ BEFORE QUOTING ANY NUMBER THIS PRODUCES.
//
// `content: none !important` is EXACTLY the mechanism charter D176 STRUCK as an
// unsound positive control. D176's objection stands and is not weakened here:
// an `!important` override proves that the override won the cascade, which is a
// fact about `!important`, not about the deployed sheet — so it can never
// establish that a rule is live, and must NEVER be quoted as a control.
//
// Its ONLY job in this file is to produce the second half of a pixel pair for a
// state that has ALREADY been proven live by computed style (L11: the deployed
// `::after` resolves to content "" with rgba(0,0,0,0.55) at z-index 4, with no
// override in the page). The computed-style read is the evidence. This is the
// photograph of it. If the computed-style assertions were ever removed, the
// pixel pair below would immediately become worthless and this whole file with
// it.
const SUPPRESS_GENERATOR_CSS = '.editor-with-preview::after { content: none !important; }';

// ── the drill ────────────────────────────────────────────────────────────────

const legs = [];
function leg(n, what, detail) {
  const line = `  L${n}  ${what}${detail ? ` — ${detail}` : ''}`;
  legs.push(line);
  console.log(line);
}

async function drill(page, base, { taskSlug, docSlug }) {
  // L2 — the root desk.
  await page.goto(`${base}/w/default/p/default/d/production/studio`, { waitUntil: 'domcontentloaded' });
  await settle(page);
  const tasksType = page.locator('.pane-column .pane-item', { hasText: 'Tasks' }).first();
  if (await tasksType.count() === 0) {
    const seen = await page.locator('.pane-column .pane-item').evaluateAll(
      (els) => els.slice(0, 12).map((e) => e.textContent.trim().replace(/\s+/g, ' ')));
    legDie('L2 (root desk)', 'the root desk rendered no "Tasks" entry to drill into.',
      seen.map((s) => `      ${s}`).join('\n'));
  }
  await tasksType.click();
  await settle(page);
  leg(2, 'root desk -> Tasks', 'type pane opened by a real click');

  // L3 — a task document. Its editor is what carries the secondary picker.
  const listPane = page.locator('.pane-column').last();
  const rows = listPane.locator('[phx-click="select"]');
  const rowCount = await rows.count();
  if (rowCount === 0) legDie('L3 (task list)', 'the Tasks pane rendered no [phx-click="select"] row.');
  const target = taskSlug
    ? listPane.locator(`[phx-click="select"][phx-value-id="${taskSlug}"]`).first()
    : rows.first();
  if (await target.count() === 0) {
    const slugs = await rows.evaluateAll((els) => els.slice(0, 8).map((e) => e.getAttribute('phx-value-id')));
    legDie('L3 (task list)', `no task row with phx-value-id="${taskSlug}" (--task).`,
      `    ${rowCount} rows rendered. First 8:\n` + slugs.map((s) => `      ${s}`).join('\n'));
  }
  const openedTask = await target.getAttribute('phx-value-id');
  await target.click();
  await settle(page);
  leg(3, 'opened a task document', `${openedTask} (of ${rowCount} rows)`);

  // L4 — "Open another". The affordance D96 asserted does not exist.
  const picker = page.locator('[data-test-id="open-secondary-picker"]').first();
  if (await picker.count() === 0) {
    legDie('L4 (secondary picker)',
      'the task editor header carries no [data-test-id="open-secondary-picker"] control, so the ' +
      'secondary pane cannot be reached by a real click. If that control has genuinely been ' +
      'removed, the compound state is unreachable — which is a DESK finding worth filing, not a ' +
      'reason to call D175 fixed.',
      // TWO CAUSES, AND THEY ARE NOT THE SAME FINDING. L3 takes the FIRST task row
      // unless --task pins one, so this can equally mean "the desk removed the
      // control" (a real finding) or "today's first task happens to render an
      // editor without it" (a moving target — D97's problem, which --doc already
      // solves for the paper but --task leaves open for the task). A cold reader
      // must be told the second one exists, or they will file the first.
      `    Opened task: ${openedTask}${taskSlug ? ' (pinned by --task)' : ' — UNPINNED, the first row of the list'}\n` +
      (taskSlug ? '' :
        '    Before filing this as a desk regression, re-run with --task=<slug> pinning a task you\n' +
        '    KNOW renders the picker. The unpinned first row is a moving target (D97); a control\n' +
        '    missing on one arbitrary document is not the same finding as a control removed.'));
  }
  await picker.click();
  await page.waitForSelector('[data-test-id="secondary-picker-modal"]', { timeout: 10_000 });
  const candidates = page.locator('.bp-secondary-candidate');
  const candCount = await candidates.count();
  if (candCount === 0) legDie('L4 (secondary picker)', 'the picker modal offered no candidates to open.');
  leg(4, 'clicked "Open another"', `picker offered ${candCount} candidates`);

  // L5 — the secondary pane itself.
  await candidates.first().click();
  await page.waitForSelector('.bp-secondary-pane', { timeout: 10_000 });
  await settle(page);
  leg(5, '.bp-secondary-pane opened', 'picked the first candidate');

  // L6 — the root pane is now a 44px strip. Expanding it is the spd-s6
  //      affordance, and it is the ONLY way back to the type list from here.
  const strip = page.locator('.pane-column--collapsed[phx-click="expand-pane"]').first();
  if (await strip.count() === 0) {
    legDie('L6 (expand-pane)',
      'no .pane-column--collapsed[phx-click="expand-pane"] strip — the ladder did not collapse the ' +
      'root pane, so the documented route back to the type list is not there.');
  }
  const stripW = await strip.evaluate((el) => Math.round(el.getBoundingClientRect().width));
  await strip.click();
  await settle(page);
  leg(6, 'expanded the collapsed root strip', `strip measured ${stripW}px wide`);

  // L7/L8 — cross the surface to a paper. `Scope.select/2` push_patches, so the
  //         LiveView does not remount.
  const papersType = page.locator('.pane-column .pane-item', { hasText: 'Papers' }).first();
  if (await papersType.count() === 0) legDie('L7 (Papers)', 'the expanded root pane rendered no "Papers" entry.');
  await papersType.click();
  await settle(page);
  leg(7, 'root -> Papers', 'the cross-surface navigation D96 said no affordance offered');

  const papersPane = page.locator('.pane-column').last();
  const paperRow = papersPane.locator(`[phx-click="select"][phx-value-id="${docSlug}"]`).first();
  if (await paperRow.count() === 0) {
    const slugs = await papersPane.locator('[phx-click="select"]').evaluateAll(
      (els) => els.slice(0, 8).map((e) => e.getAttribute('phx-value-id')));
    legDie('L8 (paper)', `the Papers list has no row with phx-value-id="${docSlug}" (--doc).`,
      `    First 8 slugs:\n` + slugs.map((s) => `      ${s}`).join('\n') +
      `\n    The paper is pinned deliberately (D97) — pass --doc=<slug> with one of these. The ` +
      `620px geometry is chrome-only, so any paper reproduces it.`);
  }
  await paperRow.click();
  await page.waitForSelector('.bp-paper-surface', { timeout: 20_000 });
  await settle(page);
  const landed = new URL(page.url()).pathname;
  if (!landed.endsWith(`/${docSlug}`)) {
    legDie('L8 (paper)', `clicked the row for ${docSlug} but landed on ${landed}.`);
  }
  leg(8, 'opened the paper', `${landed}`);

  // L9 — THE MECHANISM. push_patch, so secondary_doc survives.
  const survived = await page.locator('.bp-secondary-pane').count();
  if (survived === 0) {
    die(`THE COMPOUND STATE COLLAPSED — .bp-secondary-pane is gone after navigating to the paper.\n\n` +
        `  That is a REAL finding, not an instrument failure: it would mean Scope.select/2 no longer ` +
        `push_patches (or the pane is now dropped on navigation), and the D175 arithmetic ` +
        `(${VIEWPORT_W} - ${RAIL_PX} - ${SECONDARY_PANE_PX}) no longer has a term to stand on. ` +
        `Re-derive the defect before deciding it is fixed.`);
  }
  leg(9, 'secondary pane SURVIVED the navigation', 'Scope.select/2 is push_patch, not push_navigate');

  return { openedTask, candCount, stripW, landed };
}

// ── the measurement ──────────────────────────────────────────────────────────

const READ_STATE = () => {
  const el = document.querySelector('.editor-with-preview');
  const panel = document.querySelector('.editor-panel');
  const sidebar = document.querySelector('.bp-doc-sidebar');
  if (!el || !panel) return { fatal: true, has_editor_with_preview: !!el, has_editor_panel: !!panel };
  const cs = getComputedStyle(el, '::after');
  return {
    bucket: document.documentElement.getAttribute('data-width-bucket'),
    inner_width: window.innerWidth,
    panel_client_width: panel.clientWidth,
    secondary_pane_width: Math.round(
      document.querySelector('.bp-secondary-pane')?.getBoundingClientRect().width ?? -1),
    sidebar_is_open: !!sidebar?.classList.contains('is-open'),
    sidebar_user_opened: !!sidebar?.hasAttribute('data-user-opened'),
    after: {
      content: cs.content,
      backgroundColor: cs.backgroundColor,
      position: cs.position,
      zIndex: cs.zIndex,
      pointerEvents: cs.pointerEvents,
    },
  };
};

/** INSTRUMENT SELF-TEST, NOT A MEASUREMENT (`--simulate-fixed-build`).
 *
 *  A repro whose failure path has never run is a repro that might be structurally
 *  incapable of going red — and this one exits ZERO on the defect, so an
 *  always-green script would look exactly like a healthy run forever. This flag
 *  injects the suppression BEFORE the assertions, standing in for a build where
 *  D175 has been fixed by `spd-standard-bucket-scrim-unruled`. The correct
 *  outcome is a NON-ZERO exit naming the scrim as absent. Nothing it prints is a
 *  fact about the deployed sheet. */
async function simulateFixedBuild(page) {
  await page.addStyleTag({ content: SUPPRESS_GENERATOR_CSS });
  console.log('\n  ⚠ --simulate-fixed-build: the generator is suppressed IN THE PAGE before the');
  console.log('    assertions run. This is a self-test of the failure path. Every number below is');
  console.log('    an artefact of that injection and is NOT a measurement of the deployed sheet.');
  console.log('    The CORRECT outcome of this mode is a NON-ZERO exit.');
}

async function main() {
  const docSlug = arg('doc', DEFAULT_DOC);
  const taskSlug = arg('task', null);
  const keepShots = arg('keep-shots', null);
  const simulating = flag('simulate-fixed-build');

  const { pw, resolvedFrom, version: pwVersion } = resolvePlaywright();
  const srv = readGuerrillaServer();

  console.log('d175-compound-repro — the standard-bucket scrim, where the instrument cannot look');
  console.log(`  target        ${srv.base}`);
  console.log(`  paper         ${docSlug}   (pinned; the 620px geometry is chrome-only)`);
  console.log(`  task          ${taskSlug || '<first row that opens>'}`);
  console.log(`  playwright    ${pwVersion}  (${resolvedFrom})`);
  console.log(`  node          ${process.version} on ${os.platform()} ${os.arch()}`);

  // PRE half of the bracket. The POST half runs after the measurement and any
  // difference INVALIDATES the run — see compareProvenance().
  const pre = readProvenance();
  console.log(`\n  PRE   sha ${pre.served_sha}  ·  slot ${pre.slot_active.join(', ') || 'NONE'}  (read ${pre.read_at})`);
  console.log(`        ${pre.sha_read_method}`);
  console.log(`        ${pre.slot_read_method}`);

  const browser = await pw.chromium.launch();
  const ctx = await browser.newContext({ viewport: { width: ENTRY_W, height: 900 } });
  const page = await ctx.newPage();

  const findings = { pre, doc: docSlug };
  try {
    // L1 — authenticate. Mint immediately before navigating: 60s TTL, single use.
    const ticket = await mintTicket(srv);
    await page.goto(`${srv.base}/login/ticket/${ticket}`, { waitUntil: 'domcontentloaded' });
    if (/\/login(\b|\/|$)/.test(new URL(page.url()).pathname)) {
      die(`login-ticket flow landed back on ${page.url()} — the session cookie was not set. ` +
          `Everything after this would be a measurement of a login page.`);
    }
    console.log('\n── THE DRILL (real affordances only — no DOM injection, no env override)');
    leg(1, 'authenticated', 'D24e login-ticket flow');

    findings.drill = await drill(page, srv.base, { taskSlug, docSlug });

    // L10 — descend to the standard bucket. Entering wide and narrowing is
    //       deliberate: the bucket dead band re-anchors on WIDEN only (D80), so
    //       arriving at 1024 from below stamps `narrow` and the Tier-3
    //       suppression would legitimately eat the scrim — a different cell.
    await page.setViewportSize({ width: VIEWPORT_W, height: 900 });
    await settle(page);
    const bucket = await page.evaluate(() => document.documentElement.getAttribute('data-width-bucket'));
    if (bucket !== 'standard') {
      legDie('L10 (bucket)',
        `innerWidth ${VIEWPORT_W} stamped data-width-bucket="${bucket}", not "standard". The three ` +
        `scrim suppressions are keyed on the bucket, so a different bucket is a DIFFERENT CELL and ` +
        `no assertion below would be about D175.`);
    }
    leg(10, `descended ${ENTRY_W} -> ${VIEWPORT_W}`, 'data-width-bucket="standard"');

    // L11 — the inspector, opened by a REAL click through the live socket.
    //       `data-user-opened` is server-stamped from the sidebar_user_opened
    //       assign, so a JS-set attribute would prove only that the CSS works.
    const opened = await openInspectorByRealClick(page, { fatal: true });
    await settle(page);
    leg(11, 'opened the inspector by real click',
      `${opened.control} x${opened.clicks_needed}, data-user-opened server-stamped`);

    if (simulating) await simulateFixedBuild(page);

    // ── the computed state. THIS is the evidence; the pixels below are its
    //    photograph.
    const state = await page.evaluate(READ_STATE);
    if (state.fatal) {
      legDie('L12 (state)',
        `the page has no ${state.has_editor_with_preview ? '' : '.editor-with-preview '}` +
        `${state.has_editor_panel ? '' : '.editor-panel '}to read.`);
    }
    findings.state = state;

    console.log('\n── THE COMPOUND STATE');
    console.log(`  bucket                  ${state.bucket}  @ innerWidth ${state.inner_width}`);
    console.log(`  .bp-secondary-pane      ${state.secondary_pane_width}px`);
    console.log(`  .bp-doc-sidebar         is-open=${state.sidebar_is_open}  data-user-opened=${state.sidebar_user_opened}`);
    console.log(`  .editor-panel           clientWidth = ${state.panel_client_width}px`);
    console.log(`                          expected    = ${VIEWPORT_W} - ${RAIL_PX} - ${SECONDARY_PANE_PX} = ${EXPECTED_PANEL_PX}px`);
    console.log(`                          -> ${EXPECTED_PANEL_PX} <= 860, so the @container panel generator MATCHES`);
    console.log('\n  getComputedStyle(".editor-with-preview", "::after"):');
    for (const [k, v] of Object.entries(state.after)) console.log(`    ${k.padEnd(16)} ${v}`);

    const checks = [];
    checks.push([`.editor-panel clientWidth == ${EXPECTED_PANEL_PX} (${VIEWPORT_W} - ${RAIL_PX} - ${SECONDARY_PANE_PX})`,
      state.panel_client_width === EXPECTED_PANEL_PX,
      `got ${state.panel_client_width}px`]);
    checks.push(['.bp-doc-sidebar carries data-user-opened (server-stamped)',
      state.sidebar_user_opened === true, `got ${state.sidebar_user_opened}`]);
    for (const [k, want] of Object.entries(EXPECTED_SCRIM)) {
      checks.push([`::after ${k} == ${JSON.stringify(want)}`, state.after[k] === want,
        `got ${JSON.stringify(state.after[k])}`]);
    }

    // ── L13: PROVE IT PAINTS. Computed style says the box is generated; only a
    //    pixel pair says the reader sees it. Identical clip both times.
    const box = await page.locator('.editor-panel').boundingBox();
    if (!box) legDie('L13 (clip)', '.editor-panel has no bounding box to screenshot.');
    const clip = {
      x: Math.round(box.x), y: Math.round(box.y),
      width: Math.round(box.width), height: Math.round(box.height),
    };

    const withScrimPng = await page.screenshot({ clip, type: 'png' });
    await page.addStyleTag({ content: SUPPRESS_GENERATOR_CSS });   // ← the D176-struck mechanism
    await page.waitForTimeout(150);
    const suppressedPng = await page.screenshot({ clip, type: 'png' });

    if (keepShots) {
      fs.mkdirSync(keepShots, { recursive: true });
      fs.writeFileSync(path.join(keepShots, 'd175-scrim-present.png'), withScrimPng);
      fs.writeFileSync(path.join(keepShots, 'd175-scrim-suppressed.png'), suppressedPng);
      console.log(`\n  shots written to ${keepShots}`);
    }

    const present = decodePng(withScrimPng);
    const suppressed = decodePng(suppressedPng);
    const diff = diffPixels(present, suppressed);
    findings.pixels = {
      clip,
      luma_formula: LUMA,
      mean_luminance_scrim_present: Math.round(present.mean * 1000) / 1000,
      mean_luminance_scrim_suppressed: Math.round(suppressed.mean * 1000) / 1000,
      delta: Math.round((suppressed.mean - present.mean) * 1000) / 1000,
      ...diff,
    };

    console.log('\n── PIXEL PROOF (the same clip, twice)');
    console.log(`  clip                        ${clip.width}x${clip.height} at (${clip.x}, ${clip.y}) = ${present.pixels.toLocaleString()} px`);
    console.log(`  luma formula                ${LUMA}`);
    console.log(`  mean, scrim SUPPRESSED      ${findings.pixels.mean_luminance_scrim_suppressed}`);
    console.log(`  mean, scrim PRESENT         ${findings.pixels.mean_luminance_scrim_present}`);
    console.log(`  delta (what the scrim does) ${findings.pixels.delta} darker`);
    console.log(`  pixels differing            ${diff.differing.toLocaleString()} (${diff.differing_pct.toFixed(2)}%), max channel delta ${diff.max_channel_delta}`);
    console.log(`  first observed (D187)       ${OBSERVED.scrim_suppressed} -> ${OBSERVED.scrim_present}, delta ${OBSERVED.delta}`);
    console.log('                              — reference only, never asserted: a different clip height');
    console.log('                                or luma formula moves it without moving the defect.');
    console.log('\n  ⚠ The AFTER shot was produced with `content: none !important`, the SAME mechanism');
    console.log('    charter D176 STRUCK as an unsound positive control. It is not one here and must');
    console.log('    never be quoted as one: it establishes only that the override won the cascade.');
    console.log('    The scrim is proven LIVE by the computed-style read above, with no override in');
    console.log('    the page; this pair is the photograph of that state, nothing more.');

    checks.push(['the two shots differ pixel-wise (the scrim PAINTS)', diff.differing > 0,
      `${diff.differing} of ${present.pixels} pixels differ`]);
    checks.push(['suppressing the scrim makes the reading column BRIGHTER (it was dimming prose)',
      suppressed.mean > present.mean,
      `suppressed ${suppressed.mean.toFixed(3)} vs present ${present.mean.toFixed(3)}`]);

    // POST half of the bracket.
    const post = readProvenance();
    findings.post = post;
    console.log(`\n  POST  sha ${post.served_sha}  ·  slot ${post.slot_active.join(', ') || 'NONE'}  (read ${post.read_at})`);
    const drifts = compareProvenance(pre, post);
    for (const d of drifts) console.log(`\n  !! ${d}`);
    checks.push(['the served build did not change under the run (bracket matched)', drifts.length === 0,
      drifts.length ? `${drifts.length} difference(s) — every number above is unattributable` : 'sha and slot held']);

    console.log('\n── VERDICT');
    let ok = true;
    for (const [name, pass, got] of checks) {
      console.log(`  ${pass ? 'PASS' : 'FAIL'}  ${name}${pass ? '' : `  —  ${got}`}`);
      if (!pass) ok = false;
    }

    if (ok) {
      console.log(
        `\nD175 REPRODUCED on ${post.served_sha}. At standard/${VIEWPORT_W} with a secondary pane ` +
        `open and the inspector user-opened, .editor-panel is ${EXPECTED_PANEL_PX}px and a 55%-black ` +
        `scrim paints over the prose. No suppression reaches this cell: the b29 guard needs ` +
        `:not([data-user-opened]), the Tier-3 rule needs narrow/phone, the D170 abolition needs wide. ` +
        `The fix is spd-standard-bucket-scrim-unruled — this file only makes the defect permanently ` +
        `provable.`);
    } else if (simulating) {
      console.log(
        `\nSELF-TEST PASSED (--simulate-fixed-build): with the generator suppressed the repro goes ` +
        `RED, exactly as it must on a build where D175 is fixed. This exit code is the point; ` +
        `nothing above is a measurement of the deployed sheet.`);
    } else {
      console.log(
        `\nD175 NOT REPRODUCED on ${post.served_sha}. Read the FAIL line(s): if the scrim assertions ` +
        `are the ones that fell, the defect may genuinely be FIXED and this file should be retired ` +
        `with the charter decision that retired it. If a bracket or geometry line fell, the run ` +
        `measured something else and proves nothing either way.`);
    }
    return ok ? 0 : 1;
  } finally {
    await browser.close();
  }
}

main()
  .then((code) => process.exit(code))
  .catch((err) => {
    process.stderr.write('\nREPRO FAILED — the compound state was not measured.\n\n');
    process.stderr.write((err instanceof ReproError ? err.message : (err?.stack || String(err))) + '\n\n');
    process.exit(1);
  });
