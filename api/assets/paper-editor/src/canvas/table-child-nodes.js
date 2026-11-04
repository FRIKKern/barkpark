import { Node, mergeAttributes } from "@tiptap/core";

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
    const contentElement = (dom) => dom.querySelector(":scope > span[data-bp-table-cell-content]") || dom;
    return [{ tag: "td", preserveWhitespace: "full", contentElement }, { tag: "th[scope='row']", preserveWhitespace: "full", contentElement }];
  },
  renderHTML({ node, HTMLAttributes }) {
    // A row header (the table's header column, plan #26) is a <th scope="row"> with the reader's
    // th class; every other body cell stays a <td>. Span and align attributes ride either way.
    const attrs = { ...HTMLAttributes };
    const content = ["span", { "data-bp-table-cell-content": "" }, 0];
    if (node.attrs.head) return ["th", mergeAttributes(attrs, { scope: "row", class: "bp-table__th bp-table__th--col" }), content];
    return ["td", mergeAttributes(attrs, { class: "bp-table__td" }), content];
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
    return [{ tag: "th:not([scope='row'])", preserveWhitespace: "full", contentElement: (dom) => dom.querySelector(":scope > span[data-bp-table-cell-content]") || dom }];
  },
  renderHTML({ HTMLAttributes }) {
    return ["th", mergeAttributes(HTMLAttributes, { class: "bp-table__th" }), ["span", { "data-bp-table-cell-content": "" }, 0]];
  },
});
