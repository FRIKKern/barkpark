#!/usr/bin/env node
//
// studio-inspector-frame-sample.mjs — THE FRAME SAMPLER.
//
// Answers ONE question that `scripts/studio-desk-measure.mjs` structurally
// cannot: does the Document inspector FLASH visible during initial rendering at
// viewport 1024? The desk instrument measures SETTLED geometry — every number it
// prints is taken after the page has stopped moving — so a panel that paints for
// three frames and then collapses satisfies every cell of its matrix while a
// reader still sees it. `spd-b29-inspector-overlay-eats-the-measure` names this
// the NO FLASH obligation and hands it to `spd-w9-b29-noflash-frame-sample`.
//
// This is a SIBLING, not an edit: `studio-desk-measure.mjs` has one writer per
// wave and a 3800-line contract this question does not belong inside. It imports
// that file's `resolvePlaywright()` (the only helper it exports that is useful
// here) and DUPLICATES the minimal provenance-over-ssh and login-ticket code,
// because `readProvenance`, `readGuerrillaServer` and `mintTicket` are not
// exported and adding exports would be an edit to the file this may not touch.
// Both duplications are marked `DUPLICATED FROM studio-desk-measure.mjs` below.
//
//   node scripts/studio-inspector-frame-sample.mjs                 # one deployed run
//   node scripts/studio-inspector-frame-sample.mjs --runs=5        # five, same sha
//   node scripts/studio-inspector-frame-sample.mjs --control       # positive control too
//   node scripts/studio-inspector-frame-sample.mjs --out <path>    # write the run JSON
//   node scripts/studio-inspector-frame-sample.mjs --fixture=<path|url>  # no ssh, no auth
//   node scripts/studio-inspector-frame-sample.mjs --help
//
// ── The designed-in impossibilities ──────────────────────────────────────────
//
//   1. SAMPLING STARTS BEFORE ANY PAGE SCRIPT. The rAF loop is installed with
//      `context.addInitScript`, which chromium evaluates on every new document
//      BEFORE the document's own scripts — including the pre-paint <head> script
//      that stamps `html[data-width-bucket]`. The first rAF callback therefore
//      fires before the first paint of the document under test. A sampler
//      installed after `goto` resolves would begin AFTER the flash it exists to
//      catch, and would report a confident zero.
//
//   2. THE DOCUMENT IS REACHED BY A FRESH FULL NAVIGATION, never by the
//      in-desk click-drill. `Scope.select/2` is a LiveView push_patch: clicking a
//      row in the Papers pane never creates a new document, so there is no
//      document_start to sample and no first paint to observe. The drill runs
//      ONCE, only to LEARN the document's URL, and every sampled run is a
//      `page.goto` of that URL into a page created after the init script.
//
//   3. A ZERO-FRAME RUN IS AN INSTRUMENT FAILURE, NEVER A DESK FACT. "No frame
//      showed the inspector" and "no frame was sampled" have the same shape and
//      opposite meanings. `MIN_FRAMES` and an explicit `sidebar_ever_present`
//      check turn the second into `verdict: INSTRUMENT-FAILURE`.
//
//   4. THE BUCKET PRECONDITION IS READ PER FRAME (charter D171/D185). The rule
//      under test is scoped `html:not([data-width-bucket="wide"])`. At viewport
//      1024 the bucket must be `standard` on every frame in which the inspector
//      exists; if it is not, the reading is VOID rather than green — the CSS
//      being exercised is not the CSS the criterion is about.
//
//   5. THE HARNESS MUST PROVE IT CAN SEE. `--control` re-runs the sample with
//      the inspector user-opened by a real click, and REQUIRES
//      `visible_frames > 0`. A control that reports zero means the visibility
//      predicate is blind and the main arm's zero means nothing; the run is
//      downgraded to INSTRUMENT-FAILURE rather than reported as a MEET.
//
//   6. PROVENANCE IS BRACKETED (the desk instrument's D97, same reasoning). The
//      served sha is read BEFORE and AFTER every run set. A deploy landing
//      inside the window means the early runs and the late runs describe
//      different builds and nothing in the JSON says which is which — so a
//      mid-run sha change FAILS the run loudly instead of averaging two builds.
//
// ── The visibility predicate, stated plainly ─────────────────────────────────
//
// "The inspector is visible" is ambiguous on this desk and the ambiguity is
// load-bearing. In the shipped default state the `<aside>` STILL PAINTS: charter
// D91/D102 reproduce `.is-collapsed`'s geometry deliberately so the ~41px strip
// and its control stay on screen and clickable. A predicate of "the element has
// a painted box" is therefore TRUE on every settled frame of a correct build and
// would report MISS forever.
//
// So this harness records BOTH and says which one the verdict turns on:
//
//   `element_painted` — the raw box test the task brief describes: computed
//       display/visibility/opacity plus a non-empty client rect intersecting the
//       viewport. Reported per frame and counted as `element_painted_frames`.
//       Expected to be TRUE throughout on a correct build (that is the strip).
//
//   `obstructing`     — THE VERDICT PREDICATE. The inspector is painting in a
//       state that takes reader space: the aside is painted AND carries
//       `is-open` AND (its `__body` or `__title` paints — both are
//       `display: none` in the painted-closed state — OR its own box is wider
//       than STRIP_MAX_PX, i.e. it is the 300px panel rather than the strip).
//       This is exactly the state `spd-b29-inspector-overlay-eats-the-measure`
//       is named for. `visible_frames` counts these, and zero is the bar.
//
// Counting `element_painted` as the flash would not be a stricter reading of the
// criterion; it would be a different criterion, one the shipped design fails on
// purpose. Both numbers are in the JSON so a reader can check that claim.

