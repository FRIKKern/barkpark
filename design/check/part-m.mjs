// design/check/part-m.mjs — Part M of design/check.mjs, the W1.2 drift gate.
// design/check.mjs runs every design/check/part-*.mjs in order; this module runs
// its Part when imported. Moved out of check.mjs with no change in behaviour.

import { RULE_KEYS, RULE_UNITS, tokens } from "../emit.mjs";
import { bumpFailed, FAULT } from "./state.mjs";
import { LEDGER_MARKER, readDesignSource } from "./part-e.mjs";

// ── Part M: the RULE LADDER — one weight for structure, one for everything ───
// space.rule emits `--tok-rule-hairline`, each surface bridges it onto
// `--bp-rule-hairline`, and the rules that draw chrome spend it. That is Part J's
// shape and Part J's shape alone would be satisfied by a stylesheet where the
// token is consumed in one place and every OTHER line still draws 2px from a
// literal — which is precisely the state this part was written to end.
//
// So Part M has a second arm the other consumer censuses do not: it reads every
// HORIZONTAL border declaration in both stylesheets and refuses any literal at or
// above the structural weight, wherever it appears. That is the arm that can see
// what a photograph cannot. The rig's census (tooling/paper-excellence/rig/shoot.mjs)
// counts the rules that PAINT on the seven committed fixtures — authoritative
// about what ships, and blind to a heavy rule on a class no fixture happens to
// render. `.bp-board__col` was exactly that: a 3px accent across a task board, in
// none of the seven papers. Neither arm subsumes the other; a declaration census
// alone would miss an inline style, a rendered census alone would miss this.
//
// VERTICAL edges are deliberately not censused. A left edge is a margin accent —
// the verdict colour `.bp-callout`, `.bp-card` and `.bp-board__col` all carry, and
// the benchmark artifact's own `border-left: 3px` device — and it cannot compete
// with a horizontal boundary because it does not draw a horizontal line.
console.log("\ndesign/check.mjs — Part M: rule-ladder consumer census + heavy-declaration scan");
{
  let mFailed = 0;
  const mFail = (m) => { console.error(m); mFailed++; bumpFailed(); };

  const RULE_SURFACES = [
    "api/assets/paper-surface/paper-surface.css",
    "api/assets/paper-editor/src/styles.css",
  ];

  // ── arm 1: the token reaches a real consumer on both surfaces ──────────────
  for (const path of RULE_SURFACES) {
    const css = readDesignSource(path);
    for (const key of RULE_KEYS) {
      const value = `${tokens.space.rule[key]}${RULE_UNITS[key]}`;
      if (!css.includes(`--tok-rule-${key}: ${value};`))
        mFail(`  Part M FAIL: --tok-rule-${key} is not emitted as ${value} in ${path}`);
      if (!css.includes(`--bp-rule-${key}: var(--tok-rule-${key});`))
        mFail(`  Part M FAIL: --bp-rule-${key} has no bridge onto --tok-rule-${key} in ${path}`);
      const read = css
        .split("\n")
        .some((l) => l.includes(`var(--bp-rule-${key}`) && !l.includes(`--bp-rule-${key}: var(`));
      if (!read)
        mFail(
          `  Part M FAIL: --bp-rule-${key} is emitted and bridged in ${path} but NOTHING consumes it.\n` +
            `    Every chrome rule on this surface is then drawing a hardcoded weight, which is the\n` +
            `    drift the token exists to prevent. Spend it, or drop it from space.rule + RULE_KEYS.`,
        );
    }
  }

  // ── arm 2: no horizontal border literal at or above the structural weight ──
  // Only the section head may declare one, and it declares it through
  // `--bp-section-rule` rather than a literal, so the allowlist is empty by
  // construction: there is no legitimate literal.
  const HEAVY_PX = tokens.space.section.rule;
  // `border`, `border-top`, `border-bottom` and their `-width` forms. NOT
  // `border-left/right` (a margin accent is not a rule), and not `border-radius`
  // — the `(?![a-z-])` is what keeps `radius`, `color` and `style` out.
  const HORIZONTAL_BORDER = /border(?:-top|-bottom)?(?:-width)?(?![a-z-])\s*:\s*([^;}]*)/g;
  for (const path of RULE_SURFACES) {
    const css = readDesignSource(path).replace(/\/\*[\s\S]*?\*\//g, " ");
    for (const [, selector, body] of css.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
      for (const [decl, value] of body.matchAll(HORIZONTAL_BORDER)) {
        const px = /(\d*\.?\d+)px/.exec(value);
        if (!px || parseFloat(px[1]) < HEAVY_PX) continue;
        mFail(
          `  Part M FAIL: ${path} declares a ${px[1]}px HORIZONTAL rule outside the section head:\n` +
            `      ${selector.trim().replace(/\s+/g, " ").slice(0, 110)}\n` +
            `        ${decl.trim().slice(0, 90)}\n` +
            `    ${HEAVY_PX}px is the STRUCTURAL weight (space.section.rule) and a section boundary is the\n` +
            `    only thing allowed to spend it — a component drawing at that weight makes the boundary\n` +
            `    stop meaning anything. Use var(--bp-rule-hairline) for chrome; if the line carries a\n` +
            `    VERDICT rather than structure, put it on the left edge where .bp-callout and .bp-card\n` +
            `    already carry theirs, and it leaves this census by being vertical.`,
        );
      }
    }
  }

  if (FAULT.has("M")) mFail("  Part M FAIL: injected fault (--selftest)");
  if (!mFailed)
    console.log(
      `  ok   --tok-rule-hairline emitted, bridged and consumed on both surfaces, and neither stylesheet ` +
        `declares a horizontal border at or above the ${HEAVY_PX}px structural weight`,
    );
}

// Newline-preserving noise blanker for Part N. Deliberately SEPARATE from Part
// E's stripLedgerNoise: this ledger also reads `.ex` (the login page's CSS lives
// in a heredoc) and `.html` (the styleguide), and teaching the shared helper
// those extensions would silently move every frozen COLOUR baseline.
const motionBlank = (m) => m.replace(/[^\n]/g, " ");
// Comments only. Arm 1 uses this one and NOT the generated-region blanker, for the
// obvious reason that the declarations it is looking for live inside those regions.
function motionBlankComments(text, path) {
  let s = text.replace(/\/\*[\s\S]*?\*\//g, motionBlank); // CSS / <style> block comments
  if (/\.(heex|html)$/.test(path)) {
    s = s
      .replace(/<!--[\s\S]*?-->/g, motionBlank)
      .replace(/<%!--[\s\S]*?--%>/g, motionBlank)
      .replace(/<%#[\s\S]*?%>/g, motionBlank);
  }
  return s;
}
// Arm 2 additionally blanks every BEGIN/END GENERATED region: a duration the
// emitter wrote is not a hand-stamp.
const motionBlankAll = (text, path) =>
  motionBlankComments(text.replace(LEDGER_MARKER, motionBlank), path);

export { motionBlankAll, motionBlankComments };
