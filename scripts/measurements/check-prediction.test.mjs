// check-prediction.test.mjs — run with:  node --test scripts/measurements/
//
// What this file exists to lock: check-prediction.mjs used to collapse EVERY
// failure into exit 1, so a run whose round trip was clean and whose only
// disagreement was a registered absolute was indistinguishable from a run whose
// reading column did not come back. That is not a cosmetic difference — the
// first says "adjudicate a baseline", the second says "the desk is broken", and
// `spd-bracketed-deployed-run{1,2}-2026-07-22.json` really did get read the
// wrong way round because of it.
//
// Every fixture under ./fixtures/ is hand-authored and stamped `__synthetic__`.
// None of them is a measurement and none may ever be quoted as a desk fact.
//
// ON THE ROW'S `0,1,1,2,2,3,3`: the task that ordered this suite
// (spd-check-prediction-fixtures-committed) was filed on 2026-07-21, when the
// checker had FOUR exit codes and a stale prior was indistinguishable from a
// broken round trip — so it asked for seven cases asserting `0,1,1,2,2,3,3`.
// #16309 then split exit 4 (STALE-PRIOR) out of exit 1, and that literal string
// is now WRONG: it names no exit 4 at all. The mapping this file asserts against
// is the checker's own, read off its declarations rather than retyped —
// 0 GREEN, 1 MISMATCH/FIDELITY-FAIL, 2 INPUT FAILURE (which is also where a
// banned-scalar prediction lands, via enforceHygiene), 3 UNEVALUATED,
// 4 STALE-PRIOR — and the final test in this file pins the SET of classes the
// suite actually exercises to {0,1,2,3,4}, so deleting a case reds the suite
// instead of quietly shrinking its coverage.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const CHECKER = path.join(HERE, 'check-prediction.mjs');
const FIX = path.join(HERE, 'fixtures');
const PRED = 'pred-1280-prior-596.json';

const EXIT = { GREEN: 0, FIDELITY_FAIL: 1, INPUT_FAILURE: 2, UNEVALUATED: 3, STALE_PRIOR: 4 };

/** Every exit code this suite has actually OBSERVED the checker return. Written
 *  by check() and by the real-artefact test; read by the final test. */
const EXERCISED = new Set();

/** The checker's exit table, read out of its SOURCE TEXT rather than retyped
 *  here. If a class is deleted from check-prediction.mjs, or a new one added,
 *  this set moves and the final test says so. */
function declaredExitCodes() {
  const src = fs.readFileSync(CHECKER, 'utf8');
  const codes = new Set();
  for (const m of src.matchAll(/^const EXIT_([A-Z_]+) = (\d+);$/gm)) codes.add(Number(m[2]));
  assert.ok(codes.size >= 2, 'the EXIT_* declarations were not found in the checker source');
  return codes;
}

/** Runs the checker and returns { code, stdout, json }. Never pipes — the exit
 *  code is captured directly, so a gate cannot read a pipeline's status. */
function check(artefactName, { json = false, prediction = PRED } = {}) {
  const args = [CHECKER, path.join(FIX, prediction), path.join(FIX, artefactName)];
  if (json) args.push('--json');
  let out;
  try {
    const stdout = execFileSync(process.execPath, args, { encoding: 'utf8' });
    out = { code: 0, stdout, stderr: '', json: json ? JSON.parse(stdout) : null };
  } catch (e) {
    if (typeof e.status !== 'number') throw e;
    const stdout = e.stdout ?? '';
    out = { code: e.status, stdout, stderr: e.stderr ?? '', json: json && stdout ? JSON.parse(stdout) : null };
  }
  EXERCISED.add(out.code);
  return out;
}

test('an agreeing run is GREEN (exit 0) — the fixtures are not all failures', () => {
  const r = check('run-green.json', { json: true });
  assert.equal(r.code, EXIT.GREEN);
  assert.equal(r.json.verdict, 'GREEN');
  assert.equal(r.json.failure_class, null);
  assert.equal(r.json.misses.length, 0);
});

