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

// ── THE SHAPE MEASURED ON MAIN, console-harness run 33474373014 (2026-09-01) ──
// `READY HOST NOT PAINTED: ".topbar" … box 0x0, computed opacity "1", no
// animation running` at /?scen=empty&theme=light — a screen that renders
// perfectly. Reproduced 18 times in 20 navigations of the REAL preview page at
// load 6.45 on 10 cpus: app.css IS applied (`display: flex`, `height: 56px`,
// so the host CANNOT be 0x0 once laid out) and the host simply has no layout
// box yet, because `document.readyState` is still "loading". The three fields
// below are exactly what that probe returned.
const unlaidOut = (q = ".topbar") => [{ q, matches: 1, rendered: 0, box: "0x0", opacity: "1", animations: [], laidOut: false, display: "flex", docReady: "loading" }];
// The two shapes that must NOT be excused by the settle, each isolating ONE
// clause of the predicate. Both are measured: display-none.html reports
// laidOut false / display "none", zero-box.html reports laidOut TRUE — and both
// report docReady "complete", so each is here with docReady forced to "loading"
// to prove its OWN clause carries the refusal rather than the document state.
const hiddenWhileLoading = (q = ".topbar") => [{ q, matches: 1, rendered: 0, box: "0x0", opacity: "1", animations: [], laidOut: false, display: "none", docReady: "loading" }];
const zeroAreaWhileLoading = (q = ".topbar") => [{ q, matches: 1, rendered: 0, box: "0x0", opacity: "1", animations: [], laidOut: true, display: "block", docReady: "loading" }];
// THE HOLE ONE LEVEL UP, and the shape that most resembles the bug. An ANCESTOR
// is display:none, so the host's OWN computed display is its specified value —
// getComputedStyle does not report "none" for a descendant of a hidden subtree —
// and it has no layout box, exactly like a host the browser has not reached yet.
// Only the DOCUMENT separates them. Measured on the committed fixture
// ancestor-display-none.html in Chrome 152, 6/6 runs: docReady "complete",
// box 0x0, laidOut false, display "block".
const ancestorHidden = (q = ".topbar") => [{ q, matches: 1, rendered: 0, box: "0x0", opacity: "1", animations: [], laidOut: false, display: "block", docReady: "complete" }];

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

// ── THE UN-LAID-OUT HOST: the residual this floor still refused on main ──────
// The settle shipped by task-e72560e947dba4e6 is CONDITIONAL on a running
// animation. That closed the entry-animation half and left the other one open:
// a host with no layout box AT ALL and nothing animating took the fast refusal
// path — one probe, no settle, exit 2 — on a screen that paints 50ms later.

test("an un-laid-out host asks to SETTLE — no animation, but the document is still loading", () => {
  // The exact row measured on main. Before this clause it returned "refuse".
  assert.equal(paintVerdict(unlaidOut()).kind, "settle");
});

test("an un-laid-out host that gets its box is MEASURED, not refused", async () => {
  const h = harness([unlaidOut(), unlaidOut(), painting()]);
  await h.run(); // must not throw
  assert.equal(h.probes(), 3, "it re-polled until layout produced a box");
  assert.ok(h.elapsed() < SETTLE_CAP_MS, "and settled well inside the cap");
});

test("the settle announces an un-laid-out host by its REASON, not as an animation", async () => {
  const h = harness([unlaidOut(), painting()]);
  await h.run();
  assert.equal(h.logged.length, 1);
  assert.match(h.logged[0], /not laid out yet/);
  assert.match(h.logged[0], /"\.topbar"/);
  assert.doesNotMatch(h.logged[0], /mid-animation/, "nothing was animating; do not say it was");
});

// ── THE HONEST REFUSAL SURVIVES — each clause proven to carry it alone ───────

test("a host that NEVER gets a layout box still REFUSES, at the cap", async () => {
  // The load-dependent flake is removed by WAITING, never by excusing. A page
  // that genuinely never lays its host out spends the cap and then refuses —
  // the guard keeps its ability to say "I will not certify this screen".
  const h = harness([unlaidOut()]);
  await assert.rejects(h.run(), /READY HOST NOT PAINTED/);
  assert.ok(h.elapsed() >= SETTLE_CAP_MS, "it spent the whole cap before giving up");
  assert.ok(h.elapsed() < SETTLE_CAP_MS + 200, "and stopped there — the cap is a cap");
});

test("display:none REFUSES ON THE FIRST PASS even while the document is loading", async () => {
  // THE HOLE, pressed at its most dangerous angle. If the excuse were "no box
  // and the document is not complete", the class this floor exists for would
  // walk straight through it during any slow load. The `display !== "none"`
  // clause is what stops that, and this is the test that reds without it.
  const h = harness([hiddenWhileLoading()]);
  await assert.rejects(h.run(), /READY HOST NOT PAINTED/);
  assert.equal(h.probes(), 1, "one probe, then refuse");
  assert.deepEqual(h.slept, [], "and not one millisecond of settle");
});

