// columns-node.js — Slice S10: the FIRST canvas CONTAINER node — an in-canvas,
// recursively-editable `columns` block.
//
// `columns` is the first canvas node whose interior is a NESTED BLOCK TREE (child
// blocks with their own type/content), not inline runs (callout) nor a verbatim
// opaque carry (sheet/embed/fleet). It brings a portable-doc `columns` block INTO
// the continuous canvas as THREE cooperating ProseMirror nodes:
//
//   bpColumns (grid wrapper)  content:"bpColumn+"   — the `.bp-cols` grid; carries
//     bpId/bpType (the id contract) + a static `cols` count projected off the
//     source column count → `style="--bp-cols:N"`, so the reader's OWN
//     `.bp-paper-surface .bp-cols` grid CSS paints the layout for FREE (the canvas
//     mounts inside `.bp-paper-surface`; paper-surface.css is inlined into Studio).
//   bpColumn (one column)     content:"(paragraph | heading | bulletList |
//     orderedList | divider | bpColumnAtom)+"  — a plain block-container (the
//     blockquote pattern). It is DELIBERATELY not group:"block" (so the doc's
//     `block+` never accepts a bare column) and its content allow-list DELIBERATELY
//     OMITS bpColumns — schema-level "no container-in-container" (v1 product
//     decision). isolating:true keeps the caret inside a column (Backspace at
//     column-start cannot dissolve the grid).
//   bpColumnAtom (verbatim read-only carrier)  atom:true — a column CHILD can be ANY
//     block type (callout/code/sheet/fleet/image/terminal/nested-container). Those
//     are NOT valid bpColumn children by name, so a non-representable child rides
//     VERBATIM on this atom (the whole child block deep-cloned onto `bpBlock`), shown
//     as a read-only "· <bpType> ·" chip. It emits ZERO ops of its own and round-trips
//     the child block byte-identically through the coarse `columns` patch.
//
// DOM discipline: bpColumns / bpColumn are DOM-FREE plain `Node.create`s (renderHTML
// content holes, the role-nodes.js / divider-node.js precedent — no `document`, no
// NodeView). bpColumnAtom's NodeView references `document` LAZILY (inside
// addNodeView, which never runs in the pure-Node smoke harness), exactly like
// embed-node.js — so this module imports cleanly in plain Node.
//
// Reader parity: the wrapper is `div.bp-cols` (+ data-bp-type) and each column is
// `div.bp-cols__c` (+ data-bp-type), byte-aligned with the reader emitter
// (compose.ex:731-743) so the shared `.bp-paper-surface .bp-cols*` cascade styles
// the grid identically — zero editor CSS drift, the same lesson as callout/role.

import { Node, mergeAttributes } from "@tiptap/core";

// Node NAMES. bpColumns / bpColumn / bpColumnAtom (the canvas bp-prefix convention).
// There is NO StarterKit collision for any of the three (StarterKit ships no
// columns/column node), so NO StarterKit node is disabled for them. Keep aligned with
// run-convert.js:CANVAS_CONTAINER_NODE_NAMES / BP_COLUMN_NODE_NAME /
// BP_COLUMN_ATOM_NODE_NAME.
export const BP_COLUMNS_NODE_NAME = "bpColumns";
export const BP_COLUMN_NODE_NAME = "bpColumn";
export const BP_COLUMN_ATOM_NODE_NAME = "bpColumnAtom";

// The id-stamp attrs shared by bpColumns (the same contract as callout/divider/role):
// bpId/bpType on data-* so getJSON() preserves the id run-convert.js keys the diff by.
function idAttributes(defaultType) {
  return {
    bpId: {
      default: null,
      parseHTML: (el) => el.getAttribute("data-bp-id"),
      renderHTML: (attrs) => (attrs.bpId ? { "data-bp-id": attrs.bpId } : {}),
    },
    bpType: {
      default: defaultType,
      parseHTML: (el) => el.getAttribute("data-bp-type"),
      renderHTML: (attrs) =>
        attrs.bpType ? { "data-bp-type": attrs.bpType } : {},
    },
  };
}

