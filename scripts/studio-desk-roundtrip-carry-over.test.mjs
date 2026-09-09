#!/usr/bin/env node
//
// studio-desk-roundtrip-carry-over.test.mjs — the red test for the seeded-open
// carry-over refusal in `runRoundTrip`.
//
// THE DEFECT IT HOLDS SHUT. `runRoundTrip` descends nine widths on one page
// instance and never reloads, so each width's baseline is the state the
// previous width's dismiss left behind — a CLOSED panel. At a wide-bucket width
// the seeded default is OPEN, so the open leg needs TWO real clicks (the first
// closes, the second re-opens and stamps [data-user-opened]). Reaching the
// marker in ONE click at a wide width is therefore only possible from a panel
// that was already closed, and the `before` that width captured is a
// closed-panel reading published as the seeded default.
//
// THIS IS NOT A HYPOTHETICAL. The fixture is not invented: it is the committed
// deployed round-2 artefact `spd-bracketed-deployed-run1-2026-07-22.json`,
// replayed leg for leg. It records open_clicks 2 at 1440 and open_clicks 1 at
// 1280 — both wide — and a 1280 before-leg of content_px 640 (the CLOSED
// column) where the matrix for the same width says 599 (open). A +44px "desk
// drift" was filed off that cell (spd-w13, PR #16309). Run2 carries the same
// shape, so the test asserts it in both artefacts: the witness is reproducible,
// not one bad night.
//
// NO BROWSER, NO NETWORK, NO DEPLOYED DESK. `runRoundTrip` takes its four
// page-touching edges (settle, readStamp, open, dismiss) by injection, so this
// file drives the REAL control flow — which width is skipped, which cells are
// counted, what the rollup then refuses to claim — against a replay. A
// predicate test could not have proved any of that.
//
//   node --test scripts/studio-desk-roundtrip-carry-over.test.mjs

import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import { runRoundTrip, seededOpenCarryOver } from './studio-desk-measure.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ARTEFACTS = {
  run1: path.join(HERE, 'measurements', 'spd-bracketed-deployed-run1-2026-07-22.json'),
  run2: path.join(HERE, 'measurements', 'spd-bracketed-deployed-run2-2026-07-22.json'),
};
const readArtefact = (p) => JSON.parse(fs.readFileSync(p, 'utf8')).round_trip;

/** The one face this replay drives. Three would prove the same thing three times. */
const NATIVE = [{ id: 'native', override: null, note: 'replay of the artefact native face' }];

/**
 * Replay one committed artefact's round-trip legs as the injected edges.
 *
 * Every number handed to `runRoundTrip` comes out of the artefact: the stamp and
 * the real inner width from `bucket_precondition_before`, the click counts from
 * `open_clicks`/`dismiss_clicks`, the reading-column figures from the recorded
 * `before`/`after` maps. Nothing is synthesised except the object wrapper the
 * ROUND_TRIP_FIELDS getters read through.
 */
function replay(artefact, viewports) {
  const byWidth = new Map(artefact.widths.map((w) => [w.viewport_px, w]));
  for (const px of viewports) assert.ok(byWidth.has(px), `artefact has no ${px}px leg`);

  let current = null;
  let phase = 'before';
  const seen = { viewports: [], opens: [], dismisses: [] };

  const page = {
    async setViewportSize({ width }) {
      current = byWidth.get(width);
      phase = 'before';
      seen.viewports.push(width);
    },
  };

  const measureFace = async (face) => {
    const rec = current.faces.find((f) => f.face === face.id);
    assert.ok(rec, `artefact leg ${current.viewport_px}px has no ${face.id} face`);
    const src = rec[phase];
    return {
      content_px: src.content_px,
      content_ch: src.content_ch,
      visible_content_px: src.visible_content_px,
      visible_ch: src.visible_ch,
      ch: { probe_px_per_ch: src.px_per_ch },
      gutter: { total_px: src.gutter_px },
    };
  };

  const deps = {
    widths: viewports,
    faces: NATIVE,
    settle: async () => {},
    readStamp: async () => ({
      real_inner_width: current.bucket_precondition_before.real_inner_width,
      width_bucket_stamped: current.bucket_precondition_before.width_bucket_stamped,
    }),
    open: async () => {
      seen.opens.push(current.viewport_px);
      return {
        reached: true,
        clicks_needed: current.open_clicks,
        control: '[data-test-id="sidebar-toggle-panel"]',
        grammar: 'replayed',
      };
    },
    dismiss: async () => {
      seen.dismisses.push(current.viewport_px);
      phase = 'after';
      return {
        dismissed: true,
        clicks_needed: current.dismiss_clicks,
        control: current.dismiss_control,
        grammar: current.dismiss_grammar,
      };
    },
  };

  return { page, measureFace, deps, seen };
}

// ── the witness, asserted against the committed artefacts ────────────────────
//
// A fixture that no longer matches the thing it was cut from proves nothing. If
// these artefacts are ever regenerated without the carry-over, this arm reds
// FIRST and says so, rather than letting the guard test pass over a fixture the
// defect has left.

