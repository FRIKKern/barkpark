// table-node.js — the `table` block as FOUR hand-rolled NESTED ProseMirror nodes
// (bpTable > bpTableRow > bpTableHeaderCell|bpTableCell), NOT @tiptap/extension-table.
//
// This is the lowest-risk in-canvas table: the reader (walk.ex table/3 :article)
// emits `<table class="bp-table"><thead>?<tbody>…` where every cell body is INLINE
// runs (compose.ex:406-425 pipes each cell through compose_inline_children →
// to_pd_node_from_inline_child — the SAME serializer the callout body uses). So a
// cell body is a PM `inline*` content hole, reusing convert.js's
// inlineArrayToTiptap / tiptapInlineToPd (run-convert.js owns the block⇄node map) —
// bold/italic/links round-trip for FREE. An atom-island writing textContent would
// silently STRIP marks on the live tables (a data-loss regression); the nested-PM
// path avoids it by construction.
//
// It reuses two established idioms:
//   * role-nodes.js — a plain Node.create whose renderHTML returns the reader tag +
//     a `0` content hole, NO node-view — for the rows/cells (bpTableRow / bpTableCell
//     / bpTableHeaderCell). Those never mount `document`, so run-convert.js (which
//     references only the node TYPE names via its own mappers, never this module)
//     stays importable in the pure-Node smoke harness.
//   * callout-node.js — ONE node-view with ONE contentDOM plus chrome OUTSIDE it —
//     for the bpTable wrapper carrying the add/remove row/col + toggle-header chrome.
//
// @tiptap/extension-table is deliberately NOT added — its column-resize /
// cellselection / merged-cell surface is far more than v1 needs and a big new dep.
//
// ── SCHEMA (four nodes) ──────────────────────────────────────────────────────
//
//   bpTable            group:"block", content:"bpTableRow+", isolating (a hard
//                      boundary so backspace/join at an edge can't merge a paragraph
//                      INTO the table or pull a row OUT — the v1 no-nesting guard),
//                      defining, selectable. bpId/bpType plus a PRIVATE, non-rendered
//                      source carrier (the editable grid still lives in PM child nodes,
//                      which is what earns free inline-mark editing — contrast
//                      code-node.js storing text in a `value` attr because its interior
//                      is non-PM). A node-view (chrome + tbody contentDOM).
//   bpTableRow         NO group (can NEVER appear at doc top level — only inside
//                      bpTable's content expression), content:"(bpTableHeaderCell |
//                      bpTableCell)+", defining. No node-view.
//   bpTableCell        NO group, content:"inline*", defining. inline* + no block
//                      children is the STRUCTURAL enforcement of the v1
//                      "forbid container-in-container" rule — a cell literally cannot
//                      hold a paragraph/section/columns/table, matching the reader.
//   bpTableHeaderCell  NO group, content:"inline*", defining. The header modeling: a
//                      header row is a bpTableRow whose cells are ALL bpTableHeaderCell.
//
// StarterKit ships NO table/tr/td/th node (tables need the separate, un-added
// @tiptap/extension-table), so — UNLIKE code (codeBlock:false) and divider
// (horizontalRule:false) — NO StarterKit node is disabled; the tags are unclaimed.
//
// ── THE thead DROP ───────────────────────────────────────────────────────────
// The reader splits header/body into <thead>/<tbody>; the edit table puts ALL rows
// (header + body) in the SINGLE <tbody> contentDOM. This is invisible: NO CSS targets
// thead/tbody (grep-verified) — all styling rides `.bp-table` / `.bp-table__th` /
// `.bp-table__td`, which the cells carry regardless of the wrapper. The header row is
// distinguished purely by its cells being bpTableHeaderCell (<th class="bp-table__th">).
// Justified in the parity gate exactly as the callout-structure slice's delta.
//
// DOM-aware (the node-view builds real DOM) but the Node SCHEMA objects load in plain
// Node — `document` is referenced ONLY inside the addNodeView factory, which never runs
// in the pure-Node harness (same lazy-DOM discipline as callout-node.js).

import { Node, mergeAttributes } from "@tiptap/core";
import { TextSelection } from "@tiptap/pm/state";
// Merged cells (plan #24): the grid <-> visible-rows model and its structural transforms.
import { visibleToGrid, gridToVisible, gridTransforms, coverMap, normalizeSpans, width as gridWidth } from "./table-grid.js";

