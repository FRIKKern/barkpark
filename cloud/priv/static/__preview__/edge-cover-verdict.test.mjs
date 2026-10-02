// edge-cover-verdict.test.mjs — the arms for task-ca6e4c883c85e854.
//
// TWO FIXTURES, ONE PER MECHANISM, and each one asserts BOTH halves: that its
// own sentence is chosen AND that the other's is not. A test that only checks
// "the topbar arm says topbar" would still pass on the shipped code, because
// the shipped code said "corner" for everything — it also said "corner" when
// the corner was short. Only the NEGATIVE half separates the two.
//
// The fixtures are the real numbers off the 2026-09-10 incident where they
// exist: cornerH == headH == 55, tall.top 69.5 -> 41.5 across a 56px sticky
// topbar, covering element "topbar-scope".

import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { edgeCovered, edgeCoverSentence, edgeMechanisms } from "./edge-cover-verdict.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const GUARD = fs.readFileSync(path.join(HERE, "overflow-guard.mjs"), "utf8");

const CORNER_WORDS = "shorter than the TALLEST column";
const TOPBAR_WORDS = "SCROLLED UNDER THE STICKY TOPBAR";

// ── THE FIXTURES ─────────────────────────────────────────────────────────────

// ARM A — a SHORTENED CORNER. The regression this leg was born to catch:
// `.set-matrix-corner` from `align-self: stretch` to `align-self: center;
// height: 40px` leaves 7.5px of a 55px heading uncovered top and bottom. The
// header row is well clear of the topbar, so only one mechanism is live.
const SHORT_CORNER = {
  edge: "set-matrix-col",
  cornerH: 40,
  headH: 55,
  tallTop: 220.5,
  topbarBottom: 56,
  probeY: 222.5,
  scrollY: 812,
  edgeInTopbar: false,
};

// ARM B — the matrix CENTRED UNDER THE TOPBAR, i.e. app.css without
// `scroll-margin-top` on `.set-matrix`. The corner is exactly the header row;
// nothing about it changed. `scrollIntoView({block:'center'})` put the header
// row at 41.5, which is 14.5px above the sticky 56px topbar's bottom edge.
const UNDER_TOPBAR = {
  edge: "topbar-scope",
  cornerH: 55,
  headH: 55,
  tallTop: 41.5,
  topbarBottom: 56,
  probeY: 43.5,
  scrollY: 784,
  edgeInTopbar: true,
};

// ── ARM A: THE CORNER ────────────────────────────────────────────────────────

test("a shortened corner prints the CORNER sentence and not the topbar one", () => {
  const s = edgeCoverSentence(SHORT_CORNER);
  assert.ok(s, "an uncovered probe point must produce a sentence");
  assert.match(s, /shorter than the TALLEST column/);
  assert.ok(!s.includes(TOPBAR_WORDS), `the topbar mechanism must NOT be named here:\n${s}`);
  assert.match(s, /cornerH 40 < headH 55/, "and the numbers that chose it are printed");
});

test("MUTATION: make the corner tall enough and the corner sentence is gone", () => {
  // The same fixture with cornerH raised to the header row's height: the probe
  // point is still uncovered (edge unchanged), so a sentence is still owed —
  // but it must no longer accuse the corner. This is the exact state the
  // shipped code could not represent.
  const s = edgeCoverSentence({ ...SHORT_CORNER, cornerH: 55 });
  assert.ok(s, "still uncovered, still a failure");
  assert.ok(!s.includes(CORNER_WORDS), `the corner is innocent at 55/55:\n${s}`);
  assert.match(s, /NEITHER mechanism measures true/);
  assert.match(s, /CANNOT NAME the mechanism/);
});

// ── ARM B: THE TOPBAR ────────────────────────────────────────────────────────

test("THE 2026-09-10 INCIDENT: a header row under the sticky topbar prints the TOPBAR sentence, not the corner one", () => {
  const s = edgeCoverSentence(UNDER_TOPBAR);
  assert.ok(s);
  assert.match(s, /SCROLLED UNDER THE STICKY TOPBAR/);
  assert.match(s, /tall\.top 41\.5 < topbar bottom 56/);
  assert.match(s, /scroll-margin-top on \.set-matrix, NOT a taller corner/);
  // THE HALF THAT WOULD HAVE CAUGHT IT: the shipped sentence said exactly this
  // against exactly these numbers.
  assert.ok(!s.includes(CORNER_WORDS), `the corner mechanism must NOT be named at 55/55:\n${s}`);
  assert.match(s, /The corner is INNOCENT: 55px covers the full 55px row/);
});

test("MUTATION: scroll the matrix clear of the topbar and the topbar sentence is gone", () => {
  // `scroll-margin-top: 56px` on `.set-matrix` is exactly this delta: the same
  // header row centred 56px lower. tall.top 97.5 >= topbar bottom 56.
  const s = edgeCoverSentence({ ...UNDER_TOPBAR, tallTop: 97.5, probeY: 99.5, edge: "set-matrix-col", edgeInTopbar: false });
  assert.ok(s, "the probe point is still uncovered in this fixture, so a sentence is owed");
  assert.ok(!s.includes(TOPBAR_WORDS), `the topbar is clear at tall.top 97.5:\n${s}`);
  assert.match(s, /NEITHER mechanism measures true/);
});

