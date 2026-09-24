#!/usr/bin/env node
//
// studio-lockonly-ref-control.mjs — THE LOCK-ONLY REF CONTROL (task-b1254cbd3115c3e2).
//
// A ref that carries `data-phx-ref-src` and NO `phx-click-loading` class, made
// by the real LiveView client on a real path, and what the in-flight guard does
// about it.
//
//   node scripts/studio-lockonly-ref-control.mjs               # both refs
//   node scripts/studio-lockonly-ref-control.mjs --self-test   # + assertions, exit 1 on failure
//   node scripts/studio-lockonly-ref-control.mjs --json
//   node scripts/studio-lockonly-ref-control.mjs --ref <git ref>
//
// ── THE MECHANISM, IN THE VENDOR'S OWN BYTES ─────────────────────────────────
// `putRef` (phoenix_live_view.js) stamps the ref BEFORE it decides about the
// class:
//
//     for(let{el:a,lock:l,loading:h}of e){
//       if(!l&&!h)throw new Error("putRef requires lock or loading");
//       if(a.setAttribute(N,this.refSrc()),      // N = "data-phx-ref-src"
//          h&&a.setAttribute(ve,r),              // ve = "data-phx-ref-loading"
//          l&&a.setAttribute(C,r),               // C  = "data-phx-ref-lock"
//          !h||…)continue;                       // ← not loading: LEAVE NOW
//       …
//       a.classList.add(`phx-${i}-loading`);     // ← only reached when loading
//
// and `pushLinkPatch` is the one caller that passes a loading flag that can be
// false:
//
//     pushLinkPatch(e,t,i,n){…,o=e.isTrusted&&e.type!=="popstate",
//       a=i?()=>this.putRef([{el:i,loading:o,lock:!0}],null,"click"):null,…
//
// So `data-phx-ref-src` is UNCONDITIONAL and `phx-click-loading` is not. A
// guard keyed on the class is keyed on a symptom; a guard keyed on the ref is
// keyed on the condition.
//
// ── WHAT IS EXTRACTED AND WHAT IS COPIED ─────────────────────────────────────
// Nothing is copied. At run time this script reads, from the ref it was pointed
// at:
//   · the `.phx-click-loading, .phx-submit-loading { … }` rule from root.html.heex
//   · the JS fenced BP-INFLIGHT-GUARD-BEGIN/END from root.html.heex
// and, from the working tree (they are vendor assets, not branch state):
//   · api/priv/static/assets/phoenix.js
//   · api/priv/static/assets/phoenix_live_view.js
// Each is injected into a slot in scripts/fixtures/studio-lockonly-ref.html.
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
const FIXTURE = path.join(HERE, 'fixtures', 'studio-lockonly-ref.html');
const HEEX = 'api/lib/barkpark_web/layouts/root.html.heex';
const PHOENIX_JS = 'api/priv/static/assets/phoenix.js';
const LV_JS = 'api/priv/static/assets/phoenix_live_view.js';

const CSS_RE = /^[ \t]*\.phx-click-loading,\s*\.phx-submit-loading\s*\{[^}]*\}/m;
const FENCE_BEGIN = 'BP-INFLIGHT-GUARD-BEGIN';
const FENCE_END = 'BP-INFLIGHT-GUARD-END';

const SLOTS = {
  css: '<style id="bp-injected-css"></style>',
  guard: '<script id="bp-injected-guard"></script>',
  phoenix: '<script id="bp-phoenix"></script>',
  lv: '<script id="bp-lv"></script>',
};

class ControlError extends Error {}
const die = (msg) => { throw new ControlError(msg); };

// ── playwright ───────────────────────────────────────────────────────────────
// A worktree has no node_modules; --git-common-dir points at the primary clone
// that does. Ladder copied in shape (not in text) from
// scripts/studio-inflight-guard-control.mjs.
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
  } catch { /* not a checkout — the rest still apply */ }
  for (const from of candidates) {
    tried.push(from);
    try {
      const require_ = createRequire(from);
      const pw = require_('playwright');
      let version = 'unknown';
      try { version = require_('playwright/package.json').version; } catch { /* keep */ }
      return { pw, resolvedFrom: from, version };
    } catch { /* next */ }
  }
  die(`playwright could not be resolved. Tried, in order:\n  ${tried.join('\n  ')}\n` +
      `Set BP_PLAYWRIGHT_FROM=<path to a package.json that can require("playwright")>.`);
}

