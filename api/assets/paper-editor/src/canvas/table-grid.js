// table-grid.js — merged cells for the table block (Barkdown plan #24), one model for the canvas
// (table-node.js: transforms + merge/split chrome) and the diff (run-convert.js: block ⇄ node).
//
// STORAGE. The table block stays a rectangular grid — `head` (optional) and `rows`, every row the
// same width — so the strict editable grammar (table_editing.ex) and every positional action keep
// holding. A merge adds an entry to a sibling list on the block:
//
//   "spans": [{ "row": <body row index>, "col": <column>, "colspan": <n>, "rowspan": <m> }]
//
// and the positions a span covers keep a PLACEHOLDER cell (`[]`, an empty inline array) in `rows`.
// The reader skips covered positions and emits colspan/rowspan on the origin; BPML prints every
// cell and spells the span as attributes on the origin's <td>. Spans live in body rows only — the
// header row is never merged (Notion does not merge at all; a header that spans is a layout, not
// a table).
//
// CANVAS. ProseMirror holds only VISIBLE cells (covered positions have no node — that is how a
// browser table lays out), and each cell node carries `colspan` / `rowspan` attributes. This module
// converts between the two: the grid (rectangular rows + spans) and the visible rows.

export const PLACEHOLDER_CELL = [];

function int(v, min) {
  const n = Number(v);
  return Number.isInteger(n) && n >= min ? n : null;
}

// Spans as stored → validated, in-grid, sorted by (row, col); malformed or out-of-grid entries drop.
export function normalizeSpans(spans, nBodyRows, nCols) {
  if (!Array.isArray(spans)) return [];
  const out = [];
  const taken = new Set();
  for (const s of spans) {
    if (!s || typeof s !== "object") continue;
    const row = int(s.row, 0), col = int(s.col, 0);
    const colspan = int(s.colspan, 1) ?? 1, rowspan = int(s.rowspan, 1) ?? 1;
    if (row == null || col == null) continue;
    if (colspan === 1 && rowspan === 1) continue;
    if (row >= nBodyRows || col >= nCols) continue;
    const cs = Math.min(colspan, nCols - col), rs = Math.min(rowspan, nBodyRows - row);
    if (cs === 1 && rs === 1) continue;
    // Overlapping spans are not a grid: first one wins.
    let clash = false;
    for (let r = row; r < row + rs && !clash; r++) for (let c = col; c < col + cs; c++) if (taken.has(r + "," + c)) { clash = true; break; }
    if (clash) continue;
    for (let r = row; r < row + rs; r++) for (let c = col; c < col + cs; c++) taken.add(r + "," + c);
    out.push({ row, col, colspan: cs, rowspan: rs });
  }
  out.sort((a, b) => a.row - b.row || a.col - b.col);
  return out;
}

// Body position → the span that covers it without being its origin (null when the position is
// visible). Keyed "r,c".
export function coverMap(spans) {
  const m = new Map();
  for (const s of spans) {
    for (let r = s.row; r < s.row + s.rowspan; r++) {
      for (let c = s.col; c < s.col + s.colspan; c++) {
        if (r === s.row && c === s.col) continue;
        m.set(r + "," + c, s);
      }
    }
  }
  return m;
}

export function spanAt(spans, row, col) {
  return spans.find((s) => s.row === row && s.col === col) || null;
}

// A GRID: { head: cell[] | null, rows: cell[][], spans } with every row `width` cells; covered
// positions hold whatever the storage holds (a placeholder). `cell` is opaque here (a stored cell
// or a canvas descriptor).
//
// gridToVisible: the rows the canvas mounts — header row first (when head), then body rows with
// covered positions removed and colspan/rowspan on the origins.
export function gridToVisible(grid) {
  const spans = normalizeSpans(grid.spans, grid.rows.length, width(grid));
  const covered = coverMap(spans);
  const out = [];
  if (grid.head) out.push({ header: true, cells: grid.head.map((cell) => ({ cell, colspan: 1, rowspan: 1 })) });
  grid.rows.forEach((row, r) => {
    const cells = [];
    row.forEach((cell, c) => {
      if (covered.has(r + "," + c)) return;
      const s = spanAt(spans, r, c);
      cells.push({ cell, colspan: s ? s.colspan : 1, rowspan: s ? s.rowspan : 1 });
    });
    out.push({ header: false, cells });
  });
  return out;
}

// visibleToGrid: from the rows the canvas holds (header flag + visible cells with spans) back to the
// rectangular grid. `placeholder()` makes the stored cell for a covered position; `width` is the
// first row's span sum (a table always has at least one row).
export function visibleToGrid(visible, placeholder = () => PLACEHOLDER_CELL) {
  const headRow = visible.length && visible[0].header ? visible[0] : null;
  const bodyRows = visible.filter((r, i) => !(i === 0 && r.header));
  const spanSum = (row) => row.cells.reduce((n, c) => n + Math.max(1, c.colspan || 1), 0);
  let w = headRow ? spanSum(headRow) : bodyRows.length ? spanSum(bodyRows[0]) : 1;
  // A body row that is wider than the head (or the first row) widens the grid; ragged rows pad.
  for (const row of bodyRows) w = Math.max(w, spanSum(row));
  const spans = [];
  const covered = new Map(); // "r,c" → true, from rowspans above
  const rows = bodyRows.map((row, r) => {
    const cells = new Array(w).fill(null);
    let c = 0;
    for (const vc of row.cells) {
      while (c < w && covered.has(r + "," + c)) { cells[c] = placeholder(); c++; }
      if (c >= w) break; // more visible cells than the grid holds: drop the overflow
      const cs = Math.max(1, Math.min(vc.colspan || 1, w - c));
      const rs = Math.max(1, Math.min(vc.rowspan || 1, bodyRows.length - r));
      cells[c] = vc.cell;
      for (let k = 1; k < cs; k++) cells[c + k] = placeholder();
      if (cs > 1 || rs > 1) spans.push({ row: r, col: c, colspan: cs, rowspan: rs });
      for (let rr = r + 1; rr < r + rs; rr++) for (let cc = c; cc < c + cs; cc++) covered.set(rr + "," + cc, true);
      c += cs;
    }
    for (; c < w; c++) cells[c] = placeholder();
    return cells;
  });
  const head = headRow ? headRow.cells.map((vc) => vc.cell).concat(Array.from({ length: Math.max(0, w - headRow.cells.length) }, placeholder)) : null;
  return { head, rows, spans: normalizeSpans(spans, rows.length, w) };
}

