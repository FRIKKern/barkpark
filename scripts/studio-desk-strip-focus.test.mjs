#!/usr/bin/env node
//
// studio-desk-strip-focus.test.mjs — the committed pin on the shape of the
// spd-b21 strip-focus probe rows.
//
//   THIS HARNESS HAS NO GATE AUTHORITY (charter D81).
//   It proves the ROW SHAPE, not the desk. Nothing about the desk's focus
//   behaviour may be quoted from this file — only from a live run.
//
// WHY IT EXISTS. spd-b21-strip-focus-browser-proof closed 2026-09-06 on live
// readings taken by a scratch Playwright script in one worker's tmp dir: after
// keyboard Enter on the collapsed strip, `document.activeElement` is the
// expanded `div#pane-structure.pane-column` with `tabindex="-1"` (never BODY),
// `:focus-visible` matches, the outline computes to solid 2px rgb(18,141,170)
// with a -2px offset, and the focused node is the one the DOM patch ADDED —
// carrying `phx-mounted='[["focus",{}]]'`, with no competing focus event
// between the blur and the focus.
//
// That finding was true and UNREPEATABLE. The probe in studio-desk-measure.mjs
// makes it re-runnable; this file is the half that can run with no browser, no
// admin token and no ssh hop, and it defends the one thing a live run cannot
// defend against itself: a probe that QUIETLY STOPS RECORDING A FIELD. Drop
// `outline_offset` from the leg table and every live run still emits four
// plausible rows, exits 0, and says nothing at all about the ring — the reading
// stops being reproducible with nothing going red. So the field lists are
// pinned LITERALLY here, spelled out rather than derived from the constant they
// guard (a test that reads its expectation out of the thing it is testing
// passes for both values).
//
// Run: node --test scripts/studio-desk-strip-focus.test.mjs

import test from 'node:test';
import assert from 'node:assert/strict';

import {
  STRIP_FOCUS_LEGS,
  STRIP_FOCUS_FIELDS,
  buildStripFocusRows,
  inferPhxMountedFired,
  MeasureError,
} from './studio-desk-measure.mjs';

/** The legs and their fields, spelled out. Changing the instrument's table
 *  without changing this one is the failure this file exists to produce. */
const PINNED = {
  'active-element': ['active_selector', 'active_id', 'active_classes', 'active_tag', 'active_tabindex',
                     'active_is_BODY', 'active_is_pane_column_focus_target'],
  'focus-ring': ['active_focus_visible', 'outline_style', 'outline_width', 'outline_color', 'outline_offset'],
  'aria': ['strip_id', 'strip_tag', 'aria_controls', 'aria_controls_resolves',
           'aria_expanded', 'aria_expanded_present', 'aria_label'],
  'patch-and-focus-sequence': ['focus_event_kinds', 'focus_events', 'added_pane_count', 'added_pane_phx_mounted',
                               'added_pane_tabindex', 'focused_is_added_pane', 'focused_is_old_strip_node',
                               'old_strip_still_connected', 'competing_focus_events'],
};

/**
 * THE 2026-09-06 READING, transcribed from spd-b21-strip-focus-browser-proof's
 * evidence (served guerrilla 2fe7ddd3a, viewport 900x900, two cold loads
 * identical). It is a FIXTURE, not a measurement: it proves the builder accepts
 * the shape the live desk produced, and nothing about today's desk.
 */
const READING_2026_09_06 = () => ({
  active_selector: 'div#pane-structure.pane-column.pane-column--last',
  active_id: 'pane-structure',
  active_classes: 'pane-column pane-column--last',
  active_tag: 'DIV',
  active_tabindex: '-1',
  active_is_BODY: false,
  active_is_pane_column_focus_target: true,

  active_focus_visible: true,
  outline_style: 'solid',
  outline_width: '2px',
  outline_color: 'rgb(18, 141, 170)',
  outline_offset: '-2px',

  strip_id: 'pane-structure',
  strip_tag: 'BUTTON',
  aria_controls: 'studio-panes',
  aria_controls_resolves: true,
  aria_expanded: null,
  aria_expanded_present: false,
  aria_label: 'Structure',

  focus_event_kinds: ['blur', 'focusout', 'focus', 'focusin'],
  focus_events: [
    { t_ms: 0.1, kind: 'blur', target: { sel: 'button#pane-structure', id: 'pane-structure', tag: 'BUTTON' }, related: null },
    { t_ms: 0.2, kind: 'focusout', target: { sel: 'button#pane-structure', id: 'pane-structure', tag: 'BUTTON' }, related: null },
    { t_ms: 42.5, kind: 'focus', target: { sel: 'div#pane-structure', id: 'pane-structure', tag: 'DIV' }, related: null },
    { t_ms: 42.6, kind: 'focusin', target: { sel: 'div#pane-structure', id: 'pane-structure', tag: 'DIV' }, related: null },
  ],
  added_pane_count: 1,
  added_pane_phx_mounted: '[["focus",{}]]',
  added_pane_tabindex: '-1',
  focused_is_added_pane: true,
  focused_is_old_strip_node: false,
  old_strip_still_connected: false,
  competing_focus_events: [],
});

