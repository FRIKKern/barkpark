#!/usr/bin/env node
//
// studio-desk-instrument-reliability.test.mjs — the red tests for the three
// rulings D138 left unwritten. Each one exists because a specific sentence in
// `spd-instrument-nondeterminism-characterised` was true of the shipped
// instrument and would silently become true again if the code regressed:
//
//   1. "No gate currently fails on face_applied=false." A forced-face row whose
//      face did not apply was published WITH ITS 55ch VERDICTS INTACT — a ch
//      computed through a face nobody asked for, carrying a FALSE into a ruling
//      cell. Now the verdicts are withdrawn to NULL and the run carries a
//      machine-readable integrity block.
//   2. "The wave-9 brief authorised bounded retries only on the
//      [data-user-opened] abort, so an operator meeting THIS abort has no
//      written authority to retry it and must deviate." A list of one is not a
//      policy. `RETRYABLE_ABORTS` is the list, and this file holds it to the
//      code in BOTH directions — a new `dieRetryable` id that is not in the
//      table, and a table entry no site throws, both red here.
//   3. "The harness pins no channel, so a fresh runner fails at launch with an
//      error that looks like an instrument bug." Now it fails by name, with the
//      install command, and every run records which browser measured it.
//
// None of this needs a browser or the network: every unit under test is pure,
// or takes its one impure edge (the clock, the launcher) by injection.
//
//   node --test scripts/studio-desk-instrument-reliability.test.mjs

import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import {
  BROWSER_POLICIES,
  PAGE_MEASURE,
  MeasureError,
  RETRYABLE_ABORTS,
  browserPolicy,
  emptyFaceIntegrity,
  isMissingBrowserError,
  launchMeasureBrowser,
  missingBrowserMessage,
  parseRetries,
  recordFaceSubstitution,
  runWithRetries,
  withdrawVerdictsForFaceSubstitution,
} from './studio-desk-measure.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const INSTRUMENT = path.join(HERE, 'studio-desk-measure.mjs');
const SRC = fs.readFileSync(INSTRUMENT, 'utf8');

// The exact text playwright produced for every wave-11 verifier.
const WAVE_11_LAUNCH_ERROR =
  "browserType.launch: Executable doesn't exist at " +
  '/Users/x/Library/Caches/ms-playwright/chromium_headless_shell-1200/chrome-mac/headless_shell\n' +
  '╔════════════════════════════════════════════════════════════╗\n' +
  '║ Looks like Playwright was just installed or updated.       ║\n' +
  '║ Please run the following command to download new browsers: ║\n' +
  '║     npx playwright install                                 ║\n' +
  '╚════════════════════════════════════════════════════════════╝';

// ── RULING 1 — a substituted face withdraws the row's verdicts ───────────────

/** A forced-face row as `measureFace` returns it, with the face NOT applied —
 *  the exact shape D138 recorded at 640 / user-opened / source-serif-4. */
function substitutedRow() {
  return {
    content_meets_55ch: false,
    visible_meets_55ch: false,
    content_px: 548,
    visible_content_px: 270.967,
    ch: { probe_px_per_ch: 10 },
    font: {
      face_applied: false,
      requested_primary: 'Source Serif 4',
      resolved_family: 'Iowan Old Style',
      declared_stack: '"Iowan Old Style", Palatino, Georgia, serif',
    },
  };
}

function appliedRow() {
  const r = substitutedRow();
  r.font = { ...r.font, face_applied: true, resolved_family: 'Source Serif 4' };
  return r;
}

const SOURCE_SERIF = { id: 'source-serif-4', override: "'Source Serif 4', serif" };

test('a substituted face withdraws BOTH 55ch verdicts to NULL, never to FALSE', () => {
  const out = withdrawVerdictsForFaceSubstitution(substitutedRow(), SOURCE_SERIF);
  assert.equal(out.content_meets_55ch, null,
    'FALSE here would say "this desk fails 55ch on Source Serif 4" — and Source Serif 4 was never ' +
    'on screen. The honest value is NULL.');
  assert.equal(out.visible_meets_55ch, null);
  assert.equal(out.verdicts_withdrawn_for_face_substitution.content_meets_55ch, false,
    'the raw verdict must be preserved, not erased');
  assert.equal(out.verdicts_withdrawn_for_face_substitution.resolved_family, 'Iowan Old Style');
});

test('the px measurements SURVIVE the withdrawal — only the ch conversion was wrong', () => {
  const out = withdrawVerdictsForFaceSubstitution(substitutedRow(), SOURCE_SERIF);
  assert.equal(out.content_px, 548);
  assert.equal(out.visible_content_px, 270.967,
    'D138 measured the layout box IDENTICAL across the flake. Discarding it would throw away a ' +
    'real observation to punish a font.');
});

