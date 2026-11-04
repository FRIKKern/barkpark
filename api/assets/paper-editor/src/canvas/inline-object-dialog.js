import { t } from "../i18n.js";

const CLASS = "bp-inline-object-dialog";

// A dialog only edits fields it can name.
export function editableKind(kind) {
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
