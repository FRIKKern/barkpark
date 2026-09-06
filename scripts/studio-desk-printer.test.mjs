#!/usr/bin/env node
//
// studio-desk-printer.test.mjs — the committed proof harness for the desk
// instrument's PRINTER.
//
//   THIS HARNESS HAS NO GATE AUTHORITY (charter D81).
//   It is a proof, not a fence: nothing merges or fails to merge because of it,
//   and no verdict about the desk may be quoted from it. What it buys is the one
//   thing a green run cannot buy on its own — a check SEEN TO FIRE.
//
// WHY IT EXISTS. The silent third-state drop was found, and its fix proven, by
// a hand-written script that fed a synthetic run object to the real printTable
// and counted what came out. That script lived in a scratch directory and died
// with the session. `printTable`, `orderedStates`, `assertEveryStateRendered`,
// `summariseNonVacuity`, `expectedRowCount` and `STATE_IDS` are EXPORTED for
// exactly this purpose (the instrument says so in its own comment above
// printTable). Nothing committed exercised them, so the next state added to the
// STATES table would get no before/after and the tripwire could rot into a
// check nobody has ever watched fail.
//
// WHAT IT PROVES:
//
//   1. THE PRINTER RUNS ON A SYNTHETIC RUN. No browser, no ssh, no admin token,
//      no network, no filesystem beyond reading two source files. The whole
//      matrix — header, rows, legend, census, headline, self-checks — is
//      emitted from an object built in this file.
//   2. THE TRIPWIRE FIRES. `assertEveryStateRendered` is handed the exact
//      `rendered` set the PRE-FIX printer produced (the three summary loops
//      hardcoded ['default', 'user-opened'], i.e. `new Set(STATE_IDS)`) over a
//      run that carries a third state's rows, and it must refuse BY NAME. And
//      it must be SILENT over the set the real printer builds. Both halves, or
//      the check is either vacuous or a nuisance.
//   3. NULL VERDICTS RENDER `?`, NEVER `FAIL`. Asserted on the matrix ROW LINE,
//      not on the whole output — the legend prose says the word "FAIL" several
//      times on purpose, and a whole-document grep would be a detector that
//      cannot tell the two apart. A FAIL control row sits beside the null row so
//      the assertion is proven able to SEE a FAIL when there is one.
//   4. expected_row_count IS ARITHMETIC OVER THE STATES TABLE. Not a literal:
//      it is linear in the state list, zero on an empty list, blind to a state
//      id the table has never heard of, and it MOVES when the state list moves.
//      The printer's own "rows N of M expected" line is asserted to carry the
//      number the exported function returns.
//   5. THE THREE ZERO_CAUSE BRANCHES, plus the not-applicable case. The two
//      zeros — "the desk was fixed" and "the guard never ran" — are the same
//      number and opposite news, and each branch is reached here by shaping the
//      rows rather than by reading the source.
//
// THE FIXTURE IS DERIVED, NEVER RETYPED. The state vocabulary comes from the
// instrument's own `STATE_IDS`; the per-state row counts come from its own
// `expectedRowCount`. A state added to the STATES table changes this file's
// fixture automatically, which is the property the throwaway script did not
// have and the reason this one is committed.
//
//   node --test scripts/studio-desk-printer.test.mjs

import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import {
  MeasureError,
  STATE_IDS,
  assertEveryStateRendered,
  expectedRowCount,
  orderedStates,
  printTable,
  summariseNonVacuity,
} from './studio-desk-measure.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const SELF = fs.readFileSync(fileURLToPath(import.meta.url), 'utf8');
const SRC = fs.readFileSync(path.join(HERE, 'studio-desk-measure.mjs'), 'utf8');

// ── the fixture vocabulary ───────────────────────────────────────────────────
//
// Widths and faces here are SYNTHETIC and deliberately not the instrument's own
// — this file measures the PRINTER, not the desk, and a fixture that borrowed
// WIDTHS/FACES would read as a claim about real geometry. Only the STATE list
// and the row ARITHMETIC are taken from the instrument, because those are the
// two things a future wave will change and this harness must follow.

/** A state the STATES table has never heard of — the shape the third state had
 *  when it vanished from the human table with no error raised anywhere. */
const UNDECLARED_STATE = 'synthetic-undeclared-state';

const W = [1440, 900, 640];
const F = ['native-synth', 'georgia-synth'];

