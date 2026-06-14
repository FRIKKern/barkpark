/**
 * Sheet document model — canonical types + pure densification helpers.
 *
 * A raw Barkpark sheet stores its grid SPARSELY: each tab carries a
 * `cells` map keyed by A1 references ("A1", "E6", "AA12"). The renderer wants
 * a DENSE row-major 2-D array, so `densifyTab` parses every key, computes the
 * occupied bounds, and lays the computed values (`cell.v`) into a rectangle.
 *
 * No secrets, no `server-only`, no network: re-exported by `sheet-grid.tsx`
 * (the client renderer) and consumed by `document-detail.tsx` (server). Pure
 * functions only — fully typed, no `any`.
 */

/** One cell in a sparse sheet tab. `v` is the computed value; `f` the formula
 * source; `t` an optional type hint ("n" | "s" | "b" | "d" | …). */
export interface SheetCell {
  v?: unknown;
  f?: string;
  t?: string;
}

/** One tab (worksheet) of a sheet document, in its raw sparse form. */
export interface SheetTab {
  name?: string;
  title?: string;
  /** Sparse cell map keyed by A1 reference. */
  cells: Record<string, SheetCell>;
  /** The API's raw shape is a 1-based numeric-string map ({ "1": 120 } = column
   * A); an A1-letter map ({ "A": 120 }) and a positional array are also accepted. */
  col_widths?: Record<string, number> | number[];
  /** Row-index-keyed heights. */
  row_heights?: Record<string, number>;
  /** The API's raw shape is A1-range strings ("B3:C3"); [r1,c1,r2,c2] tuples
   * and {row,col,rowspan,colspan} objects are also accepted. */
  merges?:
    | string[]
    | Array<[number, number, number, number]>
    | Array<{ row: number; col: number; rowspan: number; colspan: number }>;
  frozen_rows?: number;
  frozen_cols?: number;
}

/** A merged-cell region in normalized 0-based form: anchor (r,c) + span. */
export interface MergeRegion {
  r: number;
  c: number;
  rs: number;
  cs: number;
}

/** The dense, render-ready form of a single tab. */
export interface DensifiedTab {
  /** Row-major grid of computed values; `null` for empty cells. */
  rows: unknown[][];
  nRows: number;
  nCols: number;
  /** Per-column widths, length `nCols` (0 = unspecified). */
  colWidths: number[];
  /** Normalized merge regions (0-based anchor + spans). */
  merges: MergeRegion[];
}

/**
 * Parse an A1 reference ("A1", "E6", "AA12") into a 0-based (row, col) pair.
 *
 * Column letters are base-26 *bijective* (A=1 … Z=26, AA=27), then shifted to
 * 0-based: A→0, Z→25, AA→26. Trailing digits are the 1-based row, shifted to
 * row−1. Returns null when the key isn't a clean A1 reference (so callers can
 * skip junk keys without throwing).
 */
export function parseA1(ref: string): { row: number; col: number } | null {
  const m = /^([A-Za-z]+)(\d+)$/.exec(ref.trim());
  if (!m) return null;
  const letters = m[1].toUpperCase();
  let col = 0;
  for (let i = 0; i < letters.length; i++) {
    col = col * 26 + (letters.charCodeAt(i) - 64); // 'A' (65) → 1
  }
  col -= 1; // bijective base-26 → 0-based
  const row = Number.parseInt(m[2], 10) - 1;
  if (row < 0 || col < 0) return null;
  return { row, col };
}

/** Read a column width for 0-based index `c` from either supported shape. */
function widthAt(
  col_widths: SheetTab["col_widths"],
  c: number,
): number {
  if (!col_widths) return 0;
  if (Array.isArray(col_widths)) {
    const w = col_widths[c];
    return typeof w === "number" ? w : 0;
  }
  // Map shape — keyed by A1 column letters ("A"), the API's canonical 1-based
  // numeric string ("1" = column A), or a 0-based numeric string. Probe in that
  // order: the 1-based form is what raw sheet tabs actually ship, so it must
  // win over the ambiguous 0-based fallback (where "1" would mean column B).
  const byLetter = col_widths[colToLetters(c)];
  if (typeof byLetter === "number") return byLetter;
  const byOneBased = col_widths[String(c + 1)];
  if (typeof byOneBased === "number") return byOneBased;
  const byZeroBased = col_widths[String(c)];
  return typeof byZeroBased === "number" ? byZeroBased : 0;
}

