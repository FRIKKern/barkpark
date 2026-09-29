#!/usr/bin/env node
//
// studio-prejoin-queue-control.mjs — THE PRE-JOIN PRESS CONTROL.
//
// task-c2dd40c6f433a787. It answers three questions, in this order, against a
// committed static fixture and a real browser:
//
//   0. WITH THE SHIPPED-ON-MAIN CODE, WHERE DOES A PRE-JOIN PRESS GO?
//      (`--ref origin/main`, the repro: NOWHERE — zero frames, ever.)
//   1. WITH THIS BRANCH'S QUEUE, WHERE DOES IT GO?
//      (`--ref WORKTREE`: one frame, put on the wire AFTER the join.)
//   2. IS IT THE QUEUE THAT DID IT? (the REPLAY-DELETED mutation: the fence is
//      present, the replay is gone, and the frame goes back to zero.)
//
//   node scripts/studio-prejoin-queue-control.mjs               # both refs
//   node scripts/studio-prejoin-queue-control.mjs --self-test   # + assertions, exit 1 on failure
//   node scripts/studio-prejoin-queue-control.mjs --json
//   node scripts/studio-prejoin-queue-control.mjs --ref <git ref>
//
// ── WHAT MAKES THIS A PROPERTY OF THE CODE ───────────────────────────────────
// `data-phx-ref-src` is never set by hand, here or in the fixture. The fixture
// loads the repo's own `phoenix.js` and `phoenix_live_view.js` and constructs a
// real LiveSocket; when a ref appears it was stamped by LiveView's own
// `putRef`. The pre-join drop is not that early return at all — `pushWithReply`
// rejects with "no connection" BEFORE the ref generator runs — which is why
// this control counts FRAMES ON THE WIRE and not attributes.
//
// The queue under test is EXTRACTED from root.html.heex at whichever ref the
// run names, by the fence BP-PREJOIN-QUEUE-BEGIN/END. A hand-copied copy would
// drift and then prove the fixture rather than the shipped code. An absent
// fence is a legitimate reading (no queue shipped at that ref) and is reported
// as `queue: false`, never silently treated as "queue present".
//
// Node 22. No dependencies beyond playwright.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createRequire } from 'node:module';
import { execFileSync } from 'node:child_process';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '..');
const FIXTURE = path.join(HERE, 'fixtures', 'studio-prejoin-join-window.html');
const HEEX = 'api/lib/barkpark_web/layouts/root.html.heex';

const FENCE_BEGIN = 'BP-PREJOIN-QUEUE-BEGIN';
const FENCE_END = 'BP-PREJOIN-QUEUE-END';
const JS_SLOT = '<script id="bp-injected-queue"></script>';

// The join reply is held this long so the press below lands INSIDE the window
// by construction and not by luck; the run still ASSERTS the un-joined state
// at press time rather than trusting these numbers.
const JOIN_DELAY_MS = 1500;
const PRESS_AT_MS = 300;
const REPLY_DELAY_MS = 400;

class ControlError extends Error {}
const die = (msg) => { throw new ControlError(msg); };

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
      return { pw: require_('playwright'), resolvedFrom: from };
    } catch { /* next */ }
  }
  die(`playwright could not be resolved. Tried, in order:\n  ${tried.join('\n  ')}\n` +
      `Set BP_PLAYWRIGHT_FROM=<path to a package.json that can require("playwright")>.`);
}

