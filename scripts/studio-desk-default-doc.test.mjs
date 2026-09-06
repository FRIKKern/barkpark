#!/usr/bin/env node
//
// studio-desk-default-doc.test.mjs — the red tests for the DEFAULT DRILL TARGET.
//
// THE DEFECT THIS PINS (#16355). The instrument used to carry a committed
// default slug, `DEFAULT_DOC = 'studio-space-priority-desk-browser-2026-07-19'`.
// The Papers pane is a newest-first window of ~100 rows that this epic's own
// waves publish into continuously, so that slug aged out of it — and a bare
// `node scripts/studio-desk-measure.mjs --json` then aborted 1 of 1,
// deterministically, naming a slug the reader had no way to replace. The
// documented invocation of a measuring instrument always failed.
//
// WHAT IT PROVES, and why each one is here rather than implied:
//
//   1. NO DATED SLUG CAN COME BACK. Not "the current one is fine" — the whole
//      failure mode is that a literal is fine on the day it is written. This
//      test reads the instrument's SOURCE with comments stripped and fails on a
//      `DEFAULT_DOC` binding or on any dated-slug string literal in live code.
//      Bumping the constant to a newer Paper would have passed a test that
//      merely asserted reachability today; it does not pass this one.
//   2. PRECEDENCE IS UNCHANGED WHERE IT ALREADY EXISTED. `--doc=` beats
//      `BP_DESK_DOC` beats the default. Two callers already depend on that and
//      neither should have to notice this change.
//   3. THE DEFAULT REFUSES AN EMPTY PANE, LOUDLY. This is the criterion the
//      whole fix turns on: "newest" applied to a list of zero must not decay
//      into "whatever surface is on screen". The next surface is the ROOT pane,
//      whose rows are document TYPES — a read that went seven weeks
//      misdiagnosed as a partially-loaded list (D138 failure C). A resolver
//      that returned null here would rebuild that confound behind a nicer name,
//      so the empty case throws a MeasureError that says so in words.
//   4. THE RUN RECORDS WHAT IT CHOSE. A resolved default is only as good as its
//      audit trail: `measured_doc`, `measured_doc_source` and
//      `measured_doc_reachability` are written into the run AND the flattened
//      artifact, next to served_sha / requested_sha.
//
// The resolvers are PURE and take argv/env by injection, for the same reason
// `parseShaPin` does: precedence is the part that rots, and a rule that can only
// be exercised through a 30-60s authenticated sweep is a rule nobody re-checks.
// Nothing here needs ssh, a browser, or the box.
//
//   node --test scripts/studio-desk-default-doc.test.mjs

import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import {
  MeasureError,
  resolveDocTarget,
  resolveNewestPaperSlug,
} from './studio-desk-measure.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const INSTRUMENT = path.join(HERE, 'studio-desk-measure.mjs');
const SRC = fs.readFileSync(INSTRUMENT, 'utf8');

/** The instrument documents its own history in prose, and that prose QUOTES the
 *  dated slug it removed — deliberately, so a reader meets the defect rather
 *  than an absence. A source scan that cannot tell a comment from code would
 *  therefore red on the explanation of the fix. This strips block comments and
 *  line comments and leaves the live code. */
