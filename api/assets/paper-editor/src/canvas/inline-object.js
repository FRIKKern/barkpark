// inline-object.js — insert and edit a schema-declared inline object in a field
// canvas (task-85fee859cf3bfef6, slice 3).
//
// An inline object is stored flat inside a paragraph's prose: `{type: name,
// ...fields}` (Sanity's span sibling `{_type, ...fields}`). The field's
// vocabulary declares the kinds under `blocks.inline` as `{name, title, fields}`
// (vocabulary.js inlineObjects). convert.js already loads every typed inline
// node the editor has no UI for as a `bpInlineOpaque` atom and writes it back
// byte-exact (task-a110126ce9111388); this module adds, for DECLARED kinds only:
//
//   * an accessible name on every atom, "<kind title>: <label>", via node
//     decorations (an undeclared or unknown kind uses its type as the title);
//   * Enter on a selected declared atom, or a double-click on it, opens the
//     field dialog;
//   * insertInlineObject — the slash row and the command palette pick a kind,
//     the dialog opens, and Save puts the atom at the caret. Cancel leaves the
//     document untouched;
//   * the dialog itself: one control per declared field, required fields
//     checked before Save, and a field-level reason from the server shown on
//     the field it names (showRefusal).
//
// An undeclared or unknown kind stays an inert atom: shown, selectable,
// deletable as one unit, never editable, never dropped.
//
// The same dialog edits a declared custom OBJECT BLOCK (blocks.of `{name, title,
// fields}`, task-aebfe6c1b3c3f881): the canvas carries it as a bpOpaque block with
// the whole block on `bpBlock`. Inserting one opens the dialog first; Enter or a
// double-click on a selected one edits it; run-convert.js emits a replace-block
// when the carried block changed.

import { Extension } from "@tiptap/core";
import { NodeSelection, Plugin, PluginKey, TextSelection } from "@tiptap/pm/state";
import { Decoration, DecorationSet } from "@tiptap/pm/view";
import { t } from "../i18n.js";
import { inlineOpaqueLabel } from "../marks.js";
import { inlineObjectFor } from "./vocabulary.js";

const ATOM = "bpInlineOpaque";
const BLOCK = "bpOpaque";
const CLASS = "bp-inline-object-dialog";
const decorationsKey = new PluginKey("bpInlineObjectNames");

// "<kind title>: <label>" — the atom's accessible name.
export function inlineObjectAccessibleName(stored, vocab) {
  const type = stored && typeof stored.type === "string" ? stored.type : "";
  const kind = inlineObjectFor(vocab, type);
  const title = kind ? kind.title : type || t("Inline");
  return `${title}: ${inlineOpaqueLabel(stored)}`;
}

// The declared custom object block `name` (blocks.of `{name, title, fields}`), or null.
export function objectBlockFor(vocab, name) {
  if (!vocab || !Array.isArray(vocab.objects)) return null;
  return vocab.objects.find((o) => o.name === name) || null;
}

// An object block's label: its first declared string field that holds text, else
// the readers' inline object rule (text, title, label, name, value, `[type]`).
export function objectBlockLabel(kind, block) {
  for (const f of (kind && kind.fields) || []) {
    const v = f && block ? block[f.name] : undefined;
    if (typeof v === "string" && v.trim() !== "") return v;
  }
  return inlineOpaqueLabel({ type: kind ? kind.name : "", ...block });
}

// A dialog only edits fields it can name.
function editableKind(kind) {
  return kind ? { ...kind, fields: (kind.fields || []).filter((f) => f && typeof f.name === "string" && f.name !== "") } : null;
}

// True when a field declaration requires a value (`validation: {required:true}`,
// or an error-level map in a list).
export function fieldRequired(field) {
  const rules = field && field.validation;
  const maps = Array.isArray(rules) ? rules : rules && typeof rules === "object" ? [rules] : [];
  return maps.some((r) => r && r.required === true && (r.level == null || r.level === "error"));
}

