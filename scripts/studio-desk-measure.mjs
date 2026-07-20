#!/usr/bin/env node
//
// studio-desk-measure.mjs — THE INSTRUMENT.
//
// Measures the DEPLOYED Studio desk in a real authenticated browser and prints a
// nine-width x three-FORCED-face matrix. It is the cure for this epic's chronic
// disease: six times a hand-driven, one-shot measurement was recorded as English
// by an agent who then evaporated, and six times a later verifier overturned it
// (charter D35/D36/D38/D40/D72/D75).
//
// CONTRACT — the only one it claims: **it prints a matrix, or it exits non-zero
// naming the thing that failed.** It is NOT a CI gate. It has no pass/fail
// opinion about the numbers. A rotted run is VISIBLY rotted rather than
// silently wrong (charter D81).
//
//   node scripts/studio-desk-measure.mjs            # human table + JSON matrix
//   node scripts/studio-desk-measure.mjs --json     # JSON matrix only
//   node scripts/studio-desk-measure.mjs --doc=<slug>   # measure a NAMED document
//   node scripts/studio-desk-measure.mjs --doc=any      # first row that opens
//
// (`BP_DESK_DOC` is the env form of `--doc`. Default: DEFAULT_DOC below.)
//
// ── The designed-in impossibilities ──────────────────────────────────────────
// Each one makes a specific historical overturn structurally unreachable:
//
//   1. SELECTOR MATCH COUNT > 0 IS ASSERTED BEFORE ANY NUMBER IS TRUSTED, and
//      the counts are printed in every record. A vacuous pass — measuring an
//      element that is not there and reporting a confident 0 — is how D31 and
//      D39 happened. `assertSelectors()` throws with the selector's own name.
//
//   2. THE GUTTER IS READ, NEVER COMPUTED (D72/D78). `.bp-paper-surface`'s
//      padding is viewport-@media'd — 56/40, then 48/24 below 767px, then
//      32/16 below 479px — so the hardcoded `element_width - 80` that produced
//      D58's withdrawn "510px = 50.96ch at viewport 640" is wrong in exactly
//      the rows this matrix exists to interrogate. We read
//      getComputedStyle(surface).paddingLeft/paddingRight and print it.
//
//   3. ch IS CONVERTED BY A PROBE SPAN inserted as a CHILD of
//      `.bp-paper-surface`, styled `width: 1ch` (D31/D38/D83) — never by
//      dividing by the chrome font's advance, which is what produced the
//      disproven 67.6ch. The browser's own in-floor `ch` (derived from the
//      resolved `calc(55ch + 80px)`) is printed ALONGSIDE it rather than one
//      being silently chosen; they differ by ~0.107% on the native face and
//      that is enough to move 64.0ch to 63.95ch.
//
//   4. HORIZONTAL OVERFLOW IS TESTED AGAINST `.editor-body.bp-paper-body`'s
//      scrollWidth vs clientWidth (D39's real scroller) — never `.editor-panel`
//      (whose `overflow: hidden` is never reached) and never `body`.
//
// ── Two more, learned this wave ──────────────────────────────────────────────
//
//   5. THE FLOOR-BIND TEST IS AN EXPERIMENT, NOT AN INFERENCE. Rather than
//      comparing the resolved `min-inline-size` against the measured width and
//      guessing, we measure the surface, then set `min-inline-size: 0px` inline,
//      re-measure, and restore. If the width moved, the floor BOUND. There is
//      no arithmetic to get wrong. (D75 says it never binds; this either
//      confirms that per face or refutes it.)
//
//   6. EACH FACE IS ACTUALLY FORCED AND THE WHOLE BOX RE-MEASURED UNDER IT
//      (D75). We never divide one face's box by another face's advance — a
//      verifier who did exactly that reported "1280px fails at 53.95ch Georgia"
//      and it would have been overturn #7. Bare `serif`/`ui-serif` is BANNED as
//      a probe face (D49): it measures narrower than both real faces and
//      INFLATES ch, masking the very bug D39 exists to catch.
//
// ── Three more, learned when this instrument became the seal's SPOF (D97) ────
//
//   7. THE DRILL NAMES ITS DOCUMENT, so a failed run is an INSTRUMENT failure
//      and never a desk fact. It used to click the FIRST `[phx-click="select"]`
//      row in a Papers list that concurrent epic waves rewrite live — 104 rows,
//      newest first, and the newest row changed between two runs. Three
//      independent verifiers hit a 30s `waitForSelector('.bp-paper-surface')`
//      timeout that later passed on the same served SHA. A wave that reads that
//      timeout as a desk fact records a NON-measurement as a measurement, which
//      is this epic's exact disease. Now: `--doc=<slug>` (env `BP_DESK_DOC`)
//      with a committed default targets `[phx-value-id="<slug>"]` directly, the
//      click+wait is retried, and the landed URL is asserted to carry that very
//      slug. `--doc=any` restores the old first-row behaviour but SKIPS rows
//      that yield no paper surface instead of failing on them. Every failure on
//      this path is worded as an instrument failure and lists what it saw.
//
//   8. PROVENANCE IS BRACKETED, NOT STAMPED ONCE. `readProvenance()` used to run
//      once, before the browser launched, and that single snapshot went into all
//      54 records. Caught in the act: a bracketed sweep ran 59.7s and observed
//      `barkpark-slot@green` entering at 00:45:38Z INSIDE the 00:44:51–00:45:50
//      window (blue-only -> blue+green -> green-only across three reads, SHA
//      constant). A same-SHA rotation is benign; a MERGE landing mid-window is
//      equally invisible and would silently misattribute every later row to a
//      commit that no longer matched what was served. Now the SHA and slot are
//      re-read AFTER the sweep, `compareProvenance()` diffs them, and any
//      difference FAILS THE RUN LOUDLY. Every row also carries its own
//      `measured_at`, so a rotation can be located in time rather than inferred.
//
//   9. THE VISIBLE VERDICT IS AUTHORED. `visible_content_px` was measured but
//      the table's `ok?` column was, by its own legend, "the LAYOUT measure
//      against >=55ch — not a verdict on the visible measure", so the number the
//      seal turns on had no verdict at all. Now every record carries
//      `content_ch` / `content_meets_55ch` AND `visible_ch` /
//      `visible_meets_55ch`, and the table prints `lay?` and `vis?` side by
//      side. Both ratios are computed IN-PAGE, in the same face-forced scope
//      that produced the box and the probe, so a cross-face division (D83/D86,
//      overturn #7 averted) is structurally unreachable rather than merely
//      discouraged.
//
// ── Sweep direction ──────────────────────────────────────────────────────────
// DESCENDING, always (D80). `bucket(w, held)` applies its +32px dead-band on
// the WIDEN side only and re-anchors to the bucket currently held, so an
// ASCENDING sweep stamps viewport 640 as `phone`, 1024 as `narrow` and 1280 as
// `standard` — three of these nine widths, and at `phone` the pane columns are
// `display: none` and every floor is neutralised, i.e. a completely different
// layout. The cold-load state additionally re-navigates per row, which makes
// each of its rows independent of the one before it regardless.
//
// ── TWO ENTRY STATES, kept because the question is real even though the
//    answer turned out to be "they agree" ──────────────────────────────────────
// A user can reach a document two ways — by clicking down the desk, or by
// opening its URL cold (a deep link, a reload, a restored tab) — and nobody in
// five waves had checked whether those produce the same layout. This harness's
// OWN first run said they did not: at viewport 900px it read the drilled state
// as panes [44] / panel 856 / content 640 = 64.00ch and the cold-load state as
// panes [44, 260] / panel 596 / content 516 = 51.60ch, which would have been a
// live, unreported 124px defect and a seventh overturn.
//
// It was the INSTRUMENT'S bug, not the desk's. The cold-load rows were being
// measured before the LiveView socket connected and pushed the width bucket, so
// they captured the pre-connect server render — a transient that resolves in
// well under a second. With `waitForDeskSettled()` in place the two states are
// byte-identical at all nine widths (see the matrix). The near-miss is exactly
// why the settle-wait exists and why every row records `settle`.
//
// Both states are still measured and still printed. The disagreement is gone
// today; it is one server-render change away from coming back, and a harness
// that stopped looking would not notice.
//
// ── Settling ────────────────────────────────────────────────────────────────
// The width bucket is stamped into `html[data-width-bucket]` pre-paint by an
// inline script, but the SERVER's `width_bucket` assign only arrives after the
// LiveView socket connects and the hook pushes it — and the pane set and the
// phone breadcrumb are both server-rendered from that assign. Measuring before
// that lands reads a transient. `waitForDeskSettled()` waits for the socket,
// then for a structural signature (pane count + widths + crumbs + bucket) to
// hold still, and every row records whether it settled and how long it took. A
// row that never settled says so instead of quietly reporting the transient.
//
// ── Provenance ───────────────────────────────────────────────────────────────
// Every record carries the served SHA (read live over ssh) and the live slot
// (QUERIED — D71 struck the charter's recorded colour twice; the wish that
// spawned this run said "only GREEN exists" and the live read says blue).
// Also: resolved font family per face, selector match counts, sweep direction,
// scrollbar width, and the landed authenticated URL.
//
// ── Playwright resolution ────────────────────────────────────────────────────
// playwright 1.59.1 + chromium-1217 are cached, but they live in the JS
// monorepo's node_modules, and this script sits in scripts/ — and is routinely
// run from a git WORKTREE, which has no node_modules of its own. So we do not
// assume: `resolvePlaywright()` tries a candidate list (env override, this
// script's own tree, then the MAIN checkout derived from `git rev-parse
// --git-common-dir`, which is how a worktree finds the primary clone) and fails
// loudly with every path it tried. No tiny package.json beside the script,
// because that would need its own install to stay true.
//
// Node 22. No dependencies beyond playwright.

