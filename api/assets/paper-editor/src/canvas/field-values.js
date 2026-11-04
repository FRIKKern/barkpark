// Pure field value coercion shared by the schema, controls, settings and conversion.

// ── THE COERCION (lifted verbatim from BarkparkFieldBlockBridge) ──────────────
//
// Read the control's value coerced by field type, EXACTLY as the per-block bridge:
//   field-boolean → control.checked  (a BOOLEAN)
//   field-number  → a NUMBER, or null when empty (what blocks.ex stores)
//   everything else → control.value   (a STRING)
// Exported so __smoke.mjs / run-convert.js can assert fidelity against the bridge.
export function coerceFieldValue(fieldType, control) {
  if (fieldType === "field-boolean") return !!(control && control.checked);
  if (fieldType === "field-number") return toFieldNumber(control ? control.value : null);
  return control ? control.value : "";
}

// A field-number value in its stored form: a finite NUMBER, or null for empty or
// unparseable input. A numeric string ("12", "2.5") becomes its number, so a value
// stored as text by an older path reads the same as one stored as a number.
export function toFieldNumber(value) {
  if (typeof value === "number") return Number.isFinite(value) ? value : null;
  if (typeof value !== "string" || value.trim() === "") return null;
  const n = Number(value);
  return Number.isFinite(n) ? n : null;
}

// ── THE PICKER COERCION (lifted verbatim from BarkparkFieldBlockBridge) ───────
//
// The pickers (bp-media-picker / bp-reference-picker) own their own DOM and emit a
// bubbling `bp-change` CustomEvent({detail:{value}}) on selection/clear — a plain
// STRING (a media id/url for image; a doc id for reference). The per-block bridge's
// picker branch (root.html.heex:3677-3683) is pure IDENTITY: push(e.detail.value),
// i.e. {op:"patch-block", id, patch:{value: e.detail.value}}. coercePickerValue LIFTS
// that exact identity so a canvas picker edit persists the SAME `value` the per-block
// path does. A missing detail/value coerces to "" (the empty/cleared value).
// Exported so __smoke.mjs can assert fidelity against the bridge.
export function coercePickerValue(detail) {
  const v = detail && detail.value;
  return v == null ? "" : v;
}