test('an applied face is left completely alone', () => {
  const run = { warnings: [], face_override_integrity: emptyFaceIntegrity() };
  const out = recordFaceSubstitution(run, 'viewport 1280px / default / face "georgia"', appliedRow(), SOURCE_SERIF);
  assert.equal(out.content_meets_55ch, false, 'a real verdict on a real face must not be withdrawn');
  assert.equal(run.face_override_integrity.clean, true);
  assert.equal(run.face_override_integrity.forced_rows_checked, 1);
  assert.equal(run.warnings.length, 0);
});

test('a substitution makes the run integrity block DIRTY and names the cell', () => {
  const run = { warnings: [], face_override_integrity: emptyFaceIntegrity() };
  const where = 'viewport 1280px / default / face "source-serif-4"';
  const out = recordFaceSubstitution(run, where, substitutedRow(), SOURCE_SERIF);
  assert.equal(out.content_meets_55ch, null);
  assert.equal(run.face_override_integrity.clean, false,
    'this boolean IS the gate --fail-on-face-substitution reads');
  assert.deepEqual(run.face_override_integrity.substitutions.map((x) => x.where), [where]);
  assert.equal(run.warnings.length, 1);
  assert.match(run.warnings[0], /FACE SUBSTITUTION/);
});

test('the sweep is WIRED to the withdrawal, not to a bare warning', () => {
  assert.match(SRC, /rec = recordFaceSubstitution\(run, `viewport \$\{width\}px/,
    'the sweep must route a forced-face row through recordFaceSubstitution and REBIND rec — the ' +
    'pre-2026-09 shape pushed a warning and published the row with its verdicts intact');
  assert.doesNotMatch(SRC, /this row's ch is NOT the named face\.`\);\n\s*\}/,
    'the old warn-only block is the exact defect ruled on; it must not come back beside the new one');
  assert.match(SRC, /--fail-on-face-substitution/,
    'the run-level gate must exist for a caller that wants one (D81 keeps it off by default)');
});

test('the gate exit happens AFTER the artifact is written — never a zero-byte run', () => {
  const write = SRC.indexOf('if (OUT_PATH) writeRunArtifact(run, OUT_PATH);');
  const gate = SRC.indexOf('FAIL_ON_FACE_SUBSTITUTION && integrity');
  assert.ok(write > 0 && gate > 0, 'both anchors must exist');
  assert.ok(write < gate,
    'D138 rules a zero-byte run an INSTRUMENT FAILURE. A gate that exits before the artifact is ' +
    'on disk manufactures exactly that, and the finding it was gating would be unreadable.');
});

// ── RULING 1b — is the flake REACHABLE into D107's seven desktop widths? ────
//
// D138 saw failure A once, at 640 / user-opened / source-serif-4 — a phone
// width, outside D107's seven. The open question the ledger row names is not
// "how often" but "can it land on a RULING cell", because if it can, a later
// wave's re-run can move the failing-cell count and 'overturn' a ruling that
// was never wrong.
//
// It cannot be settled by waiting for it: an N-run sweep that never sees it
// proves nothing about reachability (absence of an event is not a proof of
// impossibility), and one that does see it at 1280 would have settled it by
// luck. It IS settled mechanically, here: the face is forced and resolved by a
// single stretch of `PAGE_MEASURE` that reads no viewport quantity at all. Same
// code, same inputs, at every one of the nine widths — so a substitution
// possible at 640 is possible at 1280, and the answer is PROVEN POSSIBLE.

test('the face-forcing path reads NO viewport quantity — so it cannot be width-bound', () => {
  const from = PAGE_MEASURE.indexOf('if (faceOverride) surface.style.setProperty');
  const to = PAGE_MEASURE.indexOf('let winner = null;');
  assert.ok(from > 0 && to > from, 'the force -> resolve stretch must be locatable');
  const region = PAGE_MEASURE.slice(from, to);
  for (const viewportRead of ['innerWidth', 'outerWidth', 'matchMedia', 'devicePixelRatio', 'screen.',
                              'width_bucket', 'clientWidth']) {
    assert.ok(!region.includes(viewportRead),
      `the face is forced and resolved without reading ${viewportRead}. If that ever stops being ` +
      'true, D138 failure A acquires a width dependence and this test\'s reachability argument — ' +
      "PROVEN POSSIBLE at all nine widths, D107's seven included — has to be re-made from scratch.");
  }
  assert.match(region, /document\.fonts\.load/,
    'non-vacuity: this region must really be the face-forcing stretch — if the anchors ever drift ' +
    'past it, the loop above would pass over an empty string and prove nothing');
});