// Shared bpId/bpType attr skeleton (the role-nodes.js roleAttributes shape). Only the
// bpTable carries identity — rows/cells are INTERNAL PM structure with NO bpId (one id
// for the whole table sidesteps per-cell id minting + intra-table duplicate_id).
function tableAttributes() {
  return {
    bpId: {
      default: null,
      parseHTML: (el) => el.getAttribute("data-bp-id"),
      renderHTML: (attrs) => (attrs.bpId ? { "data-bp-id": attrs.bpId } : {}),
    },
    bpType: {
      default: "table",
      parseHTML: (el) => el.getAttribute("data-bp-type"),
      renderHTML: (attrs) =>
        attrs.bpType ? { "data-bp-type": attrs.bpType } : {},
    },
    // Private source carrier used by run-convert's lossless storage lens. It is
    // deliberately absent from DOM parsing/rendering: pasted HTML can never mint
    // authoritative source metadata, while getJSON/history keep it with the node.
    bpTableSource: {
      default: null,
      rendered: false,
      keepOnSplit: false,
      parseHTML: () => null,
    },
    // Column widths in CSS pixels (plan #25), null where a column has none; painted by the node
    // view as a <colgroup>, stored on the block as `cols[i].width`. Not an HTML attribute.
    colWidths: {
      default: null,
      rendered: false,
      keepOnSplit: false,
      parseHTML: () => null,
    },
    // Header column (plan #26): the first cell of every body row is a row header (<th scope="row">).
    // Stored on the block as `headCol: true`; the cells' `head` attr is derived from it on build.
    headCol: {
      default: false,
      parseHTML: (el) => el.getAttribute("data-head-col") === "true",
      renderHTML: (attrs) => (attrs.headCol ? { "data-head-col": "true" } : {}),
    },
  };
}

function tableCellAttributes() {
  return {
    // The exact authored cell carrier (scalar, inline array, or content-map).
    // It follows its PM cell through row/column moves; newly inserted cells get
    // null, so an opaque identity is never duplicated onto fresh grid space.
    bpTableCellSource: {
      default: null,
      rendered: false,
      keepOnSplit: false,
      parseHTML: () => null,
    },
    // A merged cell (plan #24): how many columns / rows it spans. Rendered as the HTML attributes
    // so the browser lays the table out; the block stores them in `spans` (table-grid.js).
    colspan: {
      default: 1,
      parseHTML: (el) => Math.max(1, parseInt(el.getAttribute("colspan") || "1", 10) || 1),
      renderHTML: (attrs) => (attrs.colspan > 1 ? { colspan: attrs.colspan } : {}),
    },
    rowspan: {
      default: 1,
      parseHTML: (el) => Math.max(1, parseInt(el.getAttribute("rowspan") || "1", 10) || 1),
      renderHTML: (attrs) => (attrs.rowspan > 1 ? { rowspan: attrs.rowspan } : {}),
    },
    // Per-cell alignment (plan #26): "center" | "right" (left is the absence). Stored on the cell as
    // a content-map `{ content, align }`; painted as an inline text-align like the reader does.
    align: {
      default: null,
      parseHTML: (el) => { const a = el.getAttribute("data-align"); return a === "center" || a === "right" ? a : null; },
      renderHTML: (attrs) => (attrs.align === "center" || attrs.align === "right" ? { "data-align": attrs.align, style: `text-align:${attrs.align}` } : {}),
    },
    // A body cell that is a ROW HEADER (the table's headCol): rendered as <th scope="row">.
    head: {
      default: false,
      rendered: false,
      parseHTML: (el) => el.getAttribute("scope") === "row",
    },
  };
}

// ── grid transforms (the node-view rebuilds the WHOLE bpTable content) ────────
//
// A coarse whole-table rebuild matches the v1 greenlit coarse round-trip: an
// add/remove row/col re-emits the entire rows/head. Each op splices EVERY row so a
// ragged intermediate never persists (the rectangular-grid invariant).

// Extract the live bpTable node into a plain row descriptor list:
//   [{ header:bool, cells:[{content:Fragment|null,source:object|null}, …] }, …]
// A null content means "empty inline body" (rebuilt as a contentless cell). header is
// uniform per row (a header row's cells are ALL bpTableHeaderCell); a row loses
// header-ness the moment any cell is a body cell.
function extractRows(tableNode) {
  const rows = [];
  tableNode.forEach((rowNode) => {
    const cells = [];
    let header = rowNode.childCount > 0;
    rowNode.forEach((cellNode) => {
      cells.push({
        content: cellNode.content && cellNode.content.size ? cellNode.content : null,
        source: cellNode.attrs?.bpTableCellSource || null,
        colspan: Math.max(1, cellNode.attrs?.colspan || 1),
        rowspan: Math.max(1, cellNode.attrs?.rowspan || 1),
        align: cellNode.attrs?.align || null,
      });
      if (cellNode.type.name !== "bpTableHeaderCell") header = false;
    });
    rows.push({ header, cells });
  });
  return rows;
}

