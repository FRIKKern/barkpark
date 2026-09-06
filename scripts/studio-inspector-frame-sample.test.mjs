#!/usr/bin/env node --test
//
// Proof harness for scripts/studio-inspector-frame-sample.mjs.
//
// The frame sampler's whole value is that a zero means something. This file
// drives the REAL script (as a subprocess, through its real CLI, in a real
// chromium) against three committed fixtures and proves that each of its three
// verdicts is PRODUCIBLE:
//
//   MEET               .fixture.meet.html    — bucket stamped pre-paint, the
//                                              shipped rule holds from frame 0
//   MISS               .fixture.miss.html    — a genuine 3-frame flash of the
//                                              300px panel, bucket valid throughout
//   INSTRUMENT-FAILURE .fixture.absent.html  — no inspector on the page at all
//
// A harness that can only ever say MEET is not evidence of anything, and the
// absent fixture is the specific trap: without it, "0 visible frames" and "there
// was nothing to see" print the same line.
//
//   node --test scripts/studio-inspector-frame-sample.test.mjs
//
// MANUAL PROOF — not wired: it drives the REAL script as a subprocess in a real
// chromium against three HTML fixtures, so it is browser-coupled and cannot join
// the dep-free `scripts/studio-desk-*.test.mjs` glob in
// .github/workflows/studio-instrument-selftests.yml (the same reason
// __studio-wide-deletion-diff.test.mjs is excluded there by name).
// run by hand with: node --test scripts/studio-inspector-frame-sample.test.mjs
// last run — NOT RUN by gates6-w13 on 2026-09-06 (no chromium in that sweep's budget).
// That line is the machine-readable exemption scripts/selftest-wiring-census.sh reads.
// If studio later splits the pure analyse() arms into their own file, THAT file
// belongs in the glob and this exemption shrinks to the browser arms.
//
// MUTATION PROOF (run by hand; see the PR body for the transcript). Break the
// visibility predicate in studio-inspector-frame-sample.mjs by neutering the
// obstruction term inside FRAME_SAMPLER:
//
//   var obstructing = !!(s.painted && isOpen && (contentPainted || widerThanStrip));
//   ->
//   var obstructing = false;
//
// The MISS fixture then reports MEET — wrongly green — and this file's
// "the MISS fixture reports MISS" test reddens. That is the catch: the test
// fails on a predicate that has gone blind, not merely on a crash.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { analyse, STRIP_MAX_PX, MIN_FRAMES, FRAME_SAMPLER } from './studio-inspector-frame-sample.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const SCRIPT = path.join(HERE, 'studio-inspector-frame-sample.mjs');
const fixture = (n) => path.join(HERE, `studio-inspector-frame-sample.fixture.${n}.html`);

/** Run the real CLI against a fixture and return the parsed run JSON. Failures
 *  carry a non-zero exit code by design (INSTRUMENT-FAILURE is exit 2), so the
 *  status is captured rather than allowed to throw — a thrown ENOENT and a
 *  legitimate exit 2 must not read the same. */
function runFixture(name, extraArgs = []) {
  let stdout = '';
  let status = 0;
  try {
    stdout = execFileSync(process.execPath,
      [SCRIPT, `--fixture=${fixture(name)}`, '--json', ...extraArgs],
      { encoding: 'utf8', timeout: 180_000, maxBuffer: 256 * 1024 * 1024 });
  } catch (e) {
    if (typeof e.status !== 'number') throw e;
    status = e.status;
    stdout = e.stdout || '';
  }
  assert.ok(stdout.trim().startsWith('{'), `expected run JSON on stdout, got: ${stdout.slice(0, 400)}`);
  return { run: JSON.parse(stdout), status };
}

test('the sampler source is valid JavaScript (a template string is invisible to node --check)', () => {
  assert.doesNotThrow(() => new Function(FRAME_SAMPLER));
});

test('MEET is producible: a build painted closed from frame zero reports 0 visible frames', () => {
  const { run, status } = runFixture('meet');
  const r = run.runs[0];
  assert.equal(r.verdict, 'MEET');
  assert.equal(r.visible_frames, 0);
  assert.equal(r.transitions, 0);
  assert.equal(r.first_frame_visible, false);
  assert.equal(status, 0);
  // NON-VACUITY: the run must have actually sampled, and the inspector must
  // actually have been there. Otherwise this is the absent fixture wearing a
  // different filename.
  assert.ok(r.total_frames >= MIN_FRAMES, `only ${r.total_frames} frames`);
  assert.ok(r.frames_with_sidebar_present > 0, 'the inspector was never present');
  assert.equal(r.bucket_precondition.ok, true);
  // And the RAW predicate is true throughout — this is the whole reason the
  // verdict keys on `obstructing` instead. If this ever goes to 0, the fixture
  // stopped reproducing the shipped painted-closed strip.
  assert.ok(r.element_painted_frames > 0,
    'element_painted was 0 — the fixture no longer paints the D91/D102 strip');
});