/** A viewport/face pair no generated row uses, so a probe row can be located in
 *  the matrix by its own coordinates rather than by counting columns. */
const PROBE_VIEWPORT = 777;

function row({
  state, viewport, face,
  contentVerdict = true, visibleVerdict = true,
  hitTested = true, guardApplies = false, guardPassed = false,
  scrimRenders = false, hostPresent = false, floorBinds = false,
}) {
  return {
    inspector_state: state,
    viewport_px: viewport,
    face,
    face_relevant: true,
    width_bucket_stamped: 'synthetic',
    settle: { settled: true },
    panes: { visible_pane_widths_px: [viewport], strips_visible: 1 },
    panel_px: 41,
    gutter: { total_px: 96 },
    content_px: 600,
    ch: { probe_px_per_ch: 9 },
    content_ch: 66.66,
    floor: floorBinds
      ? { binds: true, min_inline_size_px: 320, width_without_floor_px: 300, width_with_floor_px: 320 }
      : { binds: false },
    overflow: { horizontal_scroll: false, overflow_px: 0 },
    crumbs: { visible: true, count: 2 },
    inspector: { present: true, overlays_surface: false },
    content_meets_55ch: contentVerdict,
    visible_content_px: 600,
    visible_ch: 66.66,
    visible_meets_55ch: visibleVerdict,
    scrim: { renders: scrimRenders, host_present: hostPresent },
    dimmed_content_px: 0,
    scrim_alpha: 0,
    legacy_inspector_subtraction_px: 0,
    scrollbar_width_px: 0,
    visible_vs_legacy_delta_px: 0,
    font: { resolved_family: 'synthetic-family', font_size_px: 18 },
    occlusion: hitTested
      ? {
          scan_columns: 120,
          scan_step_px: 6,
          bisect_tolerance_px: 0.5,
          non_vacuity: { guard_applies: guardApplies, forced_sample_differs: guardPassed },
          restore: { byte_identical: true },
        }
      : null,
  };
}

/** `n` rows for one state, cycling the synthetic widths and faces. `n` is the
 *  instrument's OWN per-state arithmetic (`expectedRowCount([id])`), so a state
 *  or a width added upstream changes this fixture without a hand edit here. */
function rowsForState(state, n, extra = {}) {
  const out = [];
  for (let i = 0; i < n; i++) {
    out.push(row({ state, viewport: W[i % W.length], face: F[Math.floor(i / W.length) % F.length], ...extra }));
  }
  return out.sort((a, b) => b.viewport_px - a.viewport_px);
}

/** A run object shaped exactly as `printTable` consumes it. Everything optional
 *  (provenance bracket, drill, positive control, round trip, b29 probes) is left
 *  off by default: the printer must survive a run that never took them. */
function makeRun(rows, over = {}) {
  return {
    target: 'https://synthetic.invalid',
    measured_document: 'synthetic-document',
    measured_doc_source: 'synthetic fixture — no document was opened',
    landed_authenticated_url: 'https://synthetic.invalid/papers/synthetic-document',
    measured_url: 'https://synthetic.invalid/papers/synthetic-document',
    provenance: {
      served_sha: '0000000000000000000000000000000000000000',
      slot_active: ['synthetic'],
      slot_units_loaded: ['synthetic.service'],
      read_at: '1970-01-01T00:00:00.000Z',
    },
    doc_target: { mode: 'slug', slug: 'synthetic-document', source: 'the fixture' },
    sweep_direction: 'descending',
    platform: 'synthetic fixture',
    states_measured: [...STATE_IDS],
    states_skipped: [],
    warnings: [],
    rows,
    ...over,
  };
}

/** The run every printer test starts from: one row block per DECLARED state,
 *  sized by the instrument's own arithmetic, so `rows.length` equals
 *  `expectedRowCount(STATE_IDS)` exactly and the printer reads COMPLETE. */
function completeRun(over = {}) {
  const rows = STATE_IDS.flatMap((id) => rowsForState(id, expectedRowCount([id])));
  return makeRun(rows, over);
}

/** Capture what the printer writes. `printTable` writes through
 *  `process.stdout.write` and is fully synchronous, so nothing else can
 *  interleave into the buffer for the duration of the call. */