import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

import { resolvePlaywright } from './studio-desk-measure.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '..');

/** The default-state strip is ~41px (D91/D102 reproduce `.is-collapsed`'s
 *  geometry). The open panel is `flex: 0 0 300px`. 60 sits between them with
 *  room on both sides; it is a THRESHOLD BETWEEN TWO SHIPPED CONSTANTS, not a
 *  tuned number, and both constants are printed in every run so a future change
 *  to either is visible rather than silently re-classified. */
const STRIP_MAX_PX = 60;

/** Below this, the run sampled too little to mean anything. A settled desk at
 *  60fps produces this in well under a second; a run that cannot is not
 *  reporting a quiet page, it is reporting a broken sampler. */
const MIN_FRAMES = 30;

const VIEWPORT_W = 1024;
const VIEWPORT_H = 900;

/** The Papers list is capped at 100 rows, newest first, and concurrent epic
 *  waves publish into it continuously — so a slug pinned months ago AGES OFF and
 *  the drill fails with "the list never showed a row", which reads like a broken
 *  desk and is really a stale constant. (`studio-desk-measure.mjs`'s
 *  DEFAULT_DOC, `studio-space-priority-desk-browser-2026-07-19`, is already off
 *  the list as of 2026-09-06.) This one is a long-lived showcase document rather
 *  than a wave artefact, AND `--doc` falls back to the first row that opens
 *  rather than dying — which document is open does not change the inspector's
 *  default state, and a failed drill would report a NON-measurement. The
 *  fallback is RECORDED in the run JSON, never silent. */
const DEFAULT_DOC = 'portabledoc-showcase';
const SSH_HOST = 'root@157.180.90.121';

function die(msg) {
  process.stderr.write(`\nstudio-inspector-frame-sample: ${msg}\n\n`);
  process.exit(1);
}

