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

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const CHECKER = path.join(HERE, 'check-prediction.mjs');
const FIX = path.join(HERE, 'fixtures');
const PRED = path.join(FIX, 'pred-1280-prior-596.json');

const EXIT = { GREEN: 0, FIDELITY_FAIL: 1, INPUT_FAILURE: 2, UNEVALUATED: 3, STALE_PRIOR: 4 };

/** Runs the checker and returns { code, stdout, json }. Never pipes — the exit
 *  code is captured directly, so a gate cannot read a pipeline's status. */
function check(artefactName, { json = false } = {}) {
  const args = [CHECKER, PRED, path.join(FIX, artefactName)];
  if (json) args.push('--json');
  try {
    const stdout = execFileSync(process.execPath, args, { encoding: 'utf8' });
    return { code: 0, stdout, json: json ? JSON.parse(stdout) : null };
  } catch (e) {
    if (typeof e.status !== 'number') throw e;
    const stdout = e.stdout ?? '';
    return { code: e.status, stdout, json: json && stdout ? JSON.parse(stdout) : null };
  }
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
