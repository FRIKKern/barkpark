"use client";

import { useState } from "react";
import type { JSX } from "react";
import { densifyTab } from "@/lib/sheets";
import type { SheetCell, SheetTab } from "@/lib/sheets";

/* ── types ────────────────────────────────────────────────────────────────── */

// Canonical raw-tab types live in lib/sheets.ts (single source of truth — they
// carry the A1-string `merges` and 1-based `col_widths` forms the API ships).
// Re-export so consumers can import them from the renderer too.
export type { SheetCell, SheetTab };

/**
 * A dense, pre-densified snapshot — the shape carried by paper-embedded sheet
 * blocks (`block.snapshot`). Values are pre-computed; there is no formula
 * engine on this side. `styles` is keyed `"row,col"` (0-based).
 */
export interface DenseSnapshot {
  rows: unknown[][];
  head?: unknown[];
  col_widths?: number[];
  merges?: number[][];
  styles?: Record<string, { b?: boolean; i?: boolean; bg?: string; al?: string }>;
}

/* ── helpers ──────────────────────────────────────────────────────────────── */

type CellStyle = { b?: boolean; i?: boolean; bg?: string; al?: string };

/** Normalised merge: top row, left col, span counts (all >= 1). */
interface NormMerge {
  r: number;
  c: number;
  rowspan: number;
  colspan: number;
}

/** Spreadsheet column label: 0 → A, 25 → Z, 26 → AA, … */
function colLabel(index: number): string {
  let n = index;
  let label = "";
  do {
    label = String.fromCharCode(65 + (n % 26)) + label;
    n = Math.floor(n / 26) - 1;
  } while (n >= 0);
  return label;
}

const numberFormat = new Intl.NumberFormat("en-US", { maximumFractionDigits: 10 });

function isNumber(v: unknown): v is number {
  return typeof v === "number" && Number.isFinite(v);
}

/** Render a cell value to display text. Numbers are grouped via Intl. */
function displayValue(v: unknown): string {
  if (v == null) return "";
  if (isNumber(v)) return numberFormat.format(v);
  if (typeof v === "boolean") return v ? "TRUE" : "FALSE";
  if (typeof v === "string") return v;
  // Objects/arrays — fall back to a JSON-ish string rather than "[object …]".
  try {
    return JSON.stringify(v);
  } catch {
    return String(v);
  }
}

/**
 * Decode DENSE-SNAPSHOT merges. The API emits each merge as
 * `[row, col, rowspan, colspan]` (0-based, NOT inclusive corners) — see
 * `api/lib/barkpark/sheets.ex` (`[r1-data_start, c1-1, r2-r1+1, c2-c1+1]`).
 * The raw-tab path uses A1-range strings and is decoded separately in
 * `lib/sheets.ts`; these are genuinely different wire formats, so they must NOT
 * share a decoder.
 */
function snapshotMerges(merges: number[][] | undefined): NormMerge[] {
  if (!Array.isArray(merges)) return [];
  const out: NormMerge[] = [];
  for (const m of merges) {
    if (!Array.isArray(m)) continue;
    const [row, col, rowspan, colspan] = m;
    if (!isNumber(row) || !isNumber(col)) continue;
    out.push({
      r: row,
      c: col,
      rowspan: isNumber(rowspan) ? Math.max(1, rowspan) : 1,
      colspan: isNumber(colspan) ? Math.max(1, colspan) : 1,
    });
  }
  return out;
}

/** A lookup for cells that participate in a merge. */
interface MergeIndex {
  /** `"r,c"` of every merge anchor → its span. */
  anchors: Map<string, NormMerge>;
  /** `"r,c"` of every cell *covered but not anchoring* a merge → skip it. */
  covered: Set<string>;
}

function indexMerges(merges: NormMerge[]): MergeIndex {
  const anchors = new Map<string, NormMerge>();
  const covered = new Set<string>();
  for (const m of merges) {
    anchors.set(`${m.r},${m.c}`, m);
    for (let r = m.r; r < m.r + m.rowspan; r++) {
      for (let c = m.c; c < m.c + m.colspan; c++) {
        if (r === m.r && c === m.c) continue;
        covered.add(`${r},${c}`);
      }
    }
  }
  return { anchors, covered };
}

