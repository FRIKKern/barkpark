// note-node.js — the notes-grid split: the singular `note` WIDGET as a canvas node.
//
// Brings the NEW `note` block INTO the continuous canvas as a ProseMirror CONTENT
// node. A note is a callout SUPERSET: callout exposes ONE editable body; a note is
// "fully editable, no look-but-don't-touch" (composition-doctrine P2) — ALL THREE of
// its fields are genuinely user-editable:
//   * body  → THE contentDOM (content:"inline*"), a real editable inline region that
//             JOINS the run + FormatBubble (the callout body precedent; a PM NodeView
//             has EXACTLY ONE contentDOM, so the body claims it). Its plain encoding is
//             the flat `text` field.
//   * label → an attr-backed non-PM <input> ISLAND writing node.attrs.label (the
//             diagram/figure caption-island precedent: contentEditable=false chrome, a
//             short single-line value maps naturally to an input, not a PM textblock).
//   * lead  → an attr-backed non-PM <input> ISLAND writing node.attrs.lead; cleared →
//             null → round-trips ABSENT (byte-fidelity, the callout title precedent).
// Every field edit emits a patch-block carrying ONLY the changed field (run-convert.js
// noteNodeToPatch).
//
// ── VIEW⇄EDIT PARITY: the DELIBERATE non-class-share ──────────────────────────
//
// CHROME = `bp-canvas-note*` ONLY. UNLIKE callout/card (which carry the reader's own
// bp-callout / bp-card classes to inherit the reader paint), the note canvas node does
// NOT class-share with the reader: the parity-gate §3 forbids the legacy plural-grid
// wrapper class and the `bp-note` inner-element family (the __k / __d children) anywhere
// in the editor JS, and the WHOLE `bp-canvas-note` family dodges both by construction —
// the canvas prefix `bp-canvas-` is followed by `canvas`, never `note`, and it lacks the
// trailing `s` of the grid wrapper, so no forbidden substring is ever formed. The
// consequence: reader parity is proven by the compose BYTE-IDENTITY test
// (Components.note_item_html == a legacy grid row), NOT by shared classes; the
// edit-chrome CSS that MIMICS the reader row visuals lives in the editor bundle
// STYLESHEET (styles.css), never as a JS class literal here. The reader ground truth is
// Components.note_item_html/1: a `bp-note` row = a label chip child + a description
// child holding an optional bold lead run then the text.
// The body FLATTENS to plain text server-side (Slots.note_body_text), so inline marks
// authored here round-trip in persistence but do NOT render — the deliberate lossy
// tradeoff (byte-compat over rich body), matching the legacy notes item.
//
// DOM-aware (the NodeView builds real DOM) but the Node SCHEMA object loads in plain
// Node (imports ONLY @tiptap/core; references `document` lazily inside addNodeView,
// which never runs in the pure-Node smoke harness). run-convert.js references the note
// TYPE only (a string), never this NodeView, so the smoke suite runs headless.

import { Node, mergeAttributes } from "@tiptap/core";

// The TipTap node NAME is `note` (== its portable-doc bpType) — the callout convention
// (node.type === bpType, no NODE_NAME indirection). No StarterKit `note` node collides.
export const BP_NOTE_BP_TYPE = "note";

