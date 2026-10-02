#!/usr/bin/env node
//
// studio-desk-motion-probe.mjs — IS THERE MOTION ON THE DESK, AND DOES THE
// REDUCED-MOTION SETTING REACH IT?
//
// spd-b30-instrument-coverage-one-document-one-path, criterion 3:
// "the desk is checked for reducible motion; reduced-motion browser coverage
//  is added only if a live transition exists, otherwise the no-motion ruling is
//  recorded with source and computed-style evidence."
//
// A ruling of "no motion" read off the stylesheet alone is exactly the artefact
// this lane keeps catching: a reassuring sentence about a property nobody
// probed. root.html.heex carried one of them in the `.pane-column` rule — grep
// for `transitionDuration 0s on every desk element` — written in the present
// tense directly above the `transition: width var(--dur-1)` declaration that
// makes it false. That comment is now a DATED RETRACTION rather than a claim,
// so the grep above finds the correction, not a live assertion — check the
// tense before reading a hit as the original defect. (No line number here on
// purpose: a citation is correct exactly once, and scripts/new-lineref-check.sh
// refuses new ones.) This probe reads the SHIPPED
// COMPUTED STYLE off a live authenticated desk, in both motion regimes, and
// writes the numbers down.
//
// ── WHAT IT MEASURES ─────────────────────────────────────────────────────────
//
// For each of two ARMS — `prefers-reduced-motion: no-preference` and `reduce`,
// emulated by the browser, not by editing CSS — and each of two SURFACES — the
// bare desk and a drilled-into paper — it records, per named selector:
//
//     match count, transition-property/duration/delay/timing-function,
//     animation-name/duration/iteration-count, scroll-behavior
//
// plus `matchMedia('(prefers-reduced-motion: reduce)').matches`, the scrollbar
// width and the width bucket the page stamped on itself.
//
// ── TWO GUARDS, BECAUSE A ZERO IS THE EASY ANSWER TO FAKE ────────────────────
//
//   1. THE EMULATION CONTROL. The `reduce` arm must report `matches: true` and
//      the `no-preference` arm `false`. Without it the two arms could be the
//      same arm and every "reduced motion changes nothing" verdict would be
//      free.
//   2. THE NON-VACUITY GUARD. At least one probed selector must match at least
//      one element AND report a non-zero transition or animation duration in
//      the no-preference arm. A probe that finds no elements reports "0s
//      everywhere" in exactly the same shape as a desk with no motion, and
//      that indistinguishability is how the stale comment above was written.
//      If the guard cannot be satisfied, the run FAILS and says so rather than
//      publishing a no-motion ruling it did not earn.
//
// ── PROVENANCE: HTTPS, NOT SSH, AND IT SAYS SO ───────────────────────────────
//
// `scripts/studio-desk-measure.mjs` brackets its runs by reading the served SHA
// over ssh. This probe brackets over `GET <base>/status.json` instead, because
// the ssh key is not universally held and refusing every motion reading for
// want of one would be worse than naming the weaker source. The difference is
// real and recorded in `provenance.method`: `/status.json` reports the commit
// the APP process believes it is running, which is the same fact the desk's own
// page is served from, and it cannot see the blue/green slot. A mismatch across
// the bracket still fails the run.
//
// ── USAGE ────────────────────────────────────────────────────────────────────
//
//     node scripts/studio-desk-motion-probe.mjs                 # table
//     node scripts/studio-desk-motion-probe.mjs --json
//     node scripts/studio-desk-motion-probe.mjs --out <path>
//
// Exit 0 with a reading, 1 on a guard or a bracket mismatch, 2 on a missing
// prerequisite (no browser, no credentials). It is NOT a gate.

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { resolvePlaywright, browserPolicy, launchMeasureBrowser } from './studio-desk-measure.mjs';

const DESK_PATH = '/w/default/p/default/d/production/studio';

/** THE SELECTORS, each with the source site that motivated it. A probe whose
 *  selector list is undocumented cannot be audited against the stylesheet. */