function listOptions(field) {
  const list = field && field.options && Array.isArray(field.options.list) ? field.options.list : null;
  if (!list) return null;
  return list
    .map((o) => (o && typeof o === "object" ? { value: o.value, title: o.title ?? String(o.value) } : { value: o, title: String(o) }))
    .filter((o) => typeof o.value === "string" || typeof o.value === "number");
}

// Which control a field gets. Anything else is shown read-only and kept as stored.
export function controlKind(field) {
  if (listOptions(field)) return "select";
  switch (field && field.type) {
    case "string":
    case "slug":
      return "text";
    case "url":
      return "url";
    case "email":
      return "email";
    case "text":
      return "textarea";
    case "number":
    case "integer":
    case "float":
      return "number";
    case "boolean":
      return "checkbox";
    default:
      return "readonly";
  }
}

// The field a server refusal names, read off its path (`paragraph/content/1/tone:
// must be one of …` → "tone"), or null when it names none of `fields`.
export function refusalField(reason, fields) {
  if (typeof reason !== "string") return null;
  const m = reason.match(/^([^\s:]+): /);
  if (!m) return null;
  const name = m[1].split("/").pop();
  return (fields || []).some((f) => f.name === name) ? name : null;
}

// Every node of `typeName` with its position.
function nodesIn(doc, typeName = ATOM) {
  const out = [];
  doc.descendants((node, pos) => {
    if (node.type.name === typeName) out.push({ node, pos });
  });
  return out;
}

const atomsIn = (doc) => nodesIn(doc, ATOM);

function sameJson(a, b) {
  return JSON.stringify(a) === JSON.stringify(b);
}

// Where the dialog sits: 6px below its anchor, or 6px above it when it would
// run past the viewport's bottom and fits above; then clamped inside the
// viewport with an 8px margin on every side, so Save and Cancel stay on screen.
export function dialogPosition(anchor, size, viewport, margin = 8, gap = 6) {
  const h = size.height || 0;
  const w = size.width || 0;
  let top = anchor.bottom + gap;
  if (top + h > viewport.height - margin && anchor.top - gap - h >= margin) top = anchor.top - gap - h;
  top = Math.min(Math.max(top, margin), Math.max(margin, viewport.height - margin - h));
  const left = Math.min(Math.max(anchor.left, margin), Math.max(margin, viewport.width - margin - w));
  return { top: Math.round(top), left: Math.round(left) };
}

// ── the dialog ─────────────────────────────────────────────────────────────

export class InlineObjectDialog {
  constructor() {
    this._el = null;
    this._onKey = (e) => this._key(e);
  }

  isOpen() {
    return !!(this._el && this._el.isConnected);
  }

  // Open for `kind` ({name, title, fields}) over `stored` (the node's current
  // value, `{type}` for a new one). `onSave(values)` gets the merged node;
  // `onClose()` runs on Save and Cancel alike. `error` = {field?, message}.
  open({ kind, stored, anchorRect, onSave, onClose, error }) {
    this.close(false);
    this._kind = editableKind(kind);
    this._stored = stored && typeof stored === "object" ? stored : { type: kind.name };
    this._onSave = onSave;
    this._onClose = onClose;
    this._build(anchorRect);
    if (error && error.message) this.showError(error.field || null, error.message);
    const first = this._el.querySelector("[data-field]:not([disabled]), button");
    if (first) first.focus();
    return this._el;
  }

  close(notify = true) {
    if (!this._el) return;
    this._el.removeEventListener("keydown", this._onKey);
    this._el.remove();
    this._el = null;
    const done = this._onClose;
    this._onClose = null;
    if (notify && typeof done === "function") done();
  }