import { createRequire } from 'node:module';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '..');
const JSON_ONLY = process.argv.includes('--json');

/** The COMMITTED default drill target (D97). It must be a document that exists,
 *  is published, and is not being rewritten by a concurrent wave — so it is one
 *  of this epic's OWN sealed wave Papers, never "whatever is newest". If it ever
 *  falls off the Papers pane's first page the run fails LOUDLY naming it, which
 *  is the correct outcome: pass `--doc=<slug>` and the matrix says which
 *  document it measured. */
const DEFAULT_DOC = 'studio-space-priority-desk-browser-2026-07-19';

/** `--doc=any` re-enables the old first-row drill, but skipping rows that do not
 *  open a paper surface rather than dying on the first one that does not. */
const ANY_DOC = 'any';

function resolveDocTarget() {
  const flag = process.argv.find((a) => a.startsWith('--doc='));
  const raw = (flag ? flag.slice('--doc='.length) : process.env.BP_DESK_DOC || DEFAULT_DOC).trim();
  if (!raw) die('--doc= was passed with an empty value — name a document slug, or `any`');
  const source = flag ? '--doc flag' : (process.env.BP_DESK_DOC ? 'BP_DESK_DOC env' : 'committed default');
  return raw === ANY_DOC
    ? { mode: 'any', slug: null, source }
    : { mode: 'named', slug: raw, source };
}

/** The nine widths, DESCENDING (D80). 500 is the floor this matrix commits to;
 *  sub-500 belongs to spd-b6-sub500-phone-proof. */
const WIDTHS = [1440, 1280, 1024, 900, 800, 764, 700, 640, 500];

/** Three reading faces, each ACTUALLY forced. Bare serif/ui-serif is BANNED
 *  (D49). `native` applies no override and reports which family actually won. */
const FACES = [
  { id: 'native', override: null, note: 'no override — the deployed --paper-font-serif stack' },
  { id: 'georgia', override: "Georgia, 'Times New Roman', serif", note: 'forced Georgia' },
  { id: 'source-serif-4', override: "'Source Serif 4', serif", note: 'forced self-hosted Source Serif 4' },
];

/** Asserted before any number is trusted. Impossibility #1. */
const REQUIRED_SELECTORS = ['.bp-paper-surface', '.editor-panel', '.editor-body.bp-paper-body'];

const SSH = ['-i', path.join(os.homedir(), '.ssh/barkpark_indx'), '-o', 'ConnectTimeout=15',
             '-o', 'StrictHostKeyChecking=accept-new', 'root@157.180.90.121'];

// ── failure ──────────────────────────────────────────────────────────────────

class MeasureError extends Error {}
const die = (msg) => { throw new MeasureError(msg); };

// ── playwright ───────────────────────────────────────────────────────────────

function resolvePlaywright() {
  const tried = [];
  const candidates = [];

  if (process.env.BP_PLAYWRIGHT_FROM) candidates.push(process.env.BP_PLAYWRIGHT_FROM);
  candidates.push(path.join(REPO, 'js', 'package.json'), path.join(REPO, 'package.json'));

  // A worktree has no node_modules. --git-common-dir points at the primary
  // clone's .git, whose parent is the checkout that DOES have them.
  try {
    const common = execFileSync('git', ['rev-parse', '--path-format=absolute', '--git-common-dir'],
      { cwd: REPO, encoding: 'utf8' }).trim();
    const primary = path.dirname(common);
    candidates.push(path.join(primary, 'js', 'package.json'), path.join(primary, 'package.json'));
  } catch { /* not a git checkout — the other candidates still apply */ }

  for (const from of candidates) {
    tried.push(from);
    try {
      const require_ = createRequire(from);
      const pw = require_('playwright');
      let version = 'unknown';
      try { version = require_('playwright/package.json').version; } catch { /* keep unknown */ }
      return { pw, resolvedFrom: from, version };
    } catch { /* next */ }
  }
  die(`playwright could not be resolved. Tried, in order:\n  ${tried.join('\n  ')}\n` +
      `Set BP_PLAYWRIGHT_FROM=<path to a package.json that can require("playwright")>.`);
}

// ── provenance (queried, never assumed — D71) ────────────────────────────────

function ssh(cmd) {
  return execFileSync('ssh', [...SSH, cmd], { encoding: 'utf8', timeout: 45_000 }).trim();
}

function readProvenance() {
  let servedSha, slotRaw;
  try {
    servedSha = ssh('cd /opt/barkpark && git rev-parse HEAD');
  } catch (e) {
    die(`could not read the served SHA over ssh — refusing to publish a matrix with no provenance ` +
        `(charter D47: "a measurement taken without it certifies the bug the wave is fixing"). ${e.message}`);
  }
  try {
    slotRaw = ssh(`systemctl list-units 'barkpark-slot@*' --all --no-legend`);
  } catch (e) {
    die(`could not query the live slot over ssh (D71 forbids assuming it). ${e.message}`);
  }
  const loaded = slotRaw.split('\n').map((l) => l.trim()).filter(Boolean);
  const active = loaded.filter((l) => /\bactive\b/.test(l) && /\brunning\b/.test(l));
  return {
    read_at: new Date().toISOString(),
    served_sha: servedSha,
    slot_units_loaded: loaded,
    slot_active: active.map((l) => (l.match(/barkpark-slot@(\w+)\.service/) || [null, 'unknown'])[1]),
    slot_read_method: `ssh root@157.180.90.121 "systemctl list-units 'barkpark-slot@*' --all --no-legend"`,
    sha_read_method: 'ssh root@157.180.90.121 "cd /opt/barkpark && git rev-parse HEAD"',
  };
}

/**
 * The bracket (D97). A sweep takes ~10 minutes; the deployment underneath it is
 * not frozen for our convenience. Returns a list of human-readable differences
 * between the pre-run and post-run reads — EMPTY means every row in between was
 * served by the same code from the same process.
 *
 * Exported so this can be exercised directly, without a 10-minute authenticated
 * run, which is the only way to know the check is not vacuous.
 */
