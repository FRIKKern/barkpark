// ready-host-paint.test.mjs — the rendered-host floor, proven without a browser.
//
// What this file is FOR. The settle added by task-e72560e947dba4e6 is INVISIBLE
// in a green run: a screen that paints on the first pass never waits, and a
// screen that settles prints one extra line. So the only way the mechanics stay
// honest is a test that asserts them directly — that an animating host is
// MEASURED rather than refused, that a display:none host still REFUSES, that it
// refuses on the FIRST pass without spending the settle budget, and that a host
// which never settles refuses after the cap while NAMING the animation.
//
// The fail-closed assertions are the ones that matter: if this floor could ever
// return without a painting host, a required Console gate would go green over a
// screen nobody can see — which is the exact defect
// (cchi-w20-bl-guard-greens-when-its-hosts-disappear) it was built to catch.

import test from "node:test";
import assert from "node:assert/strict";

import {
  SETTLE_CAP_MS,
  assertReadyHostsPaint,
  paintProbeJs,
  paintRefusal,
  paintVerdict,
  readySelectorsFrom,
} from "./ready-host-paint.mjs";

// ── a harness that stands in for the browser and the clock ───────────────────
// `frames` is the script: one probe report per call to evalJs. The clock is
// VIRTUAL — `sleep` advances it rather than waiting — so a 1500ms cap costs the
// test nothing and the elapsed numbers the assertions read are exact.
function harness(frames, { cap = SETTLE_CAP_MS, poll = 50 } = {}) {
  let clock = 0;
  let calls = 0;
  const logged = [];
  const slept = [];
  const run = () =>
    assertReadyHostsPaint({
      url: "/?scen=empty&theme=light",
      readyExpr: "document.querySelector('.topbar')",
      evalJs: async () => {
        // The LAST frame repeats forever, so a "never settles" script is one
        // frame long and the cap — not the script's length — ends the loop.
        const f = frames[Math.min(calls, frames.length - 1)];
        calls += 1;
        return f;
      },
      sleep: async (ms) => { slept.push(ms); clock += ms; },
      now: () => clock,
      cap,
      poll,
      log: (l) => logged.push(l),
    });
  return { run, logged, slept, probes: () => calls, elapsed: () => clock };
}

const painting = (q = ".topbar") => [{ q, matches: 1, rendered: 1, box: "300x40", opacity: "1", animations: [] }];
const animating = (q = ".topbar") => [{ q, matches: 1, rendered: 0, box: "300x40", opacity: "0", animations: ["new-detail-in"] }];
const displayNone = (q = ".topbar") => [{ q, matches: 1, rendered: 0, box: "0x0", opacity: "1", animations: [] }];

// ── selector derivation ──────────────────────────────────────────────────────

test("literal selectors are derived from the leg's own readyExpr, in order", () => {
  assert.deepEqual(
    readySelectorsFrom("document.querySelector('.topbar') && document.getElementById('a2f-error')"),
    [".topbar", "#a2f-error"],
  );
});

test("a NEGATED selector is skipped — a leg waiting on absence must not be floored", () => {
  assert.deepEqual(readySelectorsFrom("!document.querySelector('.spinner')"), []);
});

test("a readyExpr with no literal selector derives nothing, and the floor is a no-op", async () => {
  const h = harness([displayNone()]);
  await assertReadyHostsPaint({
    url: "/x", readyExpr: "window.__ready === true",
    evalJs: async () => { throw new Error("the probe must never run with zero selectors"); },
    sleep: async () => {}, log: () => {},
  });
  assert.equal(h.probes(), 0);
});

// ── the verdict, which is the whole discrimination ───────────────────────────

test("a painting host is ok", () => {
  assert.equal(paintVerdict(painting()).kind, "ok");
});

test("an unpainted host WITH a running animation asks to settle", () => {
  assert.equal(paintVerdict(animating()).kind, "settle");
});

test("an unpainted host with NO animation refuses — the class the floor exists for", () => {
  const v = paintVerdict(displayNone());
  assert.equal(v.kind, "refuse");
  assert.equal(v.blame.q, ".topbar");
});

test("MIXED refuses and blames the non-animating host, never the animating one", () => {
  const v = paintVerdict([...animating(".modal"), ...displayNone("#a2f-error")]);
  assert.equal(v.kind, "refuse");
  assert.equal(v.blame.q, "#a2f-error", "the host with no animation is the one with a real defect");
});

test("a selector matching ZERO nodes is not a failure — an || arm whose twin satisfied the gate", () => {
  assert.equal(paintVerdict([{ q: ".absent", matches: 0, rendered: 0, animations: [] }]).kind, "ok");
});

// ── the settle: an animating host is MEASURED, not refused ───────────────────

test("an animating host that finishes its entry animation is MEASURED, not refused", async () => {
  // Two mid-animation frames, then it paints — the real sequence measured in
  // Chrome (opacity "0" → "0.674274" → "1" over ~300ms).
  const h = harness([animating(), animating(), painting()]);
  await h.run(); // must not throw
  assert.equal(h.probes(), 3, "it re-polled until the host painted");
  assert.ok(h.elapsed() < SETTLE_CAP_MS, "it settled well inside the cap");
});

test("the settle is ANNOUNCED once, naming the host and the animation", async () => {
  const h = harness([animating(), painting()]);
  await h.run();
  assert.equal(h.logged.length, 1, "said out loud exactly once, not once per poll");
  assert.match(h.logged[0], /settling/);
  assert.match(h.logged[0], /"\.topbar"/);
  assert.match(h.logged[0], /new-detail-in/);
});

