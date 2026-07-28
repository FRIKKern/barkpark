// FIRST TESTS FOR THE SEAL PREDICATE.
//
// Until wave 6 this instrument had ZERO tests anywhere in the repo — every claim
// about its behaviour was contract-read, which is how it shipped able to print
// `VERDICT: SEAL` over "0 forwarded by name / to null". Each of the four measured
// defects below is a test with a committed fixture, not a manual run.
//
// The predicate is exercised AS A PROCESS, never as an import: its contract is an
// EXIT CODE, and only a spawn can test an exit code. `SEAL_PREDICATE_PATH` points
// the whole file at a mutated copy, so "these tests red against the pre-fix
// behaviour" is itself a command anyone can rerun:
//
//   git show <pre-fix-sha>:cloud/priv/static/__preview__/seal-predicate.mjs > /tmp/pre.mjs
//   SEAL_PREDICATE_PATH=/tmp/pre.mjs node --test cloud/priv/static/__preview__/seal-predicate.test.mjs
//
// `--guard-cmd true` stands in for the browser guard so these tests measure clause
// (a) and the refusals, not Chrome. ONE test deliberately omits it, so the real
// guard arm (fail-closed on an uncommitted guard) is exercised too.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const PREDICATE = process.env.SEAL_PREDICATE_PATH || join(HERE, 'seal-predicate.mjs');
const REPO = resolve(HERE, '../../../..');
const FIX = (name) => join(HERE, 'fixtures', 'seal-predicate', name);

const SEAL = 0, NO_SEAL = 1, INFRA = 2;

function run(args) {
  const r = spawnSync('node', [PREDICATE, ...args], { encoding: 'utf8', timeout: 120000 });
  assert.equal(r.error, undefined, `the predicate never ran: ${r.error && r.error.message}`);
  assert.notEqual(r.status, null, `the predicate produced no exit status (signal ${r.signal})`);
  return { status: r.status, out: `${r.stdout}${r.stderr}` };
}

const fixtureRun = (name, extra = []) =>
  run(['--ledger', FIX(name), '--repo', REPO, '--guard-cmd', 'true', ...extra]);

// ── DEFECT 1 — NULL SUCCESSOR SILENT SEAL ───────────────────────────────────
// Pre-fix: with >=1 live row a null successor orphaned it and redded, but with ZERO
// live rows `forwarded` was never consulted, ok stayed true, and the run exited 0
// while the SCOPE paragraph said "0 forwarded by name / to null". The defect fired
// exactly at the moment of success — the one run anybody would ever quote.
test('defect 1: zero live rows + a null successor REFUSES instead of sealing', () => {
  const { status, out } = fixtureRun('zero-live-null-successor.json');
  assert.equal(status, NO_SEAL, 'a null successor must not exit 0');
  assert.match(out, /VERDICT-TOKEN: SEAL-PREDICATE REFUSED reason=NO-SUCCESSOR/);
  assert.doesNotMatch(out, /VERDICT: SEAL$/m);
  assert.doesNotMatch(out, /to null/, 'the "to null" forwarding sentence must be unreachable');
});

// ── DEFECT 2 — THE THIRD RENDERING ──────────────────────────────────────────
test('defect 2: a fixture omitting the successor key never renders "to undefined"', () => {
  const { status, out } = fixtureRun('no-successor-key.json');
  assert.equal(status, NO_SEAL);
  assert.match(out, /VERDICT-TOKEN: SEAL-PREDICATE REFUSED reason=NO-SUCCESSOR/);
  assert.doesNotMatch(out, /undefined/, 'no rendering of the successor may say "undefined"');
});

