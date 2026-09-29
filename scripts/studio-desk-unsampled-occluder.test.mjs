#!/usr/bin/env node
//
// studio-desk-unsampled-occluder.test.mjs — the committed proof that the desk
// instrument can name an occluder its five scanlines stepped over.
//
//   THIS HARNESS HAS NO GATE AUTHORITY (charter D81).
//   It is a proof, not a fence. Nothing about the desk may be quoted from it.
//
// WHY IT EXISTS (spd-b36, task-a5fbcb52ee751666). `invisible_occluder_census`
// names ONE way a real occluder reaches zero in `visible_content_px`:
// pointer-events:none, invisible to both hit-test samples. It is not the only
// way, and the other one was counted by nothing.
//
// THE SECOND HOLE, MEASURED IN A BROWSER (2026-09-10, deployed guerrilla,
// viewport 1280x900, /studio/paper/epic-paper-beauty-reference-wave-2026-07-31,
// band 146-899, content 352-932):
//
//   .bp-bulk-action-bar — summoned FOR REAL by ticking one list-pane checkbox
//   while the paper surface stayed open, i.e. a state a user reaches in two
//   clicks — position:fixed, z-index 50, pointer-events AUTO, rect top 830
//   height 50, overlapping 422.563px of the content width and 50px of the
//   band. It was topmost at 0 of 240 sampled points and the row still read
//   240/240 visible. The 0.9 scanline sits at 823.7px, six pixels above the
//   bar's top edge.
//
//   .bp-paper-format — summoned by a right-click inside the surface: 115.453px
//   x 26px over the band, topmost at 0 of 240 points, same zero.
//
// Neither is in `invisible_occluder_census` (their pointer-events are auto, so
// that census correctly excludes them) and neither moves any figure. The
// ancestry test is not at fault — it classifies both perfectly WHERE A POINT IS
// PROBED. The five lines sit one fifth of the band apart, so chrome shorter
// than that spacing is stepped over entirely.
//
// WHAT THIS FILE PROVES. `classifyUnsampledCandidate` is the predicate, and it
// is pure precisely so its verdicts can be seen to fire without a browser, an
// admin token, an ssh hop or 40 seconds of deployed desk. The page runs THE
// SAME TEXT: PAGE_MEASURE interpolates this function's own source, and the last
// test here asserts that, so a future edit cannot make the tested predicate and
// the shipped one diverge silently.
//
// Run: node --test scripts/studio-desk-unsampled-occluder.test.mjs

import test from 'node:test';
import assert from 'node:assert/strict';

import { classifyUnsampledCandidate, PAGE_MEASURE } from './studio-desk-measure.mjs';

/** The band and content box measured live on 2026-09-10 at viewport 1280x900. */
const BAND = { contentLeft: 352, contentRight: 932, bandTop: 146, bandBottom: 899 };

/** The instrument rounds every px figure to 3dp before it reaches the artifact;
 *  comparing raw IEEE sums here would test float arithmetic, not the predicate. */
const r3 = (n) => Math.round(n * 1000) / 1000;

/** The bulk-action bar exactly as it was measured: fixed, bottom-anchored,
 *  50px tall, sitting 6px BELOW the lowest scanline. */
const BULK_BAR = {
  rect: { left: 429.437, right: 852, top: 830, bottom: 880, width: 422.563, height: 50 },
  band: BAND,
  pointer_events: 'auto', visibility: 'visible', display: 'flex', opacity: '1',
  surface_related: false, sampled: false, contains_sampled: false,
};

/** The format bubble as it was measured after a right-click: 26px tall. */
const FORMAT_BUBBLE = {
  ...BULK_BAR,
  rect: { left: 500, right: 615.453, top: 400, bottom: 426, width: 115.453, height: 26 },
};

/** The toast: same geometry family, but pointer-events:none — the OTHER census
 *  owns it, and double-counting one element as two holes would overstate both. */
