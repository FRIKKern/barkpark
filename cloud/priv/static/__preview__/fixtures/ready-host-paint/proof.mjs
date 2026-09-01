#!/usr/bin/env node
// proof.mjs — the PERMANENT, REAL-BROWSER mutation proof for the rendered-host
// floor's settle (task-e72560e947dba4e6).
//
// It runs the SHIPPED floor (../../ready-host-paint.mjs) in a real headless
// Chrome against committed fixtures, in BOTH directions, and it does not pass
// unless every direction lands where it should:
//
//   1. DEFECT REPRODUCED   animating-triggered.html with the settle DEFEATED
//                          (cap 0 — the exact pre-fix code path: probe once,
//                          judge now) must REFUSE, quoting computed opacity "0"
//                          on a host measured at 300x40. This is the bug, on
//                          demand — and it is ARMED, not raced: see below.
//   2a. FIX WORKS          animating.html (a natural on-load entry animation)
//                          with the shipped cap must PASS. Nothing is asked
//                          about WHEN the floor arrived — only that it measured.
//   2b. AND SAYS SO        the ARMED fixture, shipped cap: the settle must
//                          announce itself exactly once, naming the animation.
//                          The animation is started inside the floor's own
//                          first probe, so there is always something to settle
//                          on — see runFloorArmed.
//   3. NESTED CASE         nested-modal.html — the host is a DESCENDANT of the
//                          animated element, which is the shape both `#a2f-error`
//                          main refusals had — must also PASS.
//   4. HOLE STAYS SHUT     display-none.html must still REFUSE, with the shipped
//                          cap, and its refusal must name display:none.
//   5. NO BUDGET WASTED    that refusal must arrive without spending the settle
//                          cap — proving the settle is CONDITIONAL and not a
//                          blanket wait that greens everything eventually.
//   7. THE HOLE ONE LEVEL UP  ancestor-display-none.html must ALSO refuse, on
//                          the first pass. It is the shape that most resembles
//                          the settle's second reason to wait (no layout box,
//                          own computed display "block"), and only the DOCUMENT
//                          state separates them — see below.
//
// WHAT THIS FILE CANNOT ARM, STATED RATHER THAN FAKED. The settle's second
// reason to wait — a host the browser has not LAID OUT yet (box 0x0,
// getClientRects() empty, display "flex", document "loading") — is the shape
// console-harness 33474373014 died on, and it is reproducible only by racing a
// real page's load. It was measured on the real preview page (15 refusals in 20
// navigations with the settle defeated, 0 in 20 with the shipped cap, at load
// 6.45 on 10 cpus), but it has NO committed fixture here, because there is no
// way to hold a document in "loading" with its host un-laid-out on demand:
// MEASURED — a render-blocking stylesheet held open on an ephemeral port does
// NOT do it (Chrome lays the host out under UA styles anyway: box 740x18,
// getClientRects() 1, readyState "interactive", 4/4 runs). Rather than ship a
// direction that races a clock — the exact defect the header above describes —
// that half is proven by ready-host-paint.test.mjs against a virtual clock, and
// direction 7 pins the fixture that keeps it from over-reaching.
//
// Direction 1 is why this file exists rather than a screenshot: a fix whose
// proof cannot reproduce the defect is a story about the pixels.
//
// AND DIRECTION 1 MUST NOT RACE A CLOCK, which cost one main run to learn. Its
// first version loaded animating.html — whose animation starts on load — and
// trusted the probe to beat a 280ms window. MEASURED under 24 CPU stressors
// (load 155): that approach goes VACUOUS 1 in 14 trials, reporting "the defect
// no longer reproduces" because computed opacity had already crept to
// 0.0203205 — non-zero is all checkOpacity needs. It duly failed on main inside
// one run of merging (console-harness 32690594539, job 97323534019).
//
// A flaky anti-vacuous-green check is worse than none: it teaches the reader to
// re-run, which is precisely how the floor's own intermittency survived four
// main runs. So direction 1 now ARMS the state instead of racing it — the
// animation is inert until a class lands, and the class-add and the read happen
// in the SAME evaluate. Same measurement, 0 in 14 vacuous at the same load, and
// no animation was lengthened to buy the margin.
//
// THE SAME GAP REOPENED ONE ROUND TRIP LATER (task-93220c098b7f4ecf). Arming in
// one evaluate and running the floor in the NEXT still leaves a window the size
// of a CDP round trip — and direction 2 never got the arming at all: it ran the
// floor against the on-load fixture and demanded the settle narrate itself,
// which only happens if the floor beats a 280ms animation. Measured on main on
// 2026-08-24: 8 failures in 18 runs, always that arm, always `settled in 3ms …
// printed nothing`, on a REQUIRED check. Both directions now arm INSIDE the
// floor's own first probe (runFloorArmed), so no direction in this file is
// decided by how busy the host was.
//
//   node cloud/priv/static/__preview__/fixtures/ready-host-paint/proof.mjs
//   CHROME=/path/to/chrome node …/proof.mjs

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

