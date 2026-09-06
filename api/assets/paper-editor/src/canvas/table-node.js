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
//                      defining, selectable. bpId/bpType ONLY (the grid data lives in
//                      the PM child nodes, which is what earns free inline-mark
//                      editing — contrast code-node.js storing text in a `value` attr
//                      because its interior is non-PM). A node-view (chrome + tbody
//                      contentDOM).
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

// Shared bpId/bpType attr skeleton (the role-nodes.js roleAttributes shape). Only the
// bpTable carries these — rows/cells are INTERNAL PM structure with NO bpId (one id
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
  };
}

// ── grid transforms (the node-view rebuilds the WHOLE bpTable content) ────────
//
// A coarse whole-table rebuild matches the v1 greenlit coarse round-trip: an
// add/remove row/col re-emits the entire rows/head. Each op splices EVERY row so a
// ragged intermediate never persists (the rectangular-grid invariant).

// Extract the live bpTable node into a plain row descriptor list:
//   [{ header:bool, cells:[Fragment|null, …] }, …]
// A null cell means "empty inline body" (rebuilt as a contentless cell). header is
// uniform per row (a header row's cells are ALL bpTableHeaderCell); a row loses
// header-ness the moment any cell is a body cell.
function extractRows(tableNode) {
  const rows = [];
  tableNode.forEach((rowNode) => {
    const cells = [];
    let header = rowNode.childCount > 0;
    rowNode.forEach((cellNode) => {
      cells.push(cellNode.content && cellNode.content.size ? cellNode.content : null);
      if (cellNode.type.name !== "bpTableHeaderCell") header = false;
    });
    rows.push({ header, cells });
  });
  return rows;
}

function buildCell(schema, header, frag) {
  const type = schema.nodes[header ? "bpTableHeaderCell" : "bpTableCell"];
  // Omit content for an empty cell (a contentless inline* cell, rendering an empty
  // <td>/<th> exactly like an empty callout body).
  return frag ? type.create(null, frag) : type.create(null);
}

function buildRowNodes(schema, rows) {
  return rows.map((r) =>
    schema.nodes.bpTableRow.create(
      null,
      r.cells.map((c) => buildCell(schema, r.header, c))
    )
  );
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
const TRANSFORMS = {
  addRow(rows) {
    const n = colCount(rows) || 1;
    rows.push({ header: false, cells: new Array(n).fill(null) });
  },
  removeRow(rows) {
    if (bodyRowCount(rows) <= 1) return;
    for (let i = rows.length - 1; i >= 0; i--) {
      if (!rows[i].header) {
        rows.splice(i, 1);
        return;
      }
    }
  },
  addCol(rows) {
    rows.forEach((r) => r.cells.push(null));
  },
  removeCol(rows) {
    if (colCount(rows) <= 1) return;
    rows.forEach((r) => r.cells.pop());
  },
  toggleHeader(rows) {
    if (rows.length) rows[0].header = !rows[0].header;
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

// The content-start position of every cell in the table, in row-major order.
// cell-content-start = tablePos + rowOffset + cellOffset + 3
//   (+1 into the table, +1 into the row, +1 into the cell).
function collectCellStarts(tableNode, tablePos) {
  const starts = [];
  tableNode.forEach((rowNode, rowOffset) => {
    rowNode.forEach((_cellNode, cellOffset) => {
      starts.push(tablePos + rowOffset + cellOffset + 3);
    });
  });
  return starts;
}

// Move the caret to the previous (dir=-1) / next (dir=1) cell. Returns false when the
// caret is not in a table (default Tab/Enter proceeds) and true otherwise — including
// at a grid edge, where it swallows the key so focus never escapes the editor.
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
  const starts = collectCellStarts(tableNode, tablePos);
  const idx = starts.indexOf(curCellStart);
  if (idx === -1) return true;
  const target = idx + dir;
  if (target < 0 || target >= starts.length) return true;
  editor.chain().focus().setTextSelection(starts[target]).run();
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
      table.appendChild(tbody);

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
      const runTransform = (name) => {
        if (typeof getPos !== "function") return;
        const pos = getPos();
        if (pos == null) return;
        const cur = editor.state.doc.nodeAt(pos);
        if (!cur || cur.type.name !== "bpTable") return;
        editor
          .chain()
          .focus()
          .command(({ tr, dispatch }) => {
            const rows = extractRows(cur);
            TRANSFORMS[name](rows);
            if (!rows.length) return false;
            const newTable = editor.schema.nodes.bpTable.create(
              cur.attrs,
              buildRowNodes(editor.schema, rows)
            );
            if (dispatch) tr.replaceWith(pos, pos + cur.nodeSize, newTable);
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

      return {
        dom,
        contentDOM: tbody,
        update: (updated) => {
          if (updated.type.name !== "bpTable") return false;
          repaint(updated);
          return true;
        },
        // A chrome event (a +col click) must NEVER become a PM transaction/caret jump;
        // an event inside the contentDOM cells MUST reach PM (cell typing/selection).
        stopEvent: (event) => {
          const t = event.target;
          return controls.contains(t) || colRail.contains(t) || rowRail.contains(t);
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
  parseHTML() {
    return [{ tag: "td" }];
  },
  renderHTML() {
    return ["td", { class: "bp-table__td" }, 0];
  },
});

export const BpTableHeaderCell = Node.create({
  name: "bpTableHeaderCell",
  content: "inline*",
  defining: true,
  parseHTML() {
    return [{ tag: "th" }];
  },
  renderHTML() {
    return ["th", { class: "bp-table__th" }, 0];
  },
});
