// bp-attrs.js — Phase-4 Stage S1: the attr-preservation extension for the
// continuous canvas (<bp-paper-canvas>).
//
// THE MAKE-OR-BREAK OF S1. run-convert.js:runToTiptap stamps every top-level
// node with attrs:{ bpId, bpType } so the reverse diff (runToOps) can key edits
// by the surviving bpId. But TipTap/ProseMirror DROP unknown node attributes on
// the setContent -> getJSON round-trip UNLESS the node TYPE declares them —
// ProseMirror's schema only serializes attrs it knows about. Without this
// extension editor.getJSON() returns nodes with NO bpId, so runToOps treats
// every block as new (mints fresh ids, removes the old) and mis-diffs the whole
// run. WITH it, the ids survive the DOM round-trip and runToOps diffs correctly.
//
// Mechanism: addGlobalAttributes registers bpId + bpType on the four TOP-LEVEL
// block node types a prose run can hold (paragraph | heading | bulletList |
// orderedList — see run-convert.js PROSE_TYPES + convert.js blockToTiptap). The
// parseHTML/renderHTML pair persists each attr as a data-* DOM attribute so it
// survives ProseMirror's serialize→parse cycle inside setContent/getJSON. We
// deliberately DON'T register on listItem: a list is ONE top-level run-node
// (bulletList/orderedList) carrying its own bpId; the inner listItems are never
// top-level and never stamped by runToTiptap.
//
// DOM-aware (parseHTML reads el.getAttribute) but the Extension object itself is
// inert until mounted in an Editor, so it imports cleanly.

import { Extension } from "@tiptap/core";

// The block node types runToTiptap stamps as top-level run-nodes. A heading and
// a paragraph project to themselves; a `list` block projects to a bulletList or
// orderedList. listItem is intentionally absent (see header).
const BP_BLOCK_TYPES = ["paragraph", "heading", "bulletList", "orderedList"];

export const BpAttrs = Extension.create({
  name: "bpAttrs",

  addGlobalAttributes() {
    return [
      {
        types: BP_BLOCK_TYPES,
        attributes: {
          // bpId — the portable-doc block id runToOps keys by. data-bp-id is the
          // DOM carrier that survives the setContent->getJSON round-trip.
          bpId: {
            default: null,
            parseHTML: (el) => el.getAttribute("data-bp-id"),
            renderHTML: (attrs) =>
              attrs.bpId ? { "data-bp-id": attrs.bpId } : {},
          },
          // bpType — the original portable-doc block kind (paragraph|heading|
          // list). runToOps reads it back off the node attrs; data-bp-type
          // carries it through the DOM round-trip.
          bpType: {
            default: null,
            parseHTML: (el) => el.getAttribute("data-bp-type"),
            renderHTML: (attrs) =>
              attrs.bpType ? { "data-bp-type": attrs.bpType } : {},
          },
          // locked — the DOCTRINE template lock (pdd-t2). A true value marks a
          // MANDATED template block (the locked title @0, featured image @1) that
          // CANNOT be deleted or moved: the server backstops it (patch.ex:192-274)
          // and the canvas vetoes it live (index.js filterTransaction, which reads
          // node.attrs.locked). ADDITIVE / D3: rendered ONLY when true, so a normal
          // (unlocked) block round-trips BYTE-IDENTICALLY with no data-bp-locked
          // attr — and parseHTML yields null for the absent attr. A true value also
          // carries a calm hover cue (`title`) — chrome around content, never an
          // error flash (doctrine rule 5). data-bp-locked survives the
          // setContent->getJSON round-trip so runToTiptap's stamp is read back.
          locked: {
            default: null,
            parseHTML: (el) =>
              el.getAttribute("data-bp-locked") === "true" ? true : null,
            renderHTML: (attrs) =>
              attrs.locked === true
                ? {
                    "data-bp-locked": "true",
                    title: "Part of the document template",
                  }
                : {},
          },
          // role — the template ROLE ("title" | "featured" | …). Carried VERBATIM
          // so a locked block round-trips its role; rendered ONLY when present
          // (D3 byte-fidelity — an unlocked block has no data-bp-role).
          role: {
            default: null,
            parseHTML: (el) => el.getAttribute("data-bp-role"),
            renderHTML: (attrs) =>
              attrs.role ? { "data-bp-role": attrs.role } : {},
          },
        },
      },
    ];
  },
});