import { SETTLE_CAP_MS, assertReadyHostsPaint, paintProbeJs, readySelectorsFrom } from "../../ready-host-paint.mjs";
import { BRINGUP_ATTEMPTS, bringUpChrome, captureStderr } from "../../bringup-retry.mjs";
import { createExitVocabulary } from "../../exit-vocabulary.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function findChrome() {
  if (process.env.CHROME) {
    try { fs.accessSync(process.env.CHROME, fs.constants.X_OK); return process.env.CHROME; } catch { return null; }
  }
  for (const c of [
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    "/usr/bin/google-chrome",
    "/usr/bin/google-chrome-stable",
    "/usr/bin/chromium",
    "/usr/bin/chromium-browser",
  ]) {
    try { fs.accessSync(c, fs.constants.X_OK); return c; } catch { /* next */ }
  }
  return null;
}

// THE EXIT VOCABULARY, IMPORTED RATHER THAN RE-DECIDED.
//
// This file used to spell its own refusals — `process.stderr.write("!! PROOF
// (exit 2): …"); process.exit(2)` — at four sites, and so did every sibling
// instrument, each with its own wording and its own idea of which faults were
// refusals. overflow-guard.mjs had the rule written down correctly and nowhere
// else, which is exactly why cssom-parity.mjs could quote the reasoning three
// lines above two throws that break it. exit-vocabulary.mjs is that rule as a
// function call: refuse() makes NO claim, defect() accuses the subject, and
// settle() sorts an unexpected throw toward "I did not measure" rather than
// toward an accusation. It also drains stdout before exiting, which a hand-
// rolled `write(); exit()` does not — on a pipe that can truncate the refusal
// and leave a bare exit code with no cause.
//
// `teardown` closes the CDP socket, so no refusal path can leave one open. `ws`
// is assigned later; the closure reads it at call time, so an early refusal
// (no Chrome) tears down nothing and a late one tears down the socket.
let ws = null;
const vocab = createExitVocabulary({
  instrument: "PROOF",
  subject: "the rendered-host floor (ready-host-paint.mjs)",
  teardown: async () => { try { if (ws) ws.close(); } catch { /* already gone */ } },
});

// A missing browser is an ENVIRONMENTAL refusal (exit 2), never a failed proof
// (exit 1) — the same discrimination overflow-guard.mjs makes, for the same
// reason: exit 1 here must mean "the floor behaved wrongly".
const chromeBin = findChrome();
if (!chromeBin) {
  await vocab.refuse("no Chrome/Chromium found. Set CHROME=/path/to/chrome.");
}