export const MOTION_SELECTORS = [
  { sel: '.pane-column', why: 'root.html.heex, the .pane-column rule — transition: width/min-width/max-width var(--dur-1) ease' },
  { sel: '.pane-column--collapsed', why: 'root.html.heex, the .pane-column--collapsed rule — the same box transition plus background' },
  { sel: '.pane-column--collapsed > *', why: 'root.html.heex — animation: bp-pane-strip-in var(--dur-1) ease-out both' },
  { sel: '.pane-item', why: 'root.html.heex, the .pane-item rule — declares transition: all var(--dur-1)' },
  { sel: '.pane-doc-item', why: 'a desk row the census presses' },
  { sel: '.editor-panel', why: 'the panel the matrix measures the reading column inside' },
  { sel: '.editor-panel-main.bp-paper-body', why: 'THE reading column — the @container the 720px gate sits on' },
  { sel: '.bp-paper-surface', why: 'THE measured surface — if this moves, every matrix row is a transient' },
  { sel: '.bp-doc-sidebar', why: 'root.html.heex claims the narrow/phone sidebar switch is instant (grep: "the switch between them is")' },
  { sel: '.bp-update-dot', why: 'root.html.heex — bp-update-pulse, the one animation with its own reduce arm' },
];

/** The computed properties read per element. Strings, verbatim, never parsed
 *  into a verdict in the page. */
const PAGE_READ = /* js */`(sels) => {
  const out = [];
  for (const { sel, why } of sels) {
    let els = [];
    try { els = Array.from(document.querySelectorAll(sel)); }
    catch (e) { out.push({ selector: sel, why, error: String(e && e.message || e) }); continue; }
    const seen = [];
    for (const el of els.slice(0, 4)) {
      const cs = getComputedStyle(el);
      seen.push({
        transition_property: cs.transitionProperty,
        transition_duration: cs.transitionDuration,
        transition_delay: cs.transitionDelay,
        transition_timing_function: cs.transitionTimingFunction,
        animation_name: cs.animationName,
        animation_duration: cs.animationDuration,
        animation_iteration_count: cs.animationIterationCount,
        scroll_behavior: cs.scrollBehavior,
      });
    }
    out.push({ selector: sel, why, match_count: els.length, sampled: seen });
  }
  return {
    selectors: out,
    reduce_matches: window.matchMedia('(prefers-reduced-motion: reduce)').matches,
    no_preference_matches: window.matchMedia('(prefers-reduced-motion: no-preference)').matches,
    scrollbar_width_px: window.innerWidth - document.documentElement.clientWidth,
    inner_width: window.innerWidth,
    width_bucket_stamped: document.documentElement.dataset.widthBucket ?? null,
    url: location.pathname,
  };
}`;

/** Any non-zero duration in any sampled element of any selector. */
export function hasLiveMotion(reading) {
  for (const s of reading.selectors) {
    for (const e of s.sampled ?? []) {
      if (nonZeroDuration(e.transition_duration)) return { selector: s.selector, why: 'transition', value: e.transition_duration };
      if (e.animation_name !== 'none' && nonZeroDuration(e.animation_duration)) {
        return { selector: s.selector, why: 'animation', value: `${e.animation_name} ${e.animation_duration}` };
      }
    }
  }
  return null;
}

/** "0s", "0s, 0s" and "" are all zero. Anything with a positive number is not. */
export function nonZeroDuration(v) {
  if (!v) return false;
  return v.split(',').some((part) => {
    const m = /^\s*([\d.]+)(m?s)\s*$/.exec(part);
    return !!m && Number(m[1]) > 0;
  });
}

/** Every selector whose sampled elements differ between the two arms. */
export function armDiff(noPref, reduce) {
  const bySel = new Map(reduce.selectors.map((s) => [s.selector, s]));
  const diffs = [];
  for (const a of noPref.selectors) {
    const b = bySel.get(a.selector);
    if (!b) continue;
    const n = Math.min((a.sampled ?? []).length, (b.sampled ?? []).length);
    for (let i = 0; i < n; i++) {
      for (const k of Object.keys(a.sampled[i])) {
        if (a.sampled[i][k] !== b.sampled[i][k]) {
          diffs.push({ selector: a.selector, element_index: i, property: k,
            no_preference: a.sampled[i][k], reduce: b.sampled[i][k] });
        }
      }
    }
  }
  return diffs;
}

// ── plumbing ────────────────────────────────────────────────────────────────