function buildCell(schema, header, cell) {
  const type = schema.nodes[header ? "bpTableHeaderCell" : "bpTableCell"];
  // A merged origin carries its colspan / rowspan (never on a header cell: a head does not span).
  const attrs = { bpTableCellSource: cell.source || null, colspan: header ? 1 : Math.max(1, cell.colspan || 1), rowspan: header ? 1 : Math.max(1, cell.rowspan || 1), align: cell.align || null, head: !!cell.head };
  // Omit content for an empty cell (a contentless inline* cell, rendering an empty
  // <td>/<th> exactly like an empty callout body).
  return cell.content ? type.create(attrs, cell.content) : type.create(attrs);
}

// `headCol` marks the first visible cell of each body row as a row header (a covered first column
// has no cell to mark; the spanning origin above it is the header).
function buildRowNodes(schema, rows, headCol = false) {
  return rows.map((r) =>
    schema.nodes.bpTableRow.create(
      null,
      r.cells.map((c, i) => buildCell(schema, r.header, headCol && !r.header && i === 0 && firstColumnVisible(rows, r) ? { ...c, head: true } : { ...c, head: false }))
    )
  );
}
function firstColumnVisible(rows, row) {
  const g = toGrid(rows);
  const bodyIndex = rows.filter((x) => !x.header).indexOf(row);
  if (bodyIndex < 0) return false;
  const covered = coverMap(normalizeSpans(g.spans, g.rows.length, gridWidth(g)));
  return !covered.has(bodyIndex + ",0");
}

function colCount(rows) {
  return rows.length ? rows[0].cells.length : 0;
}

function bodyRowCount(rows) {
  return rows.filter((r) => !r.header).length;
}

// Each transform mutates the descriptor list in place. add-col/remove-col touch
// EVERY row (incl. the header) so the grid stays rectangular; remove-row never drops
// the header; toggle-header flips the FIRST row's cells between header↔body.
// The visible rows (extractRows) <-> the grid (rectangular rows + spans), so every transform is a
// grid operation and merged cells survive add/remove row/col (table-grid.js). A grid cell here is
// the canvas descriptor { content, source }; a covered position holds an empty one.
const emptyCell = () => ({ content: null, source: null });
function toGrid(rows) {
  return visibleToGrid(rows.map((r) => ({ header: r.header, cells: r.cells.map((c) => ({ cell: { content: c.content, source: c.source, align: c.align || null }, colspan: c.colspan || 1, rowspan: c.rowspan || 1 })) })), emptyCell);
}
function fromGrid(rows, grid) {
  const visible = gridToVisible(grid);
  rows.length = 0;
  for (const r of visible) rows.push({ header: r.header, cells: r.cells.map((vc) => ({ content: vc.cell?.content || null, source: vc.cell?.source || null, align: vc.cell?.align || null, colspan: vc.colspan, rowspan: vc.rowspan })) });
}
// Body-grid coordinates of the k-th visible cell of visible row `rowIndex` (rows include the head).
function gridCoords(grid, rowIndex, cellIndex) {
  const r = rowIndex - (grid.head ? 1 : 0);
  if (r < 0) return null; // the head row never merges
  const covered = coverMap(normalizeSpans(grid.spans, grid.rows.length, gridWidth(grid)));
  let k = -1;
  for (let c = 0; c < gridWidth(grid); c++) {
    if (covered.has(r + "," + c)) continue;
    k++;
    if (k === cellIndex) return { r, c };
  }
  return null;
}
// The visible cell index (over the whole table, in document order) of body position (r, c).
function visibleIndexOf(grid, r, c) {
  const visible = gridToVisible(grid);
  const covered = coverMap(normalizeSpans(grid.spans, grid.rows.length, gridWidth(grid)));
  let idx = 0;
  const headRows = grid.head ? 1 : 0;
  for (let i = 0; i < visible.length; i++) {
    const br = i - headRows;
    if (br < r) { idx += visible[i].cells.length; continue; }
    for (let cc = 0; cc <= c; cc++) if (!covered.has(br + "," + cc)) { if (cc === c) return idx; idx++; }
    return idx;
  }
  return idx;
}
const TRANSFORMS = {
  addRow(rows) { const g = toGrid(rows); gridTransforms.addRow(g, emptyCell); fromGrid(rows, g); },
  removeRow(rows) { const g = toGrid(rows); if (g.rows.length <= 1) return; gridTransforms.removeRow(g); fromGrid(rows, g); },
  addCol(rows) { const g = toGrid(rows); gridTransforms.addCol(g, emptyCell); fromGrid(rows, g); },
  removeCol(rows) { const g = toGrid(rows); if (gridWidth(g) <= 1) return; gridTransforms.removeCol(g); fromGrid(rows, g); },
  toggleHeader(rows) { const g = toGrid(rows); gridTransforms.toggleHeader(g, emptyCell); fromGrid(rows, g); },
  toggleHeadCol() { return { headCol: "toggle" }; },
  // Merge: the rectangle between the selection's anchor and head cells; with the caret in one cell,
  // the cell to the right (mergeRight) or below (mergeDown). Swallowed cells' text joins the origin.
  merge(rows, ctx, dir) {
    const g = toGrid(rows);
    const a = ctx && ctx.anchor ? gridCoords(g, ctx.anchor.rowIndex, ctx.anchor.cellIndex) : null;
    let b = ctx && ctx.head ? gridCoords(g, ctx.head.rowIndex, ctx.head.cellIndex) : null;
    if (!a) return null;
    if (!b || (b.r === a.r && b.c === a.c)) {
      const spanA = normalizeSpans(g.spans, g.rows.length, gridWidth(g)).find((s) => s.row === a.r && s.col === a.c) || { colspan: 1, rowspan: 1 };
      b = dir === "down" ? { r: a.r + spanA.rowspan, c: a.c } : { r: a.r, c: a.c + spanA.colspan };
      if (b.r >= g.rows.length || b.c >= gridWidth(g)) return null;
    }
    const before = coverMap(normalizeSpans(g.spans, g.rows.length, gridWidth(g)));
    const merged = gridTransforms.merge(g, a.r, a.c, b.r, b.c);
    if (!merged) return null;
    // Gather the swallowed cells' content into the origin, in reading order.
    const origin = g.rows[merged.row][merged.col];
    const pieces = [];
    for (let r = merged.row; r < merged.row + merged.rowspan; r++) {
      for (let c = merged.col; c < merged.col + merged.colspan; c++) {
        if (r === merged.row && c === merged.col) continue;
        if (before.has(r + "," + c)) continue; // was already covered: nothing of its own
        const cell = g.rows[r][c];
        if (cell && cell.content && cell.content.size) pieces.push(cell.content);
        g.rows[r][c] = emptyCell();
      }
    }
    if (pieces.length) {
      let content = origin && origin.content && origin.content.size ? origin.content : null;
      for (const piece of pieces) content = content ? content.append(piece) : piece;
      g.rows[merged.row][merged.col] = { content, source: null };
    }
    fromGrid(rows, g);
    return { merged, visibleIndex: visibleIndexOf(g, merged.row, merged.col) };
  },
  split(rows, ctx) {
    const g = toGrid(rows);
    const a = ctx && ctx.anchor ? gridCoords(g, ctx.anchor.rowIndex, ctx.anchor.cellIndex) : null;
    if (!a) return null;
    if (!gridTransforms.split(g, a.r, a.c)) return null;
    fromGrid(rows, g);
    return { visibleIndex: visibleIndexOf(g, a.r, a.c) };
  },
};