// ── the guard, read out of root.html.heex at a git ref ───────────────────────

function readAt(ref, relPath) {
  if (ref === 'WORKTREE') return fs.readFileSync(path.join(REPO, relPath), 'utf8');
  try {
    return execFileSync('git', ['show', `${ref}:${relPath}`],
      { cwd: REPO, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  } catch (e) {
    die(`could not read ${relPath} at ref "${ref}": ${e.message}`);
  }
}

function extractGuard(ref) {
  const src = readAt(ref, HEEX);
  const css = src.match(CSS_RE);
  if (!css) die(`no ".phx-click-loading, .phx-submit-loading { … }" rule in ${HEEX} at ${ref}`);
  const lines = src.split('\n');
  const at = (marker) => {
    const hits = [];
    lines.forEach((l, i) => { if (l.trim() === `// ${marker}`) hits.push(i); });
    return hits;
  };
  const b = at(FENCE_BEGIN);
  const e = at(FENCE_END);
  if (b.length === 0 && e.length === 0) return { ref, css: css[0].trim(), guard: false, js: '' };
  if (b.length !== 1 || e.length !== 1 || e[0] <= b[0]) {
    die(`malformed BP-INFLIGHT-GUARD fence in ${HEEX} at ${ref}: ${b.length} begin, ${e.length} end`);
  }
  const js = lines.slice(b[0] + 1, e[0]).join('\n');
  if (!js.trim()) die(`empty BP-INFLIGHT-GUARD fence in ${HEEX} at ${ref}`);
  return { ref, css: css[0].trim(), guard: true, js };
}

// The one mutation that matters for the NEW key: a guard keyed on a bare
// [data-phx-ref-src]. #studio-panes holds a container ref from its own hook's
// mount push, so this arm shows what "unconditional but unscoped" costs.
function naiveKeyMutation(js) {
  const from = 'var activated = t.closest("[phx-click], [data-phx-link]");';
  const to = 'var activated = t.closest("[data-phx-ref-src]");';
  if (!js.includes(from)) return null;
  return js.replace(from, to);
}

// The other direction: the guard with its second arm removed entirely, i.e.
// exactly origin/main's key expressed in head's file. It exists so the head run
// can be told from a head run that merely inherited a green.
function classOnlyKeyMutation(js) {
  const from = `      if (!blocked) {
        var activated = t.closest("[phx-click], [data-phx-link]");
        if (activated && activated.hasAttribute("data-phx-ref-src")) blocked = activated;
      }
`;
  if (!js.includes(from)) return null;
  return js.replace(from, '');
}

// ── the fixture ──────────────────────────────────────────────────────────────

function writeFixture(destPath, guard, { dropGuard = false, guardJsOverride = null } = {}) {
  let html = fs.readFileSync(FIXTURE, 'utf8');
  for (const [name, slot] of Object.entries(SLOTS)) {
    if (!html.includes(slot)) die(`fixture lost its ${name} slot (${slot})`);
  }
  const js = guardJsOverride !== null ? guardJsOverride : ((guard.guard && !dropGuard) ? guard.js : '');
  // THE VENDOR BUNDLES GO BESIDE THE PAGE, NOT INSIDE IT. phoenix_live_view.js
  // contains one literal `<!--`, which puts the HTML parser into the
  // script-data-escaped state: inlined, every script AFTER it is swallowed and
  // the page dies with "LiveView is not defined". Measured, not guessed — that
  // was this control's first run.
  const dir = path.dirname(destPath);
  fs.writeFileSync(path.join(dir, 'phoenix.js'), readAt('WORKTREE', PHOENIX_JS), 'utf8');
  fs.writeFileSync(path.join(dir, 'phoenix_live_view.js'), readAt('WORKTREE', LV_JS), 'utf8');
  html = html
    .replace(SLOTS.css, `<style id="bp-injected-css">\n${guard.css}\n</style>`)
    .replace(SLOTS.phoenix, `<script id="bp-phoenix" src="./phoenix.js"></script>`)
    .replace(SLOTS.lv, `<script id="bp-lv" src="./phoenix_live_view.js"></script>`)
    .replace(SLOTS.guard, `<script id="bp-injected-guard">\n${js}\n</script>`);
  fs.writeFileSync(destPath, html, 'utf8');
  return destPath;
}

// ── the probe ────────────────────────────────────────────────────────────────

// The probe. A REAL function, passed to page.evaluate with its argument — a
// string-shaped "function" is evaluated as an EXPRESSION and never receives the
// argument, which reads as a missing element and so as a missing attribute.
// That is a probe that sees nothing dressed as a finding; this control's second
// run printed ABSENT for every element on the page that way.
function refState(id) {
  const el = document.getElementById(id);
  if (!el) return null;
  return {
    id,
    refSrc: el.getAttribute('data-phx-ref-src'),
    refLock: el.getAttribute('data-phx-ref-lock'),
    refLoading: el.getAttribute('data-phx-ref-loading'),
    hasRefSrc: el.hasAttribute('data-phx-ref-src'),
    clickLoading: el.classList.contains('phx-click-loading'),
    classList: Array.from(el.classList),
  };
}

async function openPage(browser, fileUrl) {
  const page = await browser.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(String(e)));
  await page.goto(fileUrl);
  // PRECONDITION, ASSERTED NOT RACED: the LiveView must actually have joined
  // and rendered the sidebar before any press is driven.
  await page.waitForFunction('window.__joined && window.__joined()', null, { timeout: 15000 });
  page.__bpErrors = errors;
  return page;
}

async function runScenarios(pw, fileUrl) {
  const browser = await pw.chromium.launch();
  try {
    const out = {};

    // ── U. UNTRUSTED press on the shipped sidebar shape (a bare
    //    `<.link patch={…}>`, `session_link_path` in chat_live.ex).
    //    `el.click()` is exactly what
    //    THIS REPO's own pre-join replay does (BP-PREJOIN-QUEUE, `el.click()`),
    //    so the untrusted press is not a contrivance — it is shipped code.
    //    Then a SECOND, trusted press on the same link while the first is in
    //    flight.
    {
      const page = await openPage(browser, fileUrl);
      await page.evaluate(() => { document.getElementById('sess-a').click(); });
      await page.waitForTimeout(120);
      const ref1 = await page.evaluate(refState, 'sess-a');
      const afterFirst = await page.evaluate(() => window.__events.slice());
      await page.click('#sess-a');
      await page.waitForTimeout(120);
      out.U = {
        press1: ref1,
        container: await page.evaluate(refState, 'studio-panes'),
        framesAfterPress1: afterFirst,
        framesAfterPress2: await page.evaluate(() => window.__events.slice()),
        pressAnswer: await page.evaluate(() => document.getElementById('bp-press-answer').textContent),
        errors: page.__bpErrors.slice(),
      };
      await page.close();
    }

    // ── B. A PRESS AIMED SOMEWHERE ELSE. #sess-a is in flight (lock-only);
    //    the user presses #sess-b, a DIFFERENT link. Navigating away from a
    //    pending patch is legitimate and must keep working whatever the guard
    //    is keyed on — this is the arm that would catch an over-broad key.
    {
      const page = await openPage(browser, fileUrl);
      await page.evaluate(() => { document.getElementById('sess-a').click(); });
      await page.waitForTimeout(120);
      const afterFirst = await page.evaluate(() => window.__events.slice());
      await page.click('#sess-b');
      await page.waitForTimeout(120);
      out.B = {
        framesAfterPress1: afterFirst,
        framesAfterPress2: await page.evaluate(() => window.__events.slice()),
        pressAnswer: await page.evaluate(() => document.getElementById('bp-press-answer').textContent),
        errors: page.__bpErrors.slice(),
      };
      await page.close();
    }

    // ── T. THE CONTROL: the SAME element, the SAME path, a TRUSTED press.
    //    If the class is missing here too, the probe saw nothing and U proves
    //    nothing.
    {
      const page = await openPage(browser, fileUrl);
      await page.click('#sess-a');
      await page.waitForTimeout(120);
      const tRef1 = await page.evaluate(refState, 'sess-a');
      const tAfterFirst = await page.evaluate(() => window.__events.slice());
      await page.click('#sess-a');
      await page.waitForTimeout(120);
      out.T = {
        press1: tRef1,
        framesAfterPress1: tAfterFirst,
        framesAfterPress2: await page.evaluate(() => window.__events.slice()),
        pressAnswer: await page.evaluate(() => document.getElementById('bp-press-answer').textContent),
        errors: page.__bpErrors.slice(),
      };
      await page.close();
    }

    // ── J. JS.patch on a plain phx-click control — the other pushLinkPatch
    //    caller (exec_patch). Untrusted press 1, then a SECOND press on the
    //    same control while the first is still in flight. This is where
    //    bindClick's early return owns the drop.
    {
      const page = await openPage(browser, fileUrl);
      await page.evaluate(() => { document.getElementById('js-patch').click(); });
      await page.waitForTimeout(120);
      const afterFirst = await page.evaluate(() => window.__events.slice());
      const ref1 = await page.evaluate(refState, 'js-patch');
      // press 2 — a REAL, TRUSTED press by the user on the in-flight control
      await page.click('#js-patch');
      await page.waitForTimeout(120);
      out.J = {
        press1: ref1,
        framesAfterPress1: afterFirst,
        framesAfterPress2: await page.evaluate(() => window.__events.slice()),
        pressAnswer: await page.evaluate(() => document.getElementById('bp-press-answer').textContent),
        errors: page.__bpErrors.slice(),
      };
      await page.close();
    }

    // ── J-trusted. The SAME sequence with a TRUSTED first press, so the
    //    difference between J and this is the trust flag and nothing else.
    {
      const page = await openPage(browser, fileUrl);
      await page.click('#js-patch');
      await page.waitForTimeout(120);
      const ref1 = await page.evaluate(refState, 'js-patch');
      const afterFirst = await page.evaluate(() => window.__events.slice());
      await page.click('#js-patch');
      await page.waitForTimeout(120);
      out.JT = {
        press1: ref1,
        framesAfterPress1: afterFirst,
        framesAfterPress2: await page.evaluate(() => window.__events.slice()),
        pressAnswer: await page.evaluate(() => document.getElementById('bp-press-answer').textContent),
        errors: page.__bpErrors.slice(),
      };
      await page.close();
    }

    // ── N. NO-REGRESSION: a press on #plain, which is not in flight, while
    //    #studio-panes carries the container ref from its hook's mount push.
    {
      const page = await openPage(browser, fileUrl);
      await page.click('#plain');
      await page.waitForTimeout(120);
      out.N = {
        container: await page.evaluate(refState, 'studio-panes'),
        frames: await page.evaluate(() => window.__events.slice()),
        pressAnswer: await page.evaluate(() => document.getElementById('bp-press-answer').textContent),
        errors: page.__bpErrors.slice(),
      };
      await page.close();
    }

    return out;
  } finally {
    await browser.close();
  }
}

const clickEvents = (frames) => frames.filter((f) => f.event === 'event' && f.payload && f.payload.type === 'click');
const patchFrames = (frames) => frames.filter((f) => f.event === 'live_patch');
const summarise = (frames) => frames.map((f) =>
  f.event === 'live_patch' ? `live_patch(${f.payload && f.payload.url})`
    : `${f.event}:${f.payload && f.payload.type}/${f.payload && f.payload.event}`);

async function measure(pw, guard, opts = {}) {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'bp-lockonly-'));
  const dest = path.join(tmp, 'fixture.html');
  writeFixture(dest, guard, opts);
  try {
    return {
      ref: guard.ref,
      label: opts.label || guard.ref,
      guardPresent: !!(guard.guard && !opts.dropGuard) || opts.guardJsOverride != null,
      scenarios: await runScenarios(pw, pathToFileURL(dest).href),
    };
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}