export function compareProvenance(pre, post) {
  const out = [];
  if (pre.served_sha !== post.served_sha) {
    out.push(
      `SERVED SHA CHANGED MID-SWEEP: ${pre.served_sha} (read ${pre.read_at}) -> ` +
      `${post.served_sha} (read ${post.read_at}). A deploy landed inside the measurement window. ` +
      `Rows measured before it describe one build and rows after it describe another, and NOTHING ` +
      `in the matrix says which is which — this is precisely the silent misattribution the bracket exists to catch.`);
  }
  const preSlot = [...pre.slot_active].sort().join(',');
  const postSlot = [...post.slot_active].sort().join(',');
  if (preSlot !== postSlot) {
    out.push(
      `LIVE SLOT CHANGED MID-SWEEP: [${preSlot || 'none'}] (read ${pre.read_at}) -> ` +
      `[${postSlot || 'none'}] (read ${post.read_at}). ` +
      (pre.served_sha === post.served_sha
        ? `The SHA held, so this is most likely a benign same-SHA rotation — but the app RESTARTED under ` +
          `the sweep, so earlier rows were served by a different process than later ones and this run ` +
          `cannot certify a single serving state.`
        : `Combined with the SHA change above, this is a deploy.`));
  }
  return out;
}

// ── auth (D24e login-ticket flow) ────────────────────────────────────────────

function readGuerrillaServer() {
  const p = path.join(os.homedir(), '.config/barkpark/config.json');
  if (!fs.existsSync(p)) die(`no barkpark config at ${p} — cannot read the guerrilla admin token`);
  const cfg = JSON.parse(fs.readFileSync(p, 'utf8'));
  const srv = (cfg.known_servers || []).find((s) => s.name === 'guerrilla');
  if (!srv?.token) die(`no guerrilla entry with a token in ${p} (known_servers[] where name=="guerrilla")`);
  const base = String(srv.server || '').replace(/\/+$/, '');
  // The session cookie is Secure. An http:// or bare-IP base is silently
  // dropped and you spend the whole run measuring a login page.
  if (!base.startsWith('https://')) die(`guerrilla server must be an https:// hostname (got ${base || '<empty>'}) — the session cookie carries Secure and an http/IP form is dropped`);
  return { base, token: srv.token };
}

/** Single-use, 60s TTL. Minted immediately before navigating. An `email` in the
 *  body mints a USER-shaped ticket — the body must stay empty. */
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

// ── the in-page measurement ──────────────────────────────────────────────────
//
// Everything below runs in the browser. It is passed the face override and
// returns one fully self-describing record. Nothing here infers a box from
// another box.