test('a stale prior — before==after, both != the registered figure — is STALE-PRIOR (exit 4)', () => {
  const r = check('run-stale-prior.json', { json: true });
  assert.equal(r.code, EXIT.STALE_PRIOR);
  assert.equal(r.json.verdict, 'STALE-PRIOR');
  assert.equal(r.json.failure_class, 'STALE-PRIOR');
  // it is NOT green: the disagreement is reported, not swallowed
  assert.ok(r.json.misses.length > 0, 'a stale prior must still be REPORTED');
  // and fidelity is explicitly intact
  assert.equal(r.json.stats.round_trip_ran, true);
  assert.equal(r.json.stats.returns_bit_identical, true);
  // the LABELLED LINE, read off the human report (a JSON run prints no prose)
  const text = check('run-stale-prior.json');
  assert.equal(text.code, EXIT.STALE_PRIOR);
  assert.match(text.stdout, /VERDICT: STALE-PRIOR \(exit 4\)/);
  assert.match(text.stdout, /THIS IS NOT A FIDELITY FAILURE/);
});

test('a genuine round-trip failure — before != after — is FIDELITY-FAIL (exit 1)', () => {
  const r = check('run-fidelity-fail.json', { json: true });
  assert.equal(r.code, EXIT.FIDELITY_FAIL);
  assert.equal(r.json.verdict, 'FIDELITY-FAIL');
  assert.equal(r.json.failure_class, 'FIDELITY-FAIL');
  assert.equal(r.json.stats.returns_bit_identical, false);
  const text = check('run-fidelity-fail.json');
  assert.equal(text.code, EXIT.FIDELITY_FAIL);
  assert.match(text.stdout, /VERDICT: FIDELITY-FAIL \(exit 1\)/);
});

test('the two verdicts do not share an exit code', () => {
  assert.notEqual(
    check('run-stale-prior.json').code,
    check('run-fidelity-fail.json').code,
    'STALE-PRIOR and FIDELITY-FAIL must be distinguishable by exit code alone');
});

test('real font drift (px_per_ch, basis `arithmetic`) is NOT swallowed as a stale prior', () => {
  // Legs AGREE, so `legs_agreed` is true for every miss — the one condition a
  // sloppy classifier would stop at. px_per_ch is basis `arithmetic` and belongs
  // to neither stale-prior set, so the verdict must stay FIDELITY-FAIL.
  const r = check('run-font-drift.json', { json: true });
  assert.equal(r.code, EXIT.FIDELITY_FAIL);
  assert.equal(r.json.verdict, 'FIDELITY-FAIL');
  assert.ok(r.json.misses.some((m) => m.field.startsWith('px_per_ch')),
    'the font-drift miss must actually be present, or this test is vacuous');
});

test('an independently-wrong ch figure raises SELF_INCONSISTENT and forces FIDELITY-FAIL', () => {
  // The px absolutes MATCH here, so nothing is stale. Only the derived ch is
  // wrong, and it is not `px / px_per_ch`. This is the case the `recomputed`
  // arm of the stale-prior rule must never swallow.
  const r = check('run-ch-independently-wrong.json', { json: true });
  assert.equal(r.code, EXIT.FIDELITY_FAIL);
  assert.equal(r.json.verdict, 'FIDELITY-FAIL');
  assert.ok(r.json.inconsistencies.length > 0,
    'the derived-ch cross-examination must fire, or this test is vacuous');
});

test('the committed 2026-07-22 deployed runs are STALE-PRIOR, not FIDELITY-FAIL', () => {
  // The regression this whole change exists for, against the REAL artefacts.
  const pred = path.join(HERE, 'spd-round-trip-prediction-2026-07-21.json');
  for (const name of ['spd-bracketed-deployed-run1-2026-07-22.json',
                      'spd-bracketed-deployed-run2-2026-07-22.json']) {
    let code = 0, stdout = '';
    try {
      stdout = execFileSync(process.execPath, [CHECKER, pred, path.join(HERE, name), '--json'],
        { encoding: 'utf8' });
    } catch (e) {
      if (typeof e.status !== 'number') throw e;
      code = e.status; stdout = e.stdout ?? '';
    }
    const j = JSON.parse(stdout);
    EXERCISED.add(code);
    assert.equal(code, EXIT.STALE_PRIOR, `${name} must exit 4`);
    assert.equal(j.verdict, 'STALE-PRIOR', name);
    assert.equal(j.stats.returns_bit_identical, true, `${name}: fidelity is intact`);
    assert.equal(j.stats.cells_returned_unchanged, 27, name);
    assert.equal(j.misses.length, 24, `${name}: all 24 misses still REPORTED`);
    // every one of them at 1280 — the attribution in
    // spd-1280-prior-observation-adjudication-2026-09-06.md depends on this
    assert.ok(j.misses.every((m) => m.key.includes('1280')),
      `${name}: every miss must sit at viewport 1280`);
  }
});

