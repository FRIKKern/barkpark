// __pointing.test.mjs — pure-Node unit harness for the Studio sheet-grid
// pointing/prediction kernel (api/priv/static/assets/bp-sheet-pointing.js).
//
// Same shape as __hook.test.mjs: load the SHIPPED browser IIFE verbatim inside
// a node:vm sandbox that fakes just `window`, then exercise the exported pure
// API (`window.BarkparkSheetPointing`) against fake grids. Zero dependencies,
// no lockfile — a regression in the committed bundle reds the gate.
//
// Run: node __pointing.test.mjs   (or: npm test once S1 globs __*.test.mjs)

import assert from "node:assert/strict";
import vm from "node:vm";
import fs from "node:fs";

// ── vm sandbox: the minimal browser surface the IIFE touches ────────────────

const sandbox = { window: {} };
vm.createContext(sandbox);
vm.runInContext(
  fs.readFileSync(
    new URL("../../priv/static/assets/bp-sheet-pointing.js", import.meta.url),
    "utf8",
  ),
  sandbox,
);
const P = sandbox.window.BarkparkSheetPointing;
assert.ok(P, "IIFE assigned window.BarkparkSheetPointing");

// ── fake grid helper ────────────────────────────────────────────────────────
//
// `grid` is a map of "c,r" -> type char ('n'/'s'/'b'). Anything absent is
// empty. getCell returns {t} for a present cell, {t:null} for a modelled-empty
// cell, or null off the modelled area — the module treats all three as empty.
function makeGrid(cells) {
  const map = new Map();
  for (const [ref, t] of Object.entries(cells)) {
    const p = P.refToPos(ref);
    map.set(p.c + "," + p.r, t);
  }
  return function getCell(c, r) {
    const t = map.get(c + "," + r);
    return t === undefined ? null : { t };
  };
}

let passed = 0;
function check(name, fn) {
  fn();
  passed++;
}

// Objects/arrays returned from the vm carry the sandbox realm's prototypes, so
// node:assert/strict's deepStrictEqual rejects them against host-side literals.
// Normalize the actual value through JSON to strip the foreign prototype before
// a structural compare; primitives (assert.equal) cross the boundary fine.
function deepEq(actual, expected, msg) {
  assert.deepEqual(JSON.parse(JSON.stringify(actual)), expected, msg);
}

// ── (a) coordinate round-trips, incl. Z / AA boundary ────────────────────────

check("colLetters bijective base-26", () => {
  const cases = [
    [1, "A"], [2, "B"], [26, "Z"], [27, "AA"], [28, "AB"],
    [52, "AZ"], [53, "BA"], [702, "ZZ"], [703, "AAA"],
  ];
  for (const [c, letters] of cases) {
    assert.equal(P.colLetters(c), letters, "colLetters(" + c + ")");
    assert.equal(P.colIndex(letters), c, "colIndex(" + letters + ")");
  }
});

check("refToPos / posToRef round-trip incl. Z/AA boundary", () => {
  const refs = ["A1", "B3", "Z1", "AA1", "AB27", "AAA999"];
  for (const ref of refs) {
    const pos = P.refToPos(ref);
    assert.equal(P.posToRef(pos), ref, "round-trip " + ref);
  }
  // case-insensitive parse, canonical uppercase emit
  deepEq(P.refToPos("b3"), { c: 2, r: 3 });
  assert.equal(P.posToRef({ c: 2, r: 3 }), "B3");
  // fail closed on non-cell refs
  for (const bad of ["B", "3", "B:B", "B3:B5", "", "$B$3", "!!"]) {
    assert.equal(P.refToPos(bad), null, "refToPos rejects " + JSON.stringify(bad));
  }
});

// ── (a) rangeText normalization + whole col/row helpers ──────────────────────

check("rangeText normalizes any drag direction to top-left:bottom-right", () => {
  const B3 = { c: 2, r: 3 }, B5 = { c: 2, r: 5 };
  const A1 = { c: 1, r: 1 }, C4 = { c: 3, r: 4 };
  // down-drag and up-drag collapse to the same normalized text
  assert.equal(P.rangeText(B3, B5), "B3:B5");
  assert.equal(P.rangeText(B5, B3), "B3:B5", "drag up still top:bottom");
  // up-LEFT drag: head above-and-left of anchor still yields TL:BR
  assert.equal(P.rangeText(C4, A1), "A1:C4");
  assert.equal(P.rangeText(A1, C4), "A1:C4");
  // single cell collapses to a bare ref
  assert.equal(P.rangeText(B3, B3), "B3");
});

check("colRefText / rowRefText normalize + collapse", () => {
  assert.equal(P.colRefText(2, 2), "B:B");
  assert.equal(P.colRefText(2, 4), "B:D");
  assert.equal(P.colRefText(4, 2), "B:D", "col order normalized");
  assert.equal(P.rowRefText(3, 3), "3:3");
  assert.equal(P.rowRefText(3, 7), "3:7");
  assert.equal(P.rowRefText(7, 3), "3:7", "row order normalized");
});

// ── (b) phantomStep matrices ─────────────────────────────────────────────────