const PAGE_MEASURE = /* js */ `
async (faceOverride) => {
  const px = (v) => { const n = parseFloat(v); return Number.isFinite(n) ? n : null; };
  const round = (n, d = 3) => (n === null ? null : Math.round(n * 10 ** d) / 10 ** d);

  const surface = document.querySelector('.bp-paper-surface');
  const panel   = document.querySelector('.editor-panel');
  const body    = document.querySelector('.editor-body.bp-paper-body');

  const counts = {
    '.bp-paper-surface':          document.querySelectorAll('.bp-paper-surface').length,
    '.editor-panel':              document.querySelectorAll('.editor-panel').length,
    '.editor-body.bp-paper-body': document.querySelectorAll('.editor-body.bp-paper-body').length,
  };
  if (!surface || !panel || !body) return { fatal: true, counts };

  // ── force the face on the surface itself, so its OWN font-family (and every
  //    ch it resolves, including the one inside calc(55ch + 80px)) recomputes.
  const hadInline = surface.style.getPropertyValue('--paper-font-serif');
  const hadInlinePriority = surface.style.getPropertyPriority('--paper-font-serif');
  if (faceOverride) surface.style.setProperty('--paper-font-serif', faceOverride);

  const restore = () => {
    // Value AND priority — restoring without the priority would leave the page
    // in a state this harness invented, for every row after this one.
    if (hadInline) surface.style.setProperty('--paper-font-serif', hadInline, hadInlinePriority);
    else surface.style.removeProperty('--paper-font-serif');
  };

  // ── FORCING A FACE IS NOT THE SAME AS HAVING IT. A self-hosted @font-face is
  //    lazy: until something asks for it, document.fonts.check() is false and
  //    the element silently renders in the NEXT stack entry. Measured on this
  //    very build: a width:1ch probe read 9.000px immediately after forcing
  //    'Source Serif 4' (that is bare fallback serif — the face D49 BANS as a
  //    probe, because it is narrower than both real faces and inflates ch) and
  //    9.171875px once the font was actually loaded. Reporting the first number
  //    would have been overturn #7, produced by this instrument.
  const wantedFamilies = (faceOverride || getComputedStyle(surface).fontFamily)
    .split(',').map((f) => f.trim().replace(/^['"]|['"]$/g, ''))
    .filter((f) => f && !/^(serif|sans-serif|monospace|ui-serif|ui-sans-serif|system-ui)$/.test(f));
  const sizeForLoad = getComputedStyle(surface).fontSize;
  for (const fam of wantedFamilies) {
    try { await document.fonts.load(\`\${sizeForLoad} "\${fam}"\`); } catch { /* not available here */ }
  }
  await document.fonts.ready;
  await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));

  const sCs = getComputedStyle(surface);
  const fontFamilyDeclared = sCs.fontFamily;
  const fontSize = px(sCs.fontSize);

  // Which family actually WON. Advance-width equality against each family in
  // the declared stack, measured in the surface's own font-size. Reported as a
  // method, not asserted as a fact.
  const probeText = 'mmmmmmmmmm0123456789';
  const advanceOf = (family) => {
    const s = document.createElement('span');
    s.textContent = probeText;
    s.style.cssText = 'position:absolute;visibility:hidden;white-space:pre;left:-9999px;';
    s.style.fontSize = sCs.fontSize;
    s.style.fontFamily = family;
    surface.appendChild(s);
    const w = s.getBoundingClientRect().width;
    s.remove();
    return w;
  };
  const stackAdvance = advanceOf(fontFamilyDeclared);
  const families = fontFamilyDeclared.split(',').map((f) => f.trim());
  let winner = null;
  for (const f of families) {
    if (Math.abs(advanceOf(f) - stackAdvance) < 0.01) { winner = f.replace(/^['"]|['"]$/g, ''); break; }
  }

  // ── the gutter: READ, never computed (D72/D78).
  const padL = px(sCs.paddingLeft), padR = px(sCs.paddingRight);
  const borL = px(sCs.borderLeftWidth), borR = px(sCs.borderRightWidth);

  // ── ch via a probe span inserted as a CHILD of .bp-paper-surface (D31/D83).
  const chProbe = document.createElement('span');
  chProbe.style.cssText = 'position:absolute;visibility:hidden;display:inline-block;width:1ch;left:-9999px;';
  surface.appendChild(chProbe);
  const chProbePx = chProbe.getBoundingClientRect().width;
  chProbe.remove();

  // ── the floor, and whether it BINDS — by experiment, not arithmetic.
  const minInlineRaw = sCs.minInlineSize;
  const minInlinePx = px(minInlineRaw);
  const maxWidthPx = px(sCs.maxWidth);

  const widthWithFloor = surface.getBoundingClientRect().width;
  const hadMin = surface.style.getPropertyValue('min-inline-size');
  const hadMinPriority = surface.style.getPropertyPriority('min-inline-size');
  surface.style.setProperty('min-inline-size', '0px', 'important');
  const widthWithoutFloor = surface.getBoundingClientRect().width;
  // Restore the PRIORITY too. We overrode with !important; putting the value
  // back without its original priority would silently promote a plain inline
  // declaration to important for the rest of the run.
  if (hadMin) surface.style.setProperty('min-inline-size', hadMin, hadMinPriority);
  else surface.style.removeProperty('min-inline-size');
  const floorBinds = Math.abs(widthWithFloor - widthWithoutFloor) > 0.5;

  // The browser's own in-floor ch, derived from the resolved floor. We only
  // ever see the USED px value, never the authored formula, so the formula is
  // an ASSUMPTION and is named as one. spd-w5-measure-lever-moves is chartered
  // to change it (to calc(55ch + 2 * var(--paper-gutter)), or to retire it), at
  // which point this derivation goes quietly wrong — so the divergence against
  // the probe is checked below and a drift beyond tolerance is REPORTED, not
  // absorbed. Printed ALONGSIDE the probe, never instead of it.
  const FLOOR_CH_MULTIPLIER = 55;
  const FLOOR_ADDEND_PX = 80;
  const chInFloorPx = (minInlinePx && minInlinePx > FLOOR_ADDEND_PX)
    ? (minInlinePx - FLOOR_ADDEND_PX) / FLOOR_CH_MULTIPLIER
    : null;

  // ── the content box. clientWidth excludes borders and includes padding.
  const surfaceBorderBoxPx = surface.getBoundingClientRect().width;
  const contentPx = surface.clientWidth - padL - padR;

  // ── overflow against D39's real scroller, never .editor-panel, never body.
  const bodyScrollW = body.scrollWidth, bodyClientW = body.clientWidth;

  // ── panes, strips, crumbs. VISIBLE counts, not just DOM counts: at phone the
  //    pane columns are display:none, so a bare querySelectorAll overstates the
  //    routes a user actually has.
  const allPanes = [...document.querySelectorAll('.pane-column')];
  const visible = (e) => getComputedStyle(e).display !== 'none' && e.getBoundingClientRect().width > 0;
  const paneColumns = allPanes.length;
  const paneColumnsVisible = allPanes.filter(visible).length;
  const paneWidths = allPanes.filter(visible).map((e) => round(e.getBoundingClientRect().width, 1));
  const allStrips = [...document.querySelectorAll('.pane-column--collapsed')];
  const strips = allStrips.length;
  const stripsVisible = allStrips.filter(visible).length;
  const stripIsButton = document.querySelectorAll('button.pane-column--collapsed').length;
  const stripAriaExpanded = allStrips.map((e) => e.getAttribute('aria-expanded'));
  const crumbsHost = document.querySelector('.bp-desk-crumbs');
  const crumbs = document.querySelectorAll('.bp-desk-crumb').length;
  const crumbsVisible = crumbsHost ? getComputedStyle(crumbsHost).display !== 'none' : false;

  // ── the inspector, in its DEFAULT state (server-default open — D57). The
  //    LAYOUT measure and the VISIBLE measure are reported side by side: a
  //    matrix that reports only the layout box reads as spin.
  //
  //    THE DOCKED CASE IS NOT A MISSING SUBTRACTION — DO NOT "FIX" IT. When the
  //    inspector is IN FLOW (computed position static/relative, i.e. docked) it
  //    is a sibling column that already took its width out of the panel before
  //    the surface was laid out. The surface's own content box is therefore
  //    ALREADY the width the reader sees, and visible == content is the correct
  //    answer, not an oversight. Subtracting the docked inspector's overlap here
  //    would double-count it and under-report the visible measure at exactly the
  //    two widths (1280, 1440) where this epic's verdict is MEET. We subtract
  //    ONLY when the inspector is out of flow (absolute/fixed), where it covers
  //    the column the surface was already sized for.
  const sidebar = document.querySelector('.bp-doc-sidebar');
  const sRect = surface.getBoundingClientRect();
  const contentLeft = sRect.left + borL + padL;
  const contentRight = sRect.right - borR - padR;
  let inspector = { present: false };
  let visibleContentPx = contentPx;
  if (sidebar) {
    const iCs = getComputedStyle(sidebar);
    const iR = sidebar.getBoundingClientRect();
    const overlapSurface = Math.max(0, Math.min(sRect.right, iR.right) - Math.max(sRect.left, iR.left));
    const overlapContent = Math.max(0, Math.min(contentRight, iR.right) - Math.max(contentLeft, iR.left));
    const overlays = iCs.position === 'absolute' || iCs.position === 'fixed';
    if (overlays) visibleContentPx = contentPx - overlapContent;
    inspector = {
      present: true,
      is_open: sidebar.classList.contains('is-open'),
      default_state_note: 'server-default OPEN — this is the state a user lands in, not one this harness opened',
      position: iCs.position,
      display: iCs.display,
      width_px: round(iR.width),
      z_index: iCs.zIndex,
      overlays_surface: overlays,
      overlap_over_surface_px: round(overlapSurface),
      overlap_over_content_box_px: round(overlapContent),
    };
  }

  // ── the scrim is an ::after pseudo-element on .editor-with-preview.
  const withPreview = document.querySelector('.editor-with-preview');
  let scrim = { host_present: !!withPreview, renders: false };
  if (withPreview) {
    const aCs = getComputedStyle(withPreview, '::after');
    scrim = {
      host_present: true,
      renders: aCs.content !== 'none' && aCs.content !== 'normal',
      content: aCs.content,
      position: aCs.position,
      background: aCs.backgroundColor,
      pointer_events: aCs.pointerEvents,
      z_index: aCs.zIndex,
    };
  }

  const pR = panel.getBoundingClientRect();

  // ── THE VERDICTS. Both are computed HERE, inside the scope that forced this
  //    row's face and measured this row's boxes with this row's own probe span.
  //    That is deliberate and structural: there is no place in this function
  //    where another face's px-per-ch is in scope, so the cross-face division
  //    that manufactured the false "1280 fails at 53.95ch Georgia" (D83/D86,
  //    overturn #7 averted) cannot be written here even by accident.
  //
  //    visible_meets_55ch is the verdict this epic seals on: the measure a
  //    reader actually SEES, against the same >=55ch bar as the layout measure.
  //    Neither is rounded toward the criterion — the comparison is on the raw
  //    ratio and only the REPORTED figure is rounded.
  const CRITERION_CH = 55;
  const contentCh = chProbePx > 0 ? contentPx / chProbePx : null;
  const visibleCh = chProbePx > 0 ? visibleContentPx / chProbePx : null;

  restore();

  return {
    fatal: false,
    counts,
    font: {
      declared_stack: fontFamilyDeclared,
      resolved_family: winner,
      resolution_method: winner
        ? 'advance-width equality vs each family in the declared stack (10x m + 10 digits, at the surface font-size)'
        : 'NO family in the declared stack reproduced the stack advance — resolved face UNKNOWN',
      font_size_px: round(fontSize),
      stack_advance_20ch_px: round(stackAdvance),
      // Did the face we asked for actually WIN, or did we fall through to a
      // fallback and quietly measure something else? The matrix must never
      // present a fallback reading as the named face.
      requested_primary: wantedFamilies[0] ?? null,
      face_applied: winner !== null && wantedFamilies.length > 0 && winner === wantedFamilies[0],
      face_available: wantedFamilies.map((f) => ({ family: f, loaded: document.fonts.check(\`\${sizeForLoad} "\${f}"\`) })),
      fell_back_to_generic_serif: winner === null || /^(serif|ui-serif)$/.test(String(winner)),
    },
    ch: {
      probe_px_per_ch: round(chProbePx, 4),
      probe_method: 'span[style="width:1ch"] inserted as a CHILD of .bp-paper-surface',
      in_floor_px_per_ch: round(chInFloorPx, 4),
      in_floor_method: minInlinePx
        ? \`(resolved min-inline-size - \${FLOOR_ADDEND_PX}) / \${FLOOR_CH_MULTIPLIER}\`
        : 'min-inline-size resolved to 0 — no in-floor ch to derive',
      in_floor_formula_assumed: \`calc(\${FLOOR_CH_MULTIPLIER}ch + \${FLOOR_ADDEND_PX}px)\`,
      divergence_pct: (chProbePx && chInFloorPx) ? round(((chInFloorPx - chProbePx) / chProbePx) * 100, 4) : null,
    },
    gutter: {
      padding_left_px: padL, padding_right_px: padR, total_px: padL + padR,
      border_left_px: borL, border_right_px: borR,
      method: 'getComputedStyle(.bp-paper-surface).paddingLeft/paddingRight — READ, never width-80 (D72/D78)',
    },
    panel_px: round(pR.width),
    surface_border_box_px: round(surfaceBorderBoxPx),
    surface_max_width_px: maxWidthPx,
    content_px: round(contentPx),
    visible_content_px: round(visibleContentPx),
    measure_note: 'content_px is the LAYOUT measure; visible_content_px subtracts the inspector overlap where the inspector is out of flow (D57). Where the inspector is DOCKED (in flow) visible == content by design: layout already shrank the surface, so subtracting again would double-count.',
    criterion_ch: CRITERION_CH,
    content_ch: round(contentCh, 2),
    content_meets_55ch: contentCh === null ? null : contentCh >= CRITERION_CH,
    visible_ch: round(visibleCh, 2),
    visible_meets_55ch: visibleCh === null ? null : visibleCh >= CRITERION_CH,
    verdict_note:
      'Both ch figures divide THIS row\\'s box by THIS row\\'s own probe span, measured under THIS ' +
      'row\\'s forced face (D83/D86 — no cross-face division). visible_meets_55ch is the VISIBLE ' +
      'verdict; content_meets_55ch is the LAYOUT verdict. They are different questions.',
    floor: {
      min_inline_size_raw: minInlineRaw,
      min_inline_size_px: round(minInlinePx),
      binds: floorBinds,
      bind_test: 'measured, then min-inline-size forced to 0px inline and re-measured, then restored — a width change IS the bind',
      width_with_floor_px: round(widthWithFloor),
      width_without_floor_px: round(widthWithoutFloor),
    },
    overflow: {
      scroller: '.editor-body.bp-paper-body',
      scroll_width: bodyScrollW, client_width: bodyClientW,
      horizontal_scroll: bodyScrollW > bodyClientW,
      overflow_px: bodyScrollW - bodyClientW,
    },
    panes: {
      pane_columns: paneColumns,
      pane_columns_visible: paneColumnsVisible,
      visible_pane_widths_px: paneWidths,
      strips: strips,
      strips_visible: stripsVisible,
      strip_is_button: stripIsButton,
      strip_aria_expanded: stripAriaExpanded,
    },
    crumbs: { host_present: !!crumbsHost, visible: crumbsVisible, count: crumbs },
    inspector,
    scrim,
    width_bucket_stamped: document.documentElement.getAttribute('data-width-bucket'),
    scrollbar_width_px: window.innerWidth - document.documentElement.clientWidth,
    viewport_px: window.innerWidth,
  };
}
`;

