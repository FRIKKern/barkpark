// expandable-node.js — the `expandable` block (a native toggle) as a canvas CONTAINER.
//
// `{ id, type:"expandable", summary?, open?, blocks:[child, …] }` — the reader renders
// `<details class="bp-expandable"><summary>…</summary><div class="bp-expandable__body">`
// (compose.ex expandable). The server already treats it as a container: nested ids are
// minted, nested patches resolve, and a legacy paper may carry the body under `children`
// instead of `blocks` (patch.ex visible_alias) — the node keeps that key on `bodyKey` so
// the block round-trips byte-identically.
//
// The node is the section container's shape (section-node.js) with the toggle's chrome:
// a contentEditable SUMMARY island writing node.attrs.summary, and the block+ body as the
// contentDOM. In the canvas the details element is always open (an author edits what is
// inside); `open` rides the attrs verbatim for the reader. The content expression is the
// section's (V1 forbid-nesting: a container child rides bpOpaque, never a nested
// container).
//
// DOM-aware (the NodeView builds real DOM) but the Node SCHEMA object loads in plain Node
// (`document` is touched only inside addNodeView).

import { Node, mergeAttributes } from "@tiptap/core";
import { BP_SECTION_CONTENT } from "./section-node.js";

export const BP_EXPANDABLE_NODE_NAME = "bpExpandable";
const BP_TYPE = "expandable";

