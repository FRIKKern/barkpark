/**
 * Tests for `densifyTab` — the sparse-SheetTab → dense-grid transform behind the
 * sheets viewer. It computes the grid bounds from BOTH occupied cells and merge
 * regions, null-fills a row-major grid, resolves per-column widths, and
 * normalizes merges to 0-based anchor+span. Bounds / merge-widening / A1-key
 * bugs here corrupt every rendered sheet; it shipped untested.
 *
 * Run: `pnpm test` (or `cd web && node --test __tests__/sheets-densify.test.ts`).
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { densifyTab, toRenderModel } from "../lib/sheets.ts";

test("an empty tab densifies to a 0×0 grid", () => {
  const d = densifyTab({ cells: {} });
  assert.deepEqual(d.rows, []);
  assert.equal(d.nRows, 0);
  assert.equal(d.nCols, 0);
  assert.deepEqual(d.colWidths, []);
  assert.deepEqual(d.merges, []);
});

test("sparse cells set the bounds and place values row-major", () => {
  const d = densifyTab({ cells: { A1: { v: 1 }, C2: { v: 2 } } });
  assert.equal(d.nRows, 2); // C2 → row index 1
  assert.equal(d.nCols, 3); // column C → index 2
  assert.deepEqual(d.rows, [
    [1, null, null],
    [null, null, 2],
  ]);
});

test("a cell with no value densifies to null", () => {
  const d = densifyTab({ cells: { A1: {} } });
  assert.deepEqual(d.rows, [[null]]);
});

test("invalid A1 keys are skipped", () => {
  const d = densifyTab({ cells: { junk: { v: 1 }, A1: { v: 2 } } });
  assert.equal(d.nRows, 1);
  assert.equal(d.nCols, 1);
  assert.deepEqual(d.rows, [[2]]);
});

test("merges widen the bounds past the last occupied cell and normalize to 0-based", () => {
  const d = densifyTab({ cells: { A1: { v: 1 } }, merges: ["A1:B2"] });
  assert.equal(d.nRows, 2);
  assert.equal(d.nCols, 2);
  assert.deepEqual(d.merges, [{ r: 0, c: 0, rs: 2, cs: 2 }]);
});

test("a stray far-down cell is clamped to MAX_ROWS, not allocated in full", () => {
  const d = densifyTab({ cells: { A100000: { v: 1 } } });
  assert.equal(d.nRows, 5000); // clamped, not 100000
  assert.equal(d.rows.length, 5000);
  assert.equal(d.nCols, 1);
});

test("a far-down/far-right cell yields a bounded grid, not billions of cells", () => {
  const d = densifyTab({ cells: { XFD1048576: { v: 1 } } });
  assert.equal(d.nRows, 5000);
  assert.equal(d.nCols, 256);
  // The out-of-bounds cell is dropped rather than written past the arrays.
  assert.equal(d.rows.length, 5000);
  assert.equal(d.rows[0].length, 256);
});

test("an oversized A1-range merge is skipped, not expanded (browser-OOM guard)", () => {
  // "A1:XFD1048576" would expand to ~1.7e10 covered-cell inserts. densifyTab
  // must skip it (merges: []) and keep the grid within the 5000×256 clamp.
  const d = densifyTab({ cells: { A1: { v: 1 } }, merges: ["A1:XFD1048576"] });
  assert.deepEqual(d.merges, []);
  // Merge dropped → grid is sized by the lone A1 cell, comfortably within the
  // 5000×256 clamp (it must never widen to the merge's runaway bounds).
  assert.ok(d.nRows <= 5000 && d.nRows >= 1);
  assert.ok(d.nCols <= 256 && d.nCols >= 1);
  assert.equal(d.rows.length, d.nRows);
});

test("an oversized array-shape merge is skipped too", () => {
  const d = densifyTab({
    cells: { A1: { v: 1 } },
    merges: [[0, 0, 999999, 16000]],
  });
  assert.deepEqual(d.merges, []);
});

test("a legit small merge still comes through", () => {
  const d = densifyTab({ cells: { A1: { v: 1 } }, merges: ["A1:B2"] });
  assert.deepEqual(d.merges, [{ r: 0, c: 0, rs: 2, cs: 2 }]);
});

test("column widths resolve from an A1-letter map and a positional array", () => {
  const byLetter = densifyTab({ cells: { A1: { v: 1 }, B1: { v: 2 } }, col_widths: { A: 100 } });
  assert.deepEqual(byLetter.colWidths, [100, 0]);

  const byArray = densifyTab({ cells: { A1: { v: 1 }, B1: { v: 2 } }, col_widths: [50, 60] });
  assert.deepEqual(byArray.colWidths, [50, 60]);
});

/* ── styles / fmts / frozen plumbing ──────────────────────────────────────── */