  // A field-level reason (a server refusal, or a missing required value).
  showError(fieldName, message) {
    if (!this._el) return;
    const control = fieldName ? this._el.querySelector(`[data-field="${CSS.escape(fieldName)}"]`) : null;
    if (control) {
      const msg = this._el.querySelector(`#${control.getAttribute("aria-describedby")}`);
      if (msg) msg.textContent = message;
      control.setAttribute("aria-invalid", "true");
      control.focus();
      return;
    }
    const general = this._el.querySelector(`.${CLASS}__error`);
    general.textContent = message;
    general.hidden = false;
  }

  _build(anchorRect) {
    const doc = document;
    const el = doc.createElement("div");
    el.className = CLASS;
    el.setAttribute("role", "dialog");
    el.setAttribute("aria-modal", "true");
    const uid = `bp-io-${Math.random().toString(36).slice(2, 8)}`;
    const heading = doc.createElement("h2");
    heading.id = `${uid}-title`;
    heading.className = `${CLASS}__title`;
    heading.textContent = t("Edit %{name}", { name: this._kind.title });
    el.setAttribute("aria-labelledby", heading.id);
    el.append(heading);

    const general = doc.createElement("p");
    general.className = `${CLASS}__error`;
    general.setAttribute("role", "alert");
    general.hidden = true;
    el.append(general);

    const form = doc.createElement("form");
    form.noValidate = true;
    form.addEventListener("submit", (e) => {
      e.preventDefault();
      this._save();
    });
    this._kind.fields.forEach((field, i) => form.append(this._row(field, `${uid}-${i}`)));

    const actions = doc.createElement("div");
    actions.className = `${CLASS}__actions`;
    const cancel = doc.createElement("button");
    cancel.type = "button";
    cancel.className = `${CLASS}__cancel`;
    cancel.textContent = t("Cancel");
    cancel.addEventListener("click", () => this.close());
    const save = doc.createElement("button");
    save.type = "submit";
    save.className = `${CLASS}__save`;
    save.textContent = t("Save");
    actions.append(cancel, save);
    form.append(actions);
    el.append(form);

    // Outside ProseMirror: a mousedown here must not move the editor selection.
    el.addEventListener("mousedown", (e) => {
      if (!(e.target instanceof HTMLInputElement || e.target instanceof HTMLTextAreaElement || e.target instanceof HTMLSelectElement)) e.preventDefault();
    });
    el.addEventListener("keydown", this._onKey);
    doc.body.append(el);
    this._el = el;
    if (anchorRect) {
      // Measured once it is in the document, so it can flip and clamp.
      const box = el.getBoundingClientRect();
      const view = doc.defaultView || window;
      const { top, left } = dialogPosition(
        anchorRect,
        { width: box.width, height: box.height },
        { width: view.innerWidth, height: view.innerHeight },
      );
      el.style.position = "fixed";
      el.style.left = `${left}px`;
      el.style.top = `${top}px`;
    }
  }

  _row(field, id) {
    const doc = document;
    const row = doc.createElement("div");
    row.className = `${CLASS}__row`;
    const label = doc.createElement("label");
    label.htmlFor = id;
    label.textContent = typeof field.title === "string" && field.title !== "" ? field.title : field.name;
    const required = fieldRequired(field);
    if (required) {
      const mark = doc.createElement("span");
      mark.className = `${CLASS}__required`;
      mark.textContent = ` (${t("required")})`;
      label.append(mark);
    }
    const kind = controlKind(field);
    const value = this._stored[field.name];
    let control;
    if (kind === "textarea") {
      control = doc.createElement("textarea");
      control.rows = 3;
      control.value = typeof value === "string" ? value : "";
    } else if (kind === "select") {
      control = doc.createElement("select");
      if (!required) control.append(new Option("", ""));
      for (const o of listOptions(field)) control.append(new Option(o.title, String(o.value)));
      control.value = value == null ? "" : String(value);
    } else if (kind === "checkbox") {
      control = doc.createElement("input");
      control.type = "checkbox";
      control.checked = value === true;
    } else {
      control = doc.createElement("input");
      control.type = kind === "readonly" ? "text" : kind;
      if (kind === "readonly") {
        control.readOnly = true;
        control.value = value === undefined ? "" : JSON.stringify(value);
      } else {
        control.value = value == null ? "" : String(value);
      }
    }
    control.id = id;
    control.dataset.field = field.name;
    control.dataset.kind = kind;
    if (required) control.setAttribute("aria-required", "true");
    const msg = doc.createElement("span");
    msg.id = `${id}-msg`;
    msg.className = `${CLASS}__msg`;
    control.setAttribute("aria-describedby", msg.id);
    control.addEventListener("input", () => {
      control.removeAttribute("aria-invalid");
      msg.textContent = "";
    });
    row.append(label, control, msg);
    return row;
  }