test('face_applied is derived from the resolved family alone, not from the width', () => {
  const line = PAGE_MEASURE.match(/face_applied: [^\n]*/);
  assert.ok(line, 'face_applied must still be a single derived expression');
  assert.match(line[0], /winner === wantedFamilies\[0\]/);
  assert.doesNotMatch(line[0], /width|viewport|bucket/i,
    'a width term here would make the flake width-bound — and would also make the matrix lie about ' +
    'which cells were measured on the face they name');
});

// ── RULING 2 — bounded retries, on the named aborts only ─────────────────────

test('every dieRetryable call site uses an id that is IN the table', () => {
  const ids = [...SRC.matchAll(/dieRetryable\(\s*'([a-z-]+)'/g)].map((m) => m[1]);
  assert.ok(ids.length >= 5, `expected the five named aborts, found ${ids.length}`);
  const known = new Set(RETRYABLE_ABORTS.map((a) => a.id));
  for (const id of ids) {
    assert.ok(known.has(id), `dieRetryable('${id}') is not in RETRYABLE_ABORTS — a retry earns its ` +
      'authority by being named in that table, never by being thrown from a convenient helper');
  }
});

test('every table entry is actually THROWN somewhere — no phantom authority', () => {
  const ids = new Set([...SRC.matchAll(/dieRetryable\(\s*'([a-z-]+)'/g)].map((m) => m[1]));
  for (const a of RETRYABLE_ABORTS) {
    assert.ok(ids.has(a.id),
      `RETRYABLE_ABORTS names "${a.id}" but nothing throws it. A table that over-promises tells an ` +
      'operator they may retry a failure that will never occur, and hides the one that will.');
  }
});

test('the five aborts D138 met are all named', () => {
  const ids = RETRYABLE_ABORTS.map((a) => a.id);
  for (const expected of ['drill', 'user-opened-marker', 'provenance-bracket']) {
    assert.ok(ids.includes(expected),
      `"${expected}" was observed aborting a real run; dropping it from the table silently ` +
      'withdraws the operator\'s authority to re-run it');
  }
});

test('a retryable abort is retried up to N times and no further', async () => {
  let calls = 0;
  const seen = [];
  await assert.rejects(
    runWithRetries(async () => {
      calls += 1;
      throw new MeasureError(`abort ${calls}`, { retryable: true, abortId: 'drill' });
    }, 2, { onRetry: (r) => seen.push(r.attempt) }),
    (err) => err instanceof MeasureError && err.attempts.length === 3,
  );
  assert.equal(calls, 3, 'retries=2 means THREE attempts, not two and not four');
  assert.deepEqual(seen, [1, 2], 'onRetry fires once per RETRIED attempt, never for the last one');
});

test('a TERMINAL failure is never retried, at any N', async () => {
  let calls = 0;
  await assert.rejects(
    runWithRetries(async () => { calls += 1; throw new MeasureError('banned generic serif'); }, 10),
    /banned generic serif/);
  assert.equal(calls, 1,
    'retrying a terminal failure burns two more authenticated sweeps to reprint the same sentence');
});

test('a plain Error is terminal too — only a NAMED abort is retryable', async () => {
  let calls = 0;
  await assert.rejects(runWithRetries(async () => { calls += 1; throw new Error('boom'); }, 3), /boom/);
  assert.equal(calls, 1);
});

test('every failed attempt is handed to onRetry IN FULL — the D138-B hole, closed', async () => {
  const messages = [];
  const { value, attempt } = await runWithRetries(async (n) => {
    if (n < 3) throw new MeasureError(`stderr of attempt ${n}`, { retryable: true, abortId: 'drill' });
    return 'the matrix';
  }, 2, { onRetry: (r) => messages.push(r.message) });
  assert.equal(value, 'the matrix');
  assert.equal(attempt, 3, 'the caller must be able to say WHICH attempt produced the matrix');
  assert.deepEqual(messages, ['stderr of attempt 1', 'stderr of attempt 2'],
    'failure B has no diagnosis today for exactly one reason: its stderr was suppressed and is ' +
    'gone. A retry loop that swallows the attempts it retried rebuilds that hole inside the ' +
    'instrument, where nobody would think to look for it.');
});

test('the retry loop prints each failed attempt to stderr before the next one', () => {
  const wire = SRC.match(/onRetry: \(\{[^}]*\}\) => \{[\s\S]*?\},\n\s*\}\)\)/);
  assert.ok(wire, 'the invocation chain must pass an onRetry — a silent retry is the defect');
  assert.match(wire[0], /process\.stderr\.write/);
  assert.match(wire[0], /\$\{message\}/, 'the full message, not a summary of it');
});