test("a zero-AREA host that IS laid out REFUSES on the first pass, loading or not", async () => {
  // zero-box.html measured: laidOut TRUE, display "block", every CSS property
  // fine. Layout has already run and decided this host gets no area — that is
  // the original `0 <= 0` defect, not a page that has not rendered yet. The
  // `laidOut === false` clause is what keeps them apart, and this test reds
  // without it.
  const h = harness([zeroAreaWhileLoading()]);
  await assert.rejects(h.run(), /READY HOST NOT PAINTED/);
  assert.equal(h.probes(), 1, "one probe, then refuse");
  assert.deepEqual(h.slept, [], "and not one millisecond of settle");
});

test("a probe report carrying NONE of the new fields behaves exactly as before", async () => {
  // FAIL-CLOSED BY CONSTRUCTION. Every clause must be explicitly present AND
  // affirmative to excuse a host, so a report that predates them — or one from
  // a probe whose getComputedStyle threw — refuses on the first pass, as it
  // always did. Absence of evidence is never an excuse here.
  const h = harness([displayNone()]);
  await assert.rejects(h.run(), /READY HOST NOT PAINTED/);
  assert.equal(h.probes(), 1);
  assert.deepEqual(h.slept, []);
});

test("MIXED refuses and blames the host with NO excuse, animating or un-laid-out", async () => {
  const v = paintVerdict([...animating(".modal"), ...unlaidOut("#shell"), ...displayNone("#a2f-error")]);
  assert.equal(v.kind, "refuse");
  assert.equal(v.blame.q, "#a2f-error", "the only host with no reason to still be coming");
});

// ── the third refusal wording, and its disjointness from the other two ───────

test("an un-laid-out refusal names the DOCUMENT, not display:none and not an animation", async () => {
  const msg = paintRefusal({ url: "/?scen=empty&theme=light", blame: unlaidOut()[0], waitedMs: SETTLE_CAP_MS });
  assert.match(msg, /never got a layout box/);
  assert.match(msg, /"loading"/, "it quotes the document state it measured");
  assert.match(msg, /box 0x0/);
  assert.doesNotMatch(msg, /display:none/, "the host is display flex; do not send the reader after display:none");
  assert.doesNotMatch(msg, /mid-animation/, "nothing was animating either");
});

test("the other two refusals do NOT claim a missing layout box", () => {
  // Three causes, three disjoint wordings — so no refusal can send the next
  // reader after another one's cause. That is the same property the animating
  // and display:none wordings already had, extended to the third.
  assert.doesNotMatch(paintRefusal({ url: "/x", blame: animating()[0], waitedMs: 1500 }), /never got a layout box/);
  assert.doesNotMatch(paintRefusal({ url: "/x", blame: displayNone()[0], waitedMs: 0 }), /never got a layout box/);
});

// ── the probe gathers the new fields ON THE SAME PASS ────────────────────────

test("the probe reads layout, display and readyState in the SAME evaluate as the box", () => {
  // ARM INSIDE THE MEASUREMENT. Reading document.readyState in a second
  // round trip would judge the box from one moment against a document state
  // from another — the exact race this whole row is about. One evaluate, one
  // moment, or the discrimination is a guess.
  const js = paintProbeJs([".topbar"]);
  assert.match(js, /getClientRects\(\)\.length>0/, "layout is asked about directly, not inferred from the box");
  assert.match(js, /document\.readyState/);
  assert.match(js, /getComputedStyle\(el\)\.display/);
  assert.equal(js.split("Runtime").length, 1, "it is one expression, not a script that round-trips");
});

test("a host hidden by an ANCESTOR refuses on the first pass once the document is complete", async () => {
  // THE CLAUSE THAT ONLY THIS TEST DEFENDS. Drop `docReady !== "complete"` from
  // notLaidOutYet and every other test in this file stays green — because no
  // other frame is un-laid-out, not itself display:none, AND finished loading.
  // This is that frame, taken from a real browser, and without it the excuse
  // would never expire: the floor would spend its whole cap on a screen it
  // should refuse instantly, and during any slow load would excuse it outright.
  const h = harness([ancestorHidden()]);
  await assert.rejects(h.run(), /READY HOST NOT PAINTED/);
  assert.equal(h.probes(), 1, "one probe, then refuse");
  assert.deepEqual(h.slept, [], "and not one millisecond of settle");
});

test("an ancestor-hidden host is a display:none report, not a layout-box one", () => {
  // Its own display reads "block", so the refusal cannot say "display is not
  // none" at it — the reader must still be sent to the display:none family.
  const msg = paintRefusal({ url: "/x", blame: ancestorHidden()[0], waitedMs: 0 });
  assert.match(msg, /display:none/);
  assert.doesNotMatch(msg, /never got a layout box/);
  assert.doesNotMatch(msg, /mid-animation/);
});
