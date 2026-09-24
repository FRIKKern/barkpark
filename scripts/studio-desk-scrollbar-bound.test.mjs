#!/usr/bin/env node
//
// studio-desk-scrollbar-bound.test.mjs — the classic-scrollbar bound, both
// directions.
//
// spd-b30-instrument-coverage-one-document-one-path, criterion 1.
//
// The bound in `studio-desk-scrollbar-bound.mjs` says what a 15px classic
// scrollbar would do to a matrix measured on macOS, where scrollbars are
// overlay and `scrollbar_width_px` is 0 in all 54 rows. Nobody in this epic
// has a classic-scrollbar host, so the claim rests entirely on a model — and a
// model nobody ran backwards is how six of this epic's overturns happened.
//
// So two things are asserted here and neither is optional:
//
//   1. THE CONTROL PASSES on the real committed matrix. Re-derived at the
//      matrix's OWN scrollbar width, the model reproduces every measured
//      `surface_border_box_px`, `content_px` and `container_gate_open`.
//   2. THE CONTROL CAN FAIL. A deliberately wrong model — the container gate
//      ignored, which is exactly the mistake a reader of the CSS would make —
//      is pushed through the SAME guard and must be refused by name. A control
//      that passes everything measures nothing (see
//      `a-control-that-flips-was-never-a-control`).
//
// Then the three derived facts the row asks for are pinned against the
// committed matrix, so a later edit to the model cannot move them silently.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  CLASSIC_SCROLLBAR_PX, surfaceModel, rowInputs, controlMisses,
  applyScrollbarBound, reachability,
} from './studio-desk-scrollbar-bound.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const MATRIX = path.join(HERE, 'measurements', 'spd-b42-deployed-default-state-2026-09-22.json');
const run = JSON.parse(fs.readFileSync(MATRIX, 'utf8'));

test('the committed matrix is the one this bound was derived against', () => {
  assert.equal(run.rows.length, 54, 'the matrix is 9 widths x 3 faces x 2 states');
  assert.equal(run.platform, 'darwin arm64');
  assert.ok(run.rows.every((r) => r.scrollbar_width_px === 0),
    'every row was measured under macOS overlay scrollbars — that is WHY a bound is needed');
  assert.equal(run.provenance_bracket.matched, true,
    'a matrix with an unmatched provenance bracket is not publishable and must not seed a bound');
});

test('CONTROL — the model reproduces the matrix at the matrix\'s own scrollbar width', () => {
  const misses = controlMisses(run.rows);
  assert.deepEqual(misses, [],
    'the model must run backwards over its own input before it may run forwards over a platform nobody has');
});

test('CONTROL CAN FAIL — a model that ignores the container gate is refused by name', () => {
  // The mistake a careful reader of the CSS still makes: apply the floor
  // unconditionally, forgetting it lives inside @container content (min-width: 720px).
  const gateBlind = ({ columnContentBoxPx, maxWidthPx, minInlineSizePx, gutterTotalPx }) => {
    const surface = Math.max(Math.min(columnContentBoxPx, maxWidthPx), minInlineSizePx);
    return { gate_open: true, surface_border_box_px: surface, content_px: surface - gutterTotalPx };
  };
  const misses = controlMisses(run.rows, gateBlind);
  assert.ok(misses.length > 0, 'the control is vacuous if a wrong model passes it');
  assert.throws(
    () => applyScrollbarBound(run, CLASSIC_SCROLLBAR_PX, gateBlind),
    /CONTROL FAILED/,
    'the bound must refuse to publish from a model that cannot reproduce its input');
});

test('the per-row content delta is 0px, -15px or -27.632px, and nothing else', () => {
  const bound = applyScrollbarBound(run, CLASSIC_SCROLLBAR_PX);
  const hist = Object.fromEntries(bound.summary.content_px_delta_histogram.map((h) => [h.delta_px, h.rows]));
  assert.deepEqual(hist, { 0: 35, '-15': 18, '-27.632': 1 },
    '0px where the surface is max-width- or floor-bound, -15px where it is column-bound, ' +
    'and -27.632px in the one row where the gate closing drops the surface off its floor');
  // The ch delta is the px delta over the row's OWN probe — never a shared constant.
  for (const r of bound.rows) {
    assert.ok(Math.abs(r.content_ch.delta - r.content_px.delta / r.probe_px_per_ch) < 1e-3,
      `${r.where}: the ch delta must be the px delta over this row's probe`);
  }
});

test('the 764 -> 779 reachability shift is DERIVED, and it is exact', () => {
  const r = reachability(run, 'user-opened', CLASSIC_SCROLLBAR_PX);
  assert.equal(r.gate_min_px, 720);
  assert.equal(r.lowest_swept_viewport_with_gate_open, 764);
  assert.equal(r.its_column_content_box_px, 720, 'this cell sits ON the gate, which is why the shift is exact');
  assert.equal(r.headroom_px, 0);
  assert.equal(r.exact, true);
  assert.equal(r.bounded_viewport_px, 779);

  // The default state has no swept width on the gate, so its shift is an upper
  // bound and must SAY so rather than quote a number it has not earned.
  const d = reachability(run, 'default', CLASSIC_SCROLLBAR_PX);
  assert.equal(d.exact, false);
  assert.match(d.note, /UPPER bound/);
});

