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
//   2. FIX WORKS           animating.html (a natural on-load entry animation)
//                          with the shipped cap must PASS.
//   3. NESTED CASE         nested-modal.html — the host is a DESCENDANT of the
//                          animated element, which is the shape both `#a2f-error`
//                          main refusals had — must also PASS.
//   4. HOLE STAYS SHUT     display-none.html must still REFUSE, with the shipped
//                          cap, and its refusal must name display:none.
//   5. NO BUDGET WASTED    that refusal must arrive without spending the settle
//                          cap — proving the settle is CONDITIONAL on a running
//                          animation and not a blanket wait that greens
//                          everything eventually.
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
//   node cloud/priv/static/__preview__/fixtures/ready-host-paint/proof.mjs
//   CHROME=/path/to/chrome node …/proof.mjs

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

import { SETTLE_CAP_MS, assertReadyHostsPaint, paintProbeJs, readySelectorsFrom } from "../../ready-host-paint.mjs";
import { BRINGUP_ATTEMPTS, bringUpChrome, captureStderr } from "../../bringup-retry.mjs";

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

// A missing browser is an ENVIRONMENTAL refusal (exit 2), never a failed proof
// (exit 1) — the same discrimination overflow-guard.mjs makes, for the same
// reason: exit 1 here must mean "the floor behaved wrongly".
const chromeBin = findChrome();
if (!chromeBin) {
  process.stderr.write("!! PROOF (exit 2): no Chrome/Chromium found. Set CHROME=/path/to/chrome.\n");
  process.exit(2);
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
}).catch((e) => {
  process.stderr.write(`!! PROOF (exit 2): Chrome never came up — ${e.message}\n`);
  process.exit(2);
});

const chrome = brought.child;
process.once("exit", () => {
  try { chrome.kill("SIGKILL"); } catch { /* gone */ }
  for (const p of profiles) { try { fs.rmSync(p, { recursive: true, force: true }); } catch { /* best effort */ } }
});

const version = await (await fetch(`http://127.0.0.1:${brought.devPort}/json/version`)).json();
process.stdout.write(`>> chrome     ${version.Browser} · node ${process.version}\n`);
const ws = new WebSocket(version.webSocketDebuggerUrl);
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

// Judge the page AS IT STANDS, without navigating — used where the caller has
// already put the DOM into the exact state under test and a re-navigation would
// throw that state away and restart the race this proof exists to remove.
async function runFloorHere(readyExpr, { cap = SETTLE_CAP_MS } = {}) {
  const t0 = Date.now();
  const lines = [];
  try {
    await assertReadyHostsPaint({
      url: "file://…/animating-triggered.html", readyExpr, evalJs, sleep, cap, log: (l) => lines.push(l),
    });
    return { ok: true, ms: Date.now() - t0, lines };
  } catch (e) {
    return { ok: false, ms: Date.now() - t0, lines, message: e.message };
  }
}

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
// animation is started and READ IN THE SAME EVALUATE. Nothing can intervene
// between the two at any load, and no animation was lengthened to buy margin.
await load("animating-triggered.html");
const armed = await evalJs(
  `(function(){document.querySelector('.deploy-detail').classList.add('is-entering');` +
  `return (${paintProbeJs([".deploy-detail"])})[0];})()`,
);
process.stdout.write(`  armed in one task -> ${JSON.stringify(armed)}\n`);
// If the state could not be established, this direction makes NO CLAIM and says
// so as an environment refusal — it must never pass by accident, and it must
// never red as though the floor misbehaved.
if (!(armed.matches > 0 && armed.rendered === 0 && (armed.animations || []).length > 0)) {
  process.stderr.write(
    `!! PROOF (exit 2): could not put the host into the pre-fix state (unpainted WITH a running animation).\n` +
    `   measured: ${JSON.stringify(armed)}\n` +
    `   NO CLAIM is being made about the floor. Adding .is-entering must start the animation in the\n` +
    `   same task that reads it; if that stopped being true, fix the fixture, not the cap.\n`,
  );
  ws.close();
  process.exit(2);
}
const d1 = await runFloorHere("document.querySelector('.deploy-detail')", { cap: 0 });
EXPECT("the pre-fix code path REFUSES a perfectly-rendering screen", !d1.ok, d1.ok ? "it passed — the defect no longer reproduces, so this proof certifies nothing" : d1.message.slice(0, 200));
EXPECT("and the refusal quotes the computed opacity it judged on", !d1.ok && /computed opacity "0"/.test(d1.message), !d1.ok ? `refusal contains: ${(d1.message.match(/measured on the first match: [^.]+\./) || ["(nothing)"])[0]}` : "n/a");
EXPECT("on a host it also measured as LAID OUT — the box is not the problem", !d1.ok && /box 300x40/.test(d1.message), "box 300x40 present in the refusal");

process.stdout.write("\n=== 2. FIX: the same fixture, shipped cap ===\n");
const d2 = await runFloor("animating.html", "document.querySelector('.deploy-detail')");
EXPECT("an animating host is MEASURED, not refused", d2.ok, d2.ok ? `settled in ${d2.ms}ms` : d2.message.slice(0, 200));
EXPECT("and the settle said so, once, naming the animation", d2.ok && d2.lines.length === 1 && /new-detail-in/.test(d2.lines[0]), (d2.lines[0] || "(printed nothing)").trim());

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

const failed = results.filter((r) => !r.pass);
process.stdout.write(`\n${results.length - failed.length}/${results.length} checks passed\n`);
if (failed.length) {
  process.stderr.write(`\n!! PROOF FAILED — ${failed.map((f) => f.name).join("; ")}\n`);
  ws.close();
  process.exit(1);
}
process.stdout.write(
  "PROOF OK — the defect reproduces on demand, the settle repairs it, and the display:none hole\n" +
  "the floor exists for still refuses on the first pass with no settle budget spent.\n",
);
ws.close();
process.exit(0);