/* ── shared grid ──────────────────────────────────────────────────────────── */

interface GridTableProps {
  rows: unknown[][];
  head?: unknown[];
  colWidths?: number[];
  merges?: NormMerge[];
  styles?: Record<string, CellStyle>;
}

const cornerCls =
  "sticky left-0 top-0 z-30 border-b border-r border-zinc-300 bg-zinc-100 dark:border-zinc-700 dark:bg-zinc-800";
const colHeadCls =
  "sticky top-0 z-20 border-b border-r border-zinc-300 bg-zinc-100 px-2 py-1 text-center text-xs font-medium text-zinc-500 dark:border-zinc-700 dark:bg-zinc-800 dark:text-zinc-400";
const rowHeadCls =
  "sticky left-0 z-10 border-b border-r border-zinc-300 bg-zinc-100 px-2 py-1 text-center text-xs font-medium text-zinc-500 dark:border-zinc-700 dark:bg-zinc-800 dark:text-zinc-400";
const dataCellCls =
  "border-b border-r border-zinc-200 px-2 py-1 align-top text-sm text-zinc-800 dark:border-zinc-800 dark:text-zinc-200";

/** Map a cell style's alignment hint to a Tailwind text-align class. */
function alignClass(al: string | undefined, numeric: boolean): string {
  switch (al) {
    case "left":
      return "text-left";
    case "center":
      return "text-center";
    case "right":
      return "text-right";
    default:
      // No explicit alignment → numbers right-align, everything else left.
      return numeric ? "text-right" : "text-left";
  }
}

/**
 * The read-only spreadsheet surface shared by `SheetGrid` and `SheetSnapshot`.
 * Renders a sticky A/B/C column header, a sticky 1/2/3 row-number gutter, and
 * one `<td>` per dense cell — honouring merges, per-column widths, and the
 * optional per-cell style map.
 */
