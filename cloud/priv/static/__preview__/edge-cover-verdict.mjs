// edge-cover-verdict.mjs — the W12 edge probe's SENTENCE, chosen from the
// measurement instead of from the leg's original defect.
//
// ── WHY THIS IS A SEPARATE MODULE ────────────────────────────────────────────
// Same reason font-pin / bringup-retry / ready-host-paint / width-drivers /
// defect-selection are siblings: the verdict is pure arithmetic over numbers
// the browser already handed back, so it can be DRIVEN WITHOUT A BROWSER. Both
// arms below have a fixture in ./edge-cover-verdict.test.mjs, and a mutation
// that swaps one condition reds there in under a second — which is the only
// way anybody was ever going to notice that the sentence and the mechanism had
// come apart.
//
// ── THE DEFECT THIS EXISTS TO NOT REPEAT (task-ca6e4c883c85e854) ─────────────
// FOUND 2026-09-10 while landing #17203 (a ninth notification-matrix row). The
// Console gate's "Overflow guard (rendered)" leg W12-narrow-viewport-truth
// failed SIX cells with one hard-typed sentence:
//
//   "2px below the top of the 55px header cell the label column is covered by
//    "topbar-scope", not .set-matrix-corner — a corner shorter than the
//    TALLEST column leaves the heading scrolling through above it"
//
// The sentence names ONE mechanism (corner height). The probe fired for
// ANOTHER. Instrumented control run over the same commit range: cornerH ==
// headH == 55 on BOTH main and the branch, all six midpoint probes hit the
// corner, probeMiss 0 — the corner was never short. What moved was `tall.top`
// AFTER the guard's own `scrollIntoView({block:'center'})`: a matrix 56px
// taller centres 28px higher, and its header row slid UNDER the sticky 56px
// `.topbar` (tall.top 69.5 -> 41.5). The covering element's class name said so
// out loud — "topbar-scope" — and the sentence talked about the corner anyway.
//
// The remedy that landed was `scroll-margin-top: 56px` on `.set-matrix`
// (0e1cb6d2b), not a taller corner. A builder who believed the message would
// have grown the corner; the first remedy the lead offered (shorten the new
// label) could not have worked at ANY width, because the overlap is a scroll
// position, not a text length.
//
// ── THE RULE ─────────────────────────────────────────────────────────────────
// The probe distinguishes two mechanisms and is allowed to name each one ONLY
// on its own measured condition:
//
//   corner shorter than the tallest column     iff  cornerH < headH
//   header scrolled under the sticky topbar    iff  tall.top < topbar bottom
//
// Both true at once is NOT a licence to pick the prettier one — it is an
// admission that this probe cannot attribute the cover, and it says so.
// Neither true is the same admission from the other side: something else is
// painted over the label column and the measurement does not name it. In every
// arm the numbers that decided the verdict are printed, so the next reader
// re-derives the choice instead of trusting it.
//
// The TOLERANCE is the guard's own, 0.5px, matching the `cornerH < headH - 0.5`
// height arm three lines above the call site: sub-pixel layout noise must not
// flip which mechanism a red accuses.

const EPS = 0.5;

const num = (v) => (typeof v === "number" && Number.isFinite(v) ? v : null);
const r2 = (v) => Math.round(v * 100) / 100;

/**
 * Is the probe point covered by the corner at all?
 *
 * Kept here rather than inline at the call site so the test suite drives the
 * SAME predicate the guard does — a second copy of `.includes(...)` is a second
 * thing to get wrong.
 *
 * @param {string} edge the className/tagName elementFromPoint named
 */
export function edgeCovered(edge) {
  return String(edge || "").includes("set-matrix-corner");
}

/**
 * Which mechanisms does the measurement support?
 *
 * @param {object} m
 * @param {number} m.cornerH   .set-matrix-corner border-box height
 * @param {number} m.headH     the TALLEST column's height (the header row)
 * @param {number} m.tallTop   that column's viewport-space top
 * @param {number|null} m.topbarBottom  sticky .topbar bottom, null if no topbar
 * @returns {{cornerShort: boolean, underTopbar: boolean|null}}
 */
export function edgeMechanisms({ cornerH, headH, tallTop, topbarBottom }) {
  const ch = num(cornerH);
  const hh = num(headH);
  const tt = num(tallTop);
  const tb = num(topbarBottom);
  return {
    cornerShort: ch !== null && hh !== null ? ch < hh - EPS : null,
    // A page with no `.topbar` is not a page where the topbar demonstrably did
    // not cover anything — it is a page this half was never measured on. null,
    // not false: an unmeasured condition must not read as a cleared one.
    underTopbar: tt !== null && tb !== null ? tt < tb - EPS : null,
  };
}