// ── settling ─────────────────────────────────────────────────────────────────
//
// The bucket is stamped pre-paint by an inline script, but the pane set and the
// phone breadcrumb are SERVER-rendered from a `width_bucket` assign that only
// arrives after the LiveView socket connects and the hook pushes it. Measure
// before that and you measure a transient. We wait for a structural signature
// to hold still, and report whether it actually did.

const SETTLE_SIGNATURE = /* js */ `() => {
  const panes = [...document.querySelectorAll('.pane-column')];
  return JSON.stringify({
    b: document.documentElement.getAttribute('data-width-bucket'),
    n: panes.length,
    w: panes.map((e) => Math.round(e.getBoundingClientRect().width)),
    c: document.querySelectorAll('.bp-desk-crumb').length,
    p: Math.round((document.querySelector('.editor-panel')?.getBoundingClientRect().width) || -1),
    // \`window.liveSocket\` is NOT exposed on this build (measured: undefined).
    // LiveView's own marker is the class it puts on the main element.
    connected: !!document.querySelector('[data-phx-main].phx-connected'),
  });
}`;

async function waitForDeskSettled(page, { quietMs = 800, timeoutMs = 20_000 } = {}) {
  const started = Date.now();
  let last = null, lastChange = Date.now(), connected = false;
  while (Date.now() - started < timeoutMs) {
    const sig = await page.evaluate((src) => eval(`(${src})`)(), SETTLE_SIGNATURE);
    const parsed = JSON.parse(sig);
    if (parsed.connected) connected = true;
    if (sig !== last) { last = sig; lastChange = Date.now(); }
    else if (connected && Date.now() - lastChange >= quietMs) {
      return { settled: true, settle_ms: Date.now() - started, live_socket_connected: true, signature: last };
    }
    await page.waitForTimeout(100);
  }
  return {
    settled: false,
    settle_ms: Date.now() - started,
    live_socket_connected: connected,
    signature: last,
    note: connected
      ? 'the desk never held still — this row is a moving target, not a measurement'
      : 'the LiveView socket never reported connected — the server-rendered pane set may be the pre-connect default',
  };
}

// ── entry states ─────────────────────────────────────────────────────────────

/** Every failure inside the drill is an INSTRUMENT failure, never a desk fact
 *  (D97). The wording is not decoration: three verifiers read a drill timeout as
 *  evidence about the desk, which is how a non-measurement gets recorded as a
 *  measurement. */
const drillDie = (msg, seen) =>
  die(`INSTRUMENT FAILURE (drill) — this says NOTHING about the desk's layout; ` +
      `the harness never reached a document to measure.\n\n  ${msg}` +
      (seen ? `\n\n  What the drill saw:\n${seen}` : '') +
      `\n\n  This is not a measurement and must not be recorded as one. Re-run, or pass ` +
      `--doc=<slug> to name a different document (--doc=any takes the first row that opens).`);

/** Open the Papers list pane. Returns the pane locator. */
async function openPapersPane(page, base) {
  await page.goto(`${base}/w/default/p/default/d/production/studio`, { waitUntil: 'domcontentloaded' });
  await waitForDeskSettled(page);

  const typeItem = page.locator('.pane-column .pane-item', { hasText: 'Papers' }).first();
  if (await typeItem.count() === 0) {
    drillDie('the root desk rendered no "Papers" entry to drill into.');
  }
  await typeItem.click();
  await waitForDeskSettled(page);
  return page.locator('.pane-column').last();
}

/** One click-and-wait attempt at a located row. Resolves to the landed pathname,
 *  or null if no paper surface appeared. Never throws on a miss — a miss is data
 *  the caller uses to try the next candidate. */
async function tryOpenRow(page, row, { timeoutMs = 20_000 } = {}) {
  try {
    await row.click({ timeout: 10_000 });
    await page.waitForSelector('.bp-paper-surface', { timeout: timeoutMs });
    await waitForDeskSettled(page);
    const landed = new URL(page.url()).pathname;
    return /\/studio\/paper\/[^/]+$/.test(landed) ? landed : null;
  } catch {
    return null;
  }
}

/** Drill by CLICKING, exactly as a user does: root desk -> Papers -> document.
 *  Returns the document path the drill landed on, so the cold-load state
 *  measures the very same document.
 *
 *  DETERMINISM (D97). The Papers list is ordered newest-first and concurrent
 *  epic waves publish into it continuously, so "the first row" is a moving
 *  target: 104 rows were observed and the first one changed between two runs of
 *  this very script. A named target is matched on `[phx-value-id]` — the slug
 *  the row carries — and the landed URL is asserted to carry that same slug, so
 *  the matrix cannot claim a document it did not measure. */
