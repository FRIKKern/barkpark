#!/usr/bin/env node
//
// studio-desk-coverage-boundary.test.mjs — the boundary travels with the
// matrix, and its prose is checked against the measurements it cites.
//
// spd-b30-instrument-coverage-one-document-one-path, criteria 0, 2, 3 and 4.
//
// THE FAILURE THIS FILE EXISTS TO STOP. A coverage claim is prose, and prose is
// where this lane keeps finding artefacts that assert a property the system
// lacks: three code comments claiming behaviour the code did not have, a served
// DOM element nothing could write to, a grep that matched the sentence
// describing what it hunted. The reassuring artefact was the false one every
// time. `COVERAGE_BOUNDARY` is more prose, so:
//
//   - it must RIDE IN the run object rather than sit in a document nobody
//     opens beside the JSON (asserted against the instrument's own source, so
//     a refactor that drops the field reds here);
//   - every axis must carry a NON-EMPTY `uncovered`, because the second branch
//     of this row's criteria is the naming of what is not covered;
//   - and its motion ruling is CHECKED AGAINST THE COMMITTED PROBE OUTPUT, not
//     taken on trust. If the numbers in scripts/measurements/spd-b30-desk-motion
//     ever stop supporting the sentence, this file reds and the sentence is the
//     thing that was wrong.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { COVERAGE_BOUNDARY, coverageBoundaryLines } from './studio-desk-measure.mjs';
import { hasLiveMotion, nonZeroDuration, armDiff, ruleOn } from './studio-desk-motion-probe.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const INSTRUMENT = path.join(HERE, 'studio-desk-measure.mjs');
const MOTION = path.join(HERE, 'measurements', 'spd-b30-desk-motion-2026-09-22.json');

const AXES = ['platform', 'engine', 'document', 'path', 'surface', 'motion'];

test('every axis is present and names what it does NOT cover', () => {
  for (const axis of AXES) {
    assert.ok(COVERAGE_BOUNDARY[axis], `missing axis: ${axis}`);
    assert.ok(COVERAGE_BOUNDARY[axis].covered?.length > 20, `${axis}.covered is not a statement`);
    assert.ok(COVERAGE_BOUNDARY[axis].uncovered?.length > 40,
      `${axis}.uncovered is the half that earns this object its place — it cannot be a stub`);
  }
  assert.ok(COVERAGE_BOUNDARY.what_would_change_this.length >= 3,
    'a boundary with no expiry conditions is a boundary nobody will ever revisit');
  assert.equal(COVERAGE_BOUNDARY.owner_task, 'spd-b30-instrument-coverage-one-document-one-path');
});

