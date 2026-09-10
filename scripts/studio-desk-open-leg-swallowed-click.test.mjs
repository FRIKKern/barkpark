#!/usr/bin/env node
//
// studio-desk-open-leg-swallowed-click.test.mjs — the red test for charter
// D184's 1440 wide-bucket open-leg no-op.
//
// THE DEFECT IT HOLDS SHUT. Once in four full sweeps against `bc64d869a`, three
// real clicks on `[data-test-id="sidebar-toggle-panel"]` at 1440 never produced
// `[data-user-opened]`; the aside sat at `width_px 41, left_px 1399,
// user_opened false, bucket "wide"`. The filing read that as the desk refusing
// to re-open from the collapsed rail.
//
// THE HANDLER SOURCE SAYS OTHERWISE, and this file proves it by replaying the
// handler rather than by citing it. `Handlers.Paper.sidebar_toggle_panel/1`
// (api/lib/barkpark_web/live/studio/studio_live/handlers/paper.ex:198-206)
// assigns `sidebar_user_opened` the SAME value as `sidebar_open` on every pass,
// and at the wide bucket `next_open? = not open?` is a pure alternator. The
// first test below enumerates ALL FOUR entry states through that exact
// arithmetic and shows the marker landing in at most TWO clicks from every one
// of them. There is no state in which a collapsed rail declines to re-open —
// so a three-click failure proves at least two clicks never reached the
// handler at all.
//
// The old loop could not tell those apart: it captured the sidebar after every
// click and read exactly one field of it, `after.user_opened`. A click that
// collapsed the rail 300px -> 41px and a click that moved nothing both spent a
// third of the three-click budget and both produced the identical skip.
//
// WHAT IS MODELLED AND WHAT IS NOT, stated so nobody reads more into a green
// than is here. There is no browser: `page` is a stub whose `evaluate` answers
// the open leg's observe() probe from a state machine running the Elixir
// handler's arithmetic, and whose `click` either drives that machine or is
// swallowed. That makes the REAL `openInspectorByRealClick` control flow the
// thing under test — which budget a click spends, when the loop stops, what the
// skip text then says. It proves nothing about CSS or about a real LiveView
// socket; the real-DOM half is the browser-coupled forcing repro
// `scripts/measurements/__open-leg-wide-bucket-repro.mjs`.
//
//   node --test scripts/studio-desk-open-leg-swallowed-click.test.mjs

import test from 'node:test';
import assert from 'node:assert/strict';

import { classifyOpenClick, openInspectorByRealClick } from './studio-desk-measure.mjs';

const VIEWPORT = 1440;

/**
 * A desk whose toggle runs `sidebar_toggle_panel/1` verbatim, and which can
 * SWALLOW a bounded number of clicks after the rail first collapses — the
 * re-render swapping the button node under the pointer, or a socket that has
 * not finished joining. A swallowed click reaches no handler: the state is
 * untouched, which is exactly why the DOM after it is byte-identical.
 */
function makeDesk({
  bucket = 'wide',
  open = true,
  asked = false,
  swallowAfterCollapse = 0,
  neverStamps = false,
} = {}) {
  const state = { open, asked };
  let swallowsLeft = 0;
  let armed = false;
  const log = [];

  const render = () => {
    const width = state.open ? 300 : 41;
    return {
      user_opened: state.asked && !neverStamps,
      is_open_class: state.open,
      position: 'relative',
      transform: 'none',
      left_px: VIEWPORT - width,
      width_px: width,
      z_index: 'auto',
      bucket,
    };
  };

  const click = () => {
    if (swallowsLeft > 0) { swallowsLeft--; log.push('swallowed'); return; }
    // sidebar_toggle_panel/1, line for line.
    const open_ = state.open === true;
    const asked_ = state.asked === true;
    const wide_ = bucket === null || bucket === 'wide';
    const painted_closed_ = open_ && !asked_ && !wide_;
    const next_open_ = painted_closed_ ? true : !open_;
    state.open = next_open_;
    state.asked = next_open_;
    log.push(next_open_ ? 'opened' : 'collapsed');
    if (!next_open_ && !armed) { armed = true; swallowsLeft = swallowAfterCollapse; }
  };

  return { render, click, log, state };
}

/** The page stub. `evaluate` answers two callers and only two. */
function makePage(desk) {
  return {
    locator: () => ({ first: () => ({ count: async () => 1, click: async () => desk.click() }) }),
    evaluate: async (_fn, arg) => {
      // waitForDeskSettled passes SETTLE_SIGNATURE (a string) and wants a JSON
      // string back. A constant one settles as soon as its quiet window passes.
      if (typeof arg === 'string') {
        return JSON.stringify({ b: desk.render().bucket, n: 0, w: [], c: 0, p: -1, connected: true });
      }
      return desk.render();
    },
    waitForTimeout: (ms) => new Promise((r) => setTimeout(r, ms)),
  };
}

const outcomes = (r) => (r.click_log ?? r.clicks ?? []).map((c) => c.outcome);

// ── 1. the premise the filing got wrong ─────────────────────────────────────