// ── cell-to-cell caret navigation (Tab / Shift-Tab), scoped to inside bpTable ─

// The bpTable depth on a resolved position, or -1 when the caret is outside a table
// (so the keymap falls through to the default Tab/Enter behaviour everywhere else).
function tableDepthInfo($pos) {
  for (let d = $pos.depth; d > 0; d--) {
    if ($pos.node(d).type.name === "bpTable") return d;
  }
  return -1;
}

// The depth of the enclosing cell (body or header) on a resolved position, or null.
function cellDepthInfo($pos) {
  for (let d = $pos.depth; d > 0; d--) {
    const name = $pos.node(d).type.name;
    if (name === "bpTableCell" || name === "bpTableHeaderCell") return { depth: d };
  }
  return null;
}

// Every cell's content range in the table, in row-major order.
// cell-content-start = tablePos + rowOffset + cellOffset + 3
//   (+1 into the table, +1 into the row, +1 into the cell); end = start + content size.
function collectCells(tableNode, tablePos) {
  const cells = [];
  tableNode.forEach((rowNode, rowOffset) => {
    rowNode.forEach((cellNode, cellOffset) => {
      const start = tablePos + rowOffset + cellOffset + 3;
      cells.push({ start, end: start + cellNode.content.size });
    });
  });
  return cells;
}