const STAMP = {
  viewport_px: 900,
  bucket: 'narrow',
  measured_at: '2026-09-06T10:21:00.000Z',
  served_sha: '2fe7ddd3a',
  slot_active: ['green'],
};

// ── the leg table ────────────────────────────────────────────────────────────

test('the leg table is exactly four legs, in order, with the pinned ids', () => {
  assert.deepEqual(STRIP_FOCUS_LEGS.map((l) => l.id),
    ['active-element', 'focus-ring', 'aria', 'patch-and-focus-sequence']);
});

test('each leg records exactly the pinned fields — a dropped field reds HERE', () => {
  for (const leg of STRIP_FOCUS_LEGS) {
    assert.deepEqual(leg.fields, PINNED[leg.id],
      `leg "${leg.id}" no longer records the fields the 2026-09-06 reading rested on`);
  }
});

test('STRIP_FOCUS_FIELDS is the flattened union, with no duplicate field names', () => {
  assert.deepEqual(STRIP_FOCUS_FIELDS, Object.values(PINNED).flat());
  assert.equal(new Set(STRIP_FOCUS_FIELDS).size, STRIP_FOCUS_FIELDS.length,
    'two legs record the same field name — a row would then carry it twice with no way to say which leg meant it');
});

test('every leg states the question it answers', () => {
  for (const leg of STRIP_FOCUS_LEGS) {
    assert.equal(typeof leg.question, 'string');
    assert.ok(leg.question.length > 10, `leg "${leg.id}" has no readable question`);
  }
});

// ── the builder ──────────────────────────────────────────────────────────────

test('a complete reading builds one row per leg, each carrying the provenance stamp', () => {
  const rows = buildStripFocusRows(READING_2026_09_06(), STAMP);
  assert.equal(rows.length, 4);
  assert.deepEqual(rows.map((r) => r.leg), STRIP_FOCUS_LEGS.map((l) => l.id));
  for (const row of rows) {
    assert.equal(row.probe, 'spd-b21 strip-focus');
    assert.equal(row.viewport_px, 900);
    assert.equal(row.bucket, 'narrow');
    assert.equal(row.measured_at, STAMP.measured_at);
    assert.equal(row.served_sha, '2fe7ddd3a');
    assert.deepEqual(row.slot_active, ['green']);
    assert.equal(row.keyboard_only, true);
    assert.match(row.probe_note, /no gate authority/);
    assert.match(row.criterion, /spd-b21/);
  }
});

test('a row carries its own leg\'s fields and NOTHING from another leg', () => {
  const rows = buildStripFocusRows(READING_2026_09_06(), STAMP);
  for (const row of rows) {
    assert.deepEqual(Object.keys(row.reading), PINNED[row.leg]);
  }
});

test('an absent stamp yields explicit nulls, never a row that omits provenance', () => {
  const [row] = buildStripFocusRows(READING_2026_09_06());
  for (const k of ['viewport_px', 'bucket', 'measured_at', 'served_sha', 'slot_active']) {
    assert.ok(k in row, `${k} missing from the row`);
    assert.equal(row[k], null);
  }
});

// ── the mutation arm: drop a field, get a named refusal ───────────────────────

