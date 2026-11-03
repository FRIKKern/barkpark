// note-node.js — the singular note as a reader-shaped canvas content node.
//
// The host supplies the canonical row classes through `bp:block-html`. The
// label is an attr-backed native island, the body remains the real ProseMirror
// contentDOM, and the optional bold lead plus separator are zero-width
// decorations. Thus the resting row has the reader's exact element/text shape
// without wrapping the body or dropping continuous PM selection.

import { Node, mergeAttributes } from "@tiptap/core";
import { Plugin, PluginKey, Selection } from "@tiptap/pm/state";
import { Decoration, DecorationSet } from "@tiptap/pm/view";
import { readerPaintClass } from "./embed-node.js";

export const BP_NOTE_BP_TYPE = "note";
const leadPluginKey = new PluginKey("bp-note-lead");
const editorIds = new WeakMap();
const leadCleanups = new Map();
let editorSequence = 0;

function editorId(editor) {
  if (!editorIds.has(editor)) editorIds.set(editor, ++editorSequence);
  return editorIds.get(editor);
}

function currentNote(editor, getWidgetPos) {
  const at = typeof getWidgetPos === "function" ? getWidgetPos() : null;
  return at == null ? null : { pos: at - 1, node: editor.state.doc.nodeAt(at - 1) };
}

function leadControl(editor, getWidgetPos, shown, key) {
  const el = document.createElement("b");
  el.textContent = shown;
  el.contentEditable = editor.isEditable ? "plaintext-only" : "false";
  el.tabIndex = editor.isEditable ? 0 : -1;
  el.setAttribute("data-test-id", "paper-note-lead");
  let composing = false;
  let dirty = false;
  const commit = () => {
    if (!dirty || composing || !editor.isEditable) return;
    const live = currentNote(editor, getWidgetPos);
    if (!live?.node || live.node.type.name !== BP_NOTE_BP_TYPE) return;
    const value = el.textContent || null;
    dirty = false;
    if ((live.node.attrs.lead || null) !== value)
      editor.view.dispatch(editor.state.tr.setNodeAttribute(live.pos, "lead", value));
  };
  const onInput = () => { dirty = true; commit(); };
  const onFocus = () => {
    el.setAttribute("role", "textbox");
    el.setAttribute("aria-label", "Note lead (optional)");
    el.setAttribute("aria-multiline", "false");
    const live = currentNote(editor, getWidgetPos);
    const raw = live?.node?.attrs?.lead || "";
    if (!dirty && !composing && el.textContent !== raw) el.textContent = raw;
  };
  const onBlur = () => {
    composing = false;
    commit();
    el.removeAttribute("role");
    el.removeAttribute("aria-label");
    el.removeAttribute("aria-multiline");
    const live = currentNote(editor, getWidgetPos);
    const trimmed = String(live?.node?.attrs?.lead || "").trim();
    if (!dirty && el.textContent !== trimmed) el.textContent = trimmed;
  };
  const onStart = () => { composing = true; };
  const onEnd = () => { composing = false; commit(); };
  const onBeforeInput = event => {
    if (["insertParagraph", "insertLineBreak"].includes(event.inputType)) event.preventDefault();
  };
  const onKey = event => {
    if (event.isComposing) return;
    if ((event.metaKey || event.ctrlKey) && !event.altKey && event.key.toLowerCase() === "a") {
      event.preventDefault();
      event.stopPropagation();
      const range = document.createRange();
      range.selectNodeContents(el);
      const selection = window.getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
    } else if ((event.metaKey || event.ctrlKey) && !event.altKey && ["z", "y"].includes(event.key.toLowerCase())) {
      event.preventDefault();
      editor.commands[event.shiftKey || event.key.toLowerCase() === "y" ? "redo" : "undo"]();
      const live = currentNote(editor, getWidgetPos);
      el.textContent = live?.node?.attrs?.lead || "";
    } else if (event.key === "Enter") {
      event.preventDefault();
      el.blur();
    }
  };
  const listeners = {
    input: onInput, focus: onFocus, blur: onBlur, compositionstart: onStart,
    compositionend: onEnd, beforeinput: onBeforeInput, keydown: onKey,
  };
  for (const [type, listener] of Object.entries(listeners)) el.addEventListener(type, listener);
  leadCleanups.set(key, () => {
    for (const [type, listener] of Object.entries(listeners)) el.removeEventListener(type, listener);
  });
  return el;
}