  // The node the form describes: the stored node with each editable field set
  // from its control. Keys the dialog does not edit (an undeclared field, `_key`)
  // ride along untouched; an emptied optional field is removed.
  values() {
    const out = { ...this._stored, type: this._kind.name };
    for (const control of this._el.querySelectorAll("[data-field]")) {
      const name = control.dataset.field;
      const kind = control.dataset.kind;
      if (kind === "readonly") continue;
      if (kind === "checkbox") {
        out[name] = control.checked;
        continue;
      }
      const raw = control.value;
      if (raw === "") {
        delete out[name];
      } else if (kind === "number") {
        const n = Number(raw);
        out[name] = Number.isFinite(n) ? n : raw;
      } else if (kind === "select") {
        const field = this._kind.fields.find((f) => f.name === name);
        const hit = (listOptions(field) || []).find((o) => String(o.value) === raw);
        out[name] = hit ? hit.value : raw;
      } else {
        out[name] = raw;
      }
    }
    return out;
  }

  _save() {
    const values = this.values();
    let firstMissing = null;
    for (const field of this._kind.fields) {
      if (!fieldRequired(field)) continue;
      const v = values[field.name];
      if (v === undefined || v === null || v === "") {
        this.showError(field.name, t("Required"));
        firstMissing = firstMissing || field.name;
      }
    }
    if (firstMissing) {
      this.showError(firstMissing, t("Required"));
      return false;
    }
    const save = this._onSave;
    this.close();
    if (typeof save === "function") save(values);
    return true;
  }

  _key(e) {
    if (e.key === "Escape") {
      e.preventDefault();
      e.stopPropagation();
      this.close();
      return;
    }
    if (e.key !== "Tab") return;
    // Keep focus inside the dialog.
    const focusable = [...this._el.querySelectorAll("input, select, textarea, button")].filter((n) => !n.disabled);
    if (!focusable.length) return;
    const first = focusable[0];
    const last = focusable[focusable.length - 1];
    if (e.shiftKey && document.activeElement === first) {
      e.preventDefault();
      last.focus();
    } else if (!e.shiftKey && document.activeElement === last) {
      e.preventDefault();
      first.focus();
    }
  }
}

// ── editor wiring ──────────────────────────────────────────────────────────

// Open the dialog for the atom at `pos`. Save rewrites its stored node in one
// transaction (one undo step); the caret returns to the atom either way.
export function editInlineObjectAt(host, editor, pos, error) {
  const vocab = host.inlineObjectVocabulary();
  const node = editor.state.doc.nodeAt(pos);
  if (!node || node.type.name !== ATOM) return false;
  const stored = node.attrs.node || {};
  const kind = inlineObjectFor(vocab, stored.type);
  if (!kind) return false;
  const dom = editor.view.nodeDOM(pos);
  const rect = dom && typeof dom.getBoundingClientRect === "function" ? dom.getBoundingClientRect() : null;
  const dialog = host.inlineObjectDialog();
  dialog.open({
    kind,
    stored,
    anchorRect: rect,
    error,
    onSave: (values) => {
      const at = findAtom(editor.state.doc, pos, stored);
      if (at == null) return;
      host.noteInlineObjectSave(values);
      editor.view.dispatch(editor.state.tr.setNodeMarkup(at, undefined, { ...node.attrs, node: values }));
    },
    onClose: () => {
      const at = findAtom(editor.state.doc, pos, null);
      editor.view.focus();
      if (at != null) editor.view.dispatch(editor.state.tr.setSelection(NodeSelection.create(editor.state.doc, at)));
    },
  });
  return true;
}

