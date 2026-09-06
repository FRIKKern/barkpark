#!/usr/bin/env node
//
// studio-desk-sha-pin.test.mjs — the red tests for `--sha` / `--ref`.
//
// WHAT IT PROVES, and why each one is here rather than implied:
//
//   1. A MISMATCHING PIN REFUSES, BY NAME, BEFORE A ROW EXISTS. The refusal is
//      a MeasureError (so it lands in the instrument's one failure handler and
//      exits 1), it is NOT retryable (a moved deployment is not a race — the
//      re-run reproduces it verbatim), and its text carries BOTH the requested
//      and the served SHA. A refusal that names neither is the confound with
//      extra steps.
//   2. A MATCHING PIN — full OR abbreviated-by-prefix — proceeds silently. The
//      short form is what a human copies out of `git log`, so a pin that only
//      accepted 40 hex characters would be refused by its own operators.
//   3. NO FLAG IS TODAY'S BEHAVIOUR, unchanged. `parseShaPin` returns null and
//      `assertServedShaPinned(null, …)` measures whatever the box serves. The
//      whole value of the flag is that it is opt-in: it must never turn an
//      unpinned run into a refusal.
//
// The call site is proven separately (`assertServedShaPinned` is called at the
// PRE half of the provenance bracket, before the browser launches), because a
// correct predicate wired after the sweep would pass every test above and still
// let a full authenticated run measure the wrong build.
//
// Nothing here needs ssh, a browser, or the box: every unit is pure, and the
// argv/env edges are taken by INJECTION rather than read from process.
//
//   node --test scripts/studio-desk-sha-pin.test.mjs

import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import {
  MeasureError,
  assertServedShaPinned,
  parseShaPin,
  shaPinMatches,
} from './studio-desk-measure.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const INSTRUMENT = path.join(HERE, 'studio-desk-measure.mjs');
const SRC = fs.readFileSync(INSTRUMENT, 'utf8');

// A real 40-hex head, and the short form a human would paste from `git log`.
const SERVED = '5aad3b917cfc4f2a1de0a7b34e9c15d8f0a6b2c1';
const SERVED_SHORT = '5aad3b9';
const OTHER = 'deadbeef00000000000000000000000000000000';

/** `assert.throws` returns undefined, so it cannot hand back the error whose
 *  TEXT is half of what these tests are about. This asserts the throw and
 *  yields the error. */
function refusal(fn, what) {
  let caught = null;
  try { fn(); } catch (e) { caught = e; }
  assert.ok(caught, `expected a refusal: ${what}`);
  assert.ok(caught instanceof MeasureError,
    `a refusal must be a MeasureError so it lands in the instrument's one failure handler (got ${caught?.constructor?.name}: ${caught?.message})`);
  return caught;
}

// ── 1. the mismatch refuses ──────────────────────────────────────────────────

test('a mismatching pin throws a MeasureError naming BOTH SHAs', () => {
  const pin = { requested: OTHER, source: '--sha=' };
  const err = refusal(() => assertServedShaPinned(pin, SERVED),
    'a served SHA that is not the requested one must REFUSE — measuring it is the D73 confound');
  assert.match(err.message, /SERVED SHA IS NOT THE PINNED SHA/,
    'the refusal must be findable by name in a scrollback, like every other named abort');
  assert.ok(err.message.includes(OTHER), 'the refusal must print what was REQUESTED');
  assert.ok(err.message.includes(SERVED), 'the refusal must print what is actually SERVED');
});

test('the mismatch refusal is TERMINAL, not retryable', () => {
  // A retryable abort tells the operator "re-run, this is a race the harness
  // lost". A moved deployment is the opposite: re-running burns two more
  // authenticated sweeps to reprint the same sentence.
  const err = refusal(() => assertServedShaPinned({ requested: OTHER, source: '--sha=' }, SERVED),
    'a mismatching pin');
  assert.equal(err.retryable, false);
  assert.equal(err.abortId, null);
});

test('a mismatch refuses BEFORE any row is emitted — proven at the call site', () => {
  // The predicate being right is not enough: it has to run early. It is called
  // from `main()` on the line after the PRE-sweep provenance read, which is
  // before the browser launches, before the ticket is minted, and before the
  // first record exists. If someone moves the call below the sweep, this reds.
  const call = SRC.indexOf('assertServedShaPinned(SHA_PIN');
  assert.notEqual(call, -1, 'main() must actually call assertServedShaPinned');
  const preRead = SRC.indexOf('const provenance = readProvenance();');
  const launch = SRC.indexOf('await launchMeasureBrowser(');
  const postRead = SRC.indexOf('const provenancePost = readProvenance();');
  assert.ok(preRead !== -1 && launch !== -1 && postRead !== -1, 'anchors moved — re-read main()');
  assert.ok(call > preRead, 'the served SHA is not known until the PRE provenance read');
  assert.ok(call < launch, 'the pin must refuse BEFORE a browser is launched — a refusal that costs a sweep is a tax, not a guard');
  assert.ok(call < postRead, 'the pin must refuse BEFORE the sweep, not with the post-sweep bracket');
});

// ── 2. a matching pin proceeds ───────────────────────────────────────────────

test('an exact pin proceeds', () => {
  assert.doesNotThrow(() => assertServedShaPinned({ requested: SERVED, source: '--sha=' }, SERVED));
});

test('an abbreviated pin matches by PREFIX', () => {
  assert.ok(shaPinMatches(SERVED_SHORT, SERVED));
  assert.doesNotThrow(() => assertServedShaPinned({ requested: SERVED_SHORT, source: '--sha=' }, SERVED));
});