async function drillToDocument(page, base, target) {
  const pane = await openPapersPane(page, base);
  const rows = pane.locator('[phx-click="select"]');
  const rowCount = await rows.count();
  if (rowCount === 0) {
    drillDie('the Papers list pane rendered no [phx-click="select"] document row — nothing to open.');
  }

  // `select` is the document-open event. The pane header's own buttons
  // (airdrop-open / access-open / new-document) are NOT it — clicking those
  // opens a modal and the drill silently never happens.
  if (target.mode === 'named') {
    const attempts = [];
    for (let attempt = 1; attempt <= 3; attempt++) {
      // Re-locate every attempt: the list re-renders under us, and a handle
      // captured before a patch is exactly what made the old drill flaky.
      const named = pane.locator(`[phx-click="select"][phx-value-id="${target.slug}"]`).first();
      if (await named.count() === 0) {
        const visible = await rows.evaluateAll(
          (els) => els.slice(0, 8).map((e) => e.getAttribute('phx-value-id')));
        drillDie(
          `the Papers list has no row with phx-value-id="${target.slug}" ` +
          `(target came from the ${target.source}).`,
          `    ${rowCount} rows rendered. First 8 slugs:\n` +
          visible.map((s) => `      ${s}`).join('\n') +
          `\n    If the target has simply aged off the list, pass --doc=<slug> with one of these.`);
      }
      const landed = await tryOpenRow(page, named);
      if (landed) {
        const slugInUrl = decodeURIComponent(landed.split('/').pop());
        if (slugInUrl !== target.slug) {
          drillDie(
            `clicked the row for "${target.slug}" but landed on "${slugInUrl}" (${landed}). ` +
            `Refusing to label this run with a document it did not open.`);
        }
        return { path: landed, slug: slugInUrl, attempts: attempt, rows_in_list: rowCount };
      }
      attempts.push(`attempt ${attempt}: clicked the row, no .bp-paper-surface appeared`);
      await page.goto(`${base}/w/default/p/default/d/production/studio`, { waitUntil: 'domcontentloaded' });
      await waitForDeskSettled(page);
      await openPapersPane(page, base);
    }
    drillDie(
      `three attempts to open "${target.slug}" all failed to produce a .bp-paper-surface.`,
      attempts.map((a) => `      ${a}`).join('\n'));
  }

  // `--doc=any`: the historical first-row behaviour, but a row that does not
  // open a paper surface is SKIPPED rather than fatal. Some documents in this
  // list are not papers and never render the surface.
  const skipped = [];
  const budget = Math.min(rowCount, 10);
  for (let i = 0; i < budget; i++) {
    const row = pane.locator('[phx-click="select"]').nth(i);
    const slug = await row.getAttribute('phx-value-id');
    const landed = await tryOpenRow(page, row);
    if (landed) {
      return {
        path: landed,
        slug: decodeURIComponent(landed.split('/').pop()),
        attempts: i + 1,
        rows_in_list: rowCount,
        skipped_rows: skipped,
      };
    }
    skipped.push(slug ?? '(no phx-value-id)');
    await page.goto(`${base}/w/default/p/default/d/production/studio`, { waitUntil: 'domcontentloaded' });
    await waitForDeskSettled(page);
    await openPapersPane(page, base);
  }
  drillDie(
    `none of the first ${budget} of ${rowCount} rows opened a paper surface (--doc=any).`,
    skipped.map((s) => `      skipped ${s}`).join('\n'));
}

// ── run ──────────────────────────────────────────────────────────────────────

async function main() {
  const { pw, resolvedFrom, version: pwVersion } = resolvePlaywright();
  const docTarget = resolveDocTarget();
  // PRE half of the bracket (D97). The POST half runs after the sweep and a
  // difference fails the run — see compareProvenance().
  const provenance = readProvenance();
  const srv = readGuerrillaServer();

  const browser = await pw.chromium.launch();
  const ctx = await browser.newContext({ viewport: { width: WIDTHS[0], height: 900 } });
  const page = await ctx.newPage();

  const run = {
    generated_at: new Date().toISOString(),
    instrument: 'scripts/studio-desk-measure.mjs',
    contract: 'prints a matrix, or exits non-zero naming the failed selector — no gate authority',
    playwright_version: pwVersion,
    playwright_resolved_from: resolvedFrom,
    node_version: process.version,
    platform: `${os.platform()} ${os.arch()}`,
    platform_note:
      'macOS overlay scrollbars: scrollbar_width_px is 0 here. A classic 15px-scrollbar ' +
      'platform removes ~15px from the panel at EVERY width, pushing viewport 1280 further ' +
      'under the criterion and moving gate-reachability from ~764px to ~779px (D83).',
    target: srv.base,
    sweep_direction: 'descending',
    sweep_note:
      'Descending (D80). The width-bucket dead-band is widen-only and re-anchors to the bucket ' +
      'currently held, so an ASCENDING sweep stamps viewport 640 as `phone`, 1024 as `narrow` ' +
      'and 1280 as `standard` — three of these nine widths. The cold-load state additionally ' +
      're-navigates per row; the drilled state cannot reload without destroying the state it names.',
    entry_states_note:
      'Two entry states, because a user can reach a document two ways and nobody had checked ' +
      'whether they agree. `drilled` = clicked root desk -> Papers -> document (the state ' +
      'D49/D74 measured). `cold-load` = the same document URL opened fresh, as a deep link, a ' +
      'reload or a restored tab does. They agree at all nine widths on this run. This harness\'s ' +
      'own first run said they differed by 124px at viewport 900px — that was the instrument ' +
      'measuring before the LiveView socket pushed the width bucket, not a defect in the desk, ' +
      'and it is why every row now carries `settle`.',
    faces_note:
      'Each face is ACTUALLY forced via --paper-font-serif on .bp-paper-surface and the WHOLE ' +
      'box re-measured under it. No ch figure anywhere divides one face box by another face ' +
      'advance (D75). Bare serif/ui-serif is banned as a probe face (D49).',
    doc_target: docTarget,
    doc_target_note:
      'The drill targets a NAMED document (D97). It used to click the first row of a Papers list ' +
      'that concurrent waves rewrite live, which made a failed run indistinguishable from a desk ' +
      'fact. `--doc=<slug>` / BP_DESK_DOC override the committed default; `--doc=any` restores ' +
      'first-row behaviour, skipping rows that open no paper surface.',
    provenance,
    provenance_note:
      'BRACKETED (D97): `provenance` is the PRE-sweep read and `provenance_post` the POST-sweep ' +
      'read of the same two facts. `provenance_bracket.matched` false means the run FAILED — a ' +
      'published matrix always carries a matched bracket. Each row also carries its own ' +
      '`measured_at`, so a mid-sweep rotation can be located in time rather than inferred.',
    warnings: [],
    rows: [],
  };

  try {
    // ── authenticate: mint immediately before navigating (60s TTL, single use).
    const ticket = await mintTicket(srv);
    await page.goto(`${srv.base}/login/ticket/${ticket}`, { waitUntil: 'domcontentloaded' });
    // LiveView holds a websocket open forever, so `networkidle` never settles.
    if (/\/login(\b|\/|$)/.test(new URL(page.url()).pathname)) {
      die(`login-ticket flow landed back on ${page.url()} — the session cookie was not set. ` +
          `Every number after this would be a measurement of a login page.`);
    }
    run.landed_authenticated_url = page.url();

    // ── the drilled state, reached the way a user reaches it. This also tells
    //    us WHICH document to cold-load, so both states measure the same one.
    await page.setViewportSize({ width: WIDTHS[0], height: 900 });
    const drill = await drillToDocument(page, srv.base, docTarget);
    const docPath = drill.path;
    run.drill = drill;
    run.measured_url = srv.base + docPath;
    run.measured_document = drill.slug;

    /** One (width x face) block against whatever is currently on screen. */
    const sweepRow = async (width, state) => {
      for (const sel of REQUIRED_SELECTORS) {
        const n = await page.locator(sel).count();
        if (n === 0) {
          die(`SELECTOR MATCHED ZERO ELEMENTS at viewport ${width}px, state "${state}": \`${sel}\`. ` +
              `Refusing to report a number derived from an element that is not there. ` +
              `(Impossibility #1 — this is how D31 and D39 happened.)`);
        }
      }
      const settle = await waitForDeskSettled(page);
      await page.evaluate(() => document.fonts.ready);

      for (const face of FACES) {
        const rec = await page.evaluate(
          ({ src, override }) => eval(`(${src})`)(override),
          { src: PAGE_MEASURE, override: face.override },
        );
        if (rec.fatal) {
          die(`a required element vanished mid-measure at viewport ${width}px, state "${state}", ` +
              `face ${face.id}: ${JSON.stringify(rec.counts)}`);
        }
        // Bare serif/ui-serif is a BANNED probe face (D49): it measures
        // narrower than both real faces and INFLATES ch, masking the very bug
        // this matrix exists to catch. If a forced face fell through to it,
        // every ch in that row is poison — refuse rather than publish it.
        if (face.override && rec.font.fell_back_to_generic_serif) {
          die(`face "${face.id}" (${face.override}) fell through to generic serif at viewport ` +
              `${width}px, state "${state}". D49 BANS bare serif/ui-serif as a probe face — it ` +
              `inflates ch and would hand the next verifier a free overturn. Availability: ` +
              JSON.stringify(rec.font.face_available));
        }
        // The in-floor ch derivation ASSUMES the authored formula is
        // `calc(55ch + 80px)`; the browser only ever exposes the used px. The
        // two ch readings agree to ~0.107% today (D83). A drift past 2% means
        // the assumption has rotted — almost certainly because the floor's
        // formula changed (spd-w5-measure-lever-moves is chartered to change
        // it) — so it is REPORTED rather than silently published as a number.
        const drift = rec.ch.divergence_pct;
        if (drift !== null && Math.abs(drift) > 2) {
          run.warnings.push(
            `viewport ${width}px / ${state} / face "${face.id}": in-floor ch diverges from the ` +
            `probe by ${drift}% (assumed formula ${rec.ch.in_floor_formula_assumed}, resolved ` +
            `${rec.floor.min_inline_size_raw}). The floor's authored formula has probably changed — ` +
            `\`in_floor_px_per_ch\` in these rows is derived from a stale assumption. The probe ch ` +
            `(and every ch in the table above) is unaffected.`);
        }
        if (face.override && !rec.font.face_applied) {
          run.warnings.push(
            `viewport ${width}px / ${state} / face "${face.id}": asked for ` +
            `${rec.font.requested_primary}, resolved ${rec.font.resolved_family} — ` +
            `this row's ch is NOT the named face.`);
        }
        run.rows.push({
          // Per-row wall clock (D97). Without it a bracket mismatch tells you
          // THAT the deployment moved but not WHICH rows straddle it.
          measured_at: new Date().toISOString(),
          viewport_px: width,
          entry_state: state,
          face: face.id,
          face_forced_to: face.override,
          face_note: face.note,
          served_sha: provenance.served_sha,
          slot_active: provenance.slot_active,
          sweep_direction: 'descending',
          settle,
          ...rec,
        });
      }
      // Leave the native face on screen for whatever the next step measures.
      await page.evaluate(() => {
        const s = document.querySelector('.bp-paper-surface');
        if (s) s.style.removeProperty('--paper-font-serif');
      });
    };

    // State A — DRILLED. Descending, and deliberately NO reload: a reload is
    // exactly what turns this state into the other one.
    for (const width of WIDTHS) {
      await page.setViewportSize({ width, height: 900 });
      await sweepRow(width, 'drilled');
    }

    // State B — COLD-LOAD. Descending, with a fresh navigation per row.
    for (const width of WIDTHS) {
      await page.setViewportSize({ width, height: 900 });
      await page.goto(srv.base + docPath, { waitUntil: 'domcontentloaded' });
      await page.waitForSelector('.bp-paper-surface', { timeout: 30_000 });
      if (/\/login(\b|\/|$)/.test(new URL(page.url()).pathname)) {
        die(`the document URL redirected to ${page.url()} at viewport ${width}px — session lost mid-sweep`);
      }
      await sweepRow(width, 'cold-load');
    }
  } finally {
    await browser.close();
  }

  // ── CLOSE THE BRACKET (D97). The sweep is over; re-read the two facts every
  //    row was stamped with. If either moved, every row's provenance is a claim
  //    the run cannot support, so the run FAILS rather than publishing a matrix
  //    whose stamps are fiction. A ~10 minute run is cheap enough to discard.
  const provenancePost = readProvenance();
  const mismatches = compareProvenance(provenance, provenancePost);
  run.provenance_post = provenancePost;
  run.provenance_bracket = {
    matched: mismatches.length === 0,
    mismatches,
    window_ms: Date.parse(provenancePost.read_at) - Date.parse(provenance.read_at),
    method: 'served SHA + active slot read over ssh immediately before the browser launched and immediately after the sweep',
  };
  if (mismatches.length) {
    die(`PROVENANCE BRACKET FAILED — the deployment moved UNDER the sweep, so all ` +
        `${run.rows.length} records carry a provenance stamp this run cannot support. ` +
        `Discarding the matrix.\n\n` +
        mismatches.map((m) => `  - ${m}`).join('\n\n') +
        `\n\n  Window: ${provenance.read_at} -> ${provenancePost.read_at} ` +
        `(${Math.round((Date.parse(provenancePost.read_at) - Date.parse(provenance.read_at)) / 1000)}s). ` +
        `Every row carries its own \`measured_at\`, so a partial salvage is possible — but this ` +
        `harness will not do it silently. Wait for the deploy to finish and re-run.`);
  }

  // The contract is "it prints a matrix". The JSON matrix IS the deliverable;
  // the human table is a convenience rendered from it. A formatting bug in the
  // table (one null where a number was expected, at the very end of a ~10min
  // authenticated run) must never destroy the data the run was for — so the
  // table is best-effort and says so on stderr if it fails.
  if (!JSON_ONLY) {
    try {
      printTable(run);
    } catch (e) {
      process.stderr.write(
        `\n  [table] the human table failed to render: ${e?.message || e}\n` +
        `  The JSON matrix below is unaffected and is the authoritative record.\n\n`);
    }
  }
  process.stdout.write(JSON.stringify(run, null, 2) + '\n');
}