/**
 * THE SENTENCE.
 *
 * Returns null when the probe point IS covered by the corner (nothing to say),
 * otherwise the failure text minus the caller's `scen/theme@width: ` prefix.
 *
 * Every arm prints the same measurement block first — covering element, probe
 * y, topbar bottom, tall.top, scrollY, corner vs tallest column — and only then
 * names a mechanism, so the reader can check the choice against the numbers
 * that made it.
 *
 * @param {object} m
 * @param {string} m.edge      what elementFromPoint named at the probe point
 * @param {number} m.probeY    the y it was asked about (tall.top + 2)
 * @param {number} m.tallTop
 * @param {number|null} m.topbarBottom
 * @param {number} m.cornerH
 * @param {number} m.headH
 * @param {number} m.scrollY   window.scrollY at the moment of the probe
 * @param {boolean|null} [m.edgeInTopbar] does the covering element sit inside .topbar
 * @returns {string|null}
 */
export function edgeCoverSentence(m) {
  if (edgeCovered(m.edge)) return null;

  const { cornerShort, underTopbar } = edgeMechanisms(m);
  const tb = num(m.topbarBottom);
  const inBar =
    m.edgeInTopbar === true ? ", and that element IS inside .topbar" :
    m.edgeInTopbar === false ? ", and that element is NOT inside .topbar" : "";

  const measured =
    `at y=${r2(m.probeY)} (2px below the top of the ${r2(m.headH)}px header row) the label column is covered by ` +
    `"${m.edge}"${inBar}, not .set-matrix-corner — MEASURED: tall.top ${r2(m.tallTop)}, ` +
    `sticky .topbar bottom ${tb === null ? "ABSENT (unmeasured)" : r2(tb)}, ` +
    `scrollY ${r2(m.scrollY)}, corner ${r2(m.cornerH)}px vs tallest column ${r2(m.headH)}px`;

  if (cornerShort && underTopbar) {
    return `${measured}. BOTH mechanisms measure TRUE — the corner is shorter than the tallest column ` +
      `(${r2(m.cornerH)} < ${r2(m.headH)}) AND the header row sits above the topbar's bottom edge ` +
      `(tall.top ${r2(m.tallTop)} < ${r2(tb)}). This probe CANNOT tell which one covers the point; ` +
      `clear the topbar overlap (scroll-margin-top on .set-matrix) and re-run before touching the corner`;
  }
  if (cornerShort) {
    return `${measured}. MECHANISM: the corner is shorter than the TALLEST column ` +
      `(cornerH ${r2(m.cornerH)} < headH ${r2(m.headH)}), so the heading scrolls through above it. ` +
      `The topbar is NOT over this point (tall.top ${r2(m.tallTop)} >= topbar bottom ` +
      `${tb === null ? "n/a" : r2(tb)}) — grow the corner, not the scroll position`;
  }
  if (underTopbar) {
    return `${measured}. MECHANISM: the header row is SCROLLED UNDER THE STICKY TOPBAR ` +
      `(tall.top ${r2(m.tallTop)} < topbar bottom ${r2(tb)}) — this guard's own ` +
      `scrollIntoView({block:'center'}) centres a taller matrix higher, and the sticky .topbar is ` +
      `painted over the header row. The corner is INNOCENT: ${r2(m.cornerH)}px covers the full ` +
      `${r2(m.headH)}px row. The fix is scroll-margin-top on .set-matrix, NOT a taller corner`;
  }
  return `${measured}. NEITHER mechanism measures true — ` +
    (cornerShort === null
      ? `the corner half was NOT MEASURED (no corner/column height came back)`
      : `the corner covers the full header row (${r2(m.cornerH)} >= ${r2(m.headH)})`) +
    ` and ` +
    (underTopbar === null
      ? `the topbar half was NOT MEASURED (no .topbar on the page), so the overlap cannot be ruled out`
      : `the header row is at or below the topbar's bottom edge (tall.top ${r2(m.tallTop)} >= ${r2(tb)})`) +
    `. This probe CANNOT NAME the mechanism: something else is painted over the label column here — ` +
    `read "${m.edge}" and do not assume either mechanism`;
}
