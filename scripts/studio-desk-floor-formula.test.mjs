#!/usr/bin/env node
//
// studio-desk-floor-formula.test.mjs — the red tests for the instrument's
// EXPECTED-FLOOR derivation (spd-w8-followup-in-floor-formula-assumption).
//
// THE DEFECT THESE TESTS EXIST TO KEEP DEAD
//
//   The served floor, read from guerrilla at d10e8d9eb, is
//
//     @container content (min-width: 720px) {
//       .editor-panel .bp-paper-surface {
//         min-inline-size: calc(55ch + 2 * var(--paper-gutter)); } }
//
//   and `--paper-gutter` is redeclared BY VIEWPORT @media on the surface
//   itself: 40px, 24px below 767px, 16px below 479px. The instrument derived
//   its in-floor ch with a hardcoded addend of 80 — which is `2 * 40px`, i.e.
//   correct in the widest band ONLY. At viewport 764 the gutter is 24px, the
//   addend is 48, and subtracting 80 removes 32px too much. That produced the
//   instrument's only three drift warnings, one per face, each of them exactly
//
//     -32 / (55 * probe_px_per_ch)
//
//   = -5.27% georgia, -5.81% native, -6.34% source-serif-4. Not noise, not a
//   font effect, not a formula change: an arithmetic constant that was right
//   in one of three bands.
//
// WHAT IS PROVEN HERE, and why each one earns its place:
//
//   1. THE ADDEND IS READ, NOT WRITTEN. The derivation is EXTRACTED FROM THE
//      INSTRUMENT'S OWN SOURCE and executed against injected computed values.
//      Restoring the hardcoded 80 reddens case 2 — the test is coupled to the
//      code it guards, not to a copy of it.
//   2. IT IS RIGHT IN ALL THREE GUTTER BANDS, against the real numbers from
//      the committed 54-row runs: at 40px the answer is unchanged (this fix
//      moves ZERO published figures), and at 24px the -5.3%/-5.8%/-6.3%
//      divergence collapses to under 0.01%.
//   3. THE EXPECTED FLOOR USES THE PROBE. `55 * probe_px_per_ch + 2 * gutter`,
//      with BOTH inputs measured in the row. A derivation that ignored the
//      probe would still satisfy (1) and (2) and would be useless.
//   4. THE FALLBACK IS ALSO A READ. If `--paper-gutter` ever resolves empty,
//      the addend falls back to the READ padding (D72/D78), never to a
//      literal — and says so in `in_floor_gutter_source`.
//   5. THE PUBLISHED FORMULA STRING NAMES THE TOKEN, so a reader of the
//      artifact is not told `calc(55ch + 80px)` by a run that did not use it.
//
// Pure: no browser, no ssh, no token, no network. The derivation runs as a
// `new Function` over the instrument's own text, so it cannot drift from it.
//
//   node --test scripts/studio-desk-floor-formula.test.mjs

import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const INSTRUMENT = path.join(HERE, 'studio-desk-measure.mjs');
const SRC = fs.readFileSync(INSTRUMENT, 'utf8');

const START = 'const FLOOR_CH_MULTIPLIER = 55;';
const END_ANCHOR = 'const expectedFloorPx';

/** Cut the derivation out of the instrument verbatim. A failure to find it is
 *  itself a finding: the block moved or was renamed, and a test that silently
 *  fell back to its own copy of the arithmetic would prove nothing. */
function extractDerivation(source) {
  const start = source.indexOf(START);
  assert.ok(start >= 0, `derivation start marker not found in the instrument: ${START}`);
  const anchor = source.indexOf(END_ANCHOR, start);
  assert.ok(anchor > start, `derivation end anchor not found: ${END_ANCHOR}`);
  const tail = source.indexOf(': null;', anchor);
  assert.ok(tail > anchor, 'the expectedFloorPx ternary did not end in ": null;"');
  return source.slice(start, tail + ': null;'.length);
}

/** Run the extracted derivation with every one of its inputs INJECTED. The
 *  browser-side names it closes over (`sCs`, `px`, `padL`, `padR`,
 *  `minInlinePx`, `chProbePx`) become parameters; anything else it reaches for
 *  is a ReferenceError, which is the correct outcome for a block that started
 *  depending on something a row does not measure. */