test('dropping ANY ONE declared field refuses by name, for all 28 fields', () => {
  let checked = 0;
  for (const leg of STRIP_FOCUS_LEGS) {
    for (const field of leg.fields) {
      const reading = READING_2026_09_06();
      delete reading[field];
      assert.throws(
        () => buildStripFocusRows(reading, STAMP),
        (err) => {
          assert.ok(err instanceof MeasureError, `${field}: threw ${err?.constructor?.name}, not MeasureError`);
          assert.match(err.message, new RegExp(`${leg.id}\\.${field}\\b`),
            `${field}: the refusal does not name the missing field and its leg`);
          assert.match(err.message, /missing 1 declared field/);
          return true;
        },
        `dropping ${leg.id}.${field} did NOT refuse — the probe would emit four plausible rows saying nothing about it`,
      );
      checked++;
    }
  }
  assert.equal(checked, STRIP_FOCUS_FIELDS.length);
  assert.equal(checked, 28, 'the field count moved — update the pin deliberately, in the PR that moves it');
});

test('an explicit undefined is the same refusal as an absent key', () => {
  const reading = READING_2026_09_06();
  reading.outline_offset = undefined;
  assert.throws(() => buildStripFocusRows(reading, STAMP), /focus-ring\.outline_offset/);
});

test('null is a LEGITIMATE reading — an absent attribute is a fact, not a gap', () => {
  const reading = READING_2026_09_06();
  reading.aria_expanded = null;
  reading.aria_label = null;
  const rows = buildStripFocusRows(reading, STAMP);
  const aria = rows.find((r) => r.leg === 'aria');
  assert.equal(aria.reading.aria_expanded, null);
  assert.equal(aria.reading.aria_label, null);
});

test('several missing fields are ALL named, not just the first', () => {
  const reading = READING_2026_09_06();
  delete reading.active_is_BODY;
  delete reading.outline_color;
  delete reading.competing_focus_events;
  assert.throws(() => buildStripFocusRows(reading, STAMP), (err) => {
    assert.match(err.message, /missing 3 declared field/);
    assert.match(err.message, /active-element\.active_is_BODY/);
    assert.match(err.message, /focus-ring\.outline_color/);
    assert.match(err.message, /patch-and-focus-sequence\.competing_focus_events/);
    return true;
  });
});

test('no reading at all refuses rather than emitting rows describing nothing', () => {
  for (const bad of [null, undefined, 'a reading', 42]) {
    assert.throws(() => buildStripFocusRows(bad, STAMP), MeasureError);
  }
});

// ── the phx-mounted inference ────────────────────────────────────────────────

test('the 2026-09-06 reading infers phx-mounted FIRED, with all four links held', () => {
  const inf = inferPhxMountedFired(READING_2026_09_06());
  assert.equal(inf.inferred, true, 'it must never present as an observation');
  assert.equal(inf.fired, true);
  assert.deepEqual(inf.broken, []);
  assert.deepEqual(inf.links.map((l) => l.id), [
    'focus-landed-on-added-node',
    'added-node-carries-phx-mounted',
    'no-competing-focus-event',
    'focused-node-is-not-the-old-strip',
  ]);
  assert.match(inf.note, /INFERENCE, never an observation/);
});

test('each of the four refuters, alone, breaks the inference BY NAME', () => {
  const cases = [
    ['focus-landed-on-added-node', (r) => { r.focused_is_added_pane = false; }],
    ['added-node-carries-phx-mounted', (r) => { r.added_pane_phx_mounted = null; }],
    ['no-competing-focus-event', (r) => { r.competing_focus_events = [{ kind: 'focus', target: { sel: 'input#q', id: 'q', tag: 'INPUT' } }]; }],
    ['focused-node-is-not-the-old-strip', (r) => { r.focused_is_old_strip_node = true; }],
  ];
  for (const [id, break_] of cases) {
    const reading = READING_2026_09_06();
    break_(reading);
    const inf = inferPhxMountedFired(reading);
    assert.equal(inf.fired, false, `${id}: the inference survived its own refuter`);
    assert.deepEqual(inf.broken, [id]);
  }
});

test('a phx-mounted attribute that is not a focus command does NOT hold the link', () => {
  const reading = READING_2026_09_06();
  reading.added_pane_phx_mounted = '[["show",{}]]';
  assert.deepEqual(inferPhxMountedFired(reading).broken, ['added-node-carries-phx-mounted']);
});

test('the inference reports inferred:true even when it fires negative', () => {
  const reading = READING_2026_09_06();
  reading.focused_is_added_pane = false;
  assert.equal(inferPhxMountedFired(reading).inferred, true);
});
