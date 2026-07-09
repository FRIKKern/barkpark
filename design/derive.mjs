// design/derive.mjs — the theme-system Wave-2 compiler CORE (theme-system D12/D14).
//
// Zero-dependency (Node built-ins only), PURE and DETERMINISTIC OKLCH colour
// math + Barkpark-format serializers. Author ~3 colours per mode ({bg, ink,
// accent}) → a flat slot map of derived theme colours: a hue-tinted neutral
// ladder, an accent ramp, a contrast-aware on-accent foreground, an 8<16<22<55
// chrome ladder, OKLCH hue-locked status roles with AA lightness-walking, and a
// hue-preserved dark inversion capability.
//
// This is the CORE only (theme-system ts-w3-derive-compiler): it creates no
// design/themes/*.json file and does not touch check.mjs / emit.mjs. The
// exported helpers + `derive()` are the contract ts-w3b (evergreen
// characterization + check.mjs Part F) consumes; the D12 w4 seam is "swap the
// emitted `tokens` singleton for derive()'s output".
//
// COLOUR MATH PROVENANCE. The Ottosson sRGB↔OKLab matrices, the sRGB gamma
// transfer, the WCAG contrast ratio, the 24-step gamut chroma bisection and the
// AA lightness-walk SHAPE are transplanted verbatim (values byte-identical) from
// frick's zero-dep compiler:
//   frick-monorepo/packages/styles/scripts/compile-palettes.ts
//     gamma transfer ............... :189-192
//     sRGB→OKLab / OKLab→sRGB ...... :226-254
//     24-step gamut chroma bisect .. :276-302
//     WCAG contrast ................ :331-340
//     AA lightness-walk shape ...... :458-491
// Two capabilities are NEW Barkpark code (neither source implements them; see
// theme-system D15/D16): the AA-walk residual assertion + miss reporting (the
// frick walk is bound-terminated, NOT proven-convergent) and the contrast-aware
// on-accent flip (frick passes accentForeground??bg through; paw hardcodes one
// warm white — Barkpark PICKS warm-white vs near-ink by whichever clears AA on
// the accent).

// ─────────────────────────────────────────────────────────────────────────────
// 1. sRGB gamma transfer (frick compile-palettes.ts:189-192, verbatim).
// ─────────────────────────────────────────────────────────────────────────────
const toLin = (c) =>
  c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
const toSrgbChannel = (c) =>
  c <= 0.0031308 ? 12.92 * c : 1.055 * Math.pow(c, 1 / 2.4) - 0.055;

