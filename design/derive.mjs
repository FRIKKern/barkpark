// design/derive.mjs — the theme-system Wave-2 compiler (theme-system D12/D14).
//
// Zero-dependency (Node built-ins only), PURE and DETERMINISTIC. TWO layers in
// one module, sharing ONE implementation of the colour math:
//
//   PART I — the capability CORE (ts-w3-derive-compiler): OKLCH colour math +
//   Barkpark-format serializers. Author ~3 colours per mode ({bg, ink, accent})
//   → `deriveSpine()`, a flat slot map of derived theme colours: a hue-tinted
//   neutral ladder, an accent ramp, a contrast-aware on-accent foreground, an
//   8<16<22<55 chrome ladder, OKLCH hue-locked status roles with AA
//   lightness-walking, and a hue-preserved dark inversion capability. These
//   formulas are IMPOSED on future themes (charter D14v); evergreen adopts them
//   slot-by-slot as its override pins burn down.
//
//   PART II — the characterization COMPILER (ts-w3b): `derive(theme)` resolves
//   every theme-varying tokens.json slot (the SLOTS contract) from an authored
//   design/themes/*.json skin — per-mode {bg,ink,accent} + an `overrides` pin
//   block + a D21 `passthrough` declaration — over a FROZEN neutral structure.
//   check.mjs Part F proves derive(evergreen) === tokens.json BYTE-equal and
//   freezes the override count (D13). The D12 w4 seam is "swap the emitted
//   `tokens` singleton for derive()'s output".
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
const WARM_WHITE_HEX = "#fbfaf6"; // paw's warm paper white (Part I hex domain)
const NEAR_INK = "#15211d"; // the paper ink (near-black, green-tinted)

