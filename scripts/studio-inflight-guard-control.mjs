#!/usr/bin/env node
//
// studio-inflight-guard-control.mjs — THE IN-FLIGHT PRESS CONTROL.
//
// spd-w19-click-loading-falls-through. It answers exactly two questions, in
// this order, against a committed static fixture and a real browser:
//
//   0. WITH THE SHIPPED-ON-MAIN GUARD, WHERE DOES A SECOND PRESS GO?
//      (`--ref origin/main`, the repro: the frame it names is the WRONG one.)
//   1. WITH THIS BRANCH'S GUARD, WHERE DOES IT GO?
//      (`--ref WORKTREE`, plus the guard-deleted mutation that proves the
//      guard — not the CSS edit alone — is what closes the hole.)
//
//   node scripts/studio-inflight-guard-control.mjs               # both refs
//   node scripts/studio-inflight-guard-control.mjs --self-test   # + assertions, exit 1 on failure
//   node scripts/studio-inflight-guard-control.mjs --json
//   node scripts/studio-inflight-guard-control.mjs --ref <git ref>
//   node scripts/studio-inflight-guard-control.mjs --help
//
// It runs FULLY OFFLINE: a `file://` fixture, the repo's own playwright, no
// deployed build, no ssh, no network. Prior art and the resolution ladder:
// scripts/studio-scrim-threshold-control.mjs.
//
// ── NOTHING IS COPIED ────────────────────────────────────────────────────────
// Both halves of the guard are EXTRACTED FROM root.html.heex at run time, at
// whichever ref the run names:
//
//   · the CSS   — the `.phx-click-loading, .phx-submit-loading { … }` rule
//   · the JS    — the region fenced BP-INFLIGHT-GUARD-BEGIN/END (ABSENT on
//                 origin/main, which is exactly the state under test in the
//                 repro run)
//
// A hand-copied rule would drift and then prove the fixture rather than the
// shipped guard. The extractor FAILS LOUD when the CSS rule is missing; an
// absent JS fence is a legitimate reading (no guard shipped at that ref) and is
// reported as `guard: false`, never silently treated as "guard present".
//
// ── WHY THE MUTATION IS SCENARIO B AND NOT SCENARIO A ────────────────────────
// Deleting `pointer-events: none` ALONE already stops scenario A: the press
// lands back on the in-flight row, and LiveView's own bindClick early return
// (live_socket.js:857-859) discards a press on an element that already holds a
// ref — no frame either way. So scenario A cannot tell the guard from its
// absence, and a mutation run there would be vacuous.
//
// Scenario B can. A NESTED action inside the in-flight row (`#row-menu`) holds
// no ref of its own, so LiveView's drop branch does not cover it: with the CSS
// edit and NO guard, pressing it while the row is in flight puts a real
// `row-menu` frame on the wire. That cell is the guard's whole reason to exist,
// and it is the cell the self-test asserts in both directions.
//
// Node 22. No dependencies beyond playwright.

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createRequire } from 'node:module';
import { execFileSync } from 'node:child_process';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '..');
const FIXTURE = path.join(HERE, 'fixtures', 'studio-inflight-overlap.html');
const HEEX = 'api/lib/barkpark_web/layouts/root.html.heex';

const CSS_RE = /^[ \t]*\.phx-click-loading,\s*\.phx-submit-loading\s*\{[^}]*\}/m;
const FENCE_BEGIN = 'BP-INFLIGHT-GUARD-BEGIN';
const FENCE_END = 'BP-INFLIGHT-GUARD-END';

const CSS_SLOT = '<style id="bp-injected-css"></style>';
const JS_SLOT = '<script id="bp-injected-guard"></script>';

class ControlError extends Error {}
const die = (msg) => { throw new ControlError(msg); };

