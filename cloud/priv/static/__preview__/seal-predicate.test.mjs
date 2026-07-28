// TESTS FOR THE SEAL PREDICATE.
//
// Until wave 6 this instrument had ZERO tests anywhere in the repo — every claim
// about its behaviour was contract-read, which is how it shipped able to print
// `VERDICT: SEAL` over "0 forwarded by name / to null". Wave 6 pinned four measured
// defects. Wave 7 retargeted the predicate at THIS epic, and the retarget itself was
// measured to pass the wave-6 suite 11/11 with ZERO test edits — i.e. that suite was
// blind to WHICH epic it certified, to the self-successor false green, to `considering`
// rows and to the measurement ladder. Those are the tests below the wave-6 block.
//
// The predicate is exercised AS A PROCESS, never as an import: its contract is an
// EXIT CODE, and only a spawn can test an exit code. `SEAL_PREDICATE_PATH` points
// the whole file at a mutated copy, so "these tests red against the pre-fix
// behaviour" is itself a command anyone can rerun:
//
//   git show <pre-fix-sha>:cloud/priv/static/__preview__/seal-predicate.mjs > /tmp/pre.mjs
//   SEAL_PREDICATE_PATH=/tmp/pre.mjs node --test cloud/priv/static/__preview__/seal-predicate.test.mjs
//
// `--guard-cmd true` stands in for the committed guards so most tests measure clause
// (a) and the refusals, not two real guard suites. Tests that assert the LADDER omit
// it and run the guards for real. The whole file is HERMETIC: no test reaches the
// network (proven at wave 6 with a sentinel `curl` shim first on PATH — it never
// fired), and no test writes inside the repo.

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
const EPIC = 'cloud-console-hardening-epic';

function run(args) {
  const r = spawnSync('node', [PREDICATE, ...args], { encoding: 'utf8', timeout: 120000 });
  assert.equal(r.error, undefined, `the predicate never ran: ${r.error && r.error.message}`);
  assert.notEqual(r.status, null, `the predicate produced no exit status (signal ${r.signal})`);
  return { status: r.status, out: `${r.stdout}${r.stderr}` };
}

const fixtureRun = (name, extra = []) =>
  run(['--ledger', FIX(name), '--repo', REPO, '--guard-cmd', 'true', ...extra]);

// Write a mutated copy of the predicate to a temp dir and run it. The mutation must
// actually apply — a regex that silently matched nothing would make every mutation
// proof below vacuous.
function mutatedRun(mutate, args) {
  const src = readFileSync(PREDICATE, 'utf8');
  const out = mutate(src);
  assert.notEqual(out, src, 'the mutation must actually apply');
  const path = join(mkdtempSync(join(tmpdir(), 'seal-pred-mut-')), 'mutated.mjs');
  writeFileSync(path, out);
  const r = spawnSync('node', [path, ...args], { encoding: 'utf8', timeout: 120000 });
  return { status: r.status, out: `${r.stdout}${r.stderr}` };
}

const token = (out) => out.split('\n').find((l) => l.startsWith('VERDICT-TOKEN:')) || '(no token)';

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
//
// DE-VACUUMED (charter D90): the wave-6 form asserted the emptiness sentinel as the
// literal `/GR108-tablet-topbar-overflow/`, which the wave-7 retarget made VACUOUSLY
// TRUE — the register no longer holds that id, so the assertion passed without the
// mutation doing anything. The sentinel is now DERIVED from the source's own first
// register entry, so it tracks whatever the register actually contains.
test('defect 4: an empty KNOWN_DEFECTS register cannot seal (sentinel derived, not hardcoded)', () => {
  const src = readFileSync(PREDICATE, 'utf8');
  const firstId = (src.match(/const KNOWN_DEFECTS = \[\s*\{\s*\n\s*id: '([^']+)'/) || [])[1];
  assert.ok(firstId, 'the emptiness sentinel must be derivable from KNOWN_DEFECTS[0].id');
  assert.match(src, new RegExp(firstId), 'sanity: the derived sentinel is present BEFORE the mutation');

  const mutated = src.replace(/const KNOWN_DEFECTS = \[[\s\S]*?\n\];/, 'const KNOWN_DEFECTS = [];');
  assert.notEqual(mutated, src, 'the KNOWN_DEFECTS mutation must actually apply');
  assert.doesNotMatch(mutated, new RegExp(firstId), 'the register must really be empty');
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
  assert.match(out, /VERDICT-TOKEN: SEAL-PREDICATE SEAL a=PASS b=PASS c=PASS orphans=0 considering=0 successor=cch-fixture-successor-epic/);
  assert.match(out, /to cch-fixture-successor-epic/);
  // A fixture green says so, in the same breath, and in the machine-readable line.
  assert.match(out, /FIXTURE-ONLY GREEN: 2 guard\(s\) STUBBED/);
  assert.match(out, /mode=fixture stubbed=2 waived=1/);
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
    ['--ledger', FIX('terminal-clean.json'), '--repo', REPO, '--guard-cmd', 'true'],
    ['--ledger', FIX('self-successor.json'), '--repo', REPO, '--guard-cmd', 'true'],
    ['--ledger', join(tmpdir(), 'seal-predicate-no-such-fixture.json'), '--repo', REPO],
  ]) {
    const { out } = run(args);
    const lines = out.split('\n').filter((l) => l.startsWith('VERDICT-TOKEN:'));
    assert.equal(lines.length, 1, `expected one VERDICT-TOKEN line, got ${lines.length} for ${args.join(' ')}`);
  }
});

