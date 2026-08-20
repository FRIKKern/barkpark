/**
 * Unit tests for the task-board embed model in `lib/task-board-columns.ts`:
 * `taskBoardColumns` buckets an ALREADY-RESOLVED task-board snapshot into the
 * five white-ladder columns + a cancelled tally + the momentum read. Pure; the
 * column order + glyph codepoints mirror the shared status vocabulary
 * (`design/status-manifest.json` / the Elixir `Board.glyphs/0`).
 *
 * Run: `pnpm test` (or `cd web && node --test __tests__/task-board-columns.test.ts`).
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  taskBoardColumns,
  TASK_BOARD_COLUMN_ORDER,
  TASK_BOARD_GLYPHS,
  type TaskBoardRow,
} from "../lib/task-board-columns.ts";

test("each status buckets into its column, cancelled folds to the tally", () => {
  const snapshot: TaskBoardRow[] = [
    { title: "a", status: "open" },
    { title: "b", status: "ready" },
    { title: "c", status: "in_progress" },
    { title: "d", status: "blocked" },
    { title: "e", status: "done" },
    { title: "f", status: "cancelled" },
  ];
  const { columns, cancelledCount } = taskBoardColumns(snapshot);

  assert.deepEqual(
    columns.open.map((r) => r.title),
    ["a"],
  );
  assert.deepEqual(
    columns.ready.map((r) => r.title),
    ["b"],
  );
  assert.deepEqual(
    columns.in_progress.map((r) => r.title),
    ["c"],
  );
  assert.deepEqual(
    columns.blocked.map((r) => r.title),
    ["d"],
  );
  assert.deepEqual(
    columns.done.map((r) => r.title),
    ["e"],
  );
  assert.equal(cancelledCount, 1);
});

test("closed/cancel aliases land honestly (manifest status map)", () => {
  const { columns, cancelledCount } = taskBoardColumns([
    { title: "closed-as-done", status: "closed" },
    { title: "cancel-alias", status: "cancel" },
  ]);
  assert.deepEqual(
    columns.done.map((r) => r.title),
    ["closed-as-done"],
  );
  assert.equal(cancelledCount, 1);
});

test("unknown / absent status fails soft to open (never dropped)", () => {
  const { columns } = taskBoardColumns([
    { title: "weird", status: "banana" },
    { title: "empty" }, // no status at all
    { title: "nonstring", status: 42 as unknown as string },
  ]);
  assert.deepEqual(
    columns.open.map((r) => r.title),
    ["weird", "empty", "nonstring"],
  );
});

test("considering/researching bucket to their OWN columns, not open (thought states)", () => {
  const { columns } = taskBoardColumns([
    { title: "c1", status: "considering" },
    { title: "r1", status: "researching" },
    { title: "o1", status: "open" },
  ]);
  assert.deepEqual(
    columns.considering.map((r) => r.title),
    ["c1"],
  );
  assert.deepEqual(
    columns.researching.map((r) => r.title),
    ["r1"],
  );
  // The thought states are NOT swept into open — only genuine open work is there.
  assert.deepEqual(
    columns.open.map((r) => r.title),
    ["o1"],
  );
});

test("thought states are OUT of the momentum denominator (never dilute pct)", () => {
  // 1 done + 1 open = 2 committed; the two thought rows must not enter the total.
  const { momentum } = taskBoardColumns([
    { status: "done" },
    { status: "open" },
    { status: "considering" },
    { status: "researching" },
  ]);
  assert.equal(momentum.pct, 50); // round(1 / 2 * 100), NOT 25 (would be 1/4)
  // A board of ONLY thought states has zero committed work → pct is 0, never NaN.
  assert.equal(
    taskBoardColumns([
      { status: "considering" },
      { status: "researching" },
    ]).momentum.pct,
    0,
  );
});

test("bucketing preserves per-column input order", () => {
  const { columns } = taskBoardColumns([
    { title: "d1", status: "done" },
    { title: "r1", status: "ready" },
    { title: "d2", status: "done" },
    { title: "r2", status: "ready" },
  ]);
  assert.deepEqual(
    columns.done.map((r) => r.title),
    ["d1", "d2"],
  );
  assert.deepEqual(
    columns.ready.map((r) => r.title),
    ["r1", "r2"],
  );
});

test("momentum counts in-flight/ready/done and pct over the non-cancelled total", () => {
  // 1 done of 4 non-cancelled (the cancelled row is OUT of the denominator).
  const { momentum } = taskBoardColumns([
    { status: "in_progress" },
    { status: "in_progress" },
    { status: "ready" },
    { status: "done" },
    { status: "cancelled" },
  ]);
  assert.equal(momentum.inFlight, 2);
  assert.equal(momentum.ready, 1);
  assert.equal(momentum.done, 1);
  assert.equal(momentum.pct, 25); // round(1 / 4 * 100)
});

test("momentum pct is never divided by zero — empty snapshot", () => {
  const { momentum } = taskBoardColumns([]);
  assert.equal(momentum.inFlight, 0);
  assert.equal(momentum.ready, 0);
  assert.equal(momentum.done, 0);
  assert.equal(momentum.pct, 0);
});

test("momentum pct is never divided by zero — all cancelled", () => {
  const { momentum, cancelledCount } = taskBoardColumns([
    { status: "cancelled" },
    { status: "cancelled" },
  ]);
  assert.equal(cancelledCount, 2);
  assert.equal(momentum.pct, 0); // 0 done / max(0,1) → 0, never NaN/Infinity
});

test("momentum pct rounds half up (round, not truncate)", () => {
  // 1 done of 3 non-cancelled → round(33.33) = 33; 1 of 6 → round(16.67) = 17.
  assert.equal(
    taskBoardColumns([
      { status: "done" },
      { status: "open" },
      { status: "open" },
    ]).momentum.pct,
    33,
  );
  assert.equal(
    taskBoardColumns([
      { status: "done" },
      { status: "open" },
      { status: "open" },
      { status: "open" },
      { status: "open" },
      { status: "open" },
    ]).momentum.pct,
    17,
  );
});

test("column order is the committed ladder then the trailing thought states", () => {
  assert.deepEqual(TASK_BOARD_COLUMN_ORDER, [
    "open",
    "ready",
    "in_progress",
    "blocked",
    "done",
    "considering",
    "researching",
  ]);
});

test("glyphs are the §1 white-ladder codepoints verbatim (never an SVG)", () => {
  assert.equal(TASK_BOARD_GLYPHS.open, "○"); // ○
  assert.equal(TASK_BOARD_GLYPHS.ready, "○"); // ○
  assert.equal(TASK_BOARD_GLYPHS.in_progress, "⠋"); // ⠋ first Braille frame
  assert.equal(TASK_BOARD_GLYPHS.blocked, "!"); // !
  assert.equal(TASK_BOARD_GLYPHS.done, "✓"); // ✓
  assert.equal(TASK_BOARD_GLYPHS.cancelled, "✕"); // ✕
  assert.equal(TASK_BOARD_GLYPHS.considering, "◌"); // ◌ dotted circle
  assert.equal(TASK_BOARD_GLYPHS.researching, "◎"); // ◎ bullseye
});

test("non-array snapshot degrades to empty columns (never throws)", () => {
  const { columns, momentum, cancelledCount } = taskBoardColumns(
    null as unknown as TaskBoardRow[],
  );
  for (const key of TASK_BOARD_COLUMN_ORDER) {
    assert.deepEqual(columns[key], []);
  }
  assert.equal(cancelledCount, 0);
  assert.equal(momentum.pct, 0);
});