test("styles are collected and sanitized; junk keys and bad bg are dropped", () => {
  // Built via a variable so TS' excess-property check doesn't reject the extra
  // `x` key we specifically want densifyTab to drop at runtime.
  const withJunkKey = { al: "center", x: 9 };
  const d = densifyTab({
    cells: {
      A1: { v: 1, s: { b: true, i: true, bg: "#FF0000", al: "right" } },
      B1: { v: 2, s: { b: false, bg: "red", al: "middle" } }, // all junk → no entry
      C1: { v: 3, s: withJunkKey }, // unknown key dropped, al kept
    },
  });
  // bg lowercased, only the four known keys kept
  assert.deepEqual(d.styles["0,0"], { b: true, i: true, bg: "#ff0000", al: "right" });
  // nothing survived sanitation → no key at all
  assert.equal(d.styles["0,1"], undefined);
  assert.deepEqual(d.styles["0,2"], { al: "center" });
});

test("fmt is collected only for the six-class vocabulary", () => {
  const d = densifyTab({
    cells: {
      A1: { v: 0.25, fmt: "percent" },
      B1: { v: 5, fmt: "bogus" }, // not a class → dropped
      C1: { v: 7 }, // no fmt
    },
  });
  assert.equal(d.fmts["0,0"], "percent");
  assert.equal(d.fmts["0,1"], undefined);
  assert.equal(d.fmts["0,2"], undefined);
});

test("frozen_rows accepts a number or a numeric string", () => {
  assert.equal(densifyTab({ cells: { A1: { v: 1 } }, frozen_rows: 1 }).frozenRows, 1);
  assert.equal(densifyTab({ cells: { A1: { v: 1 } }, frozen_rows: "1" }).frozenRows, 1);
  assert.equal(densifyTab({ cells: { A1: { v: 1 } }, frozen_rows: "0" }).frozenRows, 0);
  assert.equal(densifyTab({ cells: { A1: { v: 1 } } }).frozenRows, 0);
});

test("toRenderModel: frozen_rows '1' promotes row 0 to head and re-keys styles", () => {
  const dense = densifyTab({
    cells: {
      A1: { v: "Name" },
      B1: { v: "Age" },
      A2: { v: "Ada", s: { b: true } },
      B2: { v: 36, fmt: "thousands" },
    },
    frozen_rows: "1",
  });
  const model = toRenderModel(dense);
  assert.deepEqual(model.head, ["Name", "Age"]);
  assert.deepEqual(model.rows, [["Ada", 36]]);
  // A2 style was at grid row 1 → body row 0 after the head split.
  assert.deepEqual(model.styles["0,0"], { b: true });
  // head-row styles/fmts are dropped; body fmt re-keyed.
  assert.equal(model.fmts["0,1"], "thousands");
});

test("toRenderModel: with no frozen rows, head is undefined and keys are unchanged", () => {
  const dense = densifyTab({
    cells: { A1: { v: 1, s: { i: true } }, B2: { v: 2 } },
  });
  const model = toRenderModel(dense);
  assert.equal(model.head, undefined);
  assert.deepEqual(model.styles["0,0"], { i: true });
});

test("toRenderModel: a merge spanning the head row clips to the body", () => {
  // A1:A3 (col 0, rows 0..2). With one frozen row, it clips to body rows 0..1.
  const dense = densifyTab({
    cells: { A1: { v: "h" }, A2: { v: "x" }, A3: { v: "y" }, B1: { v: "b" } },
    merges: ["A1:A3"],
    frozen_rows: 1,
  });
  const model = toRenderModel(dense);
  // r1 = max(0,1)=1 → body row 0; r2 = 2 → body row 1; col 0; rowspan 2.
  assert.deepEqual(model.merges, [{ r: 0, c: 0, rs: 2, cs: 1 }]);
});

test("toRenderModel: a merge that clips to a single cell is dropped", () => {
  // A1:A2 with one frozen row → body rows: r1=max(0,1)=1, r2=1 → single cell.
  const dense = densifyTab({
    cells: { A1: { v: "h" }, A2: { v: "x" } },
    merges: ["A1:A2"],
    frozen_rows: 1,
  });
  const model = toRenderModel(dense);
  assert.deepEqual(model.merges, []);
});