// ═══ WAVE 7 ═════════════════════════════════════════════════════════════════
// Everything above passed 11/11 against a FULLY RETARGETED predicate with zero
// edits. That is the measurement that made the tests below mandatory.

// ── THE SUBJECT OF THE VERDICT ──────────────────────────────────────────────
test('wave 7: the predicate names the epic it is judging, in the header and the token', () => {
  const { out } = fixtureRun('sealable.json');
  assert.match(out, new RegExp(`^=== SEAL PREDICATE — epic ${EPIC} ===$`, 'm'),
    'the header must name the epic under judgement, not a predecessor');
  assert.match(out, new RegExp(`epic=${EPIC}`), 'the machine-readable token carries the epic');
  assert.doesNotMatch(out, /Cloud GUI Remake/, 'no run may print the predecessor epic\'s name');
  // And the SCOPE paragraph may not assert numbers the program does not compute.
  assert.doesNotMatch(out, /21 clean-CAS|0 of 39|upper 95%|crown is DARK/,
    'the predecessor\'s hardcoded SCOPE arithmetic must be gone, not restated');
});

test('wave 7: --epic retargets the subject of every clause, including the refusal path', () => {
  const OTHER = 'some-other-epic-entirely';
  const { out } = fixtureRun('sealable.json', ['--epic', OTHER]);
  assert.match(out, new RegExp(`^=== SEAL PREDICATE — epic ${OTHER} ===$`, 'm'));
  assert.match(out, new RegExp(`epic=${OTHER}`));
  // A refusal must carry the epic too — a verdict about an unnamed epic is unreadable.
  const refused = fixtureRun('zero-live-null-successor.json', ['--epic', OTHER]);
  assert.match(refused.out, new RegExp(`^=== SEAL PREDICATE — epic ${OTHER} ===$`, 'm'));
  assert.match(refused.out, new RegExp(`REFUSED reason=NO-SUCCESSOR .*epic=${OTHER}`));
});

// ── R4 — FORWARDING TO YOURSELF IS NOT FORWARDING ───────────────────────────
// Measured live before R4 existed: `--successor cloud-console-hardening-epic` over 83
// live rows returned `forwarded: 79`, `orphans: 0`, `a=PASS` — because `forwarded` is
// fetchRoster(SUCCESSOR), which for the epic's own id is the epic's own roster. The
// fixture reproduces that shape (every live row present in `forwarded`), and the
// mutation runs the SAME invocation against an R4-less copy.
test('R4: a successor equal to the epic is REFUSED before any clause is evaluated', () => {
  const { status, out } = fixtureRun('self-successor.json');
  assert.equal(status, NO_SEAL);
  assert.match(out, /VERDICT-TOKEN: SEAL-PREDICATE REFUSED reason=SELF-SUCCESSOR/);
  assert.match(out, /Forwarding to yourself is not forwarding/);
  assert.match(out, /a=UNEVALUATED b=UNEVALUATED c=UNEVALUATED/);
  assert.doesNotMatch(out, /VERDICT: SEAL$/m);
});