test('sidebar_toggle_panel/1 reaches user-opened in <= 2 clicks from EVERY entry state', async () => {
  const seen = [];
  for (const bucket of ['wide', 'standard']) {
    for (const open of [true, false]) {
      for (const asked of [true, false]) {
        const desk = makeDesk({ bucket, open, asked });
        const r = await openInspectorByRealClick(makePage(desk), { fatal: false });
        assert.equal(r.reached, true,
          `bucket=${bucket} open=${open} asked=${asked} never reached the marker`);
        assert.ok(r.clicks_needed <= 2,
          `bucket=${bucket} open=${open} asked=${asked} took ${r.clicks_needed} clicks`);
        seen.push(`${bucket}/${open}/${asked}=${r.clicks_needed}`);
      }
    }
  }
  assert.equal(seen.length, 8);
});

// ── 2. the forcing case: two swallowed clicks after the collapse ────────────

test('the 1440 no-op: click 1 collapses 300->41, clicks 2-3 move NOTHING', async () => {
  const desk = makeDesk({ bucket: 'wide', open: true, asked: false, swallowAfterCollapse: 2 });
  const r = await openInspectorByRealClick(makePage(desk), { fatal: false });

  // WITHOUT the fix this is where the leg died: three clicks issued, budget
  // gone, terminal state width_px 41 / user_opened false / bucket wide — the
  // artefact's exact reading.
  assert.deepEqual(outcomes(r).slice(0, 3), ['collapsed-by-us', 'no-transition', 'no-transition']);
  assert.deepEqual(r.click_log[0].after, {
    user_opened: false, is_open_class: false, position: 'relative', transform: 'none',
    left_px: 1399, width_px: 41, z_index: 'auto', bucket: 'wide',
  });
  assert.deepEqual(r.click_log[1].after, r.click_log[0].after);
  assert.deepEqual(r.click_log[2].after, r.click_log[0].after);

  // WITH it: the two no-transition clicks spend the swallow allowance, not the
  // toggle budget, so the fourth click still has a toggle step to spend.
  assert.equal(r.reached, true);
  assert.equal(r.clicks_needed, 4);
  assert.equal(r.clicks_landed, 2);
  assert.equal(r.clicks_swallowed, 2);
  assert.equal(outcomes(r)[3], 'user-opened');
  assert.deepEqual(desk.log, ['collapsed', 'swallowed', 'swallowed', 'opened']);
});

// ── 3. the allowance is BOUNDED (D138), and the skip names the world ────────

test('swallowing past the allowance stops, and the verdict says SWALLOWED not refused', async () => {
  const desk = makeDesk({ bucket: 'wide', open: true, asked: false, swallowAfterCollapse: 99 });
  const r = await openInspectorByRealClick(makePage(desk), { fatal: false });
  assert.equal(r.reached, false);
  // 1 landed + 3 swallowed: the third is the one that trips the bound. A skip
  // returns no click_log, so the per-click record is read out of the text.
  assert.equal((r.skip_reason.match(/\[no-transition\]/g) ?? []).length, 3);
  assert.match(r.skip_reason, /1 landed, 3 swallowed/);
  assert.match(r.skip_reason, /moved NOTHING observable/);
  assert.match(r.skip_reason, /bounded allowance of 2 was exhausted/);
  assert.match(r.skip_reason, /\[no-transition\]/);
});

test('a desk that ANSWERS every click and still never stamps is called a DESK finding', async () => {
  const desk = makeDesk({ bucket: 'wide', open: true, asked: false, neverStamps: true });
  const r = await openInspectorByRealClick(makePage(desk), { fatal: false });
  assert.equal(r.reached, false);
  assert.match(r.skip_reason, /3 landed, 0 swallowed/);
  assert.match(r.skip_reason, /every one of those 3 click\(s\) LANDED/);
  assert.match(r.skip_reason, /DESK finding, not this harness running out of budget/);
});

// ── 4. the classifier itself ────────────────────────────────────────────────

test('classifyOpenClick separates collapsed-by-us from a click that moved nothing', () => {
  const wide = { user_opened: false, is_open_class: true, width_px: 300, left_px: 1140, transform: 'none' };
  const rail = { user_opened: false, is_open_class: false, width_px: 41, left_px: 1399, transform: 'none' };
  const opened = { ...wide, user_opened: true };

  assert.deepEqual(classifyOpenClick(wide, rail), { outcome: 'collapsed-by-us', landed: true });
  assert.deepEqual(classifyOpenClick(rail, wide), { outcome: 'widened', landed: true });
  assert.deepEqual(classifyOpenClick(rail, rail), { outcome: 'no-transition', landed: false });
  assert.deepEqual(classifyOpenClick(wide, opened), { outcome: 'user-opened', landed: true });
  assert.deepEqual(classifyOpenClick(rail, null), { outcome: 'sidebar-absent', landed: true });
  assert.deepEqual(classifyOpenClick(null, rail), { outcome: 'no-baseline', landed: true });

  // A transform-only move is still a move: the overlay regime slides the panel
  // in without changing its box.
  assert.equal(
    classifyOpenClick(rail, { ...rail, transform: 'matrix(1, 0, 0, 1, -41, 0)' }).landed, true);
});
