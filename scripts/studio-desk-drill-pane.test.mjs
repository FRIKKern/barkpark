#!/usr/bin/env node
//
// studio-desk-drill-pane.test.mjs — the red test for charter D138's "failure C".
//
// WHAT BROKE. `openPapersPane()` clicked the "Papers" type row and then called
// `waitForDeskSettled()`, which is a QUIESCENCE detector: it returns as soon as
// its structural signature has held still for 800ms. The pre-click desk is
// already still, so the wait fired BEFORE the LiveView patch that appends the
// Papers pane column — measured live against guerrilla at served sha
// 9a837ed38 on 2026-09-06, the second `.pane-column` appears between t+1000ms
// and t+2000ms after the click. `page.locator('.pane-column').last()` then
// returned the ROOT pane, whose rows are document TYPES ("paper", "sheet",
// "rest", ...) and which reach `[phx-click="select"]` through the same
// catch-all `pane_item` a document row does. Five sequential invocations
// aborted 5 of 5 with `the Papers list has no row with phx-value-id="..."`,
// listing five type names as if they were a short document list.
//
// THE FIX under test: `waitForNewPane()` is EDGE-triggered — it reads the pane
// count before the click and waits for it to GROW.
//
// WHY THIS IS A UNIT TEST AND NOT A BROWSER TEST. The defect is entirely in the
// wait's shape, not in the page: a wait that cannot outlast an 800ms quiet
// window is wrong against any page whose patch is slower than that. `now` is
// injected, so the 1.5s arrival that broke the instrument is simulated exactly,
// deterministically, in milliseconds.
//
//   node --test scripts/studio-desk-drill-pane.test.mjs
//   node scripts/node-test-floor.mjs --floor 4 scripts/studio-desk-drill-pane.test.mjs

import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import { PANE_COUNT, waitForNewPane } from './studio-desk-measure.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const INSTRUMENT = path.join(HERE, 'studio-desk-measure.mjs');

/**
 * A fake Playwright page whose `.pane-column` count goes 1 -> 2 at
 * `arrivesAtMs` on a FAKE clock that only `waitForTimeout` advances. Nothing
 * here sleeps; the whole suite runs in milliseconds.
 */
function fakePage({ arrivesAtMs, before = 1, after = 2 }) {
  const state = { t: 0, evaluates: 0 };
  return {
    state,
    now: () => state.t,
    async evaluate(_fn, src) {
      state.evaluates += 1;
      assert.equal(src, PANE_COUNT, 'the wait must read the pane count the drill reads');
      return state.t >= arrivesAtMs ? after : before;
    },
    async waitForTimeout(ms) { state.t += ms; },
  };
}

test('the pane arriving at t+1500ms is SEEN — the case that broke the drill', async () => {
  const page = fakePage({ arrivesAtMs: 1500 });
  const got = await waitForNewPane(page, 1, { now: page.now, pollMs: 100, timeoutMs: 20_000 });
  assert.equal(got.grew, true, 'a pane that arrives at 1.5s must be waited for');
  assert.equal(got.panes, 2);
  assert.ok(got.waited_ms >= 1500, `waited ${got.waited_ms}ms, needed >=1500`);
});

test('an 800ms budget — waitForDeskSettled\'s quiet window — MISSES it', async () => {
  const page = fakePage({ arrivesAtMs: 1500 });
  const got = await waitForNewPane(page, 1, { now: page.now, pollMs: 100, timeoutMs: 800 });
  assert.equal(got.grew, false,
    'this is the defect, pinned: 800ms of quiet is not arrival, and reading the last ' +
    'pane column here returns the ROOT pane');
  assert.equal(got.panes, 1);
});

test('a pane that never arrives returns grew:false rather than hanging', async () => {
  const page = fakePage({ arrivesAtMs: Number.POSITIVE_INFINITY });
  const got = await waitForNewPane(page, 1, { now: page.now, pollMs: 100, timeoutMs: 2_000 });
  assert.equal(got.grew, false);
  assert.equal(got.panes, 1);
  assert.ok(got.waited_ms >= 2_000);
});

test('openPapersPane is WIRED to the edge-triggered wait, not to quiescence alone', () => {
  const src = fs.readFileSync(INSTRUMENT, 'utf8');
  const fn = src.match(/async function openPapersPane\(page, base\) \{[\s\S]*?\n\}/);
  assert.ok(fn, 'openPapersPane not found — this test has lost its subject');
  const body = fn[0];
  assert.match(body, /waitForNewPane\(page, panesBefore\)/,
    'openPapersPane must wait for the pane count to GROW; a bare waitForDeskSettled after the ' +
    'click is the exact defect this file exists to catch');
  assert.match(body, /const panesBefore = /,
    'the pre-click count must be read before the click — an edge needs both sides');
  assert.ok(body.indexOf('panesBefore') < body.indexOf('typeItem.click()'),
    'the count must be read BEFORE the click, not after it');
});
