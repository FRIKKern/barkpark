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

/** A per-cell style hint (the raw tab's `"s"` map), mirroring the four keys
 * `Core.cell_style/1` projects: bold, italic, background hex, alignment. */
export interface CellStyle {
  b?: boolean;
  i?: boolean;
  bg?: string;
  al?: string;
}

/** One cell in a sparse sheet tab. `v` is the computed value; `f` the formula
 * source; `t` an optional type hint ("n" | "s" | "b" | "d" | …); `s` the style
 * map; `fmt` the coarse format class ("percent" | "currency" | …). */
export interface SheetCell {
  v?: unknown;
  f?: string;
  t?: string;
  s?: CellStyle;
  fmt?: string;
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
  /** The schema stores frozen bands as strings; in-memory writers may carry an
   * integer. Both shapes are accepted (mirrors `Core.frozen_rows/1`). */
  frozen_rows?: number | string;
  frozen_cols?: number | string;
}

/**
 * Max cells a single merge region may cover before we drop it. A hostile doc
 * ("A1:XFD1048576") otherwise expands to ~1.7e10 covered-cell Set inserts and
 * freezes/OOMs the browser tab. Mirrors the server's cap — keep in lockstep
 * with `@merge_area_cap` in
 * `api/lib/barkpark/portable_doc/render/walk.ex` (canonical value 10_000).
 */
export const MERGE_AREA_CAP = 10_000;

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
  /** Sanitized per-cell styles, keyed `"row,col"` over the FULL grid (0-based,
   * before any head-band split). */
  styles: Record<string, CellStyle>;
  /** Per-cell format classes, keyed `"row,col"` over the FULL grid (0-based). */
  fmts: Record<string, string>;
  /** Number of frozen leading rows/cols (parsed from number or numeric string). */
  frozenRows: number;
  frozenCols: number;
}

/** The head-split, render-ready projection consumed by the grid: body rows with
 * an optional head band, plus styles/fmts/merges re-keyed to the BODY grid — the
 * TS twin of the server's snapshot synthesis (`Core.build_snapshot/1`). */