test('the boundary RIDES IN the run object — asserted against the instrument source', () => {
  const src = fs.readFileSync(INSTRUMENT, 'utf8');
  assert.match(src, /^\s*coverage_boundary: COVERAGE_BOUNDARY,$/m,
    'the run object must carry the boundary. A boundary stated only in this file\'s comments does ' +
    'not travel with the JSON, which is the exact defect this row names.');
  assert.match(src, /coverageBoundaryLines\(run\.coverage_boundary/,
    'the human table must print it too — the two renderings come from one object on purpose');
});

test('the printed rendering drops no axis', () => {
  const text = coverageBoundaryLines().join('\n');
  for (const axis of AXES) {
    assert.ok(text.includes(axis.toUpperCase()), `the table rendering omits ${axis}`);
    assert.ok(text.includes(COVERAGE_BOUNDARY[axis].uncovered),
      `the table rendering omits ${axis}.uncovered verbatim — a summarised boundary is a new claim`);
  }
});

test('ENGINE — Chromium-only is stated, and no cross-engine validity is implied', () => {
  const e = COVERAGE_BOUNDARY.engine;
  assert.match(e.covered, /CHROMIUM ONLY/);
  assert.match(e.uncovered, /Gecko/);
  assert.match(e.uncovered, /WebKit/);
  assert.match(e.uncovered, /measure NOTHING here/,
    'the claim must be that other engines are unmeasured, not that they are expected to agree');
  // The failure shape, spelled out: a boundary that says "other engines should
  // behave the same" would satisfy every test above and be exactly wrong.
  assert.doesNotMatch(`${e.covered} ${e.uncovered}`, /should behave the same|expected to agree|likely identical/i);
});

test('SURFACE — the two uncovered surfaces this row names are named', () => {
  const s = COVERAGE_BOUNDARY.surface.uncovered;
  assert.match(s, /non-paper/i, 'classic non-paper documents must be named as uncovered');
  assert.match(s, /\.editor-panel/, 'additional .editor-panel roots must be named as uncovered');
  assert.match(s, /sheet/i);
});

test('PLATFORM — the scrollbar bound is cited with the tool that derives it', () => {
  const p = COVERAGE_BOUNDARY.platform;
  assert.match(p.scrollbar_model, /OVERLAY/);
  assert.match(p.uncovered, /studio-desk-scrollbar-bound\.mjs/,
    'the bound must cite the tool, so a reader can re-derive it rather than believe it');
  assert.match(p.uncovered, /764px to 779px/);
  assert.match(p.uncovered, /6 -> 5/);
});

// ── the motion ruling, checked against the probe that produced it ────────────

const probe = JSON.parse(fs.readFileSync(MOTION, 'utf8'));

test('the committed motion probe is publishable at all', () => {
  assert.equal(probe.provenance_bracket.matched, true, 'an unmatched bracket means two builds, one file');
  assert.equal(probe.emulation_control.ok, true,
    'without the emulation control the two arms could be the same arm');
  assert.equal(probe.non_vacuity_guard.ok, true,
    'a probe that matched no elements prints "0s everywhere" in the same shape as a desk with no motion');
  assert.ok(probe.provenance.commit, 'the reading must name the commit it was taken against');
});

test('A LIVE TRANSITION EXISTS — so reduced-motion coverage was warranted, not optional', () => {
  const mover = hasLiveMotion(probe.arms.no_preference.surfaces.desk);
  assert.ok(mover, 'the desk must show at least one non-zero duration in the no-preference arm');
  assert.equal(mover.selector, '.pane-column');
  assert.equal(COVERAGE_BOUNDARY.motion.ruling.includes('.pane-column'), true);
  // and the reduce arm really reaches it
  const diffs = armDiff(probe.arms.no_preference.surfaces.paper, probe.arms.reduce.surfaces.paper);
  assert.ok(diffs.length > 0, 'if reduce changed nothing, the ruling in the boundary is false');
  assert.ok(diffs.some((d) => d.selector === '.pane-column' && d.property === 'transition_property'
    && d.reduce === 'background'),
    'the @media (prefers-reduced-motion: reduce) block in root.html.heex nulls the BOX transition and ' +
    'keeps background — that is what must be measured');
  assert.ok(diffs.some((d) => d.property === 'animation_name' && d.reduce === 'none'),
    'bp-pane-strip-in must be switched off under reduce');
});

test('THE MEASURED ELEMENTS CARRY NO MOTION — in BOTH regimes, which is the whole ruling', () => {
  const measured = ['.editor-panel', '.editor-panel-main.bp-paper-body', '.bp-paper-surface'];
  for (const arm of ['no_preference', 'reduce']) {
    const surface = probe.arms[arm].surfaces.paper;
    for (const sel of measured) {
      const rec = surface.selectors.find((s) => s.selector === sel);
      assert.ok(rec, `${arm}: the probe never looked at ${sel}`);
      assert.ok(rec.match_count > 0,
        `${arm}: ${sel} matched ZERO elements — a 0s reading off no element is not a no-motion finding`);
      for (const e of rec.sampled) {
        assert.equal(nonZeroDuration(e.transition_duration), false,
          `${arm}: ${sel} reports a live transition (${e.transition_duration}) — the matrix would be ` +
          `measuring a transient and the boundary's motion ruling has expired`);
        assert.equal(e.animation_name, 'none', `${arm}: ${sel} is animated (${e.animation_name})`);
      }
    }
  }
  assert.match(COVERAGE_BOUNDARY.motion.ruling, /transition-duration 0s and animation-name none in BOTH regimes/);
});

test('nonZeroDuration reads a duration list, not a string', () => {
  assert.equal(nonZeroDuration('0s'), false);
  assert.equal(nonZeroDuration('0s, 0s, 0s'), false);
  assert.equal(nonZeroDuration(''), false);
  assert.equal(nonZeroDuration('0.15s'), true);
  assert.equal(nonZeroDuration('0s, 0.15s'), true);
  assert.equal(nonZeroDuration('150ms'), true);
  assert.equal(nonZeroDuration('0ms'), false);
});

test('ruleOn refuses the no-motion verdict when the guard did not pass', () => {
  const vacuous = {
    non_vacuity_guard: { ok: false, first_moving_element: { desk: null, paper: null } },
    reduce_changed: { desk: [], paper: [] },
  };
  const r = ruleOn(vacuous);
  assert.equal(r.live_transition_exists, false);
  assert.match(r.statement, /NOT entitled to that ruling/,
    'a probe that found nothing must say it found nothing, not that there is nothing to find');
});