// ── human table ──────────────────────────────────────────────────────────────

function printTable(run) {
  const L = (s = '') => process.stdout.write(s + '\n');
  const yn = (b) => (b ? 'yes' : 'no');

  L('');
  L('  STUDIO DESK — LIVE MEASURE MATRIX');
  L('  ' + '='.repeat(118));
  L(`  target        ${run.target}`);
  L(`  document      ${run.measured_document}`);
  L(`  landed as     ${run.landed_authenticated_url}`);
  L(`  measured url  ${run.measured_url}`);
  L(`  served SHA    ${run.provenance.served_sha}   (read live over ssh)`);
  L(`  live slot     ${run.provenance.slot_active.join(', ') || 'NONE ACTIVE'}   (queried, never assumed — D71)`);
  L(`  slot units    ${run.provenance.slot_units_loaded.join(' | ') || '(none loaded)'}`);
  if (run.provenance_bracket) {
    L(`  provenance    BRACKETED — pre ${run.provenance.read_at} / post ${run.provenance_post.read_at} ` +
      `(${Math.round(run.provenance_bracket.window_ms / 1000)}s): ` +
      `${run.provenance_bracket.matched ? 'SHA and slot both held across the whole sweep' : 'MISMATCH'} (D97)`);
  }
  L(`  drill target  ${run.doc_target.mode === 'any' ? 'first row that opens (--doc=any)' : run.doc_target.slug} ` +
    `(from the ${run.doc_target.source})` +
    (run.drill ? `; opened on attempt ${run.drill.attempts} of ${run.drill.rows_in_list} rows` : ''));
  L(`  sweep         ${run.sweep_direction} (D80); cold-load re-navigates per row, drilled must not`);
  L(`  platform      ${run.platform} — scrollbar ${run.rows[0]?.scrollbar_width_px ?? '?'}px (macOS overlay; D83)`);
  L('');

  const cols = [
    ['viewport', 9], ['face', 15], ['bucket', 9], ['panes', 16], ['panel', 7],
    ['gutter', 7], ['content', 8], ['px/ch', 8], ['ch', 7], ['floor?', 7],
    ['xscroll', 8], ['strip', 6], ['crumb', 6], ['insp', 6], ['lay?', 6],
    ['visible', 8], ['vis-ch', 8], ['vis?', 5],
  ];
  const pad = (v, w) => String(v).padEnd(w);
  // The row's OWN in-page figures. Never recomputed here from another row's
  // px/ch — the table renders verdicts, it does not author them (D83/D86).
  const chOf = (r) => (r.content_ch ?? null);
  const RULE = '  ' + '-'.repeat(150);

  for (const state of ['drilled', 'cold-load']) {
    const rows = run.rows.filter((r) => r.entry_state === state);
    if (!rows.length) continue;
    L(`  ENTRY STATE: ${state.toUpperCase()}   ` +
      (state === 'drilled'
        ? '(clicked: root desk -> Papers -> document — the state D49/D74 measured)'
        : '(the same document URL opened fresh, as any deep link or reload does)'));
    L('  ' + cols.map(([h, w]) => pad(h, w)).join(''));
    L(RULE);
    let lastVp = null;
    for (const r of rows) {
      if (lastVp !== null && r.viewport_px !== lastVp) L(RULE);
      lastVp = r.viewport_px;
      const ch = chOf(r);
      L('  ' + [
        pad(r.viewport_px + (r.settle.settled ? '' : '*'), 9),
        pad(r.face, 15),
        pad(r.width_bucket_stamped ?? '(none)', 9),
        pad('[' + r.panes.visible_pane_widths_px.join(',') + ']', 16),
        pad(r.panel_px, 7),
        pad(r.gutter.total_px, 7),
        pad(r.content_px, 8),
        pad(r.ch.probe_px_per_ch, 8),
        pad(ch === null ? '?' : ch.toFixed(2), 7),
        pad(yn(r.floor.binds), 7),
        pad(yn(r.overflow.horizontal_scroll), 8),
        pad(r.panes.strips_visible, 6),
        pad(r.crumbs.visible ? r.crumbs.count : 0, 6),
        pad(r.inspector.present ? (r.inspector.overlays_surface ? 'ovl' : 'dock') : 'n/a', 6),
        pad(r.content_meets_55ch ? 'MEET' : 'FAIL', 6),
        pad(r.visible_content_px, 8),
        pad(r.visible_ch === null ? '?' : r.visible_ch.toFixed(2), 8),
        pad(r.visible_meets_55ch ? 'MEET' : 'FAIL', 5),
      ].join(''));
    }
    L('');
  }

  L('  ' + '='.repeat(150));
  L('  content = surface.clientWidth - READ paddingLeft/Right (never width-80 — D72/D78).');
  L('  ch      = content_px / a width:1ch probe span CHILD of .bp-paper-surface, in THAT face (D31/D83).');
  L('  floor?  = min-inline-size forced to 0 and re-measured; a width change IS the bind (not arithmetic).');
  L('  xscroll = .editor-body.bp-paper-body scrollWidth > clientWidth (D39\'s real scroller).');
  L('  insp    = inspector DOCKed (in flow, steals width) vs OVLays (out of flow, covers the column).');
  L('  visible = content_px minus the inspector overlap where it overlays — the measure a reader SEES (D57).');
  L('  panes   = VISIBLE .pane-column widths. strip/crumb are VISIBLE counts, not DOM counts.');
  L('  *       = the desk never settled at this width; treat the row as a moving target.');
  L('  lay?    = the LAYOUT verdict: content_px / this row\'s own px/ch, against >=55ch.');
  L('  vis?    = the VISIBLE verdict: visible_content_px / this row\'s own px/ch, against >=55ch.');
  L('            Same bar, different question — vis? is what a reader actually gets. Where the');
  L('            inspector is DOCKED the two agree BY DESIGN: layout already took the inspector\'s');
  L('            width out of the surface, so subtracting it again would double-count (see the');
  L('            comment on the docked case in PAGE_MEASURE — this is not a missing subtraction).');
  L('  Both ch figures divide THIS row\'s box by THIS row\'s probe span under THIS row\'s forced');
  L('  face. No figure anywhere divides one face\'s box by another face\'s advance (D83/D86).');
  L('');

  // The visible census — the number this wave's seal ruling turns on, stated as
  // a count rather than left for a reader to tally out of 54 rows.
  for (const state of ['drilled', 'cold-load']) {
    const rows = run.rows.filter((r) => r.entry_state === state);
    if (!rows.length) continue;
    const meet = rows.filter((r) => r.visible_meets_55ch);
    const lay = rows.filter((r) => r.content_meets_55ch).length;
    L(`  VISIBLE VERDICT (${state}): ${meet.length} of ${rows.length} cells MEET >=55ch of VISIBLE measure ` +
      `(the LAYOUT measure meets in ${lay}).`);
    if (meet.length === 0) {
      L('    None — at any width, in any face. Every cell in this state reads under the criterion.');
    } else {
      const byWidth = [...new Set(meet.map((r) => r.viewport_px))].sort((a, b) => b - a);
      for (const w of byWidth) {
        const at = meet.filter((r) => r.viewport_px === w);
        L(`    viewport ${String(w).padStart(4)}px: ${at.map((r) => `${r.face} ${r.visible_ch.toFixed(2)}ch`).join(', ')}`);
      }
      const missWidths = [...new Set(rows.filter((r) => !r.visible_meets_55ch).map((r) => r.viewport_px))]
        .sort((a, b) => b - a);
      L(`    FAIL at: ${missWidths.join(', ')}px (all faces unless listed above).`);
    }
    L('');
  }

  // The epic's own criterion, answered with a number, honestly either way.
  L('  THE EPIC\'S HEADLINE CRITERION — >=55ch of CONTENT at viewport 900px:');
  L('');
  for (const state of ['drilled', 'cold-load']) {
    for (const r of run.rows.filter((x) => x.viewport_px === 900 && x.entry_state === state)) {
      const ch = chOf(r), vch = r.visible_ch;
      L(`    ${pad(state, 11)} ${pad(r.face, 16)} content ${String(r.content_px).padEnd(7)}px = ` +
        `${ch.toFixed(2).padStart(6)}ch  ${r.content_meets_55ch ? 'MEETS' : 'FAILS'}   ` +
        `(visible ${String(r.visible_content_px).padEnd(6)}px = ${vch.toFixed(2)}ch ` +
        `${r.visible_meets_55ch ? 'MEETS' : 'FAILS'})   ` +
        `${r.ch.probe_px_per_ch}px/ch, ${r.font.resolved_family ?? 'UNRESOLVED'} @ ${r.font.font_size_px}px`);
    }
    L('');
  }
  L('  Nothing above is rounded toward the criterion. Where the two entry states disagree,');
  L('  BOTH are printed — the desk genuinely has two answers and a matrix that hides one is spin.');
  L('');

  // The protected floor: where, if anywhere, does it actually do something?
  // This is the input `spd-w5-measure-gate-right-box` needs to pick a constant,
  // so it is reported as a census rather than a claim.
  const bound = run.rows.filter((r) => r.floor.binds);
  L(`  DOES THE PROTECTED FLOOR EVER BIND?  ${bound.length} of ${run.rows.length} cells.`);
  if (bound.length === 0) {
    L('    Never — at any width, in any face, in either entry state. The measure is delivered');
    L('    by the surface\'s own max-width, not by min-inline-size.');
  } else {
    for (const r of bound) {
      L(`    viewport ${r.viewport_px}px / ${r.entry_state} / ${r.face}: ` +
        `floor ${r.floor.min_inline_size_px}px pushed the surface ` +
        `${r.floor.width_without_floor_px} -> ${r.floor.width_with_floor_px}px` +
        (r.overflow.horizontal_scroll
          ? `, and .editor-body.bp-paper-body then overflowed by ${r.overflow.overflow_px}px`
          : ', with no horizontal overflow'));
    }
  }
  L('');

  const unsettled = run.rows.filter((r) => !r.settle.settled).length;
  if (unsettled || run.warnings.length) {
    L('  CAVEATS ON THIS RUN:');
    if (unsettled) L(`    - ${unsettled}/${run.rows.length} rows never settled (marked * above) — those are moving targets.`);
    for (const w of run.warnings) L(`    - ${w}`);
    L('');
  }
}

// Run only when INVOKED, so `compareProvenance` can be imported and exercised
// directly. A bracket check that has never been seen to fire is a check nobody
// can trust, and a ~10-minute authenticated run is far too expensive to be the
// only way to see it fire.
const INVOKED_DIRECTLY = process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);

if (INVOKED_DIRECTLY) {
  main().catch((err) => {
    process.stderr.write('\nMEASURE FAILED — no matrix was produced.\n\n');
    process.stderr.write((err instanceof MeasureError ? err.message : (err?.stack || String(err))) + '\n\n');
    process.exit(1);
  });
}