// The atom near `pos` (holding `stored`, when given) — the doc may have moved
// while the dialog was open.
function findAtom(doc, pos, stored, typeName = ATOM, attr = "node") {
  const here = pos >= 0 && pos < doc.content.size ? doc.nodeAt(pos) : null;
  if (here && here.type.name === typeName && (!stored || sameJson(here.attrs[attr], stored))) return pos;
  const hit = nodesIn(doc, typeName).find((a) => !stored || sameJson(a.node.attrs[attr], stored));
  return hit ? hit.pos : null;
}

// Open the dialog for the declared object block at `pos`. Save rewrites its
// carried block in one transaction; keys the dialog does not own (its id) ride along.
export function editObjectBlockAt(host, editor, pos, error) {
  const node = editor.state.doc.nodeAt(pos);
  if (!node || node.type.name !== BLOCK) return false;
  const kind = objectBlockFor(host.inlineObjectVocabulary(), node.attrs.bpType);
  if (!kind || !editableKind(kind).fields.length) return false;
  const stored = node.attrs.bpBlock || { type: node.attrs.bpType };
  const dom = editor.view.nodeDOM(pos);
  const rect = dom && typeof dom.getBoundingClientRect === "function" ? dom.getBoundingClientRect() : null;
  host.inlineObjectDialog().open({
    kind,
    stored,
    anchorRect: rect,
    error,
    onSave: (values) => {
      const at = findAtom(editor.state.doc, pos, stored, BLOCK, "bpBlock");
      if (at == null) return;
      const live = editor.state.doc.nodeAt(at);
      host.noteInlineObjectSave(values);
      editor.view.dispatch(editor.state.tr.setNodeMarkup(at, undefined, { ...live.attrs, bpBlock: values }));
    },
    onClose: () => {
      const at = findAtom(editor.state.doc, pos, null, BLOCK, "bpBlock");
      editor.view.focus();
      if (at != null) editor.view.dispatch(editor.state.tr.setSelection(NodeSelection.create(editor.state.doc, at)));
    },
  });
  return true;
}

// Inserting a declared object block that has fields: the dialog opens over an
// empty value and Save calls `insert(values)`. False when the kind has no fields
// to ask for (the caller inserts it at once, as before).
export function openObjectBlockInsert(host, editor, name, insert) {
  const kind = objectBlockFor(host.inlineObjectVocabulary(), name);
  if (!kind || !editableKind(kind).fields.length) return false;
  // The caret the pick was made at: focus moving through the dialog must not
  // move where the block lands.
  const at = editor.state.selection.from;
  host.inlineObjectDialog().open({
    kind,
    stored: { type: name },
    anchorRect: safeCoords(editor.view, at),
    onSave: (values) => {
      host.noteInlineObjectSave(values);
      const doc = editor.state.doc;
      editor.view.dispatch(editor.state.tr.setSelection(TextSelection.near(doc.resolve(Math.min(at, doc.content.size)))));
      insert(values);
    },
    onClose: () => editor.view.focus(),
  });
  return true;
}

