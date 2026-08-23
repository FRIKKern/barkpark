/**
 * Task-board embed model — pure bucketing of an ALREADY-RESOLVED task-board
 * snapshot into the five white-ladder columns for the web paper reader.
 *
 * Charter D16 / wave 5: the `task-board` PortableDoc block resolves SERVER-SIDE
 * (`TaskResolver.resolve/2` — `task-board ∈ @snapshot_types`) into a FLAT
 * `snapshot: [row]`, each row already carrying the honest white-ladder `status`
 * (an `open` task with no unmet blocker is surfaced as `"ready"` by
 * `row_from_task/status_of` — readiness is derived ONCE, server-side, exactly
 * like the live board's D3 overlay). So this helper NEVER re-derives readiness
 * and NEVER re-queries; it only BUCKETS the resolved rows into the seven
 * ordered columns (five white-ladder + the two adopted thought states) for
 * display. No React / DOM — unit-testable under `node --test`.
 *
 * The organizer (`Barkpark.Tasks.Board`, D2) stays Elixir core; this is the far
 * simpler web twin because readiness is already decided on the wire.
 */

import { boardLabel, roleForStatus } from "./component-projections.ts";

/** One resolved snapshot row (the `TaskResolver.row_from_task` shape — pruned,
 * so absent segments are simply missing). Loosely typed: only `status` drives
 * bucketing; the rest is display. */
export interface TaskBoardRow {
  title?: string;
  status?: string;
  priority?: string;
  worker?: string;
  criteria?: { met?: number; total?: number } | null;
  phase?: string;
  [attr: string]: unknown;
}

/** The rendered columns, in white-ladder order (cancelled is folded to a tally,
 * never a column — D-fold). The two thought states — `considering`/`researching`
 * (task-lifecycle-visibility) — trail at the END, dim; empty columns collapse.
 * They are NOT committed work, so they stay OUT of the momentum denominator. */
export const TASK_BOARD_COLUMN_ORDER = [
  "open",
  "ready",
  "in_progress",
  "blocked",
  "done",
  "considering",
  "researching",
] as const;

export type TaskBoardColumnKey = (typeof TASK_BOARD_COLUMN_ORDER)[number];

/** Human labels for the column headers — FOLDED from the ONE canonical status
 * label (`design/status-manifest.json` via `boardLabel`/`roleForStatus`), NOT a
 * second hardcoded copy: each column key maps through its ladder role to the
 * sentence-cased canonical label ("in_progress" → progress → "In progress"). */
export const TASK_BOARD_COLUMN_LABELS: Record<TaskBoardColumnKey, string> =
  Object.fromEntries(
    TASK_BOARD_COLUMN_ORDER.map((col) => [col, boardLabel(roleForStatus(col))]),
  ) as Record<TaskBoardColumnKey, string>;

/**
 * The §1 white-ladder glyph map — HARD-CODED, pinned to the shared status
 * vocabulary (`design/status-manifest.json` / `internal/taskboard/components.go`
 * `StatusGlyph` / the Elixir `Board.glyphs/0`). IDENTICAL Unicode codepoints,
 * NEVER an SVG (charter D6):
 *
 *     open ○  ready ○  in_progress ⠋  blocked !  done ✓  cancelled ✕
 *
 * `in_progress` carries the FIRST Braille frame (`⠋`, U+280B) — the reader
 * animates the ten-frame spinner in CSS at rest and freezes it on `⠿` under
 * `prefers-reduced-motion`. `cancelled` carries `✕` for shared-truth parity even
 * though the board folds it to a tally (the glyph is shared; its placement isn't).
 */
export const TASK_BOARD_GLYPHS = {
  open: "○", // U+25CB
  ready: "○", // U+25CB (full weight vs open's dim — colour distinguishes, not glyph)
  in_progress: "⠋", // U+280B — first Braille spinner frame
  blocked: "!", // U+0021
  done: "✓", // U+2713
  cancelled: "✕", // U+2715
  considering: "◌", // U+25CC dotted circle — a candidate, weighed (dim)
  researching: "◎", // U+25CE bullseye — under investigation (dim)
} as const;

/** Momentum read — the "always feel progress" header. `pct` is done over the
 * non-cancelled total, NEVER divided by zero, with cancelled OUT of the
 * denominator (mirrors the organizer's `momentum.pct`). */
export interface TaskBoardMomentum {
  inFlight: number;
  ready: number;
  done: number;
  pct: number;
}

export interface TaskBoardColumns {
  columns: Record<TaskBoardColumnKey, TaskBoardRow[]>;
  cancelledCount: number;
  momentum: TaskBoardMomentum;
}

/** Map a resolved `status` string to its rendered column, or `"cancelled"` when
 * the row is cancelled (folded to the tally). Unknown / absent status fails SOFT
 * to `open` so a row never vanishes. `closed`/`cancel` aliases mirror the
 * manifest's status map so a lifecycle passthrough lands honestly. */
function columnForStatus(status: string): TaskBoardColumnKey | "cancelled" {
  switch (status) {
    case "in_progress":
      return "in_progress";
    case "done":
    case "closed":
      return "done";
    case "blocked":
      return "blocked";
    case "ready":
      return "ready";
    case "considering":
      return "considering";
    case "researching":
      return "researching";
    case "cancelled":
    case "cancel":
      return "cancelled";
    case "open":
      return "open";
    default:
      return "open"; // fail-soft — never drop a row (unknown homes in open)
  }
}

/**
 * Bucket a flat, already-resolved task-board snapshot into the seven ordered
 * columns (five white-ladder + considering/researching) + a cancelled tally +
 * the momentum read.
 *
 * Readiness is PRE-COMPUTED server-side (D16) — this only buckets by the row's
 * `status` string. `pct = round(done / max(non_cancelled_total, 1) * 100)` so it
 * is never `/0` and cancelled rows are excluded from both the columns and the
 * denominator.
 */
export function taskBoardColumns(snapshot: TaskBoardRow[]): TaskBoardColumns {
  const columns: Record<TaskBoardColumnKey, TaskBoardRow[]> = {
    open: [],
    ready: [],
    in_progress: [],
    blocked: [],
    done: [],
    considering: [],
    researching: [],
  };
  let cancelledCount = 0;

  const rows = Array.isArray(snapshot) ? snapshot : [];
  for (const row of rows) {
    const status = typeof row?.status === "string" ? row.status : "";
    const col = columnForStatus(status);
    if (col === "cancelled") {
      cancelledCount += 1;
    } else {
      columns[col].push(row);
    }
  }

  const done = columns.done.length;
  // Momentum denominator = COMMITTED work only. Cancelled is excluded (folded to
  // a tally), and the thought states (considering/researching) are DELIBERATELY
  // absent too — contemplation is not committed work, so it must not dilute pct.
  const nonCancelledTotal =
    columns.open.length +
    columns.ready.length +
    columns.in_progress.length +
    columns.blocked.length +
    done;

  const momentum: TaskBoardMomentum = {
    inFlight: columns.in_progress.length,
    ready: columns.ready.length,
    done,
    pct: Math.round((done / Math.max(nonCancelledTotal, 1)) * 100),
  };

  return { columns, cancelledCount, momentum };
}