function capture(fn) {
  const original = process.stdout.write;
  const chunks = [];
  process.stdout.write = function (chunk, enc, cb) {
    chunks.push(typeof chunk === 'string' ? chunk : String(chunk));
    if (typeof enc === 'function') enc();
    else if (typeof cb === 'function') cb();
    return true;
  };
  let error = null;
  try {
    fn();
  } catch (e) {
    error = e;
  } finally {
    process.stdout.write = original;
  }
  return { out: chunks.join(''), error };
}

function print(run) {
  const { out, error } = capture(() => printTable(run));
  if (error) throw error;
  return out;
}

/** The matrix region only — everything from the first state heading down to the
 *  legend. The legend below it says "FAIL" in prose on purpose, so a check about
 *  a VERDICT cell must never be allowed to read it. */
function matrixRegion(out) {
  const start = out.indexOf('  INSPECTOR STATE:');
  const end = out.indexOf('  content = surface.clientWidth');
  assert.ok(start >= 0 && end > start, 'the printer must emit a matrix and then its legend');
  return out.slice(start, end);
}

function matrixLineAt(out, viewport) {
  const lines = matrixRegion(out).split('\n').filter((l) => l.startsWith('  ' + viewport + ' '));
  assert.equal(lines.length, 1, `expected exactly one matrix row at viewport ${viewport}`);
  return lines[0];
}

// ── 0. the harness itself needs nothing outside this process ─────────────────

test('c0 — the harness imports nothing but node builtins and the instrument', () => {
  const specifiers = [...SELF.matchAll(/^import [^;]*?from '([^']+)';$/gm)].map((m) => m[1]);
  assert.ok(specifiers.length >= 6, `expected the import block to be found (got ${specifiers.length})`);
  for (const s of specifiers) {
    assert.ok(s.startsWith('node:') || s === './studio-desk-measure.mjs',
      `a proof harness that reaches outside the process is not a proof of the printer — found import '${s}'`);
  }
});

test('c0 — the printer renders a synthetic multi-state run end to end', () => {
  const run = completeRun();
  const out = print(run);

  for (const id of STATE_IDS) {
    assert.ok(out.includes(`  INSPECTOR STATE: ${id.toUpperCase()}`),
      `every declared state must get its own block in the matrix — ${id} did not`);
    assert.ok(out.includes(`VISIBLE VERDICT (${id}):`),
      `every declared state must get a visible census — ${id} did not`);
  }
  assert.ok(out.includes('STUDIO DESK — LIVE MEASURE MATRIX'), 'the header must print');
  assert.ok(out.includes("THE EPIC'S HEADLINE CRITERION"), 'the headline section must print');
  assert.ok(out.includes('OCCLUSION INSTRUMENT — SELF-CHECKS:'), 'the self-check census must print');
  assert.ok(out.includes('DOES THE PROTECTED FLOOR EVER BIND?'), 'the floor census must print');
});

test('c0 — a state the STATES table has never heard of still prints, and is labelled', () => {
  // This is the whole fix: the printer may not have an opinion about which
  // states exist. An undeclared state prints, in the appended position, under a
  // legend that says out loud that it is undeclared.
  const rows = [
    ...STATE_IDS.flatMap((id) => rowsForState(id, expectedRowCount([id]))),
    ...rowsForState(UNDECLARED_STATE, 3),
  ];
  const run = makeRun(rows);
  const out = print(run);

  assert.ok(out.includes(`  INSPECTOR STATE: ${UNDECLARED_STATE.toUpperCase()}`),
    'an undeclared state must be PRINTED, not dropped — that omission is the defect this harness exists for');
  assert.ok(out.includes('UNDECLARED STATE'),
    'and it must be LABELLED undeclared, so a reader is never told a synthetic state is a declared one');
  assert.deepEqual(orderedStates(run), [...STATE_IDS, UNDECLARED_STATE],
    'declared states keep the familiar reading order and anything else is APPENDED, never dropped');
});

// ── 1. the tripwire, both halves ─────────────────────────────────────────────

