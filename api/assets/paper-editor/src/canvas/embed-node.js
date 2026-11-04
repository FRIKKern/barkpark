// embed-node.js — stable public facade plus the Fleet node view.

import { Node, mergeAttributes } from "@tiptap/core";
import { isStatsType, wireStatsInline } from "./stats-inline.js";
import { wireCardsInline } from "./cards-inline.js";
import { wireNotesInline } from "./notes-inline.js";
import { isFleetTextType, wireFleetTextInline } from "./fleet-text-inline.js";
import {
  readOnlyAtomAttributes,
  readerPaintClass,
  isBlockLocked,
  atomAriaLabel,
  wireAtomAccessibility,
} from "./readonly-atom-node.js";
import {
  BP_FLEET_NODE_NAME,
  fleetChipLabel,
  fleetKindEditable,
} from "./fleet-model.js";
import { buildFleetEditor } from "./fleet-editor.js";

export {
  BP_SHEET_NODE_NAME,
  BP_EMBED_NODE_NAME,
  sheetChipLabel,
  embedChipLabel,
  atomBlockRetargeted,
  atomRetargetAllowed,
  Sheet,
  Embed,
  readerPaintClass,
  isBlockLocked,
  atomAriaLabel,
  isActivateKey,
  selectAtomNode,
  wireAtomAccessibility,
} from "./readonly-atom-node.js";
export {
  BP_FLEET_NODE_NAME,
  fleetChipLabel,
  datumEditorSpec,
  datumEditorRows,
  datumEditorSet,
  datumEditorMove,
  fleetKindEditable,
  fleetEditorText,
  fleetEditorParse,
} from "./fleet-model.js";

