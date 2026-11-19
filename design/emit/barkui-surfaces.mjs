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
//            modes for every skin, so the ground is computed, hue and chroma
//            held: in light, base's background stepped down in OKLCH lightness
//            by 0.028 (the BarkUI base's step); in dark, walked down until it
//            stands 1.05:1 off base, stopping at OKLCH lightness 0.04 so the
//            depth steps below it still fit. The well is marked by an inset
//            1px rim in every skin and mode, the mirror of raised's shadow: its
//            own rim role, the hairline walked until it stands 1.25:1 off the
//            base ground (the hairline alone is 1.01:1 there on two dark
//            skins). Its muted and selected fills keep base's lightness offsets
//            from the ground, its muted-foreground is walked until it reads at
//            4.5:1 on that muted fill, and its control edge until 3:1 on the
//            ground; every other role is base's.
//   primary  a brand fill. background is the primary slot, foreground and the
//            strong edges are primary-fg, and --ui-primary flips to primary-fg
//            with primary as its text. border is the ground stepped toward the
//            foreground by base's own border offset. muted, the disabled fill,
//            is the ground walked away from the foreground to 1.2:1, close to
//            the ground and never like the primary fill, and selected one step
//            further (1.44:1), so the foreground gains room on both; muted-foreground is
//            the palest mix of the foreground into the muted fill that reads at
//            4.5:1 on both fills and 3:1 on the ground, so disabled text is
//            readable and clearly weaker than the foreground.
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
// (aaWalk: OKLCH lightness moved, hue and chroma held) moves it until
// destructive reads at 4.5:1 and the fill stands at 3:1 against the ground, and
// a walked fill takes the deriver's on-accent pick (warm white or near ink) as
// its -foreground. Each -text reads at 4.5:1 on the ground.
//
// Each tone also has a soft fill, -soft, for soft controls (a destructive
// button, a soft badge) that draw the tone's -text on it: the tone's hue and
// chroma at a lightness 1.1:1 off the ground, on the side away from the label
// where the lightness range allows (else toward it) and where its hover and
// pressed fit. On every surface a -text that does not read at 4.5:1 on its
// -soft, or on its hover and pressed, is walked until it does (labels give way
// to their fill's states; design/emit/barkui-states.mjs).
//
// On a neutral ground (base, raised, sunken, inverse) a tone's text keeps its
// tone: Studio's hue and most of its chroma. On a brand ground (BRAND_SURFACES)
// status is carried by the fill: there a tone's text only has to read at 4.5:1
// on its soft fill and on the ground, and walking it that far may take most of
// its colour.
//
// On each ground the muted fill and the soft fills sit on one side (sideOf):
// away from the label where every one of them fits there with both its steps,
// else on the label's side. A dark ground has no room below for the muted fill,
// so in dark mode muted sits above the page (not Studio's muted-surface, which
// sits below it), with its muted-foreground walked on it.
//
// Depth is the BarkUI base's: each surface's ground moved in OKLCH lightness by
// n x 0.02 up / 0.022 down (light) or n x 0.045 up / 0.02 down (dark), hue and
// chroma held, for n in -2, -1, 1, 2, 3. In light mode a white ground cannot get
// lighter, so positive depth there equals the ground and the elevation comes
// from the depth shadow, as in the base.

import { aaWalk, contrast, mixOklch, oklchToSrgb, onAccent, parseColor, srgbToOklch, toHslTriplet } from "../derive.mjs";
import { paint, stateNames, statesOf, stepsFor } from "./barkui-states.mjs";