test('c1 — the tripwire FIRES on a dropped state, by name', () => {
  const run = makeRun([
    ...STATE_IDS.flatMap((id) => rowsForState(id, expectedRowCount([id]))),
    ...rowsForState(UNDECLARED_STATE, 3),
  ]);

  // The exact `rendered` set the PRE-FIX printer produced: three summary loops
  // that hardcoded the declared state list. The rows carry a third state; the
  // printed output does not. That is the silent drop, reproduced.
  const preFixRendered = new Set(STATE_IDS);

  let caught = null;
  try {
    assertEveryStateRendered(run, preFixRendered);
  } catch (e) {
    caught = e;
  }

  assert.ok(caught,
    'a state that produced rows and was never printed MUST be a hard failure — this assertion going ' +
    'green is the tripwire having rotted into a check that cannot fire');
  assert.ok(caught instanceof MeasureError,
    `the refusal must be a MeasureError so it lands in the instrument's one failure handler (got ${caught?.constructor?.name})`);
  assert.match(caught.message, /SILENT STATE DROP/,
    'the refusal must be findable by name in a scrollback');
  assert.ok(caught.message.includes(UNDECLARED_STATE),
    'the refusal must NAME the state that was dropped, or the operator has to go looking');
  assert.ok(caught.message.includes('Rendered: ' + [...preFixRendered].join(', ')),
    'and it must say what WAS rendered, so the two sets can be compared without a re-run');
});

test('c1 — the tripwire is SILENT when nothing is dropped', () => {
  const run = makeRun([
    ...STATE_IDS.flatMap((id) => rowsForState(id, expectedRowCount([id]))),
    ...rowsForState(UNDECLARED_STATE, 3),
  ]);
  // The set the real printer builds — every state it actually emitted.
  assert.doesNotThrow(() => assertEveryStateRendered(run, new Set(orderedStates(run))),
    'a complete render must pass silently, or the tripwire is a nuisance that will be deleted');
});

test('c1 — the real printer walks every state, so its own last line passes', () => {
  // printTable ends with assertEveryStateRendered against the set it built
  // itself. A run whose rows include an undeclared state must therefore print
  // WITHOUT throwing — the drop is now structurally impossible, and this is the
  // end-to-end proof of that through the real printer rather than at the seam.
  const run = makeRun([
    ...STATE_IDS.flatMap((id) => rowsForState(id, expectedRowCount([id]))),
    ...rowsForState(UNDECLARED_STATE, 3),
  ]);
  const { error } = capture(() => printTable(run));
  assert.equal(error, null, `the printer must not throw on a run carrying an undeclared state: ${error?.message}`);
  assert.ok(SRC.includes('assertEveryStateRendered(run, rendered);'),
    'and the tripwire must still be WIRED as the printer\'s last line — a proof of an uncalled check is worthless');
});

// ── 2a. null verdicts render '?', never 'FAIL' ───────────────────────────────

test('c2 — a null verdict renders ? and the same row never says FAIL', () => {
  const nullRow = row({
    state: STATE_IDS[0], viewport: PROBE_VIEWPORT, face: 'f-null',
    contentVerdict: null, visibleVerdict: null,
  });
  const failRow = row({
    state: STATE_IDS[0], viewport: PROBE_VIEWPORT - 1, face: 'f-fail',
    contentVerdict: false, visibleVerdict: false,
  });
  const run = makeRun([...rowsForState(STATE_IDS[0], expectedRowCount([STATE_IDS[0]])), nullRow, failRow]);
  const out = print(run);

  const nullLine = matrixLineAt(out, PROBE_VIEWPORT);
  const failLine = matrixLineAt(out, PROBE_VIEWPORT - 1);

  // THE CONTROL FIRST. If this assertion cannot see a FAIL where there is one,
  // the assertion below proves nothing at all.
  assert.ok(failLine.includes('FAIL'),
    'the FAIL control row must print FAIL — otherwise the null assertion below is vacuous');
  assert.equal((failLine.match(/\?/g) ?? []).length, 0,
    'a fully-measured row has no ? at all, so a ? in the null row can only come from a verdict');

  assert.ok(!nullLine.includes('FAIL'),
    'a null verdict printed as FAIL asserts a reading failure against a column that was never ' +
    'measured — D127 part 2 forbids it and the seal turns on this column');
  assert.equal((nullLine.match(/\?/g) ?? []).length, 2,
    'both null verdicts — layout and visible — must render as ?, and nothing else in this row is unmeasured');
});

