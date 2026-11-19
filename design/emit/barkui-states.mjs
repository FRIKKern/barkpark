// design/emit/barkui-states.mjs — the BarkUI sheet's hover and pressed fills.
// Part of the BarkUI sheet (design/emit/barkui-surfaces.mjs adds these to every
// surface; design/emit/barkui.mjs writes them).
//
// No part and no renderer works out a state colour itself. For every fill a
// control can have, on every surface, the sheet writes <fill>-hover and
// <fill>-pressed. One rule for every case, every reading taken on the 8-bit
// colour a screen paints:
//
//   - Direction, by contrast with the ground: hover and pressed move the fill
//     away from its ground, pressed furthest. Only a fill at the end of the
//     lightness range (the inverted fill on a primary surface) moves toward its
//     ground instead, and then it still stands 3:1 off the ground when pressed.
//     No state is closer to its ground than STATE_GROUND.
//   - Each step (rest to hover, hover to pressed) is visible: at least STEP:1
//     and at least STEP_L in OKLCH lightness. The step is fixed; the label
//     gives way (design/emit/barkui-surfaces.mjs walks it to 4.5:1 on all three).
//   - A state keeps its fill's colour: a soft fill's states keep its OKLCH hue
//     within 1 degree and at least SOFT_FLOOR chroma; a primary fill's keep its
//     hue within 1 degree; a grey muted fill's gain at most GREY_GAIN chroma.

import { contrast, oklchToSrgb, parseColor, srgbToOklch, toHslTriplet } from "../derive.mjs";

export const STEP = 1.12;
export const STEP_L = 0.03;
export const STATE_GROUND = 1.1;
export const SOFT_FLOOR = 0.016;
export const GREY_GAIN = 0.002;
export const stateNames = (fill) => [`${fill}-hover`, `${fill}-pressed`];

/** The 8-bit sRGB colour a screen paints for `c`. */
export const paint = (c) => parseColor(c).map((v) => Math.round(Math.min(1, Math.max(0, v)) * 255) / 255);
const css = (rgb) => `hsl(${toHslTriplet(rgb)})`;
const ok = (c) => srgbToOklch(paint(c));
const hueOff = (a, b) => { const d = Math.abs(a - b) % 360; return Math.min(d, 360 - d); };

/** Whether state `c` keeps the colour of `rest`, for a fill of `kind`. */
export function keepsColour(kind, rest, c) {
  const r = ok(rest), o = ok(c);
  if (kind === "soft") return hueOff(o.h, r.h) <= 1 && o.C >= SOFT_FLOOR;
  if (kind === "muted") return o.C <= r.C + GREY_GAIN;
  return hueOff(o.h, r.h) <= 1;
}

// Two steps from `rest` in direction `dir` (+1 lighter, -1 darker), painted, or
// null where they do not fit.
function twoSteps(kind, rest, ground, dir) {
  const r = ok(rest);
  const out = [];
  let from = paint(rest);
  for (let k = 0; k < 2; k++) {
    let step = null;
    for (let x = srgbToOklch(from).L + dir * 0.0005; x >= 0 && x <= 1; x += dir * 0.0005) {
      const c = paint(oklchToSrgb(x, r.C, r.h));
      if (contrast(c, from) < STEP || Math.abs(srgbToOklch(c).L - srgbToOklch(from).L) < STEP_L) continue;
      if (keepsColour(kind, rest, c)) { step = c; break; }
    }
    if (!step || contrast(step, ground) < STATE_GROUND) return null;
    out.push(step);
    from = step;
  }
  return out;
}

/** Hover and pressed for `rest` on `ground`, as written colours, or null where they do not fit. */
export function stepsFor(kind, rest, ground) {
  const away = contrast(paint(rest), "#000000") >= contrast(paint(ground), "#000000") ? 1 : -1;
  let steps = twoSteps(kind, rest, ground, away);
  if (!steps && contrast(paint(rest), paint(ground)) >= 3) {
    const back = twoSteps(kind, rest, ground, -away);
    if (back && contrast(back[1], paint(ground)) >= 3) steps = back;
  }
  return steps && steps.map(css);
}

/** stepsFor, throwing and naming the case where no step fits. */
export function statesOf(kind, rest, ground, at) {
  const steps = stepsFor(kind, rest, ground);
  if (!steps) throw new Error(`barkui: ${at}: no room for two steps of ${STEP}:1 and ${STEP_L} lightness`);
  return steps;
}
