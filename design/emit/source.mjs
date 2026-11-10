// design/emit/source.mjs — token and theme loading: tokens.json, the status manifest, the theme axis.
// Part of design/emit.mjs, the W1.2 emitter, moved here with no change in behaviour.
// design/emit.mjs imports this module and re-exports its public names.

import { readdirSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { derive } from "../derive.mjs";
const here = dirname(dirname(fileURLToPath(import.meta.url))); // design/

export const repoRoot = join(here, "..");
// ── the w4 seam (charter D22) ────────────────────────────────────────────────
// `rawTokens` is design/tokens.json parsed VERBATIM — the frozen structure and,
// for evergreen, the byte-for-byte characterization mirror. `tokens` (the export
// every builder reads) is that raw tree with its color palette swapped for a
// CLONE overlaid by derive(activeTheme): a clone-and-overlay adapter, never a
// tree built from scratch. structuredClone preserves every leaf verbatim; the
// overlay only re-stamps the 156 theme-varying SLOTS derive() emits (dotted paths
// under color.*), so the non-derived leaves survive untouched — status.warn.strong
// (bool, read below to emit --warn-strong), color._convention, and the 11 D21
// passthrough families derive() deliberately does not resolve. With
// activeTheme=evergreen the overlay is byte-identical to the raw color tree
// (check.mjs Part F proves derive(evergreen) === tokens.json), so NOTHING the
// emitter writes moves. Swapping activeTheme is the multitheme switch (w4b+).
export const rawTokens = JSON.parse(readFileSync(join(here, "tokens.json"), "utf8"));
const activeTheme = JSON.parse(readFileSync(join(here, "themes", "evergreen.json"), "utf8"));

// ── the SECOND source: design/status-manifest.json (the white ladder) ─────────
// tokens.json owns colour/type/motion; the STATUS VOCABULARY (roles, glyphs,
// labels, meanings, and the stored-status→role map) has always lived next door in
// design/status-manifest.json, which the Elixir side reads at COMPILE time and
// the CSS tone block is generated from. The two JS/TS surfaces were the last
// hand-typed copies of it (tlv-bl-js-vocab-generator): a comment, then a
// byte-check, guarded them. They are emitted here instead, so drift is not
// detected — it is impossible.
export const statusManifest = JSON.parse(
  readFileSync(join(here, "status-manifest.json"), "utf8"),
);

// structural deep-equality — used by the seam guard. Compares by shape and
// primitive value (order-independent for objects), so a non-string leaf that
// silently drifted (e.g. status.warn.strong flipping) is caught, not skipped.
function deepEqualColor(a, b, path = "color") {
  if (a === b) return true;
  if (typeof a !== typeof b) throw new Error(`seam guard: type drift at ${path} — ${typeof a} vs ${typeof b}`);
  if (a === null || b === null || typeof a !== "object") {
    if (a !== b) throw new Error(`seam guard: value drift at ${path} — ${JSON.stringify(a)} vs ${JSON.stringify(b)}`);
    return true;
  }
  const ak = Object.keys(a), bk = Object.keys(b);
  if (ak.length !== bk.length) throw new Error(`seam guard: key-count drift at ${path} — ${ak.length} vs ${bk.length}`);
  for (const k of ak) {
    if (!Object.prototype.hasOwnProperty.call(b, k)) throw new Error(`seam guard: missing key at ${path}.${k}`);
    deepEqualColor(a[k], b[k], `${path}.${k}`);
  }
  return true;
}

const adaptedColor = structuredClone(rawTokens.color);
{
  const derived = derive(activeTheme).values;
  for (const [slot, value] of Object.entries(derived)) {
    const keys = slot.split(".");
    let node = adaptedColor;
    for (let i = 0; i < keys.length - 1; i++) node = node[keys[i]];
    node[keys[keys.length - 1]] = value;
  }
  // Seam guard: for evergreen the overlay MUST be byte-identical to the raw color
  // tree INCLUDING non-string leaves (status.warn.strong, color._convention). This
  // is what makes the byte-identity proof total — if a derive(evergreen) slot ever
  // drifts from the shipped byte, fail loudly here rather than silently emit a
  // retinted artifact. Guarded on evergreen because a real alternate theme is
  // SUPPOSED to differ from the raw tree (that is the whole point of w4b).
  if ((activeTheme.name || "evergreen") === "evergreen")
    deepEqualColor(adaptedColor, rawTokens.color);
}
export const tokens = { ...rawTokens, color: adaptedColor };

// ── theme identity axis (theme-system Wave 4 — charter D23/D24) ───────────────
// A THEME is an authored design/themes/<name>.json skin (per-mode {bg,ink,accent}
// + overrides + passthrough); design/derive.mjs expands it into a full palette.
// Every CSS surface renders each theme into its OWN [data-bp-theme=<name>] block
// (a light AND a dark mode scope) INSIDE the generated marker, layered over the
// bare/evergreen declarations that render when no attribute is present (the FOUC-
// free fallback). Theme identity (data-bp-theme) and light/dark mode (data-theme
// / prefers-color-scheme) are two ORTHOGONAL switches.
//
// design/themes/ ships evergreen ONLY; the N-theme path is proven with a fixture
// theme injected in tests (D24). loadThemes() is the default source (the real
// dir); tests pass their own theme list straight to themeBlocks().
export const THEMES_DIR = join(here, "themes");

export function loadThemes() {
  return readdirSync(THEMES_DIR)
    .filter((f) => f.endsWith(".json"))
    .sort()
    .map((f) => {
      const spec = JSON.parse(readFileSync(join(THEMES_DIR, f), "utf8"));
      return { name: spec.name || f.replace(/\.json$/, ""), spec };
    })
    // Default theme FIRST, rest in dir order: every generated enumeration
    // (Go Themes(), Elixir @themes → Tenancy.known_themes → the Studio picker,
    // CSS theme blocks, the showroom) leads with the built-in skin regardless
    // of how theme FILENAMES alphabetize (e.g. ember.json < evergreen.json).
    .sort((a, b) => (b.name === DEFAULT_THEME ? 1 : 0) - (a.name === DEFAULT_THEME ? 1 : 0));
}

// Overlay derive(spec) onto a deep clone of tokens.color → a full tokens-shaped
// palette for one theme. Passthrough families (provider, lifecycle, statusChrome,
// readerInfo, authButton, …) and every non-color token family (type, font) come
// from base tokens UNCHANGED; only the theme-varying SLOTS are swapped. For
// evergreen this equals tokens byte-for-byte (check.mjs Part F proves
// derive(evergreen) === tokens), so the evergreen theme block renders identically
// to the bare fallback — no visual change, only a new attribute hook.
export function themePalette(spec) {
  const t = JSON.parse(JSON.stringify(tokens));
  const { values, slots } = derive(spec);
  for (const slot of slots) {
    const v = values[slot];
    if (v === undefined) continue;
    const parts = slot.split(".");
    let o = t.color;
    for (let i = 0; i < parts.length - 1; i++) o = o[parts[i]];
    o[parts[parts.length - 1]] = v;
  }
  return t;
}

// Render one surface's per-theme [data-bp-theme] blocks. `render(name, palette)`
// returns the block text for a single theme given its derived palette; the
// passthrough families that check.mjs Parts B/D count POSITIONALLY (--life-*,
// --provider-*, .bp-lg--, .bp-inst--) are NEVER re-declared inside these blocks
// (charter D25). Returns "" when no theme is present (older callers stay safe).
export function themeBlocks(themes, render) {
  return themes.map(({ name, spec }) => render(name, themePalette(spec))).join("\n");
}

// A short banner emitted just above the per-theme blocks in each CSS surface, so
// the generated output reads clearly (theme identity vs the evergreen fallback).
const THEME_BANNER =
  "/* ── theme identity (data-bp-theme) — orthogonal to light/dark mode; the bare declarations above are the evergreen fallback (no attribute → renders exactly as today) ── */";

// DEFAULT_THEME is the built-in evergreen skin every Go Resolve(theme) defaults
// to for an unknown/empty id. Emitted as a `DefaultTheme` const in each generated
// package. Adding theme N+1 grows the genTheme* maps — one keyed entry — and the
// Resolve seam already threads it to every consumer (charter D28/D30).
const DEFAULT_THEME = "evergreen";

export { DEFAULT_THEME, THEME_BANNER };