test('R4 MUTATION PROOF: with R4 removed, the identical run seals at a=PASS', () => {
  const { status, out } = mutatedRun(
    (src) => src.replace(/  if \(SUCCESSOR === EPIC\)\n    throw new Refusal\('SELF-SUCCESSOR',[\s\S]*?\);\n/, ''),
    ['--ledger', FIX('self-successor.json'), '--repo', REPO, '--guard-cmd', 'true'],
  );
  assert.equal(status, SEAL, `without R4 the self-successor run seals: ${token(out)}`);
  assert.match(out, /a=PASS/, 'clause (a) is structurally unfailable when the successor is the epic');
  assert.match(out, /orphans=0/);
  // Both verdict tokens, side by side, are the proof R4 is load-bearing.
  assert.match(token(out), /SEAL-PREDICATE SEAL a=PASS/);
  assert.match(token(fixtureRun('self-successor.json').out), /REFUSED reason=SELF-SUCCESSOR/);
});

// ── THE FOURTH CLAUSE-(a) SHAPE: TERMINAL ───────────────────────────────────
// Without it, R2 (no successor) + R3 (no placeholder resolves) make "zero residue,
// terminal epic" UNREACHABLE — the epic is required to spawn a child forever.
test('TERMINAL seals ONLY on a roster read of live==0 AND considering==0', () => {
  const { status, out } = fixtureRun('terminal-clean.json');
  assert.equal(status, SEAL);
  assert.match(out, /^VERDICT: SEAL$/m);
  assert.match(out, /post-condition roster read: live=0 considering=0/);
  assert.match(out, /TERMINAL, on a roster read of live=0 and considering=0/);
  assert.match(token(out), /SEAL-PREDICATE SEAL a=PASS .*successor=TERMINAL/);
});

test('TERMINAL is REFUTED by one live row — the flag is not the claim', () => {
  const { status, out } = fixtureRun('terminal-one-live-row.json');
  assert.equal(status, NO_SEAL);
  assert.match(out, /VERDICT-TOKEN: SEAL-PREDICATE REFUSED reason=TERMINAL-CLAIM-REFUTED/);
  assert.match(out, /gr-fixture-still-open-1/, 'the row that refutes the claim is NAMED');
  assert.match(out, /after the post-condition roster read/,
    'the refusal must say it was reached AFTER reading the roster, not before');
  assert.doesNotMatch(out, /VERDICT: SEAL$/m);
});

test('TERMINAL is REFUTED by one CONSIDERING row', () => {
  const { status, out } = fixtureRun('terminal-one-considering-row.json');
  assert.equal(status, NO_SEAL);
  assert.match(out, /VERDICT-TOKEN: SEAL-PREDICATE REFUSED reason=TERMINAL-CLAIM-REFUTED/);
  assert.match(out, /gr-fixture-considering-1/, 'the considering row is NAMED');
  assert.doesNotMatch(out, /VERDICT: SEAL$/m);
});

// ── `considering` IS COUNTED, NEVER SILENTLY EXEMPT ─────────────────────────
test('a considering row is residue: counted into clause (a) and disclosed by name', () => {
  const { status, out } = fixtureRun('considering-residue.json');
  assert.equal(status, NO_SEAL, 'unfinished work with no forwarding address must not seal');
  assert.match(out, /considering \(disclosed\)   : 1  \[gr-fixture-considering-1\]/);
  assert.match(out, /✗ gr-fixture-considering-1/, 'an unforwarded considering row is an orphan');
  assert.match(token(out), /a=FAIL .*orphans=1 considering=1/);
});

test('MUTATION PROOF: with `considering` dropped from the residue set, the same fixture seals', () => {
  const { status, out } = mutatedRun(
    (src) => src.replace("const PENDING_STATUSES = ['considering'];", 'const PENDING_STATUSES = [];'),
    ['--ledger', FIX('considering-residue.json'), '--repo', REPO, '--guard-cmd', 'true'],
  );
  assert.equal(status, SEAL, `the pre-fix filter seals over an unfinished row: ${token(out)}`);
  assert.match(token(out), /SEAL a=PASS/);
  // …and the row is disclosed NOWHERE in that green. That is the defect.
  assert.doesNotMatch(out.split('VERDICT: SEAL')[0], /gr-fixture-considering-1/);
});