class ProbeError extends Error { constructor(msg, code = 1) { super(msg); this.code = code; } }

function credentials() {
  const p = path.join(os.homedir(), '.config/barkpark/config.json');
  if (!fs.existsSync(p)) throw new ProbeError(`no barkpark config at ${p} — nothing was probed`, 2);
  const cfg = JSON.parse(fs.readFileSync(p, 'utf8'));
  const srv = (cfg.known_servers || []).find((s) => s.name === 'guerrilla');
  if (!srv?.token) throw new ProbeError(`no guerrilla entry with a token in ${p}`, 2);
  const base = String(srv.server || '').replace(/\/+$/, '');
  if (!base.startsWith('https://')) {
    throw new ProbeError(`guerrilla must be an https:// hostname (got ${base || '<empty>'}) — the session cookie is Secure`, 2);
  }
  return { base, token: srv.token };
}

async function readProvenance(base) {
  const res = await fetch(`${base}/status.json`);
  if (!res.ok) throw new ProbeError(`GET ${base}/status.json returned HTTP ${res.status} — no provenance, no reading`);
  const b = await res.json();
  return {
    read_at: new Date().toISOString(),
    host: base,
    commit: b.commit ?? null,
    version: b.version ?? null,
    app_status: b.status ?? null,
    method: 'GET <base>/status.json over HTTPS — the commit the APP process reports. ' +
      'Weaker than studio-desk-measure.mjs\'s ssh read (it cannot see the blue/green slot) ' +
      'and named as such rather than dressed up as the same thing.',
  };
}

async function mintTicket({ base, token }) {
  const res = await fetch(`${base}/v1/auth/login-tickets`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: '{}',
  });
  if (!res.ok) throw new ProbeError(`login-ticket mint failed: HTTP ${res.status} ${await res.text()}`, 2);
  const body = await res.json();
  if (!body.ticket) throw new ProbeError(`login-ticket response carried no ticket: ${JSON.stringify(body)}`, 2);
  return body.ticket;
}

/** Drill root desk -> Papers -> the newest document, exactly as a user clicks.
 *  Deliberately NOT a copy of studio-desk-measure.mjs's hardened drill: that one
 *  is not exported, and a motion reading does not need its named-document
 *  determinism — it needs A paper surface. The landed URL is still asserted, so
 *  a run can never claim a surface it did not reach. */