for (const [name, file] of Object.entries(ARTEFACTS)) {
  test(`${name}: the committed 2026-07-22 artefact carries the carry-over witness`, () => {
    const rt = readArtefact(file);
    const w1440 = rt.widths.find((w) => w.viewport_px === 1440);
    const w1280 = rt.widths.find((w) => w.viewport_px === 1280);

    assert.equal(w1440.expected_raw_band, 'wide');
    assert.equal(w1280.expected_raw_band, 'wide');
    // Two clicks at 1440: the seeded default WAS open there.
    assert.equal(w1440.open_clicks, 2);
    // One click at 1280: only reachable from an already-closed panel.
    assert.equal(w1280.open_clicks, 1);
    // And the before-leg it published is the CLOSED column, not the 599 the
    // matrix reports for the same width.
    assert.equal(w1280.faces.find((f) => f.face === 'native').before.content_px, 640);
  });
}

// ── the predicate, both directions ───────────────────────────────────────────

test('seededOpenCarryOver fires on one click at a wide width and names it', () => {
  const found = seededOpenCarryOver({ viewport_px: 1280, raw_band: 'wide', open_clicks: 1 });
  assert.ok(found, 'the wide-bucket one-click shape must be refused');
  assert.equal(found.id, 'seeded-open-carry-over');
  assert.equal(found.instrument_failure, true);
  assert.equal(found.viewport_px, 1280);
  assert.match(found.message, /INSTRUMENT FAILURE/);
  assert.match(found.message, /1280px/, 'the refusal must NAME the width');
});

test('seededOpenCarryOver is band-scoped and click-scoped, not a blanket refusal', () => {
  // The healthy wide leg: two clicks, the seeded-open default.
  assert.equal(seededOpenCarryOver({ viewport_px: 1440, raw_band: 'wide', open_clicks: 2 }), null);
  // Below wide the panel is PAINTED closed, so one click is the correct and
  // expected cost — refusing it would withdraw seven of the nine widths.
  assert.equal(seededOpenCarryOver({ viewport_px: 1024, raw_band: 'standard', open_clicks: 1 }), null);
  assert.equal(seededOpenCarryOver({ viewport_px: 500, raw_band: 'phone', open_clicks: 1 }), null);
});

// ── the leg itself, driven ───────────────────────────────────────────────────

test('runRoundTrip refuses the 1280 leg that inherited the dismissed panel', async () => {
  const rt = readArtefact(ARTEFACTS.run1);
  const { page, measureFace, deps, seen } = replay(rt, [1440, 1280]);
  const run = { warnings: [] };

  const out = await runRoundTrip(page, measureFace, run, deps);

  // The refusal, by width.
  assert.deepEqual(out.widths_refused_for_seeded_open_carry_over, [1280]);
  assert.equal(out.seeded_open_carry_over.length, 1);
  assert.equal(out.seeded_open_carry_over[0].viewport_px, 1280);
  assert.match(run.warnings.join('\n'), /INSTRUMENT FAILURE \(seeded-open carry-over\) at viewport 1280px/);

  // NO round_trip cell for that width. The whole point: the closed-panel
  // baseline never reaches `cells`, so nothing downstream can average it in.
  const refused = out.widths.find((w) => w.viewport_px === 1280);
  assert.deepEqual(refused.faces, []);
  assert.ok(refused.refused_for_seeded_open_carry_over);
  // One face x one measured width (1440). Before the guard this was TWO.
  assert.equal(out.cells, 1);
  assert.equal(out.identical_cells, 1);

  // THE SILENT 640, PRESERVED BUT NOT COUNTED. This is the exact figure the
  // pre-guard instrument published as the 1280 baseline and that a +44px "desk
  // drift" was filed off. It is kept readable on the refused entry and it is
  // NOT a cell.
  assert.equal(refused.before_raw.native.content_px, 640);

  // Coverage is part of the claim: a sweep that skipped a width may not say the
  // desk returns bit-identical, even though every cell it DID take agreed.
  assert.equal(out.returns_bit_identical, false);

  // The refusal is taken INSTEAD of the dismiss, so the width leaves the panel
  // open and the next wide width self-heals rather than cascading.
  assert.deepEqual(seen.opens, [1440, 1280]);
  assert.deepEqual(seen.dismisses, [1440]);

  // And the grammar rollup does not speak for the width it never dismissed.
  assert.deepEqual(out.dismiss_grammar_by_width.map((w) => w.viewport_px), [1440]);
});

test('a healthy wide sweep is untouched — the guard costs nothing when nothing carried over', async () => {
  const rt = readArtefact(ARTEFACTS.run1);
  // 1440 alone is the seeded-open shape (open_clicks 2). Nothing to refuse.
  const { page, measureFace, deps } = replay(rt, [1440]);
  const run = { warnings: [] };

  const out = await runRoundTrip(page, measureFace, run, deps);

  assert.deepEqual(out.widths_refused_for_seeded_open_carry_over, []);
  assert.deepEqual(run.warnings, []);
  assert.equal(out.cells, 1);
  assert.equal(out.returns_bit_identical, true);
});