// ── the sampler ──────────────────────────────────────────────────────────────
//
// EXPORTED as a string so it can be parsed (`new Function`) and reasoned about
// without an authenticated run — the same trick, and for the same reason, as
// the desk instrument's PAGE_MEASURE: a typo inside a template string is
// invisible to `node --check` on this file and would otherwise surface only
// after an ssh, a minted ticket and a drill.
export const FRAME_SAMPLER = /* js */ `
(function (STRIP_MAX_PX) {
  var frames = [];
  var stopped = false;
  var phase = 'load';

  function box(el) {
    if (!el) return { present: false, painted: false };
    var cs = getComputedStyle(el);
    var r = el.getBoundingClientRect();
    var painted =
      cs.display !== 'none' &&
      cs.visibility !== 'hidden' &&
      parseFloat(cs.opacity) > 0.01 &&
      r.width > 0 && r.height > 0 &&
      r.right > 0 && r.left < window.innerWidth &&
      r.bottom > 0 && r.top < window.innerHeight;
    return {
      present: true, painted: painted,
      display: cs.display, visibility: cs.visibility, opacity: cs.opacity,
      w: r.width, h: r.height, x: r.left, y: r.top,
    };
  }

  function r2(n) { return n === undefined || n === null ? null : Math.round(n * 100) / 100; }

  function sample() {
    var el = document.querySelector('.bp-doc-sidebar');
    var s = box(el);
    var body = box(el ? el.querySelector('.bp-doc-sidebar__body') : null);
    var title = box(el ? el.querySelector('.bp-doc-sidebar__title') : null);
    var cls = el ? (el.getAttribute('class') || '') : '';
    var isOpen = / is-open|^is-open/.test(' ' + cls) || cls.split(/\\s+/).indexOf('is-open') >= 0;
    var userOpened = !!el && el.hasAttribute('data-user-opened');
    var contentPainted = body.painted || title.painted;
    var widerThanStrip = s.painted && s.w > STRIP_MAX_PX;
    // THE VERDICT PREDICATE — see the header block for why it is not
    // \`element_painted\`.
    var obstructing = !!(s.painted && isOpen && (contentPainted || widerThanStrip));

    frames.push({
      i: frames.length,
      t_ms: Math.round(performance.now() * 100) / 100,
      phase: phase,
      ready_state: document.readyState,
      bucket: document.documentElement.getAttribute('data-width-bucket'),
      viewport_w: window.innerWidth,
      present: s.present,
      element_painted: !!s.painted,
      sidebar_w: r2(s.w), sidebar_h: r2(s.h), sidebar_x: r2(s.x),
      display: s.display || null, visibility: s.visibility || null, opacity: s.opacity || null,
      is_open: isOpen,
      user_opened: userOpened,
      body_painted: !!body.painted,
      title_painted: !!title.painted,
      wider_than_strip: !!widerThanStrip,
      obstructing: obstructing,
    });
  }

  function loop() {
    if (stopped) return;
    sample();
    window.requestAnimationFrame(loop);
  }
  window.requestAnimationFrame(loop);

  window.__bpFrameSample = {
    count: function () { return frames.length; },
    dump: function () { return frames; },
    stop: function () { stopped = true; return frames.length; },
    setPhase: function (p) { phase = p; },
    tail: function (n) { return frames.slice(-n); },
  };
})(${STRIP_MAX_PX});
`;

// ── provenance ───────────────────────────────────────────────────────────────
// DUPLICATED FROM studio-desk-measure.mjs (`readProvenance` / `compareProvenance`
// are not both exported and this file may not add exports to that one). Trimmed
// to the sha, which is the only half a frame sample can misattribute.

const SSH = ['-i', path.join(os.homedir(), '.ssh/barkpark_indx'), '-o', 'ConnectTimeout=15',
             '-o', 'StrictHostKeyChecking=accept-new', SSH_HOST];

export function readServedSha() {
  try {
    return {
      read_at: new Date().toISOString(),
      served_sha: execFileSync('ssh', [...SSH, 'cd /opt/barkpark && git rev-parse HEAD'],
        { encoding: 'utf8', timeout: 45_000 }).trim(),
      method: `ssh ${SSH_HOST} "cd /opt/barkpark && git rev-parse HEAD"`,
    };
  } catch (e) {
    die(`could not read the served SHA over ssh — refusing to publish a frame sample with no ` +
        `provenance. A no-flash claim against an unknown build certifies nothing. ${e.message}`);
  }
}

// ── auth ─────────────────────────────────────────────────────────────────────
// DUPLICATED FROM studio-desk-measure.mjs (D24e login-ticket flow), verbatim in
// behaviour: https-only base (the session cookie is Secure), empty mint body (an
// `email` mints a USER-shaped ticket), single-use 60s TTL minted immediately
// before the navigation that spends it.

function readGuerrillaServer() {
  const p = path.join(os.homedir(), '.config/barkpark/config.json');
  if (!fs.existsSync(p)) die(`no barkpark config at ${p} — cannot read the guerrilla admin token`);
  const cfg = JSON.parse(fs.readFileSync(p, 'utf8'));
  const srv = (cfg.known_servers || []).find((s) => s.name === 'guerrilla');
  if (!srv?.token) die(`no guerrilla entry with a token in ${p}`);
  const base = String(srv.server || '').replace(/\/+$/, '');
  if (!base.startsWith('https://')) {
    die(`guerrilla server must be an https:// hostname (got ${base || '<empty>'}) — the session ` +
        `cookie carries Secure and an http/IP form is silently dropped`);
  }
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
  if (!body.ticket) die(`login-ticket response carried no ticket: ${JSON.stringify(body)}`);
  return body.ticket;
}