// Move to the previous (dir=-1) / next (dir=1) cell, SELECTING that cell's whole
// content — what @tiptap/extension-table (prosemirror-tables goToNextCell) does, so
// typing into a tabbed-to cell replaces it and Tab reads as "next field". Tab in the
// LAST cell adds a body row and lands in its first cell (TableKit's addRowAfter +
// goToNextCell): that is how a table grows from the keyboard. Returns false when the
// caret is outside a table, or on Shift-Tab in the first cell, so native focus
// navigation can still leave the table backwards toward the surrounding controls.
function moveCell(editor, dir) {
  const { state } = editor;
  const { $from } = state.selection;
  const td = tableDepthInfo($from);
  if (td === -1) return false;
  const ci = cellDepthInfo($from);
  if (!ci) return false;
  const tablePos = $from.before(td);
  const tableNode = $from.node(td);
  const curCellStart = $from.before(ci.depth) + 1;
  const cells = collectCells(tableNode, tablePos);
  const idx = cells.findIndex((c) => c.start === curCellStart);
  if (idx === -1) return false;
  const target = idx + dir;
  if (target < 0) return false;
  if (target >= cells.length) {
    if (dir < 0) return false;
    // In the per-block table field (<bp-paper-editor data-editor-mode="table">) structure is
    // an ACTION the host applies and echoes (its transaction filter refuses a raw row
    // insert), so route through the same seam the chrome's "+ row" uses there.
    const contextualHost = editor.options.element?.closest?.(
      'bp-paper-editor[data-editor-mode="table"]',
    );
    if (contextualHost) return contextualHost.requestTableStructure?.("add-row") === true;
    return editor
      .chain()
      .focus()
      .command(({ tr, dispatch }) => {
        const rows = extractRows(tableNode);
        TRANSFORMS.addRow(rows);
        const newTable = editor.schema.nodes.bpTable.create(
          tableNode.attrs,
          buildRowNodes(editor.schema, rows, !!tableNode.attrs.headCol)
        );
        if (dispatch) {
          tr.replaceWith(tablePos, tablePos + tableNode.nodeSize, newTable);
          const first = collectCells(newTable, tablePos)[cells.length];
          tr.setSelection(TextSelection.create(tr.doc, first.start, first.end)).scrollIntoView();
        }
        return true;
      })
      .run();
  }
  const { start, end } = cells[target];
  editor
    .chain()
    .focus()
    .command(({ tr, dispatch }) => {
      if (dispatch) tr.setSelection(TextSelection.create(tr.doc, start, end)).scrollIntoView();
      return true;
    })
    .run();
  return true;
}

// ── the four nodes ───────────────────────────────────────────────────────────