test('parseRetries: default 2, flag beats env, junk is refused', () => {
  assert.equal(parseRetries([], {}), 2);
  assert.equal(parseRetries([], { BP_DESK_RETRIES: '0' }), 0);
  assert.equal(parseRetries(['--retries=5'], { BP_DESK_RETRIES: '0' }), 5);
  for (const bad of ['-1', '2.5', 'two', '', '11', ' ']) {
    assert.throws(() => parseRetries([`--retries=${bad}`], {}), MeasureError,
      `--retries=${JSON.stringify(bad)} must be refused, not coerced`);
  }
});

// ── RULING 3 — the browser is provenance ─────────────────────────────────────

test('the default policy is the BUNDLED chromium, and it says so', () => {
  const p = browserPolicy({});
  assert.equal(p.id, 'bundled');
  assert.equal(p.channel, null, 'bundled means no channel — the launch stays reproducible');
  assert.equal(p.source, 'default');
});

test('BP_DESK_BROWSER=chrome pins the system channel', () => {
  const p = browserPolicy({ BP_DESK_BROWSER: 'chrome' });
  assert.equal(p.channel, 'chrome');
  assert.equal(p.source, 'BP_DESK_BROWSER',
    'the artifact must be able to say the policy was CHOSEN, not inherited');
});

test('an unknown policy is refused by name rather than silently defaulted', () => {
  assert.throws(() => browserPolicy({ BP_DESK_BROWSER: 'firefox' }), /not a browser policy/);
});

test("playwright's missing-executable error is recognised as a PREREQUISITE", () => {
  assert.equal(isMissingBrowserError(new Error(WAVE_11_LAUNCH_ERROR)), true);
  assert.equal(isMissingBrowserError(new Error('Timeout 30000ms exceeded')), false,
    'a timeout is not a missing browser; translating it would hide a real failure');
});

test('the message names the exact install command, not a stack trace', () => {
  const msg = missingBrowserMessage(new Error(WAVE_11_LAUNCH_ERROR), browserPolicy({}));
  assert.match(msg, /npx playwright install chromium/,
    'the ledger row asks for this literal command — "npx playwright install" alone downloads ' +
    'every browser and was what the raw trace already said');
  assert.match(msg, /nothing was measured/,
    'D97: a launch failure says NOTHING about the desk and must not read as one');
  assert.match(msg, /BP_DESK_BROWSER=chrome/, 'the other policy must be reachable from the failure');
});

test('launchMeasureBrowser turns the wave-11 wall into an actionable MeasureError', async () => {
  await assert.rejects(
    launchMeasureBrowser(null, browserPolicy({}), async () => { throw new Error(WAVE_11_LAUNCH_ERROR); }),
    (err) => err instanceof MeasureError && /npx playwright install chromium/.test(err.message));
});

test('a launch failure that is NOT a missing browser is rethrown untouched', async () => {
  await assert.rejects(
    launchMeasureBrowser(null, browserPolicy({}), async () => { throw new Error('EACCES /dev/shm'); }),
    (err) => !(err instanceof MeasureError) && /EACCES/.test(err.message));
});

test('the chosen channel actually reaches playwright', async () => {
  const seen = [];
  await launchMeasureBrowser(null, browserPolicy({ BP_DESK_BROWSER: 'chrome' }),
    async (opts) => { seen.push(opts); return 'browser'; });
  assert.deepEqual(seen, [{ channel: 'chrome' }]);
  await launchMeasureBrowser(null, browserPolicy({}), async (opts) => { seen.push(opts); return 'browser'; });
  assert.deepEqual(seen[1], {}, 'bundled must pass NO channel — a channel:null is not the same thing');
});

test('the run records which browser measured it', () => {
  assert.match(SRC, /browser_policy: browserPolicyChosen\.id/);
  assert.match(SRC, /browser_version: browser\.version\(\)/,
    'ch is a font measurement; bundled Chromium and system Chrome are different builds, so a run ' +
    'that does not name its browser cannot be compared to one that does');
  assert.doesNotMatch(SRC, /await pw\.chromium\.launch\(\);/,
    'the bare unpolicied launch is the defect — it must not survive anywhere in the file');
});

test('--help states the browser policy and the install command', () => {
  const helpSrc = SRC.slice(SRC.indexOf('function usage()'), SRC.indexOf('const DEFAULT_DOC'));
  assert.match(helpSrc, /BP_DESK_BROWSER/);
  assert.match(helpSrc, /npx playwright install chromium|p\.fix/,
    'the deployed-run slice reads --help first; the fix has to be there');
  assert.match(helpSrc, /--retries=N/);
  assert.match(helpSrc, /--fail-on-face-substitution/);
});
