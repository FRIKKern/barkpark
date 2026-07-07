// opaque-node.js — the MOUNTABLE twin of run-convert.js's `bpOpaque` verbatim carry.
//
// run-convert.js has always PROJECTED a non-canvas block to a `{ type:"bpOpaque",
// attrs:{ bpId, bpType, bpBlock:<deep-cloned block> } }` node, but until now NO node
// named `bpOpaque` was registered in the canvas schema. That was harmless at the DOC
// TOP LEVEL because the run partition (paper_canvas.ex partition_runs/1) guarantees a
// canvas run contains ONLY canvas-eligible blocks — so a top-level opaque node never
// actually reached setContent.
//
// The section container changes that: a `section` body can legitimately hold a
// NON-canvas child (a nested section — carried opaque by the V1 depth-guard — or a
// composite/codelist/localizedText that is not canvas-eligible), which run-convert
// projects to a bpOpaque node INSIDE the bpSection body. If bpOpaque were unregistered,
// ProseMirror's Node.fromJSON would reject it (or PM would LIFT it out) → data loss on
// OPEN. Registering it makes such a child mount as a READ-ONLY verbatim carry that
// round-trips byte-identical (the whole block rides on bpBlock; ZERO value/content ops).
//
// This is the SAME read-only-atom shape sheet/embed/fleet use (embed-node.js
// readOnlyAtomNode) — an atom carrying the whole block on `bpBlock`, a read-only chip,
// stopEvent/ignoreMutation so PM never turns a click into a transaction — but with a
// GENERIC bpType (it serves any carried kind) and a generic parse anchor
// (`div[data-bp-opaque]`) so it never contends with another node's parse rule.

import { Node, mergeAttributes } from "@tiptap/core";

export const BP_OPAQUE_NODE_NAME = "bpOpaque";

export const Opaque = Node.create({
  name: BP_OPAQUE_NODE_NAME,

  // A block sibling — valid both at the doc top level (block+) and, crucially, inside
  // a bpSection body (which lists bpOpaque in its content expression).
  group: "block",

  // An atom leaf: no PM-editable interior. The whole block rides on bpBlock and is
  // never edited in the canvas, so caret-select + Backspace/Delete of the selected
  // atom (→ a structural remove) come free.
  atom: true,

  selectable: true,

  // A verbatim carry is a leaf container, not a textblock — defining keeps PM from
  // merging an adjacent textblock into it on backspace-at-edge.
  defining: true,

  addAttributes() {
    return {
      bpId: {
        default: null,
        parseHTML: (el) => el.getAttribute("data-bp-id"),
        renderHTML: (attrs) => (attrs.bpId ? { "data-bp-id": attrs.bpId } : {}),
      },
      bpType: {
        default: null,
        parseHTML: (el) => el.getAttribute("data-bp-type"),
        renderHTML: (attrs) =>
          attrs.bpType ? { "data-bp-type": attrs.bpType } : {},
      },
      // bpBlock — the WHOLE block, carried VERBATIM (deep-cloned by the projector), so
      // the opaque child round-trips byte-identical through getJSON. data-bp-block is a
      // JSON attribute (same carrier sheet/embed/fleet use for their whole-block carry).
      bpBlock: {
        default: null,
        parseHTML: (el) => {
          const raw = el.getAttribute("data-bp-block");
          if (raw == null) return null;
          try {
            return JSON.parse(raw);
          } catch (_e) {
            return null;
          }
        },
        renderHTML: (attrs) =>
          attrs.bpBlock != null
            ? { "data-bp-block": JSON.stringify(attrs.bpBlock) }
            : {},
      },
    };
  },

  // Match ONLY our own generic opaque wrapper; no bare-tag claim, so we never contend
  // with sheet/embed/section/field parse rules (all of which key on data-bp-type).
  parseHTML() {
    return [{ tag: "div[data-bp-opaque]" }];
  },

  renderHTML({ HTMLAttributes }) {
    return ["div", mergeAttributes(HTMLAttributes, { "data-bp-opaque": "" })];
  },

  // A read-only chip node-view (NO edit surface). The whole block rides on bpBlock;
  // PM never reads/writes inside this view.
  addNodeView() {
    return ({ node }) => {
      const block = (node.attrs && node.attrs.bpBlock) || {};
      const bpType = (node.attrs && node.attrs.bpType) || block.type || "block";

      const dom = document.createElement("div");
      dom.className = "bp-canvas-readonly bp-canvas-opaque";
      dom.setAttribute("data-bp-opaque", "");
      dom.setAttribute("contenteditable", "false");
      dom.setAttribute("data-test-id", `paper-opaque-${bpType}`);

      const chip = document.createElement("span");
      chip.className = "bp-canvas-readonly-chip";
      chip.textContent = opaqueChipLabel(bpType);
      dom.appendChild(chip);

      return {
        dom,
        update: (updated) => {
          if (updated.type.name !== BP_OPAQUE_NODE_NAME) return false;
          const b = (updated.attrs && updated.attrs.bpBlock) || {};
          const t = (updated.attrs && updated.attrs.bpType) || b.type || "block";
          chip.textContent = opaqueChipLabel(t);
          return true;
        },
        stopEvent: () => true,
        ignoreMutation: () => true,
      };
    };
  },
});

// A calm read-only label for a carried block (e.g. "section", "composite", "codelist").
function opaqueChipLabel(bpType) {
  return bpType ? `↪ ${bpType}` : "↪ block";
}