// ── analysis ─────────────────────────────────────────────────────────────────

/** Pure, exported, and therefore testable without a browser. Everything the
 *  verdict turns on is computed HERE, from the frame array, so the same
 *  arithmetic runs for the deployed arm, the control arm and every fixture. */
export function analyse(frames, opts = {}) {
  const arm = opts.arm || 'default';
  const total = frames.length;
  const present = frames.filter((f) => f.present);
  const visible = frames.filter((f) => f.obstructing);
  const elementPainted = frames.filter((f) => f.element_painted);

  let transitions = 0;
  for (let i = 1; i < frames.length; i++) {
    if (frames[i].obstructing !== frames[i - 1].obstructing) transitions++;
  }

  const bucketsSeen = [...new Set(present.map((f) => f.bucket))];
  const bucketOk = present.length > 0 && bucketsSeen.length === 1 && bucketsSeen[0] === 'standard';
  const bucketPrecondition = {
    required: 'standard',
    checked_frames: present.length,
    buckets_seen_while_sidebar_present: bucketsSeen,
    ok: bucketOk,
    note: bucketOk
      ? 'Every frame in which the inspector existed carried html[data-width-bucket="standard"], so ' +
        'the rule under test (scoped html:not([data-width-bucket="wide"])) was the rule in force.'
      : 'The bucket precondition FAILED or was never checked. The reading is VOID: whatever the ' +
        'frames show, it is not a statement about the rule this criterion is about (D171/D185).',
  };

  const first = frames[0] || null;
  const firstFramePresent = frames.find((f) => f.present) || null;

  const failures = [];
  if (total < MIN_FRAMES) {
    failures.push(`only ${total} frame(s) sampled (floor ${MIN_FRAMES}). A zero-or-tiny sample and a ` +
                  `clean page have the same shape; this is a broken sampler, not a desk fact.`);
  }
  if (present.length === 0) {
    failures.push(`the inspector (.bp-doc-sidebar) was NEVER present in ${total} sampled frame(s). ` +
                  `A run that never saw the element cannot report that the element never flashed.`);
  }
  if (present.length > 0 && !bucketOk) {
    failures.push(`bucket precondition failed — saw [${bucketsSeen.join(', ')}] while the inspector ` +
                  `was present, required "standard" throughout.`);
  }
  if (arm === 'control' && failures.length === 0 && visible.length === 0) {
    failures.push(`POSITIVE CONTROL SAW NOTHING: the inspector was forced open by a real click and ` +
                  `the predicate still counted 0 visible frames out of ${total}. The predicate is ` +
                  `blind, so a 0 from the default arm means nothing.`);
  }

  let verdict;
  if (failures.length > 0) verdict = 'INSTRUMENT-FAILURE';
  else if (arm === 'control') verdict = visible.length > 0 ? 'CONTROL-OK' : 'INSTRUMENT-FAILURE';
  else verdict = visible.length === 0 ? 'MEET' : 'MISS';

  return {
    arm,
    verdict,
    failures,
    total_frames: total,
    visible_frames: visible.length,
    element_painted_frames: elementPainted.length,
    frames_with_sidebar_present: present.length,
    transitions,
    first_frame: first && {
      i: first.i, t_ms: first.t_ms, ready_state: first.ready_state, bucket: first.bucket,
      present: first.present, element_painted: first.element_painted,
      is_open: first.is_open, user_opened: first.user_opened,
      sidebar_w: first.sidebar_w, obstructing: first.obstructing,
    },
    first_frame_visible: first ? !!first.obstructing : null,
    first_frame_with_sidebar_present: firstFramePresent && {
      i: firstFramePresent.i, t_ms: firstFramePresent.t_ms,
      ready_state: firstFramePresent.ready_state, bucket: firstFramePresent.bucket,
      is_open: firstFramePresent.is_open, user_opened: firstFramePresent.user_opened,
      sidebar_w: firstFramePresent.sidebar_w, obstructing: firstFramePresent.obstructing,
    },
    visible_frame_indices: visible.slice(0, 40).map((f) => f.i),
    bucket_precondition: bucketPrecondition,
    predicate: {
      verdict_predicate: 'obstructing = element painted AND .is-open AND (__body or __title painted ' +
        `OR own box width > ${STRIP_MAX_PX}px)`,
      raw_predicate: 'element_painted = computed display!=none AND visibility!=hidden AND opacity>0.01 ' +
        'AND a non-empty client rect intersecting the viewport',
      strip_max_px: STRIP_MAX_PX,
      why_not_raw: 'The shipped default state (charter D91/D102) deliberately keeps a ~41px strip and ' +
        'its control on screen and clickable. element_painted is TRUE on every settled frame of a ' +
        'CORRECT build, so keying the verdict on it would report MISS forever against a design that ' +
        'is working as ruled. Both counts are reported.',
    },
  };
}