export interface RenderModel {
  rows: unknown[][];
  head?: unknown[];
  styles: Record<string, CellStyle>;
  fmts: Record<string, string>;
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

/* ── display formatting (Elixir twin) ───────────────────────────────────────
 *
 * `numberToDisplay` mirrors `Core.number_to_display/1` and `formatDisplay`
 * mirrors `Fmt.display/2` — the raw document view is the only web surface that
 * formats values itself (paper embeds ship server-rendered strings). Semantics
 * are LOCKED by web/__tests__/fixtures/fmt-display-parity.json, generated from
 * the Elixir functions and asserted on both runtimes.
 */

/** The six format classes; anything else is "general" (delegates to
 * `numberToDisplay`). Mirrors `Map.keys(@canonical)` in
 * `api/lib/barkpark/plugins/sheets/fmt.ex` — i.e. `Fmt.vocabulary/0` MINUS
 * the display-only `"checkbox"`, which Studio renders as a toggle glyph and
 * this view never formats. That difference is LOCKED (both directions, plus
 * a second silent exclusion) by the FMT_CLASSES mirror test in
 * `api/test/barkpark/sheets_parity_test.exs`, which runs under the required
 * Elixir gate. */
const FMT_CLASSES = new Set([
  "fixed",
  "percent",
  "currency",
  "thousands",
  "date",
  "datetime",
]);

/**
 * Excel-General-like number → display string. Twin of `Core.number_to_display/1`
 * (`api/lib/barkpark/plugins/sheets/core.ex`): integral magnitudes below 1e15
 * render as plain integers; other values use the shortest round-trip form,
 * expanded to plain decimal inside `[1e-6, 1e15)` and kept in Erlang-shaped
 * exponent form (`1.0e15`, `1.0e-7`) outside it.
 */
export function numberToDisplay(v: number): string {
  if (!Number.isFinite(v)) return String(v);
  if (Number.isInteger(v) && Math.abs(v) < 1e15) {
    return String(Math.trunc(v));
  }
  const a = Math.abs(v);
  if (a >= 1e-6 && a < 1e15) {
    // Plain-decimal band. JS prints most of these without an exponent; tiny
    // magnitudes (< 1e-6 boundary excluded here) it renders as "1e-…", so
    // expand via toFixed then strip trailing zeros/dot (mirrors the Erlang
    // float_to_binary decimals:12 + trim path).
    const s = String(v);
    if (s.includes("e") || s.includes("E")) {
      return v.toFixed(12).replace(/0+$/, "").replace(/\.$/, "");
    }
    return s;
  }
  // Exponent-kept band (>= 1e15 or < 1e-6): normalize JS exponent shape to
  // Erlang's ("1e+15" → "1.0e15", "1e-7" → "1.0e-7").
  const [mant, exp] = v.toExponential().split("e");
  const m = mant.includes(".") ? mant : `${mant}.0`;
  const sign = exp.startsWith("-") ? "-" : "";
  const digits = exp.replace(/^[+-]/, "").replace(/^0+(?=\d)/, "");
  return `${m}e${sign}${digits}`;
}

/** Round half away from zero (Elixir `Kernel.round/1`, Excel half-up), unlike
 * JS `Math.round` which rounds half toward +∞. */
function roundHalfAwayFromZero(x: number): number {
  return x < 0 ? -Math.round(-x) : Math.round(x);
}

/** Comma-group an integer digit string every three from the right. */
function groupThousands(digits: string): string {
  const out: string[] = [];
  for (let i = digits.length; i > 0; i -= 3) {
    out.unshift(digits.slice(Math.max(0, i - 3), i));
  }
  return out.join(",");
}

/** A number → {negative?, unsigned body} with `decimals` fixed places and
 * optional comma grouping — the twin of `Fmt.format_number/3`. */
function formatNumber(
  v: number,
  decimals: number,
  group: boolean,
): { neg: boolean; body: string } {
  const scale = 10 ** decimals;
  let scaled = roundHalfAwayFromZero(v * scale);
  const neg = scaled < 0;
  scaled = Math.abs(scaled);
  const intPart = Math.floor(scaled / scale);
  const intStr = group
    ? groupThousands(String(intPart))
    : String(intPart);
  if (decimals > 0) {
    const frac = String(scaled % scale).padStart(decimals, "0");
    return { neg, body: `${intStr}.${frac}` };
  }
  return { neg, body: intStr };
}

/** Parse an ISO-8601 date / datetime the way xlsx import stores them, without
 * JS `Date` (which would timezone-shift). Returns null for anything unparseable,
 * matching the verbatim fallback in `Fmt.date_part/1`. */
function parseIso(v: string): { date: string; time: string | null } | null {
  const m =
    /^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2}):(\d{2})(?:\.\d+)?)?$/.exec(v);
  if (!m) return null;
  const [, y, mo, d, hh, mm, ss] = m;
  if (+mo < 1 || +mo > 12 || +d < 1 || +d > 31) return null;
  const date = `${y}-${mo}-${d}`;
  if (hh === undefined) return { date, time: null };
  if (+hh > 23 || +mm > 59 || +ss > 59) return null;
  return { date, time: `${hh}:${mm}:${ss}` };
}

function datePart(v: string): string {
  const dt = parseIso(v);
  return dt ? dt.date : v;
}

function datetimePart(v: string): string {
  const dt = parseIso(v);
  if (!dt) return v;
  return dt.time ? `${dt.date} ${dt.time}` : dt.date;
}

/**
 * The engine's error vocabulary — every `"#…!"` string a computed cell can
 * hold. Mirrors `Engine.error_values/0`; the set is LOCKED against the Elixir
 * source by web/__tests__/fixtures/engine-errors.json (generated from the
 * engine, asserted on both runtimes) so a new code can't drift out of sync.
 */
export const ENGINE_ERRORS: ReadonlySet<string> = new Set([
  "#CYCLE!",
  "#REF!",
  "#VALUE!",
  "#DIV/0!",
  "#N/A",
  "#NUM!",
  "#SPILL!",
  "#NAME?",
]);

/** True when a cell's computed value is an engine error code — the grid marks
 * such cells red/bold. Non-strings and ordinary text are never errors. */
export function isEngineError(v: unknown): boolean {
  return typeof v === "string" && ENGINE_ERRORS.has(v);
}

/**
 * True when the WHOLE string is an http(s) URL — the display-time link
 * predicate. The TS twin of walk.ex `@sheet_url_re` and Studio `Cells.link?/1`:
 * pins http(s) and bans whitespace/quote/angle chars so an attribute-breaking
 * payload never matches ("see http://x" reads false). The scheme allowlist is
 * re-checked at render via `safeHref`; this only gates the anchor affordance.
 */