// ── DEFECT 3 — BOGUS SUCCESSOR ACCEPTED VERBATIM ────────────────────────────
// Pre-fix: `--successor task-DOES-NOT-EXIST-9999` exited 0 and the id was PRINTED
// as the forwarding address. Nothing resolved it.
test('defect 3: an unresolvable successor is refused and never printed as a forwarding address', () => {
  const BOGUS = 'task-DOES-NOT-EXIST-9999';
  const { status, out } = fixtureRun('sealable.json', ['--successor', BOGUS]);
  assert.equal(status, NO_SEAL, 'an id that resolves to nothing must not seal');
  assert.match(out, /VERDICT-TOKEN: SEAL-PREDICATE REFUSED reason=UNRESOLVABLE-SUCCESSOR/);
  assert.match(out, new RegExp(`Rejected id: ${BOGUS}`), 'the rejected id is named AS rejected');
  // It may appear as the id that was refused; it may never appear as an address.
  assert.doesNotMatch(out, new RegExp(`successor: ${BOGUS}`));
  assert.doesNotMatch(out, new RegExp(`to ${BOGUS}`));
  assert.doesNotMatch(out, /forwarded by name/);
});

test('defect 3b: a successor that exists but is UNPUBLISHED does not resolve', () => {
  const fx = JSON.parse(readFileSync(FIX('sealable.json'), 'utf8'));
  fx.tasks['cch-fixture-successor-epic'].status = 'draft';
  const path = join(mkdtempSync(join(tmpdir(), 'seal-pred-')), 'draft-successor.json');
  writeFileSync(path, JSON.stringify(fx));
  const { status, out } = run(['--ledger', path, '--repo', REPO, '--guard-cmd', 'true']);
  assert.equal(status, NO_SEAL);
  assert.match(out, /reason=UNRESOLVABLE-SUCCESSOR/);
  assert.match(out, /status=draft/);
});

// ── DEFECT 4 — EMPTY DEFECT REGISTER FAILS OPEN ─────────────────────────────
// Pre-fix: a copy with KNOWN_DEFECTS = [] sealed at exit 0 having spawned NO guard.
// The disclosure line said "KNOWN over 0 hand-registered defects"; the VERDICT line
// was an unqualified SEAL. An honest sentence over an exit 0 is the same defect.
test('defect 4: an empty KNOWN_DEFECTS register cannot seal', () => {
  const src = readFileSync(PREDICATE, 'utf8');
  const mutated = src.replace(/const KNOWN_DEFECTS = \[[\s\S]*?\n\];/, 'const KNOWN_DEFECTS = [];');
  assert.notEqual(mutated, src, 'the KNOWN_DEFECTS mutation must actually apply');
  assert.doesNotMatch(mutated, /GR108-tablet-topbar-overflow/, 'the register must really be empty');
  const path = join(mkdtempSync(join(tmpdir(), 'seal-pred-')), 'empty-register.mjs');
  writeFileSync(path, mutated);
  const r = spawnSync('node', [path, '--ledger', FIX('sealable.json'), '--repo', REPO, '--guard-cmd', 'true'], { encoding: 'utf8' });
  const out = `${r.stdout}${r.stderr}`;
  assert.equal(r.status, NO_SEAL, 'a register of zero defects must not exit 0');
  assert.match(out, /VERDICT-TOKEN: SEAL-PREDICATE REFUSED reason=EMPTY-DEFECT-REGISTER/);
  assert.doesNotMatch(out, /VERDICT: SEAL$/m);
});

// ── THE CONTROL: the refusals were added BEFORE the clauses, not INSTEAD ─────
test('a resolvable successor over a clean fixture still SEALS at exit 0', () => {
  const { status, out } = fixtureRun('sealable.json');
  assert.equal(status, SEAL, 'the happy path must remain reachable');
  assert.match(out, /^VERDICT: SEAL$/m);
  assert.match(out, /VERDICT-TOKEN: SEAL-PREDICATE SEAL a=PASS b=PASS c=PASS orphans=0 successor=cch-fixture-successor-epic/);
  assert.match(out, /to cch-fixture-successor-epic/);
});