// ── the run ──────────────────────────────────────────────────────────────────

async function settleAndDump(page, { minFrames = 120, quietFrames = 60, capMs = 20_000 } = {}) {
  const started = Date.now();
  let lastCount = -1;
  let quiet = 0;
  for (;;) {
    if (Date.now() - started > capMs) break;
    const snap = await page.evaluate(() => {
      const s = window.__bpFrameSample;
      if (!s) return null;
      const tail = s.tail(80);
      return { count: s.count(), tail: tail.map((f) => f.obstructing) };
    }).catch(() => null);
    if (!snap) { await page.waitForTimeout(100); continue; }
    if (snap.count >= minFrames && snap.count !== lastCount) {
      const constant = snap.tail.length >= quietFrames &&
        snap.tail.slice(-quietFrames).every((v) => v === snap.tail[snap.tail.length - 1]);
      if (constant) { quiet++; } else { quiet = 0; }
      if (quiet >= 3) break;
    }
    lastCount = snap.count;
    await page.waitForTimeout(120);
  }
  return page.evaluate(() => {
    const s = window.__bpFrameSample;
    if (!s) return null;
    s.stop();
    return s.dump();
  });
}

async function sampleOnce(context, url, { control = false } = {}) {
  let controlClicks = 0;
  const page = await context.newPage();
  await page.setViewportSize({ width: VIEWPORT_W, height: VIEWPORT_H });
  const t0 = Date.now();
  await page.goto(url, { waitUntil: 'domcontentloaded' });
  // LiveView holds a websocket open forever, so `networkidle` never settles on
  // the deployed desk — the frame-quiet test below IS the settle detector.
  await page.waitForSelector('.bp-doc-sidebar', { timeout: 15_000 }).catch(() => {});

  if (control) {
    // The positive control: the inspector is opened THE WAY A USER OPENS IT —
    // a real click on the canonical affordance through the live socket (D110),
    // never by setting a class from script. A control that reached the state by
    // a shortcut would prove the shortcut works, not that the predicate sees.
    await page.evaluate(() => window.__bpFrameSample && window.__bpFrameSample.setPhase('control'));
    const toggle = page.locator('[data-test-id="sidebar-toggle-panel"]').first();
    await toggle.waitFor({ state: 'visible', timeout: 15_000 });
    // IT TAKES TWO CLICKS, and the reason is the whole point of the control.
    // The default state is `.is-open` WITHOUT `[data-user-opened]` — open in the
    // DOM, painted as the strip. `sidebar-toggle-panel` is a TOGGLE over
    // `panel_open`, which is already true, so the first click COLLAPSES; only
    // the second re-opens, and only that re-open stamps the server-side
    // user-open marker. (spd-w7 recorded the same "2 real click(s)".) A control
    // that clicked once observed the collapsed strip, counted zero visible
    // frames, and declared the predicate blind — a false instrument failure.
    // The loop CLICKS UNTIL THE MARKER IS THERE and gives up loudly, so it can
    // never quietly settle for a state it did not reach.
    let reached = false;
    for (let attempt = 1; attempt <= 4 && !reached; attempt++) {
      await toggle.click();
      reached = await page
        .waitForSelector('.bp-doc-sidebar.is-open[data-user-opened]', { timeout: 8_000 })
        .then(() => true).catch(() => false);
      controlClicks = attempt;
    }
    if (!reached) {
      die(`the positive control clicked [data-test-id="sidebar-toggle-panel"] ${controlClicks} time(s) ` +
          `and never reached .bp-doc-sidebar.is-open[data-user-opened]. The control never entered the ` +
          `state it exists to observe, so it says nothing about the predicate — instrument failure.`);
    }
    await page.waitForTimeout(1200);
  }

  const frames = await settleAndDump(page);
  const elapsed_ms = Date.now() - t0;
  await page.close();
  if (!frames) die(`the frame sampler was not installed on ${url} — window.__bpFrameSample was absent. ` +
                   `An addInitScript that did not run produces the same empty result as a clean page.`);
  return { frames, elapsed_ms, url, control_clicks: controlClicks };
}