export const BpTable = Node.create({
  name: "bpTable",
  group: "block",
  content: "bpTableRow+",
  // A hard boundary: no join/merge across the table edge (the v1 no-nesting guard).
  isolating: true,
  defining: true,
  selectable: true,

  addAttributes() {
    return tableAttributes();
  },

  // Specific parse so our own DOM round-trips first; a pasted BARE <table> (no
  // data-bp-type) does not claim this node.
  parseHTML() {
    return [{ tag: "table[data-bp-type='table']" }];
  },

  // Schema fallback (non-node-view path — the pure-Node round-trip / a non-editable
  // export). The node-view OVERRIDES this in the live editor. `0` is the row content
  // hole (nested under <tbody>, matching the node-view contentDOM).
  renderHTML({ HTMLAttributes }) {
    return [
      "table",
      mergeAttributes(HTMLAttributes, { "data-bp-type": "table", class: "bp-table" }),
      ["tbody", 0],
    ];
  },

  // Tab/Shift-Tab move cell→cell; Enter inside a cell does NOT split the table (the
  // isolating boundary + this cell-scoped swallow). All three fall through to the
  // default when the caret is outside a table.
  addKeyboardShortcuts() {
    return {
      Tab: () => moveCell(this.editor, 1),
      "Shift-Tab": () => moveCell(this.editor, -1),
      Enter: () => {
        const { $from } = this.editor.state.selection;
        return cellDepthInfo($from) ? true : false;
      },
    };
  },

  // The node-view: the reader <table> + class inside an edit-only wrapper carrying the
  // add/remove row/col + toggle-header chrome OUTSIDE the contentDOM. ONE contentDOM =
  // the <tbody>; all bpTableRow DOM mounts as direct children (valid, PM-happy). The
  // node-view NEVER touches cell interiors — rows/cells/inline are fully PM-managed via
  // their own renderHTML content holes (the callout-node.js chrome-outside pattern).
  addNodeView() {
    return ({ node, editor, getPos }) => {
      const dom = document.createElement("div");
      dom.className = "bp-canvas-table";
      dom.setAttribute("data-bp-type", "table");

      const colRail = document.createElement("div");
      colRail.className = "bp-canvas-table__cols";
      colRail.contentEditable = "false";
      colRail.setAttribute("role", "group");
      colRail.setAttribute("aria-label", "Table columns");

      const table = document.createElement("table");
      // The READER table element + class, byte-identical to walk.ex.
      table.className = "bp-table";
      table.setAttribute("data-bp-type", "table");
      const tbody = document.createElement("tbody");
      // Column widths (plan #25): a <colgroup> ahead of the body, one <col> per column, and a
      // grip on every column's right edge that drags the width and commits it as an attribute.
      const colgroup = document.createElement("colgroup");
      colgroup.setAttribute("contenteditable", "false");
      table.appendChild(colgroup);
      table.appendChild(tbody);
      const resizers = document.createElement("div");
      resizers.className = "bp-canvas-table__resizers";
      resizers.contentEditable = "false";
      const columnCountOf = (n) => gridWidth(toGrid(extractRows(n)));
      const paintCols = (n) => {
        const count = columnCountOf(n);
        const widths = Array.isArray(n.attrs?.colWidths) ? n.attrs.colWidths : [];
        while (colgroup.childNodes.length > count) colgroup.removeChild(colgroup.lastChild);
        while (colgroup.childNodes.length < count) colgroup.appendChild(document.createElement("col"));
        colgroup.childNodes.forEach((col, i) => { const w = widths[i]; col.style.width = Number.isInteger(w) && w > 0 ? w + "px" : ""; });
      };
      // The grips follow the first row whose cells cover every column (the head, or a row no
      // span reaches into); measured on demand so they track typing and resizing.
      const layoutGrips = () => {
        const count = colgroup.childNodes.length;
        const rowsEls = Array.from(table.querySelectorAll("tr"));
        const full = rowsEls.find((tr) => tr.cells.length === count);
        while (resizers.childNodes.length > count) resizers.removeChild(resizers.lastChild);
        while (resizers.childNodes.length < count) {
          const grip = document.createElement("div");
          grip.className = "bp-canvas-table__resize";
          grip.title = "Drag to resize the column";
          grip.setAttribute("data-col", String(resizers.childNodes.length));
          grip.addEventListener("pointerdown", (e) => startResize(e, Number(grip.getAttribute("data-col"))));
          resizers.appendChild(grip);
        }
        if (!full || !editor.isEditable) { resizers.style.display = "none"; return; }
        resizers.style.display = "";
        const base = dom.getBoundingClientRect();
        Array.from(full.cells).forEach((cell, i) => {
          const r = cell.getBoundingClientRect();
          const grip = resizers.childNodes[i];
          grip.style.left = Math.round(r.right - base.left - 3) + "px";
          grip.style.top = Math.round(r.top - base.top) + "px";
          grip.style.height = Math.round(table.getBoundingClientRect().height) + "px";
        });
      };
      const startResize = (e, col) => {
        if (!editor.isEditable || e.button !== 0) return;
        e.preventDefault();
        e.stopPropagation();
        const grip = e.currentTarget;
        const count = colgroup.childNodes.length;
        const startX = e.clientX;
        const rowsEls = Array.from(table.querySelectorAll("tr"));
        const full = rowsEls.find((tr) => tr.cells.length === count);
        const startWidth = full ? full.cells[col].getBoundingClientRect().width : 120;
        // Only columns that already have a width keep one; the dragged column gains its own. The
        // others stay auto, so one drag never freezes the whole table (Notion resizes one column).
        const current = Array.from({ length: count }, (_, i) => { const w = colgroup.childNodes[i].style.width; return w ? parseInt(w, 10) : null; });
        let next = current.slice();
        const onMove = (ev) => {
          const w = Math.max(40, Math.round(startWidth + (ev.clientX - startX)));
          next = current.slice(); next[col] = w;
          colgroup.childNodes[col].style.width = w + "px";
          layoutGrips();
        };
        const onUp = () => {
          grip.releasePointerCapture?.(e.pointerId);
          grip.removeEventListener("pointermove", onMove);
          grip.removeEventListener("pointerup", onUp);
          grip.removeEventListener("pointercancel", onUp);
          if (typeof getPos !== "function") return;
          const pos = getPos();
          if (pos == null) return;
          const cur = editor.state.doc.nodeAt(pos);
          if (!cur || cur.type.name !== "bpTable") return;
          const widths = next.map((w) => (Number.isInteger(w) && w > 0 ? w : null));
          if (JSON.stringify(widths) === JSON.stringify(cur.attrs.colWidths || null)) return;
          editor.chain().command(({ tr }) => { tr.setNodeMarkup(pos, undefined, { ...cur.attrs, colWidths: widths.some((w) => w != null) ? widths : null }); return true; }).run();
        };
        grip.setPointerCapture?.(e.pointerId);
        grip.addEventListener("pointermove", onMove);
        grip.addEventListener("pointerup", onUp);
        grip.addEventListener("pointercancel", onUp);
      };
      dom.addEventListener("mouseenter", () => layoutGrips());

      const rowRail = document.createElement("div");
      rowRail.className = "bp-canvas-table__rows";
      rowRail.contentEditable = "false";
      rowRail.setAttribute("role", "group");
      rowRail.setAttribute("aria-label", "Table rows");
      const controls = document.createElement("details");
      controls.className = "bp-canvas-table__controls";
      controls.contentEditable = "false";
      const summary = document.createElement("summary");
      summary.textContent = "Configure table";
      controls.append(summary, colRail, rowRail);
      const contextualHost = editor.options.element?.closest?.(
        'bp-paper-editor[data-editor-mode="table"]',
      );

      // A chrome button dispatches a PM transaction that REBUILDS the whole bpTable
      // content (keeping the grid rectangular), preserving bpId/bpType via cur.attrs.
      // Where the selection's ends sit in THIS table: visible row index + visible cell index, the
      // coordinates the merge / split transforms take (table-grid.js maps them onto the grid).
      const cellCoordsOf = ($p, tablePos) => {
        const td = tableDepthInfo($p);
        if (td === -1 || $p.before(td) !== tablePos) return null;
        const ci = cellDepthInfo($p);
        if (!ci) return null;
        return { rowIndex: $p.index(td), cellIndex: $p.index(ci.depth - 1) };
      };
      const runTransform = (name, dir) => {
        if (typeof getPos !== "function") return;
        const pos = getPos();
        if (pos == null) return;
        const cur = editor.state.doc.nodeAt(pos);
        if (!cur || cur.type.name !== "bpTable") return;
        const sel = editor.state.selection;
        const ctx = { anchor: cellCoordsOf(sel.$anchor, pos), head: cellCoordsOf(sel.$head, pos) };
        editor
          .chain()
          .focus()
          .command(({ tr, dispatch }) => {
            const rows = extractRows(cur);
            const outcome = TRANSFORMS[name](rows, ctx, dir);
            if (!rows.length) return false;
            if ((name === "merge" || name === "split") && !outcome) return false;
            const headCol = name === "toggleHeadCol" ? !cur.attrs.headCol : !!cur.attrs.headCol;
            const newTable = editor.schema.nodes.bpTable.create(
              { ...cur.attrs, headCol },
              buildRowNodes(editor.schema, rows, headCol)
            );
            if (dispatch) {
              tr.replaceWith(pos, pos + cur.nodeSize, newTable);
              // A merge or split lands the caret in the cell it acted on.
              if (outcome && typeof outcome.visibleIndex === "number") {
                const cell = collectCells(newTable, pos)[outcome.visibleIndex];
                if (cell) tr.setSelection(TextSelection.create(tr.doc, cell.end, cell.end));
              }
            }
            return true;
          })
          .run();
      };

      const mkBtn = (label, title, name, disabled = false) => {
        const b = document.createElement("button");
        b.type = "button";
        b.className = "bp-canvas-table__btn";
        b.textContent = label;
        b.title = title;
        b.setAttribute("aria-label", title);
        b.disabled = disabled;
        b.dataset.tableAction = name;
        b.contentEditable = "false";
        // preventDefault on mousedown so the click never steals/collapses the PM
        // selection before the transform runs.
        b.addEventListener("mousedown", (e) => e.preventDefault());
        b.addEventListener("click", (e) => {
          e.preventDefault();
          if (contextualHost) contextualHost.requestTableStructure?.(name);
          else runTransform(name);
        });
        return b;
      };

      let delColBtn = null;
      let delRowBtn = null;

      // The grips overlay sits ahead of the table in the DOM (absolutely positioned over it), so the
      // controls stay the table's next sibling.
      dom.appendChild(resizers);
      dom.appendChild(table);
      dom.appendChild(controls);

      // The chrome repaints from the live child counts: −row disabled at 1 body row,
      // −col disabled at 1 col. The contentDOM is left to PM.
      const repaint = (n) => {
        const rows = extractRows(n);
        if (!contextualHost) {
          if (!colRail.childNodes.length) {
            colRail.appendChild(mkBtn("+ col", "Add column", "addCol"));
            delColBtn = mkBtn("− col", "Remove column", "removeCol");
            colRail.appendChild(delColBtn);
            rowRail.appendChild(mkBtn("+ row", "Add row", "addRow"));
            delRowBtn = mkBtn("− row", "Remove row", "removeRow");
            rowRail.appendChild(delRowBtn);
            rowRail.appendChild(mkBtn("header", "Toggle header row", "toggleHeader"));
            colRail.appendChild(mkBtn("header col", "Toggle header column", "toggleHeadCol"));
            // Merged cells (plan #24): merge the selected cells (or the cell to the right / below
            // of the caret) and split a merged cell back into its grid positions.
            const mergeRow = document.createElement("div");
            mergeRow.className = "bp-canvas-table__rail bp-canvas-table__rail--merge";
            mergeRow.contentEditable = "false";
            const mkMergeBtn = (label, title, name, dir) => {
              const b = mkBtn(label, title, name);
              if (dir) b.addEventListener("click", (e) => { e.stopImmediatePropagation(); e.preventDefault(); runTransform(name, dir); }, true);
              return b;
            };
            mergeRow.appendChild(mkMergeBtn("merge", "Merge the selected cells (or with the cell to the right)", "merge", "right"));
            mergeRow.appendChild(mkMergeBtn("merge ↓", "Merge with the cell below", "merge", "down"));
            mergeRow.appendChild(mkBtn("split", "Split the merged cell", "split"));
            controls.appendChild(mergeRow);
          }
          delRowBtn.disabled = bodyRowCount(rows) <= 1;
          delColBtn.disabled = colCount(rows) <= 1;
          return;
        }

        const active = document.activeElement;
        const focusedRail = colRail.contains(active) ? colRail
          : rowRail.contains(active) ? rowRail : null;
        const focusedAction = focusedRail ? active.dataset?.tableAction : null;

        colRail.replaceChildren(mkBtn("+ col", "Add column", "add-column"));
        for (let column = 0; column < colCount(rows); column += 1) {
          colRail.appendChild(mkBtn("←", `Move column ${column + 1} left`,
            `left-column:${column}`, column === 0));
          colRail.appendChild(mkBtn("→", `Move column ${column + 1} right`,
            `right-column:${column}`, column + 1 === colCount(rows)));
          colRail.appendChild(mkBtn("−", `Remove column ${column + 1}`,
            `remove-column:${column}`, colCount(rows) <= 1));
        }

        const hasHeader = rows[0]?.header === true;
        rowRail.replaceChildren(mkBtn("+ row", "Add row", "add-row"));
        rowRail.appendChild(mkBtn(
          hasHeader ? "− header" : "+ header",
          hasHeader ? "Remove header" : "Add header",
          hasHeader ? "remove-header" : "add-header",
        ));
        const bodyRows = rows.filter((row) => !row.header);
        bodyRows.forEach((_row, row) => {
          rowRail.appendChild(mkBtn("↑", `Move row ${row + 1} up`,
            `up-row:${row}`, row === 0));
          rowRail.appendChild(mkBtn("↓", `Move row ${row + 1} down`,
            `down-row:${row}`, row + 1 === bodyRows.length));
          rowRail.appendChild(mkBtn("−", `Remove row ${row + 1}`,
            `remove-row:${row}`, bodyRows.length <= 1));
        });

        // Authoritative cell/grid echoes repaint chrome outside contentDOM.
        // Preserve a keyboard user's place, but never focus a Table whose
        // controls were not active. Removed/disabled actions fall back to Add
        // in the same rail, which remains available for a one-cell Table.
        if (focusedRail) {
          const buttons = Array.from(focusedRail.querySelectorAll("button"));
          const target = buttons.find((button) =>
            button.dataset.tableAction === focusedAction && !button.disabled,
          ) || buttons.find((button) => !button.disabled);
          target?.focus({ preventScroll: true });
        }
      };
      repaint(node);
      paintCols(node);

      return {
        dom,
        contentDOM: tbody,
        update: (updated) => {
          if (updated.type.name !== "bpTable") return false;
          repaint(updated);
          paintCols(updated);
          if (resizers.style.display !== "none") layoutGrips();
          return true;
        },
        // A chrome event (a +col click) must NEVER become a PM transaction/caret jump;
        // an event inside the contentDOM cells MUST reach PM (cell typing/selection).
        stopEvent: (event) => {
          const t = event.target;
          return controls.contains(t) || colRail.contains(t) || rowRail.contains(t) || resizers.contains(t);
        },
        // Ignore mutations under the chrome rails; let PM see contentDOM (tbody)
        // mutations (the callout-node.js pattern).
        ignoreMutation: (mutation) => {
          if (mutation.type === "selection") return false;
          if (tbody === mutation.target || tbody.contains(mutation.target)) return false;
          return true;
        },
      };
    };
  },
});