// Occupied run B2:B6 (a vertical column of numbers), one number away at D4.
const runGrid = makeGrid({
  B2: "n", B3: "n", B4: "n", B5: "n", B6: "n", D4: "n",
});
const bounds = { cols: 10, rows: 10 };

check("phantomStep seeds from opts.active on the first (null-state) arrow", () => {
  // plain arrow from active A1 → both anchor+head at A2 (single-cell phantom)
  const r = P.phantomStep(null, "down", { active: { c: 1, r: 1 } }, runGrid, bounds);
  deepEq(r.state.anchor, { c: 1, r: 2 });
  deepEq(r.state.head, { c: 1, r: 2 });
  assert.equal(r.refText, "A2");
});

check("phantomStep plain arrow moves head AND anchor (stays single-cell)", () => {
  const seed = { anchor: { c: 2, r: 4 }, head: { c: 2, r: 4 } }; // B4
  const r = P.phantomStep(seed, "down", {}, runGrid, bounds);
  deepEq(r.state.anchor, { c: 2, r: 5 });
  deepEq(r.state.head, { c: 2, r: 5 });
  assert.equal(r.refText, "B5");
});

check("phantomStep shift arrow moves head only (extends range)", () => {
  const seed = { anchor: { c: 2, r: 4 }, head: { c: 2, r: 4 } }; // B4
  const r = P.phantomStep(seed, "down", { shift: true }, runGrid, bounds);
  deepEq(r.state.anchor, { c: 2, r: 4 }, "anchor pinned");
  deepEq(r.state.head, { c: 2, r: 5 });
  assert.equal(r.refText, "B4:B5");
});

check("phantomStep edge from run-middle → last occupied cell of the run", () => {
  // B4 occupied, neighbour B5 occupied → jump to run end B6
  const seed = { anchor: { c: 2, r: 4 }, head: { c: 2, r: 4 } };
  const r = P.phantomStep(seed, "down", { edge: true }, runGrid, bounds);
  deepEq(r.state.head, { c: 2, r: 6 });
  assert.equal(r.refText, "B6", "single-cell (no shift) at run end");
});

check("phantomStep edge from run edge → next occupied cell, else bound", () => {
  // B6 is the run's last cell; below is empty all the way → grid bottom row 10
  const seed = { anchor: { c: 2, r: 6 }, head: { c: 2, r: 6 } };
  const r = P.phantomStep(seed, "down", { edge: true }, runGrid, bounds);
  deepEq(r.state.head, { c: 2, r: 10 }, "no data below → grid bound");
});

check("phantomStep edge from empty region → next occupied cell", () => {
  // B4 rightward: C4 empty, D4 occupied → seek lands on D4
  const seed = { anchor: { c: 2, r: 4 }, head: { c: 2, r: 4 } };
  const r = P.phantomStep(seed, "right", { edge: true }, runGrid, bounds);
  deepEq(r.state.head, { c: 4, r: 4 }, "seek to next occupied");
  assert.equal(r.refText, "D4");
});

check("phantomStep Ctrl+Shift edge extends head to the edge, anchor pinned", () => {
  const seed = { anchor: { c: 2, r: 4 }, head: { c: 2, r: 4 } };
  const r = P.phantomStep(seed, "down", { edge: true, shift: true }, runGrid, bounds);
  deepEq(r.state.anchor, { c: 2, r: 4 }, "anchor pinned");
  deepEq(r.state.head, { c: 2, r: 6 });
  assert.equal(r.refText, "B4:B6");
});

check("phantomStep clamps at the grid bound (top/left corners)", () => {
  const up = P.phantomStep(
    { anchor: { c: 1, r: 1 }, head: { c: 1, r: 1 } }, "up", {}, runGrid, bounds);
  deepEq(up.state.head, { c: 1, r: 1 }, "up clamps at row 1");
  const left = P.phantomStep(
    { anchor: { c: 1, r: 1 }, head: { c: 1, r: 1 } }, "left", {}, runGrid, bounds);
  deepEq(left.state.head, { c: 1, r: 1 }, "left clamps at col 1");
  const right = P.phantomStep(
    { anchor: { c: 10, r: 1 }, head: { c: 10, r: 1 } }, "right", {}, runGrid, bounds);
  deepEq(right.state.head, { c: 10, r: 1 }, "right clamps at cols");
});

// ── (c) predictRange goldens ─────────────────────────────────────────────────

check("predictRange: the wish case (B3/B4/B5 numeric, caret B6) → B3:B5", () => {
  const g = makeGrid({ B3: "n", B4: "n", B5: "n" });
  assert.equal(P.predictRange(g, { c: 2, r: 6 }), "B3:B5");
});

check("predictRange: gap directly above → null above → tries left", () => {
  // caret B6, B5 numeric but B4 empty → up-run is just [B5] (len 1); nothing
  // to the left of B6 → null
  const g = makeGrid({ B5: "n", B3: "n" });
  assert.equal(P.predictRange(g, { c: 2, r: 6 }), null);
});