// ── the four classes the 2026-07-21 filing proved by hand and never committed ──

test('UNEVALUATED on a SKIPPED OPEN LEG is exit 3 — not a pass, not a wrong prediction', () => {
  // run-green.json with `ran` flipped to false and a skip_reason recorded. The
  // cells are still there and still agree; the checker must refuse to read them.
  const r = check('run-unevaluated-skipped-open-leg.json', { json: true });
  assert.equal(r.code, EXIT.UNEVALUATED, 'a skipped open leg must exit 3, never 0');
  assert.equal(r.json.verdict, 'UNEVALUATED');
  assert.match(r.json.reason, /did not run/);
  assert.match(r.json.reason, /1280/, 'the skipped viewport must be named, or the fixture is inert');
  const text = check('run-unevaluated-skipped-open-leg.json');
  assert.equal(text.code, EXIT.UNEVALUATED);
  assert.match(text.stdout, /VERDICT: UNEVALUATED \(exit 3\)/);
});

test('UNEVALUATED with NO ROUND TRIP AT ALL is exit 3 — an absent section is not a clean run', () => {
  // run-green.json with the whole round_trip section deleted. The dangerous
  // reading is "no differences found"; the checker must say it measured nothing.
  const r = check('run-unevaluated-no-round-trip.json', { json: true });
  assert.equal(r.code, EXIT.UNEVALUATED, 'an artefact with no round_trip must exit 3, never 0');
  assert.equal(r.json.verdict, 'UNEVALUATED');
  assert.match(r.json.reason, /no round_trip section at all/);
});

test('a prediction quoting a BANNED SCALAR is rejected — exit 2, the INPUT-FAILURE class', () => {
  // The hygiene rule lives in the checker (BANNED_SCALARS, check-prediction.mjs:110),
  // and enforceHygiene ends in `process.exit(EXIT_INPUT_FAILURE)` (:175) — so the
  // banned-scalar path shares exit 2 with unreadable and un-keyable input. This
  // is the ONE case whose fixture is a PREDICTION, not an artefact: enforceHygiene
  // scans the prediction text only, so no edit to a run-*.json can reach it.
  const r = check('run-green.json', { prediction: 'pred-banned-scalar.json' });
  assert.equal(r.code, EXIT.INPUT_FAILURE, 'a banned scalar must be refused, not checked');
  assert.match(r.stderr, /PREDICTION REJECTED — banned scalar quoted/);
  assert.match(r.stderr, /row_count/, 'the offending scalar must be named, or the fixture is inert');
  // and the same artefact under the CLEAN prediction is green — proving the
  // rejection is the prediction's fault and not the artefact's
  assert.equal(check('run-green.json').code, EXIT.GREEN);
});

test('a WIDTH-KEYED artefact is an INPUT FAILURE (exit 2), never a clean empty pass', () => {
  // run-green.json with widths[0].viewport_px renamed to width — the exact shape
  // that made tooling written against `w.width` report a fictional pass over zero
  // rows. The checker must refuse to key it rather than find no differences.
  const r = check('run-width-keyed.json');
  assert.equal(r.code, EXIT.INPUT_FAILURE, 'an unkeyable width record must exit 2, never 0');
  assert.match(r.stderr, /INPUT FAILURE: round_trip\.widths\[0\] has no viewport_px/);
  assert.match(r.stderr, /keyed on `width`/);
});

// ── the coverage pin ───────────────────────────────────────────────────────────

test('one command exercises EVERY exit class the checker declares — {0,1,2,3,4}', () => {
  // Declared side is read from check-prediction.mjs's own `const EXIT_* = N;`
  // lines, never retyped. Exercised side is what the runs above actually
  // returned. Deleting a case, or adding an exit class without a fixture, reds
  // here — which is the whole point of committing the fixtures.
  const declared = declaredExitCodes();
  assert.deepEqual([...declared].sort(), [0, 1, 2, 3, 4],
    'the checker no longer declares exactly exit codes 0-4 — update the fixtures AND this file');
  assert.deepEqual([...EXERCISED].sort(), [...declared].sort(),
    `exit classes declared but never exercised: ${[...declared].filter((c) => !EXERCISED.has(c)).join(', ') || '(none)'}`);
  // and the local names agree with the numbers, so a rename cannot drift silently
  assert.deepEqual([...new Set(Object.values(EXIT))].sort(), [...declared].sort());
});