// ── report ───────────────────────────────────────────────────────────────────

function print(run) {
  console.log(`\n── ${run.label} ──`);
  console.log(`  guard injected: ${run.guardPresent}`);
  const s = run.scenarios;
  const ref = (r) => r ? `refSrc=${JSON.stringify(r.refSrc)} lock=${JSON.stringify(r.refLock)} ` +
    `loading=${JSON.stringify(r.refLoading)} phx-click-loading=${r.clickLoading}` : 'ELEMENT ABSENT';
  const fr = (f) => `[${summarise(f).join(', ')}]`;
  console.log(`  U  <.link patch> #sess-a, UNTRUSTED press 1 : ${ref(s.U.press1)}`);
  console.log(`     container #studio-panes                  : ${ref(s.U.container)}`);
  console.log(`     after press1=${fr(s.U.framesAfterPress1)}  after press2=${fr(s.U.framesAfterPress2)}`);
  console.log(`     press answer=${JSON.stringify(s.U.pressAnswer)}`);
  console.log(`  T  CONTROL, same element, TRUSTED press 1   : ${ref(s.T.press1)}`);
  console.log(`     after press1=${fr(s.T.framesAfterPress1)}  after press2=${fr(s.T.framesAfterPress2)}`);
  console.log(`     press answer=${JSON.stringify(s.T.pressAnswer)}`);
  console.log(`  B  #sess-b pressed while #sess-a in flight   : after press2=${fr(s.B.framesAfterPress2)}`);
  console.log(`     press answer=${JSON.stringify(s.B.pressAnswer)}`);
  console.log(`  J  JS.patch #js-patch, UNTRUSTED press 1    : ${ref(s.J.press1)}`);
  console.log(`     after press1=${fr(s.J.framesAfterPress1)}  after press2=${fr(s.J.framesAfterPress2)}`);
  console.log(`     press answer=${JSON.stringify(s.J.pressAnswer)}`);
  console.log(`  JT CONTROL, same element, TRUSTED press 1   : ${ref(s.JT.press1)}`);
  console.log(`     after press2=${fr(s.JT.framesAfterPress2)}  press answer=${JSON.stringify(s.JT.pressAnswer)}`);
  console.log(`  N  not-in-flight #plain                     : ${fr(s.N.frames)}`);
  console.log(`     container #studio-panes=${ref(s.N.container)}  press answer=${JSON.stringify(s.N.pressAnswer)}`);
  const errs = Object.values(s).flatMap((x) => x.errors || []);
  console.log(`  page errors: ${errs.length === 0 ? 'none' : JSON.stringify(errs)}`);
}