// ── bpColumns: the grid wrapper ──────────────────────────────────────────────
//
// group:"block" so it is a native top-level sibling in the doc's `block+`. content
// "bpColumn+" so it holds one-or-more columns and nothing else. defining + isolating
// so a caret at the grid edge never merges the grid into an adjacent block and a
// selection cannot straddle in/out of the grid. The `cols` attr is PROJECTED from the
// source column count (static in v1 — no live add/remove-column affordance, so it
// never goes stale) and rendered as `style="--bp-cols:N"`; the `0` in renderHTML is
// the contentDOM PM fills with the bpColumn children. NO node-view in v1.
export const Columns = Node.create({
  name: BP_COLUMNS_NODE_NAME,
  group: "block",
  content: BP_COLUMN_NODE_NAME + "+",
  defining: true,
  isolating: true,
  selectable: true,

  addAttributes() {
    return {
      ...idAttributes("columns"),
      // cols — the static column count → `--bp-cols:N`. Projected off the source
      // column count (run-convert.js columnsBlockToNode); parseHTML reads data-cols
      // so a setContent of the rendered wrapper round-trips the count. renderHTML
      // stamps data-cols (the count also drives the inline style in the node
      // renderHTML below, which sees node.attrs.cols directly).
      cols: {
        default: null,
        parseHTML: (el) => {
          const raw = el.getAttribute("data-cols");
          const n = raw == null ? null : parseInt(raw, 10);
          return Number.isFinite(n) ? n : null;
        },
        renderHTML: (attrs) =>
          attrs.cols != null ? { "data-cols": String(attrs.cols) } : {},
      },
    };
  },

  // Specific parse rule (data-bp-type='columns') so a bare <div> stays unclaimed.
  parseHTML() {
    return [{ tag: "div[data-bp-type='columns']" }];
  },

  // The reader's grid wrapper: <div class="bp-cols" data-bp-type="columns"
  // style="--bp-cols:N">…columns…</div>. The `0` content hole IS the contentDOM. A
  // null cols falls back to 2 (the reader's `--bp-cols` default), so the grid is
  // never style-less.
  renderHTML({ node, HTMLAttributes }) {
    const cols = (node.attrs && node.attrs.cols) || 2;
    return [
      "div",
      mergeAttributes(HTMLAttributes, {
        "data-bp-type": "columns",
        class: "bp-cols",
        style: `--bp-cols:${cols}`,
      }),
      0,
    ];
  },
});

// ── bpColumn: one column (a plain block-container) ───────────────────────────
//
// NO "block" group so the doc's `block+` never accepts a bare column — it can ONLY
// live inside bpColumns' `bpColumn+`. content is the FORBID-NESTING allow-list: prose
// + leaf divider + the verbatim read-only carrier; bpColumns is DELIBERATELY ABSENT
// (schema-level no-container-in-container, the v1 product decision). isolating keeps
// the caret inside the column; defining keeps an adjacent textblock from merging in.
export const Column = Node.create({
  name: BP_COLUMN_NODE_NAME,
  content:
    "(paragraph | heading | bulletList | orderedList | divider | " +
    BP_COLUMN_ATOM_NODE_NAME +
    ")+",
  defining: true,
  isolating: true,
  selectable: true,

  parseHTML() {
    return [{ tag: "div[data-bp-type='column']" }];
  },

  // The reader's column: <div class="bp-cols__c" data-bp-type="column">…blocks…</div>.
  // The `0` is the contentDOM PM fills with the column's child blocks.
  renderHTML() {
    return ["div", { "data-bp-type": "column", class: "bp-cols__c" }, 0];
  },
});

// ── bpColumnAtom: the generic verbatim READ-ONLY child carrier ───────────────
//
// A column child can be ANY block type. Only prose (paragraph/heading/list) + divider
// are valid bpColumn children by NAME; every other kind (callout/code/sheet/fleet/
// image/terminal/nested-container/composite/table) would be DROPPED by PM = DATA LOSS.
// So run-convert.js projects such a child onto this atom, carrying the WHOLE child
// block VERBATIM on `bpBlock` (deep-cloned), rendered as a read-only "· <bpType> ·"
// chip. It emits ZERO ops of its own and rides the coarse `columns` patch. Reader
// parity: this chip is edit-only chrome — on /papers the reader renders the child
// block fully; the chip never competes as an HTML producer.
//
// The block rides on `bpBlock` as a JSON string on data-bp-block so it survives the
// setContent->getJSON DOM round-trip (identical to embed-node.js's read-only atom).
function columnAtomBlockAttribute() {
  return {
    bpBlock: {
      default: null,
      parseHTML: (el) => {
        const raw = el.getAttribute("data-bp-block");
        if (raw == null || raw === "") return null;
        try {
          return JSON.parse(raw);
        } catch (_) {
          return null;
        }
      },
      renderHTML: (attrs) =>
        attrs.bpBlock != null
          ? { "data-bp-block": JSON.stringify(attrs.bpBlock) }
          : {},
    },
  };
}

