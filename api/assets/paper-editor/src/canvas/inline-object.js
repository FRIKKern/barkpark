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
//     the field it names (showRefusal);
//   * a selected atom keeps its place when the author types (Sanity's Portable
//     Text editor drops the keystroke; a NodeSelection would otherwise replace
//     the atom with the letter, task-8c509718bc320d1d), and shows Sanity's bar
//     above it: the kind's title, Edit object (declared kinds) and Remove object.
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
const BAR = "bp-inline-object-bar";
const decorationsKey = new PluginKey("bpInlineObjectNames");
const barKey = new PluginKey("bpInlineObjectBar");

// Sanity's EditIcon and TrashIcon (@sanity/icons), 25×25.
const ICON = (d) => `<svg viewBox="0 0 25 25" width="25" height="25" fill="none" stroke="currentColor" stroke-width="1.2" stroke-linejoin="round" aria-hidden="true"><path d="${d}"/></svg>`;
const EDIT_ICON = ICON("M15 7L18 10M6 19L7 15L17 5L20 8L10 18L6 19Z");
const REMOVE_ICON = ICON("M5 6.5H20M10 6.5V4.5C10 3.94772 10.4477 3.5 11 3.5H14C14.5523 3.5 15 3.94772 15 4.5V6.5M12.5 9V17M15.5 9L15 17M9.5 9L10 17M18.5 6.5L17.571 18.5767C17.5309 19.0977 17.0965 19.5 16.574 19.5H8.42603C7.90349 19.5 7.46905 19.0977 7.42898 18.5767L6.5 6.5H18.5Z");

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

// An object block's at-rest preview (task-65fb83593b2d1c29): the kind title plus
// one field value, "Callout · warning" — the same text on screen and as its
// accessible name, so two blocks of one kind can be told apart. The value is
// the first TEXT field (type `text`) that holds text, else the first other
// field holding a scalar (a select's code, a number, Yes/No); a block whose
// fields are all empty shows the title alone, never a blank chip.
export function objectBlockValue(kind, block) {
  const fields = ((kind && kind.fields) || []).filter((f) => f && typeof f.name === "string");
  const shown = (v) =>
    typeof v === "string" ? v.trim() : typeof v === "number" && Number.isFinite(v) ? String(v) : typeof v === "boolean" ? t(v ? "Yes" : "No") : "";
  const text = fields.find((f) => f.type === "text" && shown(block && block[f.name]) !== "");
  if (text) return shown(block[text.name]);
  for (const f of fields) {
    const v = shown(block && block[f.name]);
    if (v !== "") return v;
  }
  return "";
}