function selfTest(base, head, naive, classOnly) {
  const fails = [];
  const ok = (cond, msg) => { if (!cond) fails.push(msg); };
  const patchCount = (f) => patchFrames(f).length;

  // ── PRECONDITIONS, ASSERTED NOT RACED ────────────────────────────────────
  // NOT the bare-key mutation arm: that arm blocks even the FIRST press
  // (#studio-panes already holds the container ref at join), which is precisely
  // what it is there to show. Asserting "one live_patch went out" against it
  // would red the control for succeeding.
  for (const run of [base, head, classOnly].filter(Boolean)) {
    const errs = Object.values(run.scenarios).flatMap((x) => x.errors || []);
    ok(errs.length === 0, `${run.label}: the page threw — every reading below is suspect: ${JSON.stringify(errs)}`);
    ok(run.scenarios.U.press1 && run.scenarios.U.press1.id === 'sess-a',
       `${run.label}: #sess-a was never rendered, so nothing was pressed`);
    ok(patchCount(run.scenarios.U.framesAfterPress1) === 1,
       `${run.label}: the first press on #sess-a did not put exactly one live_patch on the wire ` +
       `(${JSON.stringify(summarise(run.scenarios.U.framesAfterPress1))}) — the in-flight window ` +
       `this whole run is about was never opened`);
  }
  if (naive) {
    const nerrs = Object.values(naive.scenarios).flatMap((x) => x.errors || []);
    ok(nerrs.length === 0, `${naive.label}: the page threw: ${JSON.stringify(nerrs)}`);
  }
  ok(base.guardPresent, 'the baseline ref carries no BP-INFLIGHT-GUARD fence — there is nothing to be blind');
  ok(head.guardPresent, 'the head ref carries no BP-INFLIGHT-GUARD fence');

  // ── c0: the lock-only ref, from a real path, with its trusted control ─────
  const u = base.scenarios.U.press1;
  const t = base.scenarios.T.press1;
  ok(u && u.hasRefSrc,
     `c0: the untrusted press left NO data-phx-ref-src on #sess-a: ${JSON.stringify(u)}`);
  ok(u && u.refLock !== null,
     `c0: the untrusted press set no data-phx-ref-lock, so this is not a LOCK-only ref: ${JSON.stringify(u)}`);
  ok(u && u.clickLoading === false && u.refLoading === null,
     `c0: the untrusted press DID mark the element loading — the lock-only ref does not exist: ${JSON.stringify(u)}`);
  ok(t && t.hasRefSrc && t.clickLoading === true && t.refLoading !== null,
     `c0 CONTROL: a TRUSTED press on the SAME element by the SAME path did not produce ref AND ` +
     `class together, so the missing class in U measures a blind probe, not the trust flag: ${JSON.stringify(t)}`);
  const j = base.scenarios.J.press1;
  ok(j && j.hasRefSrc && j.clickLoading === false,
     `c0: the JS.patch path did not produce a lock-only ref on #js-patch: ${JSON.stringify(j)}`);
  ok(base.scenarios.JT.press1 && base.scenarios.JT.press1.clickLoading === true,
     `c0 CONTROL: a trusted press on #js-patch did not tint it: ${JSON.stringify(base.scenarios.JT.press1)}`);

  // ── c1 half one: the press is DROPPED ────────────────────────────────────
  ok(base.scenarios.J.framesAfterPress2.length === base.scenarios.J.framesAfterPress1.length,
     `c1 half one: the second press on the lock-only #js-patch reached the wire, so bindClick did ` +
     `not drop it: ${JSON.stringify(summarise(base.scenarios.J.framesAfterPress2))}`);
  ok(base.scenarios.U.framesAfterPress2.length === base.scenarios.U.framesAfterPress1.length,
     `c1 half one: the second press on the lock-only #sess-a reached the wire: ` +
     `${JSON.stringify(summarise(base.scenarios.U.framesAfterPress2))}`);

  // ── c1 half two: and the shipped guard cannot see it ─────────────────────
  ok(base.scenarios.J.pressAnswer === '',
     `c1 half two: the class-keyed guard DID answer the lock-only press on #js-patch, so it is ` +
     `not blind: ${JSON.stringify(base.scenarios.J.pressAnswer)}`);
  ok(base.scenarios.U.pressAnswer === '',
     `c1 half two: the class-keyed guard DID answer the lock-only press on #sess-a: ` +
     `${JSON.stringify(base.scenarios.U.pressAnswer)}`);
  ok(base.scenarios.JT.pressAnswer.includes('not sent'),
     `c1 CONTROL: the class-keyed guard stayed silent even for the LOADING press, so its silence ` +
     `above measures a broken instrument rather than the missing class: ` +
     `${JSON.stringify(base.scenarios.JT.pressAnswer)}`);
  ok(base.scenarios.T.pressAnswer.includes('not sent'),
     `c1 CONTROL: the class-keyed guard stayed silent for the loading #sess-a press too: ` +
     `${JSON.stringify(base.scenarios.T.pressAnswer)}`);

  // ── c2: the new key sees it, in both directions, and costs nothing ───────
  ok(head.scenarios.J.pressAnswer.includes('not sent'),
     `c2: the head guard is still blind to the lock-only press on #js-patch: ` +
     `${JSON.stringify(head.scenarios.J.pressAnswer)}`);
  ok(head.scenarios.U.pressAnswer.includes('not sent'),
     `c2: the head guard is still blind to the lock-only press on #sess-a: ` +
     `${JSON.stringify(head.scenarios.U.pressAnswer)}`);
  ok(head.scenarios.JT.pressAnswer.includes('not sent') && head.scenarios.T.pressAnswer.includes('not sent'),
     `c2: the head guard lost the loading case it already had`);
  ok(clickEvents(head.scenarios.N.frames).length === 1 && head.scenarios.N.pressAnswer === '',
     `c2 NO-REGRESSION: a press on the not-in-flight #plain was blocked or answered under the head ` +
     `guard: ${JSON.stringify(summarise(head.scenarios.N.frames))} / ` +
     `${JSON.stringify(head.scenarios.N.pressAnswer)}`);
  ok(patchCount(head.scenarios.B.framesAfterPress2) === 2 && head.scenarios.B.pressAnswer === '',
     `c2 NO-REGRESSION: pressing #sess-b while #sess-a was in flight did not navigate under the ` +
     `head guard: ${JSON.stringify(summarise(head.scenarios.B.framesAfterPress2))} / ` +
     `${JSON.stringify(head.scenarios.B.pressAnswer)}`);

  // ── the two mutations ────────────────────────────────────────────────────
  if (classOnly) {
    ok(classOnly.scenarios.J.pressAnswer === '',
       `mutation (second arm deleted): the guard still answered the lock-only press, so the arm ` +
       `this PR adds is not what makes head green: ${JSON.stringify(classOnly.scenarios.J.pressAnswer)}`);
  }
  if (naive) {
    ok(naive.scenarios.N.container && naive.scenarios.N.container.hasRefSrc,
       'mutation (bare key): #studio-panes never took a container ref, so this arm measures nothing');
    ok(clickEvents(naive.scenarios.N.frames).length === 0,
       `mutation (bare key): a guard keyed on a BARE [data-phx-ref-src] was expected to ` +
       `blanket-block the not-in-flight #plain through the container ref on #studio-panes, and did ` +
       `not: ${JSON.stringify(summarise(naive.scenarios.N.frames))} — the scoping in the head guard ` +
       `is then unjustified and this control proves nothing about it`);
  }

  return fails;
}