test('MISS is producible: a 3-frame flash of the open panel is caught and counted', () => {
  const { run } = runFixture('miss');
  const r = run.runs[0];
  assert.equal(r.verdict, 'MISS');
  assert.ok(r.visible_frames > 0, `visible_frames was ${r.visible_frames} — the flash was NOT seen`);
  assert.ok(r.transitions >= 1, `transitions was ${r.transitions} — the flash never ended`);
  assert.equal(r.first_frame_visible, true);
  // The reading must be VALID, not void: a MISS reported off a failed bucket
  // precondition would be an instrument failure wearing a verdict.
  assert.equal(r.bucket_precondition.ok, true);
  assert.deepEqual(r.bucket_precondition.buckets_seen_while_sidebar_present, ['standard']);
});

test('INSTRUMENT-FAILURE is producible: an absent inspector never reads as a clean MEET', () => {
  const { run, status } = runFixture('absent');
  const r = run.runs[0];
  assert.equal(r.verdict, 'INSTRUMENT-FAILURE');
  assert.equal(r.visible_frames, 0);          // zero visible…
  assert.notEqual(r.verdict, 'MEET');         // …and NOT a pass
  assert.equal(status, 2);
  assert.ok(r.failures.some((f) => /NEVER present/.test(f)),
    `expected an "inspector never present" failure, got ${JSON.stringify(r.failures)}`);
});

test('the positive control proves the predicate can see', () => {
  const { run } = runFixture('meet', ['--control']);
  assert.equal(run.control.verdict, 'CONTROL-OK');
  assert.ok(run.control.visible_frames > 0,
    `the control saw ${run.control.visible_frames} visible frames — the predicate is blind`);
  assert.equal(run.runs[0].verdict, 'MEET');
});

// ── analyse() unit checks — no browser, so these hold even where chromium does
//    not. Each one guards a specific way the verdict could go quietly wrong.

const frame = (o = {}) => ({
  i: 0, t_ms: 0, phase: 'load', ready_state: 'complete', bucket: 'standard', viewport_w: 1024,
  present: true, element_painted: true, sidebar_w: 41, is_open: true, user_opened: false,
  body_painted: false, title_painted: false, wider_than_strip: false, obstructing: false, ...o,
});

test('a run below the frame floor is an instrument failure, not a MEET', () => {
  const a = analyse(Array.from({ length: MIN_FRAMES - 1 }, (_, i) => frame({ i })));
  assert.equal(a.verdict, 'INSTRUMENT-FAILURE');
  assert.ok(a.failures.some((f) => /frame\(s\) sampled/.test(f)));
});

test('a non-standard bucket VOIDS the reading even with zero visible frames', () => {
  const a = analyse(Array.from({ length: 200 }, (_, i) => frame({ i, bucket: 'wide' })));
  assert.equal(a.visible_frames, 0);
  assert.equal(a.verdict, 'INSTRUMENT-FAILURE');
  assert.equal(a.bucket_precondition.ok, false);
});

test('transitions count changes in the visible boolean, not frames', () => {
  const frames = [
    ...Array.from({ length: 100 }, (_, i) => frame({ i, obstructing: true })),
    ...Array.from({ length: 100 }, (_, i) => frame({ i: 100 + i, obstructing: false })),
  ];
  const a = analyse(frames);
  assert.equal(a.transitions, 1);
  assert.equal(a.visible_frames, 100);
  assert.equal(a.verdict, 'MISS');
  assert.equal(a.first_frame_visible, true);
});

test('a control arm that sees nothing is an instrument failure, never a pass', () => {
  const a = analyse(Array.from({ length: 200 }, (_, i) => frame({ i })), { arm: 'control' });
  assert.equal(a.verdict, 'INSTRUMENT-FAILURE');
  assert.ok(a.failures.some((f) => /POSITIVE CONTROL SAW NOTHING/.test(f)));
});

test('the strip threshold sits strictly between the two shipped constants', () => {
  // .is-collapsed / painted-closed strip is ~41px; .is-open is `flex: 0 0 300px`.
  assert.ok(STRIP_MAX_PX > 41 && STRIP_MAX_PX < 300,
    `STRIP_MAX_PX ${STRIP_MAX_PX} no longer separates the 41px strip from the 300px panel`);
});
