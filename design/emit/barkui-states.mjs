// design/emit/barkui-states.mjs — the BarkUI sheet's hover and pressed fills.
// Part of the BarkUI sheet (design/emit/barkui-surfaces.mjs adds these to every
// surface; design/emit/barkui.mjs writes them).
//
// No part and no renderer works out a state colour itself. For every fill a
// control can have, on every surface, the sheet writes <fill>-hover and
// <fill>-pressed. One rule for every case:
//
//   - Each step stands STATE_STEP:1 off the one before: rest, hover, pressed,
//     all in one direction, pressed furthest.
//   - The direction deepens the fill (moves it further from its ground) when
//     both steps fit that way; otherwise the steps move back toward the
//     ground. A step fits when it stays in the lightness range, its label still
//     reads at 4.5:1 on it, and a fill that stands 3:1 off its ground at rest
//     still does. The label never changes per state.
//   - A state keeps the fill's OKLCH hue and chroma (chroma only drops where
//     the sRGB gamut ends); only lightness moves. A step whose written colour
//     drifts off the hue (near black or white) does not fit.
//
// STATE_STEP sits under the most every case can hold, about 1.07:1. That limit is
// set by evergreen's light raised info soft fill: its label reads 5.18:1 on it,
// and a soft fill deepens toward its label, so two steps get 5.18 / 4.5 of room.

import { contrast, oklchToSrgb, srgbToOklch, toHslTriplet } from "../derive.mjs";

export const STATE_STEP = 1.06;
// A label needs this much contrast on a fill to leave room for both steps
// toward it: 4.5:1 after two steps, with a margin for the steps' rounding.
export const LABEL_ROOM = 4.5 * (STATE_STEP + 0.004) ** 2;
export const stateNames = (fill) => [`${fill}-hover`, `${fill}-pressed`];
// Under this OKLCH chroma a fill is neutral: it has no hue to keep.
export const HUED = 0.02;

const L = (v) => srgbToOklch(v).L;
const css = (rgb) => `hsl(${toHslTriplet(rgb)})`;

// Two steps from `rest` in direction `dir` (+1 lighter, -1 darker), or null
// where they do not fit.
function twoSteps(rest, label, ground, dir) {
  const { C, h } = srgbToOklch(rest);
  const edged = contrast(rest, ground) >= 3;
  // Near black or white a written hsl() can drift off the hue; a step more than 1 degree off does not fit.
  const offHue = (c) => { const d = Math.abs(srgbToOklch(c).h - h); return C >= HUED && Math.min(d, 360 - d) > 1; };
  const out = [];
  let from = rest, l = L(rest);
  for (let k = 0; k < 2; k++) {
    let step = null;
    for (let x = l + dir * 0.001; x >= 0 && x <= 1; x += dir * 0.001) {
      const c = css(oklchToSrgb(x, C, h));
      if (contrast(c, from) >= STATE_STEP) { step = { c, x }; break; }
    }
    if (!step || contrast(label, step.c) < 4.5 || (edged && contrast(step.c, ground) < 3) || offHue(step.c)) return null;
    out.push(step.c);
    from = step.c;
    l = step.x;
  }
  return out;
}

/**
 * Surface `s` with <fill>-hover and <fill>-pressed added for each [fill, label]
 * in `fills`. Throws, naming the case, where neither direction fits.
 */
export function withStates(s, fills, at) {
  const out = { ...s };
  for (const [fill, label] of fills) {
    const rest = s[fill], ground = s.background;
    const deepen = L(rest) >= L(ground) ? 1 : -1;
    const steps = twoSteps(rest, s[label], ground, deepen) ?? twoSteps(rest, s[label], ground, -deepen);
    if (!steps) throw new Error(`barkui: ${at}: ${fill} has no room for a hover and a pressed step of ${STATE_STEP}:1 under its label ${label}`);
    [out[`${fill}-hover`], out[`${fill}-pressed`]] = steps;
  }
  return out;
}
