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
import { readerPaintClass, selectAtomNode } from "./embed-node.js";
import { canEditObjectBlock, editObjectBlockAt, objectBlockFor, objectBlockValue } from "./inline-object.js";
import { cardMoreButton, wireCardMenu } from "./card-menu.js";

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
    // Above every built-in block's `div[data-bp-type=…]` rule: a carried block
    // that shares a built-in's name (a declared `callout`) must come back as the
    // carry, bpBlock and all (task-d175b72aba4d5cd6).
    return [{ tag: "div[data-bp-opaque]", priority: 80 }];
  },

  renderHTML({ HTMLAttributes }) {
    return ["div", mergeAttributes(HTMLAttributes, { "data-bp-opaque": "" })];
  },

  // A read-only chip node-view (NO edit surface). The whole block rides on bpBlock;
  // PM never reads/writes inside this view.
  addNodeView() {
    return ({ node, editor, view, getPos }) => {
      const block = (node.attrs && node.attrs.bpBlock) || {};
      const bpType = (node.attrs && node.attrs.bpType) || block.type || "block";
      if (bpType === "note") return readonlyNoteView(node, editor);

      const dom = document.createElement("div");
      dom.className = "bp-canvas-readonly bp-canvas-opaque";
      dom.setAttribute("data-bp-opaque", "");
      dom.setAttribute("contenteditable", "false");
      dom.setAttribute("data-test-id", `paper-opaque-${bpType}`);

      const chip = document.createElement("span");
      chip.className = "bp-canvas-readonly-chip";
      paintChip(dom, chip, bpType, block, view && view.dom);
      dom.appendChild(chip);

      // A declared object block's card (contract 1.12.0, shown on a canvas with
      // `block-cards`), as Sanity's block object: a "…" whose menu offers Edit (the
      // block's own dialog, as the block handle's Edit) and Remove, and a click that
      // selects it. CSS shows the button only on an object row of such a canvas.
      const more = cardMoreButton("bp-canvas-object-more");
      dom.appendChild(more);
      const host = () => dom.closest("bp-paper-canvas");
      const at = () => (typeof getPos === "function" ? getPos() : null);
      const closeMenu = wireCardMenu(more, {
        dom,
        menuClass: "bp-canvas-object-menu",
        items: () => {
          const pos = at();
          const cur = pos == null ? null : editor.state.doc.nodeAt(pos);
          const h = host();
          return cur && h ? [...(canEditObjectBlock(h, cur) ? ["edit"] : []), "remove"] : [];
        },
        onPick: (action) => {
          const pos = at();
          const cur = pos == null ? null : editor.state.doc.nodeAt(pos);
          if (!cur || cur.type.name !== BP_OPAQUE_NODE_NAME) return;
          if (action === "edit") editObjectBlockAt(host(), editor, pos);
          else editor.chain().command(({ tr }) => (tr.delete(pos, pos + cur.nodeSize), true)).focus().run();
        },
        top: (r) => r.bottom + 4,
        enabled: () => editor.isEditable && dom.classList.contains("bp-canvas-object-row"),
      });
      dom.addEventListener("click", (e) => {
        if (!editor.isEditable || !dom.closest("bp-paper-canvas[block-cards]") || e.target.closest("button")) return;
        if (dom.classList.contains("bp-canvas-object-row")) selectAtomNode(editor, getPos);
      });

      return {
        dom,
        update: (updated) => {
          if (updated.type.name !== BP_OPAQUE_NODE_NAME) return false;
          const b = (updated.attrs && updated.attrs.bpBlock) || {};
          const t = (updated.attrs && updated.attrs.bpType) || b.type || "block";
          if (t === "note") return false;
          paintChip(dom, chip, t, b, dom);
          return true;
        },
        stopEvent: () => true,
        ignoreMutation: () => true,
        destroy: () => closeMenu(false),
      };
    };
  },
});

// A calm read-only label for a carried block (e.g. "section", "composite", "codelist").
// A custom object block the field DECLARES is a row instead, as Sanity draws one: an
// icon, the kind title and a preview line (a field value, task-65fb83593b2d1c29),
// each its own element a host can style (.bp-canvas-object-row, [data-object-type]).
// The chip's text stays "Callout · warning" (the separator is in the text, not
// shown), so its name and text read the same.
// Sanity's DocumentIcon, a block object's media when its preview has none.
const DOCUMENT_ICON = '<svg class="bp-canvas-object-doc" width="25" height="25" viewBox="0 0 25 25" fill="none" stroke="currentColor" stroke-width="1.2" stroke-linejoin="round"><path d="M11.5 4.5V9.5H6.5"/><path d="M18.5 20.5H6.5V9.5L11.5 4.5H18.5V20.5Z"/></svg>';

