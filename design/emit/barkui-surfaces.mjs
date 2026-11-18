// design/emit/barkui-surfaces.mjs — the BarkUI sheet's surface and depth values.
// Part of the BarkUI sheet (design/emit/barkui.mjs builds the rules from these).
//
// The BarkUI base has five surfaces a part can sit on, each a full set of the
// colour roles parts read, and five depth steps that move a surface's ground.
// This module works them out per skin and mode from the roles of the base
// surface (the sheet's existing name table), using the deriver's own OKLCH
// helpers. It changes no derived slot.
//
//   base     the skin's own roles, from the name table.
//   raised   a panel lifted off the ground: background is Studio's
//            studioChrome.surface-raised slot; every other role is base's.
//   sunken   a well below the ground. No slot sits below the ground in both
//            modes for every skin, so the ground is computed: base's background
//            stepped down in OKLCH lightness by 0.028 (light) or 0.03 (dark), the
//            BarkUI base's steps, hue and chroma held. Its muted and selected
//            fills keep base's lightness offsets from the ground, and its
//            muted-foreground is walked until it reads at 4.5:1 on that muted
//            fill; every other role is base's.
//   primary  a brand fill. background is the primary slot, foreground and the
//            strong edges are primary-fg, and --ui-primary flips to primary-fg
//            with primary as its text. muted, selected and border are the ground
//            stepped by base's own offsets (muted-surface, bg-accent and border
//            against bg): toward the foreground, or away from it where toward
//            would leave the foreground under 4.5:1 on the fill.
//            muted-foreground is the palest mix of the foreground into the
//            ground that still reads at 4.5:1 on the ground and both fills.
//            input (the control edge) is that border walked toward the
//            foreground with the deriver's contrast walk until it stands at 3:1
//            on the ground; no slot is drawn for the brand ground.
//   inverse  the other mode's base, role for role: a dark band on a light page
//            and a light band on a dark page, in the skin's own designed values.
//            (The BarkUI base uses the ink as the ground instead; the other
//            mode's palette is the same idea with roles that were designed.)
//
// Tones (success, warning, danger, info; each a fill, a -foreground on the
// fill and a -text) and destructive, per surface. Base and inverse use the
// mode's own designed tones. Raised, sunken and primary keep base's tone where
// it passes on their ground; where it does not, the deriver's contrast walk
// (aaWalk: OKLCH lightness moved, hue and chroma held) moves it until -text and
// destructive read at 4.5:1 and the fill stands at 3:1 against the ground, and
// a walked fill takes the deriver's on-accent pick (warm white or near ink) as
// its -foreground.
//
// Depth is the BarkUI base's: each surface's ground moved in OKLCH lightness by
// n x 0.02 up / 0.022 down (light) or n x 0.045 up / 0.02 down (dark), hue and
// chroma held, for n in -2, -1, 1, 2, 3. In light mode a white ground cannot get
// lighter, so positive depth there equals the ground and the elevation comes
// from the depth shadow, as in the base.

import { aaWalk, contrast, mixOklch, oklchToSrgb, onAccent, parseColor, srgbToOklch, toHslTriplet } from "../derive.mjs";

export const SURFACES = ["base", "raised", "sunken", "primary", "inverse"];
export const TONES = ["success", "warning", "danger", "info"];
const TONE_ROLES = TONES.flatMap((t) => [t, `${t}-foreground`, `${t}-text`]);
export const SURFACE_ROLES = [
  "background", "foreground", "muted", "muted-foreground", "border", "input",
  "primary", "primary-foreground", "ring", "ring-border", "accent", "selected",
  ...TONE_ROLES, "destructive",
];
export const DEPTHS = [-2, -1, 1, 2, 3];
export const depthKey = (n) => (n < 0 ? `m${-n}` : String(n));
// The name a part reads for a role: UI SDK's --ui-* or BarkUI's --bark-*.
const BARK_ROLES = new Set(["accent", "selected", ...TONE_ROLES]);
export const pointedName = (role) => (BARK_ROLES.has(role) ? `--bark-${role}` : `--ui-${role}`);

const SUNKEN = { light: 0.028, dark: 0.03 };
const DEPTH_STEP = { light: { up: 0.02, down: 0.022 }, dark: { up: 0.045, down: 0.02 } };
const DARK_FLOOR = 0.145;

const L = (v) => srgbToOklch(v).L;
const css = (rgb) => `hsl(${toHslTriplet(rgb)})`;
// `ref`'s hue and chroma at lightness `l`.
function atL(ref, l) {
  const { C, h } = srgbToOklch(ref);
  return css(oklchToSrgb(Math.min(1, Math.max(0, l)), C, h));
}