// ─────────────────────────────────────────────────────────────────────────────
// 2. sRGB ↔ OKLab (Ottosson matrices — frick :226-254, verbatim coefficients).
//    Inputs/outputs are sRGB channels in 0..1 (gamma-encoded) and OKLab.
// ─────────────────────────────────────────────────────────────────────────────
function srgbToOklab([r, g, b]) {
  const lr = toLin(r),
    lg = toLin(g),
    lb = toLin(b);
  const l = 0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb;
  const m = 0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb;
  const s = 0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb;
  const l_ = Math.cbrt(l),
    m_ = Math.cbrt(m),
    s_ = Math.cbrt(s);
  return [
    0.2104542553 * l_ + 0.793617785 * m_ - 0.0040720468 * s_,
    1.9779984951 * l_ - 2.428592205 * m_ + 0.4505937099 * s_,
    0.0259040371 * l_ + 0.7827717662 * m_ - 0.808675766 * s_,
  ];
}
function oklabToSrgb([L, a, b]) {
  const l_ = L + 0.3963377774 * a + 0.2158037573 * b;
  const m_ = L - 0.1055613458 * a - 0.0638541728 * b;
  const s_ = L - 0.0894841775 * a - 1.291485548 * b;
  const l = l_ ** 3,
    m = m_ ** 3,
    s = s_ ** 3;
  return [
    toSrgbChannel(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
    toSrgbChannel(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
    toSrgbChannel(-0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s),
  ];
}

// ─────────────────────────────────────────────────────────────────────────────
// 3. Parsing — Barkpark's authoring formats → sRGB 0..1.
//    Accepts: HSL triplet "H S% L%" (tokens.json form), hsl()/hsla(), #hex 3|6,
//    rgb()/rgba(). `var(...)` is NOT a colour — callers pass it through untouched
//    (see passthrough()); parseColor throws on it so a mis-route is loud.
// ─────────────────────────────────────────────────────────────────────────────
function hslChannelsToRgb(h, s, l) {
  s /= 100;
  l /= 100;
  const c = (1 - Math.abs(2 * l - 1)) * s;
  const hp = ((((h % 360) + 360) % 360) / 60);
  const x = c * (1 - Math.abs((hp % 2) - 1));
  let r = 0,
    g = 0,
    b = 0;
  if (hp < 1) [r, g, b] = [c, x, 0];
  else if (hp < 2) [r, g, b] = [x, c, 0];
  else if (hp < 3) [r, g, b] = [0, c, x];
  else if (hp < 4) [r, g, b] = [0, x, c];
  else if (hp < 5) [r, g, b] = [x, 0, c];
  else [r, g, b] = [c, 0, x];
  const m = l - c / 2;
  return [r + m, g + m, b + m];
}

/** Parse a bare CSS colour to sRGB 0..1. Throws on an unrecognised / var() raw. */
export function parseColor(raw) {
  if (Array.isArray(raw)) return raw.slice(0, 3);
  const v = String(raw).trim().toLowerCase();
  // "H S% L%" bare triplet (the tokens.json colour form) — no wrapper.
  let m = v.match(/^([\d.]+)\s+([\d.]+)%\s+([\d.]+)%$/);
  if (m) return hslChannelsToRgb(+m[1], +m[2], +m[3]);
  // hsl(H S% L%) / hsl(H, S%, L%) / hsla(...)
  m = v.match(/^hsla?\(\s*([\d.]+)\s*,?\s*([\d.]+)%\s*,?\s*([\d.]+)%/);
  if (m) return hslChannelsToRgb(+m[1], +m[2], +m[3]);
  // #rgb
  m = v.match(/^#([0-9a-f]{3})$/);
  if (m) return m[1].split("").map((c) => parseInt(c + c, 16) / 255);
  // #rrggbb
  m = v.match(/^#([0-9a-f]{6})$/);
  if (m) return [0, 2, 4].map((i) => parseInt(m[1].slice(i, i + 2), 16) / 255);
  // rgb()/rgba()
  m = v.match(/^rgba?\(\s*([\d.]+)\s*,?\s*([\d.]+)\s*,?\s*([\d.]+)/);
  if (m) return [+m[1], +m[2], +m[3]].map((c) => c / 255);
  throw new Error(`[derive] cannot parse colour: "${raw}"`);
}

const isVar = (v) => typeof v === "string" && v.trim().startsWith("var(");
/** Slot values that are `var(--role)` passthroughs stay literal (D21/D13). */
export function passthrough(v) {
  return isVar(v) ? v.trim() : v;
}

// ─────────────────────────────────────────────────────────────────────────────
// 4. OKLCH conversions + gamut clamping (frick :264-302, verbatim shape).
// ─────────────────────────────────────────────────────────────────────────────
const clamp01 = ([r, g, b]) =>
  [r, g, b].map((c) => Math.min(1, Math.max(0, c)));

const inGamut = ([r, g, b]) => {
  const e = 1e-4;
  return r >= -e && r <= 1 + e && g >= -e && g <= 1 + e && b >= -e && b <= 1 + e;
};

function oklchToRgbRaw(L, C, h) {
  const r = (h * Math.PI) / 180;
  return oklabToSrgb([L, C * Math.cos(r), C * Math.sin(r)]);
}

/** OKLCH → sRGB 0..1, reducing chroma by 24-step bisection until in gamut at
 *  (L,h) (frick :276-302). Returns a clamped, guaranteed-in-gamut colour. */
export function oklchToSrgb(L, C, h) {
  const rgb = oklchToRgbRaw(L, C, h);
  if (inGamut(rgb)) return clamp01(rgb);
  let lo = 0,
    hi = C;
  for (let i = 0; i < 24; i++) {
    const mid = (lo + hi) / 2;
    if (inGamut(oklchToRgbRaw(L, mid, h))) lo = mid;
    else hi = mid;
  }
  return clamp01(oklchToRgbRaw(L, lo, h));
}

/** sRGB (string or [r,g,b]) → OKLCH { L, C, h° }. */
export function srgbToOklch(raw) {
  const [L, a, b] = srgbToOklab(parseColor(raw));
  const C = Math.hypot(a, b);
  let h = (Math.atan2(b, a) * 180) / Math.PI;
  if (h < 0) h += 360;
  return { L, C, h };
}

/** Max in-gamut chroma at (L,h) — 24-step bisection up to 0.5 (frick :293-302). */
export function maxChroma(L, h) {
  let lo = 0,
    hi = 0.5;
  for (let i = 0; i < 24; i++) {
    const mid = (lo + hi) / 2;
    if (inGamut(oklchToRgbRaw(L, mid, h))) lo = mid;
    else hi = mid;
  }
  return lo;
}

// ─────────────────────────────────────────────────────────────────────────────
// 5. WCAG contrast (frick :331-340, verbatim).
// ─────────────────────────────────────────────────────────────────────────────
function relLum([r, g, b]) {
  const a = [r, g, b].map(toLin);
  return 0.2126 * a[0] + 0.7152 * a[1] + 0.0722 * a[2];
}
/** WCAG 2.x contrast ratio between two colours (strings or [r,g,b]). 1..21. */
export function contrast(fg, bg) {
  const l1 = relLum(parseColor(fg)),
    l2 = relLum(parseColor(bg));
  const [hi, lo] = l1 >= l2 ? [l1, l2] : [l2, l1];
  return (hi + 0.05) / (lo + 0.05);
}

// ─────────────────────────────────────────────────────────────────────────────
// 6. AA lightness-walk (frick :458-491 shape) + residual assertion (D15).
//    The frick walk terminates on threshold OR a fixed iteration cap OR a
//    lightness bound — it is NOT proven-convergent. So `aaWalk` returns `hit`
//    (did the residual clear `target`?) and the achieved `contrast`; a caller
//    that ignores `hit` and ships the colour anyway is the bug D15 warns about.
//    `derive()` collects every miss into a non-enumerable `misses` list.
// ─────────────────────────────────────────────────────────────────────────────
/**
 * Walk OKLCH lightness away from `bg` at fixed chroma+hue until contrast ≥
 * `target`, then stop. Deterministic (fixed start / step / caps).
 *
 * @returns {{rgb:number[], L:number, C:number, h:number, contrast:number,
 *            hit:boolean, iters:number, target:number}}
 */
export function aaWalk(startL, C, h, bg, opts = {}) {
  const {
    target = 4.5,
    step = -0.02,
    maxIter = 48,
    minL = 0.04,
    maxL = 0.98,
  } = opts;
  const bgRgb = parseColor(bg);
  let L = Math.min(maxL, Math.max(minL, startL));
  let rgb = oklchToSrgb(L, C, h);
  let iters = 0;
  for (let i = 0; i < maxIter && contrast(rgb, bgRgb) < target; i++) {
    iters = i + 1;
    L = Math.min(maxL, Math.max(minL, L + step));
    rgb = oklchToSrgb(L, C, h);
    if (L <= minL || L >= maxL) break;
  }
  const achieved = contrast(rgb, bgRgb);
  return {
    rgb,
    L,
    C,
    h,
    contrast: achieved,
    hit: achieved >= target - 1e-9,
    iters,
    target,
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// 7. On-accent flip (theme-system D16 — NEW code, neither source implements it).
//    Pick the on-accent foreground (warm off-white vs near-ink) by whichever
//    clears AA on the accent; if both clear, take the higher contrast; if
//    neither clears (a mid-L accent), still return the higher-contrast option
//    but flag it so a caller can pin an override (D13).
// ─────────────────────────────────────────────────────────────────────────────
const WARM_WHITE = "#fbfaf6"; // paw's warm paper white
const NEAR_INK = "#15211d"; // the paper ink (near-black, green-tinted)

/** @returns {{ color:string, contrast:number, clears:boolean, pick:"warm-white"|"near-ink" }} */
export function onAccent(accent, opts = {}) {
  const { warmWhite = WARM_WHITE, nearInk = NEAR_INK, target = 4.5 } = opts;
  const cw = contrast(warmWhite, accent);
  const ci = contrast(nearInk, accent);
  const wWins = cw >= ci;
  const color = wWins ? warmWhite : nearInk;
  const c = wWins ? cw : ci;
  return {
    color,
    contrast: c,
    clears: c >= target - 1e-9,
    pick: wWins ? "warm-white" : "near-ink",
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// 8. color-mix pre-resolution (the chrome-ladder capability, theme-system D14v).
//    `color-mix(in srgb, A p%, B)` mixes GAMMA-ENCODED sRGB channels; `in oklch`
//    mixes OKLCH (L,C linear, hue along the shortest arc). We RESOLVE the mix at
//    compile time to a concrete colour so the shipped byte is a literal, not a
//    runtime color-mix() the emit target may not support.
// ─────────────────────────────────────────────────────────────────────────────
/** color-mix(in srgb, A `pctA`%, B) → sRGB [r,g,b]. */
export function mixSrgb(a, b, pctA) {
  const ra = parseColor(a),
    rb = parseColor(b);
  const t = pctA / 100;
  return clamp01(ra.map((c, i) => c * t + rb[i] * (1 - t)));
}
/** color-mix(in oklch, A `pctA`%, B) → sRGB [r,g,b] (hue: shortest arc). */
export function mixOklch(a, b, pctA) {
  const A = srgbToOklch(a),
    B = srgbToOklch(b);
  const t = pctA / 100;
  const dh = ((B.h - A.h + 540) % 360) - 180; // shortest signed arc
  const h = A.h + dh * (1 - t);
  const L = A.L * t + B.L * (1 - t);
  const C = A.C * t + B.C * (1 - t);
  return oklchToSrgb(L, C, ((h % 360) + 360) % 360);
}

// ─────────────────────────────────────────────────────────────────────────────
// 9. Serializers — hit tokens.json byte formats exactly (theme-system w3):
//    HSL triplet "H S% L%" (no wrapper), lowercase #hex, rgba(r, g, b, a.aa),
//    and literal var() passthrough.
// ─────────────────────────────────────────────────────────────────────────────
const chan255 = (c) => Math.round(Math.min(1, Math.max(0, c)) * 255);
/** Trim a number to ≤2 decimals, dropping trailing zeros (46.00→"46", 3.90→"3.9"). */
const num = (x) => String(Math.round(x * 100) / 100);

/** sRGB [r,g,b] → lowercase "#rrggbb". */
export function toHex(rgb) {
  return (
    "#" +
    rgb
      .slice(0, 3)
      .map((c) => chan255(c).toString(16).padStart(2, "0"))
      .join("")
  );
}

/** sRGB [r,g,b] → "H S% L%" (tokens.json colour form — no hsl() wrapper). */
export function toHslTriplet(rgb) {
  const [r, g, b] = rgb.slice(0, 3).map((c) => Math.min(1, Math.max(0, c)));
  const max = Math.max(r, g, b),
    min = Math.min(r, g, b);
  const l = (max + min) / 2;
  let h = 0,
    s = 0;
  const d = max - min;
  if (d > 1e-9) {
    s = d / (1 - Math.abs(2 * l - 1));
    if (max === r) h = ((g - b) / d) % 6;
    else if (max === g) h = (b - r) / d + 2;
    else h = (r - g) / d + 4;
    h *= 60;
    if (h < 0) h += 360;
  }
  return `${num(h)} ${num(s * 100)}% ${num(l * 100)}%`;
}

/** sRGB [r,g,b] + alpha → "rgba(r, g, b, a.aa)" (2-decimal alpha, tokens form). */
export function toRgba(rgb, a) {
  const [r, g, b] = rgb.slice(0, 3).map(chan255);
  return `rgba(${r}, ${g}, ${b}, ${a.toFixed(2)})`;
}

// ─────────────────────────────────────────────────────────────────────────────
// 10. Hue-preserved dark inversion (paw's mechanical inversion, theme-system
//     D14iv — covers the brand/neutral SPINE; per-theme dark accents are pinned).
//     Hue is preserved exactly; lightness is inverted through a gentle affine
//     band so near-white → deep and near-ink → pale without muddying mids;
//     chroma is preserved (optionally scaled).
// ─────────────────────────────────────────────────────────────────────────────
export function invertL(L) {
  // L=1 → 0.14, L=0 → 0.92: an inverted band that lands inside a comfortable
  // dark-mode range rather than a literal 1−L that muddies the middle.
  return 0.14 + (1 - L) * 0.78;
}
/** { L,C,h } (a light OKLCH) → its hue-preserved dark counterpart. */
export function darkInvert({ L, C, h }, chromaScale = 1) {
  return { L: invertL(L), C: C * chromaScale, h };
}

// ─────────────────────────────────────────────────────────────────────────────
// 11. Neutral ladder — hue-tinted, PER-RUNG chroma schedule (theme-system D14ii).
//     The tint hue rides the accent; chroma RAMPS 0.004 (bg) → 0.019 (ink) so
//     surfaces are barely tinted and the ink carries the most colour. Each rung
//     interpolates OKLCH L between bg.L and ink.L at fraction `t`.
// ─────────────────────────────────────────────────────────────────────────────
const NEUTRAL_RUNGS = [
  { slot: "surface", t: 0.02, C: 0.004 },
  { slot: "muted-surface", t: 0.06, C: 0.006 },
  { slot: "border", t: 0.12, C: 0.01 },
  { slot: "muted-text", t: 0.55, C: 0.015 },
];

function neutralLadder(bg, ink, accentHue) {
  const bgO = srgbToOklch(bg),
    inkO = srgbToOklch(ink);
  const out = {};
  for (const { slot, t, C } of NEUTRAL_RUNGS) {
    const L = bgO.L + (inkO.L - bgO.L) * t;
    out[slot] = oklchToSrgb(L, C, accentHue);
  }
  return out;
}

// ─────────────────────────────────────────────────────────────────────────────
// 12. Accent ramp (theme-system D14i + tint constants).
//     hover: per-mode ΔL (light darkens ≈−0.075 OKLCH L, dark lightens ≈+0.047),
//            chroma ×0.78. tint/tint2/ring are accent rgba fills (.10/.06/.28).
// ─────────────────────────────────────────────────────────────────────────────
const HOVER_DL = { light: -0.075, dark: 0.047 };
const HOVER_CHROMA_X = 0.78;
const ACCENT_TINT = { tint: 0.1, tint2: 0.06, ring: 0.28 };

function accentRamp(accent, mode) {
  const a = srgbToOklch(accent);
  const hoverL = Math.min(0.99, Math.max(0.02, a.L + HOVER_DL[mode]));
  const hover = oklchToSrgb(hoverL, a.C * HOVER_CHROMA_X, a.h);
  const accentRgb = parseColor(accent);
  return {
    hover,
    tint: toRgba(accentRgb, ACCENT_TINT.tint),
    tint2: toRgba(accentRgb, ACCENT_TINT.tint2),
    ring: toRgba(accentRgb, ACCENT_TINT.ring),
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// 13. Status roles — OKLCH hue-lock + chroma dial (frick status harmony,
//     theme-system w3). Each role keeps a CONSTANT semantic hue; chroma scales
//     to the theme's own accent chroma via `sat ∈ [0.35, 1]`. Text walks to AA
//     4.5, accent to AA 3.0 — both via `aaWalk` (misses reported per D15).
// ─────────────────────────────────────────────────────────────────────────────
const STATUS_HUE = { ok: 150, warn: 75, danger: 27, info: 264 }; // OKLCH degrees
const STATUS_CMAX = { ok: 0.15, warn: 0.17, danger: 0.18, info: 0.16 };
const STATUS_ROLES = ["ok", "warn", "danger", "info"];

/** Theme harmony dial: accent OKLCH chroma mapped [0.04,0.20] → [0.35,1]. */
function satOf(accentC) {
  return Math.min(1, Math.max(0.35, 0.35 + ((accentC - 0.04) / 0.16) * 0.65));
}

function deriveStatusRole(role, accent, mode, misses) {
  const h = STATUS_HUE[role];
  const cMax = STATUS_CMAX[role];
  const sat = satOf(srgbToOklch(accent).C);

  // BG — pale in light, deep in dark; low chroma family.
  const bgL = mode === "light" ? 0.96 : 0.24;
  const bgC = (mode === "light" ? cMax * 0.28 : cMax * 0.55) * sat + 0.02;
  const bg = oklchToSrgb(bgL, bgC, h);

  // TEXT — high-contrast same-hue partner, walk L to AA 4.5.
  const txStart = mode === "light" ? 0.3 : 0.9;
  const txC = (mode === "light" ? cMax * 0.7 : cMax * 0.35) * sat;
  const tw = aaWalk(txStart, txC, h, bg, {
    target: 4.5,
    step: mode === "light" ? -0.02 : 0.01,
  });
  if (!tw.hit)
    misses.push({ role, mode, slot: "text", got: tw.contrast, want: 4.5 });

  // ACCENT — mid-L same hue, walk L to AA 3.0.
  const acStart = mode === "light" ? 0.52 : 0.68;
  const acC = cMax * sat;
  const aw = aaWalk(acStart, acC, h, bg, {
    target: 3.0,
    step: mode === "light" ? -0.02 : 0.02,
    maxL: 0.97,
  });
  if (!aw.hit)
    misses.push({ role, mode, slot: "accent", got: aw.contrast, want: 3.0 });

  // BORDER — between bg and accent in L and C.
  const bgO = srgbToOklch(bg);
  const border = oklchToSrgb((bgO.L + aw.L) / 2, (bgC + acC) / 2, h);

  return { bg, text: tw.rgb, accent: aw.rgb, border };
}

// ─────────────────────────────────────────────────────────────────────────────
// 14. Chrome ladder — the 8<16<22<55 capability (theme-system D14v). Monotonic
//     ink-over-bg mixes; muted/secondary/input mix in srgb, muted-foreground in
//     oklch (mirrors frick's chrome ladder). Imposed on future themes; evergreen
//     pins its off-ladder slots.
// ─────────────────────────────────────────────────────────────────────────────
const CHROME_LADDER = [
  { slot: "chrome-muted", pct: 8, space: "srgb" },
  { slot: "chrome-secondary", pct: 16, space: "srgb" },
  { slot: "chrome-border", pct: 22, space: "srgb" },
  { slot: "chrome-muted-fg", pct: 75, space: "oklch" },
  { slot: "chrome-input", pct: 55, space: "srgb" },
];

function chromeLadder(bg, ink) {
  const out = {};
  for (const { slot, pct, space } of CHROME_LADDER) {
    out[slot] =
      space === "oklch" ? mixOklch(ink, bg, pct) : mixSrgb(ink, bg, pct);
  }
  return out;
}

// ─────────────────────────────────────────────────────────────────────────────
// 15. derive(themeSpec) → flat slot map.
//
//   themeSpec = {
//     light: { bg, ink, accent },   // authoring colours (any parseable form)
//     dark:  { bg, ink, accent },
//     overrides?: { "<slot>.<mode>": value }   // honest pins (D13), incl var()
//   }
//
//   Returns a flat map keyed "<slot>.<mode>" → serialized colour. Base/neutral/
//   accent slots are HSL triplets; accent tints are rgba(); status/chrome are
//   HSL triplets. `overrides` are applied verbatim last (var() passes through).
//   AA-walk misses live on a NON-enumerable `.misses` array so a byte-comparison
//   over Object.keys stays clean while a caller can still audit them (D15).
// ─────────────────────────────────────────────────────────────────────────────
export function derive(spec, opts = {}) {
  const { onMiss = defaultOnMiss } = opts;
  const out = {};
  const misses = [];
  const put = (slot, mode, rgb) => {
    out[`${slot}.${mode}`] = toHslTriplet(rgb);
  };

  for (const mode of ["light", "dark"]) {
    const { bg, ink, accent } = spec[mode];
    const accentHue = srgbToOklch(accent).h;

    // Spine: bg / text(ink) / primary(accent) verbatim through the serializer.
    put("bg", mode, parseColor(bg));
    put("text", mode, parseColor(ink));
    put("primary", mode, parseColor(accent));

    // Primary foreground — contrast-aware on-accent flip (D16).
    const fg = onAccent(accent);
    out[`primary-fg.${mode}`] = toHslTriplet(parseColor(fg.color));
    if (!fg.clears)
      misses.push({
        role: "primary-fg",
        mode,
        slot: "on-accent",
        got: fg.contrast,
        want: 4.5,
      });

    // Accent ramp — hover + tint/tint2/ring rgba fills.
    const ramp = accentRamp(accent, mode);
    put("primary-hover", mode, ramp.hover);
    put("ring", mode, parseColor(accent));
    out[`accent-tint.${mode}`] = ramp.tint;
    out[`accent-tint2.${mode}`] = ramp.tint2;
    out[`accent-ring.${mode}`] = ramp.ring;

    // Neutral ladder — hue-tinted, per-rung chroma schedule.
    const neut = neutralLadder(bg, ink, accentHue);
    for (const slot of Object.keys(neut)) put(slot, mode, neut[slot]);

    // Chrome ladder — 8<16<22<55 (+ oklch muted-fg).
    const chrome = chromeLadder(bg, ink);
    for (const slot of Object.keys(chrome)) put(slot, mode, chrome[slot]);

    // Status roles — OKLCH hue-lock + chroma dial; text→AA4.5, accent→AA3.
    for (const role of STATUS_ROLES) {
      const r = deriveStatusRole(role, accent, mode, misses);
      put(`status-${role}-bg`, mode, r.bg);
      put(`status-${role}-text`, mode, r.text);
      put(`status-${role}-accent`, mode, r.accent);
      put(`status-${role}-border`, mode, r.border);
    }
  }

  // Honest pins (D13): overrides win, verbatim; var() passes through.
  for (const [key, value] of Object.entries(spec.overrides || {})) {
    out[key] = passthrough(value);
  }

  if (misses.length) for (const m of misses) onMiss(m);
  Object.defineProperty(out, "misses", { value: misses, enumerable: false });
  return out;
}

function defaultOnMiss(m) {
  console.warn(
    `[derive] AA MISS ${m.role}/${m.mode} ${m.slot}: contrast ${m.got.toFixed(
      2,
    )} < ${m.want} — pin an override (D13/D15).`,
  );
}