const profiles = [];
const brought = await bringUpChrome({
  label: "ready-host-paint-proof",
  attempts: BRINGUP_ATTEMPTS,
  newProfile: () => { const p = fs.mkdtempSync(path.join(os.tmpdir(), "rhp-proof-")); profiles.push(p); return p; },
  launch: (profile) => {
    const c = spawn(chromeBin, [
      "--headless=new", "--remote-debugging-port=0", `--user-data-dir=${profile}`,
      "--no-first-run", "--no-default-browser-check", "--disable-gpu",
      "--no-sandbox", "--disable-dev-shm-usage", "about:blank",
    ], { stdio: ["ignore", "ignore", "pipe"] });
    return { child: c, readStderr: captureStderr(c) };
  },
  awaitDevToolsPort: async ({ profile }) => {
    for (let w = 0; w < 15000; w += 100) {
      try {
        const raw = fs.readFileSync(path.join(profile, "DevToolsActivePort"), "utf8").split("\n");
        if (raw[0] && Number(raw[0])) return Number(raw[0]);
      } catch { /* not written yet */ }
      await sleep(100);
    }
    return null;
  },
  abandon: async ({ profile, child }) => {
    try { child && child.kill("SIGKILL"); } catch { /* gone */ }
    try { fs.rmSync(profile, { recursive: true, force: true }); } catch { /* best effort */ }
  },
  log: (l) => process.stderr.write(l),
}).catch((e) => vocab.refuse(`Chrome never came up — ${e.message}`));

const chrome = brought.child;
process.once("exit", () => {
  try { chrome.kill("SIGKILL"); } catch { /* gone */ }
  for (const p of profiles) { try { fs.rmSync(p, { recursive: true, force: true }); } catch { /* best effort */ } }
});

const version = await (await fetch(`http://127.0.0.1:${brought.devPort}/json/version`)).json();
process.stdout.write(`>> chrome     ${version.Browser} · node ${process.version}\n`);
// Assigned into the `ws` declared above, so the vocabulary's teardown can close
// it on any refusal from here on without every exit site remembering to.
ws = new WebSocket(version.webSocketDebuggerUrl);
await new Promise((res, rej) => {
  ws.addEventListener("open", res, { once: true });
  ws.addEventListener("error", () => rej(new Error("CDP connect failed")), { once: true });
});
let seq = 0;
const pending = new Map();
ws.addEventListener("message", (ev) => {
  const m = JSON.parse(ev.data);
  if (m.id == null) return;
  const p = pending.get(m.id);
  if (!p) return;
  pending.delete(m.id);
  m.error ? p.reject(new Error(JSON.stringify(m.error))) : p.resolve(m.result);
});
const raw = (method, params = {}, sessionId) => new Promise((res, rej) => {
  const id = ++seq;
  pending.set(id, { resolve: res, reject: rej });
  const frame = { id, method, params };
  if (sessionId) frame.sessionId = sessionId;
  ws.send(JSON.stringify(frame));
});

const { targetId } = await raw("Target.createTarget", { url: "about:blank" });
const { sessionId } = await raw("Target.attachToTarget", { targetId, flatten: true });
await raw("Runtime.enable", {}, sessionId);
await raw("Page.enable", {}, sessionId);

const send = (method, params = {}) => raw(method, params, sessionId);
const evalJs = async (expression) => {
  const r = await send("Runtime.evaluate", { expression, returnByValue: true });
  if (r.exceptionDetails) throw new Error("page eval threw: " + r.exceptionDetails.text);
  return r.result.value;
};

// Land on the fixture the way nav() does, then hand the floor the browser it
// would have had. `about:blank` first so each case starts its animation clock
// from a real navigation rather than inheriting the previous page's.
async function load(file) {
  await send("Page.navigate", { url: "about:blank" });
  await sleep(60);
  await send("Page.navigate", { url: "file://" + path.join(HERE, file) });
  // The readiness poll's own minimum lap. The floor is entitled to assume the
  // document exists; it is NOT entitled to assume it has finished animating.
  for (let i = 0; i < 60; i++) {
    try { if (await evalJs("!!document.querySelector('.deploy-detail, #a2f-error')")) return; } catch { /* still navigating */ }
    await sleep(20);
  }
  throw new Error(`fixture ${file} never rendered its host`);
}

const results = [];

