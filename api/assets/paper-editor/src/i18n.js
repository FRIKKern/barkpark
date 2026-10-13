// i18n.js — the paper canvas's words in the viewer's Studio language
// (task-addade22d350314a).
//
// The server stamps `data-strings` (BarkparkWeb.StudioLocale.component_strings
// (:paper_canvas)) on the canvas run's host element: a JSON map keyed by the
// ENGLISH text, the same contract bp-asset-explorer and the pickers read. `t`
// returns the stamped word, else the English unchanged, and fills `%{name}`
// slots from `vars`. A page carries one Studio language, so one module-level
// map serves every canvas on it; each canvas reloads it when it connects.

let strings = {};

// Load the map from the nearest `[data-strings]` ancestor of `el` (the canvas
// run host). No host, or a malformed map, reads English.
export function loadStringsFrom(el) {
  strings = {};
  const host = el && typeof el.closest === "function" ? el.closest("[data-strings]") : null;
  if (!host) return;
  try {
    const parsed = JSON.parse(host.getAttribute("data-strings") || "{}");
    if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) strings = parsed;
  } catch (_e) {
    strings = {};
  }
}

// `text` is the English (and the key); `vars` fill its %{name} slots.
export function t(text, vars) {
  let out = typeof strings[text] === "string" ? strings[text] : text;
  if (vars) {
    out = out.replace(/%\{(\w+)\}/g, (slot, name) =>
      Object.prototype.hasOwnProperty.call(vars, name) ? String(vars[name]) : slot,
    );
  }
  return out;
}

// `t`, escaped for an HTML string (a translation is text, never markup).
export function te(text, vars) {
  return t(text, vars)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}