test('the set of floor-binding rows CHANGES: 6 -> 5', () => {
  const { floor_binding_rows: f } = applyScrollbarBound(run, CLASSIC_SCROLLBAR_PX).summary;
  assert.equal(f.measured.length, 6);
  assert.equal(f.bounded.length, 5);
  assert.equal(f.changed, true);
  const gone = f.measured.filter((w) => !f.bounded.includes(w));
  assert.deepEqual(gone, ['1024/user-opened/georgia'],
    'the gate closes at 1024/user-opened and that is the only row there whose floor exceeded max-width');
  // Cross-check against the instrument's own bind EXPERIMENT (it forces
  // min-inline-size to 0px and re-measures), not against this file's model.
  const measuredBinds = run.rows.filter((r) => r.floor.binds).map((r) => `${r.viewport_px}/${r.inspector_state}/${r.face}`);
  assert.deepEqual(measuredBinds.sort(), [...f.measured].sort(),
    'the model\'s "binds" must agree with the instrument\'s forced-to-0px bind test');
});

test('the container gate flips at BOTH of the two cells sitting on 720.0px', () => {
  const { container_gate_flips: g } = applyScrollbarBound(run, CLASSIC_SCROLLBAR_PX).summary;
  const cells = [...new Set(g.map((x) => x.where.split('/').slice(0, 2).join('/')))].sort();
  assert.deepEqual(cells, ['1024/user-opened', '764/user-opened'],
    'the row brief names 764 only; 1024/user-opened sits on the same 720.0px knife edge');
  assert.equal(g.length, 6, 'three faces at each of the two cells');
});

test('three 55ch verdicts flip TRUE -> FALSE, and they are named', () => {
  const { criterion_verdict_flips: flips } = applyScrollbarBound(run, CLASSIC_SCROLLBAR_PX).summary;
  assert.deepEqual(flips.map((f) => f.where).sort(), [
    '1024/user-opened/georgia',
    '640/default/source-serif-4',
    '700/user-opened/georgia',
  ]);
  assert.ok(flips.every((f) => f.from === true && f.to === false));
});

test('a mixed-scrollbar matrix is refused rather than half-shifted', () => {
  const mixed = { ...run, rows: run.rows.map((r, i) => ({ ...r, scrollbar_width_px: i === 0 ? 15 : 0 })) };
  assert.throws(() => applyScrollbarBound(mixed), /mixes scrollbar widths/);
});

test('the bound names what it does not cover, in the artifact itself', () => {
  const bound = applyScrollbarBound(run, CLASSIC_SCROLLBAR_PX);
  const text = bound.not_covered.join(' ');
  assert.match(text, /gutter band/i, 'the 767/479 @media edges move by the scrollbar width too');
  assert.match(text, /innerWidth/, 'the JS bucket and the CSS band read DIFFERENT widths on a classic platform');
  assert.ok(bound.kind.includes('NOT a measurement'),
    'a bound that could be mistaken for a measurement is the failure this row exists to stop');
});

test('surfaceModel is pure arithmetic — no browser, no host, no row object', () => {
  // gate closed: the floor never applies however large it is
  assert.deepEqual(
    surfaceModel({ columnContentBoxPx: 679, gateMinPx: 720, maxWidthPx: 660, minInlineSizePx: 9999, gutterTotalPx: 48 }),
    { gate_open: false, surface_border_box_px: 660, content_px: 612 });
  // gate open: the floor can exceed max-width, which is the whole point of the 687.625px rows
  assert.deepEqual(
    surfaceModel({ columnContentBoxPx: 720, gateMinPx: 720, maxWidthPx: 660, minInlineSizePx: 687.625, gutterTotalPx: 80 }),
    { gate_open: true, surface_border_box_px: 687.625, content_px: 607.625 });
  // column-bound: neither cap reaches
  assert.deepEqual(
    surfaceModel({ columnContentBoxPx: 555, gateMinPx: 720, maxWidthPx: 660, minInlineSizePx: 0, gutterTotalPx: 48 }),
    { gate_open: false, surface_border_box_px: 555, content_px: 507 });
});

test('rowInputs reads the row and computes nothing', () => {
  const r = run.rows[0];
  assert.deepEqual(rowInputs(r), {
    columnContentBoxPx: r.floor.container_content_box_px,
    gateMinPx: r.floor.container_gate_min_px,
    maxWidthPx: r.surface_max_width_px,
    minInlineSizePx: r.floor.min_inline_size_px,
    gutterTotalPx: r.gutter.total_px,
  });
});