export function objectBlockPreview(kind, block) {
  const value = objectBlockValue(kind, block);
  return value === "" ? kind.title : `${kind.title} · ${value}`;
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
    this.focusFirst();
    return this._el;
  }

  // Focus the first field (or the first button when every field is disabled).
  focusFirst() {
    const first = this._el && this._el.querySelector("[data-field]:not([disabled]), button");
    if (first) first.focus();
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

// The host's own editor for a declared object (editBlockObject, EMBED-CONTRACT):
// the same open/close surface as InlineObjectDialog, so every insert and edit path
// goes through it unchanged. The host gets { type, title, inline, fields, value,
// error } and answers the new value or null. Only the declared fields are taken
// from the answer; type, id and undeclared keys stay as stored. A missing required
// value asks again with that field's error, over what the host answered.
export class HostObjectDialog {
  constructor(hook) {
    this._hook = hook;
    this._ticket = 0;
    this._open = false;
  }

  isOpen() {
    return this._open;
  }

  focusFirst() {}

  open({ kind, stored, onSave, onClose, error, inline = false }) {
    this.close(false);
    const ticket = ++this._ticket;
    this._open = true;
    this._onClose = onClose;
    const k = editableKind(kind);
    const base = stored && typeof stored === "object" ? stored : { type: k.name };
    const ask = async (err, current = base) => {
      let answer = null;
      try {
        answer = await this._hook({
          type: k.name,
          title: k.title || k.name,
          inline: !!inline,
          fields: JSON.parse(JSON.stringify(k.fields)),
          value: JSON.parse(JSON.stringify(current)),
          error: err && err.message ? { field: err.field || null, message: err.message } : null,
        });
      } catch (_e) {
        answer = null;
      }
      if (ticket !== this._ticket || !this._open) return;
      if (!answer || typeof answer !== "object") return this.close();
      const values = { ...base, type: k.name };
      for (const field of k.fields) {
        const v = answer[field.name];
        if (v === undefined || v === null || v === "") delete values[field.name];
        else values[field.name] = v;
      }
      const missing = k.fields.find((f) => fieldRequired(f) && values[f.name] === undefined);
      if (missing) return ask({ field: missing.name, message: t("Required") }, values);
      this.close();
      if (typeof onSave === "function") onSave(values);
    };
    void ask(error);
    return null;
  }

  close(notify = true) {
    if (!this._open) return;
    this._open = false;
    this._ticket++;
    const done = this._onClose;
    this._onClose = null;
    if (notify && typeof done === "function") done();
  }

  showError() {}
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
    inline: true,
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

// True when `node` is a declared object block with fields to edit (its Edit).
export function canEditObjectBlock(host, node) {
  if (!node || node.type.name !== BLOCK) return false;
  const kind = objectBlockFor(host.inlineObjectVocabulary(), node.attrs.bpType);
  return !!(kind && editableKind(kind).fields.length);
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
    inline: true,
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

// ── the selection bar ───────────────────────────────────────────────────────
// Sanity's InlineObjectToolbarPopover: while an atom is the selection in an
// editable canvas, a small bar above it names its kind and offers Edit object
// (a declared kind) and Remove object. Tab from the editor goes to the bar, Tab
// past its last button and Escape come back. Portaled to <body> like the dialog.
export class InlineObjectBar {
  constructor(host, editor) {
    this._host = host;
    this._editor = editor;
    this._el = null;
    this._pos = null;
  }

  get el() {
    return this._el;
  }

  isOpen() {
    return !!(this._el && this._el.style.display !== "none");
  }

  _build() {
    const el = document.createElement("div");
    el.className = BAR;
    el.setAttribute("role", "toolbar");
    el.style.display = "none";
    const title = document.createElement("span");
    title.className = `${BAR}__title`;
    const button = (cls, label, icon, act) => {
      const b = document.createElement("button");
      b.type = "button";
      b.className = `${BAR}__btn ${BAR}__${cls}`;
      b.setAttribute("aria-label", label);
      b.title = label;
      b.innerHTML = icon;
      b.addEventListener("click", act);
      return b;
    };
    const edit = button("edit", t("Edit object"), EDIT_ICON, () => this.edit());
    const remove = button("remove", t("Remove object"), REMOVE_ICON, () => this.remove());
    el.append(title, edit, remove);
    // A press inside the bar must not move the editor's selection.
    el.addEventListener("mousedown", (e) => e.preventDefault());
    el.addEventListener("keydown", (e) => this._key(e));
    this._parts = { title, edit, remove };
    document.body.appendChild(el);
    this._el = el;
  }

  // Show for the selection, or hide when it is not an atom in an editable canvas.
  update() {
    const view = this._editor.view;
    const sel = this._editor.state.selection;
    const atom = sel instanceof NodeSelection && sel.node.type.name === ATOM;
    const inBar = this._el && this._el.contains(document.activeElement);
    const dialogOpen = typeof this._host._objectEditorOpen === "function" && this._host._objectEditorOpen();
    if (!atom || !this._host._editable || dialogOpen || !(view.hasFocus() || inBar)) return this.hide();
    if (!this._el) this._build();
    const stored = sel.node.attrs.node || {};
    const kind = inlineObjectFor(this._host.inlineObjectVocabulary(), stored.type);
    this._pos = sel.from;
    this._parts.title.textContent = kind ? kind.title : stored.type || t("Inline");
    this._parts.edit.style.display = kind && editableKind(kind).fields.length ? "" : "none";
    const dom = view.nodeDOM(sel.from);
    // Portaled to <body>: carry the paper's theme along.
    if (dom && dom.nodeType === 1) {
      const theme = getComputedStyle(dom);
      for (const name of ["--paper-chrome-bg", "--paper-chrome-border", "--paper-ink", "--paper-ink-soft", "--paper-accent", "--paper-font-sans"]) {
        this._el.style.setProperty(name, theme.getPropertyValue(name));
      }
    }
    this._el.style.display = "flex";
    this._place(dom);
  }

  // Centred above the atom, 8px off it; below it when there is no room above.
  _place(dom) {
    const a = dom && typeof dom.getBoundingClientRect === "function" ? dom.getBoundingClientRect() : null;
    if (!a) return;
    const box = this._el.getBoundingClientRect();
    const margin = 8;
    const vw = window.innerWidth || 0;
    let left = Math.round(a.left + a.width / 2 - box.width / 2);
    if (vw) left = Math.min(Math.max(left, margin), Math.max(margin, vw - box.width - margin));
    let top = Math.round(a.top - box.height - 8);
    if (top < margin) top = Math.round(a.bottom + 8);
    this._el.style.left = `${left}px`;
    this._el.style.top = `${top}px`;
  }

  hide() {
    if (this._el) this._el.style.display = "none";
    this._pos = null;
  }

  // Tab from the editor: the bar's first button.
  focusFirst() {
    if (!this.isOpen()) return false;
    const first = [this._parts.edit, this._parts.remove].find((b) => b.style.display !== "none");
    if (!first) return false;
    first.focus();
    return true;
  }

  _key(e) {
    const buttons = [this._parts.edit, this._parts.remove].filter((b) => b.style.display !== "none");
    const back = () => {
      e.preventDefault();
      this._editor.view.focus();
    };
    if (e.key === "Escape") {
      back();
      this.hide();
    } else if (e.key === "Tab" && !e.shiftKey && e.target === buttons[buttons.length - 1]) back();
    else if (e.key === "Tab" && e.shiftKey && e.target === buttons[0]) back();
  }

  edit() {
    const pos = this._pos;
    this.hide();
    if (pos != null) editInlineObjectAt(this._host, this._editor, pos);
  }

  remove() {
    const pos = this._pos;
    this.hide();
    const node = pos == null ? null : this._editor.state.doc.nodeAt(pos);
    if (!node || node.type.name !== ATOM) return;
    const tr = this._editor.state.tr.delete(pos, pos + node.nodeSize);
    tr.setSelection(TextSelection.create(tr.doc, Math.min(pos, tr.doc.content.size)));
    this._editor.view.dispatch(tr);
    this._editor.view.focus();
  }

  destroy() {
    if (this._el) this._el.remove();
    this._el = null;
  }
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
  let bar = null;
  return Extension.create({
    name: "bpInlineObjects",
    // Ahead of input rules: a keystroke on a selected atom never reaches them.
    priority: 1000,
    addKeyboardShortcuts() {
      return {
        Enter: ({ editor }) => {
          const sel = editor.state.selection;
          if (!(sel instanceof NodeSelection) || !host._editable) return false;
          if (sel.node.type.name === ATOM) return editInlineObjectAt(host, editor, sel.from);
          if (sel.node.type.name === BLOCK) return editObjectBlockAt(host, editor, sel.from);
          return false;
        },
        // Sanity's: Tab from a selected atom goes to its bar.
        Tab: () => !!(bar && bar.focusFirst()),
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
                  "aria-label": objectBlockPreview(kind, node.attrs.bpBlock || {}),
                  "data-object-editable": "true",
                }));
              }
              return DecorationSet.create(state.doc, decos);
            },
            handleDoubleClickOn(view, pos, node, nodePos) {
              if (node.type.name !== ATOM || !host._editable) return false;
              return editInlineObjectAt(host, editor, nodePos);
            },
            // Typing on a selected atom keeps it (Sanity drops the keystroke):
            // ProseMirror would replace the NodeSelection with the text.
            handleTextInput(view) {
              const sel = view.state.selection;
              return sel instanceof NodeSelection && sel.node.type.name === ATOM;
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
        new Plugin({
          key: barKey,
          view(view) {
            bar = new InlineObjectBar(host, editor);
            host._inlineObjectBar = bar;
            // Focus leaving for anywhere but the bar hides it; coming back shows it.
            const onFocusOut = (e) => {
              if (!(bar.el && bar.el.contains(e.relatedTarget))) bar.hide();
            };
            const onFocusIn = () => bar.update();
            const onScroll = () => bar.isOpen() && bar.update();
            view.dom.addEventListener("focusout", onFocusOut);
            view.dom.addEventListener("focusin", onFocusIn);
            document.addEventListener("scroll", onScroll, true);
            return {
              update: () => bar.update(),
              destroy: () => {
                view.dom.removeEventListener("focusout", onFocusOut);
                view.dom.removeEventListener("focusin", onFocusIn);
                document.removeEventListener("scroll", onScroll, true);
                bar.destroy();
                if (host._inlineObjectBar === bar) host._inlineObjectBar = null;
                bar = null;
              },
            };
          },
        }),
      ];
    },
  });
}