export const Note = Node.create({
  name: "note",

  // A top-level block sibling inside the one canvas document. group:"block" lets it sit
  // in the doc's `block+` content AND in a grid section's body.
  group: "block",

  // The body slot is a SINGLE editable inline region — a paragraph's content model
  // (the callout body precedent). NOT block+.
  content: "inline*",

  selectable: true,

  // defining — PM won't merge the note into an adjacent textblock on backspace-at-edge
  // (Backspace at the body start lifts out of the note rather than dissolving chrome).
  defining: true,

  addAttributes() {
    return {
      // bpId — the portable-doc block id runToOps keys by.
      bpId: {
        default: null,
        parseHTML: (el) => el.getAttribute("data-bp-id"),
        renderHTML: (attrs) => (attrs.bpId ? { "data-bp-id": attrs.bpId } : {}),
      },
      // bpType — the original portable-doc block kind ("note").
      bpType: {
        default: BP_NOTE_BP_TYPE,
        parseHTML: (el) => el.getAttribute("data-bp-type") || BP_NOTE_BP_TYPE,
        renderHTML: (attrs) => ({ "data-bp-type": attrs.bpType || BP_NOTE_BP_TYPE }),
      },
      // label — the label slot's plain text, PRESENT-ONLY. Empty/absent → no data-label
      // (round-trips ABSENT; noteNodeToBlock omits it, the reader shows an empty chip).
      label: {
        default: null,
        parseHTML: (el) =>
          el.hasAttribute("data-label") ? el.getAttribute("data-label") : null,
        renderHTML: (attrs) =>
          attrs.label != null ? { "data-label": attrs.label } : {},
      },
      // lead — the lead slot's plain text, PRESENT-ONLY. A null/absent lead round-trips
      // ABSENT (never ""), byte-mirroring the callout title.
      lead: {
        default: null,
        parseHTML: (el) =>
          el.hasAttribute("data-lead") ? el.getAttribute("data-lead") : null,
        renderHTML: (attrs) =>
          attrs.lead != null ? { "data-lead": attrs.lead } : {},
      },
    };
  },

  parseHTML() {
    return [{ tag: "div[data-bp-type='note']" }];
  },

  // A schema-level fallback render (used when NO node-view is mounted — the pure-Node
  // round-trip / a non-editable export). The node-view (below) OVERRIDES this. The `0`
  // is the inline body content hole; chrome (label/lead) lives ONLY in the node-view,
  // so parseHTML never mis-parses chrome as body.
  renderHTML({ HTMLAttributes }) {
    return [
      "div",
      mergeAttributes(HTMLAttributes, { "data-bp-type": "note" }),
      ["div", { "data-note-body": "" }, 0],
    ];
  },

  // ── the NodeView: label island + description (lead island + editable body) ────
  //
  //   <div class="bp-canvas-note" data-bp-type="note">
  //     <input class="bp-canvas-note__k">                 ← EDITABLE label island
  //     <div class="bp-canvas-note__d">
  //       <input class="bp-canvas-note__lead">            ← EDITABLE lead island
  //       <div class="bp-canvas-note__body">…</div>       ← contentDOM (editable body)
  //     </div>
  //   </div>
  //
  // The label/lead islands write node.attrs.{label,lead} via a debounced,
  // re-entrancy-guarded setNodeMarkup (the card title-island precedent); their
  // events/mutations are hidden from PM (stopEvent/ignoreMutation) so PM never treats an
  // input keystroke as a body edit. All classes are `bp-canvas-note*` (parity §3).
  addNodeView() {
    return ({ node, editor, getPos }) => {
      const dom = document.createElement("div");
      dom.className = "bp-canvas-note";
      dom.setAttribute("data-bp-type", "note");

      // label island — a single-line input (contentEditable=false so PM leaves it alone).
      const labelInput = document.createElement("input");
      labelInput.type = "text";
      labelInput.className = "bp-canvas-note__k";
      labelInput.placeholder = "label";
      labelInput.contentEditable = "false";
      labelInput.setAttribute("data-test-id", "paper-note-label");

      // description column: the lead island above the editable body.
      const desc = document.createElement("div");
      desc.className = "bp-canvas-note__d";

      const leadInput = document.createElement("input");
      leadInput.type = "text";
      leadInput.className = "bp-canvas-note__lead";
      leadInput.placeholder = "lead (optional)";
      leadInput.contentEditable = "false";
      leadInput.setAttribute("data-test-id", "paper-note-lead");

      // body — the contentDOM hole PM fills with the inline body slot.
      const body = document.createElement("div");
      body.className = "bp-canvas-note__body";

      desc.append(leadInput, body);
      dom.append(labelInput, desc);

      // Write an attr via a re-entrancy-guarded setNodeMarkup (the card/section precedent).
      const writeAttr = (mutate) => {
        if (!editor.isEditable) return;
        if (typeof getPos !== "function") return;
        const pos = getPos();
        if (pos == null) return;
        const cur = editor.state.doc.nodeAt(pos);
        if (!cur || cur.type.name !== "note") return;
        const nextAttrs = mutate({ ...cur.attrs });
        editor
          .chain()
          .command(({ tr }) => {
            tr.setNodeMarkup(pos, undefined, nextAttrs);
            return true;
          })
          .run();
      };

      const currentNode = () => {
        if (typeof getPos !== "function") return node;
        const pos = getPos();
        if (pos == null) return node;
        return editor.state.doc.nodeAt(pos) || node;
      };

      const paint = (n) => {
        const a = (n && n.attrs) || {};
        const label = a.label == null ? "" : a.label;
        const lead = a.lead == null ? "" : a.lead;
        // Never clobber a focused input's caret; only write when the DOM disagrees.
        if (labelInput.value !== label && document.activeElement !== labelInput) {
          labelInput.value = label;
        }
        if (leadInput.value !== lead && document.activeElement !== leadInput) {
          leadInput.value = lead;
        }
        const editable = editor.isEditable;
        labelInput.disabled = !editable;
        leadInput.disabled = !editable;
      };

      // Debounced write-back per field (cleared → null → round-trips ABSENT).
      let labelTimer = null;
      let leadTimer = null;
      const commitLabel = () => {
        const raw = labelInput.value || "";
        const next = raw === "" ? null : raw;
        writeAttr((attrs) => {
          if ((attrs.label || null) === next) return attrs;
          attrs.label = next;
          return attrs;
        });
      };
      const commitLead = () => {
        const raw = leadInput.value || "";
        const next = raw === "" ? null : raw;
        writeAttr((attrs) => {
          if ((attrs.lead || null) === next) return attrs;
          attrs.lead = next;
          return attrs;
        });
      };
      const scheduleWrite = (which) => {
        if (!editor.isEditable) return;
        if (which === "label") {
          if (labelTimer) clearTimeout(labelTimer);
          labelTimer = setTimeout(() => {
            labelTimer = null;
            commitLabel();
          }, 250);
        } else {
          if (leadTimer) clearTimeout(leadTimer);
          leadTimer = setTimeout(() => {
            leadTimer = null;
            commitLead();
          }, 250);
        }
      };
      const flushPending = () => {
        if (labelTimer) {
          clearTimeout(labelTimer);
          labelTimer = null;
          commitLabel();
        }
        if (leadTimer) {
          clearTimeout(leadTimer);
          leadTimer = null;
          commitLead();
        }
      };

      const onLabelInput = () => scheduleWrite("label");
      const onLeadInput = () => scheduleWrite("lead");
      // Enter in a single-line island commits (blur) instead of inserting a newline.
      const onIslandKeydown = (e) => {
        if (e.key === "Enter") {
          e.preventDefault();
          e.target.blur();
        }
      };
      labelInput.addEventListener("input", onLabelInput);
      leadInput.addEventListener("input", onLeadInput);
      labelInput.addEventListener("keydown", onIslandKeydown);
      leadInput.addEventListener("keydown", onIslandKeydown);
      dom.addEventListener("bp-flush-node", flushPending);

      paint(node);

      return {
        dom,
        contentDOM: body,
        update: (updated) => {
          if (updated.type.name !== "note") return false;
          paint(updated);
          return true;
        },
        // The islands are their own edit surface — PM must not intercept their events.
        stopEvent: (e) => {
          const t = e && e.target;
          return !!(t && (t === labelInput || t === leadInput));
        },
        ignoreMutation: (m) => {
          if (m.type === "selection") return false; // let PM own selection
          if (m.type === "attributes" && m.target === dom) return true;
          if (m.target === labelInput || labelInput.contains(m.target)) return true;
          if (m.target === leadInput || leadInput.contains(m.target)) return true;
          // Let PM handle mutations inside the editable body (contentDOM); ignore chrome.
          return !body.contains(m.target);
        },
        destroy: () => {
          if (labelTimer) clearTimeout(labelTimer);
          if (leadTimer) clearTimeout(leadTimer);
          labelInput.removeEventListener("input", onLabelInput);
          leadInput.removeEventListener("input", onLeadInput);
          labelInput.removeEventListener("keydown", onIslandKeydown);
          leadInput.removeEventListener("keydown", onIslandKeydown);
          dom.removeEventListener("bp-flush-node", flushPending);
        },
      };
    };
  },
});