export const SURFACES = ["base", "raised", "sunken", "primary", "inverse"];
export const TONES = ["success", "warning", "danger", "info"];
const TONE_ROLES = TONES.flatMap((t) => [t, `${t}-foreground`, `${t}-text`, `${t}-soft`]);
// Every fill a control can have, with its label and its kind: the primary fill,
// the muted fill a secondary control takes, and each tone's soft fill (a
// destructive control is the danger tone's soft fill). Each gets -hover and
// -pressed (design/emit/barkui-states.mjs).
const STATE_FILLS = [["primary", "primary-foreground", "primary"], ["muted", "foreground", "muted"], ...TONES.map((t) => [`${t}-soft`, `${t}-text`, "soft"])];
export const SURFACE_ROLES = [
  "background", "foreground", "muted", "muted-foreground", "border", "input",
  "primary", "primary-foreground", "ring", "ring-border", "accent", "selected",
  ...TONE_ROLES, "destructive",
  ...STATE_FILLS.flatMap(([fill]) => stateNames(fill)),
];
export const DEPTHS = [-2, -1, 1, 2, 3];
export const depthKey = (n) => (n < 0 ? `m${-n}` : String(n));
// The name a part reads for a role: UI SDK's --ui-* or BarkUI's --bark-*.
const BARK_ROLES = new Set(["accent", "selected", ...TONE_ROLES, ...TONES.flatMap((t) => stateNames(`${t}-soft`))]);
export const pointedName = (role) => (BARK_ROLES.has(role) ? `--bark-${role}` : `--ui-${role}`);

const SUNKEN_LIGHT = 0.028;
const DARK_SUNKEN_STEP = 1.05; // a dark sunken ground off base; its rim does the rest
const RIM_STEP = 1.25; // a sunken well's inset rim off the base ground it is cut into
const SOFT_STEP = 1.1; // a tone's soft fill off its ground: visibly tinted
const SOFT_CHROMA = 0.06; // a soft fill's OKLCH chroma, where the gamut allows it
// The surfaces whose ground is the brand colour, not a neutral one.
export const BRAND_SURFACES = ["primary"];
const MUTED_STEP = 1.2; // the primary surface's disabled fill off its ground
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

// The palest mix of `fg` into `into` that reads at 4.5:1 on every fill and
// 3:1 on `ground`.
function quiet(fg, into, fills, ground) {
  for (let pct = 0; pct <= 100; pct++) {
    const c = css(mixOklch(fg, into, pct));
    if (fills.every((f) => contrast(c, f) >= 4.5) && contrast(c, ground) >= 3) return c;
  }
  return fg;
}

// `ground` walked at its hue and chroma, `dir` (+1 lighter, -1 darker), until it
// stands `target`:1 off itself, or to the end of the lightness range.
function stepOff(ground, dir, target, minL = 0) {
  const { L: l, C, h } = srgbToOklch(ground);
  return css(aaWalk(l, C, h, ground, { target: target + 0.005, step: dir * 0.002, maxIter: 600, minL, maxL: 1 }).rgb);
}

// The side text reads best on `ground`: +1 lighter, -1 darker.
const textSide = (ground) => (contrast("#ffffff", ground) >= contrast("#000000", ground) ? 1 : -1);

// `color` itself if it reads at `target` on `ground`; else the deriver's
// contrast walk at its hue and chroma, toward `prefer` (+1 lighter, -1 darker)
// first, by default away from the ground's lightness. The walk aims a little
// past the target so the written hsl() keeps it.
function walkTo(color, ground, target, prefer) {
  if (Array.isArray(ground)) {
    // Several grounds: walk against each in turn until all pass.
    for (let i = 0; i < 4 && !ground.every((g) => contrast(color, g) >= target); i++)
      for (const g of ground) color = walkTo(color, g, target, prefer);
    return color;
  }
  if (contrast(color, ground) >= target) return color;
  const { L: l, C, h } = srgbToOklch(color);
  const first = prefer ?? (l >= L(ground) ? 1 : -1);
  let best;
  for (const dir of [first, -first]) {
    const r = aaWalk(l, C, h, ground, { target: target + 0.05, step: dir * 0.005, maxIter: 400, minL: 0, maxL: 1 });
    if (r.hit) return css(r.rgb);
    if (!best || r.contrast > best.contrast) best = r;
  }
  return css(best.rgb);
}

