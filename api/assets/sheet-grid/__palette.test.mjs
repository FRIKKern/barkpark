// __palette.test.mjs — contrast gate for the Formula-UX ref rainbow.
//
// The point-mode/intellisense design (S4) introduces 8 ref-hue tokens
// (--sheet-ref-0..7) in root.html.heex, one per theme. A hue that fails to
// stand off the sheet background is invisible as a cell outline — the whole
// rainbow's recognition value collapses. This harness reads the SHIPPED heex,
// extracts every ref hex for BOTH themes plus the sheet background (var(--bg),
// authored as hsl()), computes WCAG relative luminance + contrast ratio in
// pure JS, and asserts:
//   • all 8 hues clear 3:1 (WCAG 1.4.11 non-text) against their theme bg;
//   • all 8 are pairwise distinct within a theme.
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

// The two sheet backgrounds are the global --bg tokens: dark is authored first
// (:root / html[data-theme="dark"]), light second (html[data-theme="light"]).
const bgMatches = [...SRC.matchAll(/--bg:\s*(hsl\([^)]*\))/gi)].map((m) => m[1]);
assert.ok(bgMatches.length >= 2, `expected >=2 --bg declarations, found ${bgMatches.length}`);
const bgDark = hslToRgb(bgMatches[0]);
const bgLight = hslToRgb(bgMatches[1]);

// The ref hues live in two labelled blocks. Split the source at the light
// override so a --sheet-ref-N is attributed to the right theme regardless of
// how many other tokens sit between them.
function refBlock(anchorSel) {
  // grab from the anchor selector to the next closing brace of that rule
  const i = SRC.indexOf(anchorSel);
  assert.ok(i >= 0, `could not find ref token block for: ${anchorSel}`);
  const end = SRC.indexOf("}", i);
  return SRC.slice(i, end);
}
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

const MIN_CONTRAST = 3.0;
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

// Sanity: the rainbow must NOT collide with the presence-cursor palette
// (presence_state.ex @colors) — a collaborator cursor must never read as one
// of your refs. Pinned here as hexes since that file is Elixir.
const PRESENCE = new Set(
  ["#3b82f6", "#ef4444", "#10b981", "#f59e0b", "#8b5cf6", "#ec4899", "#06b6d4", "#f97316"].map((h) =>
    h.toLowerCase(),
  ),
);
for (const [theme, refs] of [["dark", darkRefs], ["light", lightRefs]]) {
  for (let i = 0; i < 8; i++) {
    assert.ok(
      !PRESENCE.has(refs[i]),
      `${theme} --sheet-ref-${i} (${refs[i]}) collides with the presence-cursor palette`,
    );
  }
}

console.log(`__palette.test.mjs OK — ${checked} contrast checks (>=${MIN_CONTRAST}:1), 16 hues distinct, disjoint from presence`);