test('c2 — a null verdict reads NOT MEASURABLE in the headline, never FAILS', () => {
  const nullAt900 = row({
    state: STATE_IDS[0], viewport: 900, face: 'f-null-900',
    contentVerdict: null, visibleVerdict: null,
  });
  const run = makeRun([...rowsForState(STATE_IDS[0], expectedRowCount([STATE_IDS[0]])), nullAt900]);
  const out = print(run);
  // The HEADLINE region only. The same face string also appears in the matrix
  // row above, and reading that one would test a different renderer entirely.
  const headline = out.slice(out.indexOf("  THE EPIC'S HEADLINE CRITERION"));
  assert.ok(headline.length > 0, 'the headline section must print');
  const line = headline.split('\n').find((l) => l.includes('f-null-900'));
  assert.ok(line, 'the 900px headline section must print the null row');
  assert.ok(line.includes('NOT MEASURABLE'), 'a null verdict is a THIRD answer, not a failing one');
  assert.ok(!line.includes('FAILS'), 'and it must never be reported as a failure');
});

test('c2 — the visible census counts null cells as neither MEET nor FAIL', () => {
  const state = STATE_IDS[0];
  const per = expectedRowCount([state]);
  const rows = [
    ...rowsForState(state, per),                                                    // all MEET
    row({ state, viewport: PROBE_VIEWPORT, face: 'f-null', contentVerdict: null, visibleVerdict: null }),
  ];
  const out = print(makeRun(rows));
  const census = out.split('\n').find((l) => l.includes(`VISIBLE VERDICT (${state}):`));
  assert.ok(census, 'the census line must print');
  assert.ok(census.includes(`${per} of ${per} MEASURABLE cells MEET`),
    `the null cell must be OUT of the denominator (census read: ${census.trim()})`);
  assert.ok(census.includes(`1 of ${per + 1} cells are NOT MEASURABLE`),
    'and it must be announced as not measurable rather than silently missing from a total');
});

// ── 2b. expected_row_count is arithmetic over the STATES table ───────────────

test('c2 — expectedRowCount is LINEAR in the state list, not a literal', () => {
  const whole = expectedRowCount(STATE_IDS);
  const summed = STATE_IDS.reduce((n, id) => n + expectedRowCount([id]), 0);
  assert.ok(whole > 0, 'the full table must expect a positive number of rows');
  assert.equal(whole, summed,
    'the count is a SUM over the states of (widths applicable to that state x faces) — if these ever ' +
    'disagree the printer is quoting a number the sweep does not produce');
  assert.equal(expectedRowCount([]), 0, 'a run measuring no state expects no rows');
});

test('c2 — changing the state list CHANGES the count, and an unknown id adds nothing', () => {
  const whole = expectedRowCount(STATE_IDS);
  assert.ok(STATE_IDS.length >= 2, 'this assertion needs at least two declared states to drop one');
  const dropped = STATE_IDS.slice(1);
  assert.equal(expectedRowCount(dropped), whole - expectedRowCount([STATE_IDS[0]]),
    'a skipped state must contribute NOTHING — an expected count that ignores the skip is the ' +
    'compiled-in literal D121 retired, wearing a function call');
  assert.ok(expectedRowCount(dropped) < whole, 'and the count must actually move when the list moves');
  assert.equal(expectedRowCount([...STATE_IDS, UNDECLARED_STATE]), whole,
    'a state id the STATES table has never heard of inflates nothing — the count is over the TABLE');
});

test('c2 — the printer quotes the exported arithmetic, and says COMPLETE or SHORT', () => {
  const complete = completeRun();
  const outComplete = print(complete);
  const expected = expectedRowCount(complete.states_measured);
  assert.equal(complete.rows.length, expected, 'the fixture is sized from the instrument\'s own arithmetic');
  assert.ok(outComplete.includes(`  rows          ${expected} of ${expected} expected`),
    'the printed row line must carry the number expectedRowCount returns');
  assert.ok(outComplete.includes('— COMPLETE'), 'a full run reads COMPLETE');

  const short = completeRun();
  short.rows = short.rows.slice(0, -1);
  const outShort = print(short);
  assert.ok(outShort.includes(`  rows          ${expected - 1} of ${expected} expected`),
    'a short run must state both numbers');
  assert.ok(outShort.includes('— SHORT, see the caveats below'), 'and be flagged SHORT at the top');
  assert.ok(outShort.includes('ROW COUNT MISMATCH'), 'and again in the caveats, as arithmetic');
});

// ── 2c. the three zero_cause branches ────────────────────────────────────────

const nvRun = (rows, over = {}) => makeRun(rows, over);