// The tone roles and destructive of base `b`, made to read on `ground`. Text
// (each -text, destructive) walks toward the side text reads best on; a fill
// walks to the other side where it can reach 3:1 there.
function tonesOn(b, ground) {
  const side = textSide(ground);
  const out = { destructive: walkTo(b.destructive, ground, 4.5, side) };
  for (const t of TONES) {
    const fill = walkTo(b[t], ground, 3, -side);
    out[t] = fill;
    out[`${t}-foreground`] = fill === b[t] ? b[`${t}-foreground`] : css(parseColor(onAccent(fill).color));
    out[`${t}-text`] = walkTo(b[`${t}-text`], ground, 4.5, side);
  }
  return out;
}

// The side of its ground the soft fills and the muted fill sit on, chosen per
// ground so that every such button on one ground presses the same way: the side
// away from the label if every one of them fits there (its rest fill and both
// steps, hover and pressed); otherwise all of them sit on the label's side.
// Sides are by the painted luminance, as contrast measures them; a candidate
// that paints the same as its ground is on neither side. So on a dark ground,
// where the muted fill has no room below, every one of them sits above.
const lighter = (a, b) => contrast(a, "#000000") > contrast(b, "#000000");
export const sideOfGround = (c, ground) => Math.sign(contrast(paint(c), "#000000") - contrast(paint(ground), "#000000"));
// `fills` maps a role to [kind, candidates]; returns the role -> colour the ground's side picks.
function sideOf(ground, label, fills) {
  const labelSide = sideOfGround(label, ground);
  const pick = (side) => Object.fromEntries(Object.entries(fills).map(([role, [, cs]]) => [role, cs.find((c) => c && sideOfGround(c, ground) === side)]));
  const far = pick(-labelSide), near = pick(labelSide);
  const fits = Object.entries(fills).every(([role, [kind, , solid]]) => far[role] && stepsFor(kind, far[role], ground, solid));
  const out = fits ? far : near;
  for (const [role, c] of Object.entries(out)) if (!c) throw new Error(`barkui: ${role} has no fill on the label's side of its ground`);
  return out;
}

// A tone's soft fill on `ground`, one candidate on each side: the tone's own
// OKLCH hue at chroma SOFT_CHROMA (less where the gamut ends), at the lightness
// that stands SOFT_STEP:1 off the ground. sideOf picks the side.
export function softSides(fill, ground) {
  const { h } = srgbToOklch(fill);
  const at = (dir) => {
    for (let l = L(ground) + dir * 0.002; l >= 0 && l <= 1; l += dir * 0.002) {
      const rgb = oklchToSrgb(l, SOFT_CHROMA, h);
      // the side is the side by luminance, as contrast measures it, not by OKLCH lightness
      if (lighter(rgb, ground) === dir > 0 && contrast(rgb, ground) >= SOFT_STEP + 0.005) return css(rgb);
    }
    return null;
  };
  return [at(-1), at(1)];
}

