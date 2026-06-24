// canvas/slash-insert.js — PURE, DOM-free core of the canvas "/" slash menu.
//
// Split out of canvas/index.js (which CANNOT be imported in plain Node — its
// top-level `class extends HTMLElement` + `customElements.define` throw
// `HTMLElement is not defined`) so the slash-insert primitives can be unit-tested
// in pure Node, exactly the reason tone.js lives apart from index.js. canvas/index.js
// imports these and does ONLY the WC-side wiring (open the popup, replace the
// "/query" block with the node, route keys).
//
// The three primitives, all DOM-free:
//   CANVAS_SLASH_TYPES   — the allowlist of types insertable into a prose run.
//   canvasDefaultBlock   — the minimal default BLOCK per type (mirrors default_block/2).
//   slashTypeToNode      — the TipTap NODE to insert, built via runToTiptap (so it is
//                          byte-identical to the projection runToOps/nextNodeToBlock reverse).

import { runToTiptap } from "./run-convert.js";

// ── the insertable-type allowlist ───────────────────────────────────────────
//
// A CANVAS slash pick inserts a default NODE into the live prose run — so it can
// only offer types that (a) have a canvas node-view and (b) can be inserted EMPTY
// into a run without a ref/picker and without SPLITTING the run. That set is exactly:
// the 3 prose types (paragraph/heading/list), the 4 non-prose node-view blocks the
// run can CONTAIN (callout/code/divider/diagram), and the 7 NATIVE field-* types
// (string/slug/text/boolean/select/datetime/color).
//
// EXCLUDED on purpose (these EXIST in SLASH_ITEMS but cannot be DIRECT-inserted):
//   * sheet / embed            — REFERENCES; need a target/ref a slash pick can't supply.
//   * section + composite / arrayOf / codelist / localizedText
//                              — run-splitting / object boundaries (no canvas node-view).
//   * eyebrow / byline / ingress / pullquote
//                              — article-chrome blocks with no canvas node-view (bpOpaque).
//   * field-image / field-reference
//                              — PICKER fields; need the upload/reference picker (bpOpaque).
export const CANVAS_SLASH_TYPES = new Set([
  "paragraph",
  "heading",
  "list",
  "callout",
  "code",
  "divider",
  "diagram",
  "field-string",
  "field-slug",
  "field-text",
  "field-boolean",
  "field-select",
  "field-datetime",
  "field-color",
]);

// canvasDefaultBlock(type) → the minimal VALID portable-doc block for `type`,
// MIRRORING blocks.ex default_block/2 (the server clause a per-block bp-slash-insert
// would build). The canvas inserts the NODE for this block directly, so the block
// shape MUST match default_block/2 so the round-tripped insert-after carries the SAME
// block the server would have produced. Only the insertable types are mapped; an
// unmapped type falls back to an empty paragraph (default_block/2's catch-all).
//
// Fidelity notes (vs default_block/2):
//   * heading  → level 2 + "New heading" text (server default level is 2, NOT 1).
//   * list     → ordered:false, ONE empty item.
//   * callout  → tone "info", ONE empty inline text run (the server default).
//   * code     → lang "" + value "".  divider → bare {type}.  diagram → source/caption "".
//   * field-*  → the per-type {label, value} (+ options for select); value default is
//                false for boolean, "#000000" for color, "" otherwise.
// id is null so runToOps mints a fresh id (the new-block signal) — exactly the
// Enter-split/typed-paragraph path.
export function canvasDefaultBlock(type) {
  switch (type) {
    case "heading":
      return { id: null, type: "heading", text: "New heading", level: 2 };
    case "paragraph":
      return { id: null, type: "paragraph", content: [{ type: "text", value: "" }] };
    case "list":
      return {
        id: null,
        type: "list",
        ordered: false,
        items: [[{ type: "text", value: "" }]],
      };
    case "callout":
      return {
        id: null,
        type: "callout",
        tone: "info",
        content: [{ type: "text", value: "" }],
      };
    case "code":
      return { id: null, type: "code", lang: "", value: "" };
    case "divider":
      return { id: null, type: "divider" };
    case "diagram":
      return { id: null, type: "diagram", source: "", caption: "" };
    case "field-string":
      return { id: null, type: "field-string", label: "Text", value: "" };
    case "field-slug":
      return { id: null, type: "field-slug", label: "Slug", value: "" };
    case "field-text":
      return { id: null, type: "field-text", label: "Long text", value: "" };
    case "field-boolean":
      return { id: null, type: "field-boolean", label: "Boolean", value: false };
    case "field-datetime":
      return { id: null, type: "field-datetime", label: "Date & time", value: "" };
    case "field-color":
      return { id: null, type: "field-color", label: "Color", value: "#000000" };
    case "field-select":
      return {
        id: null,
        type: "field-select",
        label: "Select",
        value: "",
        options: [
          { value: "option-1", label: "Option 1" },
          { value: "option-2", label: "Option 2" },
        ],
      };
    default:
      // Catch-all mirrors default_block/2's terminal clause: an empty paragraph.
      return { id: null, type: "paragraph", content: [{ type: "text", value: "" }] };
  }
}