test('c2 — zero_cause: NOT APPLICABLE when the guard applied somewhere', () => {
  const rows = rowsForState(STATE_IDS[0], 3, { guardApplies: true, guardPassed: true, scrimRenders: true, hostPresent: true });
  const nv = summariseNonVacuity(nvRun(rows));
  assert.equal(nv.applies_in_rows, 3);
  assert.equal(nv.vacuous, false);
  assert.match(nv.zero_cause, /^not-applicable/, 'with the guard applying, there is no zero to explain');
});

test('c2 — zero_cause: DESK-FIXED (proven) when the positive control fired', () => {
  const rows = rowsForState(STATE_IDS[0], 3, { hostPresent: true });
  const nv = summariseNonVacuity(nvRun(rows, { positive_control: { ran: true, guard_passed: true, face: 'f', verdict: 'fired' } }));
  assert.equal(nv.applies_in_rows, 0);
  assert.match(nv.zero_cause, /DESK-FIXED \(proven\)/,
    'a control that forced a scrim and saw the guard fire converts the zero from plausible to proven');
  assert.equal(nv.positive_control_guard_passed, true);
});

test('c2 — zero_cause: GUARD-NEVER-RAN when the scrim host was absent everywhere', () => {
  const rows = rowsForState(STATE_IDS[0], 3, { hostPresent: false });
  const nv = summariseNonVacuity(nvRun(rows));
  assert.equal(nv.scrim_host_present_in_rows, 0);
  assert.match(nv.zero_cause, /GUARD-NEVER-RAN \(instrument suspect\)/,
    'a diff that was zero BY CONSTRUCTION is instrument rot, not a fixed desk, and must say so');
  assert.match(nv.zero_cause, /Do NOT read this zero as a fixed desk/);
});

test('c2 — zero_cause: DESK-FIXED (unproven) when the host was there and no control ran', () => {
  const rows = rowsForState(STATE_IDS[0], 4, { hostPresent: true });
  const nv = summariseNonVacuity(nvRun(rows));
  assert.equal(nv.scrim_host_present_in_rows, 4);
  assert.match(nv.zero_cause, /DESK-FIXED \(unproven\)/,
    'the host census is EVIDENCE for the fixed-desk reading, and must not be stated as proof');
  assert.ok(nv.zero_cause.includes('4 of 4 hit-tested rows'), 'and it must show the census it rests on');
});

test('c2 — the printer prints WHICH ZERO IS THIS only when the guard applied nowhere', () => {
  const vacuous = makeRun(rowsForState(STATE_IDS[0], expectedRowCount([STATE_IDS[0]]), { hostPresent: false }));
  assert.ok(print(vacuous).includes('WHICH ZERO IS THIS?'),
    'a bare zero must never be printed on its own — the two zeros are opposite news');

  const applied = makeRun(rowsForState(STATE_IDS[0], expectedRowCount([STATE_IDS[0]]),
    { guardApplies: true, guardPassed: true, scrimRenders: true, hostPresent: true }));
  assert.ok(!print(applied).includes('WHICH ZERO IS THIS?'),
    'and it must not be printed when there is no zero to tell apart');
});

// ── 3. no gate authority (D81) ───────────────────────────────────────────────

test('c3 — this file states in its own header that it carries NO gate authority', () => {
  // The slice stops at the import block ON PURPOSE. The regex below is itself
  // part of this file, so a whole-file match would pass even with the header
  // deleted — the classic self-read that proves only that the test exists.
  const header = SELF.slice(0, SELF.indexOf('\nimport '));
  assert.ok(header.length > 0, 'the header must precede the imports');
  assert.match(header, /NO GATE AUTHORITY \(charter D81\)/,
    'a proof that could be mistaken for a fence is a fence — the header must say which it is');
  assert.match(header, /It is a proof, not a fence/,
    'and say it in words, not only by citation');
});

test('c3 — the seam this harness rests on is still exported', () => {
  for (const sym of [
    'export function printTable',
    'export function orderedStates',
    'export function assertEveryStateRendered',
    'export function summariseNonVacuity',
    'export function expectedRowCount',
    'export const STATE_IDS',
  ]) {
    assert.ok(SRC.includes(sym),
      `${sym} is the seam that makes this proof possible without a 30-60s authenticated sweep — ` +
      `un-exporting it silently deletes the only place the tripwire is ever seen to fire`);
  }
});
