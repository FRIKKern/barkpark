// __palette.test.mjs — contrast gate for the Formula-UX ref rainbow.
//
// The point-mode/intellisense design (S4) introduces 8 ref-hue tokens
// (--sheet-ref-0..7) in root.html.heex, one per theme. A hue that fails to
// stand off the sheet background is invisible as a cell outline — the whole
// rainbow's recognition value collapses. This harness reads the SHIPPED heex,
// extracts every ref hex for BOTH themes plus the sheet background (var(--bg),
// authored as hsl()), computes WCAG relative luminance + contrast ratio in
// pure JS, and asserts:
//   • all 8 hues clear 4.5:1 (WCAG 1.4.3 text) against their theme bg — the
//     hues color the 12px formula-bar mirror TEXT, not just cell outlines,
//     so the text bound governs (the charter's 3:1 outline floor follows);
//   • all 8 are pairwise distinct within a theme;
//   • each .sheet-refc-N class index-locks --rc AND color to token N;
//   • the rainbow is disjoint from the LIVE presence palette (followed from
//     presence_state.ex into TokensGen, not a pinned copy that could rot);
//   • .sheet-ghost's token (--fg-muted) is text-legible in both themes.
// Zero dependencies. Fails loudly with the offending token name.
//
// Run: node __palette.test.mjs   (CI globs every __*.test.mjs)

import assert from "node:assert/strict";
import fs from "node:fs";

const SRC = fs.readFileSync(
  new URL("../../lib/barkpark_web/layouts/root.html.heex", import.meta.url),
  "utf8",
);

// ── colour math ─────────────────────────────────────────────────────────────

// sRGB channel [0..1] → linear-light, per WCAG 2.x.
const toLinear = (c) => (c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4);
const relLuminance = ({ r, g, b }) =>
  0.2126 * toLinear(r / 255) + 0.7152 * toLinear(g / 255) + 0.0722 * toLinear(b / 255);
const contrast = (a, b) => {
  const [hi, lo] = [relLuminance(a), relLuminance(b)].sort((x, y) => y - x);
  return (hi + 0.05) / (lo + 0.05);
};

function hexToRgb(hex) {
  const m = /^#([0-9a-f]{6})$/i.exec(hex.trim());
  assert.ok(m, `not a 6-digit hex: ${hex}`);
  const n = parseInt(m[1], 16);
  return { r: (n >> 16) & 255, g: (n >> 8) & 255, b: n & 255 };
}

// hsl(H S% L%) (space- or comma-separated) → rgb 0..255. The sheet background
// (var(--bg)) is authored as hsl(), so the gate parses it honestly rather than
// hard-coding a background hex that could drift from the token.
function hslToRgb(str) {
  const m = /hsl\(\s*([\d.]+)\s*[, ]\s*([\d.]+)%\s*[, ]\s*([\d.]+)%\s*\)/i.exec(str);
  assert.ok(m, `not an hsl() color: ${str}`);
  const h = parseFloat(m[1]) / 360;
  const s = parseFloat(m[2]) / 100;
  const l = parseFloat(m[3]) / 100;
  if (s === 0) {
    const v = Math.round(l * 255);
    return { r: v, g: v, b: v };
  }
  const q = l < 0.5 ? l * (1 + s) : l + s - l * s;
  const p = 2 * l - q;
  const hue = (t) => {
    if (t < 0) t += 1;
    if (t > 1) t -= 1;
    if (t < 1 / 6) return p + (q - p) * 6 * t;
    if (t < 1 / 2) return q;
    if (t < 2 / 3) return p + (q - p) * (2 / 3 - t) * 6;
    return p;
  };
  return {
    r: Math.round(hue(h + 1 / 3) * 255),
    g: Math.round(hue(h) * 255),
    b: Math.round(hue(h - 1 / 3) * 255),
  };
}

// ── extract tokens from the heex ─────────────────────────────────────────────