// A surface with hover and pressed for every control fill. The step is fixed;
// the label gives way: it is walked away from its fill until it reads 4.5:1 on
// rest, hover and pressed, one label for all three.
function withStates(s, at) {
  const out = { ...s };
  for (const [fill, , kind] of STATE_FILLS)
    [out[`${fill}-hover`], out[`${fill}-pressed`]] = statesOf(kind, s[fill], s.background, `${at}: ${fill}`, kind === "soft" ? s[fill.replace(/-soft$/, "")] : undefined);
  for (const [fill, label] of STATE_FILLS) {
    // a label that reads on the ground (a tone's text) keeps reading there too
    const on = [fill, `${fill}-hover`, `${fill}-pressed`].map((n) => out[n]);
    if (contrast(out[label], s.background) >= 4.5) on.push(s.background);
    out[label] = walkLabel(out[label], on, L(out[label]) >= L(out[fill]) ? 1 : -1);
  }
  return out;
}
// A label walked to 4.5:1 on every colour in `on`. Where the walk's colour, as
// painted, turns a tone's text more than half a degree off its hue, the label is
// instead walked in painted steps that keep the hue.
function walkLabel(label, on, dir) {
  const walked = walkTo(label, on, 4.5, dir), { L: l, C, h } = srgbToOklch(label), o = srgbToOklch(paint(walked));
  const off = (a) => { const d = Math.abs(a - h) % 360; return Math.min(d, 360 - d); };
  if (walked === label || o.C < 0.02 || off(o.h) <= 0.5) return walked;
  for (let x = l + dir * 0.001; x >= 0 && x <= 1; x += dir * 0.001) {
    const c = paint(oklchToSrgb(x, C, h));
    if (on.every((g) => contrast(c, paint(g)) >= 4.55) && off(srgbToOklch(c).h) <= 0.5) return css(c);
  }
  return walked;
}
// Surface `s` with its muted fill and each tone's -soft on the side sideOf
// picks for its ground (the muted fill as given, or mirrored across the ground
// by the same lightness). A muted fill that moves has its muted-foreground
// walked on it; on a computed surface (`walk`) a -text that does not read at
// 4.5:1 on its soft fill is walked until it does.
function withSofts(s, walk) {
  const fills = { muted: ["muted", [s.muted, atL(s.muted, 2 * L(s.background) - L(s.muted))]] };
  for (const t of TONES) fills[`${t}-soft`] = ["soft", softSides(s[t], s.background), s[t]];
  const out = { ...s, ...sideOf(s.background, s.foreground, fills) };
  if (out.muted !== s.muted) out["muted-foreground"] = walkTo(s["muted-foreground"], out.muted, 4.5);
  if (walk) for (const t of TONES)
    out[`${t}-text`] = walkTo(s[`${t}-text`], [s.background, out[`${t}-soft`]], 4.5, L(s[`${t}-text`]) >= L(s.background) ? 1 : -1);
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
    const sunkGround = mode === "light"
      ? atL(b.background, L(b.background) - SUNKEN_LIGHT)
      : stepOff(b.background, -1, DARK_SUNKEN_STEP, -DEPTHS[0] * DEPTH_STEP.dark.down);
    const sunkMuted = atL(b.muted, L(sunkGround) + offset("muted"));
    const sunken = {
      ...b,
      background: sunkGround,
      muted: sunkMuted,
      "muted-foreground": walkTo(b["muted-foreground"], sunkMuted, 4.5),
      input: walkTo(b.input, sunkGround, 3),
      // The inset rim that marks the well: the hairline, walked off the base
      // ground the well is cut into until it stands RIM_STEP:1 there.
      rim: walkTo(b.border, b.background, RIM_STEP, textSide(b.background)),
      selected: atL(b.selected, L(sunkGround) + offset("selected")),
      ...tonesOn(b, sunkGround),
    };
    const ground = b.primary, fg = b["primary-foreground"];
    const towardFg = Math.sign(L(fg) - L(ground));
    // Disabled (muted) and selected fills step away from the foreground, so
    // both give its text more room; selected one step past muted.
    const pMuted = stepOff(ground, -towardFg, MUTED_STEP), pSelected = stepOff(ground, -towardFg, MUTED_STEP ** 2);
    const pBorder = atL(ground, L(ground) + towardFg * Math.abs(offset("border")));
    const primary = {
      background: ground, foreground: fg, muted: pMuted, "muted-foreground": quiet(fg, pMuted, [pMuted, pSelected], ground),
      border: pBorder, input: walkTo(pBorder, ground, 3), primary: fg, "primary-foreground": ground,
      ring: primaryRing[mode], "ring-border": fg, accent: fg, selected: pSelected,
      ...tonesOn(b, ground),
    };
    const rg = raisedGround[mode];
    // Raised keeps base's muted offset from its own ground, as sunken does.
    const rMuted = atL(b.muted, L(rg) + offset("muted"));
    const raised = {
      ...b, background: rg, muted: rMuted, "muted-foreground": walkTo(b["muted-foreground"], rMuted, 4.5),
      input: walkTo(b.input, rg, 3), ...tonesOn(b, rg),
    };
    const out = { base: withSofts(b, false), raised: withSofts(raised, true), sunken: withSofts(sunken, true), primary: withSofts(primary, true) };
    for (const s of Object.keys(out)) out[s] = { ...withStates(out[s], `${mode}/${s}`), depth: depths(out[s].background, mode) };
    return out;
  };
  const light = one("light"), dark = one("dark");
  light.inverse = dark.base;
  dark.inverse = light.base;
  return { light, dark };
}