// Pick a declared kind: the dialog opens over an empty value; Save puts the atom
// at the caret (replacing `replaceRange` first, e.g. the slash "/query" text) and
// leaves the caret after it. Cancel inserts nothing.
export function insertInlineObject(host, editor, name, { replaceRange } = {}) {
  const kind = inlineObjectFor(host.inlineObjectVocabulary(), name);
  const nodeType = editor.state.schema.nodes[ATOM];
  if (!kind || !nodeType) return false;
  if (replaceRange && replaceRange.to > replaceRange.from) {
    editor.view.dispatch(editor.state.tr.delete(replaceRange.from, replaceRange.to));
  }
  const at = editor.state.selection.from;
  const caret = typeof editor.view.coordsAtPos === "function" ? safeCoords(editor.view, at) : null;
  host.inlineObjectDialog().open({
    kind,
    stored: { type: name },
    anchorRect: caret,
    onSave: (values) => {
      host.noteInlineObjectSave(values);
      const pos = Math.min(at, editor.state.doc.content.size);
      const tr = editor.state.tr.insert(pos, nodeType.create({ node: values }));
      tr.setSelection(TextSelection.create(tr.doc, pos + 1));
      editor.view.dispatch(tr);
    },
    onClose: () => editor.view.focus(),
  });
  return true;
}

function safeCoords(view, pos) {
  try {
    const c = view.coordsAtPos(pos);
    return { left: c.left, top: c.top, bottom: c.bottom };
  } catch {
    return null;
  }
}

// The canvas extension: accessible names on atoms, Enter / double-click to edit.
// `host` is the canvas element: inlineObjectVocabulary(), inlineObjectDialog(),
// noteInlineObjectSave(values).
export function inlineObjects(host) {
  return Extension.create({
    name: "bpInlineObjects",
    addKeyboardShortcuts() {
      return {
        Enter: ({ editor }) => {
          const sel = editor.state.selection;
          if (!(sel instanceof NodeSelection) || !host._editable) return false;
          if (sel.node.type.name === ATOM) return editInlineObjectAt(host, editor, sel.from);
          if (sel.node.type.name === BLOCK) return editObjectBlockAt(host, editor, sel.from);
          return false;
        },
      };
    },
    addProseMirrorPlugins() {
      const editor = this.editor;
      return [
        new Plugin({
          key: decorationsKey,
          props: {
            decorations(state) {
              const vocab = host.inlineObjectVocabulary();
              const decos = atomsIn(state.doc).map(({ node, pos }) => {
                const stored = node.attrs.node || {};
                const editable = !!inlineObjectFor(vocab, stored.type);
                return Decoration.node(pos, pos + node.nodeSize, {
                  role: "img",
                  "aria-label": inlineObjectAccessibleName(stored, vocab),
                  "data-inline-editable": editable ? "true" : "false",
                });
              });
              // A declared object block with fields is named "<kind title>: <label>"
              // and marked editable (Enter / double-click opens its dialog).
              for (const { node, pos } of nodesIn(state.doc, BLOCK)) {
                const kind = objectBlockFor(vocab, node.attrs.bpType);
                if (!kind || !editableKind(kind).fields.length) continue;
                decos.push(Decoration.node(pos, pos + node.nodeSize, {
                  role: "group",
                  "aria-label": `${kind.title}: ${objectBlockLabel(kind, node.attrs.bpBlock || {})}`,
                  "data-object-editable": "true",
                }));
              }
              return DecorationSet.create(state.doc, decos);
            },
            handleDoubleClickOn(view, pos, node, nodePos) {
              if (node.type.name !== ATOM || !host._editable) return false;
              return editInlineObjectAt(host, editor, nodePos);
            },
          },
          // The opaque block's node view stops every event before ProseMirror sees
          // it, so its double-click is read off the editor DOM directly.
          view(view) {
            const onDblClick = (e) => {
              const el = e.target && typeof e.target.closest === "function" ? e.target.closest("[data-bp-opaque]") : null;
              if (!el || !host._editable) return;
              const hit = nodesIn(view.state.doc, BLOCK).find(({ pos }) => view.nodeDOM(pos) === el);
              if (hit && editObjectBlockAt(host, editor, hit.pos)) e.preventDefault();
            };
            view.dom.addEventListener("dblclick", onDblClick);
            return { destroy: () => view.dom.removeEventListener("dblclick", onDblClick) };
          },
        }),
      ];
    },
  });
}