// ── ARMING, PERFORMED INSIDE THE FLOOR'S OWN FIRST PROBE ─────────────────────
// The strongest form of "control the CONDITION, do not race a clock": the class
// that starts the animation is added in the SAME `Runtime.evaluate` that the
// floor takes its first measurement in. There is no gap between the two — not a
// CDP round trip, not a task boundary, not a frame — so the floor's opening
// verdict is always taken against a freshly-started animation, at any load.
//
// Arming in one evaluate and THEN running the floor (this file's previous
// shape) still left a gap: the arming evaluate returned, and the floor's probe
// was a SEPARATE round trip. Spend 280ms between the two — which a loaded
// runner does — and the animation is over before the floor ever looks, so the
// direction silently changes meaning. That residual is what reddened
// DIRECTION 2 on main eight times in eighteen runs (2026-08-24): it reported
// `settled in 3ms`, i.e. the floor found nothing to wait for, and then failed
// the assertion that demanded the settle narrate itself. Injecting the arming
// INTO the probe removes the gap instead of shrinking it, so neither direction
// can be decided by how busy the host was.
//
// `armJs` runs first, the probe expression second, and the row the probe
// returns is kept as `first` — the proof that the state under test really
// existed, read from the very measurement the floor acted on rather than from a
// second look at a page that has since moved on.
async function runFloorArmed(file, readyExpr, armJs, { cap = SETTLE_CAP_MS } = {}) {
  await load(file);
  let first = null;
  let armError = null;
  let armedOnce = false;
  const armingEvalJs = (expression) => {
    if (armedOnce) return evalJs(expression);
    armedOnce = true;
    return evalJs(`(function(){${armJs}\nreturn (${expression});})()`).then(
      (row) => {
        first = Array.isArray(row) ? row[0] : row;
        return row;
      },
      (e) => {
        // KEPT, NOT SWALLOWED. An arming script that throws produces the same
        // `first === null` as a floor that never probed, and the two have
        // opposite remedies — so the refusal below has to be able to tell them
        // apart instead of guessing.
        armError = e;
        throw e;
      },
    );
  };
  const t0 = Date.now();
  const lines = [];
  try {
    await assertReadyHostsPaint({
      url: `file://…/${file}`, readyExpr, evalJs: armingEvalJs, sleep, cap, log: (l) => lines.push(l),
    });
    return { ok: true, ms: Date.now() - t0, lines, first, armError };
  } catch (e) {
    return { ok: false, ms: Date.now() - t0, lines, first, armError, message: e.message };
  }
}

// THE PRECONDITION IS ESTABLISHED, NOT HOPED FOR — and a direction that could
// not establish it makes NO CLAIM.
//
// This is the cchi-w20 lesson turned on the instrument instead of the guard:
// zero matches means zero assertions ran, and a proof that ran zero assertions
// must never read as a pass. So an unestablished state exits 2 (an
// ENVIRONMENTAL refusal — "no claim is being made about the floor"), never 0
// and never 1. Every branch below is reachable by breaking the fixture, and
// each one names which half of the state was missing.
function requireArmedState(where, run) {
  const row = run && run.first;
  const why =
    run && run.armError
      ? `the arming expression itself threw in the page — ${String(run.armError.message).slice(0, 160)}`
      : !row
        ? "the floor never probed at all — its readyExpr derived no literal selector, so ZERO assertions ran"
        : row.matches === 0
          ? `the selector "${row.q}" matched NO nodes — zero hosts judged, which must never read as a pass`
          : row.rendered !== 0
            ? "the host was ALREADY PAINTED at the first probe — the state under test never existed"
            : (row.animations || []).length === 0
              ? "no animation was running at the first probe — the arming class did not start one"
              : null;
  if (!why) return;
  return vocab.refuse(
    `${where} could not be put into the state under test — ${why}.\n` +
    `   measured at the floor's OWN first probe: ${JSON.stringify(row)}\n` +
    `   The arming class must start the animation in the same evaluate that reads it;\n` +
    `   if that stopped being true, fix the fixture, not the cap.`,
  );
}