const TOAST = { ...BULK_BAR, pointer_events: 'none' };

test('a bottom-anchored bar the scanlines stepped over IS a residue', () => {
  const v = classifyUnsampledCandidate(BULK_BAR);
  assert.equal(v.residue, true);
  assert.equal(r3(v.overlap_over_content_px), 422.563);
  assert.equal(r3(v.overlap_height_px), 50);
  assert.match(v.reason, /no probed point ever landed on it/);
});

test('the format bubble measured after a right-click IS a residue', () => {
  const v = classifyUnsampledCandidate(FORMAT_BUBBLE);
  assert.equal(v.residue, true);
  assert.equal(r3(v.overlap_over_content_px), 115.453);
  assert.equal(r3(v.overlap_height_px), 26);
});

test('THE CONTROL: the same bar, once a scanline lands on it, is NOT a residue', () => {
  // Without this arm the predicate could return true for everything and every
  // assertion above would still pass.
  const v = classifyUnsampledCandidate({ ...BULK_BAR, sampled: true });
  assert.equal(v.residue, false);
  assert.match(v.reason, /already sampled/);
});

test('pointer-events:none belongs to invisible_occluder_census, not this one', () => {
  const v = classifyUnsampledCandidate(TOAST);
  assert.equal(v.residue, false);
  assert.match(v.reason, /invisible_occluder_census owns it/);
});

test('a container that merely CONTAINS the sampled winner is not a residue', () => {
  const v = classifyUnsampledCandidate({ ...BULK_BAR, contains_sampled: true });
  assert.equal(v.residue, false);
  assert.match(v.reason, /contains a sampled winner/);
});

test('the surface and its ancestry can never occlude the surface', () => {
  const v = classifyUnsampledCandidate({ ...BULK_BAR, surface_related: true });
  assert.equal(v.residue, false);
  assert.match(v.reason, /is the surface or in its ancestry/);
});

test('chrome outside the band is not a residue however large', () => {
  // A footer below the band. The metric measures a reading COLUMN; horizontal
  // chrome under it narrows nothing, and calling it occlusion is the exact
  // failure that once zeroed a row whose other two lines read 640px.
  const footer = { ...BULK_BAR, rect: { left: 0, right: 1280, top: 920, bottom: 980, width: 1280, height: 60 } };
  const v = classifyUnsampledCandidate(footer);
  assert.equal(v.residue, false);
  assert.match(v.reason, /does not overlap the band/);
});

test('a non-painting element is not a residue, by each of its three routes', () => {
  for (const [patch, want] of [
    [{ display: 'none' }, /not painting/],
    [{ visibility: 'hidden' }, /not painting/],
    [{ opacity: '0' }, /fully transparent/],
  ]) {
    const v = classifyUnsampledCandidate({ ...BULK_BAR, ...patch });
    assert.equal(v.residue, false, JSON.stringify(patch));
    assert.match(v.reason, want);
  }
});

test('a zero-area rect is rejected before any overlap arithmetic', () => {
  const v = classifyUnsampledCandidate({ ...BULK_BAR, rect: { left: 400, right: 400, top: 400, bottom: 400, width: 0, height: 0 } });
  assert.equal(v.residue, false);
  assert.match(v.reason, /zero-area rect/);
});

test('THE SHARING PROOF: the page runs this exact function source', () => {
  // A predicate tested in Node while the page ran a hand-copied twin would be a
  // green with no subject. PAGE_MEASURE interpolates the function itself.
  assert.ok(PAGE_MEASURE.includes(classifyUnsampledCandidate.toString()),
    'PAGE_MEASURE no longer carries classifyUnsampledCandidate\'s own source — the ' +
    'in-page census and this suite have diverged and every assertion above is vacuous.');
  assert.ok(PAGE_MEASURE.includes('unsampled_occluder_census'),
    'the census is no longer emitted into the row');
});