test('case does not matter — `git log` and `rev-parse` disagree on nothing else', () => {
  assert.ok(shaPinMatches(SERVED_SHORT.toUpperCase(), SERVED));
  assert.ok(shaPinMatches(SERVED, SERVED.toUpperCase()));
});

test('the match is a PREFIX test, never a substring one', () => {
  // A SHA appearing in the MIDDLE of another is not a revision identity, and
  // `includes` would have said it was.
  const middle = SERVED.slice(8, 20);
  assert.ok(SERVED.includes(middle), 'fixture check: the fragment really is inside the served SHA');
  assert.equal(shaPinMatches(middle, SERVED), false);
});

test('an empty or absent served SHA never satisfies a pin', () => {
  assert.equal(shaPinMatches(SERVED_SHORT, ''), false);
  assert.equal(shaPinMatches(SERVED_SHORT, null), false);
  assert.equal(shaPinMatches('', SERVED), false);
  const err = refusal(() => assertServedShaPinned({ requested: SERVED_SHORT, source: '--sha=' }, ''),
    'an unreadable served SHA');
  assert.match(err.message, /<empty>/, 'an unreadable served SHA must still print a legible refusal');
});

// ── 3. no flag = today's behaviour ───────────────────────────────────────────

test('no flag and no env parses to null, and null never refuses', () => {
  assert.equal(parseShaPin(['node', 'studio-desk-measure.mjs'], {}), null);
  assert.equal(parseShaPin(['node', 'x', '--json', '--retries=0'], {}), null);
  assert.doesNotThrow(() => assertServedShaPinned(null, SERVED));
  assert.doesNotThrow(() => assertServedShaPinned(undefined, ''));
});

test('an empty BP_DESK_SHA is "unpinned", not an error', () => {
  assert.equal(parseShaPin(['node', 'x'], { BP_DESK_SHA: '' }), null);
  assert.equal(parseShaPin(['node', 'x'], { BP_DESK_SHA: '   ' }), null);
});

// ── parsing ──────────────────────────────────────────────────────────────────

test('--sha and --ref are the same flag, in both = and space forms', () => {
  for (const argv of [
    ['node', 'x', `--sha=${SERVED_SHORT}`],
    ['node', 'x', '--sha', SERVED_SHORT],
    ['node', 'x', `--ref=${SERVED_SHORT}`],
    ['node', 'x', '--ref', SERVED_SHORT],
  ]) {
    const pin = parseShaPin(argv, {});
    assert.equal(pin.requested, SERVED_SHORT, `argv ${JSON.stringify(argv)}`);
  }
});

test('argv beats the env form, and the env form is honoured alone', () => {
  assert.equal(parseShaPin(['node', 'x', `--sha=${SERVED_SHORT}`], { BP_DESK_SHA: OTHER }).requested, SERVED_SHORT);
  const env = parseShaPin(['node', 'x'], { BP_DESK_SHA: SERVED });
  assert.equal(env.requested, SERVED);
  assert.equal(env.source, 'BP_DESK_SHA');
});

test('the pin is lowercased on the way in, so the record is canonical', () => {
  assert.equal(parseShaPin(['node', 'x', `--sha=${SERVED.toUpperCase()}`], {}).requested, SERVED);
});

test('a branch or tag name is refused as an ARGUMENT, not as a mismatch', () => {
  // The box reports `git rev-parse HEAD`. A name could only ever mismatch, so
  // accepting it would dress a bad argument up as a moved deployment.
  const err = refusal(() => parseShaPin(['node', 'x', '--sha=main'], {}), 'a branch name');
  assert.match(err.message, /hex commit SHA/);
  refusal(() => parseShaPin(['node', 'x', '--ref=origin/main'], {}), 'a qualified branch name');
  refusal(() => parseShaPin(['node', 'x', '--sha=5aad3b'], {}), '6 chars: too short to identify');
  refusal(() => parseShaPin(['node', 'x', '--sha='], {}), 'an empty --sha=');
});

test('--sha followed by another flag is a naming error, not a SHA', () => {
  const err = refusal(() => parseShaPin(['node', 'x', '--sha', '--json'], {}), '--sha followed by --json');
  assert.match(err.message, /another flag, not a SHA/);
  refusal(() => parseShaPin(['node', 'x', '--sha'], {}), '--sha as the last argv entry');
});

// ── wiring ───────────────────────────────────────────────────────────────────

test('the pin is parsed at the ENTRYPOINT, never at module scope', () => {
  // Parsing argv at module scope couples IMPORT to the importer's command line
  // — this file is one such importer, and a stray `--sha` in ITS argv would
  // otherwise die on `import`. (Same reason `resolveOutPath` is deferred.)
  assert.match(SRC, /SHA_PIN = parseShaPin\(\)/, 'the entrypoint must assign SHA_PIN');
  const assign = SRC.indexOf('SHA_PIN = parseShaPin()');
  const guard = SRC.indexOf('if (INVOKED_DIRECTLY) {');
  assert.ok(guard !== -1 && assign > guard, 'the assignment must sit inside the INVOKED_DIRECTLY chain');
});

test('the run records what was REQUESTED alongside what was served', () => {
  assert.match(SRC, /requested_sha: SHA_PIN\?\.requested \?\? null/,
    'a run must say which build it was pinned to, or the artifact is back to prose');
  assert.match(SRC, /requested_sha: run\.requested_sha \?\? null/,
    'the flattened artifact carries it too — that is the half a later reader greps');
});

test('--help documents both spellings and the env form', () => {
  const help = SRC.slice(SRC.indexOf('function usage()'), SRC.indexOf('function usage()') + 6000);
  assert.match(help, /--sha=<sha>/);
  assert.match(help, /--ref=<sha>/);
  assert.match(help, /BP_DESK_SHA/);
});