function usage() {
  console.log(`studio-lockonly-ref-control.mjs — the lock-only ref control (task-b1254cbd3115c3e2)

  --ref <git ref>   read the guard from that ref ("WORKTREE" = the working tree). Repeatable.
  --self-test       assert the finding and the fix, both directions; exit 1 on failure
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

  const sha = (r) => {
    try { return execFileSync('git', ['rev-parse', r], { cwd: REPO, encoding: 'utf8' }).trim(); }
    catch { return 'unknown'; }
  };

  const runs = [];
  if (refs.length) {
    for (const r of refs) runs.push(await measure(pw, extractGuard(r)));
  } else {
    const baseGuard = extractGuard('origin/main');
    const headGuard = extractGuard('WORKTREE');
    runs.push(await measure(pw, baseGuard, { label: `origin/main (${sha('origin/main').slice(0, 9)})` }));
    runs.push(await measure(pw, headGuard, { label: 'WORKTREE' }));
    const naiveJs = naiveKeyMutation(headGuard.js);
    runs.push(naiveJs ? await measure(pw, headGuard, {
      label: 'WORKTREE (mutation: bare [data-phx-ref-src] key)',
      guardJsOverride: naiveJs,
    }) : null);
    const classOnlyJs = classOnlyKeyMutation(headGuard.js);
    runs.push(classOnlyJs ? await measure(pw, headGuard, {
      label: 'WORKTREE (mutation: second arm deleted — origin/main\'s key)',
      guardJsOverride: classOnlyJs,
    }) : null);
  }

  let fails = [];
  if (doSelfTest) {
    if (runs.length < 2) die('--self-test runs the default pair/triple; do not combine it with --ref');
    fails = selfTest(runs[0], runs[1], runs[2] || null, runs[3] || null);
  }

  const payload = {
    fixture: path.relative(REPO, FIXTURE),
    heex: HEEX,
    playwright: version,
    generated_at: new Date().toISOString(),
    head_sha: sha('HEAD'),
    origin_main_sha: sha('origin/main'),
    runs: runs.filter(Boolean),
    self_test: doSelfTest ? { failures: fails, ok: fails.length === 0 } : null,
  };

  if (json) {
    console.log(JSON.stringify(payload, null, 2));
  } else {
    for (const r of runs.filter(Boolean)) print(r);
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
