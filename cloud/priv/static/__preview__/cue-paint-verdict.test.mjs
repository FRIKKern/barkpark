// cue-paint-verdict.test.mjs — every branch of the D253 cue predicate, driven
// WITHOUT a browser. The predicate used to live twice inside overflow-guard.mjs
// where the only way to exercise it was a full headless Chrome run, so no
// clause had ever been driven in isolation and a dropped clause would have been
// invisible until it certified a clipped screen.
import test from "node:test";
import assert from "node:assert/strict";
import { cuePaints, cueWhy, CUE_METRICS_FN } from "./cue-paint-verdict.mjs";

// The shape the browser side hands back for a box that clips an unbreakable
// run: the ONE record on which a cue really does paint.
const paints = { sw: 408, cw: 200, mw: 303, tw: 303, ws: "nowrap", te: "ellipsis", ov: "hidden", ox: "hidden", t: "a@b.example" };

test("all four clauses met — the cue paints", () => {
  assert.equal(cuePaints(paints), true);
});

test("white-space is NOT the test (D253): `normal` with an unbreakable run still paints", () => {
  assert.equal(cuePaints({ ...paints, ws: "normal" }), true);
});

test("(2) overflow-x visible — no marker is ever reached, and the reason says so", () => {
  const n = { ...paints, ox: "visible", ov: "visible clip" };
  assert.equal(cuePaints(n), false);
  assert.match(cueWhy(n), /does not clip horizontally/);
  assert.match(cueWhy(n), /overflow-x "visible"/);
  // Read on the X AXIS by name (cch-w29-s3): the shorthand serialises a pair
  // the spec does not blockify, so the shorthand alone would have exempted this.
  assert.match(cueWhy(n), /shorthand "visible clip"/);
});

test("(1) text-overflow clip — nothing is authored to paint", () => {
  const n = { ...paints, te: "clip" };
  assert.equal(cuePaints(n), false);
  assert.match(cueWhy(n), /computed text-overflow is "clip"/);
});

test("(3) a break opportunity FITS — the overflow is vertical and hidden eats lines", () => {
  const n = { ...paints, mw: 42 };
  assert.equal(cuePaints(n), false);
  assert.match(cueWhy(n), /min-content 42px FITS inside clientWidth 200px/);
  assert.match(cueWhy(n), /VERTICAL/);
});

test("(3) min-content EQUAL to the box does not count as no-break-fits", () => {
  assert.equal(cuePaints({ ...paints, mw: 200 }), false);
});

test("a min-content clone that failed to measure (mw 0) FLAGS rather than exempts", () => {
  const n = { ...paints, mw: 0 };
  assert.equal(cuePaints(n), false);
  assert.match(cueWhy(n), /min-content 0px FITS/);
});

test("(4) an atomic-inline-only line has no run to truncate", () => {
  const n = { ...paints, tw: 0 };
  assert.equal(cuePaints(n), false);
  assert.match(cueWhy(n), /no text run to truncate \(widest run 0px\)/);
});

test("the reason names the FIRST failing clause, never a later coincidence", () => {
  // Both (2) and (4) fail here. Blaming the text run would tell the reader to
  // go looking for content when the box was never going to clip.
  const n = { ...paints, ox: "visible", tw: 0 };
  assert.match(cueWhy(n), /does not clip horizontally/);
});

test("CUE_METRICS_FN is a parenthesised function expression that COMPILES", () => {
  // `node --check` cannot see inside a string: a mis-escaped regex or a dropped
  // paren in the browser-side source is a runtime `page eval threw` 40 minutes
  // into a headless run. Compiling it here is the cheapest place to find out.
  const fn = new Function(`return ${CUE_METRICS_FN}`)();
  assert.equal(typeof fn, "function");
  assert.equal(fn.length, 1);
});

test("CUE_METRICS_FN keeps the escapes that only a runtime would have caught", () => {
  // In a template literal `\s` collapses to `s`, so the whitespace-collapsing
  // regex must be written `\\s` in the source. A silent collapse would make the
  // printed row identity `/s+/g`-collapsed — wrong text in every failure line.
  assert.ok(CUE_METRICS_FN.includes("/\\s+/g"));
  // cssText is APPENDED (`+=`), never assigned: an assignment deletes the
  // copied style attribute and measures the clone under a cascade it lacks.
  assert.ok(CUE_METRICS_FN.includes("cl.style.cssText+="));
  // The clone is measured at `width:min-content` and detached again.
  assert.ok(CUE_METRICS_FN.includes("width:min-content!important"));
  assert.ok(CUE_METRICS_FN.includes("cl.parentNode.removeChild(cl)"));
  // The text walk descends through inline/contents only — an inline-block child
  // is an atom, which is the whole point of clause (4).
  assert.ok(CUE_METRICS_FN.includes("dd==='inline'||dd==='contents'"));
  // overflow-x is captured BY NAME alongside the shorthand.
  assert.ok(CUE_METRICS_FN.includes("ox:cs.overflowX"));
  assert.ok(CUE_METRICS_FN.includes("ov:cs.overflow,"));
});