// slashTypeToNode(type) → the TipTap NODE to insert at the caret for a slash pick.
//
// THE CRUX of the canvas slash menu. Rather than hand-build each per-type node (and
// risk drift from runToTiptap's projection — the exact shape runToOps + nextNodeToBlock
// reverse), we build the default BLOCK (canvasDefaultBlock, mirroring default_block/2)
// and run it through runToTiptap, lifting the single projected node. This GUARANTEES
// the inserted node is byte-identical to one runToTiptap would have produced for a
// server-built default block — so the diff reconstructs the right { type, …default }
// via nextNodeToBlock, for FREE, for every insertable type (prose/atom/content/attr-
// atom/field) without a per-type builder here.
//
// The projected node carries bpId:null (canvasDefaultBlock sets id:null) — the
// new-block signal runToOps needs to mint a fresh id and emit ONE insert-after.
export function slashTypeToNode(type) {
  return runToTiptap([canvasDefaultBlock(type)]).content[0];
}

// True when a slash NODE is an EDITABLE-body block the caret should land INSIDE after
// insert (prose paragraph/heading/list textblock, or a callout whose body is inline
// content). For an ATOM (divider/code/diagram/field) there is no text hole — PM's
// NodeSelection on the atom is the natural post-insert state. Keyed by the NODE type
// (the runToTiptap projection name): paragraph/heading/bulletList/orderedList and
// `callout` are content nodes; divider/bpCode/bpDiagram/bpField are atoms.
export const CANVAS_SLASH_TEXTABLE_NODES = new Set([
  "paragraph",
  "heading",
  "bulletList",
  "orderedList",
  "callout",
]);

// slashTriggerAllowsParent(depth, parentTypeName) → may the `/` slash menu OR the
// `> [!type]` callout shorthand fire when the caret's resolved $from has this
// depth and this parent-node type?
//
// THE GUARD. A slash pick / callout shorthand REPLACES the whole enclosing
// textblock — `start = $pos.before(depth); end = $pos.after(depth)` — with a NEW
// top-level node. That is only safe when the caret sits in a REAL top-level PROSE
// textblock (a paragraph or heading that is a DIRECT child of the doc):
//
//   * depth === 1 alone is NOT enough. A callout BODY (callout-node.js:
//     group:"block", content:"inline*") is ALSO a depth-1 top-level node, so a
//     depth-only guard lets a "/head"+Enter or "> [!warning] " typed INSIDE a
//     callout body pass — and start/end then span the WHOLE callout, so the
//     replaceWith DESTROYS the enclosing callout (chrome + body). Data corruption.
//   * Requiring the parent type to be `paragraph` or `heading` excludes the
//     callout body (parent type "callout") and any future inline-content node-view,
//     so the swap can never replace its own container.
//   * depth !== 1 (e.g. a paragraph nested in a list item, depth 3) is still
//     rejected — swapping the inner paragraph for a top-level node corrupts the doc.
//
// Pure + DOM-free so it unit-tests in plain Node (the canvas custom element can't).
// The wikilink/tag triggers do NOT use this — they insert an inline MARK via
// block-local text, which is valid INSIDE a callout body and must keep working.
export function slashTriggerAllowsParent(depth, parentTypeName) {
  return depth === 1 && (parentTypeName === "paragraph" || parentTypeName === "heading");
}