export function width(grid) {
  if (grid.head && grid.head.length) return grid.head.length;
  return grid.rows.length ? grid.rows[0].length : 0;
}

// ── structural transforms on a grid (rectangular rows + spans) ─────────────────────────────────
export const gridTransforms = {
  addRow(grid, placeholder) {
    const w = width(grid) || 1;
    grid.rows.push(Array.from({ length: w }, placeholder));
  },
  // Removes the LAST body row; a span reaching it shrinks.
  removeRow(grid) {
    if (grid.rows.length <= 1) return;
    const last = grid.rows.length - 1;
    grid.rows.pop();
    grid.spans = normalizeSpans((grid.spans || []).map((s) => ({ ...s, rowspan: Math.min(s.rowspan, last - s.row) })), grid.rows.length, width(grid));
  },
  addCol(grid, placeholder) {
    if (grid.head) grid.head.push(placeholder());
    grid.rows.forEach((row) => row.push(placeholder()));
  },
  // Removes the LAST column; a span reaching it shrinks.
  removeCol(grid) {
    const w = width(grid);
    if (w <= 1) return;
    if (grid.head) grid.head.pop();
    grid.rows.forEach((row) => row.pop());
    grid.spans = normalizeSpans((grid.spans || []).map((s) => ({ ...s, colspan: Math.min(s.colspan, w - 1 - s.col) })), grid.rows.length, w - 1);
  },
  // Header on: the first body row becomes the head (its spans are split first — a head never spans).
  // Header off: the head becomes the first body row (span rows shift down by one).
  toggleHeader(grid, placeholder) {
    if (grid.head) {
      grid.rows.unshift(grid.head);
      grid.head = null;
      grid.spans = normalizeSpans((grid.spans || []).map((s) => ({ ...s, row: s.row + 1 })), grid.rows.length, width(grid));
    } else if (grid.rows.length > 1) {
      gridTransforms.splitRow(grid, 0, placeholder);
      grid.head = grid.rows.shift();
      grid.spans = normalizeSpans((grid.spans || []).map((s) => ({ ...s, row: s.row - 1 })), grid.rows.length, width(grid));
    }
  },
  // Merge the rectangle (r0,c0)–(r1,c1) of body rows into one cell: the origin keeps its content,
  // the others become placeholders (their text is appended to the origin by the caller if wanted).
  merge(grid, r0, c0, r1, c1) {
    const w = width(grid);
    const top = Math.min(r0, r1), left = Math.min(c0, c1), bottom = Math.max(r0, r1), right = Math.max(c0, c1);
    if (top < 0 || left < 0 || bottom >= grid.rows.length || right >= w) return false;
    // Widen the rectangle to swallow any span it touches, so the result is a grid.
    let changed = true;
    let T = top, L = left, B = bottom, R = right;
    while (changed) {
      changed = false;
      for (const s of grid.spans || []) {
        const sB = s.row + s.rowspan - 1, sR = s.col + s.colspan - 1;
        const touches = !(sB < T || s.row > B || sR < L || s.col > R);
        if (touches) {
          const nT = Math.min(T, s.row), nL = Math.min(L, s.col), nB = Math.max(B, sB), nR = Math.max(R, sR);
          if (nT !== T || nL !== L || nB !== B || nR !== R) { T = nT; L = nL; B = nB; R = nR; changed = true; }
        }
      }
    }
    if (T === B && L === R) return false;
    const rest = (grid.spans || []).filter((s) => s.row + s.rowspan - 1 < T || s.row > B || s.col + s.colspan - 1 < L || s.col > R);
    rest.push({ row: T, col: L, colspan: R - L + 1, rowspan: B - T + 1 });
    grid.spans = normalizeSpans(rest, grid.rows.length, w);
    return { row: T, col: L, colspan: R - L + 1, rowspan: B - T + 1 };
  },
  // Split the span whose origin or cover is at (r, c): covered positions become plain cells again
  // (they already hold placeholders).
  split(grid, r, c) {
    const spans = grid.spans || [];
    const covered = coverMap(spans);
    const s = spanAt(spans, r, c) || covered.get(r + "," + c) || null;
    if (!s) return false;
    grid.spans = spans.filter((x) => x !== s);
    return true;
  },
  splitRow(grid, r, _placeholder) {
    const spans = grid.spans || [];
    grid.spans = spans.filter((s) => !(s.row <= r && r <= s.row + s.rowspan - 1));
  },
};