async function drillToPaper(page, base) {
  await page.goto(`${base}${DESK_PATH}`, { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('.pane-column', { timeout: 30_000 });
  const papers = page.locator('.pane-column .pane-item', { hasText: 'Papers' }).first();
  if (await papers.count() === 0) throw new ProbeError('the root desk rendered no "Papers" row to drill into');
  await papers.click();
  await page.waitForSelector('.pane-doc-item', { timeout: 30_000 });
  const row = page.locator('.pane-doc-item [phx-click="select"], .pane-doc-item[phx-click="select"]').first();
  const slug = await row.getAttribute('phx-value-id');
  await row.click();
  await page.waitForSelector('.bp-paper-surface', { timeout: 30_000 });
  const landed = new URL(page.url()).pathname;
  if (!landed.endsWith(`/${slug}`)) {
    throw new ProbeError(`drilled at [phx-value-id="${slug}"] and landed on ${landed} — the probe cannot ` +
      `claim to have measured a document whose slug the URL does not carry`);
  }
  return { slug, path: landed };
}

async function probeArm(pw, policy, creds, reducedMotion) {
  const browser = await launchMeasureBrowser(pw, policy);
  try {
    const ctx = await browser.newContext({ viewport: { width: 1280, height: 900 }, reducedMotion });
    const page = await ctx.newPage();
    const ticket = await mintTicket(creds);
    await page.goto(`${creds.base}/login/ticket/${ticket}`, { waitUntil: 'domcontentloaded' });

    await page.goto(`${creds.base}${DESK_PATH}`, { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('.pane-column', { timeout: 30_000 });
    const desk = await page.evaluate((a) => eval(`(${a[0]})`)(a[1]), [PAGE_READ, MOTION_SELECTORS]);

    const doc = await drillToPaper(page, creds.base);
    const paper = await page.evaluate((a) => eval(`(${a[0]})`)(a[1]), [PAGE_READ, MOTION_SELECTORS]);

    return { emulated_reduced_motion: reducedMotion, document: doc, surfaces: { desk, paper },
             browser_version: browser.version() };
  } finally {
    await browser.close();
  }
}

export async function runProbe() {
  const creds = credentials();
  const { pw, version: pwVersion, resolvedFrom } = resolvePlaywright();
  const policy = browserPolicy();

  const pre = await readProvenance(creds.base);
  const noPref = await probeArm(pw, policy, creds, 'no-preference');
  const reduce = await probeArm(pw, policy, creds, 'reduce');
  const post = await readProvenance(creds.base);

  const mismatches = [];
  if (pre.commit !== post.commit) {
    mismatches.push(`SERVED COMMIT CHANGED MID-PROBE: ${pre.commit} -> ${post.commit}. ` +
      `The two motion arms describe two different builds and nothing says which is which.`);
  }

  // GUARD 1 — the emulation actually took.
  const emulation = {
    no_preference_arm_reports_reduce: noPref.surfaces.desk.reduce_matches,
    reduce_arm_reports_reduce: reduce.surfaces.desk.reduce_matches,
    ok: noPref.surfaces.desk.reduce_matches === false && reduce.surfaces.desk.reduce_matches === true,
  };

  // GUARD 2 — something on this desk actually moves.
  const live = {
    desk: hasLiveMotion(noPref.surfaces.desk),
    paper: hasLiveMotion(noPref.surfaces.paper),
  };
  const nonVacuous = !!(live.desk || live.paper);

  const run = {
    generated_at: new Date().toISOString(),
    instrument: 'scripts/studio-desk-motion-probe.mjs',
    contract: 'prints a motion reading in two emulated motion regimes, or exits non-zero naming the guard that failed — no gate authority',
    task: 'spd-b30-instrument-coverage-one-document-one-path (criterion 3)',
    platform: `${os.platform()} ${os.arch()}`,
    engine: 'Chromium only — see coverage_boundary',
    browser_policy: policy.id,
    browser_version: noPref.browser_version,
    playwright_version: pwVersion,
    playwright_resolved_from: resolvedFrom,
    node_version: process.version,
    viewport_px: 1280,
    selectors: MOTION_SELECTORS,
    provenance: pre,
    provenance_post: post,
    provenance_bracket: { matched: mismatches.length === 0, mismatches,
      method: pre.method, window_ms: Date.parse(post.read_at) - Date.parse(pre.read_at) },
    emulation_control: {
      ...emulation,
      what: 'prefers-reduced-motion emulated by the browser (playwright context reducedMotion), ' +
            'and matchMedia read back in the page. Without this the two arms could be the same arm.',
    },
    non_vacuity_guard: {
      ok: nonVacuous,
      first_moving_element: live,
      what: 'at least one probed selector must match an element AND report a non-zero duration in the ' +
            'no-preference arm. A probe that matched nothing prints "0s everywhere" in the same shape ' +
            'as a desk with no motion, and that is how the .pane-column comment in root.html.heex came to claim 0s on every ' +
            'desk element while line 1384 declares a transition.',
    },
    arms: { no_preference: noPref, reduce },
    reduce_changed: {
      desk: armDiff(noPref.surfaces.desk, reduce.surfaces.desk),
      paper: armDiff(noPref.surfaces.paper, reduce.surfaces.paper),
    },
  };

  run.ruling = ruleOn(run);
  return run;
}

/** The verdict, stated as the criterion asks for it. */
export function ruleOn(run) {
  const moving = run.non_vacuity_guard.ok;
  const changed = run.reduce_changed.desk.length + run.reduce_changed.paper.length;
  return {
    live_transition_exists: moving,
    reduced_motion_reaches_it: changed > 0,
    computed_style_properties_changed_under_reduce: changed,
    measured_surfaces: ['desk (root, 1280px)', 'paper (drilled, 1280px)'],
    statement: moving
      ? `A live transition EXISTS on the desk (${run.non_vacuity_guard.first_moving_element.desk?.selector ?? run.non_vacuity_guard.first_moving_element.paper?.selector}), ` +
        `so reduced-motion coverage is warranted and is what this run adds: both regimes measured, ` +
        `${changed} computed property value(s) differ between them.`
      : 'NO live transition was found on either probed surface — but see non_vacuity_guard: this ' +
        'run is NOT entitled to that ruling, because the guard did not pass.',
  };
}

// ── CLI ──────────────────────────────────────────────────────────────────────

function table(run) {
  const L = [];
  L.push('STUDIO DESK MOTION PROBE');
  L.push(`  host          ${run.provenance.host} @ ${run.provenance.commit} (${run.provenance.version})`);
  L.push(`  bracket       ${run.provenance_bracket.matched ? 'MATCHED' : 'MISMATCHED'} over ${run.provenance_bracket.window_ms}ms — ${run.provenance.method.split('.')[0]}`);
  L.push(`  browser       ${run.browser_policy} ${run.browser_version} on ${run.platform} (Chromium only)`);
  L.push(`  document      ${run.arms.no_preference.document.path}`);
  L.push(`  emulation     no-preference arm reduce=${run.emulation_control.no_preference_arm_reports_reduce}, reduce arm reduce=${run.emulation_control.reduce_arm_reports_reduce} — ${run.emulation_control.ok ? 'CONTROL OK' : 'CONTROL FAILED'}`);
  L.push(`  non-vacuity   ${run.non_vacuity_guard.ok ? 'OK' : 'FAILED'}${run.non_vacuity_guard.first_moving_element.desk ? ` — first mover on the desk: ${run.non_vacuity_guard.first_moving_element.desk.selector} (${run.non_vacuity_guard.first_moving_element.desk.value})` : ''}`);
  for (const surface of ['desk', 'paper']) {
    L.push('');
    L.push(`  ${surface.toUpperCase()} — no-preference arm`);
    for (const s of run.arms.no_preference.surfaces[surface].selectors) {
      const e = s.sampled?.[0];
      L.push(`    ${s.selector.padEnd(34)} x${String(s.match_count).padEnd(4)} ` +
        (e ? `transition ${e.transition_duration} (${e.transition_property.slice(0, 40)})  animation ${e.animation_name} ${e.animation_duration}` : '(no element)'));
    }
    const d = run.reduce_changed[surface];
    L.push(`    reduce changes: ${d.length ? '' : 'NOTHING on this surface'}`);
    for (const x of d) L.push(`      ${x.selector}[${x.element_index}].${x.property}: ${x.no_preference}  ->  ${x.reduce}`);
  }
  L.push('');
  L.push(`  RULING: ${run.ruling.statement}`);
  return L.join('\n');
}

const IS_ENTRY = !!process.argv[1]
  && fs.realpathSync(process.argv[1]) === fs.realpathSync(fileURLToPath(import.meta.url));

if (IS_ENTRY) {
  const args = process.argv.slice(2);
  runProbe().then((run) => {
    const outAt = args.indexOf('--out');
    if (outAt >= 0 && args[outAt + 1]) {
      fs.mkdirSync(path.dirname(args[outAt + 1]), { recursive: true });
      fs.writeFileSync(args[outAt + 1], JSON.stringify(run, null, 2) + '\n');
      process.stderr.write(`wrote ${args[outAt + 1]}\n`);
    }
    process.stdout.write(args.includes('--json') ? JSON.stringify(run, null, 2) + '\n' : table(run) + '\n');
    const failed = [];
    if (!run.provenance_bracket.matched) failed.push(...run.provenance_bracket.mismatches);
    if (!run.emulation_control.ok) failed.push('EMULATION CONTROL FAILED — the two arms did not differ in what matchMedia reports, so neither arm measured what it claims to.');
    if (!run.non_vacuity_guard.ok) failed.push('NON-VACUITY GUARD FAILED — no probed selector reported a non-zero duration, so a "no motion" ruling would be indistinguishable from a probe that matched nothing.');
    if (failed.length) {
      process.stderr.write(`\nPROBE FAILED — the reading above is NOT publishable.\n\n  ${failed.join('\n  ')}\n\n`);
      process.exit(1);
    }
  }).catch((err) => {
    process.stderr.write(`\nMOTION PROBE FAILED — nothing was measured, and this says nothing about the desk.\n\n${err?.message ?? err}\n\n`);
    process.exit(err instanceof ProbeError ? err.code : 1);
  });
}