function liveCode(src) {
  return src
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .split('\n')
    .filter((l) => !/^\s*\/\//.test(l))
    .join('\n');
}

/** `assert.throws` returns undefined, so it cannot hand back the error whose
 *  TEXT is half of what these tests are about. This asserts the throw and
 *  yields the error. */
function refusal(fn, what) {
  let caught = null;
  try { fn(); } catch (e) { caught = e; }
  assert.ok(caught, `expected a refusal: ${what}`);
  assert.ok(caught instanceof MeasureError,
    `a refusal must be a MeasureError so it lands in the instrument's one failure handler and ` +
    `exits 1 by name — got ${caught?.constructor?.name}: ${caught?.message}`);
  return caught;
}

// ── 1. the dated literal cannot come back ────────────────────────────────────

test('the comment stripper leaves live code standing (non-vacuity)', () => {
  const code = liveCode(SRC);
  assert.match(code, /const NEWEST_DOC = 'newest';/,
    'if the stripper blanked the file, every doesNotMatch below would pass on nothing');
  assert.match(code, /export function resolveNewestPaperSlug/);
  assert.doesNotMatch(code, /THERE IS NO COMMITTED DEFAULT SLUG/,
    'the block comment explaining the fix must NOT survive stripping — it quotes the dated slug');
});

test('no DEFAULT_DOC binding survives in live code', () => {
  assert.doesNotMatch(liveCode(SRC), /(?:^|\s)(?:const|let|var)\s+DEFAULT_DOC\b/,
    'a committed default slug is the defect (#16355) whatever value it holds: the Papers pane is a ' +
    'newest-first ~100-row window, so any fixed slug ages out of it and the bare invocation starts ' +
    'aborting 1 of 1. The default must RESOLVE at run time.');
});

test('no dated slug literal survives in live code', () => {
  const dated = /['"`][^'"`\n]*-20\d\d-\d\d-\d\d[^'"`\n]*['"`]/;
  assert.doesNotMatch(liveCode(SRC), dated,
    'a `…-2026-07-19`-shaped literal in this file is a target with an expiry date. Bumping it to a ' +
    'newer Paper is not the fix — it only buys the date of the next outage.');
  // The detector is only worth its green if it would have caught the original.
  assert.match(`const DEFAULT_DOC = 'studio-space-priority-desk-browser-2026-07-19';`, dated,
    'the dated-slug detector must match the literal this task deleted, or its silence means nothing');
});

// ── 2. precedence ────────────────────────────────────────────────────────────

test('the flag wins over the env wins over the resolved newest', () => {
  const argv = ['node', 'studio-desk-measure.mjs', '--doc=from-the-flag'];
  const env = { BP_DESK_DOC: 'from-the-env' };

  assert.deepEqual(resolveDocTarget(argv, env),
    { mode: 'named', slug: 'from-the-flag', source: '--doc=', resolution: '--doc=' });

  assert.deepEqual(resolveDocTarget(['node', 'studio-desk-measure.mjs'], env),
    { mode: 'named', slug: 'from-the-env', source: 'BP_DESK_DOC', resolution: 'BP_DESK_DOC' });

  assert.deepEqual(resolveDocTarget(['node', 'studio-desk-measure.mjs'], {}),
    { mode: 'newest', slug: null, source: 'default', resolution: 'newest-paper' },
    'with neither form the default is a MODE, resolved at run time — never a slug');
});

test('an empty or blank BP_DESK_DOC is not a target — it is the default', () => {
  for (const value of ['', '   ']) {
    assert.deepEqual(resolveDocTarget(['node', 'x'], { BP_DESK_DOC: value }),
      { mode: 'newest', slug: null, source: 'default', resolution: 'newest-paper' },
      `BP_DESK_DOC=${JSON.stringify(value)} must not be read as a document slug`);
  }
});

test('slugs are trimmed and the sentinels are modes, not documents', () => {
  assert.deepEqual(resolveDocTarget(['node', 'x', '--doc=  spaced-slug  '], {}),
    { mode: 'named', slug: 'spaced-slug', source: '--doc=', resolution: '--doc=' });

  assert.deepEqual(resolveDocTarget(['node', 'x', '--doc=newest'], {}),
    { mode: 'newest', slug: null, source: '--doc=', resolution: 'newest-paper' },
    'asking for newest EXPLICITLY must resolve the same way as asking for nothing');

  assert.deepEqual(resolveDocTarget(['node', 'x', '--doc=any'], {}),
    { mode: 'any', slug: null, source: '--doc=', resolution: 'first-openable-row' },
    '--doc=any is the pre-existing first-openable-row drill and must keep working unchanged');

  assert.deepEqual(resolveDocTarget(['node', 'x'], { BP_DESK_DOC: 'any' }),
    { mode: 'any', slug: null, source: 'BP_DESK_DOC', resolution: 'first-openable-row' });
});

test('--doc= with an empty value still refuses by name', () => {
  const err = refusal(() => resolveDocTarget(['node', 'x', '--doc='], {}), '--doc= with no value');
  assert.match(err.message, /--doc=/);
  assert.match(err.message, /newest/, 'the refusal must name the default it could have had');
});

// ── 3. the empty pane refuses rather than measuring the root pane ────────────

test('the newest paper is the first row that carries a slug', () => {
  const chosen = resolveNewestPaperSlug(['newest-paper-slug', 'older', 'older-still']);
  assert.equal(chosen.slug, 'newest-paper-slug');
  assert.equal(chosen.source, 'newest-paper', 'the run must be able to say HOW the document was chosen');
  assert.equal(chosen.rows_considered, 3);
  assert.equal(chosen.rows_with_slug, 3);

  const skipping = resolveNewestPaperSlug([null, '  ', 'first-real-slug']);
  assert.equal(skipping.slug, 'first-real-slug',
    'a row with no phx-value-id cannot be clicked by id or asserted against the landed URL');
  assert.equal(skipping.rows_considered, 3);
  assert.equal(skipping.rows_with_slug, 1);
});

test('an EMPTY Papers pane REFUSES — it does not fall back to the root pane', () => {
  for (const [label, rows] of [
    ['no rows at all', []],
    ['rows with no phx-value-id', [null, undefined, '   ']],
    ['not a list at all', undefined],
  ]) {
    const err = refusal(() => resolveNewestPaperSlug(rows), label);
    assert.match(err.message, /INSTRUMENT FAILURE \(drill\)/,
      'a drill that never reached a document says nothing about the desk, and must say so');
    assert.match(err.message, /root pane/i,
      'the refusal must name the thing it is refusing to measure — the root pane, whose rows are ' +
      'document TYPES. A generic "nothing found" is how that read went seven weeks misdiagnosed.');
    assert.match(err.message, /--doc=/, 'a refusal must name the way past it');
  }
});

test('the refusal is not retryable — an empty pane is an environment fact', () => {
  const err = refusal(() => resolveNewestPaperSlug([]), 'empty pane');
  assert.notEqual(err.retryable, true,
    'retrying an empty Papers pane reproduces it verbatim; a retry loop would only bury the reason');
});

// ── 4. the call site, and what the run records ───────────────────────────────

test('the drill resolves newest INSIDE the pane it proved it entered', () => {
  const drill = SRC.slice(SRC.indexOf('async function drillToDocument'));
  assert.ok(drill.length > 0, 'drillToDocument moved or was renamed');
  assert.match(drill.slice(0, 3000), /resolveNewestPaperSlug\(slugs\)/,
    'the newest row must come from the Papers pane THIS run rendered — a slug read from anywhere ' +
    'else is a slug that can have aged off the window before the click');
  assert.match(drill.slice(0, 3000), /mode: 'named'/,
    'once resolved it must proceed as an ordinary named target, so the landed URL is still asserted ' +
    'to carry the slug the matrix claims to have measured');
});

test('the run and the flattened artifact record which document, from which source, and why reachable', () => {
  for (const field of ['measured_doc', 'measured_doc_source', 'measured_doc_reachability']) {
    assert.match(SRC, new RegExp(`run\\.${field} =`),
      `${field} must be set on the run — "which document did this matrix measure" cannot be a ` +
      `question a committed artifact fails to answer`);
    assert.match(SRC, new RegExp(`^\\s+${field}: run\\.${field}`, 'm'),
      `${field} must also reach the FLATTENED artifact, beside served_sha / requested_sha — that ` +
      `block is what a later reader greps, and a field only in the deep run is a field not read`);
  }
  assert.match(SRC, /measured_document: run\.measured_document/,
    'the long-standing name stays: committed runs in scripts/measurements/ are read by it');
});