test("a host that paints on the FIRST pass never sleeps — the green path pays nothing", async () => {
  const h = harness([painting()]);
  await h.run();
  assert.equal(h.probes(), 1);
  assert.deepEqual(h.slept, [], "no settle budget spent on a screen that was already up");
  assert.deepEqual(h.logged, [], "and nothing printed");
});

// ── FAIL-CLOSED: the hole the floor exists for stays shut ────────────────────

test("a display:none host still REFUSES — the floor's whole reason for existing", async () => {
  const h = harness([displayNone()]);
  await assert.rejects(h.run(), /READY HOST NOT PAINTED/);
});

test("a display:none host refuses on the FIRST pass, spending no settle budget", async () => {
  // If the settle were blanket rather than conditional on a running animation,
  // every genuine refusal would cost the full cap — and, worse, a remedy that
  // simply waited longer would be indistinguishable from one that waited for a
  // reason. This pins that the discrimination is real.
  const h = harness([displayNone()]);
  await assert.rejects(h.run());
  assert.equal(h.probes(), 1, "one probe, then refuse");
  assert.deepEqual(h.slept, [], "and not one millisecond of settle");
});

test("an INFINITE animation refuses at the cap rather than hanging the guard", async () => {
  // app.css ships five infinite animations (fresh-pulse, new-spin, live-breathe,
  // ov-pulse, deploy-rail-breathe). Awaiting `animation.finished` on one would
  // never resolve, so the guard would hang instead of refusing — a required
  // check that never reports is worse than one that reds.
  const h = harness([[{ q: ".fresh-dot", matches: 1, rendered: 0, box: "5x5", opacity: "0", animations: ["fresh-pulse"] }]]);
  await assert.rejects(h.run(), (e) => {
    assert.match(e.message, /READY HOST NOT PAINTED/);
    assert.match(e.message, /fresh-pulse/, "the refusal names the animation that never settled");
    return true;
  });
  assert.ok(h.elapsed() >= SETTLE_CAP_MS, "it spent the whole cap before giving up");
  assert.ok(h.elapsed() < SETTLE_CAP_MS + 200, "and stopped there — the cap is a cap");
});

test("the floor NEVER returns without a painting host, however long it is fed failures", async () => {
  // The single assertion that makes every green above worth reading: exhaust the
  // loop with a script that never paints and confirm it throws rather than
  // falling out of the while and returning.
  for (const frame of [displayNone(), animating()]) {
    const h = harness([frame]);
    await assert.rejects(h.run(), /READY HOST NOT PAINTED/);
  }
});

// ── the refusal string names the cause ───────────────────────────────────────

test("an animating refusal names the ANIMATION, not Chrome or the port", async () => {
  const msg = paintRefusal({ url: "/?scen=x", blame: animating()[0], waitedMs: 1500 });
  assert.match(msg, /new-detail-in/);
  assert.match(msg, /opacity: 0/, "it explains the from-keyframe mechanism");
  assert.match(msg, /computed opacity "0"/, "it quotes what it measured");
  assert.match(msg, /box 300x40/, "and that the host WAS laid out");
  assert.doesNotMatch(msg, /display:none/, "a host that is animating is not a display:none report");
});

test("a non-animating refusal still names display:none and friends", async () => {
  const msg = paintRefusal({ url: "/?scen=x", blame: displayNone()[0], waitedMs: 0 });
  assert.match(msg, /display:none/);
  assert.match(msg, /visibility:hidden/);
  assert.match(msg, /no animation running/);
  assert.match(msg, /box 0x0/);
  assert.doesNotMatch(msg, /mid-animation/, "nothing was animating; do not send the reader after one");
});

test("the refusal keeps the ledger ids so the next reader can find both rows", () => {
  const msg = paintRefusal({ url: "/x", blame: displayNone()[0], waitedMs: 0 });
  assert.match(msg, /cchi-w20-bl-guard-greens-when-its-hosts-disappear/);
  assert.match(msg, /task-e72560e947dba4e6/);
});

// ── the probe JS itself ──────────────────────────────────────────────────────

test("the probe keeps checkOpacity — dropping it re-opens visibility:hidden", () => {
  // A remedy that greened the animating case by deleting checkOpacity would
  // trade this flake for a vacuous green: visibility:hidden and
  // content-visibility:hidden keep the rect while checkVisibility reads false,
  // and both are MEASURED to be caught only by this flag.
  const js = paintProbeJs([".topbar"]);
  assert.match(js, /checkOpacity:true/);
  assert.match(js, /checkVisibilityCSS:true/);
});

test("the probe keeps the zero-box test — display:none's only tell", () => {
  assert.match(paintProbeJs([".topbar"]), /r\.width>0&&r\.height>0/);
});

test("the probe CLIMBS to ancestors — the majority case, and the one that broke this fix once", () => {
  // Caught by fixtures/ready-host-paint/proof.mjs against a real browser while
  // this fix was being written, which is why the fixture exists.
  //
  // `getAnimations({subtree:true})` returns the element's own animations and its
  // DESCENDANTS'. It does NOT climb. But two of the four observed main refusals
  // named `#a2f-error`, which does not animate — the `.modal` AROUND it carries
  // modal-in, and checkOpacity resolves against ANCESTOR opacity. Measured with
  // a subtree-only probe: box 297x20, opacity "1", animations [] — i.e. the
  // fix's own diagnosis said "nothing is animating" on the exact case it was
  // built for, and the floor refused it as a display:none.
  const js = paintProbeJs(["#a2f-error"]);
  assert.match(js, /parentElement/, "the probe must walk up, not only down");
  assert.match(js, /subtree:true/, "and still cover the host's own descendants");
});

test("the probe only counts RUNNING animations — a finished one explains nothing", () => {
  assert.match(paintProbeJs([".topbar"]), /playState==="running"/);
});