// Tokens are resolved through the SELECTOR that declares them, never by their
// ordinal position in the file. Ordinal position is not a selector: this file
// used to take the first --bg as dark and the second as light, and when the
// GENERATED token block (design/emit.mjs) landed above the dark block the gate
// silently began scoring the dark hues against the LIGHT background — #5b9dff
// vs white is 2.72:1, which is the only reason this harness ever failed.
// Swapping the two indices back would have re-broken on the next reorder.
//
// Comments are stripped first: a /* … */ banner sits between the closing brace
// of one rule and the selector of the next, so leaving it in makes the selector
// unrecognisable (and its commas fake a selector list).
const CSS = SRC.replace(/\/\*[\s\S]*?\*\//g, " ");
const RULES = [...CSS.matchAll(/([^{}]+)\{([^{}]*)\}/g)].map((m) => ({
  selectors: m[1].trim().split(",").map((s) => s.trim().replace(/\s+/g, " ")),
  body: m[2],
}));

// The dark cascade is every rule naming html[data-theme="dark"] — the generated
// dark block plus the hand-authored `:root, html[data-theme="dark"]` alias
// block. The light cascade is html[data-theme="light"] plus the BARE :root
// rules: :root alone carries the light values, while a `:root,` paired with the
// dark attribute is the attribute-less DARK fallback and must not count light.
function cascade(theme) {
  return RULES.filter(({ selectors }) =>
    theme === "dark"
      ? selectors.includes('html[data-theme="dark"]')
      : selectors.includes('html[data-theme="light"]') ||
        (selectors.length === 1 && selectors[0] === ":root"),
  );
}

// Last declaration in the theme's cascade wins, then a bare var(--alias) is
// followed WITHIN THE SAME THEME — e.g. --fg-muted is authored as
// var(--muted-text) and only the generated per-theme block carries the hsl().
function token(theme, name, seen = new Set()) {
  assert.ok(!seen.has(name), `${theme} --${name}: circular var() chain`);
  seen.add(name);
  const re = new RegExp(`(?:^|[;\\s])--${name}:\\s*([^;]+);`);
  let value = null;
  for (const rule of cascade(theme)) {
    const m = re.exec(rule.body);
    if (m) value = m[1].trim();
  }
  assert.ok(value, `${theme}: no --${name} declaration under a ${theme}-theme selector`);
  const alias = /^var\(\s*--([\w-]+)\s*\)$/.exec(value);
  return alias ? token(theme, alias[1], seen) : value;
}

const bgDarkSrc = token("dark", "bg");
const bgLightSrc = token("light", "bg");
const bgDark = hslToRgb(bgDarkSrc);
const bgLight = hslToRgb(bgLightSrc);
// The tripwire the ordinal read never had: the dark sheet must actually BE
// darker. If the anchors ever drift again this fails by name instead of
// blaming an innocent hue for a background it is never painted on.
assert.ok(
  relLuminance(bgDark) < relLuminance(bgLight),
  `--bg theme anchors are inverted: dark resolved to ${bgDarkSrc}, light to ${bgLightSrc}`,
);

// The ref hues live in two labelled blocks. Split the source at the light
// override so a --sheet-ref-N is attributed to the right theme regardless of
// how many other tokens sit between them.
function extractRefs(block, label) {
  const out = {};
  for (const m of block.matchAll(/--sheet-ref-(\d):\s*(#[0-9a-fA-F]{6})/g)) {
    out[Number(m[1])] = m[2].toLowerCase();
  }
  const keys = Object.keys(out).map(Number).sort((a, b) => a - b);
  assert.deepEqual(
    keys,
    [0, 1, 2, 3, 4, 5, 6, 7],
    `${label}: expected --sheet-ref-0..7, got ${keys.join(",")}`,
  );
  return out;
}

// Dark refs are authored under the ":root," / dark rule; the light overrides
// under html[data-theme="light"] that contains --sheet-ref-0. Anchor each on
// the unique substring immediately preceding its token list.
const darkAnchor = SRC.slice(0, SRC.indexOf("--sheet-ref-0")).lastIndexOf(":root,");
assert.ok(darkAnchor >= 0, "could not locate the dark :root ref block");
const darkBlock = SRC.slice(darkAnchor, SRC.indexOf("}", darkAnchor));
const lightIdx = SRC.indexOf('html[data-theme="light"] {', SRC.indexOf("--sheet-ref-0"));
assert.ok(lightIdx >= 0, "could not locate the light ref block");
const lightBlock = SRC.slice(lightIdx, SRC.indexOf("}", lightIdx));

const darkRefs = extractRefs(darkBlock, "dark");
const lightRefs = extractRefs(lightBlock, "light");

// ── assertions ───────────────────────────────────────────────────────────────

// Text-grade bound: the same hues color the formula-bar mirror text (12px,
// normal weight → WCAG 1.4.3 wants 4.5:1). Strictly stronger than the
// charter's 3:1 outline minimum, so one threshold covers both roles.
const MIN_CONTRAST = 4.5;
let checked = 0;

for (const [theme, refs, bg] of [
  ["dark", darkRefs, bgDark],
  ["light", lightRefs, bgLight],
]) {
  // contrast vs the theme's sheet background
  for (let i = 0; i < 8; i++) {
    const hex = refs[i];
    const ratio = contrast(hexToRgb(hex), bg);
    assert.ok(
      ratio >= MIN_CONTRAST,
      `${theme} --sheet-ref-${i} (${hex}) contrast ${ratio.toFixed(2)}:1 < ${MIN_CONTRAST}:1 vs sheet bg`,
    );
    checked++;
  }
  // pairwise distinct within the theme
  const seen = new Map();
  for (let i = 0; i < 8; i++) {
    const hex = refs[i];
    if (seen.has(hex)) {
      assert.fail(`${theme} --sheet-ref-${i} (${hex}) duplicates --sheet-ref-${seen.get(hex)}`);
    }
    seen.set(hex, i);
  }
}

// Index lock: each .sheet-refc-N must bind BOTH --rc (refbox ring/fill) and
// color (mirror span text) to var(--sheet-ref-N). A drifted index would show
// a B3:B5 outline in one hue and the B3:B5 bar text in another — the exact
// recognition link the rainbow exists to make.
for (let i = 0; i < 8; i++) {
  const re = new RegExp(
    `\\.sheet-refc-${i}\\s*\\{\\s*--rc:\\s*var\\(--sheet-ref-${i}\\);\\s*color:\\s*var\\(--sheet-ref-${i}\\);`,
  );
  assert.ok(re.test(SRC), `.sheet-refc-${i} does not index-lock --rc + color to --sheet-ref-${i}`);
}

// Disjointness: the rainbow must NOT collide with the presence-cursor palette
// — a collaborator cursor must never read as one of your refs. The palette used
// to be a literal `@colors ~w(…)` sigil in presence_state.ex; 9a327b298
// (Unified Aesthetic W2) replaced it with TokensGen.presence_palette(), so
// re-parsing that sigil finds nothing forever. Follow the CALL instead: assert
// presence_state.ex still delegates (an inlined literal must fail loudly here),
// then read the list out of the generator that answers the call.
const PRESENCE_SRC = fs.readFileSync(
  new URL("../../lib/barkpark_web/studio/presence_state.ex", import.meta.url),
  "utf8",
);
assert.ok(
  /@colors\s+TokensGen\.presence_palette\(\)/.test(PRESENCE_SRC),
  "presence_state.ex no longer sources @colors from TokensGen.presence_palette() — re-point this check at whatever now feeds the cursor palette",
);
// tokens_gen.ex is itself emitted from design/tokens.json (color.presence.palette)
// by design/emit.mjs, so this is the value that actually compiles into presence.
const TOKENS_GEN_SRC = fs.readFileSync(
  new URL("../../lib/barkpark_web/studio/tokens_gen.ex", import.meta.url),
  "utf8",
);
const presenceMatch = /def\s+presence_palette,\s*do:\s*~w\(([^)]+)\)/.exec(TOKENS_GEN_SRC);
assert.ok(presenceMatch, "could not find `def presence_palette, do: ~w(...)` in tokens_gen.ex");
const presenceHexes = presenceMatch[1].trim().split(/\s+/).map((h) => h.toLowerCase());
assert.ok(presenceHexes.length >= 4, `presence palette suspiciously small: ${presenceHexes.length}`);
for (const h of presenceHexes) hexToRgb(h); // every entry must be a real hex
const PRESENCE = new Set(presenceHexes);
for (const [theme, refs] of [["dark", darkRefs], ["light", lightRefs]]) {
  for (let i = 0; i < 8; i++) {
    assert.ok(
      !PRESENCE.has(refs[i]),
      `${theme} --sheet-ref-${i} (${refs[i]}) collides with the presence-cursor palette`,
    );
  }
}

// Ghost legibility: .sheet-ghost renders the predicted range the user must
// READ to accept (`B3:B5`), on var(--bg). It must sit on --fg-muted (the
// "secondary but legible" token) and that token must clear 4.5:1 in both
// themes — --fg-dim + opacity bottomed out near 1.6:1 (invisible ghost).
assert.ok(
  /\.sheet-ghost\s*\{[^}]*var\(--fg-muted/.test(SRC),
  ".sheet-ghost no longer uses var(--fg-muted) — re-verify ghost text legibility",
);
// --fg-muted is an ALIAS (var(--muted-text)) in both themes, so it is resolved
// through the same selector-anchored cascade as --bg rather than pattern-matched
// for an hsl() it no longer literally carries.
for (const [theme, bg] of [
  ["dark", bgDark],
  ["light", bgLight],
]) {
  const fgMuted = token(theme, "fg-muted");
  const ratio = contrast(hslToRgb(fgMuted), bg);
  assert.ok(
    ratio >= 4.5,
    `${theme} --fg-muted (${fgMuted}) ghost contrast ${ratio.toFixed(2)}:1 < 4.5:1 vs sheet bg`,
  );
  checked++;
}

console.log(
  `__palette.test.mjs OK — ${checked} contrast checks (>=${MIN_CONTRAST}:1 refs, 4.5:1 ghost), 16 hues distinct, refc index-locked, disjoint from live presence palette`,
);