function readHeex(ref) {
  if (ref === 'WORKTREE') return fs.readFileSync(path.join(REPO, HEEX), 'utf8');
  try {
    return execFileSync('git', ['show', `${ref}:${HEEX}`],
      { cwd: REPO, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  } catch (e) {
    die(`could not read ${HEEX} at ref "${ref}": ${e.message}`);
  }
}

/** The fence, when the ref has one. A marker counts only on a line whose
 *  trimmed form IS the JS comment `// <MARKER>` — prose naming it does not. */
function extractQueue(ref) {
  const lines = readHeex(ref).split('\n');
  const at = (marker) => {
    const hits = [];
    lines.forEach((l, i) => { if (l.trim() === `// ${marker}`) hits.push(i); });
    return hits;
  };
  const b = at(FENCE_BEGIN), e = at(FENCE_END);
  if (b.length === 0 && e.length === 0) return { ref, queue: false, js: '' };
  if (b.length !== 1 || e.length !== 1 || e[0] <= b[0]) {
    die(`malformed ${FENCE_BEGIN}/${FENCE_END} fence in ${HEEX} at ${ref}: ` +
        `${b.length} begin, ${e.length} end`);
  }
  const js = lines.slice(b[0] + 1, e[0]).join('\n');
  if (!js.trim()) die(`empty ${FENCE_BEGIN} fence in ${HEEX} at ${ref}`);
  return { ref, queue: true, js };
}

/** The mutation that proves the REPLAY — not the swallow — is what sends the
 *  press. The fence stays, the listener stays, only the re-dispatch dies. */
function deleteReplay(js) {
  const needle = '        el.click();\n';
  if (!js.includes(needle)) die('REPLAY-DELETED mutation could not find the replay `el.click()`');
  return js.replace(needle, '        /* REPLAY DELETED BY THE MUTATION */\n');
}

async function runCell(pw, { label, js, queue }) {
  const html = fs.readFileSync(FIXTURE, 'utf8');
  if (!html.includes(JS_SLOT)) die(`fixture has no ${JS_SLOT} slot`);
  const filled = html.replace(JS_SLOT, `<script id="bp-injected-queue">\n${js}\n</script>`);
  const tmp = path.join(path.dirname(FIXTURE), `.__prejoin-${process.pid}-${label.replace(/\W+/g, '_')}.html`);
  fs.writeFileSync(tmp, filled);
  const browser = await pw.chromium.launch();
  try {
    const page = await browser.newPage();
    const errors = [];
    page.on('pageerror', (e) => errors.push(String(e).slice(0, 200)));
    await page.addInitScript(({ join, reply }) => {
      window.__joinDelayMs = join;
      window.__replyDelayMs = reply;
    }, { join: JOIN_DELAY_MS, reply: REPLY_DELAY_MS });
    await page.goto(pathToFileURL(tmp).href);
    await page.waitForTimeout(PRESS_AT_MS);

    // THE PRECONDITION, ASSERTED — not raced. The press below is only evidence
    // about the pre-join window if the view is demonstrably not joined yet.
    const press = await page.evaluate(() => {
      const main = document.querySelector('[data-phx-main]');
      const el = document.getElementById('item-paper');
      const armed = {
        joinedAtPress: main.classList.contains('phx-connected'),
        refAtPress: el.hasAttribute('data-phx-ref-src'),
        framesBefore: window.__frames.filter((f) => f.type === 'click').length,
      };
      el.click();
      return armed;
    });
    if (press.joinedAtPress) die(`${label}: the view was ALREADY joined at press time — the cell measured nothing`);
    if (press.refAtPress) die(`${label}: #item-paper carried a ref before any press — the fixture is not in its pre-join state`);

    await page.waitForTimeout(JOIN_DELAY_MS + 600);
    const after = await page.evaluate(() => ({
      joinedAt: window.__joinedAt,
      clickFrames: window.__frames.filter((f) => f.type === 'click').map((f) => f.t),
      allFrames: window.__frames.map((f) => `${f.event}${f.name ? ':' + f.name : ''}@${f.t}`),
      says: (document.getElementById('bp-press-answer') || {}).textContent || '',
    }));

    // The IN-FLIGHT cell, on the same page, now joined: press once (LiveView
    // stamps its own ref), press again while that ref is outstanding.
    const inflight = await page.evaluate(async () => {
      const el = document.getElementById('item-paper');
      const n0 = window.__frames.filter((f) => f.type === 'click').length;
      el.click();
      const n1 = window.__frames.filter((f) => f.type === 'click').length;
      const refSelfArrived = el.hasAttribute('data-phx-ref-src');
      el.click();
      const n2 = window.__frames.filter((f) => f.type === 'click').length;
      return { n0, n1, n2, refSelfArrived };
    });

    return { label, queue, press, ...after, inflight, errors };
  } finally {
    await browser.close();
    fs.rmSync(tmp, { force: true });
  }
}

function line(c) {
  const sent = c.clickFrames.length;
  return `${c.label.padEnd(26)} queue=${String(c.queue).padEnd(5)} ` +
         `join@${String(c.joinedAt).padStart(5)}ms  click frames: ${sent}` +
         (sent ? ` (t=${c.clickFrames.join(',')}ms)` : '') +
         `  ${sent ? 'SENT' : 'SWALLOWED'}`;
}

async function main() {
  const argv = process.argv.slice(2);
  const json = argv.includes('--json');
  const selfTest = argv.includes('--self-test');
  const refIdx = argv.indexOf('--ref');
  const refs = refIdx >= 0 ? [argv[refIdx + 1]] : ['origin/main', 'WORKTREE'];
  for (const a of argv) {
    if (!['--json', '--self-test', '--ref', ...refs].includes(a)) die(`unknown flag: ${a}`);
  }

  const { pw } = resolvePlaywright();
  const cells = [];
  for (const ref of refs) {
    const q = extractQueue(ref);
    cells.push(await runCell(pw, { label: `ref ${ref}`, js: q.js, queue: q.queue }));
    if (q.queue) {
      cells.push(await runCell(pw, { label: `ref ${ref} REPLAY-DELETED`, js: deleteReplay(q.js), queue: true }));
    }
  }

  if (json) console.log(JSON.stringify(cells, null, 2));
  else cells.forEach((c) => console.log(line(c)));

  if (!selfTest) return 0;

  let bad = 0;
  const ok = (cond, msg) => { console.log(`${cond ? 'ok  ' : 'FAIL'} ${msg}`); if (!cond) bad++; };
  const byLabel = (l) => cells.find((c) => c.label === l);

  for (const c of cells) ok(c.errors.length === 0, `${c.label}: no page errors (${c.errors.join('; ')})`);

  const head = byLabel('ref WORKTREE');
  if (head) {
    ok(head.queue, 'WORKTREE ships a BP-PREJOIN-QUEUE fence');
    ok(head.clickFrames.length === 1,
       `WORKTREE: the pre-join press reaches the wire exactly once (got ${head.clickFrames.length})`);
    ok(head.clickFrames.length === 1 && head.clickFrames[0] >= head.joinedAt,
       `WORKTREE: it is sent AFTER the join (frame@${head.clickFrames[0]}ms, join@${head.joinedAt}ms)`);
    const mut = byLabel('ref WORKTREE REPLAY-DELETED');
    ok(mut && mut.clickFrames.length === 0,
       `WORKTREE REPLAY-DELETED: deleting the replay puts the press back to zero frames (got ${mut && mut.clickFrames.length})`);
    ok(head.inflight.refSelfArrived,
       'the in-flight ref is stamped by LiveView itself, never by this control');
    ok(head.inflight.n1 === head.inflight.n0 + 1 && head.inflight.n2 === head.inflight.n1,
       `the queue does not touch the in-flight swallow (${head.inflight.n0}->${head.inflight.n1}->${head.inflight.n2})`);
  }
  const base = byLabel('ref origin/main');
  if (base) {
    ok(!base.queue, 'origin/main ships no BP-PREJOIN-QUEUE fence');
    ok(base.clickFrames.length === 0,
       `origin/main: the pre-join press never reaches the wire (got ${base.clickFrames.length})`);
    ok(base.inflight.n1 === base.inflight.n0 + 1 && base.inflight.n2 === base.inflight.n1,
       `origin/main in-flight swallow reproduced (${base.inflight.n0}->${base.inflight.n1}->${base.inflight.n2})`);
  }
  console.log(bad === 0 ? `\nself-test: ${cells.length} cells, all assertions pass` : `\nself-test: ${bad} FAILED`);
  return bad === 0 ? 0 : 1;
}

try {
  process.exitCode = await main();
} catch (e) {
  if (e instanceof ControlError) { console.error(`GUARD: ${e.message}`); process.exitCode = 2; }
  else throw e;
}