/** Inverse of the A1 column parse: 0-based index → bijective base-26 letters. */
export function colToLetters(c: number): string {
  let n = c + 1; // back to 1-based for the bijective math
  let out = "";
  while (n > 0) {
    const rem = (n - 1) % 26;
    out = String.fromCharCode(65 + rem) + out;
    n = Math.floor((n - 1) / 26);
  }
  return out;
}

/** Normalize the two accepted merge shapes into {@link MergeRegion}s. */
function normalizeMerges(merges: SheetTab["merges"]): MergeRegion[] {
  if (!Array.isArray(merges)) return [];
  const out: MergeRegion[] = [];
  for (const m of merges) {
    if (typeof m === "string") {
      // The API's raw shape: an A1 range "B3:C3". Parse both corners; skip
      // anything that isn't a clean two-corner range (mirrors the Elixir
      // synthesis, which is total over malformed input).
      const parts = m.split(":");
      if (parts.length !== 2) continue;
      const p1 = parseA1(parts[0]);
      const p2 = parseA1(parts[1]);
      if (p1 && p2) {
        out.push({
          r: Math.min(p1.row, p2.row),
          c: Math.min(p1.col, p2.col),
          rs: Math.abs(p2.row - p1.row) + 1,
          cs: Math.abs(p2.col - p1.col) + 1,
        });
      }
    } else if (Array.isArray(m)) {
      // [r1, c1, r2, c2] — inclusive bounds → anchor + spans.
      const [r1, c1, r2, c2] = m;
      if (
        typeof r1 === "number" &&
        typeof c1 === "number" &&
        typeof r2 === "number" &&
        typeof c2 === "number"
      ) {
        out.push({
          r: Math.min(r1, r2),
          c: Math.min(c1, c2),
          rs: Math.abs(r2 - r1) + 1,
          cs: Math.abs(c2 - c1) + 1,
        });
      }
    } else if (m && typeof m === "object") {
      const { row, col, rowspan, colspan } = m;
      if (typeof row === "number" && typeof col === "number") {
        out.push({
          r: row,
          c: col,
          rs: typeof rowspan === "number" && rowspan > 0 ? rowspan : 1,
          cs: typeof colspan === "number" && colspan > 0 ? colspan : 1,
        });
      }
    }
  }
  return out;
}

/**
 * Densify a sparse tab into a render-ready grid.
 *
 * Walks every A1 key to find the occupied bounds (max row, max col), allocates
 * a `nRows × nCols` rectangle of `null`, and drops each cell's computed value
 * (`cell.v`) into place. Column widths and merges are normalized to positional
 * arrays / 0-based regions so the renderer never re-parses A1.
 *
 * An empty tab densifies to a 0×0 grid — the renderer handles the empty case.
 */
export function densifyTab(tab: SheetTab): DensifiedTab {
  const cells = tab.cells ?? {};
  let maxRow = -1;
  let maxCol = -1;
  const parsed: Array<{ row: number; col: number; v: unknown }> = [];

  for (const [ref, cell] of Object.entries(cells)) {
    const pos = parseA1(ref);
    if (!pos) continue;
    if (pos.row > maxRow) maxRow = pos.row;
    if (pos.col > maxCol) maxCol = pos.col;
    parsed.push({ row: pos.row, col: pos.col, v: cell?.v ?? null });
  }

  // Merges can extend past the last occupied cell — widen bounds to cover them.
  const merges = normalizeMerges(tab.merges);
  for (const m of merges) {
    if (m.r + m.rs - 1 > maxRow) maxRow = m.r + m.rs - 1;
    if (m.c + m.cs - 1 > maxCol) maxCol = m.c + m.cs - 1;
  }

  const nRows = maxRow + 1;
  const nCols = maxCol + 1;

  const rows: unknown[][] = Array.from({ length: nRows }, () =>
    new Array<unknown>(nCols).fill(null),
  );
  for (const { row, col, v } of parsed) {
    rows[row][col] = v;
  }

  const colWidths: number[] = new Array<number>(nCols).fill(0);
  for (let c = 0; c < nCols; c++) {
    colWidths[c] = widthAt(tab.col_widths, c);
  }

  return { rows, nRows, nCols, colWidths, merges };
}