// ── CLAUSE (b): THE THREE-RUNG LADDER ───────────────────────────────────────
// Run WITHOUT --guard-cmd, so the two committed guards actually execute.
test('clause (b) prints three distinct outcomes and FAILS on the rate limiter by name', () => {
  const { status, out } = run(['--ledger', FIX('ladder-no-waiver.json'), '--repo', REPO]);
  assert.equal(status, NO_SEAL, 'a rung-3 entry must make clause (b) fail');

  // rung 1 — measured HERE, and the guard's own output had to name the measurement.
  assert.match(out, /MEASURED HERE by cloud\/priv\/static\/__app\.test\.mjs/);
  assert.match(out, /which printed "cch-w1: seven fleet ticks after one boot cost 12 requests, not 40"/);
  assert.match(out, /MEASURED HERE by design\/emit-fence\.test\.mjs/);

  // rung 2 — passes, but says in the same breath that it did not run.
  assert.match(out, /rung 2 — MEASURED-ELSEWHERE/);
  assert.match(out, /MEASURED-ELSEWHERE by cloud\/test\/barkpark_cloud\/web\/router_test\.exs, run by \.github\/workflows\/cloud\.yml job `test` on cloud\/\*\*/);
  assert.match(out, /THIS RUN DID NOT EXECUTE IT/);

  // rung 3 — neither. Named, with the gap stated, and it is the reason for the red.
  assert.match(out, /✗ CCH-D5-rate-limiter-sees-every-user-as-one  \(rung 3\)/);
  assert.match(out, /NO MEASUREMENT \(rung 3\): no test anywhere asserts that two clients/);
  assert.match(out, /unlanded, unverifiable or UNMEASURED \(clause b\): CCH-D5-rate-limiter-sees-every-user-as-one/);
  assert.match(token(out), /b=FAIL/);
});

test('a rung-1 guard that exits 0 without naming its measurement does NOT count as measured', () => {
  const { status, out } = mutatedRun(
    (src) => src.replace(
      "guardExpect: 'cch-w1: seven fleet ticks after one boot cost 12 requests, not 40',",
      "guardExpect: 'a sentence this guard never prints',",
    ),
    ['--ledger', FIX('ladder-no-waiver.json'), '--repo', REPO],
  );
  assert.equal(status, NO_SEAL);
  assert.match(out, /guard exited 0 but its output never named the measurement/);
  assert.match(out, /an exit code is not a post-condition read/);
});

