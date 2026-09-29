// note-node.js — the notes-grid split: the singular `note` WIDGET as a canvas node.
//
// Brings the NEW `note` block INTO the continuous canvas as a ProseMirror CONTENT
// node. A note is a callout SUPERSET: callout exposes ONE editable body; a note is
// editable when all three source carriers are losslessly supported (unsupported
// notes use the existing read-only opaque node):
//   * body  → THE contentDOM (content:"inline*"), a real editable inline region that
//             JOINS the run + FormatBubble (the callout body precedent; a PM NodeView
//             has EXACTLY ONE contentDOM, so the body claims it). Its plain encoding is
//             flat text for new notes; original carriers are retained for edits.
//   * label → an attr-backed native text ISLAND writing node.attrs.label (the
//             diagram/figure caption-island precedent: contentEditable=false chrome, a
//             short single-line value maps naturally to an input, not a PM textblock).
//   * lead  → an attr-backed native text ISLAND writing node.attrs.lead; cleared →
//             null; persistence clears the active carrier without dropping metadata.
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
// are not authored here. Original source wrappers survive plain-text edits intact.
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
  marks: "", // Reader text is plain; existing source wrappers stay in bpBlock.

  selectable: true,

  // defining — PM won't merge the note into an adjacent textblock on backspace-at-edge
  // (Backspace at the body start lifts out of the note rather than dissolving chrome).
  defining: true,

  addAttributes() {
    return {
      // Authoritative source for lossless reconstruction; never serialized to HTML.
      bpBlock: { default: null, rendered: false },
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

  // Reader-shaped native text islands, matching the callout run-in title pattern.
  // Plain inline elements can wrap with the body; input controls cannot.
  addNodeView() {
    return ({ node, editor, getPos }) => {
      const dom = document.createElement("div");
      dom.className = "bp-canvas-note";
      dom.setAttribute("data-bp-type", "note");
      const labelHost = document.createElement("span");
      labelHost.className = "bp-canvas-note__label-host";
      labelHost.contentEditable = "false";
      const label = document.createElement("span");
      label.className = "bp-canvas-note__k";
      labelHost.appendChild(label);
      const desc = document.createElement("div");
      desc.className = "bp-canvas-note__d";
      const leadHost = document.createElement("span");
      leadHost.contentEditable = "false";
      const lead = document.createElement("b");
      lead.className = "bp-canvas-note__lead";
      leadHost.appendChild(lead);
      const space = document.createTextNode("");
      const body = document.createElement("span");
      body.className = "bp-canvas-note__body";
      desc.append(leadHost, space, body);
      dom.append(labelHost, desc);

      let current = node;
      const fields = new Map([[label, "label"], [lead, "lead"]]);
      const dirty = new Set();
      const composing = new Set();
      const markPending = () => dom.toggleAttribute("data-note-pending", dirty.size > 0);
      const paint = () => {
        for (const [el, key] of fields) {
          el.contentEditable = editor.isEditable ? "plaintext-only" : "false";
          el.tabIndex = editor.isEditable ? 0 : -1;
          const raw = current.attrs[key] || "";
          const shown = key === "lead" && document.activeElement !== el ? raw.trim() : raw;
          if (!dirty.has(el) && !composing.has(el) && el.textContent !== shown) el.textContent = shown;
        }
        space.textContent = (current.attrs.lead || "").trim() ? " " : "";
      };
      // No private timer: the canvas must see pending input before a foreign
      // echo or an exit can replace the NodeView. IME drafts remain explicitly
      // pending until composition ends (the same island pattern as callout).
      const commit = el => {
        if (!dirty.has(el) || composing.has(el) || !editor.isEditable || typeof getPos !== "function") return;
        const pos = getPos();
        if (pos == null) return;
        const cur = editor.state.doc.nodeAt(pos);
        if (!cur || cur.type.name !== "note") return;
        const key = fields.get(el);
        const value = el.textContent || null;
        dirty.delete(el);
        markPending();
        if ((cur.attrs[key] || null) === value) return;
        // AttrStep history restores only this field, never an older bpBlock
        // after authoritative carrier metadata has refreshed outside history.
        editor.view.dispatch(editor.state.tr.setNodeAttribute(pos, key, value));
      };
      const onInput = event => { dirty.add(event.currentTarget); markPending(); commit(event.currentTarget); };
      const onStart = event => composing.add(event.currentTarget);
      const onEnd = event => { composing.delete(event.currentTarget); commit(event.currentTarget); };
      const onFocus = () => paint();
      const onBlur = event => { composing.delete(event.currentTarget); commit(event.currentTarget); paint(); };
      const onBeforeInput = event => {
        if (["insertParagraph", "insertLineBreak"].includes(event.inputType)) event.preventDefault();
      };
      const onKey = event => {
        if (event.isComposing) return;
        if ((event.metaKey || event.ctrlKey) && !event.altKey && event.key.toLowerCase() === "a") {
          event.preventDefault();
          const range = document.createRange();
          range.selectNodeContents(event.currentTarget);
          const selection = window.getSelection();
          selection.removeAllRanges();
          selection.addRange(range);
        } else if ((event.metaKey || event.ctrlKey) && !event.altKey && ["z", "y"].includes(event.key.toLowerCase())) {
          event.preventDefault();
          editor.commands[event.shiftKey || event.key.toLowerCase() === "y" ? "redo" : "undo"]();
        } else if (event.key === "Enter") {
          event.preventDefault();
          event.currentTarget.blur();
        }
      };
      const listeners = { input: onInput, focus: onFocus, blur: onBlur,
        compositionstart: onStart, compositionend: onEnd, beforeinput: onBeforeInput, keydown: onKey };
      for (const [el, key] of fields) {
        el.setAttribute("data-test-id", `paper-note-${key}`);
        el.setAttribute("role", "textbox");
        el.setAttribute("aria-label", key === "label" ? "Note label" : "Note lead (optional)");
        el.setAttribute("aria-multiline", "false");
        el.setAttribute("data-placeholder", key === "label" ? "Label" : "Lead (optional)");
        for (const [event, listener] of Object.entries(listeners)) el.addEventListener(event, listener);
      }
      // The empty contentDOM has no hit area after a native lead island. A
      // plain click on its visible remainder must not retain a run-wide selection.
      const onEmptyBodyMouseDown = event => {
        if (!editor.isEditable || event.button !== 0 || event.shiftKey || event.ctrlKey ||
            event.metaKey || event.altKey || event.target !== desc || typeof getPos !== "function") return;
        const pos = getPos();
        if (pos == null) return;
        const cur = editor.state.doc.nodeAt(pos);
        // IME can render a lead before its pending draft reaches node attrs.
        if (!cur || cur.type.name !== "note" || cur.content.size !== 0 || !(lead.textContent || "").trim()) return;
        event.preventDefault();
        editor.chain().setTextSelection(pos + 1).focus().run();
      };
      desc.addEventListener("mousedown", onEmptyBodyMouseDown);
      const flushPending = () => { for (const el of fields.keys()) commit(el); };
      dom.addEventListener("bp-flush-node", flushPending);
      paint();
      return {
        dom,
        contentDOM: body,
        update: updated => {
          if (updated.type.name !== "note") return false;
          current = updated;
          paint();
          return true;
        },
        stopEvent: event => labelHost.contains(event.target) || leadHost.contains(event.target),
        ignoreMutation: mutation => {
          if (mutation.type === "selection") return false;
          return !body.contains(mutation.target);
        },
        destroy: () => {
          for (const el of fields.keys()) {
            for (const [event, listener] of Object.entries(listeners)) el.removeEventListener(event, listener);
          }
          dom.removeEventListener("bp-flush-node", flushPending);
          desc.removeEventListener("mousedown", onEmptyBodyMouseDown);
        },
      };
    };
  },
});