// The `bpFleet` node. Shares the read-only atom SCHEMA (atom, group:"block",
// selectable, defining, the id/type/bpBlock attrs, the data-bp-type parse anchor)
// but overrides the NodeView to render a server-paint hole instead of a chip. The
// schema object loads in pure Node (the NodeView factory references `document`
// lazily), so __smoke.mjs / __fleet.test.mjs import run-convert.js without a browser.
export const Fleet = Node.create({
  name: BP_FLEET_NODE_NAME,
  group: "block",
  atom: true,
  selectable: true,
  defining: true,

  addAttributes() {
    return readOnlyAtomAttributes();
  },

  // Parse ONLY our own data-attributed wrapper (a <div data-bp-fleet='true'>),
  // reading the whole block off data-bp-block. No bare-tag claim, so we never
  // contend with sheet/embed (which anchor on their own data-bp-type) or any other
  // node's parse rule.
  parseHTML() {
    return [{ tag: "div[data-bp-fleet='true']" }];
  },

  // Schema-level fallback render (no node-view mounted — pure-Node round-trip /
  // non-editable export). All data rides the typed attrs; data-bp-fleet is the
  // parse anchor.
  renderHTML({ HTMLAttributes }) {
    return ["div", mergeAttributes(HTMLAttributes, { "data-bp-fleet": "true" })];
  },

  // The NodeView: a read-only paint hole. Builds
  //   <div class="bp-canvas-readonly" data-bp-fleet-id="<id>" data-bp-type="<type>"
  //        contenteditable="false">
  //     <div class="bp-paper-surface" data-bp-fleet-body>
  //       <div class="bp-canvas-readonly-chip">…loading label…</div>
  //   The Studio hook replaces the hole's contents with the server HTML on
  //   bp:block-html. contentEditable false + stopEvent/ignoreMutation so PM never
  //   turns a click (or the hook's own innerHTML write) into a transaction or reads
  //   it back into the document.
  addNodeView() {
    return ({ node, getPos, editor }) => {
      const block = (node.attrs && node.attrs.bpBlock) || {};
      const bpType = (node.attrs && node.attrs.bpType) || (block && block.type) || "";
      const bpId = (node.attrs && node.attrs.bpId) || "";

      const dom = document.createElement("div");
      dom.className = "bp-canvas-readonly bp-canvas-fleet";
      dom.setAttribute("data-bp-type", bpType);
      dom.setAttribute("data-bp-fleet-id", bpId);
      dom.setAttribute("contenteditable", "false");
      dom.setAttribute("data-test-id", `paper-fleet-${bpType}`);

      const body = document.createElement("div");
      // The `.bp-paper-surface` sink: the injected reader HTML is styled by the ONE
      // canonical stylesheet exactly as /papers renders it (D8 — no hand-mirrored
      // markup, no editor-only CSS).
      body.className = readerPaintClass(editor);
      body.setAttribute("data-bp-fleet-body", "");

      const chip = document.createElement("div");
      chip.className = "bp-canvas-readonly-chip";
      chip.textContent = fleetChipLabel(block);
      body.appendChild(chip);
      dom.appendChild(body);

      // pd-ee-fleet-editors: the structured EDIT ISLAND, a SIBLING of the paint hole
      // (so the server hook's innerHTML write into [data-bp-fleet-body] never touches
      // it). Built ONLY for an editable fleet kind (cards/notes/pipeline items, task-*
      // query) that is NOT template-locked; other kinds stay purely read-only. An edit
      // writes the mutated block to attrs.bpBlock via setNodeMarkup → run-convert emits
      // ONE patch-block → the server repaints the hole (D8: still 100% server-painted).
      // The island sits in a "Configure" disclosure whose toggle is revealed on hover /
      // focus (resting chrome, opacity only) and opens on click — never in flow on hover.
      const isEditableKind = fleetKindEditable(bpType) && !isBlockLocked(block);
      let fleetEditor = null;
      let nativeConfig = null;
      const currentBlock = () => {
        const pos = typeof getPos === "function" ? getPos() : null;
        return pos == null ? block : editor.state.doc.nodeAt(pos)?.attrs.bpBlock || block;
      };
      const commitBlock = nextBlock => {
        if (!editor.isEditable || isBlockLocked(currentBlock()) || typeof getPos !== "function") return;
        const pos = getPos();
        const cur = pos == null ? null : editor.state.doc.nodeAt(pos);
        if (!cur || cur.type.name !== BP_FLEET_NODE_NAME) return;
        editor.view.dispatch(editor.state.tr.setNodeMarkup(pos, undefined, { ...cur.attrs, bpBlock: nextBlock }));
      };
      const wireNative = isStatsType(bpType) ? wireStatsInline : bpType === "cards" ? wireCardsInline
        : bpType === "notes" ? wireNotesInline
        : isFleetTextType(bpType) ? (el, options) => wireFleetTextInline(el, options, bpType) : null;
      const nativeInline = wireNative ? wireNative(body, {
        getBlock: currentBlock, isEditable: () => editor.isEditable,
        commit: commitBlock, undo: () => editor.commands.undo(), redo: () => editor.commands.redo(),
      }) : null;
      let focused = false;
      const syncReveal = () => {
        if (!fleetEditor) return;
        // The disclosure itself is hover/focus-revealed by CSS (opacity only — it
        // never takes flow space); here it only disappears outside editability.
        nativeConfig.style.display = editor.isEditable && !isBlockLocked(currentBlock()) ? "" : "none";
      };
      const onFocusIn = () => {
        focused = true;
        syncReveal();
      };
      const onFocusOut = (e) => {
        // Focus-within guard (code/task-list pattern): keep revealed while focus only
        // MOVES within the atom (relatedTarget still inside).
        if (e && e.relatedTarget && dom.contains(e.relatedTarget)) return;
        focused = false;
        syncReveal();
      };
      if (isEditableKind) {
        fleetEditor = buildFleetEditor(block, {
          isEditable: () => editor.isEditable && !isBlockLocked(currentBlock()),
          onEdit: (nextBlock) => {
            if (!editor.isEditable) return;
            if (typeof getPos !== "function") return;
            const pos = getPos();
            if (pos == null) return;
            const cur = editor.state.doc.nodeAt(pos);
            if (!cur) return;
            editor
              .chain()
              .command(({ tr }) => {
                tr.setNodeMarkup(pos, undefined, {
                  ...cur.attrs,
                  bpBlock: nextBlock,
                });
                return true;
              })
              .run();
          },
        });
        // EVERY editable kind's island lives in an out-of-flow "Configure" disclosure.
        // Hover only reveals the (absolutely placed) toggle; the island takes page
        // space only once the author OPENS it. An in-flow island shown on hover would
        // collapse on pointer-leave and slide the next block under the pointer, so a
        // click aimed at that block's text landed (and saved) in the block below.
        dom.classList.add("bp-paper-contextual-editor");
        if (nativeInline && isStatsType(bpType)) dom.classList.add("bp-canvas-stats-inline");
        nativeConfig = document.createElement("details");
        const configKind = !nativeInline || isFleetTextType(bpType) ? "fleet"
          : bpType === "cards" || bpType === "notes" ? bpType : "stats";
        nativeConfig.className = `bp-paper-contextual-controls bp-paper-${configKind}-config`;
        const summary = document.createElement("summary");
        summary.className = "bp-paper-contextual-toggle";
        summary.textContent = { cards: "Configure Cards", notes: "Configure Notes", stats: "Configure Stats" }[configKind]
          || `Configure ${fleetChipLabel(block)}`;
        nativeConfig.appendChild(summary);
        fleetEditor.el.classList.add("bp-paper-contextual-panel");
        nativeConfig.appendChild(fleetEditor.el);
        dom.appendChild(nativeConfig);
        dom.addEventListener("focusin", onFocusIn);
        dom.addEventListener("focusout", onFocusOut);
        syncReveal();
      }
      const flushFleetEditor = () => {
        if (nativeInline) nativeInline.flush();
        if (fleetEditor) fleetEditor.flush();
      };
      dom.addEventListener("bp-flush-node", flushFleetEditor);

      // pdd-t12c: keyboard + screen-reader parity — a tab stop with the fleet block's
      // human name + locked-state announcement, and Enter/Space → select (→ Backspace
      // deletes). The painted reader HTML keeps ALL its own interactivity: interior
      // links/inputs/scrollers stay native (the island stopEvent/ignoreMutation
      // contract below never swallows them), and the aria-label names the WHOLE block
      // for a screen reader landing on the atom. `e.target !== dom` guards so a
      // keystroke inside a painted form control is never hijacked for atom selection.
      wireAtomAccessibility(dom, {
        block,
        chipText: fleetChipLabel(block),
        editor,
        getPos,
      });

      return {
        dom,
        // KEEP the existing DOM across attr updates (echo / undo): returning true
        // preserves the paint hole AND whatever server HTML the hook already
        // injected into it — a re-created node-view would flash back to the chip.
        // A fresh paint for changed content arrives on the hook's own channel
        // (bp:block-html, keyed by the stable data-bp-fleet-id), never from PM.
        update: (updated) => {
          if (updated.type.name !== BP_FLEET_NODE_NAME) return false;
          // Keep the accessible name + lock cue in lockstep with the carried block
          // (an echo/undo could change locked state) WITHOUT touching the painted
          // body — the aria lives on the wrapper, so the server HTML is untouched.
          const b = (updated.attrs && updated.attrs.bpBlock) || {};
          dom.setAttribute("aria-label", atomAriaLabel(fleetChipLabel(b), b));
          if (isBlockLocked(b)) dom.setAttribute("data-bp-locked", "true");
          else dom.removeAttribute("data-bp-locked");
          // Re-seed the editor from an echo / undo WITHOUT clobbering an in-progress
          // edit (refresh no-ops when the block is content-equal or focus is inside).
          if (fleetEditor) fleetEditor.refresh(b, focused);
          if (nativeInline) nativeInline.refresh();
          syncReveal();
          return true;
        },
        // PM must NOT turn a click inside the painted body into a transaction — a
        // click only ever SELECTS the atom.
        stopEvent: () => true,
        // PM must NOT read the body's DOM mutations back into the document — the
        // hook mutates the paint hole's innerHTML directly and PM must ignore it.
        ignoreMutation: () => true,
        destroy: () => {
          if (nativeInline) nativeInline.destroy();
          dom.removeEventListener("bp-flush-node", flushFleetEditor);
          if (fleetEditor) {
            fleetEditor.destroy();
            dom.removeEventListener("focusin", onFocusIn);
            dom.removeEventListener("focusout", onFocusOut);
          }
        },
      };
    };
  },
});