export const Note = Node.create({
  name: BP_NOTE_BP_TYPE,
  group: "block",
  content: "inline*",
  marks: "",
  selectable: true,
  defining: true,

  addAttributes() {
    return {
      bpBlock: { default: null, rendered: false },
      bpId: {
        default: null,
        parseHTML: el => el.getAttribute("data-bp-id"),
        renderHTML: attrs => attrs.bpId ? { "data-bp-id": attrs.bpId } : {},
      },
      bpType: {
        default: BP_NOTE_BP_TYPE,
        parseHTML: el => el.getAttribute("data-bp-type") || BP_NOTE_BP_TYPE,
        renderHTML: attrs => ({ "data-bp-type": attrs.bpType || BP_NOTE_BP_TYPE }),
      },
      label: {
        default: null,
        parseHTML: el => el.hasAttribute("data-label") ? el.getAttribute("data-label") : null,
        renderHTML: attrs => attrs.label != null ? { "data-label": attrs.label } : {},
      },
      lead: {
        default: null,
        parseHTML: el => el.hasAttribute("data-lead") ? el.getAttribute("data-lead") : null,
        renderHTML: attrs => attrs.lead != null ? { "data-lead": attrs.lead } : {},
      },
    };
  },

  parseHTML() {
    return [{ tag: "div[data-bp-type='note']" }];
  },

  renderHTML({ HTMLAttributes }) {
    return [
      "div",
      mergeAttributes(HTMLAttributes, { "data-bp-type": BP_NOTE_BP_TYPE }),
      ["div", { "data-note-body": "" }, 0],
    ];
  },

  addProseMirrorPlugins() {
    const editor = this.editor;
    const owner = editorId(editor);
    return [new Plugin({
      key: leadPluginKey,
      props: {
        handleKeyDown(view, event) {
          if (event.defaultPrevented || event.isComposing || event.shiftKey || event.metaKey || event.ctrlKey || event.altKey) return false;
          if (event.key !== "ArrowLeft" && event.key !== "ArrowRight") return false;
          const { $from, empty } = view.state.selection;
          if (!empty || $from.parent.type.name !== BP_NOTE_BP_TYPE) return false;
          const leavingStart = event.key === "ArrowLeft" && $from.parentOffset === 0;
          const leavingEnd = event.key === "ArrowRight" && $from.parentOffset === $from.parent.content.size;
          if (!leavingStart && !leavingEnd) return false;
          const boundary = leavingStart ? $from.before() : $from.after();
          view.dispatch(view.state.tr.setSelection(Selection.near(view.state.doc.resolve(boundary), leavingStart ? -1 : 1)));
          view.focus();
          return true;
        },
        decorations(state) {
          const decorations = [];
          state.doc.descendants((node, pos) => {
            if (node.type.name !== BP_NOTE_BP_TYPE) return;
            const lead = String(node.attrs.lead || "").trim();
            if (!lead) return;
            const stem = `bp-note:${owner}:${node.attrs.bpId || pos}`;
            let getLeadPos = null;
            const leadKey = `${stem}:lead`;
            decorations.push(Decoration.widget(pos + 1, (view, getPos) => {
              getLeadPos = getPos;
              return leadControl(editor, getPos, lead, leadKey);
            }, {
              side: -2, key: leadKey, raw: true, stopEvent: () => true,
              destroy: () => {
                leadCleanups.get(leadKey)?.();
                leadCleanups.delete(leadKey);
                getLeadPos = null;
              },
            }));
            decorations.push(Decoration.widget(pos + 1, () => {
              const separator = document.createElement("span");
              separator.textContent = " ";
              separator.setAttribute("data-bp-note-separator", "");
              separator.setAttribute("aria-hidden", "true");
              return separator;
            }, {
              side: -1, key: `${stem}:space`,
            }));
          });
          return DecorationSet.create(state.doc, decorations);
        },
      },
    })];
  },

  addNodeView() {
    return ({ node, editor, getPos }) => {
      const dom = document.createElement("div");
      dom.className = "bp-canvas-note";
      dom.setAttribute("data-bp-type", BP_NOTE_BP_TYPE);
      dom.setAttribute("data-bp-fleet-id", node.attrs.bpId || "");
      dom.setAttribute("data-test-id", "paper-canvas-note");

      const body = document.createElement("div");
      body.className = readerPaintClass(editor);
      body.setAttribute("data-bp-fleet-body", "");
      const row = document.createElement("div");
      const label = document.createElement("span");
      label.setAttribute("data-test-id", "paper-note-label");
      const desc = document.createElement("div");
      desc.setAttribute("data-test-id", "paper-note-body");
      row.append(label, desc);
      body.appendChild(row);
      dom.appendChild(body);

      const fallbackLead = document.createElement("input");
      fallbackLead.type = "text";
      fallbackLead.className = "bp-canvas-note-field";
      fallbackLead.setAttribute("data-test-id", "paper-note-lead");
      fallbackLead.setAttribute("aria-label", "Note lead (optional)");
      fallbackLead.setAttribute("role", "textbox");
      fallbackLead.setAttribute("contenteditable", "false");
      dom.appendChild(fallbackLead);

      let current = node;
      let labelDirty = false;
      let labelComposing = false;
      let fallbackComposing = false;
      const liveNode = () => {
        if (typeof getPos !== "function") return current;
        const pos = getPos();
        return pos == null ? current : editor.state.doc.nodeAt(pos) || current;
      };
      const setAttr = (key, value) => {
        if (!editor.isEditable || typeof getPos !== "function") return;
        const pos = getPos();
        const live = pos == null ? null : editor.state.doc.nodeAt(pos);
        if (!live || live.type.name !== BP_NOTE_BP_TYPE || (live.attrs[key] || null) === value) return;
        editor.view.dispatch(editor.state.tr.setNodeAttribute(pos, key, value));
      };
      const markPending = value => dom.toggleAttribute("data-note-pending", value);
      const commitLabel = () => {
        if (!labelDirty || labelComposing) return;
        labelDirty = false;
        markPending(false);
        setAttr("label", label.textContent || null);
      };
      const commitFallback = () => {
        if (fallbackComposing) return;
        markPending(false);
        setAttr("lead", fallbackLead.value || null);
      };
      const sync = () => {
        const live = liveNode();
        const attrs = live.attrs || {};
        label.contentEditable = editor.isEditable ? "plaintext-only" : "false";
        label.tabIndex = editor.isEditable ? 0 : -1;
        if (!labelDirty && !labelComposing && label.textContent !== (attrs.label || ""))
          label.textContent = attrs.label || "";
        const lead = desc.querySelector(":scope > b");
        if (lead && document.activeElement !== lead && lead.textContent !== String(attrs.lead || "").trim())
          lead.textContent = String(attrs.lead || "").trim();
        fallbackLead.hidden = !!String(attrs.lead || "").trim();
        fallbackLead.readOnly = !editor.isEditable;
        if (document.activeElement !== fallbackLead && !fallbackComposing && fallbackLead.value !== (attrs.lead || ""))
          fallbackLead.value = attrs.lead || "";
      };

      const onLabelInput = () => { labelDirty = true; markPending(true); commitLabel(); };
      const onLabelStart = () => { labelComposing = true; markPending(true); };
      const onLabelEnd = () => { labelComposing = false; commitLabel(); };
      const onLabelFocus = () => {
        label.setAttribute("role", "textbox");
        label.setAttribute("aria-label", "Note label");
        label.setAttribute("aria-multiline", "false");
      };
      const onLabelBlur = () => {
        labelComposing = false;
        commitLabel();
        label.removeAttribute("role");
        label.removeAttribute("aria-label");
        label.removeAttribute("aria-multiline");
        sync();
      };
      const onLabelBeforeInput = event => {
        if (["insertParagraph", "insertLineBreak"].includes(event.inputType)) event.preventDefault();
      };
      const onLabelKey = event => {
        if (event.isComposing) return;
        if ((event.metaKey || event.ctrlKey) && !event.altKey && event.key.toLowerCase() === "a") {
          event.preventDefault();
          event.stopPropagation();
          const range = document.createRange();
          range.selectNodeContents(label);
          const selection = window.getSelection();
          selection.removeAllRanges();
          selection.addRange(range);
        } else if ((event.metaKey || event.ctrlKey) && !event.altKey && ["z", "y"].includes(event.key.toLowerCase())) {
          event.preventDefault();
          editor.commands[event.shiftKey || event.key.toLowerCase() === "y" ? "redo" : "undo"]();
        } else if (event.key === "Enter") {
          event.preventDefault();
          label.blur();
        }
      };
      const onFallbackInput = () => { markPending(true); commitFallback(); };
      const onFallbackStart = () => { fallbackComposing = true; markPending(true); };
      const onFallbackEnd = () => { fallbackComposing = false; commitFallback(); };
      const onFallbackKey = event => {
        if (event.isComposing) return;
        if (event.key === "Enter") {
          event.preventDefault();
          fallbackLead.blur();
        } else if ((event.metaKey || event.ctrlKey) && !event.altKey && ["z", "y"].includes(event.key.toLowerCase())) {
          event.preventDefault();
          editor.commands[event.shiftKey || event.key.toLowerCase() === "y" ? "redo" : "undo"]();
        }
      };
      const onPaint = event => {
        event.preventDefault();
        const template = document.createElement("template");
        template.innerHTML = typeof event.detail?.html === "string" ? event.detail.html : "";
        const painted = template.content.firstElementChild;
        const paintedLabel = painted?.children?.[0];
        const paintedDesc = painted?.children?.[1];
        if (painted && paintedLabel?.tagName === "SPAN" && paintedDesc?.tagName === "DIV") {
          row.className = painted.className;
          label.className = paintedLabel.className;
          desc.className = paintedDesc.className;
        }
        sync();
      };
      const flushPending = () => {
        commitLabel();
        if (document.activeElement === fallbackLead) commitFallback();
      };

      label.addEventListener("input", onLabelInput);
      label.addEventListener("focus", onLabelFocus);
      label.addEventListener("compositionstart", onLabelStart);
      label.addEventListener("compositionend", onLabelEnd);
      label.addEventListener("blur", onLabelBlur);
      label.addEventListener("beforeinput", onLabelBeforeInput);
      label.addEventListener("keydown", onLabelKey);
      fallbackLead.addEventListener("input", onFallbackInput);
      fallbackLead.addEventListener("compositionstart", onFallbackStart);
      fallbackLead.addEventListener("compositionend", onFallbackEnd);
      fallbackLead.addEventListener("keydown", onFallbackKey);
      body.addEventListener("bp-fleet-paint", onPaint);
      dom.addEventListener("bp-flush-node", flushPending);
      sync();

      return {
        dom,
        contentDOM: desc,
        update: updated => {
          if (updated.type.name !== BP_NOTE_BP_TYPE) return false;
          current = updated;
          dom.setAttribute("data-bp-fleet-id", updated.attrs.bpId || "");
          sync();
          queueMicrotask(sync);
          return true;
        },
        stopEvent: event => label.contains(event.target) || fallbackLead.contains(event.target),
        ignoreMutation: mutation => {
          if (mutation.type === "selection") return document.activeElement === label || document.activeElement === fallbackLead;
          if (mutation.type === "attributes" && (mutation.target === row || mutation.target === desc)) return true;
          if (label.contains(mutation.target) || fallbackLead.contains(mutation.target)) return true;
          return !desc.contains(mutation.target);
        },
        destroy: () => {
          label.removeEventListener("input", onLabelInput);
          label.removeEventListener("focus", onLabelFocus);
          label.removeEventListener("compositionstart", onLabelStart);
          label.removeEventListener("compositionend", onLabelEnd);
          label.removeEventListener("blur", onLabelBlur);
          label.removeEventListener("beforeinput", onLabelBeforeInput);
          label.removeEventListener("keydown", onLabelKey);
          fallbackLead.removeEventListener("input", onFallbackInput);
          fallbackLead.removeEventListener("compositionstart", onFallbackStart);
          fallbackLead.removeEventListener("compositionend", onFallbackEnd);
          fallbackLead.removeEventListener("keydown", onFallbackKey);
          body.removeEventListener("bp-fleet-paint", onPaint);
          dom.removeEventListener("bp-flush-node", flushPending);
        },
      };
    };
  },
});