export const Expandable = Node.create({
  name: BP_EXPANDABLE_NODE_NAME,
  group: "block",
  content: BP_SECTION_CONTENT,
  defining: true,
  isolating: true,

  addAttributes() {
    return {
      bpId: {
        default: null,
        parseHTML: (el) => el.getAttribute("data-bp-id"),
        renderHTML: (attrs) => (attrs.bpId ? { "data-bp-id": attrs.bpId } : {}),
      },
      bpType: {
        default: BP_TYPE,
        parseHTML: (el) => el.getAttribute("data-bp-type") || BP_TYPE,
        renderHTML: (attrs) => ({ "data-bp-type": attrs.bpType || BP_TYPE }),
      },
      // The summary line. Present-only: null/absent round-trips ABSENT (never "").
      summary: {
        default: null,
        parseHTML: (el) => (el.hasAttribute("data-summary") ? el.getAttribute("data-summary") : null),
        renderHTML: (attrs) => (attrs.summary != null ? { "data-summary": attrs.summary } : {}),
      },
      // The reader's initial state; carried verbatim, never edited here.
      open: {
        default: null,
        parseHTML: (el) => (el.hasAttribute("data-open") ? el.getAttribute("data-open") === "true" : null),
        renderHTML: (attrs) => (attrs.open != null ? { "data-open": attrs.open ? "true" : "false" } : {}),
      },
      // Which key the persisted block keeps its body under ("blocks" | "children").
      bodyKey: {
        default: "blocks",
        parseHTML: (el) => el.getAttribute("data-body-key") || "blocks",
        renderHTML: (attrs) => (attrs.bodyKey && attrs.bodyKey !== "blocks" ? { "data-body-key": attrs.bodyKey } : {}),
      },
    };
  },

  parseHTML() {
    return [{ tag: "details[data-bp-type='expandable']" }, { tag: "div[data-bp-type='expandable']" }];
  },

  // Schema-level fallback render: the reader's own markup, open, with the body hole.
  renderHTML({ HTMLAttributes, node }) {
    const summary = node && node.attrs && node.attrs.summary != null ? node.attrs.summary : "";
    return [
      "details",
      mergeAttributes(HTMLAttributes, { "data-bp-type": BP_TYPE, class: "bp-expandable", open: "" }),
      ["summary", { contenteditable: "false" }, summary],
      ["div", { class: "bp-expandable__body", "data-expandable-body": "" }, 0],
    ];
  },

  addNodeView() {
    return ({ node, editor, getPos }) => {
      // Not a <details>/<summary> pair in the canvas: a <summary> owns Space and Enter
      // (they toggle it) and a toggle rebuilds the subtree under the caret, which is
      // exactly what an editable summary cannot afford. The canvas wrapper is a div
      // wearing the reader's classes, always "open", with a decorative marker; the
      // reader still gets its native <details> (compose.ex) from the same block.
      const dom = document.createElement("div");
      dom.className = "bp-expandable bp-canvas-expandable";
      dom.setAttribute("data-bp-type", BP_TYPE);

      // The summary island is an <input>, not a contentEditable: ProseMirror's focus
      // handler snaps the DOM selection back to its own selection ~20ms after anything
      // inside view.dom gains focus, which pulls the caret out of a contentEditable
      // island into the body (the section title has the same exposure); an input's
      // selection is its own, so it keeps the caret (the figure caption precedent).
      const summaryEl = document.createElement("input");
      summaryEl.type = "text";
      summaryEl.className = "bp-expandable__summary";
      summaryEl.placeholder = "Summary";
      summaryEl.spellcheck = false;
      summaryEl.setAttribute("data-test-id", "paper-expandable-summary");
      summaryEl.setAttribute("aria-label", "toggle summary");
      summaryEl.setAttribute("contenteditable", "false");

      const body = document.createElement("div");
      body.className = "bp-expandable__body";

      dom.append(summaryEl, body);

      let syncing = false;
      let focused = false;
      const currentNode = () => {
        if (typeof getPos !== "function") return node;
        const pos = getPos();
        if (pos == null) return node;
        return editor.state.doc.nodeAt(pos) || node;
      };

      const paint = (n) => {
        const summary = n.attrs && n.attrs.summary;
        const shown = summary != null && summary !== "" ? summary : "";
        if (summaryEl.value !== shown) {
          syncing = true;
          summaryEl.value = shown;
          syncing = false;
        }
        summaryEl.readOnly = !editor.isEditable;
        summaryEl.classList.toggle("bp-expandable__summary--empty", shown === "" && !focused);
      };

      // The summary is committed to node.attrs on blur, Enter and bp-flush-node — never
      // while it has focus. A contentEditable island's DOM selection lives inside the
      // editor's DOM, so a transaction dispatched mid-typing (a debounced write, as the
      // figure caption does from an <input>) lets ProseMirror restore ITS selection and
      // pull the caret into the body; the blur repaint would then drop the typed text.
      let dirty = false;
      const commitWrite = () => {
        if (typeof getPos !== "function") return;
        const pos = getPos();
        if (pos == null) return;
        const cur = editor.state.doc.nodeAt(pos);
        if (!cur || cur.type.name !== BP_EXPANDABLE_NODE_NAME) return;
        const raw = summaryEl.value || "";
        const next = raw === "" ? null : raw;
        dirty = false;
        if ((cur.attrs.summary || null) === next) return;
        editor
          .chain()
          .command(({ tr }) => {
            tr.setNodeMarkup(pos, undefined, { ...cur.attrs, summary: next });
            return true;
          })
          .run();
      };
      const onInput = () => {
        if (syncing || !editor.isEditable) return;
        dirty = true;
      };
      const flushWrite = () => {
        if (dirty) commitWrite();
      };
      const onFocus = () => { focused = true; paint(currentNode()); };
      const onBlur = () => {
        focused = false;
        flushWrite();
        paint(currentNode());
      };
      const onKeydown = (e) => {
        if (e.key === "Enter") {
          e.preventDefault();
          summaryEl.blur();
        }
      };
      summaryEl.addEventListener("focus", onFocus);
      summaryEl.addEventListener("blur", onBlur);
      summaryEl.addEventListener("keydown", onKeydown);
      summaryEl.addEventListener("input", onInput);
      dom.addEventListener("bp-flush-node", flushWrite);

      paint(node);

      return {
        dom,
        contentDOM: body,
        update: (updated) => {
          if (updated.type.name !== BP_EXPANDABLE_NODE_NAME) return false;
          paint(updated);
          return true;
        },
        stopEvent: (e) => {
          const t = e && e.target;
          return !!(t && summaryEl.contains(t));
        },
        ignoreMutation: (m) => {
          if (m.type === "selection") return false;
          if (m.type === "attributes" && (m.target === dom || m.target === body)) return true;
          if (summaryEl.contains(m.target)) return true;
          return !body.contains(m.target);
        },
        destroy: () => {
          dom.removeEventListener("bp-flush-node", flushWrite);
          summaryEl.removeEventListener("focus", onFocus);
          summaryEl.removeEventListener("blur", onBlur);
          summaryEl.removeEventListener("keydown", onKeydown);
          summaryEl.removeEventListener("input", onInput);
        },
      };
    };
  },
});
