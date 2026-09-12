// width-drivers.mjs — WHICH LEGS DRIVE A WIDTH, RECOUNTED FROM THE AXES.
//
// ── THE DEFECT (task-72ffb2fdecffd2d3) ──────────────────────────────────────
// overflow-guard.mjs's W26-instance-track-min-content leg printed, on EVERY
// CLEAN RUN, an okLine ending:
//
//     "1280 is driven by NO other instrument in this repo: the defect outlived
//      every band swept above, and a sweep stopping at 1024 certifies a desktop
//      that is still dragging"
//
// and asserted the same in its header comment ("1280 APPEARS IN NO INSTRUMENT
// IN THIS REPO TODAY — this leg is the first to drive it"). Both halves were
// false, and the counter-example was in the same file:
//
//   * `const FLICK_VIEWPORTS = [[320, 568], [390, 844], [1280, 900]];` in the
//     W27-failed-retry-reachable-after-flick leg has driven 1280x900 since
//     7c8fa229a, 2026-08-03 — thirty-nine days before the sentence. That leg
//     even carries an AXIS CHECK that REFUSES if 1280x900 ever leaves the set,
//     so the repo hard-guards a 1280 driver while another leg prints that
//     nothing drives 1280.
//   * Six axes in the same file sweep ABOVE 1280 (all to 1440). The band that
//     "stops at 1024" is one axis among many, not the file's ceiling.
//
// ── WHY A MODULE AND NOT A CORRECTED SENTENCE ───────────────────────────────
// breakpoint-sweep.mjs (grep -n 'A COMMENT CANNOT BE DERIVED' breakpoint-sweep.mjs)
// — "A COMMENT CANNOT BE DERIVED, only RECOUNTED by an
// arm that reads these bytes." Retyping the true names today buys one correct
// run and the identical rot: the next axis edit puts the sentence back where it
// was, silently, on a green run, in the prose a reviewer quotes to justify
// dropping a band. So the sentence is COMPUTED from the axes at print time, and
// the arms below recount the computation.
//
// ── THE BLINDNESS THAT PRODUCED THE ORIGINAL SENTENCE ───────────────────────
// A reader looking for 1280 in `const *_WIDTHS` arrays finds ONE hit and
// concludes nothing else drives it. FLICK_VIEWPORTS is `[[w, h], ...]` — a
// PAIR axis — and the height-varying legs all use that shape. A widths-only
// parser reproduces the exact false negative, which is why `parseAxes` handles
// both shapes and why the suite has an arm that reds if pair support is removed.

/** One declared viewport axis found in an instrument's source. */
class Axis {
  constructor({ name, leg, widths, pairs, line }) {
    this.name = name;
    this.leg = leg;           // the `const D = "..."` this sits inside, or null for module scope
    this.widths = widths;     // every WIDTH the axis drives, pair axes included
    this.pairs = pairs;       // [[w, h], ...] when the axis is pair-shaped, else null
    this.line = line;         // 1-indexed, so a refusal can point at it
  }
  /** How this axis drives a width, phrased for a human: "1280x900" or "1280". */
  cellFor(width) {
    if (!this.pairs) return String(width);
    const p = this.pairs.find(([w]) => w === width);
    return p ? `${p[0]}x${p[1]}` : String(width);
  }
  get max() { return this.widths.length ? Math.max(...this.widths) : 0; }
}

// THE PREFIX IS OPTIONAL, AND THAT IS A MEASURED CORRECTION, not a nicety: the
// file's PRIMARY axis is named bare `WIDTHS` (the module-level default, max
// 1440). A pattern written `[A-Z][A-Z0-9_]*(?:WIDTHS|VIEWPORTS)` requires at
// least one character before the suffix and therefore misses exactly that one —
// this derivation reported five axes above 1280 instead of six until the `_`
// group was made optional. A naming convention is not a guarantee, and the arm
// "the bare `WIDTHS` axis is found" is what keeps this honest.
const AXIS_DECL = /^(\s*)const ((?:[A-Z][A-Z0-9_]*_)?(?:WIDTHS|VIEWPORTS))\s*=\s*(\[[^;]*\]);/;
const LEG_DECL = /^\s*const D = "([^"]+)";/;

