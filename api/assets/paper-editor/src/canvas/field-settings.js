// field-settings.js — the quiet settings disclosure on a canvas field atom.
//
// The field row edits its label and value in place; its CONFIG (a select's
// options, a number's min / max / step / unit) lives behind a native <details>
// that shows on hover / focus-within, like the diagram's "Edit diagram"
// disclosure (diagram-node.js). Every edit is written through setNodeMarkup on
// the node attrs, so run-convert's field patch carries only the keys that changed.
//
// A config the server would refuse (min > max, a step <= 0, a value the new
// range strands, an empty or repeated option value) stays in its input, marked
// aria-invalid, and is not sent — the same rule the value input follows.

import { toFieldNumber } from "./field-node.js";
import { t } from "../i18n.js";

export const FIELD_SETTINGS_TYPES = new Set(["field-select", "field-number"]);

const NUMBER_SETTINGS = [
  { key: "min", label: "Minimum" },
  { key: "max", label: "Maximum" },
  { key: "step", label: "Step" },
  { key: "unit", label: "Unit" },
];

// The number config a set of raw input strings asks for, or the key it fails on.
// `value` is the field's stored value: a range must still hold it.
export function numberSettingsFrom(raw, value) {
  const next = {};
  for (const key of ["min", "max", "step"]) {
    const text = raw[key] == null ? "" : String(raw[key]).trim();
    const n = toFieldNumber(text);
    if (text !== "" && n == null) return { refused: key };
    next[key] = n;
  }
  const unit = raw.unit == null ? "" : String(raw.unit).trim();
  next.unit = unit === "" ? null : unit;
  if (next.step != null && !(next.step > 0)) return { refused: "step" };
  if (next.min != null && next.max != null && next.min > next.max) return { refused: "range" };
  const v = typeof value === "number" ? value : null;
  if (v != null && next.min != null && v < next.min) return { refused: "min" };
  if (v != null && next.max != null && v > next.max) return { refused: "max" };
  return { config: next };
}

// The selected value once the options change: kept while its option survives,
// carried along when that option's value is renamed in place, and cleared when
// its option is removed, so the field never points at an option it lacks.
export function selectValueAfter(value, before, after) {
  if (value == null || value === "" || after.some((o) => o.value === value)) return {};
  const i = before.findIndex((o) => o.value === value);
  if (i >= 0 && before.length === after.length && !before.some((o) => o.value === after[i].value)) {
    return { value: after[i].value };
  }
  return { value: "" };
}

// The options list a set of {value,label} rows asks for, or the row it fails on.
// A row with neither value nor label is a draft still being typed and is left out.
export function selectOptionsFrom(rows) {
  const seen = new Set();
  const options = [];
  for (let i = 0; i < rows.length; i++) {
    const value = String(rows[i].value ?? "").trim();
    const label = String(rows[i].label ?? "").trim();
    if (value === "" && label === "") continue;
    if (value === "" || seen.has(value)) return { refused: i };
    seen.add(value);
    options.push(label === "" ? { value } : { value, label });
  }
  return { options };
}

function settingInput(labelText, testId) {
  const label = document.createElement("label");
  label.className = "bp-canvas-field-setting";
  const span = document.createElement("span");
  span.textContent = t(labelText);
  const input = document.createElement("input");
  input.className = "bp-canvas-field-setting-input";
  input.setAttribute("data-test-id", testId);
  label.append(span, input);
  return { label, input };
}

function settingButton(text, testId) {
  const button = document.createElement("button");
  button.type = "button";
  button.className = "bp-canvas-field-setting-button";
  button.textContent = text;
  button.setAttribute("data-test-id", testId);
  return button;
}