// ── playwright ───────────────────────────────────────────────────────────────
// A worktree has no node_modules, but --git-common-dir points at the primary
// clone that does. Same ladder as studio-scrim-threshold-control.mjs.
function resolvePlaywright() {
  const tried = [];
  const candidates = [];
  if (process.env.BP_PLAYWRIGHT_FROM) candidates.push(process.env.BP_PLAYWRIGHT_FROM);
  candidates.push(path.join(REPO, 'js', 'package.json'), path.join(REPO, 'package.json'));
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

// ── the guard, read out of root.html.heex at a git ref ───────────────────────

function readHeex(ref) {
  if (ref === 'WORKTREE') {
    return fs.readFileSync(path.join(REPO, HEEX), 'utf8');
  }
  try {
    return execFileSync('git', ['show', `${ref}:${HEEX}`], { cwd: REPO, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  } catch (e) {
    die(`could not read ${HEEX} at ref "${ref}": ${e.message}`);
  }
}

function extractGuard(ref) {
  const src = readHeex(ref);
  const css = src.match(CSS_RE);
  if (!css) die(`no ".phx-click-loading, .phx-submit-loading { … }" rule in ${HEEX} at ${ref} — ` +
                `the extractor is keyed on that selector pair and must not fall back to a copy.`);
  const cssText = css[0].trim();

  // The fence, when the ref has one. Both markers must appear exactly once
  // OUTSIDE any prose that merely names them: a marker counts only on a line
  // whose trimmed form IS the JS comment `// <MARKER>`.
  const lines = src.split('\n');
  const at = (marker) => {
    const hits = [];
    lines.forEach((l, i) => { if (l.trim() === `// ${marker}`) hits.push(i); });
    return hits;
  };
  const b = at(FENCE_BEGIN);
  const e = at(FENCE_END);
  if (b.length === 0 && e.length === 0) {
    return { ref, css: cssText, pointerEventsNone: /pointer-events\s*:\s*none/.test(cssText), guard: false, js: '' };
  }
  if (b.length !== 1 || e.length !== 1 || e[0] <= b[0]) {
    die(`malformed BP-INFLIGHT-GUARD fence in ${HEEX} at ${ref}: ` +
        `${b.length} begin marker(s), ${e.length} end marker(s)`);
  }
  const js = lines.slice(b[0] + 1, e[0]).join('\n');
  if (!js.trim()) die(`empty BP-INFLIGHT-GUARD fence in ${HEEX} at ${ref}`);
  return { ref, css: cssText, pointerEventsNone: /pointer-events\s*:\s*none/.test(cssText), guard: true, js };
}

// ── the fixture, with a guard injected ───────────────────────────────────────

function writeFixture(destPath, guard, { dropGuard = false } = {}) {
  let html = fs.readFileSync(FIXTURE, 'utf8');
  if (!html.includes(CSS_SLOT)) die(`fixture lost its CSS slot (${CSS_SLOT})`);
  if (!html.includes(JS_SLOT)) die(`fixture lost its guard slot (${JS_SLOT})`);
  html = html.replace(CSS_SLOT, `<style id="bp-injected-css">\n${guard.css}\n</style>`);
  const js = (guard.guard && !dropGuard) ? guard.js : '';
  html = html.replace(JS_SLOT, `<script id="bp-injected-guard">\n${js}\n</script>`);
  fs.writeFileSync(destPath, html, 'utf8');
  return destPath;
}

// ── the run ──────────────────────────────────────────────────────────────────
//
// One page per scenario. Nothing is reset between presses: the in-flight
// window opened by press 1 is still open at press 2, which is the state under
// test.

async function runScenarios(pw, fileUrl) {
  const browser = await pw.chromium.launch();
  try {
    const out = {};

    // A. STACKED ROWS — press #row-over twice at the same point.
    {
      const page = await browser.newPage();
      await page.goto(fileUrl);
      const box = await page.locator('#row-over-label').boundingBox();
      const pt = { x: box.x + box.width / 2, y: box.y + box.height / 2 };
      await page.mouse.click(pt.x, pt.y);
      const first = await page.evaluate(() => window.__frames.slice());
      await page.mouse.click(pt.x, pt.y);
      out.A = {
        frames: await page.evaluate(() => window.__frames.slice()),
        firstPressFrames: first,
        dropped: await page.evaluate(() => window.__dropped.slice()),
        inflightPreserved: await page.evaluate(() =>
          document.getElementById('row-over').classList.contains('phx-click-loading') &&
          document.getElementById('row-over').hasAttribute('data-phx-ref-src')),
        pressAnswer: await page.evaluate(() => document.getElementById('bp-press-answer').textContent),
      };
      await page.close();
    }

    // B. NESTED ACTION — press the row, then its nested #row-menu.
    {
      const page = await browser.newPage();
      await page.goto(fileUrl);
      const rowBox = await page.locator('#row-over-label').boundingBox();
      await page.mouse.click(rowBox.x + rowBox.width / 2, rowBox.y + rowBox.height / 2);
      const menuBox = await page.locator('#row-menu').boundingBox();
      await page.mouse.click(menuBox.x + menuBox.width / 2, menuBox.y + menuBox.height / 2);
      out.B = {
        frames: await page.evaluate(() => window.__frames.slice()),
        dropped: await page.evaluate(() => window.__dropped.slice()),
        inflightPreserved: await page.evaluate(() =>
          document.getElementById('row-over').classList.contains('phx-click-loading') &&
          document.getElementById('row-over').hasAttribute('data-phx-ref-src')),
        pressAnswer: await page.evaluate(() => document.getElementById('bp-press-answer').textContent),
      };
      await page.close();
    }

    // K. KEYBOARD — Enter on a control that is NOT in flight must still fire,
    // and Enter on one that IS in flight must not. Both after the row has been
    // put in flight by a mouse press, so the guard is armed for the second half.
    {
      const page = await browser.newPage();
      await page.goto(fileUrl);
      const rowBox = await page.locator('#row-over-label').boundingBox();
      await page.mouse.click(rowBox.x + rowBox.width / 2, rowBox.y + rowBox.height / 2);
      await page.locator('#row-side').focus();
      await page.keyboard.press('Enter');
      const afterSide = await page.evaluate(() => window.__frames.slice());
      await page.locator('#row-menu').focus();
      await page.keyboard.press('Enter');
      out.K = {
        notInFlightFired: afterSide.some((f) => f.type === 'click' && f.event === 'side-action'),
        frames: await page.evaluate(() => window.__frames.slice()),
      };
      await page.close();
    }

    return out;
  } finally {
    await browser.close();
  }
}

const clicks = (frames) => frames.filter((f) => f.type === 'click');
const names = (frames) => clicks(frames).map((f) => `${f.event}@${f.id}`);

async function measure(pw, guard, { dropGuard = false } = {}) {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'bp-inflight-'));
  const dest = path.join(tmp, 'fixture.html');
  writeFixture(dest, guard, { dropGuard });
  try {
    const scenarios = await runScenarios(pw, pathToFileURL(dest).href);
    return {
      ref: guard.ref,
      guardPresent: guard.guard && !dropGuard,
      guardDeleted: dropGuard,
      pointerEventsNone: guard.pointerEventsNone,
      css: guard.css,
      scenarios,
    };
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}

// ── report ───────────────────────────────────────────────────────────────────

function print(run) {
  const tag = run.guardDeleted ? `${run.ref} (guard DELETED)` : run.ref;
  console.log(`\n── ${tag} ──`);
  console.log(`  css                : ${run.css}`);
  console.log(`  pointer-events:none: ${run.pointerEventsNone}`);
  console.log(`  guard injected     : ${run.guardPresent}`);
  for (const k of ['A', 'B']) {
    const s = run.scenarios[k];
    console.log(`  scenario ${k}: frames=[${names(s.frames).join(', ')}] dropped=[${s.dropped.join(', ')}]`);
    console.log(`              in-flight state preserved on #row-over: ${s.inflightPreserved}`);
    console.log(`              press answer: ${JSON.stringify(s.pressAnswer)}`);
  }
  console.log(`  keyboard  : not-in-flight #row-side fired: ${run.scenarios.K.notInFlightFired}`);
  console.log(`              frames=[${names(run.scenarios.K.frames).join(', ')}]`);
}

// The second click's frame, if any — the whole question.
function secondClick(scenario) {
  const c = clicks(scenario.frames);
  return c.length > 1 ? c[1] : null;
}

function selfTest(baseline, head, mutant) {
  const fails = [];
  const ok = (cond, msg) => { if (!cond) fails.push(msg); };

  // ── criterion 0: the repro, at the shipped ref ────────────────────────────
  ok(baseline.pointerEventsNone,
     `baseline ref ${baseline.ref} does not carry pointer-events:none — nothing to reproduce`);
  const a0 = secondClick(baseline.scenarios.A);
  ok(a0 && a0.event === 'delete-dataset' && a0.id === 'row-under',
     `baseline scenario A: expected the second press to fall through to ` +
     `{type:"click",event:"delete-dataset",id:"row-under"}, got ${JSON.stringify(a0)}`);
  const b0 = secondClick(baseline.scenarios.B);
  ok(b0 && b0.event === 'delete-dataset' && b0.id === 'row-under',
     `baseline scenario B: expected the nested action press to fall through to ` +
     `{type:"click",event:"delete-dataset",id:"row-under"}, got ${JSON.stringify(b0)}`);

  // ── criterion 1: the swap ─────────────────────────────────────────────────
  ok(!head.pointerEventsNone, `head ref ${head.ref} still carries pointer-events:none`);
  ok(head.guardPresent, `head ref ${head.ref} has no BP-INFLIGHT-GUARD fence`);
  ok(secondClick(head.scenarios.A) === null,
     `head scenario A: a second frame was sent: ${JSON.stringify(secondClick(head.scenarios.A))}`);
  ok(secondClick(head.scenarios.B) === null,
     `head scenario B: a second frame was sent: ${JSON.stringify(secondClick(head.scenarios.B))}`);
  ok(head.scenarios.A.inflightPreserved && head.scenarios.B.inflightPreserved,
     'head: the in-flight state on #row-over was not preserved across the swallowed press');
  ok(head.scenarios.A.pressAnswer.includes('not sent'),
     `head scenario A: the press answer stayed silent: ${JSON.stringify(head.scenarios.A.pressAnswer)}`);
  ok(head.scenarios.K.notInFlightFired,
     'head: keyboard activation on the NOT-in-flight #row-side was swallowed — regression');

  // ── the mutation, the other direction ─────────────────────────────────────
  const bm = secondClick(mutant.scenarios.B);
  ok(bm && bm.event === 'row-menu',
     `mutation (head CSS, guard deleted) scenario B: expected the nested action to fire ` +
     `{type:"click",event:"row-menu"}, got ${JSON.stringify(bm)} — the guard is not load-bearing here ` +
     `and this control proves nothing`);
  ok(mutant.scenarios.K.notInFlightFired,
     'mutation: the keyboard control is vacuous — #row-side did not fire even without the guard');

  return fails;
}

function usage() {
  console.log(`studio-inflight-guard-control.mjs — the in-flight press control (spd-w19)

  --ref <git ref>   read the guard from that ref instead of the default pair
                    ("WORKTREE" = the working tree). Repeatable.
  --self-test       assert the repro and the fix, both directions; exit 1 on failure
  --json            machine-readable
  --help            this
`);
}

async function main() {
  const argv = process.argv.slice(2);
  if (argv.includes('--help')) { usage(); return 0; }
  const json = argv.includes('--json');
  const doSelfTest = argv.includes('--self-test');

  const refs = [];
  for (let i = 0; i < argv.length; i++) if (argv[i] === '--ref') refs.push(argv[++i]);

  const { pw, resolvedFrom, version } = resolvePlaywright();
  if (!json) console.log(`playwright ${version} (resolved from ${resolvedFrom})`);

  const headSha = (() => {
    try { return execFileSync('git', ['rev-parse', 'HEAD'], { cwd: REPO, encoding: 'utf8' }).trim(); }
    catch { return 'unknown'; }
  })();
  const baseSha = (() => {
    try { return execFileSync('git', ['rev-parse', 'origin/main'], { cwd: REPO, encoding: 'utf8' }).trim(); }
    catch { return 'unknown'; }
  })();

  const runs = [];
  if (refs.length) {
    for (const r of refs) runs.push(await measure(pw, extractGuard(r)));
  } else {
    const baselineGuard = extractGuard('origin/main');
    const headGuard = extractGuard('WORKTREE');
    runs.push(await measure(pw, baselineGuard));
    runs.push(await measure(pw, headGuard));
    runs.push(await measure(pw, headGuard, { dropGuard: true }));
  }

  let fails = [];
  if (doSelfTest) {
    if (runs.length !== 3) die('--self-test runs the default triple; do not combine it with --ref');
    fails = selfTest(runs[0], runs[1], runs[2]);
  }

  const payload = {
    fixture: path.relative(REPO, FIXTURE),
    heex: HEEX,
    playwright: version,
    generated_at: new Date().toISOString(),
    head_sha: headSha,
    origin_main_sha: baseSha,
    runs,
    self_test: doSelfTest ? { failures: fails, ok: fails.length === 0 } : null,
  };

  if (json) {
    console.log(JSON.stringify(payload, null, 2));
  } else {
    for (const r of runs) print(r);
    if (doSelfTest) {
      console.log('');
      if (fails.length === 0) console.log(`SELF-TEST OK — ${runs.length} runs, 0 failures`);
      else fails.forEach((f) => console.log(`SELF-TEST FAIL: ${f}`));
    }
  }
  return fails.length === 0 ? 0 : 1;
}

main()
  .then((code) => process.exit(code))
  .catch((e) => {
    console.error(e instanceof ControlError ? `error: ${e.message}` : e);
    process.exit(2);
  });