function derive({ gutterToken, padL = 0, padR = 0, minInlinePx, chProbePx, source = SRC }) {
  const body = `${extractDerivation(source)}
    return {
      addend: FLOOR_ADDEND_PX,
      gutter: floorGutterPx,
      gutter_source: floorGutterSource,
      in_floor_px_per_ch: chInFloorPx,
      expected_floor_px: expectedFloorPx,
      container_gate_min_px: FLOOR_CONTAINER_GATE_PX,
    };`;
  // eslint-disable-next-line no-new-func
  const fn = new Function('sCs', 'px', 'padL', 'padR', 'minInlinePx', 'chProbePx', body);
  const sCs = { getPropertyValue: (name) => (name === '--paper-gutter' ? gutterToken : '') };
  const px = (v) => { const n = parseFloat(v); return Number.isFinite(n) ? n : null; };
  return fn(sCs, px, padL, padR, minInlinePx, chProbePx);
}

const driftPct = (inFloor, probe) => ((inFloor - probe) / probe) * 100;

// The three faces at viewport 764 / user-opened, verbatim from the committed
// 54-row run scripts/measurements/spd-instrument-nondeterminism-representative-run-2026-09-06.json
// (gutter 24px there — the surface's own @media (max-width: 767px) band), and
// the same three faces at 1440/900/800 where the gutter is 40px. The probe px/ch
// is IDENTICAL in both bands: the gutter moves the floor, never the font.
const FACES = [
  { face: 'georgia',        probe: 11.0479, wide_min_inline: 687.632, narrow_min_inline: 655.632 },
  { face: 'native',         probe: 10.0107, wide_min_inline: 630.591, narrow_min_inline: 598.591 },
  { face: 'source-serif-4', probe:  9.1799, wide_min_inline: 584.897, narrow_min_inline: 552.897 },
];

test('the addend is READ from --paper-gutter, never a literal', () => {
  const slice = extractDerivation(SRC);
  assert.match(slice, /getPropertyValue\('--paper-gutter'\)/,
    'the derivation must read the --paper-gutter custom property from computed style');
  assert.match(slice, /const FLOOR_ADDEND_PX = 2 \* floorGutterPx;/,
    'the addend must be twice the READ gutter');
  assert.doesNotMatch(slice, /FLOOR_ADDEND_PX\s*=\s*[\d.]+\s*;/,
    'a numeric-literal addend is the exact defect this suite exists to keep dead');
  // The 40px band's addend is 80 and always was. The point is that 80 is now
  // COMPUTED there, not written down anywhere.
  assert.doesNotMatch(slice, /\b80\b\s*;/, 'no bare 80 addend may survive in the derivation');
});

test('the 24px band: the -5.3%/-5.8%/-6.3% divergence was the hardcoded 80, and it is gone', () => {
  for (const f of FACES) {
    const got = derive({ gutterToken: '24px', minInlinePx: f.narrow_min_inline, chProbePx: f.probe });
    assert.equal(got.gutter, 24, `${f.face}: gutter read`);
    assert.equal(got.addend, 48, `${f.face}: addend is 2 * 24px, not 80`);

    const drift = driftPct(got.in_floor_px_per_ch, f.probe);
    assert.ok(Math.abs(drift) < 0.01,
      `${f.face} at 764/user-opened: in-floor ch ${got.in_floor_px_per_ch} vs probe ${f.probe} ` +
      `is ${drift.toFixed(4)}% — expected under 0.01%`);

    // And the counterfactual, computed here rather than asserted from memory:
    // the old constant reproduces the warning that was filed, to the digit.
    const stale = (f.narrow_min_inline - 80) / 55;
    const staleDrift = driftPct(stale, f.probe);
    assert.ok(staleDrift < -5 && staleDrift > -7,
      `${f.face}: the hardcoded 80 should still reproduce the filed warning, got ${staleDrift}%`);
    // -32px over the whole 55ch span IS the entire effect. Nothing font-related.
    assert.ok(Math.abs(staleDrift - (-32 / (55 * f.probe)) * 100) < 0.001,
      `${f.face}: the stale drift must be exactly -32 / (55 * probe)`);
  }
});