function paintChip(dom, chip, bpType, block, el) {
  const host = el && typeof el.closest === "function" ? el.closest("bp-paper-canvas") : null;
  const vocab = host && typeof host._inlineObjectVocabulary === "function" ? host._inlineObjectVocabulary() : null;
  const kind = objectBlockFor(vocab, bpType);
  const row = !!(kind && Array.isArray(kind.fields) && kind.fields.length);
  dom.classList.toggle("bp-canvas-object-row", row);
  if (!row) {
    dom.removeAttribute("data-object-type");
    chip.textContent = bpType ? `↪ ${bpType}` : "↪ block";
    return;
  }
  dom.setAttribute("data-object-type", bpType);
  const value = objectBlockValue(kind, block || {});
  const span = (cls, text) => {
    const s = document.createElement("span");
    s.className = cls;
    if (text != null) s.textContent = text;
    return s;
  };
  // The icon in a tile: a card (block-cards) shows the tile with Sanity's DocumentIcon,
  // a plain row its own small glyph.
  const icon = span("bp-canvas-object-media");
  icon.setAttribute("aria-hidden", "true");
  icon.innerHTML = '<span class="bp-canvas-object-icon" aria-hidden="true"></span>' + DOCUMENT_ICON;
  const text = span("bp-canvas-object-text");
  text.appendChild(span("bp-canvas-object-title", kind.title));
  if (value !== "") {
    text.appendChild(span("bp-canvas-object-sep", " · "));
    text.appendChild(span("bp-canvas-object-preview", value));
  }
  chip.replaceChildren(icon, text);
}

// Unsafe note carriers stay opaque. Only the canonical server producer supplies
// their display; the source-bound paint never enters ProseMirror or save history.
function readonlyNoteView(initialNode, editor) {
  let node = initialNode;
  let destroyed = false;
  const dom = document.createElement("div");
  dom.setAttribute("data-bp-opaque", "");
  dom.setAttribute("data-bp-type", "note");
  dom.setAttribute("data-bp-fleet-id", node.attrs.bpId || "");
  dom.setAttribute("contenteditable", "false");
  dom.setAttribute("data-test-id", "paper-opaque-note");
  const body = document.createElement("div");
  body.className = readerPaintClass(editor);
  body.setAttribute("data-bp-fleet-body", "");
  dom.appendChild(body);

  const fallback = message => {
    dom.className = "bp-canvas-readonly bp-canvas-opaque";
    const chip = document.createElement("span");
    chip.className = "bp-canvas-readonly-chip";
    chip.textContent = message;
    body.replaceChildren(chip);
  };
  const onPaint = event => {
    // Cancel the hook's generic raw injection even for stale/unbound replies.
    event.preventDefault();
    const { html, sourceBlock } = event.detail || {};
    if (!sourceBlock || sourceBlock.id !== node.attrs.bpId ||
        !node.type.create({ ...node.attrs, bpBlock: sourceBlock }).eq(node)) return;
    if (typeof html !== "string" || html.trim() === "") {
      fallback("Note preview unavailable (read-only).");
      return;
    }
    // This HTML comes from bp:block-html, never from a source-block HTML field.
    body.innerHTML = html;
    dom.className = "bp-canvas-note-preview";
  };
  // A conflict can cache the latest paired paint before this node exists or
  // accepts its source. Replay through the existing hook after PM installs it.
  const signalReady = () => queueMicrotask(() => {
    if (!destroyed && dom.isConnected) {
      dom.dispatchEvent(new CustomEvent("bp-ready", { bubbles: true, composed: true }));
    }
  });
  body.addEventListener("bp-fleet-paint", onPaint);
  fallback("Loading note preview (read-only)…");
  signalReady();
  return {
    dom,
    update(updated) {
      if (updated.type.name !== BP_OPAQUE_NODE_NAME || updated.attrs.bpType !== "note") return false;
      const changed = !updated.eq(node);
      if (changed) fallback("Loading note preview (read-only)…");
      node = updated;
      dom.setAttribute("data-bp-fleet-id", node.attrs.bpId || "");
      if (changed) signalReady();
      return true;
    },
    stopEvent: () => true,
    ignoreMutation: () => true,
    destroy() {
      destroyed = true;
      body.removeEventListener("bp-fleet-paint", onPaint);
    },
  };
}