export const BpTableRow = Node.create({
  name: "bpTableRow",
  content: "(bpTableHeaderCell | bpTableCell)+",
  defining: true,
  parseHTML() {
    return [{ tag: "tr" }];
  },
  renderHTML() {
    return ["tr", 0];
  },
});

export const BpTableCell = Node.create({
  name: "bpTableCell",
  content: "inline*",
  defining: true,
  addAttributes() {
    return tableCellAttributes();
  },
  parseHTML() {
    return [{ tag: "td" }, { tag: "th[scope='row']" }];
  },
  renderHTML({ node, HTMLAttributes }) {
    // A row header (the table's header column, plan #26) is a <th scope="row"> with the reader's
    // th class; every other body cell stays a <td>. Span and align attributes ride either way.
    const attrs = { ...HTMLAttributes };
    if (node.attrs.head) return ["th", mergeAttributes(attrs, { scope: "row", class: "bp-table__th bp-table__th--col" }), 0];
    return ["td", mergeAttributes(attrs, { class: "bp-table__td" }), 0];
  },
});

export const BpTableHeaderCell = Node.create({
  name: "bpTableHeaderCell",
  content: "inline*",
  defining: true,
  addAttributes() {
    return tableCellAttributes();
  },
  parseHTML() {
    return [{ tag: "th:not([scope='row'])" }];
  },
  renderHTML({ HTMLAttributes }) {
    return ["th", mergeAttributes(HTMLAttributes, { class: "bp-table__th" }), 0];
  },
});