test('the 40px band is unchanged — this fix moves zero published figures', () => {
  for (const f of FACES) {
    const got = derive({ gutterToken: '40px', minInlinePx: f.wide_min_inline, chProbePx: f.probe });
    assert.equal(got.addend, 80, `${f.face}: 2 * 40px is still 80 — computed, not written`);
    const drift = driftPct(got.in_floor_px_per_ch, f.probe);
    assert.ok(Math.abs(drift) < 0.01,
      `${f.face} at the wide gutter: ${drift.toFixed(4)}% — expected under 0.01%`);
  }
});

test('the 16px band (below 479px) resolves too — no width in the sweep reaches it, the arithmetic must still hold', () => {
  const got = derive({ gutterToken: '16px', minInlinePx: 55 * 10 + 32, chProbePx: 10 });
  assert.equal(got.addend, 32);
  assert.equal(got.in_floor_px_per_ch, 10);
});

test('the expected floor is 55 * PROBE + 2 * READ gutter — both inputs measured in the row', () => {
  const a = derive({ gutterToken: '24px', minInlinePx: 655.632, chProbePx: 11.0479 });
  assert.ok(Math.abs(a.expected_floor_px - (55 * 11.0479 + 48)) < 1e-9);
  assert.ok(Math.abs(a.expected_floor_px - 655.632) < 0.01,
    `the derived floor must land on the resolved one: ${a.expected_floor_px} vs 655.632`);

  // Move ONLY the probe: a derivation that ignored it would not budge.
  const b = derive({ gutterToken: '24px', minInlinePx: 655.632, chProbePx: 9.1799 });
  assert.notEqual(a.expected_floor_px, b.expected_floor_px);
  assert.ok(Math.abs(b.expected_floor_px - (55 * 9.1799 + 48)) < 1e-9);

  // Move ONLY the gutter: same.
  const c = derive({ gutterToken: '40px', minInlinePx: 687.632, chProbePx: 11.0479 });
  assert.equal(c.expected_floor_px - a.expected_floor_px, 32);
});

test('a missing --paper-gutter falls back to the READ padding, never to a literal', () => {
  const got = derive({ gutterToken: '', padL: 24, padR: 24, minInlinePx: 655.632, chProbePx: 11.0479 });
  assert.equal(got.gutter, 24);
  assert.equal(got.addend, 48);
  assert.match(got.gutter_source, /fallback/i);
  assert.match(got.gutter_source, /padding/i);
  assert.ok(Math.abs(driftPct(got.in_floor_px_per_ch, 11.0479)) < 0.01);

  const token = derive({ gutterToken: '24px', padL: 24, padR: 24, minInlinePx: 655.632, chProbePx: 11.0479 });
  assert.match(token.gutter_source, /--paper-gutter/);
  assert.doesNotMatch(token.gutter_source, /fallback/i);
});

test('the published formula string names the token, and the container gate is the served 720px', () => {
  assert.match(SRC, /in_floor_formula_assumed: \\`calc\(\\\$\{FLOOR_CH_MULTIPLIER\}ch \+ 2 \* var\(--paper-gutter\)\)\\`/,
    'the artifact must publish the served formula shape, not calc(55ch + 80px)');
  assert.doesNotMatch(SRC, /calc\(\\\$\{FLOOR_CH_MULTIPLIER\}ch \+ \\\$\{FLOOR_ADDEND_PX\}px\)/,
    'the old px-addend formula string must not survive');
  const got = derive({ gutterToken: '24px', minInlinePx: 655.632, chProbePx: 11.0479 });
  assert.equal(got.container_gate_min_px, 720,
    'the floor lives inside @container content (min-width: 720px) — the gate value is served, not chosen');
});

test('a zero floor derives nothing — a closed container gate is not a measurement', () => {
  // Where the gate is closed the declaration never applies and min-inline-size
  // resolves to 0px. That is the reason two thirds of the matrix cannot emit a
  // drift warning at all, and it must stay a null rather than a number.
  const got = derive({ gutterToken: '24px', minInlinePx: 0, chProbePx: 11.0479 });
  assert.equal(got.in_floor_px_per_ch, null);
});
