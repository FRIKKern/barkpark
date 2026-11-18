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
//            fills keep base's lightness offsets from the ground; every other
//            role is base's.
//   primary  a brand fill. background is the primary slot, foreground and the
//            strong edges are primary-fg, and --ui-primary flips to primary-fg
//            with primary as its text. muted, selected and border are the ground
//            stepped toward the foreground by base's own offsets (muted-surface,
//            bg-accent and border against bg); muted-foreground is the palest mix
//            of the foreground into the ground that still reads at 4.5:1.
//   inverse  the other mode's base, role for role: a dark band on a light page
//            and a light band on a dark page, in the skin's own designed values.
//            (The BarkUI base uses the ink as the ground instead; the other
//            mode's palette is the same idea with roles that were designed.)
//
// Depth is the BarkUI base's: each surface's ground moved in OKLCH lightness by
// n x 0.02 up / 0.022 down (light) or n x 0.045 up / 0.02 down (dark), hue and
// chroma held, for n in -2, -1, 1, 2, 3. In light mode a white ground cannot get
// lighter, so positive depth there equals the ground and the elevation comes
// from the depth shadow, as in the base.

import { contrast, mixOklch, oklchToSrgb, srgbToOklch, toHslTriplet } from "../derive.mjs";

export const SURFACES = ["base", "raised", "sunken", "primary", "inverse"];
export const SURFACE_ROLES = [
  "background", "foreground", "muted", "muted-foreground", "border", "input",
  "primary", "primary-foreground", "ring", "ring-border", "accent", "selected",
];
export const DEPTHS = [-2, -1, 1, 2, 3];
export const depthKey = (n) => (n < 0 ? `m${-n}` : String(n));
// The name a part reads for a role: UI SDK's --ui-* or BarkUI's --bark-*.
export const pointedName = (role) => (role === "accent" || role === "selected" ? `--bark-${role}` : `--ui-${role}`);

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
    const sunken = {
      ...b,
      background: sunkGround,
      muted: atL(b.muted, L(sunkGround) + offset("muted")),
      selected: atL(b.selected, L(sunkGround) + offset("selected")),
    };
    const ground = b.primary, fg = b["primary-foreground"];
    const toward = (role) => atL(ground, L(ground) + Math.sign(L(fg) - L(ground)) * Math.abs(offset(role)));
    const pMuted = toward("muted"), pSelected = toward("selected"), pBorder = toward("border");
    const primary = {
      background: ground, foreground: fg, muted: pMuted, "muted-foreground": quiet(fg, ground, [ground, pMuted, pSelected]),
      border: pBorder, input: pBorder, primary: fg, "primary-foreground": ground,
      ring: primaryRing[mode], "ring-border": fg, accent: fg, selected: pSelected,
    };
    const out = { base: b, raised: { ...b, background: raisedGround[mode] }, sunken, primary };
    for (const s of Object.keys(out)) out[s] = { ...out[s], depth: depths(out[s].background, mode) };
    return out;
  };
  const light = one("light"), dark = one("dark");
  light.inverse = dark.base;
  dark.inverse = light.base;
  return { light, dark };
}
