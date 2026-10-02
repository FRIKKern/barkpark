// attach-deadline.test.mjs — the arms for task-3eda8d2ebb0b2327.
//
// An arm about a HANG has to terminate, so every one of these drives a
// never-settling promise on an INJECTED clock rather than a real one. A suite
// that proved the deadline by actually waiting 30s would be the defect it is
// testing for.

import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { ATTACH_CAP, AttachTimeout, withAttachDeadline } from "./attach-deadline.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const GUARD = fs.readFileSync(path.join(HERE, "overflow-guard.mjs"), "utf8");

/** A clock the test drives by hand. `fire()` runs whatever is pending. */
function fakeClock() {
  const timers = new Map();
  let id = 0;
  return {
    cleared: [],
    setTimer(fn, ms) { const h = { id: ++id, fn, ms, unref() { return this; } }; timers.set(h.id, h); return h; },
    clearTimer(h) { if (h) { this.cleared.push(h.id); timers.delete(h.id); } },
    pending() { return [...timers.values()]; },
    fire() { for (const h of [...timers.values()]) { timers.delete(h.id); h.fn(); } },
  };
}

const NEVER = new Promise(() => {});

test("THE DEFECT, in one arm: a promise that never settles REFUSES by name instead of hanging", async () => {
  const clock = fakeClock();
  const p = withAttachDeadline(NEVER, {
    step: "Target.createTarget", ms: 30000,
    setTimer: clock.setTimer.bind(clock), clearTimer: clock.clearTimer.bind(clock),
  });
  assert.equal(clock.pending().length, 1, "the deadline must be ARMED before the work is awaited, or the race is a coin flip");
  assert.equal(clock.pending()[0].ms, 30000);
  clock.fire();
  const err = await p.then(() => null, (e) => e);
  assert.ok(err instanceof AttachTimeout, "a deaf debugger must produce an AttachTimeout, not a pending promise");
  assert.equal(err.attachTimeout, true, "the caller routes on the FLAG, never on the message — message sniffing is how a refusal becomes a defect");
  assert.equal(err.refused, true, "and it is a REFUSAL, the same class bringup-retry.mjs raises one step earlier");
  assert.equal(err.step, "Target.createTarget");
  assert.equal(err.ms, 30000);
  // THE NAMING IS THE POINT: "the guard timed out" tells a reviewer nothing.
  assert.match(err.message, /ATTACH TIMEOUT/);
  assert.match(err.message, /Target\.createTarget/, "the refusal must NAME the step, or it cannot be told from any other timeout");
  assert.match(err.message, /30000ms/, "and state the budget it outlived");
  assert.match(err.message, /Environment, not CSS/, "the class has to be stated: nothing was measured, so this is no claim about a stylesheet");
  assert.match(err.message, /OVERFLOW_GUARD_ATTACH_CAP/, "a refusal a loaded box cannot act on is a dead end");
});

test("NOT VACUOUS: a step that answers in time yields its VALUE and the deadline never fires", async () => {
  const clock = fakeClock();
  const v = await withAttachDeadline(Promise.resolve({ targetId: "T1" }), {
    step: "Target.createTarget",
    setTimer: clock.setTimer.bind(clock), clearTimer: clock.clearTimer.bind(clock),
  });
  assert.deepEqual(v, { targetId: "T1" }, "the wrapper must be transparent on the healthy path — every attach on every green run rides it");
  assert.equal(clock.pending().length, 0, "and the timer must be CLEARED: an un-cleared Node timer holds the event loop open, which converts a hang before the legs into a hang after them");
  assert.equal(clock.cleared.length, 1);
});

test("a step that FAILS keeps its own error — the deadline never relabels a real transport fault", async () => {
  const clock = fakeClock();
  const boom = Object.assign(new Error("CDP connect failed: ws://127.0.0.1:0/"), { method: "connect" });
  const err = await withAttachDeadline(Promise.reject(boom), {
    step: "websocket open",
    setTimer: clock.setTimer.bind(clock), clearTimer: clock.clearTimer.bind(clock),
  }).then(() => null, (e) => e);
  assert.equal(err, boom, "a debugger that REFUSED the connection already said why; wrapping it as a timeout would lose the reason");
  assert.ok(!(err instanceof AttachTimeout));
  assert.equal(clock.pending().length, 0, "and its timer is cleared too");
});

