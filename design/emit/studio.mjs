// design/emit/studio.mjs — the Studio root.html.heex surface.
// Part of design/emit.mjs, the W1.2 emitter, moved here with no change in behaviour.
// design/emit.mjs imports this module and re-exports its public names.

import { loadThemes, THEME_BANNER, themeBlocks, tokens } from "./source.mjs";
import { baseVars, hsl, LIFE_ORDER, motionVars, primaryVars, statusVars, TYPE_STEPS } from "./vocab.mjs";

// ── surface: Studio (api/lib/barkpark_web/layouts/root.html.heex inline style) ─
// ADOPTION (W2.7): base roles now cascade to the hand-authored html[data-theme]
// blocks that follow — they no longer redefine --primary/--ring, so the emitted
// evergreen primary is live. Light base + status sit on :root; the DARK base is
// keyed on html[data-theme="dark"] (NOT @media) because Studio themes via a
// data-theme toggle, so the dark base must track the attribute (mirrors
// cloudBlock). Status dark stays under @media (unchanged). Emitted inside a
// <style>, hence CSS comment syntax and an extra 4-space indent to sit in block.
// On-fill status foregrounds (--ok-fg/--warn-fg/--danger-fg/--info-fg) + the
// zinc/chrome ladder (--bg-accent/--border-muted/--fg-dim/--fg-accent). Both are
// Studio-ONLY: no other surface consumes them, so they live here (studioBlock),
// NOT in the shared statusVars/baseVars that every CSS surface emits. Chrome
// values are HSL channels OR a bare var(--role) reference (border-muted light =
// --border; fg-accent dark = --text) — the emitter passes a var() through.
const STATUS_FG = ["ok-fg", "warn-fg", "danger-fg", "info-fg"];
const CHROME_ALIASES = ["bg-accent", "border-muted", "fg-dim", "fg-accent", "surface-raised", "border-subtle"];
const chromeVal = (v) => (v.startsWith("var(") ? v : hsl(v));

function onStatusVars(theme, indent, t = tokens) {
  const os = t.color.onStatus;
  return STATUS_FG.map((r) => indent + `--${r}: ${hsl(os[r][theme])};`).join("\n");
}
// Text-on-tint voices (color.onTint): a status hue as TEXT on its own -soft tint,
// a darker step in light so it clears AA there (task-98bc0a831eecc140). Studio-only
// like onStatus; its dark value rides the same prefers-color-scheme block as the
// status roles it shadows, so --warn-text and --warn always flip together.
const ON_TINT = ["ok-text", "warn-text", "danger-text", "info-text", "primary-text"];
function onTintVars(theme, indent, t = tokens) {
  const ot = t.color.onTint;
  return ON_TINT.map((r) => indent + `--${r}: ${hsl(ot[r][theme])};`).join("\n");
}
function chromeVars(theme, indent, t = tokens) {
  const ch = t.color.studioChrome;
  return CHROME_ALIASES.map((r) => indent + `--${r}: ${chromeVal(ch[r][theme])};`).join("\n");
}

// Chrome type scale → --text-<step> / --text-<step>-lh CSS vars (W2.7 gap close,
// Decision D2). Theme-invariant (size/line-height don't flip), so emitted ONLY in
// :root. The Studio styleguide type ladder renders straight off these vars.
function chromeTypeVars(indent) {
  const t = tokens.type.chrome;
  return TYPE_STEPS
    .map((s) => indent + `--text-${s}: ${t[s].size}px; --text-${s}-lh: ${t[s].lineHeight};`)
    .join("\n");
}

// Lifecycle glyph tones → --life-<state> CSS vars (Decision D1). The Studio MIRROR
// of the one lifecycle source (tokens.lifecycle.*.color) — the exact hues the Go
// board + paper-surface .bp-lg-- classes emit from. Theme-specific: light on
// :root, dark on html[data-theme="dark"]. Lets the styleguide colour a lifecycle
// glyph via var(--life-<state>) (an APPLIED-STYLE var, never a copied hex) and
// participates in the §6 cross-surface parity assertion (design/check.mjs Part B).
function lifeVars(theme, indent) {
  const life = tokens.lifecycle;
  return LIFE_ORDER.map((s) => indent + `--life-${s}: ${life[s].color[theme]};`).join("\n");
}

// Studio theme block: base + primary + status + on-status + chrome under the
// theme attribute (all inside the <style>, so the 4-space block indent). The
// dark scope keys on [data-theme=dark] — Studio always seeds data-theme, so the
// toggle carries status dark too (a superset of the bare @media path). Chrome
// type-scale (theme-invariant px) and --life-* glyph tones (positional
// passthrough, Part B) are excluded (D25).
const studioThemeBlock = (name, t) => {
  const ind = "    ";
  return [
    ind + `html[data-bp-theme="${name}"] {`,
    baseVars("light", ind + "  ", t),
    primaryVars("light", ind + "  ", t),
    statusVars("light", ind + "  ", t),
    onStatusVars("light", ind + "  ", t),
    onTintVars("light", ind + "  ", t),
    chromeVars("light", ind + "  ", t),
    ind + "}",
    ind + `html[data-bp-theme="${name}"][data-theme="dark"] {`,
    baseVars("dark", ind + "  ", t),
    primaryVars("dark", ind + "  ", t),
    statusVars("dark", ind + "  ", t),
    onStatusVars("dark", ind + "  ", t),
    onTintVars("dark", ind + "  ", t),
    chromeVars("dark", ind + "  ", t),
    ind + "}",
  ].join("\n");
};

function studioBlock(themes = loadThemes()) {
  const ind = "    ";
  const lines = [
    ind + ":root {",
    baseVars("light", ind + "  "),
    primaryVars("light", ind + "  "),
    statusVars("light", ind + "  "),
    onStatusVars("light", ind + "  "),
    onTintVars("light", ind + "  "),
    chromeVars("light", ind + "  "),
    chromeTypeVars(ind + "  "),
    motionVars(ind + "  "),
    lifeVars("light", ind + "  "),
    ind + "}",
    ind + 'html[data-theme="dark"] {',
    baseVars("dark", ind + "  "),
    primaryVars("dark", ind + "  "),
    // The status hues follow the explicit theme too (task-9dfa7ee60e6b0589):
    // before, they flipped only on the OS media query, so the theme the user
    // picked set the ground and the OS set the status colours.
    statusVars("dark", ind + "  "),
    onStatusVars("dark", ind + "  "),
    onTintVars("dark", ind + "  "),
    chromeVars("dark", ind + "  "),
    lifeVars("dark", ind + "  "),
    ind + "}",
    ind + "@media (prefers-color-scheme: dark) {",
    ind + "  :root {",
    statusVars("dark", ind + "    "),
    onTintVars("dark", ind + "    "),
    ind + "  }",
    ind + "}",
    // An explicit light theme re-asserts the light status hues, so a dark-mode
    // OS cannot repaint them (paper-surface's four-block shape: bare light,
    // prefers-dark, explicit light, explicit dark). html[data-theme] outranks
    // the media query's :root by specificity.
    ind + 'html[data-theme="light"] {',
    statusVars("light", ind + "  "),
    onTintVars("light", ind + "  "),
    ind + "}",
  ];
  const themed = themeBlocks(themes, studioThemeBlock);
  if (themed) lines.push(ind + THEME_BANNER, themed);
  return lines.join("\n");
}

export { studioBlock };