export const ColumnAtom = Node.create({
  name: BP_COLUMN_ATOM_NODE_NAME,

  // No group — it is a valid bpColumn child by NAME (in bpColumn.content), never a
  // top-level or free-floating block.
  atom: true,
  selectable: true,
  defining: true,

  addAttributes() {
    return {
      // bpType — the CARRIED child's kind (e.g. "callout"/"terminal"/"image"), so the
      // chip can label it and run-convert.js can read it back. default null.
      bpType: {
        default: null,
        parseHTML: (el) => el.getAttribute("data-bp-child-type"),
        renderHTML: (attrs) =>
          attrs.bpType ? { "data-bp-child-type": attrs.bpType } : {},
      },
      // bpId — carried for symmetry (a column child MAY have an id in the wild; the
      // reader ignores child ids, so this is not load-bearing). default null.
      bpId: {
        default: null,
        parseHTML: (el) => el.getAttribute("data-bp-id"),
        renderHTML: (attrs) => (attrs.bpId ? { "data-bp-id": attrs.bpId } : {}),
      },
      ...columnAtomBlockAttribute(),
    };
  },

  // Parse ONLY our own data-attributed wrapper (a <div data-bp-type='column-atom'>),
  // reading the whole child block off data-bp-block. "column-atom" is an editor-only
  // marker (NOT the carried child's type), so it never contends with another node's
  // parse rule.
  parseHTML() {
    return [{ tag: "div[data-bp-type='column-atom']" }];
  },

  // Schema-level fallback render (no node-view mounted — pure-Node round-trip). The
  // whole block rides the typed bpBlock attr; data-bp-type is the parse anchor.
  renderHTML({ HTMLAttributes }) {
    return [
      "div",
      mergeAttributes(HTMLAttributes, { "data-bp-type": "column-atom" }),
    ];
  },

  // The NodeView: a minimal read-only "· <bpType> ·" chip (the embed-node.js
  // read-only pattern). contentEditable false + stopEvent/ignoreMutation so PM never
  // turns a click into a transaction or reads the chip's DOM back into the document.
  // It is selectable, so Backspace on a selected chip deletes it → the coarse columns
  // patch re-emits. The whole child block rides on bpBlock, untouched.
  addNodeView() {
    return ({ node }) => {
      const block = (node.attrs && node.attrs.bpBlock) || {};
      const bpType =
        (node.attrs && node.attrs.bpType) || (block && block.type) || "block";

      const dom = document.createElement("div");
      dom.className = "bp-cols__atom";
      dom.setAttribute("contenteditable", "false");
      dom.setAttribute("data-bp-type", "column-atom");
      dom.setAttribute("data-test-id", "paper-column-atom");
      dom.textContent = `· ${bpType} ·`;

      return {
        dom,
        // Re-render the chip label when the carried block changes (echo / undo).
        // Return false for a different node type so PM rebuilds the view.
        update: (updated) => {
          if (updated.type.name !== BP_COLUMN_ATOM_NODE_NAME) return false;
          const b = (updated.attrs && updated.attrs.bpBlock) || {};
          const t =
            (updated.attrs && updated.attrs.bpType) || (b && b.type) || "block";
          dom.textContent = `· ${t} ·`;
          return true;
        },
        // PM must NOT turn a click into a transaction — a click only ever selects
        // the atom.
        stopEvent: () => true,
        // PM must NOT read the chip's DOM mutations back into the document (no
        // contentDOM on an atom).
        ignoreMutation: () => true,
      };
    };
  },
});