test("the clock cannot win TWICE, and cannot win after the work already did", async () => {
  const clock = fakeClock();
  let settle;
  const p = withAttachDeadline(new Promise((r) => { settle = r; }), {
    step: "Runtime.enable",
    setTimer: clock.setTimer.bind(clock), clearTimer: clock.clearTimer.bind(clock),
  });
  settle("ok");
  assert.equal(await p, "ok");
  clock.fire();                      // a timer that somehow survived
  assert.equal(await p, "ok", "a late timer must not be able to reject an already-resolved attach");
});

test("the default cap is a DECISION, and it is far above any healthy attach", () => {
  assert.ok(Number.isFinite(ATTACH_CAP) && ATTACH_CAP > 0, "an unbounded or NaN cap is the defect with extra steps");
  // The symptom this was filed for is ~10 CONCURRENT guards on one box: a real
  // attach under load is SLOW, not dead. A tight deadline would convert load
  // into a refusal, which is a new lie pointing the other way.
  assert.ok(ATTACH_CAP >= 15000, `the attach cap (${ATTACH_CAP}ms) must be at least as generous as the bring-up polls it follows, or load becomes a refusal`);
});

// ── THE WIRING, ASSERTED IN THE GUARD'S OWN BYTES ────────────────────────────
//
// A deadline module nothing calls is the same hang with a green suite over it,
// so these arms read overflow-guard.mjs rather than trusting that it imports
// this file.

test("EVERY attach step in overflow-guard.mjs is inside the deadline", () => {
  assert.match(GUARD, /from "\.\/attach-deadline\.mjs"/, "the guard must import the deadline it is supposed to be bounded by");
  // The attach block: from the /json/version fetch to the last enable.
  const start = GUARD.indexOf("const attach = (step, work)");
  const end = GUARD.indexOf("CDP bring-up failed:");
  assert.ok(start > 0 && end > start, "the attach block must still be findable — if this fails the block moved and these arms need re-aiming, which is the point of failing loudly");
  const block = GUARD.slice(start, end);
  // Every CDP round trip on the attach path, by name.
  for (const step of ["Target.createTarget", "Target.attachToTarget", "Runtime.enable", "Page.enable", "Network.enable", "Network.setCacheDisabled"]) {
    assert.ok(block.includes(step), `the attach block must still drive ${step}`);
  }
  // The block funnels every step through a local `attach(step, work)`, and that
  // helper must be the deadline itself — a local named `attach` that forwarded
  // its work unwrapped would satisfy a call count and bound nothing.
  assert.match(GUARD, /const attach = \(step, work\) => withAttachDeadline\(work, \{ step \}\);/,
    "the local attach() helper must BE withAttachDeadline; a pass-through with the same name is the hang wearing the fix's clothes");
  const sends = block.match(/cdp\.send\(/g) || [];
  const bounded = block.match(/await attach\(/g) || [];
  assert.ok(sends.length >= 6, `expected the six attach sends, found ${sends.length}`);
  // fetch + connect + every send.
  assert.ok(bounded.length >= sends.length + 2,
    `${sends.length} cdp.send call(s) plus the fetch and the websocket open must ALL be bounded; found ${bounded.length} bounded await(s). An attach step outside the deadline is the original hang, narrowed.`);
});

test("the /json/version fetch carries its own abort signal — a deadline does not cancel a socket", () => {
  const i = GUARD.indexOf("/json/version");
  const line = GUARD.slice(i - 200, i + 300);
  assert.match(line, /AbortSignal\.timeout/,
    "withAttachDeadline rejects but cannot close an fd; an un-aborted fetch keeps the handle and, without process.exit, the refusal would print over a live socket");
});

test("the timeout reaches the guard's OWN refusal vocabulary, not a stack trace", () => {
  // die() writes `!! OVERFLOW GUARD: <msg>` — the one prefix
  // scripts/console-refusal-capture.mjs trusts without an `(exit 2)` marker.
  const i = GUARD.indexOf("CDP bring-up failed:");
  const around = GUARD.slice(i - 900, i + 400);
  assert.match(around, /attachTimeout/,
    "the catch has to tell an attach TIMEOUT from a transport THROW: they are both exit 2 but only one of them means 'nobody answered'");
  assert.match(around, /return die\(/, "and both must leave through die(), which is what publishes the capturable prefix");
});
