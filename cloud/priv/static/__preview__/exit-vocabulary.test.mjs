// exit-vocabulary.test.mjs — the rule, pinned.
//
// Every assertion here is a claim the module makes about CLASSIFICATION, not
// about wording. The wording tests exist only where the wording IS the contract
// (a refusal must say it made no claim, and must name what it declined to
// measure) — because the measured harm in this class is a MISDIRECTED READER,
// and the sentence is what misdirects them.
//
//   node --test cloud/priv/static/__preview__/exit-vocabulary.test.mjs

import { test } from "node:test";
import assert from "node:assert/strict";

import {
  EXIT_DEFECT,
  EXIT_OK,
  EXIT_REFUSED,
  REFUSED,
  createExitVocabulary,
  isRefusal,
  refusalError,
} from "./exit-vocabulary.mjs";

// A harness stand-in: captures what would have been written and what code would
// have been exited with, instead of doing either.
function harness(opts = {}) {
  const out = [];
  const err = [];
  const calls = { teardown: 0 };
  const sink = (bucket) => ({ write: (s) => { bucket.push(s); return true; } });
  const v = createExitVocabulary({
    instrument: "TEST GUARD",
    subject: "the-subject.css",
    teardown: async () => { calls.teardown++; },
    stdout: sink(out),
    stderr: sink(err),
    exit: (code) => { calls.code = code; return code; },
    ...opts,
  });
  return { v, out, err, calls, stdoutText: () => out.join(""), stderrText: () => err.join("") };
}

test("the three codes are the three claims, and they are distinct", () => {
  assert.equal(EXIT_OK, 0);
  assert.equal(EXIT_DEFECT, 1);
  assert.equal(EXIT_REFUSED, 2);
  assert.equal(new Set([EXIT_OK, EXIT_DEFECT, EXIT_REFUSED]).size, 3);
});

test("refuse() exits 2 and says NO claim is being made, naming the subject", async () => {
  const h = harness();
  await h.v.refuse("no Chrome on PATH");
  assert.equal(h.calls.code, EXIT_REFUSED);
  assert.match(h.stderrText(), /REFUSED TO MEASURE — no Chrome on PATH/);
  assert.match(h.stderrText(), /NO claim is being made about the-subject\.css/);
  assert.match(h.stderrText(), /not a clean bill and not an accusation/);
});

test("defect() exits 1 and is the only path that accuses the subject", async () => {
  const h = harness();
  await h.v.defect("3 selectors never reached the CSSOM");
  assert.equal(h.calls.code, EXIT_DEFECT);
  assert.match(h.stderrText(), /MEASURED DEFECT — 3 selectors never reached the CSSOM/);
  // The refusal's disclaimer must NOT appear on a defect: a defect IS a claim.
  assert.doesNotMatch(h.stderrText(), /NO claim is being made/);
});

test("pass() exits 0 on stdout, not stderr", async () => {
  const h = harness();
  await h.v.pass("every authored selector reached the CSSOM");
  assert.equal(h.calls.code, EXIT_OK);
  assert.match(h.stdoutText(), /TEST GUARD PASS/);
  assert.equal(h.stderrText(), "");
});

test("every exit tears down first — a refusal must not leak a browser", async () => {
  for (const drive of [
    (v) => v.refuse("x"),
    (v) => v.defect("y"),
    (v) => v.pass("z"),
    (v) => v.settle(new Error("boom")),
  ]) {
    const h = harness();
    await drive(h.v);
    assert.equal(h.calls.teardown, 1);
  }
});

// ── THE CLASSIFICATION, WHICH IS THE WHOLE POINT ────────────────────────────

test("a tagged refusal is recognised across a module boundary", () => {
  const err = refusalError("the baseline sidecar is missing");
  assert.ok(isRefusal(err));
  assert.equal(err[REFUSED], true);
  // Symbol.for, not Symbol() — a second, independently-obtained handle to the
  // same registry symbol must still match, which is what "across a module
  // boundary" means in practice.
  assert.ok(err[Symbol.for("barkpark.preview.refused-to-measure")]);
});

test("a ReferenceError is ALWAYS a refusal — the instrument never ran", () => {
  assert.ok(isRefusal(new ReferenceError("WebSocket is not defined")));
});

test("a plain Error is NOT a refusal by tag — but settle() still refuses on it", async () => {
  assert.equal(isRefusal(new Error("plain")), false);
  const h = harness();
  await h.v.settle(new Error("collection threw"));
  assert.equal(h.calls.code, EXIT_REFUSED, "an unexpected throw measured nothing, so it cannot be a defect");
  assert.match(h.stderrText(), /threw before it finished: collection threw/);
  assert.match(h.stderrText(), /this is NOT a defect finding/);
});

test("settle() on a TAGGED refusal quotes the reason without the 'threw' framing", async () => {
  const h = harness();
  await h.v.settle(refusalError("Chrome never came up after 3 attempts"));
  assert.equal(h.calls.code, EXIT_REFUSED);
  assert.match(h.stderrText(), /REFUSED TO MEASURE — Chrome never came up after 3 attempts/);
  assert.doesNotMatch(h.stderrText(), /threw before it finished/);
});

test("settle() NEVER produces exit 1 — an accusation must be a decision, not a default", async () => {
  for (const thrown of [
    new Error("plain"),
    new TypeError("x.y is not a function"),
    new ReferenceError("WebSocket is not defined"),
    refusalError("tagged"),
    "a bare string",
    null,
  ]) {
    const h = harness();
    await h.v.settle(thrown);
    assert.notEqual(h.calls.code, EXIT_DEFECT, `settle() must never accuse the subject (threw: ${String(thrown)})`);
    assert.equal(h.calls.code, EXIT_REFUSED);
  }
});

test("isRefusal is falsy-safe — a thrown null must not crash the classifier", () => {
  assert.equal(isRefusal(null), false);
  assert.equal(isRefusal(undefined), false);
  assert.equal(isRefusal(0), false);
});

// ── THE DRAIN, which is the bug a shared helper would otherwise propagate ────

test("a backpressured stream is drained before the exit, so a refusal is never truncated", async () => {
  const chunks = [];
  let drainHandler = null;
  const backpressured = {
    write: (s) => { chunks.push(s); return false; },              // buffer full
    once: (ev, fn) => { if (ev === "drain") drainHandler = fn; },
    on: (ev, fn) => { if (ev === "drain") drainHandler = fn; },
    removeListener: () => {},
    off: () => {},
  };
  const h = harness({ stderr: backpressured });
  const pending = h.v.refuse("something environmental");
  // Let the awaited teardown and the write actually run. Without this the
  // assertions below race the module's own first `await` and report a listener
  // that simply has not been registered YET — which is how this test failed the
  // first time it was written.
  await new Promise((r) => setImmediate(r));
  // The exit must NOT have happened yet — we are still waiting on drain.
  assert.equal(h.calls.code, undefined, "exited before the refusal was flushed");
  assert.ok(drainHandler, "no drain listener was registered");
  drainHandler();
  await pending;
  assert.equal(h.calls.code, EXIT_REFUSED);
  assert.match(chunks.join(""), /REFUSED TO MEASURE/);
});

test("the factory refuses to build a nameless instrument", () => {
  assert.throws(() => createExitVocabulary({}), /needs an `instrument` name/);
});