// The class that turns animating-triggered.html's inert host into an entering
// one. It is added inside the probe, never before it.
// NULL-SAFE ON PURPOSE. If the host vanished, the honest report is the floor's
// own measurement — "the selector matched NO nodes", the cchi-w20 shape — not a
// TypeError from the arming script, which describes the instrument rather than
// the page. requireArmedState refuses either way; only the diagnosis differs.
const ARM_ENTERING = "document.querySelector('.deploy-detail')?.classList.add('is-entering');";

async function runFloor(file, readyExpr, { cap = SETTLE_CAP_MS } = {}) {
  await load(file);
  const t0 = Date.now();
  const lines = [];
  try {
    await assertReadyHostsPaint({
      url: `file://…/${file}`, readyExpr, evalJs, sleep, cap, log: (l) => lines.push(l),
    });
    return { ok: true, ms: Date.now() - t0, lines };
  } catch (e) {
    return { ok: false, ms: Date.now() - t0, lines, message: e.message };
  }
}

// The raw measurement the fixtures' comments quote, printed so the proof's
// evidence is in its own output rather than only in a ledger row.
async function quoteProbe(file, sel) {
  await load(file);
  const [row] = await evalJs(paintProbeJs(readySelectorsFrom(`document.querySelector('${sel}')`)));
  return row;
}

const EXPECT = (name, cond, detail) => {
  results.push({ name, pass: !!cond, detail });
  process.stdout.write(`${cond ? "  ok  " : "  FAIL"}  ${name}\n        ${detail}\n`);
};

process.stdout.write("\n=== the moment of judgment, measured ===\n");
const at0 = await quoteProbe("animating.html", ".deploy-detail");
process.stdout.write(`  animating.html .deploy-detail -> ${JSON.stringify(at0)}\n`);
const gone = await quoteProbe("display-none.html", ".deploy-detail");
process.stdout.write(`  display-none.html .deploy-detail -> ${JSON.stringify(gone)}\n`);
const nested = await quoteProbe("nested-modal.html", "#a2f-error");
process.stdout.write(`  nested-modal.html #a2f-error -> ${JSON.stringify(nested)}\n`);
const zeroBox = await quoteProbe("zero-box.html", ".deploy-detail");
process.stdout.write(`  zero-box.html .deploy-detail -> ${JSON.stringify(zeroBox)}\n`);
const ancestor = await quoteProbe("ancestor-display-none.html", ".deploy-detail");
process.stdout.write(`  ancestor-display-none.html .deploy-detail -> ${JSON.stringify(ancestor)}\n`);

process.stdout.write("\n=== 1. DEFECT REPRODUCED: settle defeated (cap 0) on a screen that renders ===\n");
// THE PRECONDITION IS ESTABLISHED, NOT HOPED FOR.
//
// The first version of this direction loaded animating.html — whose animation
// starts on load — and trusted the probe to outrace a 280ms clock. That held
// locally and FAILED ON MAIN inside one run (console-harness 32690594539, job
// 97323534019): "it passed — the defect no longer reproduces, so this proof
// certifies nothing". On a loaded runner the navigation outlasted the
// animation, so the pre-fix path was handed a host that had already painted.
// A flaky anti-vacuous-green check is worse than none: it teaches the reader to
// re-run, which is exactly how the floor's own intermittency survived.
//
// The repair is the one this whole row is about — do not wait on a clock,
// control the CONDITION. animating-triggered.html leaves the animation INERT
// until `.is-entering` lands, so the navigation is paid FIRST and then the
// animation is started and READ IN THE SAME EVALUATE AS THE FLOOR'S OWN FIRST
// PROBE (runFloorArmed). Nothing can intervene between the two at any load, and
// no animation was lengthened to buy margin.
const d1 = await runFloorArmed("animating-triggered.html", "document.querySelector('.deploy-detail')", ARM_ENTERING, { cap: 0 });
process.stdout.write(`  armed in the floor's own probe -> ${JSON.stringify(d1.first)}\n`);
requireArmedState("direction 1 (settle defeated, cap 0)", d1);
EXPECT("the pre-fix code path REFUSES a perfectly-rendering screen", !d1.ok, d1.ok ? "it passed — the defect no longer reproduces, so this proof certifies nothing" : d1.message.slice(0, 200));
EXPECT("and the refusal quotes the computed opacity it judged on", !d1.ok && /computed opacity "0"/.test(d1.message), !d1.ok ? `refusal contains: ${(d1.message.match(/measured on the first match: [^.]+\./) || ["(nothing)"])[0]}` : "n/a");
EXPECT("on a host it also measured as LAID OUT — the box is not the problem", !d1.ok && /box 300x40/.test(d1.message), "box 300x40 present in the refusal");