export function isHttpUrl(s: unknown): boolean {
  return typeof s === "string" && /^https?:\/\/[^\s<>"']+$/i.test(s);
}

/**
 * Render a cell value for display (no fmt class) — twin of the general path of
 * `Fmt.display/2`. Numbers via {@link numberToDisplay}, booleans as TRUE/FALSE,
 * strings verbatim, everything else JSON-ish.
 */
export function displayValue(v: unknown): string {
  if (v == null) return "";
  if (typeof v === "number" && Number.isFinite(v)) return numberToDisplay(v);
  if (typeof v === "boolean") return v ? "TRUE" : "FALSE";
  if (typeof v === "string") return v;
  try {
    return JSON.stringify(v);
  } catch {
    return String(v);
  }
}

/**
 * Render a cell value under its `fmt` class — the exact twin of `Fmt.display/2`.
 * Booleans always render TRUE/FALSE; number classes use half-away-from-zero
 * rounding (percent/fixed 2 decimals, thousands grouped integer, currency
 * `$`-prefixed with the sign OUTSIDE the symbol); date/datetime operate on ISO
 * strings; any type/class mismatch or absent/unknown fmt falls through to
 * {@link displayValue}.
 */
export function formatDisplay(v: unknown, fmt?: string): string {
  if (typeof v === "boolean") return v ? "TRUE" : "FALSE";

  if (typeof v === "number" && Number.isFinite(v)) {
    // Near-ceiling floats overflow the numeric clauses' pre-format multiply
    // (percent's v*100, currency/fixed/thousands' 10^decimals scale). The
    // Elixir twin RAISES there; JS would silently emit Infinity. Both route
    // to the overflow-safe general/exponent path — twin of `Fmt.display/2`'s
    // is_float `abs(v) >= 1.0e300` fall-through.
    if (
      Math.abs(v) >= 1e300 &&
      (fmt === "percent" ||
        fmt === "fixed" ||
        fmt === "thousands" ||
        fmt === "currency")
    ) {
      return numberToDisplay(v);
    }

    switch (fmt) {
      case "percent": {
        const { neg, body } = formatNumber(v * 100, 2, false);
        return `${neg ? "-" : ""}${body}%`;
      }
      case "fixed": {
        const { neg, body } = formatNumber(v, 2, false);
        return `${neg ? "-" : ""}${body}`;
      }
      case "thousands": {
        const { neg, body } = formatNumber(v, 0, true);
        return `${neg ? "-" : ""}${body}`;
      }
      case "currency": {
        const { neg, body } = formatNumber(v, 2, true);
        return `${neg ? "-" : ""}$${body}`;
      }
      // date/datetime on a number, or general/unknown → general path.
      default:
        return numberToDisplay(v);
    }
  }

  if (typeof v === "string") {
    if (fmt === "date") return datePart(v);
    if (fmt === "datetime") return datetimePart(v);
    return v;
  }

  return displayValue(v);
}

/* ── snapshot presentation helpers ───────────────────────────────────────────
 *
 * A snapshot's values arrive as already-formatted strings ("25.00%", "$1,234.50")
 * — the fmt class was applied server-side. `looksNumericDisplay` recognises those
 * so the renderer can right-align them like real numbers, and `truncationNotice`
 * surfaces the position-cap clip the server marks with `truncated`.
 */

// A number as `Fmt.display` / `Core.number_to_display` emits it: optional
// parens/sign, optional currency symbol, grouped or plain integer, optional
// decimals, optional percent. The second form also accepts bare exponent
// notation ("1e-7"). Grouping must be exact 3-digit runs — "1,23" fails.
const NUMERIC_DISPLAY_GROUPED = /^\(?-?[$€£¥]?\d{1,3}(,\d{3})*(\.\d+)?%?\)?$/;
const NUMERIC_DISPLAY_PLAIN = /^-?\d+(\.\d+)?(e[+-]?\d+)?%?$/i;

/**
 * Does a display string read as a formatted number? Used to right-align snapshot
 * cells whose values are pre-formatted strings ("25.00%", "$1,234.50", "-3.5",
 * "1e-7") rather than raw numbers. Empty / non-numeric text ("", "abc",
 * "12 apples", "A1", "1,23") reads false.
 */
export function looksNumericDisplay(s: string): boolean {
  return NUMERIC_DISPLAY_GROUPED.test(s) || NUMERIC_DISPLAY_PLAIN.test(s);
}

/**
 * The muted "partial data" note for a clipped snapshot, or null when the grid is
 * whole. Text matches the server walker (`Walk.sheet_truncation_note/3`): N is the
 * number of body rows actually present in the snapshot.
 */
export function truncationNotice(snapshot: {
  rows?: unknown[][];
  truncated?: boolean;
  total_rows?: number;
}): string | null {
  if (!snapshot?.truncated) return null;
  const shown = Array.isArray(snapshot.rows) ? snapshot.rows.length : 0;
  return `Sheet truncated — showing the first ${shown} rows`;
}

/** Normalize the three accepted merge shapes (A1-range string, [r1,c1,r2,c2]
 * tuple, {row,col,rowspan,colspan} object) into {@link MergeRegion}s. */
function normalizeMerges(merges: SheetTab["merges"]): MergeRegion[] {
  if (!Array.isArray(merges)) return [];
  const out: MergeRegion[] = [];
  // Accept a candidate region only when its anchor is a real 0-based cell and
  // its area stays within MERGE_AREA_CAP — a hostile "A1:XFD1048576" otherwise
  // blows up downstream covered-cell expansion. Skip (drop), don't clamp, to
  // mirror the server's `rs * cs <= @merge_area_cap` guard in walk.ex.
  const push = (r: number, c: number, rs: number, cs: number) => {
    if (!Number.isFinite(r) || !Number.isFinite(c) || r < 0 || c < 0) return;
    if (rs * cs > MERGE_AREA_CAP) return;
    out.push({ r, c, rs, cs });
  };
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
        push(
          Math.min(p1.row, p2.row),
          Math.min(p1.col, p2.col),
          Math.abs(p2.row - p1.row) + 1,
          Math.abs(p2.col - p1.col) + 1,
        );
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
        push(
          Math.min(r1, r2),
          Math.min(c1, c2),
          Math.abs(r2 - r1) + 1,
          Math.abs(c2 - c1) + 1,
        );
      }
    } else if (m && typeof m === "object") {
      const { row, col, rowspan, colspan } = m;
      if (typeof row === "number" && typeof col === "number") {
        push(
          row,
          col,
          typeof rowspan === "number" && rowspan > 0 ? rowspan : 1,
          typeof colspan === "number" && colspan > 0 ? colspan : 1,
        );
      }
    }
  }
  return out;
}