test('clause (a) still reds: a resolvable successor does not forgive unnamed residue', () => {
  const { status, out } = fixtureRun('orphan-residue.json');
  assert.equal(status, NO_SEAL);
  assert.match(out, /VERDICT-TOKEN: SEAL-PREDICATE NO-SEAL a=FAIL b=PASS c=PASS orphans=1/);
  assert.match(out, /✗ gr-fixture-orphan-1/);
});

// ── THE GUARD ARM, exercised WITHOUT --guard-cmd ────────────────────────────
// Pointing --repo at an empty directory makes the committed guard unreachable; the
// clause must fail CLOSED, because unmeasured is never cleared.
test('without --guard-cmd, an uncommitted guard fails closed rather than passing', () => {
  const empty = mkdtempSync(join(tmpdir(), 'seal-pred-norepo-'));
  const { status, out } = run(['--ledger', FIX('sealable.json'), '--repo', empty]);
  assert.equal(status, NO_SEAL);
  assert.match(out, /is NOT COMMITTED — the fix is unmeasured/);
  assert.match(out, /VERDICT-TOKEN: SEAL-PREDICATE NO-SEAL a=PASS b=FAIL/);
});

// ── THE THIRD EXIT CODE, ported from tooling/grip/seal.mjs ───────────────────
test('an unreadable ledger is INFRA FAULT (exit 2), never NO SEAL (exit 1)', () => {
  const { status, out } = run(['--ledger', join(tmpdir(), 'seal-predicate-no-such-fixture.json'), '--repo', REPO]);
  assert.equal(status, INFRA, 'infra must not be reported through the verdict code');
  assert.match(out, /INFRA FAULT at /);
  assert.match(out, /VERDICT-TOKEN: SEAL-PREDICATE INFRA-FAULT a=UNKNOWN b=UNKNOWN c=UNKNOWN/);
  assert.doesNotMatch(out, /VERDICT: NO SEAL/);
});

// ── R0 — THE OVERRIDE CANNOT REACH A LIVE RUN ────────────────────────────────
// `--guard-cmd` is applied verbatim once per registered defect and never receives
// the defect id, so ONE `--guard-cmd true` marks all three entries measured-clean.
// That is a command-line path to the exact vacuous green clause (b) exists to
// prevent. Binding it to --ledger means the live run — the only run whose green
// anybody quotes — cannot substitute a stub for the browser guard.
test('R0: --guard-cmd without --ledger is REFUSED before any clause runs', () => {
  const { status, out } = run(['--repo', REPO, '--guard-cmd', 'true', '--successor', 'whatever']);
  assert.equal(status, NO_SEAL, 'a live run with a stubbed guard must never seal');
  assert.match(out, /VERDICT-TOKEN: SEAL-PREDICATE REFUSED reason=GUARD-OVERRIDE-WITHOUT-FIXTURE/);
  assert.match(out, /a=UNEVALUATED b=UNEVALUATED c=UNEVALUATED/);
  assert.doesNotMatch(out, /VERDICT: SEAL$/m);
  // It refuses BEFORE the network, so an unreachable ledger server cannot turn
  // this into an infra fault that reads as "inconclusive".
  assert.doesNotMatch(out, /INFRA FAULT/);
});

test('every run emits exactly one machine-readable VERDICT-TOKEN line', () => {
  for (const args of [
    ['--ledger', FIX('sealable.json'), '--repo', REPO, '--guard-cmd', 'true'],
    ['--ledger', FIX('orphan-residue.json'), '--repo', REPO, '--guard-cmd', 'true'],
    ['--ledger', FIX('no-successor-key.json'), '--repo', REPO, '--guard-cmd', 'true'],
    ['--ledger', join(tmpdir(), 'seal-predicate-no-such-fixture.json'), '--repo', REPO],
  ]) {
    const { out } = run(args);
    const lines = out.split('\n').filter((l) => l.startsWith('VERDICT-TOKEN:'));
    assert.equal(lines.length, 1, `expected one VERDICT-TOKEN line, got ${lines.length} for ${args.join(' ')}`);
  }
});