process.stdout.write("\n=== 2. FIX: the same fixture, shipped cap ===\n");
// TWO CLAIMS, EACH TRUE AT ANY TIMING — which is the whole repair here.
//
// The single claim this replaced ran the floor against animating.html (whose
// animation starts on load) and demanded that the settle NARRATE itself. That
// narration only happens when the floor's opening probe catches a running
// animation, so the assertion was really asking "did the floor look before the
// 280ms animation ended?" — a question about the runner's load, not about the
// floor. On main it answered NO in 8 of 18 runs (`settled in 3ms … printed
// nothing`) and reddened a REQUIRED check on bytes nothing was wrong with.
//
// Worse, it contradicted direction 6, which asserts the OPPOSITE — that a
// settle with nothing to wait for prints nothing. Both cannot be right about
// the same fast host, so the flake was not merely noisy; one arm was wrong.
//
// 2a asks only what the fix actually promises for a natural on-load entry
// animation: it is MEASURED rather than refused. That holds whether the floor
// arrives mid-fade or after it — no narration is required, so nothing is being
// asked about the clock.
const d2 = await runFloor("animating.html", "document.querySelector('.deploy-detail')");
EXPECT("an animating host is MEASURED, not refused", d2.ok, d2.ok ? `settled in ${d2.ms}ms` : d2.message.slice(0, 200));

// 2b keeps the narration claim — it is worth keeping, because a settle that
// happened silently would make this whole fix invisible in a green run — but
// ESTABLISHES the animation instead of hoping for it. The arming class lands
// inside the floor's first probe, so there is always something running to
// settle on, and `requireArmedState` proves it from that same probe: if the
// host were already painted, or matched nothing, the direction refuses at
// exit 2 rather than passing or failing on a state it never had.
const d2b = await runFloorArmed("animating-triggered.html", "document.querySelector('.deploy-detail')", ARM_ENTERING);
process.stdout.write(`  armed in the floor's own probe -> ${JSON.stringify(d2b.first)}\n`);
requireArmedState("direction 2b (settle narrates, shipped cap)", d2b);
EXPECT("an ARMED animating host is MEASURED, not refused", d2b.ok, d2b.ok ? `settled in ${d2b.ms}ms` : d2b.message.slice(0, 200));
EXPECT("and the settle said so, once, naming the animation", d2b.ok && d2b.lines.length === 1 && /new-detail-in/.test(d2b.lines[0]), `${d2b.lines.length} line(s): ${(d2b.lines[0] || "(printed nothing)").trim()}`);

process.stdout.write("\n=== 3. THE MAIN-RUN SHAPE: host is a DESCENDANT of the animated element ===\n");
const d3 = await runFloor("nested-modal.html", "document.getElementById('a2f-error')");
EXPECT("a host inside an animating ancestor is MEASURED, not refused", d3.ok, d3.ok ? `settled in ${d3.ms}ms` : d3.message.slice(0, 300));