// Build the disclosure for a field node view. `write(attrs)` saves attrs onto the
// node; `current()` reads the node as it stands now.
export function buildFieldSettings({ fieldType, editor, write, current }) {
  const disclosure = document.createElement("details");
  disclosure.className = "bp-canvas-field-settings";
  disclosure.setAttribute("contenteditable", "false");
  const summary = document.createElement("summary");
  summary.className = "bp-canvas-field-settings-toggle";
  summary.textContent = fieldType === "field-select" ? t("Edit options") : t("Edit number");
  const fields = document.createElement("div");
  fields.className = "bp-canvas-field-settings-fields";
  disclosure.append(summary, fields);

  const busy = () => disclosure.contains(disclosure.ownerDocument.activeElement);
  const invalid = (input, on) => {
    if (on) input.setAttribute("aria-invalid", "true");
    else input.removeAttribute("aria-invalid");
  };

  let paintFields;
  if (fieldType === "field-number") {
    const inputs = {};
    for (const { key, label } of NUMBER_SETTINGS) {
      const field = settingInput(label, "paper-field-setting-" + key);
      field.input.type = key === "unit" ? "text" : "number";
      if (key !== "unit") field.input.step = "any";
      inputs[key] = field.input;
      fields.appendChild(field.label);
    }
    const commit = (event) => {
      const node = current();
      if (!node || !editor.isEditable) return;
      const raw = {};
      for (const key in inputs) raw[key] = inputs[key].value;
      // A number input the browser cannot parse reads as "" — not a cleared bound.
      const bad = ["min", "max", "step"].find((k) => inputs[k].validity && inputs[k].validity.badInput);
      const result = bad ? { refused: bad } : numberSettingsFrom(raw, node.attrs.value);
      for (const key in inputs) invalid(inputs[key], false);
      if (result.refused) {
        const at = inputs[result.refused] || (event && event.target) || inputs.min;
        invalid(at, true);
        return;
      }
      const a = node.attrs;
      const c = result.config;
      if (["min", "max", "step", "unit"].every((k) => (a[k] ?? null) === c[k])) return;
      write(c);
    };
    for (const key in inputs) inputs[key].addEventListener("change", commit);
    paintFields = (node) => {
      for (const key in inputs) {
        const input = inputs[key];
        if (input.getAttribute("aria-invalid") === "true") continue;
        const v = node.attrs[key];
        const str = v == null ? "" : String(v);
        if (input.value !== str && input.ownerDocument.activeElement !== input) input.value = str;
      }
    };
  } else {
    const list = document.createElement("div");
    list.className = "bp-canvas-field-settings-options";
    const add = settingButton(t("Add option"), "paper-field-setting-add-option");
    fields.append(list, add);
    const rowsOf = () =>
      [...list.children].map((row) => ({
        value: row.querySelector("[data-option-part='value']").value,
        label: row.querySelector("[data-option-part='label']").value,
      }));
    const commit = () => {
      const node = current();
      if (!node || !editor.isEditable) return;
      const rows = [...list.children];
      for (const row of rows) invalid(row.querySelector("[data-option-part='value']"), false);
      const result = selectOptionsFrom(rowsOf());
      if (result.refused != null) {
        invalid(rows[result.refused].querySelector("[data-option-part='value']"), true);
        return;
      }
      const before = node.attrs.options || [];
      if (JSON.stringify(result.options) === JSON.stringify(before)) return;
      write({ options: result.options, ...selectValueAfter(node.attrs.value, before, result.options) });
    };
    const renumber = () => {
      [...list.children].forEach((row, i) => {
        const n = i + 1;
        row.querySelector("[data-option-part='value']").setAttribute("aria-label", t("Option %{n} value", { n }));
        row.querySelector("[data-option-part='label']").setAttribute("aria-label", t("Option %{n} label", { n }));
        row.querySelector("button").setAttribute("aria-label", t("Remove option %{n}", { n }));
      });
    };
    const addRow = (opt) => {
      const row = document.createElement("div");
      row.className = "bp-canvas-field-setting bp-canvas-field-setting-option";
      const value = document.createElement("input");
      value.type = "text";
      value.className = "bp-canvas-field-setting-input";
      value.setAttribute("data-option-part", "value");
      value.placeholder = t("value");
      value.value = opt && opt.value != null ? String(opt.value) : "";
      const label = document.createElement("input");
      label.type = "text";
      label.className = "bp-canvas-field-setting-input";
      label.setAttribute("data-option-part", "label");
      label.placeholder = t("label");
      label.value = opt && opt.label != null ? String(opt.label) : "";
      const remove = settingButton(t("Remove"), "paper-field-setting-remove-option");
      remove.addEventListener("click", () => {
        const next = row.nextElementSibling || row.previousElementSibling;
        row.remove();
        renumber();
        commit();
        (next ? next.querySelector("input") : add).focus();
      });
      value.addEventListener("change", commit);
      label.addEventListener("change", commit);
      row.append(value, label, remove);
      list.appendChild(row);
      return row;
    };
    add.addEventListener("click", () => {
      const row = addRow(null);
      renumber();
      row.querySelector("input").focus();
    });
    paintFields = (node) => {
      // Never rebuild the rows under the author's hands; blur repaints.
      if (busy()) return;
      list.replaceChildren();
      for (const opt of Array.isArray(node.attrs.options) ? node.attrs.options : []) addRow(opt);
      renumber();
    };
  }

  // Escape closes the disclosure and hands focus back to its summary.
  const onKey = (e) => {
    if (e.key !== "Escape" || !disclosure.open) return;
    e.preventDefault();
    e.stopPropagation();
    disclosure.open = false;
    summary.focus();
  };
  disclosure.addEventListener("keydown", onKey);

  return {
    dom: disclosure,
    paint(node) {
      disclosure.hidden = !editor.isEditable;
      paintFields(node);
    },
    destroy() {
      disclosure.removeEventListener("keydown", onKey);
    },
  };
}
