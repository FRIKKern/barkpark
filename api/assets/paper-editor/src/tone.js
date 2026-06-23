// tone.js — pure, DOM-free tone normalization for callout authoring.
//
// Lives in its own module (NOT index.js) for two reasons: (1) index.js cannot be
// imported in plain Node — its top-level `class extends HTMLElement` +
// `customElements.define` throw `HTMLElement is not defined` — so a tone helper
// living there could never be unit-tested without jsdom; (2) tone is a content
// concern, orthogonal to the slash-menu popup in slash-menu.js. Both index.js
// (the `> [!type]` shorthand detector) and the pure-Node test import it here.
//
// Maps Obsidian-style admonition aliases onto the canonical Barkpark callout
// tones that compose.ex / walk.ex / the web tone-map already understand. The
// canonical set is pass-through; only the aliases (note, warn, error) and a
// bare/unknown token are remapped. Unknown tokens fall back to "info" so a typo
// never produces an undefined tone that the render half can't class.

const CANONICAL = new Set(["info", "success", "warning", "danger", "neutral"]);

const ALIASES = {
  note: "info",
  warn: "warning",
  error: "danger",
};

// normalizeTone(raw) → canonical tone string.
//   note  → info
//   warn  → warning
//   error → danger
//   info | success | warning | danger | neutral → pass-through
//   anything else (incl. "" / non-string) → info
export function normalizeTone(raw) {
  const key = typeof raw === "string" ? raw.toLowerCase() : "";
  if (CANONICAL.has(key)) return key;
  if (Object.prototype.hasOwnProperty.call(ALIASES, key)) return ALIASES[key];
  return "info";
}