/**
 * Every width/viewport axis an instrument declares, in source order.
 *
 * SCOPE IS READ FROM THE INDENTATION, not from "the last `const D` above".
 * A module-level axis starts at column 0; a leg's axis is indented inside its
 * `if (requested.includes(...))` block. Keying on the nearest preceding `const
 * D` would attribute every module-level axis declared after the first leg to
 * that leg — a misattribution nobody would ever see, because the printed
 * sentence would still look plausible.
 *
 * @param {string} src  the instrument's source text
 * @returns {Axis[]}
 */
export function parseAxes(src) {
  const out = [];
  let leg = null;
  const lines = String(src).split("\n");
  for (let i = 0; i < lines.length; i++) {
    const legHit = LEG_DECL.exec(lines[i]);
    if (legHit) { leg = legHit[1]; continue; }
    const m = AXIS_DECL.exec(lines[i]);
    if (!m) continue;
    const [, indent, name, literal] = m;
    const parsed = readLiteral(literal);
    if (!parsed) continue;
    out.push(new Axis({
      name,
      leg: indent.length ? leg : null,
      widths: parsed.widths,
      pairs: parsed.pairs,
      line: i + 1,
    }));
  }
  return out;
}

/** `[320, 390]` -> widths; `[[320, 568], [1280, 900]]` -> widths + pairs; else null. */
function readLiteral(literal) {
  const pairs = [...literal.matchAll(/\[\s*(\d+)\s*,\s*(\d+)\s*\]/g)].map((m) => [Number(m[1]), Number(m[2])]);
  if (pairs.length) return { widths: pairs.map(([w]) => w), pairs };
  const body = literal.slice(1, -1).trim();
  if (!body) return null;
  const nums = body.split(",").map((t) => t.trim()).filter(Boolean);
  if (!nums.every((t) => /^\d+$/.test(t))) return null;   // not a numeric axis
  return { widths: nums.map(Number), pairs: null };
}

/**
 * Who ELSE drives `width`, and what is swept above it.
 *
 * @param {string} src
 * @param {number} width
 * @param {string} selfAxis  the asking leg's own axis name, excluded from "else"
 * @returns {{ drivers: Axis[], above: Axis[], width: number }}
 */
export function widthDrivers(src, width, selfAxis) {
  const axes = parseAxes(src);
  return {
    width,
    drivers: axes.filter((a) => a.name !== selfAxis && a.widths.includes(width)),
    above: axes.filter((a) => a.name !== selfAxis && a.max > width),
  };
}

/**
 * The SENTENCE — built from the report, never typed.
 *
 * It is deliberately willing to say the honest negative: given a width nothing
 * else drives and nothing sweeps above, it says so, in the same shape. The
 * original claim was not wrong for being a negative; it was wrong for being a
 * negative nobody recounted.
 */
export function driverSentence({ width, drivers, above }) {
  const named = drivers.length
    ? `${width} is ALSO driven by ${drivers.length} other axis/axes in this file: ` +
      drivers.map((a) => `${a.name}:${a.line} (${a.leg || "module scope"}, ${a.cellFor(width)})`).join(", ")
    : `${width} is driven by NO other axis in this file`;
  const ceiling = above.length
    ? `${above.length} axis/axes sweep above ${width} (to ${Math.max(...above.map((a) => a.max))}px): ` +
      above.map((a) => `${a.name}:${a.line}`).join(", ")
    : `no axis in this file sweeps above ${width}`;
  return `${named}; ${ceiling}. Both halves are RECOUNTED from the declared axes on every run, never typed`;
}