test("and when the corner DOES cover the point there is no sentence at all", () => {
  assert.equal(edgeCoverSentence({ ...UNDER_TOPBAR, edge: "set-matrix-corner" }), null);
  assert.equal(edgeCovered("set-matrix-corner sticky"), true);
  assert.equal(edgeCovered("topbar-scope"), false);
  assert.equal(edgeCovered(null), false, "a null hit-test is not a cover");
});

// ── THE TWO REFUSALS ─────────────────────────────────────────────────────────

test("BOTH mechanisms true is an admission, not a choice", () => {
  const s = edgeCoverSentence({ ...UNDER_TOPBAR, cornerH: 40 });
  assert.match(s, /BOTH mechanisms measure TRUE/);
  assert.match(s, /CANNOT tell which one covers the point/);
  // It still names both conditions with their numbers — an admission that
  // withholds the measurement is no better than a guess.
  assert.match(s, /40 < 55/);
  assert.match(s, /tall\.top 41\.5 < 56/);
});

test("a page with no .topbar leaves the topbar half UNMEASURED, never cleared", () => {
  const m = { ...UNDER_TOPBAR, topbarBottom: null };
  assert.equal(edgeMechanisms(m).underTopbar, null, "null, not false — nothing was measured");
  const s = edgeCoverSentence(m);
  assert.match(s, /sticky \.topbar bottom ABSENT \(unmeasured\)/);
  assert.match(s, /NOT MEASURED \(no \.topbar on the page\)/);
  assert.ok(!s.includes(TOPBAR_WORDS));
  assert.ok(!s.includes(CORNER_WORDS));
});

// ── THE MEASUREMENT BLOCK IS ALWAYS THERE ────────────────────────────────────

test("every arm prints covering element, probe y, topbar bottom, tall.top and scrollY", () => {
  const arms = [
    SHORT_CORNER,
    UNDER_TOPBAR,
    { ...UNDER_TOPBAR, cornerH: 40 },
    { ...SHORT_CORNER, cornerH: 55 },
  ];
  for (const m of arms) {
    const s = edgeCoverSentence(m);
    assert.match(s, new RegExp(`covered by "${m.edge}"`), `covering element missing:\n${s}`);
    assert.match(s, new RegExp(`at y=${String(m.probeY).replace(".", "\\.")}\\b`), `probe y missing:\n${s}`);
    assert.match(s, new RegExp(`tall\\.top ${String(m.tallTop).replace(".", "\\.")}`), `tall.top missing:\n${s}`);
    assert.match(s, new RegExp(`topbar bottom ${m.topbarBottom}`), `topbar bottom missing:\n${s}`);
    assert.match(s, new RegExp(`scrollY ${m.scrollY}`), `scrollY missing:\n${s}`);
  }
});

// ── THE TOLERANCE ────────────────────────────────────────────────────────────

test("sub-pixel noise does not flip which mechanism a red accuses", () => {
  // The 0.5px tolerance is the guard's own, matching the `cornerH < headH - 0.5`
  // height arm at the call site.
  assert.equal(edgeMechanisms({ cornerH: 54.8, headH: 55, tallTop: 200, topbarBottom: 56 }).cornerShort, false);
  assert.equal(edgeMechanisms({ cornerH: 54.4, headH: 55, tallTop: 200, topbarBottom: 56 }).cornerShort, true);
  assert.equal(edgeMechanisms({ cornerH: 55, headH: 55, tallTop: 55.8, topbarBottom: 56 }).underTopbar, false);
  assert.equal(edgeMechanisms({ cornerH: 55, headH: 55, tallTop: 55.4, topbarBottom: 56 }).underTopbar, true);
});

// ── THE CALL SITE — RECOUNTED, NOT ASSUMED ───────────────────────────────────
// width-drivers.test.mjs's shape: a helper nobody calls is a helper that proves
// nothing, and the sentence being TYPED at the call site is precisely the
// defect. Both halves are read out of overflow-guard.mjs on every run.

test("overflow-guard.mjs calls this helper and no longer types the sentence itself", () => {
  assert.match(GUARD, /import \{ edgeCoverSentence \} from "\.\/edge-cover-verdict\.mjs";/);
  assert.match(GUARD, /const edgeSentence = edgeCoverSentence\(mid\);/);
  assert.match(GUARD, /if \(edgeSentence\) fail\(D, /);
  const live = GUARD.split("\n").filter((l) => !l.trim().startsWith("//")).join("\n");
  assert.ok(
    !live.includes("a corner shorter than the TALLEST column leaves the heading"),
    "the hard-typed one-mechanism sentence is back in the guard's executable bytes",
  );
});

test("the W12 mid read hands back every input the verdict needs", () => {
  for (const field of ["tallTop", "probeY", "scrollY", "topbarBottom", "edgeInTopbar"]) {
    assert.match(GUARD, new RegExp(`\\b${field}:`), `the mid read no longer returns ${field}, so the sentence cannot be chosen from the measurement`);
  }
});