check("predictRange: falls back to a leftward numeric run", () => {
  // caret D2: nothing numeric above (D1 empty), but A2/B2/C2 numeric → A2:C2
  const g = makeGrid({ A2: "n", B2: "n", C2: "n" });
  assert.equal(P.predictRange(g, { c: 4, r: 2 }), "A2:C2");
});

check("predictRange: single numeric above → null (run must be ≥2)", () => {
  const g = makeGrid({ B5: "n" }); // one cell above B6, nothing left
  assert.equal(P.predictRange(g, { c: 2, r: 6 }), null);
});

check("predictRange: a non-numeric cell stops the run", () => {
  // B5 numeric, B4 numeric, B3 STRING → up-run stops at B4, giving B4:B5
  const g = makeGrid({ B5: "n", B4: "n", B3: "s", B2: "n" });
  assert.equal(P.predictRange(g, { c: 2, r: 6 }), "B4:B5");
  // a bool immediately above kills the up-run (len 0); one cell to the left
  // (A6) is only length 1 → null
  const g2 = makeGrid({ B5: "b", A6: "n" });
  assert.equal(P.predictRange(g2, { c: 2, r: 6 }), null);
});

// ── (d) shouldOfferGhost truth table ─────────────────────────────────────────

check("shouldOfferGhost truth table", () => {
  const rows = [
    ["SUM", 0, true, true],       // whitelisted, first arg, empty → offer
    ["sum", 0, true, true],       // case-insensitive
    ["AVERAGE", 0, true, true],
    ["MEDIAN", 0, true, true],
    ["SUM", 1, true, false],      // second arg → no
    ["SUM", 0, false, false],     // non-empty arg → no
    ["IF", 0, true, false],       // not whitelisted → no
    ["AVERAGEIF", 0, true, false],// family member deliberately excluded
    ["", 0, true, false],
    [null, 0, true, false],
  ];
  for (const [fn, argIndex, argEmpty, want] of rows) {
    assert.equal(
      P.shouldOfferGhost(fn, argIndex, argEmpty), want,
      "shouldOfferGhost(" + JSON.stringify(fn) + "," + argIndex + "," + argEmpty + ")",
    );
  }
  // every whitelisted aggregate offers at (0, empty)
  for (const fn of P.AGGREGATES) {
    assert.equal(P.shouldOfferGhost(fn, 0, true), true, fn + " offers");
  }
});

// ── (e) fuzzyFns ordering ─────────────────────────────────────────────────────

check("fuzzyFns: prefix before contains, stable order, cap 8, empty → []", () => {
  const names = ["SUM", "SUMIF", "SUMIFS", "AVERAGE", "PRODUCT", "MAXA", "MAX"];
  // "SUM": prefix matches in original order, no contains
  deepEq(P.fuzzyFns("SUM", names), ["SUM", "SUMIF", "SUMIFS"]);
  // "MAX": prefix (MAXA, MAX) first, then contains (none here) — original order
  deepEq(P.fuzzyFns("max", names), ["MAXA", "MAX"]);
  // "UM": no prefix, contains matches in original order
  deepEq(P.fuzzyFns("UM", names), ["SUM", "SUMIF", "SUMIFS"]);
  // prefix ranks ahead of contains even when the contains match comes first
  deepEq(
    P.fuzzyFns("A", ["MAXA", "AVERAGE"]), ["AVERAGE", "MAXA"],
    "prefix (AVERAGE) outranks earlier contains (MAXA)",
  );
  // empty query → []
  deepEq(P.fuzzyFns("", names), []);
  deepEq(P.fuzzyFns(null, names), []);
  // cap at 8
  const many = Array.from({ length: 20 }, (_, i) => "SUM" + i);
  assert.equal(P.fuzzyFns("SUM", many).length, 8);
});

// ── (f) ghostReduce full event matrix ────────────────────────────────────────

check("ghostReduce: offer sets, accept consumes, everything else clears", () => {
  // offer sets the offered text
  deepEq(
    P.ghostReduce({ offered: null }, { type: "offer", text: "B3:B5" }),
    { offered: "B3:B5" },
  );
  // offer from undefined initial state
  deepEq(
    P.ghostReduce(undefined, { type: "offer", text: "A1:A9" }),
    { offered: "A1:A9" },
  );
  // accept returns the offered text and clears
  deepEq(
    P.ghostReduce({ offered: "B3:B5" }, { type: "accept" }),
    { accepted: "B3:B5", offered: null },
  );
  // accept with nothing offered → accepted null
  deepEq(
    P.ghostReduce({ offered: null }, { type: "accept" }),
    { accepted: null, offered: null },
  );
  // EVERY other event clears the offer — the ghost never steals a keystroke
  for (const type of ["key", "click", "arrow", "dismiss", "blur", "wat"]) {
    deepEq(
      P.ghostReduce({ offered: "B3:B5" }, { type }),
      { offered: null },
      type + " clears the offer",
    );
  }
  // offer with a null text is treated as no offer
  deepEq(
    P.ghostReduce({ offered: "x" }, { type: "offer", text: null }),
    { offered: null },
  );
});

console.log("bp-sheet-pointing: " + passed + " groups passed");