function depths(ground, mode) {
  const out = {};
  for (const n of DEPTHS) {
    const d = n > 0 ? n * DEPTH_STEP[mode].up : n * DEPTH_STEP[mode].down;
    const from = mode === "dark" && d > 0 ? Math.max(L(ground), DARK_FLOOR - 0.01) : L(ground);
    out[depthKey(n)] = atL(ground, from + d);
  }
  return out;
}

// The palest mix of `fg` into `ground` that reads at 4.5:1 on every fill.
function quiet(fg, ground, fills) {
  for (let pct = 45; pct <= 100; pct++) {
    const c = css(mixOklch(fg, ground, pct));
    if (fills.every((f) => contrast(c, f) >= 4.5)) return c;
  }
  return fg;
}

// `color` itself if it reads at `target` on `ground`; else the deriver's
// contrast walk at its hue and chroma, away from the ground's lightness first.
// The walk aims a little past the target so the written hsl() keeps it.
function walkTo(color, ground, target) {
  if (contrast(color, ground) >= target) return color;
  const { L: l, C, h } = srgbToOklch(color);
  const first = l >= L(ground) ? 1 : -1;
  let best;
  for (const dir of [first, -first]) {
    const r = aaWalk(l, C, h, ground, { target: target + 0.05, step: dir * 0.005, maxIter: 400, minL: 0, maxL: 1 });
    if (r.hit) return css(r.rgb);
    if (!best || r.contrast > best.contrast) best = r;
  }
  return css(best.rgb);
}

// The tone roles and destructive of base `b`, made to read on `ground`.
function tonesOn(b, ground) {
  const out = {};
  for (const t of TONES) {
    const fill = walkTo(b[t], ground, 3);
    out[t] = fill;
    out[`${t}-foreground`] = fill === b[t] ? b[`${t}-foreground`] : css(parseColor(onAccent(fill).color));
    out[`${t}-text`] = walkTo(b[`${t}-text`], ground, 4.5);
  }
  out.destructive = walkTo(b.destructive, ground, 4.5);
  return out;
}

/**
 * Every surface's roles and depth grounds for one skin.
 * `base[mode]` is { role: css } from the name table; `raisedGround[mode]` is
 * the studioChrome.surface-raised value; `primaryRing[mode]` is primary-fg at
 * the soft-tint alpha. Returns { mode: { surface: { ...roles, depth: { k: css } } } }.
 */
export function surfaceValues(base, raisedGround, primaryRing) {
  const one = (mode) => {
    const b = base[mode];
    const offset = (role) => L(b[role]) - L(b.background);
    const sunkGround = atL(b.background, L(b.background) - SUNKEN[mode]);
    const sunkMuted = atL(b.muted, L(sunkGround) + offset("muted"));
    const sunken = {
      ...b,
      background: sunkGround,
      muted: sunkMuted,
      "muted-foreground": walkTo(b["muted-foreground"], sunkMuted, 4.5),
      selected: atL(b.selected, L(sunkGround) + offset("selected")),
      ...tonesOn(b, sunkGround),
    };
    const ground = b.primary, fg = b["primary-foreground"];
    const towardFg = Math.sign(L(fg) - L(ground));
    const step = (role) => {
      const d = Math.abs(offset(role));
      const toward = atL(ground, L(ground) + towardFg * d);
      return contrast(fg, toward) >= 4.5 ? toward : atL(ground, L(ground) - towardFg * d);
    };
    const pMuted = step("muted"), pSelected = step("selected");
    const pBorder = atL(ground, L(ground) + towardFg * Math.abs(offset("border")));
    const primary = {
      background: ground, foreground: fg, muted: pMuted, "muted-foreground": quiet(fg, ground, [ground, pMuted, pSelected]),
      border: pBorder, input: walkTo(pBorder, ground, 3), primary: fg, "primary-foreground": ground,
      ring: primaryRing[mode], "ring-border": fg, accent: fg, selected: pSelected,
      ...tonesOn(b, ground),
    };
    const raised = { ...b, background: raisedGround[mode], ...tonesOn(b, raisedGround[mode]) };
    const out = { base: b, raised, sunken, primary };
    for (const s of Object.keys(out)) out[s] = { ...out[s], depth: depths(out[s].background, mode) };
    return out;
  };
  const light = one("light"), dark = one("dark");
  light.inverse = dark.base;
  dark.inverse = light.base;
  return { light, dark };
}