/** @returns {{ color:string, contrast:number, clears:boolean, pick:"warm-white"|"near-ink" }} */
export function onAccent(accent, opts = {}) {
  const { warmWhite = WARM_WHITE_HEX, nearInk = NEAR_INK, target = 4.5 } = opts;
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
// 15. deriveSpine(themeSpec) → flat slot map (the CAPABILITY pipeline).
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
//   NOTE: this is the capability pipeline for FUTURE themes — the shipped-byte
//   characterization compiler is `derive()` in Part II below.
// ─────────────────────────────────────────────────────────────────────────────
export function deriveSpine(spec, opts = {}) {
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

// ═════════════════════════════════════════════════════════════════════════════
// PART II — the characterization COMPILER (ts-w3b, charter D12/D13/D21).
// derive(theme) resolves every theme-varying tokens.json slot from an authored
// design/themes/*.json skin over a FROZEN neutral structure. check.mjs Part F
// proves derive(evergreen) === tokens.json byte-equal. The perceptual math
// (OKLCH, WCAG contrast, AA-walk, gamut clamp) is PART I's — one owner.
// ═════════════════════════════════════════════════════════════════════════════

// ── byte-exact string-format helpers (0..255 channel domain) ─────────────────
// These serialize/parse the exact string formats tokens.json ships. Distinct
// from Part I's 0..1-domain serializers on purpose: Part F byte-equality rides
// on this rounding path matching emit.mjs's hslToHex converter.
const toHex2 = (v) =>
  Math.round(Math.min(1, Math.max(0, v)) * 255)
    .toString(16)
    .padStart(2, "0");

export function hexToRgb(hex) {
  const h = hex.replace("#", "");
  return [0, 2, 4].map((i) => parseInt(h.slice(i, i + 2), 16));
}
export const rgbToHex = ([r, g, b]) =>
  `#${toHex2(r / 255)}${toHex2(g / 255)}${toHex2(b / 255)}`;

// HSL channels "H S% L%" ⇄ {h,s,l}. Format round-trips byte-for-byte for the
// values tokens.json carries (integers stay integers, "9.6"/"217.2" keep their
// decimals) — JS Number#toString drops trailing zeros exactly like the source.
export function hslParse(ch) {
  const m = ch.trim().split(/\s+/);
  return { h: parseFloat(m[0]), s: parseFloat(m[1]), l: parseFloat(m[2]) };
}
const num4 = (x) => Number(x.toFixed(4)); // strip float noise, keep authored precision
export const hslFormat = ({ h, s, l }) => `${num4(h)} ${num4(s)}% ${num4(l)}%`;

/** "H S% L%"-parsed {h,s,l} → sRGB [r,g,b] in 0..255 (UNROUNDED floats). */
export function hslToRgb({ h, s, l }) {
  s /= 100;
  l /= 100;
  const c = (1 - Math.abs(2 * l - 1)) * s;
  const hp = h / 60;
  const x = c * (1 - Math.abs((hp % 2) - 1));
  let r = 0,
    g = 0,
    b = 0;
  if (hp >= 0 && hp < 1) [r, g, b] = [c, x, 0];
  else if (hp < 2) [r, g, b] = [x, c, 0];
  else if (hp < 3) [r, g, b] = [0, c, x];
  else if (hp < 4) [r, g, b] = [0, x, c];
  else if (hp < 5) [r, g, b] = [x, 0, c];
  else [r, g, b] = [c, 0, x];
  const m = l - c / 2;
  return [(r + m) * 255, (g + m) * 255, (b + m) * 255];
}
export const hslToHex = (ch) => rgbToHex(hslToRgb(hslParse(ch)));

// ── on-accent flip (D16) over Part I's WCAG contrast ─────────────────────────
// Pick the foreground that sits ON a filled accent: warm-white if it clears AA
// on the fill, else a near-ink of the accent's own hue. Both branches are
// unit-tested. (Part I's `onAccent` is the hex-domain twin used by
// deriveSpine; this one speaks tokens.json HSL-triplet strings.)
export const WARM_WHITE = "0 0% 100%";
export function onAccentFor(fillHsl, { warmWhite = WARM_WHITE, aa = 4.5 } = {}) {
  if (contrast(fillHsl, warmWhite) >= aa) return warmWhite;
  // near-ink of the accent hue: hold H, drop to a low L that clears AA.
  const { h } = hslParse(fillHsl);
  return hslFormat({ h, s: 45, l: 8 });
}

// ── rgba passthrough helper (byte-exact alpha as a literal string) ───────────
const rgbaFrom = (hex, alphaStr) => {
  if (typeof hex !== "string") return undefined; // an unresolved (unpinned) base cascades as undefined, not a throw
  const [r, g, b] = hexToRgb(hex);
  return `rgba(${r}, ${g}, ${b}, ${alphaStr})`;
};

// ── per-mode formula constants (fit-first, D14) ──────────────────────────────
// hover is a per-mode lightness step (darken in light, lighten in dark). The
// shipped evergreen hover bytes fit a clean HSL-L step exactly; Part I's OKLCH
// ΔL (~-7.5/+4.7) is the design intent this step approximates on the brand ramp.
const HOVER_HSL_STEP = { light: -6, dark: +8 };
// Paper hairline / tint alphas — the rule/edit-hover/accent-soft/chrome-border
// roles are the paper ink (or accent) at a fixed alpha. Strings so "0.10"
// keeps its trailing zero.
const PAPER_ALPHA = {
  "rule":          { light: "0.09", dark: "0.10" },
  "edit-hover":    { light: "0.08", dark: "0.09" },
  "chrome-border": { light: "0.12", dark: "0.13" },
  "accent-soft":   { light: "0.10", dark: "0.16" },
};

// ── skin-responsive perceptual formula helpers (ts-w5a — full derive) ─────────
// These PROMOTE Part I's deriveSpine capabilities into derive()'s per-slot
// formulas so a BARE {bg,ink,accent}×2 skin (no overrides) resolves EVERY one of
// the 156 slots — no frozen zinc "silent inherit". The frozen NEUTRAL_HSL /
// ZINC_CHROME ladders are GONE: the neutral + chrome rungs are now re-hued toward
// the theme accent (a warm theme gets warm neutrals, a cool theme cool ones).
// Evergreen's hand-tuned shadcn-zinc bytes DRIFT from these formulas, so evergreen
// PINS them (a characterization freeze — overrides win, Part F byte gate stays
// green); a fresh theme re-skins natively. Output is in tokens.json string forms.
const oklchHsl = (L, C, h) => toHslTriplet(oklchToSrgb(L, C, h)); // → "H S% L%"
const oklchHex = (L, C, h) => toHex(oklchToSrgb(L, C, h));        // → "#rrggbb"
const accentHueOf = (skin, mode) => srgbToOklch(skin[mode].accent).h;

// Neutral CSS rungs — {L,C} targets re-hued toward the accent, chroma ramping up
// the ladder (D14ii). L targets approximate the shadcn-zinc rung lightnesses
// evergreen ships (which evergreen then pins byte-exact). The frozen ladder was
// hue-BLIND — that hue-blindness is exactly the silent inherit this replaces.
const NEUTRAL_II = {
  "muted-surface": { light: { L: 0.966, C: 0.005 }, dark: { L: 0.162, C: 0.006 } },
  "border":        { light: { L: 0.906, C: 0.007 }, dark: { L: 0.191, C: 0.006 } },
  "muted-text":    { light: { L: 0.520, C: 0.010 }, dark: { L: 0.686, C: 0.012 } },
  "surface":       {                                 dark: { L: 0.095, C: 0.010 } },
};
const STUDIO_II = {
  "bg-accent":     { light: { L: 0.936, C: 0.006 }, dark: { L: 0.166, C: 0.006 } },
  // fg-dim L raised toward the ground on BOTH modes so contrast(--fg-dim,--bg)
  // clears WCAG AA 4.5 for the native (ember/fjord) themes while staying the
  // dimmest text tier (light L still > muted-text 0.520; dark L still < 0.686).
  // Evergreen PINS its own fg-dim (zinc rung) — see themes/evergreen.json.
  "fg-dim":        { light: { L: 0.550, C: 0.008 }, dark: { L: 0.605, C: 0.010 } },
  "fg-accent":     { light: { L: 0.220, C: 0.014 }                                },
  "border-muted":  {                                 dark: { L: 0.156, C: 0.006 } },
  // surface-raised: an elevated panel/card fill that VISIBLY separates from --bg.
  // DARK rung is bg-RELATIVE (raisedDark below): L = theme's dark-bg L + 0.0695 so
  // the elevation step is CONSTANT across themes. A fixed absolute L gave evergreen
  // a legible +0.069 step but only +0.016 on ember / +0.026 on fjord (invisible).
  // dark.L below is the evergreen fit target (0.14051 bg + 0.0695 = 0.21001, the
  // committed 0.210 byte) kept for reference; only dark.C is consumed by the helper.
  // light ≈ bg (near-white) since light-mode elevation rides border + shadow.
  "surface-raised": { light: { L: 0.992, C: 0.004 }, dark: { L: 0.210, C: 0.010 } },
  // border-subtle: a hairline sitting BETWEEN --border-muted and --bg. DARK rung is
  // bg-relative too (L = dark-bg L + 0.0445); a fixed L INVERTED below bg on ember
  // dark (hairline darker than the ground). dark.L is the evergreen fit target
  // (0.14051 + 0.0445 = 0.18501, the committed 0.185 byte); only dark.C is consumed.
  "border-subtle":  { light: { L: 0.960, C: 0.005 }, dark: { L: 0.185, C: 0.008 } },
};
const neutralII = (skin, mode, spec) => oklchHsl(spec.L, spec.C, accentHueOf(skin, mode));
// bg-relative dark elevation rung — L rides the theme's OWN dark-bg lightness so a
// raised surface / subtle hairline sits a CONSTANT OKLCH-L step above the ground on
// every theme (evergreen, ember, fjord), C/hue staying chrome-neutral toward accent.
const raisedDark = (skin, dL, C) =>
  oklchHsl(srgbToOklch(skin.dark.bg).L + dL, C, accentHueOf(skin, "dark"));

// CLI chrome gray ramp — the theme ink mixed over the theme bg in gamma sRGB
// (the frozen zinc hexes evergreen pins; a fresh theme's chrome carries its tint).
// Percent = how much ink; higher → darker in light, lighter in dark.
const CHROME_II = {
  "chrome-ink":            { light: 92, dark: 90 },
  "chrome-text-secondary": { light: 75, dark: 63 },
  "chrome-dim":            { light: 38, dark: 38 },
  "chrome-field-border":   { light: 18, dark: 65 },
  "chrome-toolbar-bg":     { light: 2,  dark: 4  },
  "chrome-cursor-bg":      { light: 5,  dark: 10 },
};
const chromeII = (skin, mode, pct) => toHex(mixSrgb(skin[mode].ink, skin[mode].bg, pct));

// Paper reading-surface bases — hue-tinted near-white / near-ink from the skin.
// The whole paper.reader / mailChrome / paperEmail cascade resolves off these.
const PAPER_BASE_II = {
  "bg":        { light: { L: 0.985, C: 0.006 }, dark: { L: 0.140, C: 0.012 } },
  "bg-deep":   { light: { L: 0.948, C: 0.010 }, dark: { L: 0.186, C: 0.014 } },
  "ink":       { light: { L: 0.245, C: 0.020 }, dark: { L: 0.902, C: 0.010 } },
  "ink-soft":  { light: { L: 0.440, C: 0.016 }, dark: { L: 0.702, C: 0.012 } },
  "ink-faint": { light: { L: 0.585, C: 0.012 }, dark: { L: 0.532, C: 0.010 } },
};

// Status roles — OKLCH hue-lock + chroma dial + AA lightness-walk (D15). Each
// status.<role>.<mode> is a SINGLE readable tone (the shipped tokens shape),
// walked to clear AA 4.5 on the mode ground; a residual miss is REPORTED into
// the derive misses list (D15) — never silently shipped.
function statusII(role, skin, mode, misses) {
  const h = STATUS_HUE[role];
  const sat = satOf(srgbToOklch(skin[mode].accent).C);
  const C = STATUS_CMAX[role] * sat;
  const ground = mode === "light" ? "0 0% 100%" : skin.dark.bg;
  const startL = mode === "light" ? 0.55 : 0.72;
  const w = aaWalk(startL, C, h, ground, {
    target: 4.5, step: mode === "light" ? -0.02 : 0.02, maxL: 0.97,
  });
  if (!w.hit) misses.push({ slot: `status.${role}.${mode}`, got: w.contrast, want: 4.5 });
  return toHslTriplet(w.rgb);
}

// Paper callout tones — TINTED from the status ramp: a pale tinted panel (bg) and
// an AA-clearing ink (fg) at the role's locked hue; neutral rides the accent hue
// at near-zero chroma (a gray callout). Output hex (tokens shape).
const CALLOUT_HUE = { success: 150, warning: 75, danger: 27, info: 264 };
function calloutII(mode, role, sub, skin, misses) {
  const neutral = role === "neutral";
  const h = neutral ? accentHueOf(skin, mode) : CALLOUT_HUE[role];
  const sat = satOf(srgbToOklch(skin[mode].accent).C);
  const baseC = neutral ? 0.006 : 0.13 * sat;
  const bgL = mode === "light" ? 0.951 : 0.155;
  const bg = oklchToSrgb(bgL, baseC * (mode === "light" ? 0.35 : 0.6), h);
  if (sub === "bg") return toHex(bg);
  const w = aaWalk(
    mode === "light" ? 0.45 : 0.8, baseC * (mode === "light" ? 0.9 : 0.7), h, bg,
    { target: 4.5, step: mode === "light" ? -0.02 : 0.02 },
  );
  if (!w.hit) misses.push({ slot: `paperCallout.${mode}.${role}.${sub}`, got: w.contrast, want: 4.5 });
  return toHex(w.rgb);
}

// Warm-shift an HSL triplet (hue rotate + optional sat bump) — the decorative /
// reading accents are a warmer sibling hue of the brand seed.
function shiftHsl(hslStr, dh, ds = 0) {
  const p = hslParse(hslStr);
  return hslFormat({
    h: (((p.h + dh) % 360) + 360) % 360,
    s: Math.min(100, Math.max(0, p.s + ds)),
    l: p.l,
  });
}

// ── the derivation map: slot → (ctx) => value ────────────────────────────────
// Every slot is EITHER here (native) OR in the theme's overrides (pinned). A
// slot in neither resolves to undefined — Part F reds that as an uncovered slot.
function buildFormulas() {
  const F = {};
  const modes = ["light", "dark"];
  const M = (fn) => modes.forEach((m) => { const [k, v] = fn(m); F[k] = v; });

  // — brand spine —
  M((m) => [`primary.${m}`, (c) => c.skin[m].accent]);
  M((m) => [`primary-hover.${m}`, (c) => {
    const p = hslParse(c.skin[m].accent); return hslFormat({ ...p, l: p.l + HOVER_HSL_STEP[m] });
  }]);
  // primary foreground — the contrast-aware on-accent FLIP, BOTH modes (D16):
  // warm-white on a deep fill, near-ink on a light fill (evergreen's amber-free
  // brand → warm-white light; a mid-L dark accent → near-ink dark).
  M((m) => [`primary-fg.${m}`, (c) => onAccentFor(c.skin[m].accent)]);
  M((m) => [`bg.${m}`, (c) => c.skin[m].bg]);
  M((m) => [`text.${m}`, (c) => c.skin[m].ink]);
  F["surface.light"] = (c) => c.skin.light.bg; // paper-flat page bg
  F["surface.dark"] = (c) => neutralII(c.skin, "dark", NEUTRAL_II["surface"].dark);
  // ring — a mid-L brand tone (light) / the brand dark accent (dark).
  F["ring.light"] = (c) => { const p = hslParse(c.skin.light.accent); return hslFormat({ ...p, l: Math.min(62, p.l + 8) }); };
  F["ring.dark"] = (c) => c.skin.dark.accent;

  // — decorative + reading accents (sibling hues of the brand seed) —
  // accent = the brand seed by default (a theme MAY pin a second hue, as evergreen
  // pins amber); reading-accent = a warmer sibling (hue rotated toward red).
  M((m) => [`accent.${m}`, (c) => c.skin[m].accent]);
  M((m) => [`reading-accent.${m}`, (c) => shiftHsl(c.skin[m].accent, -40, 14)]);

  // — code frame: bg from the chrome ramp; fg tracks the reading accent —
  M((m) => [`code.bg.${m}`, (c) => chromeII(c.skin, m, m === "light" ? 4 : 10)]);
  M((m) => [`code.fg.${m}`, (c) => toHex(parseColor(c.resolve(`reading-accent.${m}`)))]);

  // — CSS neutral rungs: hue-tinted ladder re-hued toward the accent (D14ii) —
  for (const role of ["muted-surface", "muted-text", "border"])
    M((m) => [`${role}.${m}`, (c) => neutralII(c.skin, m, NEUTRAL_II[role][m])]);
  F["studioChrome.bg-accent.light"] = (c) => neutralII(c.skin, "light", STUDIO_II["bg-accent"].light);
  F["studioChrome.bg-accent.dark"] = (c) => neutralII(c.skin, "dark", STUDIO_II["bg-accent"].dark);
  F["studioChrome.border-muted.light"] = () => "var(--border)";
  F["studioChrome.border-muted.dark"] = (c) => neutralII(c.skin, "dark", STUDIO_II["border-muted"].dark);
  F["studioChrome.fg-dim.light"] = (c) => neutralII(c.skin, "light", STUDIO_II["fg-dim"].light);
  F["studioChrome.fg-dim.dark"] = (c) => neutralII(c.skin, "dark", STUDIO_II["fg-dim"].dark);
  F["studioChrome.fg-accent.light"] = (c) => neutralII(c.skin, "light", STUDIO_II["fg-accent"].light);
  F["studioChrome.fg-accent.dark"] = () => "var(--text)";
  F["studioChrome.surface-raised.light"] = (c) => neutralII(c.skin, "light", STUDIO_II["surface-raised"].light);
  F["studioChrome.surface-raised.dark"] = (c) => raisedDark(c.skin, 0.0695, STUDIO_II["surface-raised"].dark.C);
  F["studioChrome.border-subtle.light"] = (c) => neutralII(c.skin, "light", STUDIO_II["border-subtle"].light);
  F["studioChrome.border-subtle.dark"] = (c) => raisedDark(c.skin, 0.0445, STUDIO_II["border-subtle"].dark.C);

  // — onStatus: warm-white on every status chip; the two fills that don't clear
  // AA 4.5 on white (warn/info light) are the charter's known warn/info AA
  // follow-up; danger-fg.light's asymmetric 98% is the one pinned residual. —
  for (const role of ["ok", "warn", "danger", "info"])
    M((m) => [`onStatus.${role}-fg.${m}`, () => WARM_WHITE]);

  // — status roles: OKLCH hue-lock + chroma dial + AA-walk (D15) —
  for (const role of ["ok", "warn", "danger", "info"])
    M((m) => [`status.${role}.${m}`, (c) => statusII(role, c.skin, m, c.misses)]);

  // — CLI chrome: skin-tinted gray ramp + 5 structural var() aliases —
  for (const role of Object.keys(CHROME_II))
    M((m) => [`cliChrome.${role}.${m}`, (c) => chromeII(c.skin, m, CHROME_II[role][m])]);
  F["cliChrome.chrome-border"] = () => "var(--border)";
  F["cliChrome.chrome-border-active"] = () => "var(--info)";
  F["cliChrome.chrome-label"] = () => "var(--muted-text)";
  F["cliChrome.chrome-primary-cta"] = () => "var(--primary)";
  F["cliChrome.chrome-on-primary"] = () => "var(--primary-fg)";

  // — CLI chrome accent/selection: PRIMARY-DERIVED (ts-w3e retint, charter D19).
  // chrome-accent = hslToHex(primary) per mode; selection-fg = primary (light) /
  // primary-hover (dark) as hex; selection-bg = primary mixed 10% over the mode
  // bg, flattened to a solid gamma-sRGB hex. NATIVE — zero pins (D19). —
  M((m) => [`cliChrome.chrome-accent.${m}`, (c) => hslToHex(c.skin[m].accent)]);
  F["cliChrome.chrome-selection-fg.light"] = (c) => hslToHex(c.skin.light.accent);
  F["cliChrome.chrome-selection-fg.dark"] = (c) => {
    const p = hslParse(c.skin.dark.accent);
    return rgbToHex(hslToRgb({ ...p, l: p.l + HOVER_HSL_STEP.dark }));
  };
  M((m) => [`cliChrome.chrome-selection-bg.${m}`, (c) => {
    const acc = hslToRgb(hslParse(c.skin[m].accent));
    const bg = hslToRgb(hslParse(c.skin[m].bg));
    return rgbToHex(acc.map((v, i) => v * 0.1 + bg[i] * 0.9)); // color-mix(in srgb, primary 10%, bg)
  }]);

  // — cliCalloutNeutral: the neutral peer of the status family = the muted-text
  // tone (hue-tinted neutral), serialized as hex for the pdrender WASM reader. —
  M((m) => [`cliCalloutNeutral.${m}`, (c) => hslToHex(c.resolve(`muted-text.${m}`))]);

  // — paper.surface: hue-tinted bases from the skin, then hairlines/tints/chrome —
  for (const role of Object.keys(PAPER_BASE_II))
    M((m) => [`paper.surface.${role}.${m}`, (c) => oklchHex(PAPER_BASE_II[role][m].L, PAPER_BASE_II[role][m].C, accentHueOf(c.skin, m))]);
  M((m) => [`paper.surface.accent.${m}`, (c) => hslToHex(c.skin[m].accent)]);
  for (const role of ["rule", "edit-hover", "chrome-border"])
    M((m) => [`paper.surface.${role}.${m}`, (c) => rgbaFrom(c.resolve(`paper.surface.ink.${m}`), PAPER_ALPHA[role][m])]);
  M((m) => [`paper.surface.accent-soft.${m}`, (c) => rgbaFrom(c.resolve(`paper.surface.accent.${m}`), PAPER_ALPHA["accent-soft"][m])]);
  F["paper.surface.chrome-bg.light"] = (c) => c.resolve("paper.surface.bg.light");    // chrome bg == page bg (light)
  F["paper.surface.chrome-bg.dark"] = (c) => c.resolve("paper.surface.bg-deep.dark"); // chrome bg == deep bg (dark)

  // — paper.reader: overlay of paper.surface; only the two hairline rules diverge —
  const readerMap = {
    light: { bg: "bg", "bg-deep": "bg-deep", ink: "ink", "ink-soft": "ink-soft", accent: "accent", "accent-soft": "accent-soft" },
    dark: { bg: "bg", "bg-deep": "bg-deep", ink: "ink", "ink-soft": "ink-soft", accent: "accent", "accent-soft": "accent-soft", "ink-faint": "ink-faint", "chrome-bg": "chrome-bg", "chrome-border": "chrome-border" },
  };
  for (const m of modes)
    for (const [rk, sk] of Object.entries(readerMap[m]))
      F[`paper.reader.${m}.${rk}`] = ((mm, s) => (c) => c.resolve(`paper.surface.${s}.${mm}`))(m, sk);
  // reader hairline DIVERGES from the surface rule (charter D4): light is a SOLID
  // tint (ink mixed over the page), dark a slightly heavier alpha than surface's.
  F["paper.reader.light.rule"] = (c) => toHex(mixSrgb(c.resolve("paper.surface.ink.light"), c.resolve("paper.surface.bg.light"), 13));
  F["paper.reader.dark.rule"] = (c) => rgbaFrom(c.resolve("paper.surface.ink.dark"), "0.13");

  // — mailChrome: ⊂ paper.surface mapping. paper.light = the (near-white) page bg;
  // rule.dark = a solid hairline (paper ink mixed 20% over the dark page). —
  const mailMap = {
    "bar.light": "paper.surface.bg.light", "bar.dark": "paper.surface.bg.dark",
    "paper.dark": "paper.surface.bg-deep.dark",
    "rule.light": "paper.reader.light.rule",
    "ink.light": "paper.surface.ink.light", "ink.dark": "paper.surface.ink.dark",
    "soft.light": "paper.surface.ink-soft.light", "soft.dark": "paper.surface.ink-soft.dark",
    "accent.light": "paper.surface.accent.light", "accent.dark": "paper.surface.accent.dark",
  };
  for (const [slot, src] of Object.entries(mailMap))
    F[`mailChrome.${slot}`] = ((s) => (c) => c.resolve(s))(src);
  F["mailChrome.paper.light"] = (c) => hslToHex(c.skin.light.bg);
  F["mailChrome.rule.dark"] = (c) => toHex(mixSrgb(c.resolve("paper.surface.ink.dark"), c.resolve("paper.surface.bg.dark"), 20));

  // — paperEmail: light-only skin, ⊂ paper.surface / reader —
  const emailMap = {
    brand: "paper.surface.accent.light", "brand-text": null, // brand-text = warm white
    rule: "paper.reader.light.rule", "page-bg": "paper.surface.bg-deep.light",
    paper: "mailChrome.paper.light", text: "paper.surface.ink.light",
    muted: "paper.surface.ink-soft.light", "code-bg": "paper.surface.bg-deep.light",
  };
  for (const [slot, src] of Object.entries(emailMap))
    F[`paperEmail.${slot}`] = src == null ? () => "#ffffff" : ((s) => (c) => c.resolve(s))(src);

  // — paperCallout: 5 role tones × {bg,fg} × 2 modes, TINTED from the status ramp —
  for (const mode of modes)
    for (const role of ["success", "warning", "danger", "info", "neutral"])
      for (const sub of ["bg", "fg"])
        F[`paperCallout.${mode}.${role}.${sub}`] =
          ((mm, rr, ss) => (c) => calloutII(mm, rr, ss, c.skin, c.misses))(mode, role, sub);

  return F;
}
const FORMULAS = buildFormulas();

// ── the output contract: every theme-varying slot derive() produces ──────────
// Part F asserts this set === tokens.json's theme-varying leaf set (minus
// declared passthroughs). A drift either way is a red (w4 must not discover a
// hole — D21). paperCallout carries light AND dark tone families (post ts-w3c).
export const SLOTS = (() => {
  const base = ["primary", "primary-hover", "primary-fg", "bg", "surface", "muted-surface", "text", "muted-text", "border", "ring", "accent", "reading-accent"];
  const s = [];
  for (const r of base) for (const m of ["light", "dark"]) s.push(`${r}.${m}`);
  for (const r of ["fg", "bg"]) for (const m of ["light", "dark"]) s.push(`code.${r}.${m}`);
  const paperRoles = ["bg", "bg-deep", "ink", "ink-soft", "ink-faint", "rule", "edit-hover", "accent", "accent-soft", "chrome-bg", "chrome-border"];
  for (const r of paperRoles) for (const m of ["light", "dark"]) s.push(`paper.surface.${r}.${m}`);
  for (const r of ["bg", "bg-deep", "ink", "ink-soft", "rule", "accent", "accent-soft"]) s.push(`paper.reader.light.${r}`);
  for (const r of ["bg", "bg-deep", "ink", "ink-soft", "rule", "accent", "accent-soft", "ink-faint", "chrome-bg", "chrome-border"]) s.push(`paper.reader.dark.${r}`);
  for (const r of ["paper", "bar", "rule", "ink", "soft", "accent"]) for (const m of ["light", "dark"]) s.push(`mailChrome.${r}.${m}`);
  for (const m of ["light", "dark"]) s.push(`cliCalloutNeutral.${m}`);
  for (const r of ["ok", "warn", "danger", "info"]) for (const m of ["light", "dark"]) s.push(`status.${r}.${m}`);
  for (const r of ["ok-fg", "warn-fg", "danger-fg", "info-fg"]) for (const m of ["light", "dark"]) s.push(`onStatus.${r}.${m}`);
  for (const r of ["bg-accent", "border-muted", "fg-dim", "fg-accent", "surface-raised", "border-subtle"]) for (const m of ["light", "dark"]) s.push(`studioChrome.${r}.${m}`);
  const cliHex = ["chrome-accent", "chrome-dim", "chrome-ink", "chrome-text-secondary", "chrome-selection-bg", "chrome-selection-fg", "chrome-field-border", "chrome-toolbar-bg", "chrome-cursor-bg"];
  for (const r of cliHex) for (const m of ["light", "dark"]) s.push(`cliChrome.${r}.${m}`);
  for (const r of ["chrome-border", "chrome-border-active", "chrome-label", "chrome-primary-cta", "chrome-on-primary"]) s.push(`cliChrome.${r}`);
  for (const r of ["brand", "brand-text", "rule", "page-bg", "paper", "text", "muted", "code-bg"]) s.push(`paperEmail.${r}`);
  for (const t of ["light", "dark"])
    for (const r of ["success", "warning", "danger", "info", "neutral"])
      for (const k of ["bg", "fg"]) s.push(`paperCallout.${t}.${r}.${k}`);
  return s;
})();

// The theme-INVARIANT families a theme is allowed to declare as passthrough
// (D21). A theme.json `passthrough` array outside this set is a schema red — it
// can not opt a derivable family out of characterization.
export const PASSTHROUGH_FAMILIES = [
  "presence", "sheetCf", "matchQuality", "pdrenderChart", "pdrenderHeatmap",
  "provider", "statusHealth", "fleetStatus", "statusChrome",
  "errorPage", "graphCanvas", "readerInfo", "lifecycle", "instanceLifecycle",
  "authButton", "cloudChrome",
];

// ── derive(theme) — the characterization compiler ────────────────────────────
const PENDING = Symbol("pending");
export function derive(theme) {
  const O = theme.overrides || {};
  const skin = theme.modes;
  const memo = new Map();
  function resolve(slot) {
    if (memo.has(slot)) {
      const v = memo.get(slot);
      if (v === PENDING) throw new Error(`derive: cyclic slot dependency at ${slot}`);
      return v;
    }
    memo.set(slot, PENDING);
    let v;
    if (Object.prototype.hasOwnProperty.call(O, slot)) v = O[slot];
    else if (FORMULAS[slot]) v = FORMULAS[slot](ctx);
    else v = undefined;
    memo.set(slot, v);
    return v;
  }
  // `misses` collects every AA-walk residual that could NOT clear its target (D15)
  // — a formula that walks (status, paperCallout) pushes here rather than silently
  // shipping a failing colour. Part F asserts a committed theme's misses are all
  // declared in its `_aaExceptions`; the bare-skin tests assert the reporting path.
  const misses = [];
  const ctx = { skin, resolve, misses };
  const values = {};
  for (const slot of SLOTS) values[slot] = resolve(slot);
  const pinned = SLOTS.filter((s) => Object.prototype.hasOwnProperty.call(O, s));
  const native = SLOTS.filter((s) => !Object.prototype.hasOwnProperty.call(O, s));
  // A slot that is neither pinned nor covered by a formula (undefined value) is an
  // UNRESOLVED hole — for a bare {bg,ink,accent} skin this must be empty (every
  // slot has a real formula; the compiler is not vacuous). check.mjs gates it.
  const unresolved = SLOTS.filter((s) => values[s] === undefined);
  return { values, native, pinned, unresolved, misses, slots: SLOTS };
}

export default derive;