/** Sanitize a raw cell `"s"` map to the four keys the server keeps, dropping
 * anything junk — the twin of `Core.cell_style/1`. Returns null when nothing
 * survives (so the caller records no style entry). */
function sanitizeStyle(s: SheetCell["s"]): CellStyle | null {
  if (!s || typeof s !== "object") return null;
  const out: CellStyle = {};
  if (s.b === true) out.b = true;
  if (s.i === true) out.i = true;
  if (typeof s.bg === "string") {
    const bg = s.bg.toLowerCase();
    if (/^#[0-9a-f]{6}$/.test(bg)) out.bg = bg;
  }
  if (s.al === "left" || s.al === "center" || s.al === "right") out.al = s.al;
  return Object.keys(out).length > 0 ? out : null;
}

/** Frozen-band count from a number or numeric string (twin of
 * `Core.frozen_rows/1`); anything else means zero. */
function frozenCount(v: number | string | undefined): number {
  if (typeof v === "number" && Number.isInteger(v) && v > 0) return v;
  if (typeof v === "string") {
    const n = Number.parseInt(v, 10);
    return Number.isInteger(n) && n > 0 ? n : 0;
  }
  return 0;
}

/**
 * Densify a sparse tab into a render-ready grid.
 *
 * Walks every A1 key to find the occupied bounds (max row, max col), allocates
 * a `nRows × nCols` rectangle of `null`, and drops each cell's computed value
 * (`cell.v`) into place. Column widths and merges are normalized to positional
 * arrays / 0-based regions so the renderer never re-parses A1. Per-cell styles
 * and fmt classes are collected into `"row,col"`-keyed maps over the full grid
 * (head-band split happens later, in {@link toRenderModel}).
 *
 * An empty tab densifies to a 0×0 grid — the renderer handles the empty case.
 */
export function densifyTab(tab: SheetTab): DensifiedTab {
  // A stray far-down/far-right cell (e.g. "XFD1048576") would otherwise size a
  // multi-billion-cell grid and OOM/freeze the tab — cap the allocation.
  const MAX_ROWS = 5000;
  const MAX_COLS = 256;
  const cells = tab.cells ?? {};
  let maxRow = -1;
  let maxCol = -1;
  const parsed: Array<{
    row: number;
    col: number;
    v: unknown;
    s: CellStyle | null;
    fmt: string | null;
  }> = [];

  for (const [ref, cell] of Object.entries(cells)) {
    const pos = parseA1(ref);
    if (!pos) continue;
    if (pos.row > maxRow) maxRow = pos.row;
    if (pos.col > maxCol) maxCol = pos.col;
    const fmt =
      typeof cell?.fmt === "string" && FMT_CLASSES.has(cell.fmt)
        ? cell.fmt
        : null;
    parsed.push({
      row: pos.row,
      col: pos.col,
      v: cell?.v ?? null,
      s: sanitizeStyle(cell?.s),
      fmt,
    });
  }

  // Merges can extend past the last occupied cell — widen bounds to cover them.
  const merges = normalizeMerges(tab.merges);
  for (const m of merges) {
    if (m.r + m.rs - 1 > maxRow) maxRow = m.r + m.rs - 1;
    if (m.c + m.cs - 1 > maxCol) maxCol = m.c + m.cs - 1;
  }

  const nRows = Math.min(maxRow + 1, MAX_ROWS);
  const nCols = Math.min(maxCol + 1, MAX_COLS);

  const rows: unknown[][] = Array.from({ length: nRows }, () =>
    new Array<unknown>(nCols).fill(null),
  );
  const styles: Record<string, CellStyle> = {};
  const fmts: Record<string, string> = {};
  for (const { row, col, v, s, fmt } of parsed) {
    if (row < nRows && col < nCols) {
      rows[row][col] = v;
      if (s) styles[`${row},${col}`] = s;
      if (fmt) fmts[`${row},${col}`] = fmt;
    }
  }

  const colWidths: number[] = new Array<number>(nCols).fill(0);
  for (let c = 0; c < nCols; c++) {
    colWidths[c] = widthAt(tab.col_widths, c);
  }

  return {
    rows,
    nRows,
    nCols,
    colWidths,
    merges,
    styles,
    fmts,
    frozenRows: frozenCount(tab.frozen_rows),
    frozenCols: frozenCount(tab.frozen_cols),
  };
}

/**
 * Project a {@link DensifiedTab} into a {@link RenderModel}: split off the head
 * band when rows are frozen and re-key styles/fmts/merges to the BODY grid —
 * the TS twin of the server's `Core.build_snapshot/1` head-band derivation
 * (`maybe_put_head` / `maybe_put_styles` / `maybe_put_merges`).
 *
 * Only `frozen_rows >= 1` promotes row 0 to the head band (matching the server;
 * frozen columns are not yet reflected here — sticky-column rendering is
 * deferred). Head STYLES are dropped (the head band carries its own fixed
 * style), but fmt DISPLAY is applied to head values first — each head cell is
 * rendered through `formatDisplay` with its row-0 fmt — and only then is the
 * fmt key dropped (so `{v: 0.25, fmt: "percent"}` heads read "25.00%" like on
 * every other surface; plain strings pass verbatim through `displayValue`).
 * Merges are clipped to start at the body.
 */
export function toRenderModel(dense: DensifiedTab): RenderModel {
  const dataStart = dense.frozenRows >= 1 ? 1 : 0;
  const head = dataStart
    ? dense.rows[0].map((v, c) => formatDisplay(v, dense.fmts[`0,${c}`]))
    : undefined;
  const rows = dense.rows.slice(dataStart);

  const rekey = <T>(src: Record<string, T>): Record<string, T> => {
    if (dataStart === 0) return src;
    const out: Record<string, T> = {};
    for (const [key, val] of Object.entries(src)) {
      const [r, c] = key.split(",").map(Number);
      if (r >= dataStart) out[`${r - dataStart},${c}`] = val;
    }
    return out;
  };

  const maxRow = dense.nRows - 1;
  const maxCol = dense.nCols - 1;
  const merges: MergeRegion[] = [];
  for (const m of dense.merges) {
    const r1 = Math.max(m.r, dataStart);
    const c1 = m.c;
    const r2 = Math.min(m.r + m.rs - 1, maxRow);
    const c2 = Math.min(m.c + m.cs - 1, maxCol);
    // Drop ranges that clip to nothing or to a single cell (no span left).
    if (r1 > r2 || c1 > c2 || (r1 === r2 && c1 === c2)) continue;
    merges.push({ r: r1 - dataStart, c: c1, rs: r2 - r1 + 1, cs: c2 - c1 + 1 });
  }

  return {
    rows,
    head,
    styles: rekey(dense.styles),
    fmts: rekey(dense.fmts),
    merges,
  };
}