// A guard's verdict must not depend on WHO SPAWNED IT. Measured while building this
// suite, and it is exactly the day's law turned on the instrument itself: `node --test`
// exports NODE_TEST_CONTEXT, a node:test guard inherits it and switches to the
// V8-serialised reporter, whose stream is 1.16MB — over spawnSync's default 1MB buffer.
// The guard PASSED; the predicate read ENOBUFS and reported "NEVER RAN", i.e. it made a
// claim about a defect from a read that failed. Two repairs: the guard env is sanitised,
// and the guard spawn carries a buffer large enough to hold a chatty guard.
test('a passing guard is never misread as unrun because of who spawned it', () => {
  const r = spawnSync('node', [PREDICATE, '--ledger', FIX('ladder-no-waiver.json'), '--repo', REPO],
    { encoding: 'utf8', timeout: 120000, env: { ...process.env, NODE_TEST_CONTEXT: 'child-v8' } });
  const out = `${r.stdout}${r.stderr}`;
  assert.match(out, /MEASURED HERE by cloud\/priv\/static\/__app\.test\.mjs/,
    'an inherited NODE_TEST_CONTEXT must not change what the guard is read to have said');

  // MUTATION: put both leaks back, and the SAME passing guard is reported as unrun.
  const leaky = mutatedRun(
    (src) => src
      .replace(/for \(const k of \['NODE_TEST_CONTEXT'[^\n]*\n/, '')
      .replace(', env: GUARD_ENV, maxBuffer: 16 * 1024 * 1024 });', '});'),
    ['--ledger', FIX('ladder-no-waiver.json'), '--repo', REPO],
  );
  assert.match(leaky.out, /guard cloud\/priv\/static\/__app\.test\.mjs NEVER RAN \(ENOBUFS\)/,
    'pre-fix, a guard whose output overflowed the spawn buffer was reported as never having run');
  assert.match(leaky.out, /✗ CCH-D1-overview-refetch-storm/);
});

// ── THE COMMIT IS VERIFIED BY ITS DIFF, NEVER BY ITS SUBJECT ────────────────
// `481d6f231`'s subject is a sign-out cleanup; its squash body carries the coalescing
// fix. The fixture supplies that subject line AS the patch body.
test('a commit whose diff is only its subject line FAILS clause (b)', () => {
  const { status, out } = fixtureRun('diff-is-only-the-subject.json');
  assert.equal(status, NO_SEAL);
  assert.match(out, /diff never matches .* — verified by DIFF, never by subject line/);
  assert.match(out, /✗ CCH-D1-overview-refetch-storm/);
  assert.match(token(out), /b=FAIL/);
});

test('the live commit fetch never reads the commit message at all', () => {
  const src = readFileSync(PREDICATE, 'utf8');
  assert.match(src, /'show', '--format=', sha/,
    'git show must be invoked with an EMPTY --format, so the subject is never in the process');
  assert.doesNotMatch(src, /--format=%s|--pretty/, 'no subject-line format may be used anywhere');
});

// ── A GUARD'S EXIT 2 IS A REFUSAL, NOT A DEFECT CLAIM ───────────────────────
// `overflow-guard.mjs` exits 2 for an unknown --defect. The predecessor laundered that
// into "the defect is still measurable at origin/main" — a defect claim over a
// measurement that never happened. The GUARD-side fix belongs to the open row
// `hg-overflow-guard-refusal-exits-1`; this file only reads the code honestly.
test('a guard exiting 2 is INFRA FAULT (exit 2), never a NO SEAL defect claim', () => {
  const { status, out } = run(['--ledger', FIX('sealable.json'), '--repo', REPO, '--guard-cmd', 'exit 2']);
  assert.equal(status, INFRA, 'a refusal to measure must not be reported as a verdict');
  assert.match(out, /INFRA FAULT at /);
  assert.match(out, /that is a REFUSAL to measure/);
  assert.match(out, /VERDICT-TOKEN: SEAL-PREDICATE INFRA-FAULT/);
  assert.doesNotMatch(out, /still measurable at origin\/main/,
    'exit 2 must never be laundered into a defect claim');
  assert.doesNotMatch(out, /VERDICT: NO SEAL/);
});

test('a guard exiting 1 IS a defect claim — exit 2 is not merely "any non-zero"', () => {
  const { status, out } = run(['--ledger', FIX('sealable.json'), '--repo', REPO, '--guard-cmd', 'exit 1']);
  assert.equal(status, NO_SEAL);
  assert.match(out, /guard exited 1 — the defect is still measurable at origin\/main/);
  assert.match(token(out), /NO-SEAL .*b=FAIL/);
});

test('the guard-side exit-2 fix is NAMED, not duplicated into this file', () => {
  const src = readFileSync(PREDICATE, 'utf8');
  assert.match(src, /hg-overflow-guard-refusal-exits-1/,
    'the row that owns the guard-side fix must be named by id');
});

// ── BUCKET (c) IS THE THREE OF CHARTER D89 ──────────────────────────────────
test('the permanent human gate bucket is exactly three, and billing is gone', () => {
  const { out } = fixtureRun('sealable.json');
  for (const id of ['gr-ops-platform-admin-emails', 'gr-backlog-qr-live-scan-proof', 'cch-hg-compose-network-recreation'])
    assert.match(out, new RegExp(`✓ ${id}  status=`), `${id} must be disclosed by hardcoded name`);
  assert.doesNotMatch(out, /cloud-console-billing-live-gate/,
    'billing hangs under cloud-console-goal, which is lifecycle=done — a tombstoned address');
  const rows = out.split('\n').filter((l) => /^  [✓✗] \S+  status=/.test(l));
  assert.equal(rows.length, 3, `the bucket is three rows, got ${rows.length}`);
});

test('bucket (c) still reds when a hardcoded gate stops resolving', () => {
  const fx = JSON.parse(readFileSync(FIX('sealable.json'), 'utf8'));
  delete fx.gates['cch-hg-compose-network-recreation'];
  const path = join(mkdtempSync(join(tmpdir(), 'seal-pred-')), 'gate-vanished.json');
  writeFileSync(path, JSON.stringify(fx));
  const { status, out } = run(['--ledger', path, '--repo', REPO, '--guard-cmd', 'true']);
  assert.equal(status, NO_SEAL, 'a gate that silently vanished is NO SEAL, not a clean sheet');
  assert.match(out, /✗ cch-hg-compose-network-recreation/);
  assert.match(token(out), /c=FAIL/);
});