process.stdout.write("\n=== 4. THE HOLE STAYS SHUT ===\n");
const d4 = await runFloor("display-none.html", "document.querySelector('.deploy-detail')");
EXPECT("a display:none host still REFUSES with the shipped cap", !d4.ok, d4.ok ? "it PASSED — the settle traded a flake for a vacuous green" : d4.message.slice(0, 160));
EXPECT("and its refusal names display:none, not an animation", !d4.ok && /display:none/.test(d4.message) && /no animation running/.test(d4.message), "refusal names display:none and 'no animation running'");

process.stdout.write("\n=== 5. THE ZERO-BOX HALF, which checkVisibility alone does NOT catch ===\n");
// Measured: deleting `r.width>0&&r.height>0` from the probe leaves directions
// 1-4 fully green, because checkVisibility already reports display:none as
// invisible. This direction is the only one that reds — so without this fixture
// the floor's original defect (`0 <= 0` over 98 invisible pills) would have no
// standing proof at all.
const d5 = await runFloor("zero-box.html", "document.querySelector('.deploy-detail')");
EXPECT("a zero-area host REFUSES even though every CSS property is fine", !d5.ok, d5.ok ? "it PASSED — the zero-box test is gone and `0 <= 0` is clean again" : d5.message.slice(0, 140));
EXPECT("and checkVisibility would have called it visible — so the box test is doing the work", zeroBox.rendered === 0 && zeroBox.box === "0x0" && zeroBox.opacity === "1", `measured ${JSON.stringify(zeroBox)}`);

process.stdout.write("\n=== 6. THE SETTLE IS CONDITIONAL, NOT A BLANKET WAIT ===\n");
EXPECT("the display:none refusal spent no settle budget", !d4.ok && d4.ms < SETTLE_CAP_MS / 2, `refused in ${d4.ms}ms against a ${SETTLE_CAP_MS}ms cap`);
EXPECT("and printed no settle line — nothing was animating to wait for", d4.lines.length === 0, `${d4.lines.length} line(s) printed`);

process.stdout.write("\n=== 7. THE HOLE ONE LEVEL UP, and the clause that keeps it shut ===\n");
// WHY THIS FIXTURE EXISTS. The settle's second reason to wait is "this host has
// no layout box YET". The shape that most resembles it is a host whose ANCESTOR
// is display:none: getComputedStyle does not report "none" for a descendant of a
// hidden subtree, so the host reads display "block" with no layout box —
// character for character what a host the browser has not reached yet reports.
// The ONLY thing separating them is the document state, which is what
// `docReady !== "complete"` is for. Drop that clause and this is the single
// direction — and the single unit test — that reds.
const d7 = await runFloor("ancestor-display-none.html", "document.querySelector('.deploy-detail')");
EXPECT("a host hidden by an ANCESTOR still REFUSES", !d7.ok, d7.ok ? "it PASSED — the un-laid-out excuse reached the hole one level up" : d7.message.slice(0, 160));
EXPECT("and it spends no settle budget — the excuse expired when the document did", !d7.ok && d7.ms < SETTLE_CAP_MS / 2, `refused in ${d7.ms}ms against a ${SETTLE_CAP_MS}ms cap`);
EXPECT(
  "measured: NO layout box, own display \"block\", document complete — indistinguishable from the bug except by the document",
  ancestor.laidOut === false && ancestor.display === "block" && ancestor.docReady === "complete",
  `measured ${JSON.stringify(ancestor)}`,
);

const failed = results.filter((r) => !r.pass);
process.stdout.write(`\n${results.length - failed.length}/${results.length} checks passed\n`);
// A FAILED DIRECTION IS A MEASURED DEFECT, and it is the ONLY exit 1 this file
// has: the floor was exercised and behaved wrongly. Every other way out is a
// refusal, which is the asymmetry exit-vocabulary.mjs exists to keep.
if (failed.length) {
  await vocab.defect(`the floor behaved wrongly in: ${failed.map((f) => f.name).join("; ")}`);
}
await vocab.pass(
  "the defect reproduces on demand, the settle repairs it, and the display:none hole\n" +
  "the floor exists for still refuses on the first pass with no settle budget spent.",
);
