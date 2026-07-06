// divider-node.js — Phase-4 Stage S3: the FIRST canvas atom node-view.
//
// Brings the `divider` block INTO the continuous canvas as a ProseMirror ATOM
// node, so it stops being a run boundary and a prose run can CONTAIN dividers.
// This is the simplest non-prose block — a leaf, NO content, NO edit UI — so it
// is the right first proof of the atom-node-view pattern the other non-prose
// classes (callout/code/field/sheet) will follow in later increments.
//
// Why an ATOM:
//   * group:"block"   — a top-level sibling of paragraph/heading/list, so it
//     lives inside the SAME ProseMirror document the canvas mounts (StarterKit's
//     doc content is `block+`, so a block-group leaf is a native sibling).
//   * atom:true       — no editable interior; ProseMirror treats it as a single
//     indivisible unit. This gives caret-selection of the whole node and
//     Backspace/Delete removal FOR FREE (the StarterKit keymaps delete a
//     selected/adjacent atom), which is all v1 needs — no custom node-view.
//   * content absent  — a divider is a pure leaf; it carries no children.
//
// bpId / bpType ride the node as attributes, carried through the DOM round-trip
// on `data-bp-id` / `data-bp-type` — IDENTICAL contract to BpAttrs (bp-attrs.js)
// for prose nodes. This is what makes getJSON() preserve the id run-convert.js
// keys by; without it ProseMirror would drop the id and runToOps would mis-diff
// the divider as new on every save.
//
// DOM-free: imports ONLY `@tiptap/core` (loads in plain Node) plus a toDOM that
// is inert until mounted in an Editor — so the pure-Node smoke harness can
// import this module to assert its schema without a browser. The toDOM emits the
// reader's §-on-a-hairline structure — a `<div class="bp-section-divider">`
// wrapping a `<span class="bp-section-divider__mark">§</span>` — byte-aligned
// with `Figures.section_divider_html/0` (figures.ex:33-37) so the edit canvas
// paints the same centered section mark the /papers article reader does, instead
// of a bare `<hr>`. Still a pure ATOM (the § is a static renderHTML literal, not
// editable PM content); a custom node-view (delete affordance / selected styling)
// is a deliberate later add ONLY if the bare atom proves insufficient.

import { Node, mergeAttributes } from "@tiptap/core";

export const Divider = Node.create({
  name: "divider",

  // A top-level block sibling (paragraph|heading|list|divider) inside the one
  // canvas document. group:"block" is what lets it sit in the doc's `block+`
  // content without any schema surgery on the doc node itself.
  group: "block",

  // An atom leaf: no editable interior, treated as a single unit. PM's atom
  // selection + Backspace/Delete-of-a-selected-atom come free from StarterKit,
  // which is the entire delete affordance v1 needs.
  atom: true,

  // Defensive: a divider is a leaf, so it is never the target of a text
  // selection. selectable lets the user click it and Backspace/Delete it.
  selectable: true,

  addAttributes() {
    return {
      // bpId — the portable-doc block id runToOps keys by. data-bp-id is the DOM
      // carrier that survives the setContent -> getJSON round-trip (same role as
      // BpAttrs.bpId for prose). default null so a freshly-typed divider (no id
      // yet) reads as new and runToOps mints one.
      bpId: {
        default: null,
        parseHTML: (el) => el.getAttribute("data-bp-id"),
        renderHTML: (attrs) => (attrs.bpId ? { "data-bp-id": attrs.bpId } : {}),
      },
      // bpType — the original portable-doc block kind ("divider"). Carried for
      // symmetry with prose so runToOps can read the type back off node.attrs.
      bpType: {
        default: null,
        parseHTML: (el) => el.getAttribute("data-bp-type"),
        renderHTML: (attrs) =>
          attrs.bpType ? { "data-bp-type": attrs.bpType } : {},
      },
    };
  },

  // Parse the § divider DOM back into a divider node (so a setContent of rendered
  // HTML, and an intra-canvas paste of a copied divider, round-trip). Also keeps
  // parsing legacy bare `<hr>` (older content + the StarterKit `---` inputrule in
  // the per-block prose editor). The data-* attrs are read by addAttributes'
  // parseHTML above off whichever element matched.
  parseHTML() {
    return [
      { tag: "div.bp-section-divider" },
      { tag: "div[data-bp-type='divider']" },
      { tag: "hr" },
    ];
  },

  // Render the atom as the reader's §-on-a-hairline structure: an outer
  // `<div class="bp-section-divider">` (the hairline rule) wrapping a
  // `<span class="bp-section-divider__mark">§</span>` (the masked glyph),
  // byte-aligned with Figures.section_divider_html/0 (figures.ex:33-37).
  // mergeAttributes folds the per-attr renderHTML output (data-bp-id /
  // data-bp-type) onto the OUTER div — preserving the bp-attrs stamp contract.
  renderHTML({ HTMLAttributes }) {
    return [
      "div",
      mergeAttributes(HTMLAttributes, { class: "bp-section-divider" }),
      ["span", { class: "bp-section-divider__mark" }, "§"],
    ];
  },
});