function parseArgs(argv) {
  const out = { runs: 1, control: false, json: false, out: null, fixture: null, doc: DEFAULT_DOC };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--help' || a === '-h') { out.help = true; }
    else if (a === '--control') out.control = true;
    else if (a === '--json') out.json = true;
    else if (a === '--out') out.out = argv[++i];
    else if (a.startsWith('--out=')) out.out = a.slice('--out='.length);
    else if (a.startsWith('--runs=')) out.runs = parseInt(a.slice('--runs='.length), 10);
    else if (a.startsWith('--fixture=')) out.fixture = a.slice('--fixture='.length);
    else if (a.startsWith('--doc=')) out.doc = a.slice('--doc='.length);
    else die(`unknown argument "${a}" — see --help`);
  }
  if (!Number.isFinite(out.runs) || out.runs < 1) die(`--runs must be a positive integer`);
  return out;
}

const HELP = `studio-inspector-frame-sample.mjs — does the Studio inspector FLASH at viewport ${VIEWPORT_W}?

  --runs=N        Sample N times against the same served sha (default 1).
  --control       ALSO run the positive control (inspector user-opened by a real
                  click). Required for a reading to mean anything: a control that
                  reports 0 visible frames proves the predicate is blind.
  --fixture=<p>   Sample a local HTML file or URL instead of deployed guerrilla.
                  No ssh, no login-ticket. For the proof harness.
  --out <path>    Write the full run JSON (frames included) to <path>.
  --json          Print the run JSON to stdout instead of the human summary.
  --doc=<slug>    The document to open (default ${DEFAULT_DOC}).

Verdicts: MEET (0 visible frames) · MISS (>0) · INSTRUMENT-FAILURE (the run
cannot speak: too few frames, the inspector never existed, the width bucket was
not "standard", or the positive control saw nothing).`;

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) { process.stdout.write(HELP + '\n'); return; }

  const { pw, resolvedFrom, version } = resolvePlaywright();
  const browser = await pw.chromium.launch();
  const provenance = { browser: { engine: 'chromium', playwright_version: version,
                                 playwright_resolved_from: resolvedFrom,
                                 browser_version: browser.version(),
                                 executable_path: pw.chromium.executablePath() } };

  const run = {
    tool: 'scripts/studio-inspector-frame-sample.mjs',
    generated_at: new Date().toISOString(),
    question: `Does the Document inspector paint in an obstructing state during initial rendering ` +
              `at viewport ${VIEWPORT_W}? Zero visible frames is the bar.`,
    viewport: { width: VIEWPORT_W, height: VIEWPORT_H },
    mode: args.fixture ? 'fixture' : 'deployed',
    provenance,
    runs: [],
    control: null,
    warnings: [],
  };

  try {
    let url;
    if (args.fixture) {
      url = /^[a-z]+:\/\//.test(args.fixture) ? args.fixture
          : pathToFileURL(path.resolve(args.fixture)).href;
      run.provenance.fixture = { source: args.fixture, resolved_url: url };
      run.warnings.push('FIXTURE MODE — this run says nothing about the deployed build. It exercises ' +
                        'the harness, not the desk.');
    } else {
      run.provenance.served_sha_pre = readServedSha();
      const srv = readGuerrillaServer();
      run.provenance.base = srv.base;

      // Authenticate ONCE on a boot page; the session cookie lives on the
      // context and every sampled page below reuses it. Minted immediately
      // before the navigation that spends it (single use, 60s TTL).
      const boot = await browser.newContext();
      const bootPage = await boot.newPage();
      await bootPage.setViewportSize({ width: VIEWPORT_W, height: VIEWPORT_H });
      const ticket = await mintTicket(srv);
      await bootPage.goto(`${srv.base}/login/ticket/${ticket}`, { waitUntil: 'domcontentloaded' });
      if (/\/login(\b|\/|$)/.test(new URL(bootPage.url()).pathname)) {
        die(`login-ticket flow landed back on ${bootPage.url()} — the session cookie was not set. ` +
            `Every frame after this would be a sample of a login page.`);
      }

      // REACH THE DOCUMENT BY ITS URL, NOT BY THE PANE DRILL.
      //
      // `studio-desk-measure.mjs` drills by clicking (root desk -> Papers ->
      // row) because a SETTLED sweep wants the state a user's clicks leave
      // behind. A FIRST-PAINT sample cannot use that path at all: `Scope.select/2`
      // is a push_patch, so the click creates no new document and there is no
      // document_start to sample (impossibility #2). The drill could therefore
      // only ever have been a way to LEARN the URL — and it is a bad one here.
      // Measured on the deployed desk, 2026-09-06: the click drill fails
      // NON-DETERMINISTICALLY, because the desk restores the previously-opened
      // document, which changes both which pane column holds the list and
      // whether a "Papers" pane-item renders at all. Three consecutive attempts
      // died at three different points.
      //
      // So: build the URL, navigate, and assert the two things the drill's
      // assertion actually bought (D97) — a `.bp-paper-surface` appeared, and
      // the landed URL carries the slug we asked for. Neither is weakened.
      const deskRoot = `${srv.base}/w/default/p/default/d/production/studio`;
      const candidate = `${deskRoot}/paper/${encodeURIComponent(args.doc)}`;
      await bootPage.goto(candidate, { waitUntil: 'domcontentloaded' });
      const opened = await bootPage.waitForSelector('.bp-paper-surface', { timeout: 30_000 })
        .then(() => true).catch(() => false);
      if (!opened) {
        die(`${candidate} rendered no .bp-paper-surface within 30s. Either the slug is wrong (pass ` +
            `--doc=<slug>) or the desk did not open it. Instrument failure, not a desk fact.`);
      }
      const landed = new URL(bootPage.url());
      const slugInUrl = decodeURIComponent(landed.pathname.split('/').pop());
      if (slugInUrl !== args.doc) {
        die(`asked for "${args.doc}" but landed on "${slugInUrl}" (${bootPage.url()}). Refusing to ` +
            `label this run with a document it did not open.`);
      }
      if (/\/login(\b|\/|$)/.test(landed.pathname)) {
        die(`landed on a login page (${bootPage.url()}) — every frame after this would be a sample ` +
            `of the login screen, not the desk.`);
      }
      url = bootPage.url();
      run.measured_document = slugInUrl;
      run.measured_url = url;
      run.drill = {
        method: 'direct URL + .bp-paper-surface assertion + slug-in-URL assertion',
        requested: args.doc,
        opened: slugInUrl,
        why_not_click_drill:
          'A push_patch drill produces no document_start to sample, and on the deployed desk the ' +
          'click path failed non-deterministically (the restored document moves the Papers list ' +
          'between pane columns and can remove the "Papers" pane-item entirely).',
      };
      // The session cookie lives on this context; every sampled page reuses it.
      run.provenance.cookies_from = 'the authenticated boot context (one login-ticket, reused by every sampled page)';
      await bootPage.close();
      run.__context = boot;
    }

    const context = run.__context || await browser.newContext();
    delete run.__context;
    await context.addInitScript(FRAME_SAMPLER);
    run.sampler_installed_via = 'context.addInitScript (evaluated before any page script, every document)';

    for (let i = 0; i < args.runs; i++) {
      const r = await sampleOnce(context, url);
      run.runs.push({ run_index: i + 1, elapsed_ms: r.elapsed_ms, ...analyse(r.frames, { arm: 'default' }),
                      frames: r.frames });
    }

    if (args.control) {
      const c = await sampleOnce(context, url, { control: true });
      run.control = { elapsed_ms: c.elapsed_ms, control_clicks: c.control_clicks,
                      control_state_reached: '.bp-doc-sidebar.is-open[data-user-opened], asserted before sampling',
                      ...analyse(c.frames, { arm: 'control' }), frames: c.frames };
    }

    if (!args.fixture) {
      run.provenance.served_sha_post = readServedSha();
      if (run.provenance.served_sha_pre.served_sha !== run.provenance.served_sha_post.served_sha) {
        run.warnings.push(
          `SERVED SHA CHANGED MID-RUN: ${run.provenance.served_sha_pre.served_sha} -> ` +
          `${run.provenance.served_sha_post.served_sha}. Early runs and late runs describe different ` +
          `builds and nothing here says which is which. Every verdict below is VOID.`);
        run.runs.forEach((r) => { r.verdict = 'INSTRUMENT-FAILURE'; r.failures.push('served sha changed mid-run'); });
        if (run.control) { run.control.verdict = 'INSTRUMENT-FAILURE'; }
      }
    }

    // The control gates the whole reading (impossibility #5).
    if (args.control && run.control && run.control.verdict !== 'CONTROL-OK') {
      run.warnings.push('THE POSITIVE CONTROL DID NOT PASS. Every default-arm verdict below is VOID: ' +
                        'a predicate that cannot see the inspector when it IS open has not shown that ' +
                        'the inspector was absent when it looked absent.');
      run.runs.forEach((r) => { if (r.verdict === 'MEET') { r.verdict = 'INSTRUMENT-FAILURE'; r.failures.push('positive control failed'); } });
    }

    const verdicts = run.runs.map((r) => r.verdict);
    run.stable = new Set(verdicts).size === 1;
    run.verdict = run.stable ? verdicts[0] : 'INSTRUMENT-FAILURE';
    if (!run.stable) run.warnings.push(`verdicts differed across runs: [${verdicts.join(', ')}]`);

    if (args.out) {
      fs.mkdirSync(path.dirname(path.resolve(args.out)), { recursive: true });
      fs.writeFileSync(path.resolve(args.out), JSON.stringify(run, null, 2) + '\n');
    }

    if (args.json) {
      process.stdout.write(JSON.stringify(run, null, 2) + '\n');
    } else {
      const L = [];
      L.push('');
      L.push(`FRAME SAMPLE — inspector flash at viewport ${VIEWPORT_W}   [${run.mode}]`);
      if (run.provenance.served_sha_pre) {
        L.push(`  served sha : ${run.provenance.served_sha_pre.served_sha} (pre) / ` +
               `${run.provenance.served_sha_post?.served_sha ?? '?'} (post)`);
      }
      if (run.measured_url) L.push(`  document   : ${run.measured_url}`);
      if (run.provenance.fixture) L.push(`  fixture    : ${run.provenance.fixture.resolved_url}`);
      L.push(`  browser    : chromium ${provenance.browser.browser_version} via playwright ` +
             `${version} (${resolvedFrom})`);
      L.push('');
      L.push('  run | frames | visible | painted | trans | first-frame | bucket   | verdict');
      L.push('  ----+--------+---------+---------+-------+-------------+----------+--------');
      for (const r of run.runs) {
        L.push(`  ${String(r.run_index).padStart(3)} | ${String(r.total_frames).padStart(6)} | ` +
               `${String(r.visible_frames).padStart(7)} | ${String(r.element_painted_frames).padStart(7)} | ` +
               `${String(r.transitions).padStart(5)} | ` +
               `${(r.first_frame_visible ? 'VISIBLE' : 'not vis').padEnd(11)} | ` +
               `${(r.bucket_precondition.ok ? 'standard' : 'VOID').padEnd(8)} | ${r.verdict}`);
      }
      if (run.control) {
        L.push(`  ctl | ${String(run.control.total_frames).padStart(6)} | ` +
               `${String(run.control.visible_frames).padStart(7)} | ` +
               `${String(run.control.element_painted_frames).padStart(7)} | ` +
               `${String(run.control.transitions).padStart(5)} | ` +
               `${(run.control.first_frame_visible ? 'VISIBLE' : 'not vis').padEnd(11)} | ` +
               `${(run.control.bucket_precondition.ok ? 'standard' : 'VOID').padEnd(8)} | ${run.control.verdict}`);
      }
      L.push('');
      L.push(`  VERDICT: ${run.verdict}   (stable across ${run.runs.length} run(s): ${run.stable})`);
      L.push(`  visible_frames counts the OBSTRUCTING predicate: ${analyse([], {}).predicate.verdict_predicate}`);
      for (const w of run.warnings) L.push(`  ! ${w}`);
      for (const r of run.runs) for (const f of r.failures) L.push(`  ! run ${r.run_index}: ${f}`);
      if (run.control) for (const f of run.control.failures) L.push(`  ! control: ${f}`);
      if (args.out) L.push(`  written: ${args.out}`);
      L.push('');
      process.stdout.write(L.join('\n') + '\n');
    }

    process.exitCode = run.verdict === 'INSTRUMENT-FAILURE' ? 2 : 0;
  } finally {
    await browser.close();
  }
}

const invokedDirectly = process.argv[1] &&
  path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url));
if (invokedDirectly) {
  main().catch((e) => die(e?.stack || String(e)));
}

export { STRIP_MAX_PX, MIN_FRAMES, VIEWPORT_W, REPO };