function GridTable({ rows, head, colWidths, merges, styles }: GridTableProps) {
  // Column count: the widest of head, every row, and the declared widths.
  let colCount = head?.length ?? 0;
  for (const row of rows) colCount = Math.max(colCount, row.length);
  colCount = Math.max(colCount, colWidths?.length ?? 0);

  if (colCount === 0 || (rows.length === 0 && !head)) {
    return (
      <p className="px-1 py-2 text-sm text-zinc-400 italic">
        This sheet is empty.
      </p>
    );
  }

  const { anchors, covered } = indexMerges(merges ?? []);
  const styleFor = (r: number, c: number): CellStyle | undefined =>
    styles?.[`${r},${c}`];
  const widthFor = (c: number): number | undefined => {
    const w = colWidths?.[c];
    return isNumber(w) && w > 0 ? w : undefined;
  };

  const renderCell = (value: unknown, r: number, c: number) => {
    const key = `${r},${c}`;
    if (covered.has(key)) return null; // swallowed by a merge anchor above/left

    const merge = anchors.get(key);
    const st = styleFor(r, c);
    const numeric = isNumber(value);
    const width = widthFor(c);

    const cls = [
      dataCellCls,
      alignClass(st?.al, numeric),
      numeric ? "font-mono tabular-nums" : "",
      st?.b ? "font-semibold" : "",
      st?.i ? "italic" : "",
    ]
      .filter(Boolean)
      .join(" ");

    return (
      <td
        key={key}
        className={cls}
        colSpan={merge && merge.colspan > 1 ? merge.colspan : undefined}
        rowSpan={merge && merge.rowspan > 1 ? merge.rowspan : undefined}
        style={{
          ...(width ? { minWidth: width, width } : {}),
          ...(st?.bg ? { backgroundColor: st.bg } : {}),
        }}
      >
        {displayValue(value)}
      </td>
    );
  };

  return (
    <div className="overflow-x-auto rounded-lg border border-zinc-200 dark:border-zinc-800">
      <table className="border-collapse text-sm">
        <thead>
          <tr>
            <th className={cornerCls} aria-hidden />
            {Array.from({ length: colCount }, (_, c) => (
              <th
                key={c}
                className={colHeadCls}
                style={widthFor(c) ? { minWidth: widthFor(c), width: widthFor(c) } : undefined}
                scope="col"
              >
                {colLabel(c)}
              </th>
            ))}
          </tr>
          {head ? (
            <tr>
              <th className={rowHeadCls} scope="row" aria-hidden />
              {Array.from({ length: colCount }, (_, c) => {
                const value = head[c];
                return (
                  <th
                    key={c}
                    className={`${dataCellCls} bg-zinc-50 text-left font-semibold dark:bg-zinc-900/60`}
                    scope="col"
                  >
                    {displayValue(value)}
                  </th>
                );
              })}
            </tr>
          ) : null}
        </thead>
        <tbody>
          {rows.map((row, r) => (
            <tr key={r}>
              <th className={rowHeadCls} scope="row">
                {r + 1}
              </th>
              {Array.from({ length: colCount }, (_, c) =>
                renderCell(row[c], r, c),
              )}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

/* ── public components ────────────────────────────────────────────────────── */

function tabLabel(tab: SheetTab, index: number): string {
  return tab.title || tab.name || `Sheet ${index + 1}`;
}

/**
 * Render a raw sheet document: one densified grid per tab, with a tab bar when
 * there is more than one tab. Densification (sparse A1 cells → dense rows) is
 * delegated to `densifyTab`; this component owns only the active-tab state and
 * the visual surface.
 */
export function SheetGrid({ tabs }: { tabs: SheetTab[] }): JSX.Element {
  const [active, setActive] = useState(0);

  if (!Array.isArray(tabs) || tabs.length === 0) {
    return (
      <p className="text-sm text-zinc-400 italic">This sheet has no tabs.</p>
    );
  }

  const safeActive = Math.min(Math.max(active, 0), tabs.length - 1);
  const tab = tabs[safeActive];
  const dense = densifyTab(tab);
  // densifyTab emits MergeRegion {r,c,rs,cs}; GridTable wants NormMerge.
  const denseMerges: NormMerge[] = dense.merges.map((m) => ({
    r: m.r,
    c: m.c,
    rowspan: Math.max(1, m.rs),
    colspan: Math.max(1, m.cs),
  }));

  return (
    <div className="flex flex-col gap-2">
      {tabs.length > 1 ? (
        <div
          role="tablist"
          aria-label="Sheet tabs"
          className="flex flex-wrap gap-1 border-b border-zinc-200 dark:border-zinc-800"
        >
          {tabs.map((t, i) => {
            const selected = i === safeActive;
            return (
              <button
                key={i}
                type="button"
                role="tab"
                aria-selected={selected}
                onClick={() => setActive(i)}
                className={
                  selected
                    ? "-mb-px border-b-2 border-zinc-900 px-3 py-1.5 text-sm font-medium text-zinc-900 dark:border-zinc-100 dark:text-zinc-100"
                    : "-mb-px border-b-2 border-transparent px-3 py-1.5 text-sm text-zinc-500 transition-colors hover:text-zinc-900 dark:text-zinc-400 dark:hover:text-zinc-200"
                }
              >
                {tabLabel(t, i)}
              </button>
            );
          })}
        </div>
      ) : null}

      <GridTable
        rows={Array.isArray(dense.rows) ? dense.rows : []}
        colWidths={Array.isArray(dense.colWidths) ? dense.colWidths : undefined}
        merges={denseMerges}
      />
    </div>
  );
}

/**
 * Render a dense snapshot — the form embedded in paper sheet-blocks. Values are
 * already computed and the grid is already dense, so this is a thin wrapper over
 * the shared `GridTable`.
 */
export function SheetSnapshot({
  snapshot,
}: {
  snapshot: DenseSnapshot;
}): JSX.Element {
  if (!snapshot || !Array.isArray(snapshot.rows)) {
    return (
      <p className="text-sm text-zinc-400 italic">This sheet is empty.</p>
    );
  }
  return (
    <GridTable
      rows={snapshot.rows}
      head={Array.isArray(snapshot.head) ? snapshot.head : undefined}
      colWidths={
        Array.isArray(snapshot.col_widths) ? snapshot.col_widths : undefined
      }
      merges={snapshotMerges(snapshot.merges)}
      styles={snapshot.styles}
    />
  );
}
