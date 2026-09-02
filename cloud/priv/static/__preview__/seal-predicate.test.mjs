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
import { mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const PREDICATE = process.env.SEAL_PREDICATE_PATH || join(HERE, 'seal-predicate.mjs');
const REPO = resolve(HERE, '../../../..');
const FIX = (name) => join(HERE, 'fixtures', 'seal-predicate', name);
const CLOUD_WF = join(REPO, '.github', 'workflows', 'cloud.yml');
const REQUIRED_CHECKS = join(REPO, '.github', 'required-checks.json');
const AGG = 'Cloud gate';

const SEAL = 0, NO_SEAL = 1, INFRA = 2, REFUSED = 3; // REFUSED (exit 3): nothing measured — a Refusal, never a verdict
const EPIC = 'cloud-console-hardening-epic';

const tmp = (prefix) => mkdtempSync(join(tmpdir(), prefix));

function run(args) {
  const r = spawnSync('node', [PREDICATE, ...args], { encoding: 'utf8', timeout: 120000 });
  assert.equal(r.error, undefined, `the predicate never ran: ${r.error && r.error.message}`);
  assert.notEqual(r.status, null, `the predicate produced no exit status (signal ${r.signal})`);
  return { status: r.status, out: `${r.stdout}${r.stderr}` };
}

// ── WHY EVERY FIXTURE NOW CARRIES `requiredContexts` ────────────────────────
// Wave 9 made rung 2 depend on BRANCH PROTECTION: a measurement counts only if a
// required status check goes red when its job does. `Cloud gate` is not registered
// yet — that is `cch-w9-register-console-and-cloud-gates` — so on the REAL branch
// every rung-2 entry is honestly rung 3 and clause (b) FAILS. Without an override,
// every clause-(a) fixture below would red for a clause-(b) reason and stop
// measuring the thing it was written to measure.
//
// So the ledger fixture stands in for branch protection exactly as `landed` stands
// in for ancestry and `diffs` for the patch — fixture-only, and printed as such in
// the MEASURED-ELSEWHERE line. `liveRun` below keeps the unoverridden truth pinned,
// and the leg tests drive the FILE, not the override.
const withRequired = (name, contexts = [AGG]) => {
  const fx = JSON.parse(readFileSync(FIX(name), 'utf8'));
  fx.requiredContexts = contexts;
  const p = join(tmp('seal-pred-fx-'), name);
  writeFileSync(p, JSON.stringify(fx));
  return p;
};

const fixtureRun = (name, extra = []) =>
  run(['--ledger', withRequired(name), '--repo', REPO, '--guard-cmd', 'true', ...extra]);

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
  assert.equal(status, REFUSED, 'a null successor must not exit 0');
  assert.match(out, /VERDICT-TOKEN: SEAL-PREDICATE REFUSED reason=NO-SUCCESSOR/);
  assert.doesNotMatch(out, /VERDICT: SEAL$/m);
  assert.doesNotMatch(out, /to null/, 'the "to null" forwarding sentence must be unreachable');
});

// ── DEFECT 2 — THE THIRD RENDERING ──────────────────────────────────────────
test('defect 2: a fixture omitting the successor key never renders "to undefined"', () => {
  const { status, out } = fixtureRun('no-successor-key.json');
  assert.equal(status, REFUSED);
  assert.match(out, /VERDICT-TOKEN: SEAL-PREDICATE REFUSED reason=NO-SUCCESSOR/);
  assert.doesNotMatch(out, /undefined/, 'no rendering of the successor may say "undefined"');
});

// ── DEFECT 3 — BOGUS SUCCESSOR ACCEPTED VERBATIM ────────────────────────────
// Pre-fix: `--successor task-DOES-NOT-EXIST-9999` exited 0 and the id was PRINTED
// as the forwarding address. Nothing resolved it.
test('defect 3: an unresolvable successor is refused and never printed as a forwarding address', () => {
  const BOGUS = 'task-DOES-NOT-EXIST-9999';
  const { status, out } = fixtureRun('sealable.json', ['--successor', BOGUS]);
  assert.equal(status, REFUSED, 'an id that resolves to nothing must not seal');
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
  fx.requiredContexts = [AGG];
  const path = join(tmp('seal-pred-'), 'draft-successor.json');
  writeFileSync(path, JSON.stringify(fx));
  const { status, out } = run(['--ledger', path, '--repo', REPO, '--guard-cmd', 'true']);
  assert.equal(status, REFUSED);
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
  const r = spawnSync('node', [path, '--ledger', withRequired('sealable.json'), '--repo', REPO, '--guard-cmd', 'true'], { encoding: 'utf8' });
  const out = `${r.stdout}${r.stderr}`;
  assert.equal(r.status, REFUSED, 'a register of zero defects must not exit 0');
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
  // `waived=0` since wave 8: sealable.json still CARRIES an `unmeasuredWaivers` entry
  // for CCH-D5, but a waiver is only consulted for a rung-3 entry and CCH-D5 is now
  // MEASURED, so nothing is waived. The waiver branch is therefore no longer reachable
  // by any unmutated fixture — the test directly below keeps it measured rather than
  // leaving live code with no test, which is this epic's own disease.
  assert.match(out, /mode=fixture stubbed=2 waived=0/);
});

// The waiver branch (`seal-predicate.mjs`, `waivers.has(d.id)`) exists so a clause-(a)
// fixture can reach a SEAL while a rung-3 entry stands unmeasured in the register. Wave
// 8 paid CCH-D5 off, which emptied the register of rung-3 entries and left that branch
// live but unexercised. It is kept measured by MUTATION: put a rung-3 entry back and the
// waiver in the ledger must consume it — named, printed, and counted in the token.
test('the ledger waiver still consumes a rung-3 entry, and says so in the same breath', () => {
  const waived = mutatedRun(
    (src) => src.replace(
      /    measured_by: \['cloud\/test\/barkpark_cloud\/web\/router_signin_rate_bucket_test\.exs'\],\n    measured_in_ci: \{ workflow: '\.github\/workflows\/cloud\.yml', job: 'test' \},\n/,
      "    unmeasured: 'nothing measures the bucket separation',\n",
    ),
    ['--ledger', withRequired('sealable.json'), '--repo', REPO, '--guard-cmd', 'true'],
  );
  assert.equal(waived.status, SEAL, `a waived rung-3 entry must still seal: ${token(waived.out)}`);
  assert.match(waived.out, /UNMEASURED — WAIVED BY LEDGER FIXTURE/);
  assert.match(waived.out, /1 unmeasured entr\(ies\) WAIVED by the ledger fixture/);
  assert.match(token(waived.out), /waived=1/);
  // A waiver is fixture-only and must never be a silent one: the green says so.
  assert.match(waived.out, /FIXTURE-ONLY GREEN/);

  // AND the waiver is not a blanket forgiveness — it clears only the id it names.
  // Rename that id and the SAME rung-3 entry reds by name.
  const unwaived = mutatedRun(
    (src) => src.replace(
      /    measured_by: \['cloud\/test\/barkpark_cloud\/web\/router_signin_rate_bucket_test\.exs'\],\n    measured_in_ci: \{ workflow: '\.github\/workflows\/cloud\.yml', job: 'test' \},\n/,
      "    unmeasured: 'nothing measures the bucket separation',\n",
    ).replace(
      "id: 'CCH-D5-rate-limiter-sees-every-user-as-one',",
      "id: 'CCH-D5-rate-limiter-sees-every-user-as-one-NOT-THE-WAIVED-ID',",
    ),
    ['--ledger', withRequired('sealable.json'), '--repo', REPO, '--guard-cmd', 'true'],
  );
  assert.equal(unwaived.status, NO_SEAL, 'a waiver must not forgive an id it does not name');
  assert.match(unwaived.out, /NO MEASUREMENT \(rung 3\): nothing measures the bucket separation/);
  assert.match(token(unwaived.out), /b=FAIL waived=0|waived=0/);
});

test('clause (a) still reds: a resolvable successor does not forgive unnamed residue', () => {
  const { status, out } = fixtureRun('orphan-residue.json');
  assert.equal(status, NO_SEAL);
  assert.match(out, /VERDICT-TOKEN: SEAL-PREDICATE NO-SEAL a=FAIL b=PASS c=PASS orphans=1/);
  assert.match(out, /✗ gr-fixture-orphan-1/);
});

// ── THE GUARD ARM, exercised WITHOUT --guard-cmd ────────────────────────────
// A committed guard that is not there makes the clause fail CLOSED, because unmeasured
// is never cleared.
//
// WAVE 27 REPLACED THE MECHANISM AND KEPT THE INTENT, AND SAYING WHY IS THE POINT.
// Until this edit the case pointed `--repo` at an EMPTY DIRECTORY — which is now an
// INFRA FAULT by construction, because an unreadable root cannot tell "this guard was
// never committed" from "you handed me the wrong tree", and for eight waves it printed
// the first sentence for the second condition. The property under test is unchanged and
// its two assertion targets are byte-identical; only the fixture moved, from a root the
// program cannot read to one it CAN read and which simply does not carry the guards.
// `synthRepo()` supplies the workflow and the required-checks record, so rung 2 resolves
// and the ONLY thing missing is the pair of rung-1 guard files.
test('without --guard-cmd, an uncommitted guard fails closed rather than passing', () => {
  const { status, out } = run(['--ledger', FIX('sealable.json'), '--repo', synthRepo({})]);
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
  assert.equal(status, REFUSED, 'a live run with a stubbed guard must never seal');
  assert.match(out, /VERDICT-TOKEN: SEAL-PREDICATE REFUSED reason=GUARD-OVERRIDE-WITHOUT-FIXTURE/);
  assert.match(out, /a=UNEVALUATED b=UNEVALUATED c=UNEVALUATED/);
  assert.doesNotMatch(out, /VERDICT: SEAL$/m);
  // It refuses BEFORE the network, so an unreachable ledger server cannot turn
  // this into an infra fault that reads as "inconclusive".
  assert.doesNotMatch(out, /INFRA FAULT/);
});

test('every run emits exactly one machine-readable VERDICT-TOKEN line', () => {
  for (const args of [
    ['--ledger', withRequired('sealable.json'), '--repo', REPO, '--guard-cmd', 'true'],
    ['--ledger', FIX('orphan-residue.json'), '--repo', REPO, '--guard-cmd', 'true'],
    ['--ledger', FIX('no-successor-key.json'), '--repo', REPO, '--guard-cmd', 'true'],
    ['--ledger', FIX('terminal-clean.json'), '--repo', REPO, '--guard-cmd', 'true'],
    ['--ledger', withRequired('self-successor.json'), '--repo', REPO, '--guard-cmd', 'true'],
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
  assert.equal(status, REFUSED);
  assert.match(out, /VERDICT-TOKEN: SEAL-PREDICATE REFUSED reason=SELF-SUCCESSOR/);
  assert.match(out, /Forwarding to yourself is not forwarding/);
  assert.match(out, /a=UNEVALUATED b=UNEVALUATED c=UNEVALUATED/);
  assert.doesNotMatch(out, /VERDICT: SEAL$/m);
});

test('R4 MUTATION PROOF: with R4 removed, the identical run seals at a=PASS', () => {
  const { status, out } = mutatedRun(
    (src) => src.replace(/  if \(SUCCESSOR === EPIC\)\n    throw new Refusal\('SELF-SUCCESSOR',[\s\S]*?\);\n/, ''),
    ['--ledger', withRequired('self-successor.json'), '--repo', REPO, '--guard-cmd', 'true'],
  );
  assert.equal(status, SEAL, `without R4 the self-successor run seals: ${token(out)}`);
  assert.match(out, /a=PASS/, 'clause (a) is structurally unfailable when the successor is the epic');
  assert.match(out, /orphans=0/);
  // Both verdict tokens, side by side, are the proof R4 is load-bearing.
  assert.match(token(out), /SEAL-PREDICATE SEAL a=PASS/);
  assert.match(token(fixtureRun('self-successor.json').out), /REFUSED reason=SELF-SUCCESSOR/);
});

// ── R5 / R6 — THE DEAD LETTERBOX (wave 12) ──────────────────────────────────
// Measured LIVE at 2026-07-31T05:47Z, on the origin/main copy of the predicate:
//   node seal-predicate.mjs --successor gr-p5r5-successor-seal
//   -> `epic cloud-console-hardening-epic   successor: gr-p5r5-successor-seal`
// It RESOLVED, and was printed as the forwarding address, over a row that is
// `lifecycle_status: done`, `status: published`, `parent_id:
// cloud-console-hardening-epic` — a corpse, AND a child of the epic it forwards out
// of, closed for PROMISING to file a successor. resolveTask read existence, `_type`
// and `status` and NEVER `lifecycle_status`; R4 refuses only SUCCESSOR === EPIC, so
// one hop below the epic was wide open. Two fences, two refusal codes, because "this
// id is a corpse" and "this id is inside the epic" are different ledger facts.
//
// `sealable.json` is the control on purpose: it is the ONLY non-terminal fixture that
// may exit 0, so each mutation below turns a REFUSAL back into a SEAL and the two
// tokens side by side are the proof the fence carries weight.
const successorFixture = (mutate, name) => {
  const fx = JSON.parse(readFileSync(FIX('sealable.json'), 'utf8'));
  mutate(fx.tasks['cch-fixture-successor-epic']);
  fx.requiredContexts = [AGG];
  const p = join(tmp('seal-pred-succ-'), name);
  writeFileSync(p, JSON.stringify(fx));
  return p;
};
const DEAD = (name) => successorFixture((t) => { t.lifecycle_status = name; }, `dead-${name}.json`);
const INSIDE = (parent) => successorFixture((t) => { t.parent_id = parent; }, 'successor-inside-epic.json');

// The mutations, hoisted so the fence tests and the mutation proofs cannot drift apart.
const DROP_R5 = (src) => src.replace(
  /  const lifecycle = doc\.lifecycle_status;\n  if \(!SUCCESSOR_LIVE_STATUSES\.includes\(lifecycle\)\)\n    return \{\n[\s\S]*?\n    \};\n/, '');
const DROP_R6 = (src) => src.replace(/  const epic = opts\.epic;\n  if \(epic\) \{\n[\s\S]*?\n  \}\n/, '');

test('R5: a successor that is a DONE row is REFUSED — a corpse is a dead letterbox', () => {
  const { status, out } = run(['--ledger', DEAD('done'), '--repo', REPO, '--guard-cmd', 'true']);
  assert.equal(status, REFUSED, 'a done successor must not seal');
  assert.match(out, /VERDICT-TOKEN: SEAL-PREDICATE REFUSED reason=DEAD-SUCCESSOR/);
  assert.match(out, /lifecycle_status=done/);
  assert.match(out, /dead letterbox/);
  assert.match(out, /Rejected id: cch-fixture-successor-epic/, 'the id is named AS rejected');
  // It may be named as refused; it may never be rendered as an address.
  assert.doesNotMatch(out, /successor: cch-fixture-successor-epic/);
  assert.doesNotMatch(out, /forwarded by name/);
  assert.doesNotMatch(out, /VERDICT: SEAL$/m);
});

test('R5: cancelled and a MISSING lifecycle_status are refused by the same fence', () => {
  const cancelled = run(['--ledger', DEAD('cancelled'), '--repo', REPO, '--guard-cmd', 'true']);
  assert.equal(cancelled.status, REFUSED);
  assert.match(token(cancelled.out), /REFUSED reason=DEAD-SUCCESSOR/);
  assert.match(cancelled.out, /lifecycle_status=cancelled/);

  // Absent is not live either: a row with no lifecycle at all is unworkable, and the
  // refusal says `(absent)` rather than rendering `undefined` at a reader.
  const absent = run(['--ledger', successorFixture((t) => { delete t.lifecycle_status; }, 'no-lifecycle.json'),
    '--repo', REPO, '--guard-cmd', 'true']);
  assert.equal(absent.status, REFUSED);
  assert.match(token(absent.out), /REFUSED reason=DEAD-SUCCESSOR/);
  assert.match(absent.out, /lifecycle_status=\(absent\)/);
  assert.doesNotMatch(absent.out, /undefined/);
});

test('R5: an in_progress successor still resolves — the fence refuses corpses, not work', () => {
  const { status, out } = run(['--ledger', DEAD('in_progress'), '--repo', REPO, '--guard-cmd', 'true']);
  assert.equal(status, SEAL, `in_progress is a LIVE successor: ${token(out)}`);
  assert.match(token(out), /SEAL-PREDICATE SEAL a=PASS/);
});

test('R5 MUTATION PROOF: with the lifecycle fence removed, the DONE successor resolves again', () => {
  const path = DEAD('done');
  const { status, out } = mutatedRun(DROP_R5, ['--ledger', path, '--repo', REPO, '--guard-cmd', 'true']);
  assert.equal(status, SEAL, `without R5 a corpse is accepted as the forwarding address: ${token(out)}`);
  assert.match(out, /successor: cch-fixture-successor-epic/, 'the pre-fix shape printed the corpse AS the address');
  assert.match(token(out), /SEAL-PREDICATE SEAL a=PASS/);
  // Both tokens, side by side.
  assert.match(token(run(['--ledger', path, '--repo', REPO, '--guard-cmd', 'true']).out),
    /REFUSED reason=DEAD-SUCCESSOR/);
});

test('R6: a successor that is a CHILD of the epic is REFUSED — R4 only caught the epic itself', () => {
  const { status, out } = run(['--ledger', INSIDE(EPIC), '--repo', REPO, '--guard-cmd', 'true']);
  assert.equal(status, REFUSED, 'a child of the epic is not OUT of the epic');
  assert.match(out, /VERDICT-TOKEN: SEAL-PREDICATE REFUSED reason=SUCCESSOR-INSIDE-EPIC/);
  assert.match(out, /after 1 hop\(s\): cch-fixture-successor-epic -> cloud-console-hardening-epic/);
  assert.doesNotMatch(out, /successor: cch-fixture-successor-epic/);
  assert.doesNotMatch(out, /VERDICT: SEAL$/m);
  // The distinction from R4 is the whole point: same defect, one hop down, own code.
  assert.doesNotMatch(token(out), /SELF-SUCCESSOR/);
});

test('R6: a GRANDCHILD of the epic is refused too, and the trail is printed hop by hop', () => {
  const fx = JSON.parse(readFileSync(FIX('sealable.json'), 'utf8'));
  fx.tasks['cch-fixture-successor-epic'].parent_id = 'cch-fixture-middle';
  fx.tasks['cch-fixture-middle'] = {
    _id: 'cch-fixture-middle', _type: 'task', status: 'published',
    lifecycle_status: 'open', parent_id: EPIC,
  };
  fx.requiredContexts = [AGG];
  const p = join(tmp('seal-pred-succ-'), 'grandchild.json');
  writeFileSync(p, JSON.stringify(fx));
  const { status, out } = run(['--ledger', p, '--repo', REPO, '--guard-cmd', 'true']);
  assert.equal(status, REFUSED);
  assert.match(token(out), /REFUSED reason=SUCCESSOR-INSIDE-EPIC/);
  assert.match(out, /after 2 hop\(s\): cch-fixture-successor-epic -> cch-fixture-middle -> cloud-console-hardening-epic/);
});

test('R6: a successor OUTSIDE the epic still resolves, and a parent cycle terminates', () => {
  // The committed happy path parents the successor at `cloud-console-goal` — outside.
  assert.equal(fixtureRun('sealable.json').status, SEAL);

  // A ledger cycle is a data fault, not a successor: the walk must stop rather than
  // spin, and it must not manufacture a refusal out of a chain that never hits the epic.
  const fx = JSON.parse(readFileSync(FIX('sealable.json'), 'utf8'));
  fx.tasks['cch-fixture-successor-epic'].parent_id = 'cch-fixture-loop';
  fx.tasks['cch-fixture-loop'] = {
    _id: 'cch-fixture-loop', _type: 'task', status: 'published',
    lifecycle_status: 'open', parent_id: 'cch-fixture-successor-epic',
  };
  fx.requiredContexts = [AGG];
  const p = join(tmp('seal-pred-succ-'), 'cycle.json');
  writeFileSync(p, JSON.stringify(fx));
  const { status } = run(['--ledger', p, '--repo', REPO, '--guard-cmd', 'true']);
  assert.equal(status, SEAL, 'a cycle that never reaches the epic is not an inside-epic refusal');
});

test('R6 MUTATION PROOF: with the ancestry fence removed, a child of the epic resolves again', () => {
  const path = INSIDE(EPIC);
  const { status, out } = mutatedRun(DROP_R6, ['--ledger', path, '--repo', REPO, '--guard-cmd', 'true']);
  assert.equal(status, SEAL, `without R6 a row inside the epic is accepted: ${token(out)}`);
  assert.match(out, /successor: cch-fixture-successor-epic/);
  assert.match(token(out), /SEAL-PREDICATE SEAL a=PASS/);
  assert.match(token(run(['--ledger', path, '--repo', REPO, '--guard-cmd', 'true']).out),
    /REFUSED reason=SUCCESSOR-INSIDE-EPIC/);
});

test('R5 and R6 are INDEPENDENT fences: dropping one leaves the other firing', () => {
  // gr-p5r5-successor-seal was BOTH a corpse and a child of the epic. One fence must
  // not be able to stand in for the other — a reader told "DEAD" learns nothing about
  // where the row sits, and vice versa.
  const both = successorFixture((t) => { t.lifecycle_status = 'done'; t.parent_id = EPIC; }, 'corpse-inside-epic.json');
  assert.match(token(run(['--ledger', both, '--repo', REPO, '--guard-cmd', 'true']).out),
    /REFUSED reason=DEAD-SUCCESSOR/, 'the lifecycle fence is read first');
  assert.match(token(mutatedRun(DROP_R5, ['--ledger', both, '--repo', REPO, '--guard-cmd', 'true']).out),
    /REFUSED reason=SUCCESSOR-INSIDE-EPIC/, 'with R5 gone, R6 catches the same row for its own reason');
  assert.equal(mutatedRun((src) => DROP_R6(DROP_R5(src)),
    ['--ledger', both, '--repo', REPO, '--guard-cmd', 'true']).status,
  SEAL, 'with BOTH gone, the live-ledger corpse is accepted — the pre-wave-12 shape');
});

test('the three successor-resolution refusals carry three DISTINCT reason codes', () => {
  // A single UNRESOLVABLE-SUCCESSOR for all of them would tell a reader that the id was
  // unknown when in fact it was known, published, and disqualified for a stated reason.
  const codes = new Set();
  for (const args of [
    ['--ledger', withRequired('sealable.json'), '--repo', REPO, '--guard-cmd', 'true', '--successor', 'task-DOES-NOT-EXIST-9999'],
    ['--ledger', DEAD('done'), '--repo', REPO, '--guard-cmd', 'true'],
    ['--ledger', INSIDE(EPIC), '--repo', REPO, '--guard-cmd', 'true'],
  ]) {
    const m = token(run(args).out).match(/reason=([A-Z-]+)/);
    assert.ok(m, 'every refusal names a reason in its token');
    codes.add(m[1]);
  }
  assert.deepEqual([...codes].sort(),
    ['DEAD-SUCCESSOR', 'SUCCESSOR-INSIDE-EPIC', 'UNRESOLVABLE-SUCCESSOR']);
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
  assert.equal(status, REFUSED);
  assert.match(out, /VERDICT-TOKEN: SEAL-PREDICATE REFUSED reason=TERMINAL-CLAIM-REFUTED/);
  assert.match(out, /gr-fixture-still-open-1/, 'the row that refutes the claim is NAMED');
  assert.match(out, /after the post-condition roster read/,
    'the refusal must say it was reached AFTER reading the roster, not before');
  assert.doesNotMatch(out, /VERDICT: SEAL$/m);
});

test('TERMINAL is REFUTED by one CONSIDERING row', () => {
  const { status, out } = fixtureRun('terminal-one-considering-row.json');
  assert.equal(status, REFUSED);
  assert.match(out, /VERDICT-TOKEN: SEAL-PREDICATE REFUSED reason=TERMINAL-CLAIM-REFUTED/);
  assert.match(out, /gr-fixture-considering-1/, 'the considering row is NAMED');
  assert.doesNotMatch(out, /VERDICT: SEAL$/m);
});

// ── `considering` IS COUNTED, NEVER SILENTLY EXEMPT ─────────────────────────
test('a considering row is residue: counted into clause (a) and disclosed by name', () => {
  const { status, out } = fixtureRun('considering-residue.json');
  assert.equal(status, NO_SEAL, 'unfinished work with no forwarding address must not seal');
  assert.match(out, /considering \(disclosed\)   : 1  \[gr-fixture-considering-1\]/);
  assert.match(token(out), /a=FAIL .*considering=1/);
});

// ── A ROW CANNOT BE BOTH DISCLOSED AND UNNAMED ──────────────────────────────
// Wave 28's re-derivation of clause (a) from a clean checkout (charter D334) found the
// SAME row on two lines whose labels contradict each other: `considering (disclosed) :
// 1 [<id>]`, and two lines under it `UNNAMED RESIDUE (orphans) : 1  ✗ <id>`. Live that
// day: 59 open rows minus the 3 hardcoded permanent human gates = 56 genuinely unnamed
// rows, and the token said `orphans=57` — the 57th being `cloud-console-operator-audit-
// log`, printed by name immediately above. The count, not just the label, was wrong.
//
// THIS TEST ASSERTS THE COUNT, NOT MERELY THE LINE — a fix that only re-worded the
// label would leave `orphans=` inflated and every reader of the token misled.
test('the disclosed considering row is counted ONCE, and never as UNNAMED residue', () => {
  const { status, out } = fixtureRun('considering-residue.json');
  const clauseA = out.split('BUCKET (c)')[0];

  // 1. THE COUNT. Zero rows are unnamed: the only residue row is named two lines up.
  assert.match(out, /UNNAMED RESIDUE \(orphans\) : 0/);
  assert.match(token(out), /\borphans=0 considering=1\b/, 'the token carries the corrected count');
  assert.doesNotMatch(clauseA, /✗ gr-fixture-considering-1/, 'a row printed by name is not UNNAMED');

  // 2. THE ARITHMETIC. The four buckets partition residue exactly — the sum the wave-28
  //    reader had to do by hand off the live ledger, printed by the instrument itself.
  assert.match(out, /── buckets partition residue: 0 \+ 0 \+ 1 \+ 0 = 1/);

  // 3. THE ROW IS NAMED EXACTLY ONCE inside clause (a). Two mentions is the defect.
  assert.equal(clauseA.split('gr-fixture-considering-1').length - 1, 1,
    `the considering row must appear exactly once in the clause (a) block:\n${clauseA}`);

  // 4. NOT AN EXEMPTION. Re-labelling must not lower the bar: the header's clause (a)
  //    is "zero children open/in_progress/CONSIDERING without … a named forwarding
  //    address", so this run still fails, still at a=FAIL, and says why by name.
  assert.equal(status, NO_SEAL, 'a disclosed considering row still has no forwarding address');
  assert.match(token(out), /\ba=FAIL\b/);
  assert.match(out, /1 considering row\(s\) are disclosed by name and STILL carry no forwarding address \(clause a\): gr-fixture-considering-1/);
});

// MUTATION PROOF, DIRECTION 1 — re-merge the buckets (this is main's byte-for-byte
// behaviour before the fix) and the printed orphan count MOVES, 0 -> 1, with the row
// carrying the ✗ it was disclosed by name two lines above.
test('MUTATION PROOF: re-merging the buckets puts the disclosed row back under UNNAMED', () => {
  const { status, out } = mutatedRun(
    (src) => src.replace(
      '    else if (PENDING_STATUSES.includes(c.lifecycle_status)) consideringResidue.push(c._id);\n', ''),
    ['--ledger', withRequired('considering-residue.json'), '--repo', REPO, '--guard-cmd', 'true'],
  );
  assert.equal(status, NO_SEAL, `the merged shape still reds, but for the wrong reason: ${token(out)}`);
  assert.match(token(out), /\borphans=1 considering=1\b/, 'the pre-fix count double-counts the disclosed row');
  assert.match(out, /✗ gr-fixture-considering-1/, 'and prints it as UNNAMED under its own disclosed name');
});

// MUTATION PROOF, DIRECTION 2 — the opposite failure, and the one a careless fix would
// have shipped: drop the new bucket out of clause (a)'s pass predicate and the SAME
// fixture SEALS over an unfinished row. The bucket is a re-labelling, never an exemption.
test('MUTATION PROOF: dropping the considering bucket from clause (a) seals an unfinished row', () => {
  const { status, out } = mutatedRun(
    (src) => src.replace(
      'const aPass = orphans.length === 0 && consideringResidue.length === 0;',
      'const aPass = orphans.length === 0;'),
    ['--ledger', withRequired('considering-residue.json'), '--repo', REPO, '--guard-cmd', 'true'],
  );
  assert.equal(status, SEAL, `the exempting shape seals: ${token(out)}`);
  assert.match(token(out), /SEAL a=PASS/);
});

// AND THE OTHER SIDE OF THE ORDERING: a considering row that HAS a forwarding address
// is what clause (a) asks for, so it seals — and its name is STILL printed, on the
// re-disclosure line, because D90's "printed by name" is unconditional and does not
// depend on which bucket the row happened to land in.
test('a FORWARDED considering row seals — and is still disclosed by name', () => {
  const { status, out } = fixtureRun('considering-forwarded.json');
  assert.equal(status, SEAL, `a considering row with a named forwarding address must not red: ${token(out)}`);
  assert.match(token(out), /SEAL a=PASS .*\borphans=0 considering=1\b/);
  assert.match(out, /forwarded under successor : 1/);
  assert.match(out, /considering \(disclosed\)   : 0/);
  assert.match(out, /\(\+1 considering row\(s\) counted on a line above.*gr-fixture-considering-1\)/,
    'no considering row is ever disclosed by count alone');
  assert.match(out, /── buckets partition residue: 1 \+ 0 \+ 0 \+ 0 = 1/);
});

test('MUTATION PROOF: with `considering` dropped from the residue set, the same fixture seals', () => {
  const { status, out } = mutatedRun(
    (src) => src.replace("const PENDING_STATUSES = ['considering'];", 'const PENDING_STATUSES = [];'),
    ['--ledger', withRequired('considering-residue.json'), '--repo', REPO, '--guard-cmd', 'true'],
  );
  assert.equal(status, SEAL, `the pre-fix filter seals over an unfinished row: ${token(out)}`);
  assert.match(token(out), /SEAL a=PASS/);
  // …and the row is disclosed NOWHERE in that green. That is the defect.
  assert.doesNotMatch(out.split('VERDICT: SEAL')[0], /gr-fixture-considering-1/);
});

// ── CLAUSE (b): THE MEASUREMENT LADDER ──────────────────────────────────────
// Run WITHOUT --guard-cmd, so the two committed guards actually execute.
//
// WAVE 8 REWROTE THIS TEST, AND SAYING WHY IS THE POINT. Through waves 7 and 8's
// Decide, CCH-D5 sat at rung 3 and clause (b) failed on it BY NAME, and this test
// asserted exactly that. Wave 8 paid the gap — `router_signin_rate_bucket_test.exs`
// measures the bucket separation through a real `Router.call/2` — so CCH-D5 is rung 2
// and clause (b) passes on its own merits for the first time. The four assertions that
// named rung 3 as "the reason for the red" INVERTED with the measurement; keeping them
// would have made a green suite that certified a stale sentence.
//
// The property under test did not change: rung 3 is still a LOUD, by-name failure. It
// is now proven by MUTATION (stripping CCH-D5's measurement back to `unmeasured:`)
// rather than by the register happening to contain a rung-3 entry — which is the
// stronger form, because it survives the register being paid off again.
test('clause (b): every registered defect is measured, and rung 3 would still red by name', () => {
  const { status, out } = run(['--ledger', withRequired('ladder-no-waiver.json'), '--repo', REPO]);
  assert.equal(status, SEAL, `no rung-3 entry remains, so clause (b) passes: ${token(out)}`);

  // rung 1 — measured HERE, and the guard's own output had to name the measurement.
  assert.match(out, /MEASURED HERE by cloud\/priv\/static\/__app\.test\.mjs/);
  assert.match(out, /which printed "cch-w1: seven fleet ticks after one boot cost 12 requests, not 40"/);
  assert.match(out, /MEASURED HERE by design\/emit-fence\.test\.mjs/);

  // rung 2 — passes, but says in the same breath that it did not run.
  //
  // WAVE 9 REWROTE THIS ASSERTION, and the rewrite is the whole point of the slice.
  // It used to read `… job \`test\` on cloud/**`, because the resolver's third leg was
  // `src.includes('cloud/**')` against the workflow's raw text — satisfiable by a
  // COMMENT, and in any case an answer to the wrong question. The sentence now names
  // the REQUIRED CONTEXT that goes red when that job goes red, because that is what
  // makes a measurement able to stop something.
  assert.match(out, /rung 2 — MEASURED-ELSEWHERE/);
  assert.match(out, /MEASURED-ELSEWHERE by cloud\/test\/barkpark_cloud\/web\/router_test\.exs, run by \.github\/workflows\/cloud\.yml job `test`, whose failure is enforced through the REQUIRED status check "Cloud gate"/);
  assert.doesNotMatch(out, /on cloud\/\*\*/, 'the path-glob sentence is gone, not reworded');
  assert.match(out, /THIS RUN DID NOT EXECUTE IT/);
  // A fixture-supplied required set says so, in the same breath.
  assert.match(out, /REQUIRED-CONTEXT SET SUPPLIED BY LEDGER FIXTURE/);

  // CCH-D5 specifically: at rung 2, named with the file that measures it, and no
  // longer anywhere in the failure list.
  assert.match(out, /◐ CCH-D5-rate-limiter-sees-every-user-as-one  \(rung 2 — MEASURED-ELSEWHERE\)/);
  assert.match(out, /MEASURED-ELSEWHERE by cloud\/test\/barkpark_cloud\/web\/router_signin_rate_bucket_test\.exs/);
  assert.doesNotMatch(out, /rung 3/, 'no register entry is unmeasured any more');
  assert.match(token(out), /b=PASS/);

  // MUTATION: put the gap back — CCH-D5 loses its measurement and regains the rung-3
  // `unmeasured:` sentence — and the identical run reds by name. Rung 3 is still loud.
  const regressed = mutatedRun(
    (src) => src.replace(
      /    measured_by: \['cloud\/test\/barkpark_cloud\/web\/router_signin_rate_bucket_test\.exs'\],\n    measured_in_ci: \{ workflow: '\.github\/workflows\/cloud\.yml', job: 'test' \},\n/,
      "    unmeasured: 'no test anywhere asserts that two clients behind the front door get SEPARATE rate buckets.',\n",
    ),
    ['--ledger', withRequired('ladder-no-waiver.json'), '--repo', REPO],
  );
  assert.equal(regressed.status, NO_SEAL, 'a rung-3 entry must make clause (b) fail');
  assert.match(regressed.out, /✗ CCH-D5-rate-limiter-sees-every-user-as-one  \(rung 3\)/);
  assert.match(regressed.out, /NO MEASUREMENT \(rung 3\): no test anywhere asserts that two clients/);
  assert.match(regressed.out, /unlanded, unverifiable or UNMEASURED \(clause b\): CCH-D5-rate-limiter-sees-every-user-as-one/);
  assert.match(token(regressed.out), /b=FAIL/);

  // AND the rung-2 claim is not satisfied by merely ASSERTING a file. CCH-D5 carries
  // exactly ONE measured_by path on purpose — the classifier raises only when EVERY
  // named path is missing, so a second path would let the entry survive the deletion of
  // the file that actually measures it. Rename that one path and the entry fails closed.
  const absent = mutatedRun(
    (src) => src.replace(
      "'cloud/test/barkpark_cloud/web/router_signin_rate_bucket_test.exs'],",
      "'cloud/test/barkpark_cloud/web/router_signin_rate_bucket_test_DELETED.exs'],",
    ),
    ['--ledger', withRequired('ladder-no-waiver.json'), '--repo', REPO],
  );
  assert.equal(absent.status, NO_SEAL, 'a measurement that is asserted but absent must not seal');
  assert.match(absent.out, /and NONE of them exist — the measurement is asserted, not present/);
  assert.match(absent.out, /✗ CCH-D5-rate-limiter-sees-every-user-as-one/);
  assert.match(token(absent.out), /b=FAIL/);
});

test('a rung-1 guard that exits 0 without naming its measurement does NOT count as measured', () => {
  const { status, out } = mutatedRun(
    (src) => src.replace(
      "guardExpect: 'cch-w1: seven fleet ticks after one boot cost 12 requests, not 40',",
      "guardExpect: 'a sentence this guard never prints',",
    ),
    ['--ledger', withRequired('ladder-no-waiver.json'), '--repo', REPO],
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
  const r = spawnSync('node', [PREDICATE, '--ledger', withRequired('ladder-no-waiver.json'), '--repo', REPO],
    { encoding: 'utf8', timeout: 120000, env: { ...process.env, NODE_TEST_CONTEXT: 'child-v8' } });
  const out = `${r.stdout}${r.stderr}`;
  assert.match(out, /MEASURED HERE by cloud\/priv\/static\/__app\.test\.mjs/,
    'an inherited NODE_TEST_CONTEXT must not change what the guard is read to have said');

  // MUTATION: put both leaks back, and the SAME passing guard is reported as unrun.
  //
  // THE CLAIM THIS MUTATION MAKES, NARROWED (charter wave 8). The mutant pins the
  // buffer at 64 KiB rather than deleting the options wholesale, because the deleting
  // form asserted something no code in this repo controls: that the guard's serialised
  // stream exceeds spawnSync's 1 MiB DEFAULT. That byte count is driven by the ABSOLUTE
  // PATH LENGTH of the checkout — measured at one commit: macOS deep path 1,173,861
  // (over, green), macOS short path 978,921 (under, red), linux CI 896,566 (under, red)
  // — so main failed here on four consecutive runs while a deep builder worktree passed.
  // What is proven now is the honest, path-independent half: the pre-fix code misreads
  // ANY overflow of the guard's stream as NEVER RAN, i.e. it makes a defect claim from a
  // read that failed. It is NOT proven that the real 16 MiB buffer is load-bearing for
  // this particular guard on any particular host — that depends on the checkout path.
  const leaky = mutatedRun(
    (src) => src
      .replace(/for \(const k of \['NODE_TEST_CONTEXT'[^\n]*\n/, '')
      .replace(', env: GUARD_ENV, maxBuffer: 16 * 1024 * 1024 });', ', maxBuffer: 64 * 1024 });'),
    ['--ledger', withRequired('ladder-no-waiver.json'), '--repo', REPO],
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
  const { status, out } = run(['--ledger', withRequired('sealable.json'), '--repo', REPO, '--guard-cmd', 'exit 2']);
  assert.equal(status, INFRA, 'a refusal to measure must not be reported as a verdict');
  assert.match(out, /INFRA FAULT at /);
  assert.match(out, /that is a REFUSAL to measure/);
  assert.match(out, /VERDICT-TOKEN: SEAL-PREDICATE INFRA-FAULT/);
  assert.doesNotMatch(out, /still measurable at origin\/main/,
    'exit 2 must never be laundered into a defect claim');
  assert.doesNotMatch(out, /VERDICT: NO SEAL/);
});

test('a guard exiting 1 IS a defect claim — exit 2 is not merely "any non-zero"', () => {
  const { status, out } = run(['--ledger', withRequired('sealable.json'), '--repo', REPO, '--guard-cmd', 'exit 1']);
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
  fx.requiredContexts = [AGG];
  const path = join(tmp('seal-pred-'), 'gate-vanished.json');
  writeFileSync(path, JSON.stringify(fx));
  const { status, out } = run(['--ledger', path, '--repo', REPO, '--guard-cmd', 'true']);
  assert.equal(status, NO_SEAL, 'a gate that silently vanished is NO SEAL, not a clean sheet');
  assert.match(out, /✗ cch-hg-compose-network-recreation/);
  assert.match(token(out), /c=FAIL/);
});

// ═══ WAVE 9 — RUNG 2 IS A THREE-LEG STRUCTURAL READ ═════════════════════════
//
// The pre-wave-9 resolver asked `src.includes('cloud/**')` of cloud.yml's raw text.
// Two facts about it, both measured:
//
//   * the four rung-2 register entries were 100% UNTESTED. Deleting BOTH of that
//     branch's problem-pushes left this suite 31/31 green.
//   * the check was satisfiable by a COMMENT. Delete the real `paths:` key, add
//     `# cloud/**` anywhere in the file, and clause (b) went back to PASS.
//
// Every leg below is therefore proven by MUTATION against a SYNTHETIC REPO: the
// legs read `.github/workflows/cloud.yml` and `.github/required-checks.json` from
// `--repo`, so pointing `--repo` at a tree carrying deliberately-broken copies of
// those two files drives each leg to both polarities. Nothing here writes inside
// the real repo.

// A minimal repo the rung-2 legs can read: the two structural files (copied from
// the real ones, optionally mutated) plus an empty stand-in for every measured_by
// path the register names. `--guard-cmd true` covers the rung-1 guards, and fixture
// mode covers ancestry, so those two files are the ONLY inputs the legs consume.
function synthRepo({ workflow, requiredChecks } = {}) {
  const root = tmp('seal-pred-synth-');
  const wfDir = join(root, '.github', 'workflows');
  mkdirSync(wfDir, { recursive: true });
  const wfSrc = readFileSync(CLOUD_WF, 'utf8');
  writeFileSync(join(wfDir, 'cloud.yml'), workflow ? workflow(wfSrc) : wfSrc);
  const rc = JSON.parse(readFileSync(REQUIRED_CHECKS, 'utf8'));
  // The real file does NOT list `Cloud gate` yet — that is the honest interim state
  // pinned by the live test at the bottom. The synthetic default DOES, so each leg
  // below varies exactly one thing away from a working configuration.
  rc.protection.required_status_checks.checks.push({ context: AGG, app_id: 15368 });
  writeFileSync(join(root, '.github', 'required-checks.json'),
    JSON.stringify(requiredChecks ? requiredChecks(rc) : rc, null, 2));
  for (const q of new Set(readFileSync(PREDICATE, 'utf8').match(/'cloud\/test\/[^']+'/g) || [])) {
    const rel = q.slice(1, -1);
    mkdirSync(join(root, dirname(rel)), { recursive: true });
    writeFileSync(join(root, rel), '');
  }
  return root;
}

const synthRun = (opts) =>
  run(['--ledger', FIX('ladder-no-waiver.json'), '--repo', synthRepo(opts), '--guard-cmd', 'true']);

// ── THE CONTROL. Every leg satisfied -> rung 2, and clause (b) passes. ───────
// Without this, each red below could be a broken rig rather than a working leg.
test('wave 9 CONTROL: workflow intact + aggregator registered -> rung 2, clause (b) passes', () => {
  const { status, out } = synthRun({});
  assert.equal(status, SEAL, `all three legs satisfied must reach a SEAL: ${token(out)}`);
  assert.match(out, /◐ CCH-D2-session-peer-ip-is-the-docker-bridge  \(rung 2 — MEASURED-ELSEWHERE\)/);
  assert.match(out, /whose failure is enforced through the REQUIRED status check "Cloud gate" on main/);
  assert.doesNotMatch(out, /REQUIRED-CONTEXT SET SUPPLIED BY LEDGER FIXTURE/,
    'this run read the FILE, not a fixture override — otherwise the legs below prove nothing');
  assert.match(token(out), /b=PASS/);
});

// ── LEG A — enforced:false is an INFRA FAULT, never a claim ─────────────────
// Until 2026-07-28 this repo had NO branch protection, and this epic's own charter
// asserted so as a standing fact. Under that condition every required context is
// decorative: "measured in CI" would certify a job nobody has to pass. The honest
// answer is not NO SEAL (that is a verdict about the product) — it is exit 2:
// nothing was measured, so nothing is claimed.
test('wave 9 LEG A: enforced:false REFUSES with an INFRA FAULT rather than claiming rung 2', () => {
  const { status, out } = synthRun({ requiredChecks: (rc) => ({ ...rc, enforced: false }) });
  assert.equal(status, INFRA, 'an unenforced boundary must not be reported through the verdict code');
  assert.match(out, /INFRA FAULT at /);
  assert.match(out, /says enforced=false — branch protection is NOT applied to main/);
  assert.match(out, /REFUSING to evaluate rung 2 rather than claiming it/);
  assert.match(out, /VERDICT-TOKEN: SEAL-PREDICATE INFRA-FAULT a=UNKNOWN b=UNKNOWN c=UNKNOWN/);
  assert.doesNotMatch(out, /VERDICT: SEAL$/m);
  assert.doesNotMatch(out, /MEASURED-ELSEWHERE/, 'nothing may be reported measured off an unenforced branch');
});

test('wave 9 LEG A: a missing required-checks.json is INFRA FAULT, not a silent rung 2', () => {
  const root = synthRepo({});
  rmSync(join(root, '.github', 'required-checks.json'));
  const { status, out } = run(['--ledger', FIX('ladder-no-waiver.json'), '--repo', root, '--guard-cmd', 'true']);
  assert.equal(status, INFRA);
  assert.match(out, /required-checks\.json does not exist/);
  assert.match(out, /Nothing is asserted about clause \(b\)/);
});

// ── LEG B — no always()-aggregator over the job -> rung 3, BY NAME ───────────
test('wave 9 LEG B: deleting the Cloud gate job drops all four entries to rung 3 by name', () => {
  const { status, out } = synthRun({ workflow: (src) => {
    const cut = src.replace(/\n {2}cloud-gate:\n[\s\S]*$/, '\n');
    assert.notEqual(cut, src, 'the cloud-gate job must actually be removed');
    assert.doesNotMatch(cut, /^ {2}cloud-gate:/m);
    return cut;
  } });
  assert.equal(status, NO_SEAL);
  assert.match(out, /NO job both `needs:` `test` and carries `if: always\(\)`/);
  assert.match(out, /This measurement cannot stop a merge: rung 3/);
  for (const id of ['CCH-D2-session-peer-ip-is-the-docker-bridge', 'CCH-D3-bearer-token-in-the-access-log',
    'CCH-D4-head-prober-gets-a-session-token', 'CCH-D5-rate-limiter-sees-every-user-as-one'])
    assert.match(out, new RegExp(`✗ ${id}  \\(rung 3\\)`), `${id} must drop to rung 3`);
  assert.match(token(out), /b=FAIL/);
});

// ── LEG B — a MATRIXED aggregator is refused, and refused by name ────────────
// This is why the aggregator had to be a NEW job and never a rename of `test`: a
// matrixed job's published check-run name is not its `name:`, so it can never be a
// required context (honest-gates D20). Silently accepting one would certify a name
// that branch protection can never match.
test('wave 9 LEG B: a matrixed aggregator cannot render a requirable context', () => {
  const { status, out } = synthRun({ workflow: (src) => {
    const mutated = src.replace(/^ {4}name: Cloud gate$/m,
      '    name: Cloud gate\n    strategy:\n      matrix:\n        otp: ["27.0"]');
    assert.notEqual(mutated, src, 'the matrix must actually be added');
    return mutated;
  } });
  assert.equal(status, NO_SEAL);
  assert.match(out, /carry a `strategy\.matrix`, so their published check-run name is not their `name:`/);
  assert.match(out, /A matrixed job cannot be a required context \(D20\)/);
  assert.match(token(out), /b=FAIL/);
});

// ── LEG C — the aggregator exists but nobody has to pass it -> rung 3 ────────
// THE DEFECT THIS SLICE REMOVES, stated as a test. An aggregator that exists,
// runs, and reds while the PR merges green is not a measurement; it is a display.
test('wave 9 LEG C: an UNREGISTERED aggregator is rung 3, named, with the fix named too', () => {
  // The survivor list is DERIVED from the spec this case builds, never quoted.
  // A literal "Elixir gate, PR references an active task" was correct until the
  // wave-11 flip added two contexts, and then it failed on the MERGED tree
  // while every per-slice gate stayed green — the exact shape this epic exists
  // to kill. Derive from the foreign surface; pin only what this case owns.
  let survivors = [];
  const { status, out } = synthRun({ requiredChecks: (rc) => {
    rc.protection.required_status_checks.checks =
      rc.protection.required_status_checks.checks.filter((c) => c.context !== AGG);
    survivors = rc.protection.required_status_checks.checks.map((c) => c.context);
    return rc;
  } });
  assert.ok(survivors.length > 0 && !survivors.includes(AGG),
    'the specimen must strip the aggregator and leave a non-empty required set, else the assertions below are vacuous');
  assert.equal(status, NO_SEAL, 'an unenforced aggregator must not be certified as a measurement');
  assert.match(out, /is aggregated by "Cloud gate", and "Cloud gate" is NOT a required status check on main/);
  assert.ok(out.includes(`required today: ${survivors.join(', ')}`),
    `the required set that DOES exist is printed, so the gap is readable — expected "required today: ${survivors.join(', ')}"`);
  assert.match(out, /The job can go red and the PR still merges/);
  assert.match(out, /cch-w9-register-console-and-cloud-gates/, 'the row that pays this is named');
  assert.match(out, /✗ CCH-D2-session-peer-ip-is-the-docker-bridge  \(rung 3\)/);
  assert.match(token(out), /b=FAIL/);
});

// ── THE COMMENT CAN SATISFY NOTHING ─────────────────────────────────────────
// The measured cheap escape: with the real `paths:` key deleted, a bare YAML
// comment containing `cloud/**` restored the pre-wave-9 check to PASS. Here the
// same comment is added to a workflow whose aggregator has been removed — if any
// leg were textual, this would go green.
test('wave 9: a YAML comment naming cloud/** satisfies NO leg', () => {
  const commented = synthRun({ workflow: (src) => {
    const cut = src.replace(/\n {2}cloud-gate:\n[\s\S]*$/, '\n');
    return `${cut}\n# paths: cloud/**\n# - "cloud/**"\n# name: Cloud gate\n# needs: [test]\n# if: always()\n`;
  } });
  assert.equal(commented.status, NO_SEAL, 'prose must never satisfy a structural read');
  assert.match(commented.out, /NO job both `needs:` `test` and carries `if: always\(\)`/);
  assert.match(token(commented.out), /b=FAIL/);

  // …and the SAME comment block on an INTACT workflow changes nothing either way:
  // the entries resolve on structure alone, so the comment is inert in both
  // directions rather than merely "not enough".
  const intact = synthRun({ workflow: (src) => `${src}\n# paths: cloud/**\n` });
  assert.equal(intact.status, SEAL, `an inert comment must not disturb a real resolution: ${token(intact.out)}`);
  assert.match(token(intact.out), /b=PASS/);
});

test('wave 9: the resolver never greps the workflow text for the registered path glob', () => {
  const raw = readFileSync(PREDICATE, 'utf8');
  // CODE only. The file's own header narrates the removed `src.includes(...)` call by
  // name — that prose is the record of why the legs exist and must not make this
  // assertion unsatisfiable. Stripping `//` lines is what makes the check about
  // behaviour rather than about vocabulary.
  const code = raw.split('\n').filter((l) => !/^\s*\/\//.test(l)).join('\n');
  assert.match(raw, /src\.includes\(/, 'sanity: the header still explains what was removed');
  assert.doesNotMatch(code, /src\.includes\(/,
    'no leg may be a substring test against the workflow source');
  assert.doesNotMatch(code, /measured_in_ci\.paths/,
    'the `paths` field is gone from the register, not merely unread');
  assert.doesNotMatch(code, /paths: 'cloud/,
    'no register entry may still carry a path glob for something to grep');
});

// ── BOTH `needs:` SPELLINGS ─────────────────────────────────────────────────
// cloud.yml writes the inline flow sequence, but a block sequence is equally legal
// YAML and a resolver that assumed one style would silently find no aggregator —
// i.e. red a correct configuration.
test('wave 9: the aggregator is found through EITHER YAML needs: spelling', () => {
  const asBlock = synthRun({ workflow: (src) => {
    const mutated = src.replace('    needs: [changes, compile, test, path-escape]',
      '    needs:\n      - changes\n      - compile\n      - test\n      - path-escape');
    assert.notEqual(mutated, src, 'the needs: rewrite must actually apply');
    return mutated;
  } });
  assert.equal(asBlock.status, SEAL, `a block-sequence needs: must resolve identically: ${token(asBlock.out)}`);
  assert.match(asBlock.out, /enforced through the REQUIRED status check "Cloud gate"/);
});

// ── TWO AGGREGATORS OVER THE SAME JOB — THE REGISTERED ONE WINS ─────────────
// Several always()-aggregators over one job is legal YAML. The question rung 2 asks
// is "can ANY required context go red when this job does", so resolving to whichever
// candidate the parser happened to see first would report rung 3 over a job that IS
// enforced — a false NO SEAL decided by job ORDER in a file. The decoy below is
// declared BEFORE `cloud-gate`, so a first-wins resolver reds this test.
test('wave 9 LEG C: with a decoy aggregator declared first, the REGISTERED name still resolves', () => {
  const { status, out } = synthRun({ workflow: (src) => {
    const decoy = [
      '  cloud-gate-decoy:',
      '    name: Cloud gate decoy',
      '    if: always()',
      '    needs: [changes, compile, test, path-escape]',
      '    runs-on: ubuntu-latest',
      '    steps:',
      '      - run: "true"',
      '',
    ].join('\n');
    const mutated = src.replace(/^ {2}cloud-gate:$/m, `${decoy}  cloud-gate:`);
    assert.notEqual(mutated, src, 'the decoy aggregator must actually be inserted');
    assert.ok(mutated.indexOf('cloud-gate-decoy:') < mutated.indexOf('\n  cloud-gate:'),
      'the decoy must come FIRST, else this proves nothing about ordering');
    return mutated;
  } });
  assert.equal(status, SEAL, `an enforced aggregator must resolve regardless of file order: ${token(out)}`);
  assert.match(out, /enforced through the REQUIRED status check "Cloud gate" on main/);
  assert.doesNotMatch(out, /"Cloud gate decoy"/, 'the unregistered decoy must not be reported as the enforcer');
  assert.match(token(out), /b=PASS/);
});

// …and when NEITHER candidate is registered, the failure names BOTH, so the reader
// is not sent to register a name that was chosen arbitrarily.
test('wave 9 LEG C: with two unregistered aggregators, the refusal names both', () => {
  const { status, out } = synthRun({
    workflow: (src) => src.replace(/^ {2}cloud-gate:$/m,
      '  cloud-gate-decoy:\n    name: Cloud gate decoy\n    if: always()\n    needs: [changes, compile, test, path-escape]\n    runs-on: ubuntu-latest\n    steps:\n      - run: "true"\n\n  cloud-gate:'),
    requiredChecks: (rc) => {
      rc.protection.required_status_checks.checks =
        rc.protection.required_status_checks.checks.filter((c) => c.context !== AGG);
      return rc;
    },
  });
  assert.equal(status, NO_SEAL);
  assert.match(out, /is aggregated by "Cloud gate decoy", "Cloud gate", and NONE of those names is a required status check on main/);
  assert.match(token(out), /b=FAIL/);
});

// ── THE LIVE STATE, PINNED HONESTLY ─────────────────────────────────────────
// No fixture override, no synthetic repo: the real cloud.yml and the real
// required-checks.json.
//
// REWRITTEN IN WAVE 11 REVIEW, and the rewrite is the point. This case used to
// hard-assert the PRE-flip answer ("Cloud gate is NOT required, therefore clause
// (b) FAILS") with a comment telling a future human to flip it by hand once
// registration landed. Registration landed in the same wave as this file's other
// change, on a DIFFERENT branch — so every per-slice gate was green and the
// MERGED tree failed. A case that must be hand-flipped on someone else's merge
// is a case that reds the integration nobody ran.
//
// So it now asserts the INVARIANT instead of one side of it: the predicate's
// clause-(b) reading must AGREE with the committed spec, whichever side of the
// flip the branch is on. Both arms carry real assertions, and the arm that runs
// is reported, so a reader can see which state the tree is in.
test('LIVE: the clause-(b) reading agrees with the committed spec, on either side of the flip', () => {
  const rc = JSON.parse(readFileSync(REQUIRED_CHECKS, 'utf8'));
  assert.equal(rc.enforced, true, 'branch protection IS live — that is what makes this readable at all');
  const registered = rc.protection.required_status_checks.checks.some((c) => c.context === AGG);
  const { status, out } = run(['--ledger', FIX('ladder-no-waiver.json'), '--repo', REPO, '--guard-cmd', 'true']);

  if (registered) {
    // POST-FLIP. `Cloud gate` carries the cloud.yml `test` job, so every entry
    // measured there climbs from rung 3 to rung 2 and clause (b) stops failing
    // for THIS reason. Nothing here claims a seal: clause (a) is fixtured.
    assert.doesNotMatch(out, /"Cloud gate" is NOT a required status check on main/,
      'Cloud gate is registered in the committed spec, so the predicate must stop reporting it as unregistered');
    assert.match(out, /CCH-D2-session-peer-ip-is-the-docker-bridge/);
    assert.doesNotMatch(token(out), /b=FAIL/,
      'with the aggregator required, clause (b) must no longer fail on the unenforced-measurement leg');
    assert.match(out, /rung 2 — MEASURED-ELSEWHERE/,
      'the registered aggregator must move the cloud.yml-measured entries to rung 2');
  } else {
    // PRE-FLIP. The honest interim answer, unchanged.
    assert.equal(status, NO_SEAL, 'the interim state is NO SEAL, and that is the honest answer');
    assert.match(out, /"Cloud gate" is NOT a required status check on main/);
    assert.match(token(out), /b=FAIL/);
  }
});

// ═══ WAVE 11 — `--ladder-only` READS THE LADDER AND CLAIMS NOTHING ═══════════
//
// Weight 3 of this epic ("where does the seal actually stand?") was unanswerable for
// four waves because the instrument CONFLATED reading the clause-(b) ladder with
// claiming a verdict: every legal live invocation refuses UPSTREAM of the ladder
// (`--successor TERMINAL` -> TERMINAL-CLAIM-REFUTED, `--successor <name>` ->
// UNRESOLVABLE-SUCCESSOR) and the catch prints a=b=c=UNEVALUATED. `--ladder-only`
// separates the two acts: it reads, and it claims nothing.
//
// These tests FAIL IF THE FLAG LIES, in the two ways it could:
//   1. by emitting a verdict anyway — then it is the seal under a new name, and the
//      first CI job to wire it in re-creates the conflation; and
//   2. by SWALLOWING an INFRA FAULT into a clean read — the regression that reads
//      like PROGRESS, because a Leg-A refusal degrading to "read fine" turns an
//      unenforced branch into a green ladder at exit 0.

const ladderOnlyRun = (extra = []) => run(['--ladder-only', '--repo', REPO, ...extra]);

test('wave 11: --ladder-only NEVER emits a verdict — no VERDICT: line, no SEAL/NO-SEAL token', () => {
  const { status, out } = ladderOnlyRun();
  assert.equal(status, SEAL, `a clean read exits 0 even with rung-3 entries present: ${token(out)}`);
  // Every shape a verdict takes in this file, all absent.
  assert.doesNotMatch(out, /^VERDICT:/m, 'a reading must print no VERDICT: line at all');
  assert.doesNotMatch(out, /SEAL-PREDICATE (SEAL|NO-SEAL|REFUSED|INFRA-FAULT)\b/,
    'the token must carry no verdict word — LADDER-ONLY is not a verdict');
  assert.doesNotMatch(out, /\bNO[- ]SEAL\b/, 'nothing in a reading may read as NO SEAL');
  assert.doesNotMatch(out, /REFUSED at /);
  // ...and it says, in its own letters, which clauses it never read.
  assert.match(token(out), /^VERDICT-TOKEN: SEAL-PREDICATE LADDER-ONLY b-rungs=rung1:\d+,rung2:\d+,rung3:\d+ /);
  assert.match(token(out), /a=NOT-READ c=NOT-READ/,
    'the token string itself is what makes a --ladder-only run unquotable as "the seal"');
  assert.match(out, /Clause \(a\) and bucket \(c\) were NOT READ/);
  assert.match(out, /D83 forbids MANUFACTURING A SUCCESSOR TO FORCE A VERDICT; it does not/);
  assert.match(out, /CLAUSE \(b\) known user-facing defects — 6 registered/);
});

test('wave 11: --ladder-only does NOT swallow an INFRA FAULT into a clean read', () => {
  // Leg A throws on `enforced !== true`. If --ladder-only caught that and printed a
  // ladder anyway, clause (b) would silently degrade from FAIL to UNEVALUATED behind
  // an exit 0. exit 2, or nothing.
  const root = synthRepo({ requiredChecks: (rc) => ({ ...rc, enforced: false }) });
  const { status, out } = run(['--ladder-only', '--repo', root, '--guard-cmd', 'true',
    '--ledger', FIX('ladder-no-waiver.json')]);
  assert.equal(status, INFRA, 'an unenforced boundary must not be laundered into a 0-exit reading');
  assert.match(out, /INFRA FAULT at /);
  assert.match(out, /says enforced=false — branch protection is NOT applied to main/);
  assert.doesNotMatch(out, /LADDER-ONLY/, 'no reading may be printed off a read that never happened');
  assert.doesNotMatch(out, /MEASURED-ELSEWHERE/);
});

// ── THE LIVE ROSTER, STUBBED IN SOURCE ──────────────────────────────────────
// Until wave 30 the control below was the ONE test in this whole file that reached
// the NETWORK: `run(['--repo', REPO, '--successor', 'TERMINAL'])` fetched the live
// roster of this epic from ${BP_SERVER:-https://guerrilla.barkpark.cloud}, and
// ANONYMOUSLY — `Authorization: Bearer undefined`, since BP_TOKEN is unset in CI. So
// the REQUIRED `Console gate` context, which aggregates this suite, was green only
// while a host this repo does not own was up AND served this epic's roster to an
// unauthenticated caller. With the network dead the suite read `pass 73 / fail 1` and
// the sole red was `not ok 56` saying `2 !== 1` — an exit-code mismatch naming
// neither guerrilla, nor the network, nor the ledger.
//
// AND IT WAS SELF-TERMINATING INDEPENDENT OF AVAILABILITY: this test passes only while
// the foreign roster still HOLDS residue. The day this epic seals, the TERMINAL claim
// stops being refuted, the run walks on to bucket (c)'s gate fetches and exits 2 — a
// red on a healthy network with a healthy predicate.
//
// `--ledger` IS NOT THE FIX. `mode=${fixture ? 'fixture' : 'live'}` rides only the
// LADDER-ONLY and SEAL/NO-SEAL tokens; the REFUSED token carries no `mode=` field at
// all, so a fixture-backed run here would be BYTE-INDISTINGUISHABLE from a live one
// while taking the other branch — and this test's entire stated point is a claim ABOUT
// the live path. The roster is therefore stubbed IN SOURCE with `fixture` still null,
// exactly as `emptyLiveRoster` above does. One open row plus one done row is the
// smallest population that refutes a TERMINAL claim on the live branch: the open row
// is the residue, the done row proves the refusal counted a population rather than a
// constant.
//
// HERMETIC HERE SCOPES TO THE NETWORK AND NOTHING WIDER. This run still reads real git
// history through `--repo REPO` (filed as cch-w28-followup-seal-suite-depth1-coupling).
const stubbedLiveRoster = (src) => {
  const from = 'const children = fixture ? fixture.children : fetchRoster(EPIC);';
  // ASSERTED PRESENT BEFORE IT IS REPLACED. `String.prototype.replace` on an anchor that
  // has drifted is a SILENT no-op, and `mutatedRun`'s own `assert.notEqual(out, src)`
  // only proves SOMETHING changed — which the day this line is reworded would leave the
  // test back on the network with nothing saying so.
  assert.ok(src.includes(from), `mutation anchor has drifted out of the predicate: ${from}`);
  return src.replace(from,
    'const children = fixture ? fixture.children : ['
    + '{ _id: "stub-open-row", lifecycle_status: "open", parent_id: EPIC }, '
    + '{ _id: "stub-done-row", lifecycle_status: "done", parent_id: EPIC }];');
};

test('wave 11: --ladder-only reaches the ladder the live refusals never can', () => {
  // The control. The SAME tree, minus the flag, refuses upstream of the ladder and
  // reports every clause UNEVALUATED. That contrast IS this slice. The roster is
  // stubbed in source (see above) so the refusal is driven on the LIVE branch without
  // a network call.
  const refused = mutatedRun(stubbedLiveRoster, ['--repo', REPO, '--successor', 'TERMINAL']);
  assert.equal(refused.status, REFUSED);
  assert.match(refused.out, /1 live row\(s\) \[stub-open-row\]/,
    'the refusal must have counted the STUBBED live roster — that is what proves the live branch ran');
  assert.match(token(refused.out),
    /REFUSED reason=TERMINAL-CLAIM-REFUTED a=UNEVALUATED b=UNEVALUATED c=UNEVALUATED/);
  assert.doesNotMatch(refused.out, /CLAUSE \(b\)/,
    'the refusal never reaches the ladder — that is the problem being solved');

  const read = ladderOnlyRun();
  assert.equal(read.status, SEAL);
  assert.match(token(read.out), /rung1:2/, 'both committed guards actually SPAWNED and named their measurement');
  assert.match(read.out, /MEASURED HERE by cloud\/priv\/static\/__app\.test\.mjs/);
  assert.match(read.out, /MEASURED HERE by design\/emit-fence\.test\.mjs/);
});

test('wave 11: --ladder-only names the drift the committed record cannot see', () => {
  // Rung 2 is a read of the COMMITTED record. A 4-context spec that merges while the
  // PUT never lands — or is reverted — still prints rung 2 with nothing enforcing it.
  // The reading discloses that itself rather than letting a reader infer live
  // protection from it.
  const { out } = ladderOnlyRun();
  assert.match(out, /COMMITTED RECORD ONLY/);
  assert.match(out, /This program makes no network call BY DESIGN/);
  assert.match(out, /required-checks-verify\.sh` is the only instrument that catches/);
});

test('wave 11: --ladder-only refuses to let anyone credit the Console gate for clause (b)', () => {
  // All four rung-2 entries name cloud.yml job `test`; NO register entry references
  // console-harness.yml. A Cloud-gate-only spec therefore reads IDENTICALLY to one
  // that also registers the Console gate — measured here, not asserted.
  const args = (root) => ['--ladder-only', '--repo', root, '--guard-cmd', 'true',
    '--ledger', FIX('ladder-no-waiver.json')];
  const cloudOnly = run(args(synthRepo({})));
  const bothGates = run(args(synthRepo({ requiredChecks: (rc) => {
    rc.protection.required_status_checks.checks.push({ context: 'Console harness gate', app_id: 15368 });
    return rc;
  } })));
  assert.equal(cloudOnly.status, SEAL);
  assert.equal(bothGates.status, SEAL);
  assert.match(token(cloudOnly.out), /b-rungs=rung1:2,rung2:4,rung3:0/);
  assert.match(token(bothGates.out), /b-rungs=rung1:2,rung2:4,rung3:0/,
    'registering the Console gate moves NOT ONE line of clause (b)');
  assert.match(cloudOnly.out, /Registering the Console gate moves no line above/);
});

test('wave 11: --ladder-only is still bound by R0 and R1 — no stub, no empty register', () => {
  // The four SUCCESSOR refusals are skipped by design: they protect a VERDICT, and a
  // reading claims none. The two that protect clause (b) ITSELF are not skipped — a
  // live --guard-cmd would read a stub as a measurement, and an empty register would
  // read zero defects as a clean ladder.
  const stub = run(['--ladder-only', '--repo', REPO, '--guard-cmd', 'true']);
  assert.equal(stub.status, REFUSED, 'R0 still refuses a live stub — a reading of a stub is not a reading');
  assert.match(token(stub.out), /REFUSED reason=GUARD-OVERRIDE-WITHOUT-FIXTURE/);

  const emptied = mutatedRun(
    (s) => s.replace(/^const KNOWN_DEFECTS = \[[\s\S]*?^\];$/m, 'const KNOWN_DEFECTS = [];'),
    ['--ladder-only', '--repo', REPO]);
  assert.equal(emptied.status, REFUSED, 'R1 still refuses an empty register on the reading path too');
  assert.match(token(emptied.out), /REFUSED reason=EMPTY-DEFECT-REGISTER/);
});

// ═══ WAVE 27 — A POPULATION IT COULD NOT READ IS NOT ONE IT READ AND FOUND CLEAN ═══
//
// Two defects, one discipline. Both were live on origin/main, both were measured before
// the fix, and both had already corrupted a wave's primary finding:
//
//   1. FALSE FINDINGS ON AN UNREADABLE ROOT. Five clause-(b) legs resolve under --repo
//      and each reports its own miss as a DEFECT sentence, so a root that is merely the
//      WRONG DIRECTORY produced six verbatim "commit … is not an ancestor of
//      origin/main" lines at exit 0.
//   2. FAIL-OPEN ON AN EMPTY ROSTER, which is worse in kind. Clause (a) had no
//      cardinality floor, so an epic id that resolved to NOTHING sealed at exit 0.
//
// Every case below drives the SAME run to both polarities by mutation, so none of them
// is green by construction: the fixed arm refuses, and the arm with the refusal removed
// reproduces the exact pre-fix output.

// A root shaped like a `git archive` extraction: the committed structural files are
// there and readable, and there is no `.git` anywhere. `synthRepo()` already builds
// exactly that, which is also why the twelve rung-2 leg cases above had to stay on the
// fixture path — they drive this same non-git shape on purpose.
const archiveShapedRoot = () => synthRepo({});

test('wave 27: an EMPTY --repo is INFRA FAULT with a named code, never an unmeasured defect', () => {
  const empty = tmp('seal-pred-norepo-');
  const { status, out } = run(['--ledger', FIX('sealable.json'), '--repo', empty]);
  assert.equal(status, INFRA, 'a wrong root must not be reported through the verdict code');
  assert.match(out, /INFRA FAULT at /);
  assert.match(out, /carries no .github\/workflows\/cloud\.yml, so it is not a checkout of this repository/);
  assert.match(token(out), /INFRA-FAULT a=UNKNOWN b=UNKNOWN c=UNKNOWN epic=\S+ code=UNREADABLE-REPO-ROOT/,
    'the code is APPENDED AFTER epic=, so the clause letters keep their existing run');
  assert.ok(token(out).includes(`repo=${empty}`), 'the token names the root it refused to read');
  // The whole point: not one defect-shaped ROW is rendered for a wrong-root condition.
  // Asserted against the ladder's own rendering, never against vocabulary — the refusal
  // deliberately QUOTES the three sentences it prevents, and banning the words would
  // force that explanation out of the one message that has to carry it.
  assert.doesNotMatch(out, /^ {2}[✗◐✓·] CCH-D/m, 'no register entry may be rendered at all');
  assert.doesNotMatch(out, /^CLAUSE \(b\)/m, 'the clause-(b) section is not reached, let alone reported');
  assert.doesNotMatch(out, /VERDICT: NO SEAL/, 'an infra fault is never a verdict');
});

test('wave 27: a git-archive root on the LIVE path refuses instead of inventing six findings', () => {
  const root = archiveShapedRoot();
  // `--ladder-only` is a LIVE path (no --ledger) and makes no network call, so this is
  // the honest hermetic reproduction of the run that corrupted two waves.
  const { status, out } = run(['--ladder-only', '--repo', root]);
  assert.equal(status, INFRA);
  assert.match(out, /is not the top level of a git work tree/);
  assert.match(token(out), /code=REPO-NOT-A-GIT-WORK-TREE/);
  // Counted over RENDERED ladder rows, not over vocabulary: the refusal quotes the
  // sentence it prevents, and that explanation must stay in the message.
  assert.equal(out.split('\n').filter((l) => / is not an ancestor of origin\/main$/.test(l)).length, 0,
    'an ancestry claim is about the PRODUCT and may not be derived from a fact about the DIRECTORY');
  assert.doesNotMatch(out, /^ {2}[✗◐✓·] CCH-D/m, 'no register entry may be rendered at all');
  assert.doesNotMatch(out, /LADDER-ONLY/, 'no reading may be printed off a read that never happened');

  // MUTATION CONTROL — remove ONLY the root git leg and the identical run reaches the
  // ladder over a directory with no `.git` at all.
  //
  // REWRITTEN IN WAVE 29, AND THE COUNT IS NOT RELAXED. Through wave 28 this control
  // asserted SIX verbatim `is not an ancestor of origin/main` lines, because that is
  // exactly what the undiscriminated ancestry leg printed for a directory git could not
  // read. Wave 29 taught the leg to tell rc 1 (an answer about the PRODUCT) from rc 128 /
  // missing ref / missing object / truncated walk (an answer about the ENVIRONMENT), so
  // the same run now answers rc 128 at the REF probe and prints six HISTORY-UNAVAILABLE
  // sentences instead. The assertion therefore moves to the NEW sentence AT THE SAME
  // CARDINALITY. Relaxing it to `>= 0`, dropping it, or deleting this test would silently
  // restore the defect the whole slice exists to remove: today NONE of the five
  // `ladderOnlyRun` assertions read `b-clean` or counted anything, which is why
  // origin/main scored 65/65 in a pristine depth-1 clone while printing six false
  // ancestry sentences. A selector that cannot reach the defect is green by construction
  // even with a cruel fixture.
  const unguarded = mutatedRun(
    (src) => src.replace('if (!top || realpathSync(top) !== realpathSync(REPO))', 'if (false)'),
    ['--ladder-only', '--repo', root]);
  assert.equal(unguarded.status, SEAL, 'the READ path exits 0 even with an unreadable history — charter D335');
  const invented = unguarded.out.split('\n').filter((l) => / is not an ancestor of origin\/main$/.test(l));
  assert.equal(invented.length, 0,
    `not one ancestry claim may be derived from a directory git cannot read, got ${invented.length}`);
  const unreadable = unguarded.out.split('\n').filter((l) => /^ {8}HISTORY-UNAVAILABLE: commit \S+ — /.test(l));
  assert.equal(unreadable.length, 6,
    `every registered defect must be reported UNREADABLE — not unlanded — when the DIRECTORY has no .git, got ${unreadable.length}`);
  for (const l of unreadable)
    assert.match(l, /MISSING-REF\b.*\[ref: origin\/main DOES NOT RESOLVE \(rev-parse --verify rc \d+\) \| object: ABSENT \(cat-file -e rc \d+\) \| walk: unknown \(.*\) \| ancestry: NOT RUN/,
      `each sentence names all four probes and which one answered: ${l}`);
  assert.match(token(unguarded.out), /LADDER-ONLY/);
  assert.match(token(unguarded.out), / b-clean=0\/6 b-unavailable=6\/6 /,
    'and the token carries the condition in LETTERS — the count is machine-readable, not buried in prose');
});

test('wave 27: the root guard reads a LINKED WORKTREE, where `.git` is a FILE, not a directory', () => {
  const dotGit = statSync(join(REPO, '.git'));
  const { status, out } = ladderOnlyRun();
  assert.equal(status, SEAL, `the live path must resolve a real checkout, worktree or not: ${token(out)}`);
  assert.match(token(out), /head=[0-9a-f]{7,}/, 'leg 2 resolved a HEAD, so the work-tree read succeeded');
  assert.doesNotMatch(out, /is not the top level of a git work tree/);

  // THE TRAP, PINNED IN CODE RATHER THAN IN A SENTENCE. The obvious root check is
  // `statSync('.git').isDirectory()`; in a LINKED WORKTREE `.git` is a ~75-byte FILE
  // pointing at the real gitdir, so that shape refuses every worktree — and this epic
  // runs nearly all of its proofs from worktrees, which would have made the fix the
  // next instrument manufacturing false findings. The guard must ask GIT, never the
  // filesystem, and this file may not contain the refuted shape.
  const code = readFileSync(PREDICATE, 'utf8').split('\n').filter((l) => !/^\s*\/\//.test(l)).join('\n');
  assert.doesNotMatch(code, /isDirectory\(\)/,
    'no root check may stat `.git` — `.git` is a FILE in every linked worktree');
  assert.match(code, /'rev-parse', '--show-toplevel'/,
    'the work-tree read goes through git itself, which is what makes a worktree readable');
  if (dotGit.isFile())
    assert.ok(dotGit.size > 0,
      `this run IS from a linked worktree (.git is a ${dotGit.size}-byte file) and the guard read it fine`);
});

// ── CLAUSE (a) FAILS OPEN OVER AN EMPTY ROSTER ──────────────────────────────
// The live shape, measured before the fix: `--epic cloud-console-hardening-epicc` (one
// doubled letter) exited 0 with `VERDICT: SEAL a=PASS b=PASS c=PASS orphans=0
// … mode=live`, no stub and no waiver, and printed "Sealed 0 children of
// cloud-console-hardening-epicc". Reproduced here WITHOUT the network by standing an
// empty array in for the live roster fetch — the same population that typo produced.
const emptyLiveRoster = (src) => {
  const out = src.replace('const children = fixture ? fixture.children : fetchRoster(EPIC);',
    'const children = fixture ? fixture.children : [];');
  assert.notEqual(out, src, 'the empty-live-roster mutation must actually apply');
  return out;
};

test('wave 27: a LIVE run over an EMPTY roster REFUSES instead of sealing over nobody', () => {
  const refused = mutatedRun(emptyLiveRoster, ['--repo', REPO, '--successor', 'TERMINAL']);
  assert.equal(refused.status, REFUSED, 'a roster of nobody must not exit 0');
  assert.match(token(refused.out), /REFUSED reason=EMPTY-ROSTER a=UNEVALUATED b=UNEVALUATED c=UNEVALUATED/);
  assert.match(refused.out, /the live roster of \S+ is EMPTY/);
  assert.match(refused.out, /orphans=0 is arithmetic, not evidence/);
  assert.match(refused.out, /after the roster read, before any clause was evaluated/,
    'the refusal must say it was reached AFTER reading the roster — it is a post-condition read, not a flag');
  assert.doesNotMatch(refused.out, /VERDICT: SEAL$/m);
  assert.doesNotMatch(refused.out, /Sealed 0 children of/, 'the fabrication sentence must be unreachable');

  // MUTATION CONTROL — remove ONLY the floor and the identical run seals over zero
  // children, prints its own fabrication, and reports a=PASS. (The gate fetch is stubbed
  // so the control stays hermetic; if any of the three mutations failed to apply the
  // assertions below red rather than passing vacuously.)
  // `String.prototype.replace` on an anchor that no longer exists is a SILENT no-op, and
  // `mutatedRun`'s own guard only proves that SOMETHING changed — the roster mutation
  // alone would satisfy it. Each anchor is therefore asserted present before it is used.
  const mustReplace = (src, from, to) => {
    assert.ok(src.includes(from), `mutation anchor has drifted out of the predicate: ${from}`);
    return src.replace(from, to);
  };
  const sealed = mutatedRun(
    (src) => mustReplace(
      mustReplace(emptyLiveRoster(src),
        'if (!fixture && children.length === 0)', 'if (false && children.length === 0)'),
      'const fetchById = (id) => {',
      'const fetchById = (id) => ({ _id: id, lifecycle_status: \'open\', parent_id: \'stub\' });\nconst _unused_real_fetchById = (id) => {'),
    ['--repo', REPO, '--successor', 'TERMINAL']);

  // THIS CONTROL ASSERTS CLAUSE (a) ONLY — NEVER THE OVERALL EXIT CODE. The exit code
  // is the CONJUNCTION of (a), (b) and (c), and clause (b) reads git three ways per
  // registered defect (`merge-base --is-ancestor`, `git show --name-only`, `git show`).
  // `console-harness.yml:239-248` says in its own words that a shallow checkout would
  // make the predicate "manufacture a false NO SEAL out of a shallow clone" and that
  // "the test file is hermetic instead" — so binding a clause-(a) control to the exit
  // code made it hostage to a clause it does not test, and it red in CI (`NO-SEAL
  // a=PASS b=FAIL c=PASS`) for an environment fact, not a defect. The floor this test
  // exists to pin is clause (a)'s, so the token's clause-(a) letters are what we read.
  // The fabrication sentences (`VERDICT: SEAL`, `Sealed 0 children of`) are pushed
  // INSIDE `if (ok)` at seal-predicate.mjs:1062-1066 — structurally unreachable in ANY
  // environment where clause (b) fails — so they moved to the fixture-mode sibling
  // below rather than being deleted.
  const sealedToken = token(sealed.out);
  assert.match(sealedToken, /\ba=PASS\b/,
    `removing the floor makes clause (a) pass over a roster of nobody: ${sealedToken}`);
  assert.match(sealedToken, /\borphans=0\b/, 'and the arithmetic reads clean over zero rows');
  assert.match(sealedToken, /\bmode=live\b/, 'this is the LIVE path, not a ledger fixture');
  assert.match(sealedToken, /\broster=0\b/, 'over a population of nobody');
  assert.doesNotMatch(sealedToken, /REFUSED reason=EMPTY-ROSTER/,
    'the floor mutation must actually remove the floor — otherwise this control passes vacuously');
  assert.doesNotMatch(sealed.out, /the live roster of \S+ is EMPTY/,
    'the refusal sentence must be gone with the floor it belongs to');

  // …and bucket (c) demonstrably cannot stop it: the three gates resolve for an epic
  // whose roster is empty, and the run says so in its own letters. Bucket (c) is pushed
  // at seal-predicate.mjs:1047-1049, BEFORE `ok` is computed at :1056, so this line is
  // printed on the NO-SEAL branch too and needs no git history to be reachable.
  assert.match(sealed.out, /in-epic-roster=false/,
    'the gates are fetched by hardcoded id INDEPENDENTLY of --epic, which is why clause (c) is no backstop');

  // AFTER-NOTE FOR cch-w28-s2 (clause-(b) HISTORY-UNAVAILABLE discrimination): when the
  // predicate learns to tell "this commit is not an ancestor" from "this checkout has no
  // history to ask", that condition MUST surface as a LETTER in the verdict token at
  // exit 1 (e.g. `b=HISTORY-UNAVAILABLE`) and NEVER as a process-level exit-2
  // INFRA-FAULT — an INFRA-FAULT prints `a=UNKNOWN b=UNKNOWN c=UNKNOWN` and would red
  // every clause-(a) assertion installed above.
});

// THE FABRICATION SENTENCES, RELOCATED — reachable WITHOUT git history.
// `Sealed 0 children of …` is the sentence the empty-roster floor exists to prevent, so
// it must stay pinned somewhere a depth-1 CI clone can reach. The floor is live-only
// (`if (!fixture && children.length === 0)`), so a ledger fixture with an EMPTY
// `children` array walks straight into it — and the fixture path stands `landed` in for
// ancestry, so clause (b) never touches git at all. The one thing this demonstration
// does NOT carry, relative to the live control above, is `mode=live`: it proves the
// sentence exists and what it says, not that a live run can print it. The live control
// above is what pins the live path.
test('wave 28: the fabrication sentence is reachable over an empty FIXTURE roster', () => {
  const { status, out } = fixtureRun('terminal-empty-roster.json');
  assert.equal(status, SEAL, `an empty fixture roster is not stopped by the live-only floor: ${token(out)}`);
  assert.match(out, /^VERDICT: SEAL$/m);
  assert.match(out, /Sealed 0 children of cloud-console-hardening-epic: 0 evidence-closed, 0 forwarded by name/,
    'this is the fabrication the empty-roster floor exists to prevent on the live path');
  // ANCHORED at the token's head. The predecessor of this assertion read
  // `/SEAL a=PASS .*orphans=0 .*mode=live/`, which matches the SUBSTRING inside
  // `NO-SEAL a=PASS` and therefore discriminated SEAL from NO-SEAL not at all.
  assert.match(token(out), /^VERDICT-TOKEN: SEAL-PREDICATE SEAL a=PASS b=PASS c=PASS orphans=0 /,
    'a NO-SEAL token can never satisfy this — the verdict word is pinned at a fixed offset');
  assert.match(token(out), /\broster=0\b.*\bmode=fixture\b|\bmode=fixture\b.*\broster=0\b/,
    'and the token names both the population it counted and the fact that it read a ledger fixture');
});

// ── EVERY VERDICT LINE NAMES ITS POPULATION ─────────────────────────────────
// `orphans=0` is a ratio with an unstated denominator: it reads identically over a
// 123-row roster with every row forwarded and over a roster of nobody. And this
// predicate is PROVEN checkout-sensitive — the same command printed b=FAIL from a stale
// primary checkout and b=PASS from a clean worktree — so a seal run that does not name
// its tree is unquotable.
test('wave 27: the verdict token names the roster it counted and the tree it read', () => {
  // The LIVE verdict path, reached hermetically through the control mutation above.
  const live = mutatedRun(
    (src) => emptyLiveRoster(src)
      .replace('if (!fixture && children.length === 0)', 'if (false && children.length === 0)')
      .replace('const fetchById = (id) => {',
        'const fetchById = (id) => ({ _id: id, lifecycle_status: \'open\', parent_id: \'stub\' });\nconst _unused_real_fetchById = (id) => {'),
    ['--repo', REPO, '--successor', 'TERMINAL']);
  assert.match(token(live.out), /roster=0 repo=\S+ head=[0-9a-f]{7,}/,
    'a live verdict states its population AND the tree it was taken from');

  // The FIXTURE path states the population too, and is honest that it read no tree:
  // `head=NOT-READ`, because the fixture path stands `landed` in for ancestry and
  // therefore never resolves a work tree at all.
  const { out } = fixtureRun('sealable.json');
  assert.match(token(out), /mode=fixture stubbed=2 waived=0 roster=3 repo=\S+ head=NOT-READ/);

  // A --ladder-only reading names its tree as well — it always did name `repo=`, and
  // now names the sha too, so two readings from two checkouts are distinguishable.
  assert.match(token(ladderOnlyRun().out), /mode=live repo=\S+ head=[0-9a-f]{7,}/);
});

// ═══ WAVE 29 — "I COULD NOT LOOK" IS NOT "THE THING IS BROKEN" ══════════════
//
// Wave 27 fixed that conflation at the ROOT — a `git archive` extraction is refused
// before any clause runs — and left it standing at the OBJECT. A pristine
// `git clone --depth 1 --branch main` of this repository is a REAL checkout of a REAL
// repository: `.github/workflows/cloud.yml` is there, `rev-parse --show-toplevel`
// answers, and `origin/main` RESOLVES. Only the HISTORY is absent. origin/main scored
// 65/65 in exactly that clone while printing six verbatim `is not an ancestor of
// origin/main` sentences, because not one of the five `ladderOnlyRun` assertions above
// read `b-clean` or counted a single line: A SELECTOR THAT CANNOT REACH THE DEFECT IS
// GREEN BY CONSTRUCTION EVEN WITH A CRUEL FIXTURE.
//
// Every case below drives REAL GIT — `git init` in a temp dir, never a stub — because
// the four probes ARE git's exit codes and a stub would pin this file's idea of them.
// Nothing here reaches the network and nothing writes inside the repo.

// A synthetic tree that is BOTH a readable repo root (the wave-27 leg) and a real git
// work tree, so the clause-(b) history probes are the only thing under test.
//   originMain:false  — the `pull_request` shape: only refs/remotes/pull/N/merge was ever
//                       fetched, so `rev-parse --verify --quiet origin/main` answers rc 1,
//                       the SAME code as an honest "no".
// Returns { root, base, side } — `base` IS an ancestor of origin/main, `side` is present
// and genuinely is NOT.
function synthGitRepo({ originMain = true } = {}) {
  const root = synthRepo({});
  const g = (...args) => {
    const r = spawnSync('git', ['-C', root, ...args], { encoding: 'utf8' });
    assert.equal(r.status, 0, `git ${args[0]} failed in the synthetic repo: ${r.stderr}`);
    return (r.stdout || '').trim();
  };
  g('init', '-q');
  g('symbolic-ref', 'HEAD', 'refs/heads/main');
  g('config', 'user.email', 'seal-predicate@test.invalid');
  g('config', 'user.name', 'seal predicate test');
  g('config', 'commit.gpgsign', 'false');
  // The two rung-1 guards, stood in for the same way `synthRepo` stands in for the
  // measured_by paths — and DERIVED from the register rather than quoted, so a renamed
  // guard or a reworded guardExpect cannot leave this rig silently asserting the wrong
  // thing. Without them both rung-1 entries carry a real `guard … is NOT COMMITTED`
  // PROBLEM, b reads FAIL, and a test about UNREADABLE HISTORY would be measuring an
  // absent file instead.
  const src = readFileSync(PREDICATE, 'utf8');
  for (const m of src.matchAll(/guard: '([^']+)',\n\s*guardExpect: '([^']+)'/g)) {
    mkdirSync(join(root, dirname(m[1])), { recursive: true });
    writeFileSync(join(root, m[1]), `console.log(${JSON.stringify(m[2])});\n`);
  }
  g('add', '-A');
  g('commit', '-qm', 'base');
  const base = g('rev-parse', 'HEAD');
  if (originMain) g('update-ref', 'refs/remotes/origin/main', base);
  // A commit that EXISTS in this store and is NOT reachable from origin/main. It is made
  // on a detached head so `main` (and therefore origin/main) never moves onto it.
  g('checkout', '-q', '--detach', base);
  writeFileSync(join(root, 'side.txt'), 'off main\n');
  g('add', '-A');
  g('commit', '-qm', 'side');
  const side = g('rev-parse', 'HEAD');
  g('checkout', '-q', 'main');
  return { root, base, side };
}

const REGISTERED_SHAS = ['481d6f231', '8fd00b6afb1eca55d3c991f7921ed6ec2b7d77b4',
  'd157d098c78bc6604d00d84e22d038bdb176ef58', '26acc7a91be0f0352efdb3e89b2017accb786367',
  '58862f621'];
// Retarget register entries onto shas that exist in a SYNTHETIC repo. Every anchor is
// asserted present first, because a rewrite that silently matched nothing is exactly how
// a mutation control passes vacuously.
const retarget = (src, map) => {
  let out = src;
  for (const [from, to] of map) {
    assert.ok(out.includes(`commit: '${from}'`), `register anchor has drifted: ${from}`);
    out = out.split(`commit: '${from}'`).join(`commit: '${to}'`);
  }
  return out;
};
const unavailableLines = (out) =>
  out.split('\n').filter((l) => /^ {8}HISTORY-UNAVAILABLE: commit \S+ — /.test(l));
const ancestryLines = (out) =>
  out.split('\n').filter((l) => / is not an ancestor of origin\/main$/.test(l));

test('wave 29 SELECTOR: a ladder-only reading is CHECKED for unreadable history, not just for rungs', () => {
  // THE CLAUSE-5 DEFENCE, and it is why origin/main scored 65/65 in a depth-1 clone.
  // This assertion reaches `b-unavailable` AND counts the sentences behind it, so the
  // token and the prose cannot disagree. It is written to hold in EITHER shape — 0/6 in
  // a checkout with whole history, 6/6 in a depth-1 CI clone — because pinning a value
  // would red the whole suite in exactly the environment `console-unit` runs in.
  const { status, out } = ladderOnlyRun();
  assert.equal(status, SEAL, `the READ path exits 0 in every environment (charter D335): ${token(out)}`);
  const m = token(out).match(/ b-clean=(\d+)\/(\d+) b-unavailable=(\d+)\/(\d+) a=NOT-READ/);
  assert.ok(m, `the token must carry b-unavailable immediately after b-clean: ${token(out)}`);
  const [, clean, total, unread, total2] = m.map(Number);
  assert.equal(total2, total, 'both b-fields count the same register');
  assert.equal(total, 6, 'over the six registered defects');
  assert.equal(unavailableLines(out).length, unread,
    'the counted per-entry sentences must EQUAL the number in the token — prose and letters cannot disagree');
  assert.ok(clean + unread <= total, 'an entry read as unavailable is never also counted clean');
  // …and an unreadable entry is never rendered as an ancestry claim about the product.
  if (unread > 0) assert.equal(ancestryLines(out).length, 0);
});

test('wave 29 PROBE 2 (MISSING-OBJECT): a real git repo without the history says so, and exits 0 on the READ path', () => {
  // The `actions/checkout@v4` PUSH shape, reproduced with real git: origin/main RESOLVES
  // (wave 27's corollary was half wrong about this — only the OBJECTS are missing) and
  // every registered sha is absent from the store.
  const { root } = synthGitRepo({});
  const { status, out } = run(['--ladder-only', '--repo', root]);
  assert.equal(status, SEAL, `exit-1-on-read is REFUSED (charter D335): ${token(out)}`);
  assert.equal(ancestryLines(out).length, 0,
    'not one ancestry claim may be derived from a store that does not hold the commit');
  assert.equal(unavailableLines(out).length, 6);
  for (const l of unavailableLines(out))
    assert.match(l, /MISSING-OBJECT\b.*\[ref: origin\/main resolves to [0-9a-f]{7,} \| object: ABSENT \(cat-file -e rc \d+\)/,
      `the sentence names the ref as RESOLVING and the object as absent — the two are different probes: ${l}`);
  assert.match(token(out), / b-clean=0\/6 b-unavailable=6\/6 /);
  // Asserted on the TOKEN, never on vocabulary: the reading's own prose explains that its
  // only non-zero exit is an INFRA FAULT, and banning the words would force that
  // explanation out of the one place that has to carry it.
  assert.doesNotMatch(token(out), /INFRA-FAULT/, 'a per-defect condition is never a process-level fault');
});

test('wave 29 PROBE 1 (MISSING-REF): the pull_request shape has no origin/main, and rc 1 there is not an answer', () => {
  // `rev-parse --verify --quiet origin/main` answers rc 1 — the SAME code an honest "no"
  // uses everywhere else in git. Keying on the code alone is how this leg stayed broken.
  const { root } = synthGitRepo({ originMain: false });
  const { status, out } = run(['--ladder-only', '--repo', root]);
  assert.equal(status, SEAL);
  assert.equal(ancestryLines(out).length, 0);
  assert.equal(unavailableLines(out).length, 6);
  for (const l of unavailableLines(out))
    assert.match(l, /MISSING-REF\b.*\[ref: origin\/main DOES NOT RESOLVE \(rev-parse --verify rc \d+\)/, l);
  assert.match(token(out), / b-unavailable=6\/6 /);
});

test('wave 29 ANTI-VACUITY: a sha that is PRESENT and genuinely NOT an ancestor still gets ONE honest sentence', () => {
  // THE FIX MUST NOT SWALLOW THE TRUE ANSWER. Five entries are retargeted onto a commit
  // that IS an ancestor of origin/main and one onto a commit that is present and is NOT.
  // All four probes are clean for that one, so its rc 1 is a claim about the PRODUCT —
  // and it must still be made, exactly once, with zero HISTORY-UNAVAILABLE lines anywhere.
  const { root, base, side } = synthGitRepo({});
  const map = REGISTERED_SHAS.map((s) => [s, s === '58862f621' ? side : base]);
  const { status, out } = mutatedRun((src) => retarget(src, map), ['--ladder-only', '--repo', root]);
  assert.equal(status, SEAL, `the READ path still exits 0: ${token(out)}`);
  assert.equal(unavailableLines(out).length, 0,
    'a store that HOLDS the commit and CAN walk to origin/main has nothing unavailable about it');
  assert.equal(ancestryLines(out).length, 1,
    'exactly one honest product sentence, for the one entry whose commit really is off main');
  assert.match(out, new RegExp(`commit ${side} is not an ancestor of origin/main`));
  assert.match(token(out), / b-unavailable=0\/6 /);
});

test('wave 29 THE VERDICT PATH: HISTORY-UNAVAILABLE is a LETTER at exit 1, never an exit-2 INFRA-FAULT', () => {
  // CHARTER D335, and cch-w28-s1's clause-(a) tripwire is armed on it: an INFRA-FAULT
  // prints `a=UNKNOWN b=UNKNOWN c=UNKNOWN` at rc 2 and throws away two clause readings
  // that were perfectly available. The degrade is PER-DEFECT: b carries its own letter,
  // (a) and (c) are still evaluated and still printed, and the exit code is 1.
  const { root } = synthGitRepo({});
  const must = (s, from, to) => { assert.ok(s.includes(from), `anchor drifted: ${from}`); return s.replace(from, to); };
  const mut = (src) => must(
    must(src, 'const children = fixture ? fixture.children : fetchRoster(EPIC);',
      'const children = fixture ? fixture.children : [{ _id: "x", lifecycle_status: "done" }];'),
    'const fetchById = (id) => {',
    'const fetchById = (id) => ({ _id: id, lifecycle_status: \'open\', parent_id: \'stub\' });\nconst _unused_real_fetchById = (id) => {');
  const { status, out } = mutatedRun(mut, ['--repo', root, '--successor', 'TERMINAL']);
  assert.equal(status, NO_SEAL, `a per-defect unreadable history costs exit 1, not exit 2: ${token(out)}`);
  assert.match(token(out), /SEAL-PREDICATE NO-SEAL a=PASS b=HISTORY-UNAVAILABLE c=PASS /,
    'b carries its OWN letter while (a) and (c) carry REAL letters — the degrade is per-defect');
  assert.doesNotMatch(token(out), /INFRA-FAULT/);
  assert.doesNotMatch(token(out), /a=UNKNOWN/, 'exactly the shape cch-w28-s1 is armed to red');
  assert.match(token(out), / b-unavailable=6\/6$/,
    'the count is appended AFTER head=, so the clause letters keep their existing run');
  assert.match(out, /could NOT BE READ from this checkout \(clause b, HISTORY-UNAVAILABLE\)/);
  assert.match(out, /THIS IS NOT A DEFECT CLAIM/);
  assert.match(out, /git fetch --unshallow/, 'and the reader is told how to get an answer');
  assert.match(out, /^BUCKET \(c\) permanent human gates$/m, 'bucket (c) was still evaluated and printed');
});

test('wave 29: a checkout with WHOLE history is BYTE-IDENTICAL to the undiscriminated run', () => {
  // The discrimination must cost NOTHING where there is nothing to discriminate. Both
  // arms run the same live verdict path over the same tree; the only difference is the
  // ancestry leg. `b-unavailable=` is appended ONLY when non-zero for exactly this
  // reason — a new field on every green would make every previously-quoted token
  // unmatchable for a condition that did not occur.
  const roster = (src) => src.replace('const children = fixture ? fixture.children : fetchRoster(EPIC);',
    'const children = fixture ? fixture.children : [{ _id: "x", lifecycle_status: "done" }];');
  const stubGate = (src) => src.replace('const fetchById = (id) => {',
    'const fetchById = (id) => ({ _id: id, lifecycle_status: \'open\', parent_id: \'stub\' });\nconst _unused_real_fetchById = (id) => {');
  const now = mutatedRun((s) => stubGate(roster(s)), ['--repo', REPO, '--successor', 'TERMINAL']);
  // The undiscriminated ancestry leg, restored verbatim on top of everything else.
  const before = mutatedRun((s) => {
    const patched = stubGate(roster(s));
    const restored = patched.replace(
      /  const probe = historyProbe\(commit\);\n[\s\S]*?if \(probe\.verdict === 'not-ancestor'\)[^\n]*\n/,
      "  try { execFileSync('git', ['-C', REPO, 'merge-base', '--is-ancestor', commit, 'origin/main'], { stdio: 'ignore' }); }\n"
      + "  catch { problems.push(`commit ${commit} is not an ancestor of origin/main`); return null; }\n");
    assert.notEqual(restored, patched, 'the un-discrimination must actually apply');
    return restored;
  }, ['--repo', REPO, '--successor', 'TERMINAL']);
  // In a checkout WITHOUT whole history the two arms are honest in different ways and the
  // comparison is meaningless — skip rather than pin CI to a shape it does not have.
  if (/b-unavailable=/.test(token(now.out))) return;
  assert.equal(now.status, before.status, 'same exit code');
  assert.equal(token(now.out), token(before.out),
    'over a whole history the discrimination changes not one byte of the verdict token');
  assert.match(token(now.out), /\bb=PASS\b/);
});

// ── THE THREE CLAUSE-(a)/(c) DEFECTS IN THE SAME FILE, WITHIN ~15 LINES ─────
// Same disease as the ancestry leg: a population this program could not read, reported as
// one it read and found clean.

// A canned PAGING ledger, so these stay hermetic. `q` is the single HTTP site, so
// standing pages in for it drives the whole roster walk. The real `q` body is left intact
// behind a dead name rather than deleted: a mutation that has to delete a whole function
// body is a mutation that drifts the day the body changes shape.
//
// It behaves like the endpoint MEASURED on 2026-08-09 (wave 64): `offset` moves the
// window, `count=true` adds `result.total`, `order=_createdAt:asc` is honoured. Every one
// of those is a switch, so a test can make the server misbehave in exactly ONE way at a
// time and watch which arm fires. `rows: Infinity` is a ledger that never runs out —
// the shape a walk must be able to give up on rather than loop over forever.
//
// `fetchById` reaches the same `q`, so the stub answers `filter[_id]` on its OWN branch
// rather than letting a by-id lookup fall through the roster generator and come back with
// `row-0` — a stub that answers a question it was not asked is the very defect these
// tests exist to pin. `byId` picks HOW it answers, and the default is `absent` (no such
// row), which is what the roster arms below want: these tests run `--successor TERMINAL`
// (which consults no successor) and read clause (a)'s OWN letters, never the exit code,
// exactly as the wave-29 control did.
//   absent      the id is not in the ledger — a real answer, and `null`
//   honest      one row, and it IS the row asked for
//   wrong-row   ONE row, and it is a stranger — the shape only the identity arm can catch
//   unfiltered  a FULL page of strangers, `total` the whole task table — a dropped
//               `filter[]` wrapper, measured live on 2026-08-22
const cannedLedger = (o) => 'function q(params) {\n'
  + '  const p = new Map(params);\n'
  + '  const BY_ID = ' + JSON.stringify(o.byId || 'absent') + ';\n'
  + '  if (p.has("filter[_id]")) {\n'
  + '    const want = p.get("filter[_id]"), n = Number(p.get("limit") || 0);\n'
  + '    const row = (i) => ({ _id: i, _type: "task", status: "published", lifecycle_status: "open", parent_id: null, _createdAt: "2026-01-01T00:00:00.000000000Z" });\n'
  + '    if (BY_ID === "honest") return { result: { documents: [row(want)], count: 1, offset: 0, limit: n, total: 1 } };\n'
  + '    if (BY_ID === "wrong-row") return { result: { documents: [row("cch-w39-s4-a-stranger")], count: 1, offset: 0, limit: n, total: 1 } };\n'
  + '    if (BY_ID === "unfiltered") {\n'
  + '      const d = []; for (let i = 0; i < Math.max(n, 1); i += 1) d.push(row("cch-w39-s4-a-stranger-" + i));\n'
  + '      return { result: { documents: d, count: d.length, offset: 0, limit: n, total: 6994 } };\n'
  + '    }\n'
  + '    return { result: { documents: [], count: 0, offset: 0, limit: n, total: 0 } };\n'
  + '  }\n'
  + '  const ROWS = ' + (o.rows === Infinity ? 'Infinity' : String(o.rows))
  + ', TOTAL = ' + (o.total === undefined || o.total === null ? 'null' : String(o.total))
  + ', DESC = ' + Boolean(o.descending)
  + ', OFFSET_HONOURED = ' + (o.offsetHonoured !== false) + ';\n'
  + '  const off = OFFSET_HONOURED ? Number(p.get("offset") || 0) : 0;\n'
  + '  const lim = Number(p.get("limit") || 0);\n'
  + '  const stamp = (i) => "2026-01-01T00:00:00." + String(DESC ? 999999999 - i : i).padStart(9, "0") + "Z";\n'
  + '  const docs = [];\n'
  + '  for (let i = off; i < Math.min(off + lim, ROWS); i += 1)\n'
  + '    docs.push({ _id: "row-" + i, _createdAt: stamp(i), lifecycle_status: "done", parent_id: "cloud-console-hardening-epic" });\n'
  + '  const result = { documents: docs, count: docs.length, offset: off, limit: lim };\n'
  + '  if (TOTAL !== null) result.total = TOTAL;\n'
  + '  return { result };\n'
  + '}\n'
  + 'function _unused_real_q(params) {';

// THE CROSS-CHECK READ, CANNED — and canning it is not optional. `fetchRoster` now asks a
// SECOND endpoint (`/v1/tasks/:id`) for the ledger's own `child_count`, because
// `/v1/data/query` answers published-only and a draft child is unreachable through it.
// This file is HERMETIC by contract (see the header: a sentinel `curl` shim proved at
// wave 6 that no test reaches the network), so a stub for `q` alone would have let the
// new read escape to the live ledger — which is exactly what it did the first time this
// was written, reddening 8 tests that had nothing to do with drafts.
//
// The default `child_count` is the canned roster's OWN size, so every pre-existing test
// describes a parent with NO draft children and the new refusal stays silent in all of
// them. `childCount:` overrides it to open a gap on purpose.
const cannedTasks = (o) => {
  const rows = o.rows === Infinity ? 0 : Number(o.rows || 0);
  const served = o.total === undefined || o.total === null ? rows : Number(o.total);
  const n = o.childCount === undefined ? served : Number(o.childCount);
  return 'function qTasks(id) {\n'
    + '  return { doc: { child_count: ' + n + ' } };\n'
    + '}\n'
    + 'function _unused_real_qTasks(id) {';
};
const must = (s, from, to) => { assert.ok(s.includes(from), `anchor drifted: ${from}`); return s.replace(from, to); };
const chain = (...fns) => (s) => fns.reduce((acc, f) => f(acc), s);
const withLedger = (o) => (s) => must(
  must(s, 'function q(params) {', cannedLedger(o)),
  'function qTasks(id) {', cannedTasks(o));
const withPageLimit = (n) => (s) => must(s, 'const ROSTER_PAGE_LIMIT = 500;', `const ROSTER_PAGE_LIMIT = ${n};`);
const withMaxPages = (n) => (s) => must(s, 'const ROSTER_MAX_PAGES = 40;', `const ROSTER_MAX_PAGES = ${n};`);
// READ ON THE CLAUSE-(a) LETTERS, NEVER ON THE EXIT CODE, in every control below. The
// exit code is the CONJUNCTION of (a), (b) and (c), and clause (b) reads git per
// registered defect — so in a depth-1 checkout a control bound to `status === SEAL` reds
// with `b=HISTORY-UNAVAILABLE` for an ENVIRONMENT fact while passing on a full clone, and
// `console-unit` runs at depth-1 on every push to main. (`VERDICT: SEAL` lives inside
// `if (ok)` and is structurally unreachable wherever clause (b) is not clean, so it
// cannot be asserted here either.) The floor these tests pin is clause (a)'s.
const rosterRun = (mutate) => mutatedRun(mutate, ['--repo', REPO, '--successor', 'TERMINAL']);

test('wave 64 THE INSTRUMENT READS ITS OWN EPIC: the roster PAGINATES past the page limit', () => {
  // THE DEFECT THIS REPLACES. Waves 29–63 read ONE page and refused whenever it came back
  // full — correct, and by wave 64 no longer a read: this epic passed 500 children around
  // wave 40 and carries 850 today, so the predicate answered `INFRA-FAULT a=UNKNOWN
  // b=UNKNOWN c=UNKNOWN code=ROSTER-TRUNCATED` about the one epic it exists to certify,
  // and every Law-0 figure came from a raw `curl limit=1000` with no truncation guard of
  // its own. Seven rows over a page limit of three is the same crossing in miniature:
  // three pages (3 + 3 + 1), terminating on the SHORT page.
  const paged = rosterRun(chain(withLedger({ rows: 7, total: 7 }), withPageLimit(3)));
  assert.notEqual(paged.status, INFRA, `a roster it CAN page is not an infra fault: ${token(paged.out)}`);
  assert.doesNotMatch(token(paged.out), /code=ROSTER-/, 'no roster refusal may fire on a walk that completed');
  assert.match(token(paged.out), /\broster=7\b/, 'the POPULATION, not the page size');
  assert.doesNotMatch(token(paged.out), /\broster=3\b/, 'the pre-fix answer was the first page and nothing else');
  assert.match(token(paged.out), /\ba=PASS\b/, 'clause (a) is evaluated over the whole roster');

  // AND THE OLD ARM IS NOT MERELY DISARMED — it is re-aimed. A page that comes back FULL
  // is now the NORMAL case, so the sentence the old refusal printed must be gone from a
  // healthy walk rather than merely unreached.
  assert.doesNotMatch(paged.out, /came back FULL/);
});

test('wave 64 THE REFUSAL SURVIVES (ceiling): a walk that cannot finish REFUSES, and the refusal can lose', () => {
  // A ledger that never runs out. The walk must give up and SAY SO, never loop and never
  // count what it managed to read as if it were the population.
  const endless = chain(withLedger({ rows: Infinity }), withPageLimit(3), withMaxPages(4));

  const refused = rosterRun(endless);
  assert.equal(refused.status, INFRA, 'a roster this program could not read whole is an infra fault, never a verdict');
  assert.match(token(refused.out), /INFRA-FAULT a=UNKNOWN b=UNKNOWN c=UNKNOWN epic=\S+ code=ROSTER-TRUNCATED/);
  assert.match(refused.out, /could not be paginated to the end — 4 pages of 3 were read \(12 rows\)/);
  assert.doesNotMatch(refused.out, /VERDICT: SEAL/);

  // THE CONTROL — MUTATION-PROOF THAT THE REFUSAL IS LOAD-BEARING. Soften the ceiling
  // from a refusal into a `break` (the "just warn and carry on" shape) and the identical
  // run reports clause (a) CLEAN over the 12 rows it happened to reach, out of a ledger
  // with no end. That is the false seal the arm exists to prevent, and it is what a
  // pagination fix that could no longer refuse would have shipped.
  const softened = rosterRun((s) => must(endless(s),
    'if (page > ROSTER_MAX_PAGES)', 'if (page > ROSTER_MAX_PAGES) break;\n    if (false)'));
  assert.notEqual(softened.status, INFRA, 'softened, the walk stops refusing');
  assert.doesNotMatch(token(softened.out), /code=ROSTER-TRUNCATED/,
    'the mutation must actually remove the refusal — otherwise this control passes vacuously');
  assert.match(token(softened.out), /\ba=PASS\b/, 'and clause (a) reads clean over a population it never finished reading');
  assert.match(token(softened.out), /\broster=12\b/, '12 rows of an endless ledger, printed as the population');
});

test('wave 64 THE REFUSAL SURVIVES (window): an `offset` the server IGNORES is a refusal, not a loop', () => {
  // The second shape of "pagination cannot terminate", and the one an endpoint can cause
  // without erroring: `offset` accepted and dropped. Every page comes back full and
  // IDENTICAL, so a walk that trusted its own parameter would read page one forever.
  // No `total` is served here — this arm must fire on the pages alone.
  const stuck = chain(withLedger({ rows: Infinity, offsetHonoured: false }), withPageLimit(3));

  const refused = rosterRun(stuck);
  assert.equal(refused.status, INFRA);
  assert.match(token(refused.out), /INFRA-FAULT a=UNKNOWN b=UNKNOWN c=UNKNOWN epic=\S+ code=ROSTER-TRUNCATED/);
  assert.match(refused.out, /STOPPED ADVANCING at offset 3/);
  assert.match(refused.out, /first id \(row-0\) is the first id of the page before it/);

  // THE CONTROL — remove the non-advancing arm (and the order arm behind it, which sees
  // the same repeated page as a sequence going backwards) and the CEILING still catches
  // it, at page six instead of page two. Three independent refusals stacked over one
  // fault is what stops this from being one guard wearing three hats.
  const noWindow = chain(stuck, withMaxPages(6),
    (s) => must(s, 'if (docs.length >= ROSTER_PAGE_LIMIT && firstId !== null && firstId === prevFirstId)', 'if (false)'),
    (s) => must(s, 'if (at < highWater)', 'if (false)'));
  const ceilingCaught = rosterRun(noWindow);
  assert.equal(ceilingCaught.status, INFRA, 'with the window arm gone the ceiling still refuses');
  assert.match(token(ceilingCaught.out), /code=ROSTER-TRUNCATED/);
  assert.match(ceilingCaught.out, /could not be paginated to the end — 6 pages of 3/);
  assert.doesNotMatch(ceilingCaught.out, /STOPPED ADVANCING/,
    'the window mutation must actually apply — otherwise the arm under test never left');

  // AND WITH EVERY ARM SOFTENED, the pre-fix disease returns intact: 3 unique rows of an
  // endless ledger, clause (a) clean over them.
  const blind = rosterRun(chain(noWindow,
    (s) => must(s, 'if (page > ROSTER_MAX_PAGES)', 'if (page > ROSTER_MAX_PAGES) break;\n    if (false)')));
  assert.notEqual(blind.status, INFRA);
  assert.match(token(blind.out), /\ba=PASS\b/);
  assert.match(token(blind.out), /\broster=3\b/, 'one page, reported as the population — the wave-29 defect, exactly');
});

test('wave 64: a walk that comes back SHORT of the server\'s own total REFUSES (ROSTER-INCOMPLETE)', () => {
  // `count=true` makes the endpoint state a total, so the walk can check its own work.
  // A row unpublished or reparented mid-walk shifts the window left and takes a row with
  // it — silently, because a short page still looks like the end.
  const short = chain(withLedger({ rows: 5, total: 9 }), withPageLimit(3));

  const refused = rosterRun(short);
  assert.equal(refused.status, INFRA, 'a roster short of its own reported total is a read that missed rows');
  assert.match(token(refused.out), /INFRA-FAULT a=UNKNOWN b=UNKNOWN c=UNKNOWN epic=\S+ code=ROSTER-INCOMPLETE/);
  assert.match(refused.out, /came back SHORT — 5 unique rows paginated against a server-reported total of 9 \(4 missing\)/);

  // THE CONTROL — without the arm, clause (a) certifies 5 rows of a population of 9.
  //
  // `childCount: 5` ISOLATES THIS ARM, and the reason is worth stating because it is a
  // real interaction and not a workaround. A ledger serving 5 rows while reporting a total
  // of 9 ALSO describes a parent whose `child_count` exceeds its published roster, so with
  // the default canned `child_count` (the reported total) the wave-66 draft arm fires here
  // too — correctly, on the same 4-row gap, but from the other end. This control exists to
  // prove that THIS refusal is load-bearing, so the draft arm is given nothing to catch:
  // `child_count` equal to the rows actually served. Both arms remain armed; only the
  // overlap is removed.
  const counted = rosterRun(chain(withLedger({ rows: 5, total: 9, childCount: 5 }), withPageLimit(3), (s) => must(s,
    'if (typeof total === \'number\' && rows.length < total)', 'if (false)')));
  assert.notEqual(counted.status, INFRA);
  assert.doesNotMatch(token(counted.out), /code=ROSTER-INCOMPLETE/, 'the mutation must actually remove the refusal');
  assert.match(token(counted.out), /\ba=PASS\b/);
  assert.match(token(counted.out), /\broster=5\b/, '5 of 9, reported as the population');

  // AND THE ARM MUST NOT FIRE ON GROWTH. Rows created after the count was taken sort to
  // the TAIL under `_createdAt:asc` and ARE read, so more rows than the total is not a
  // miss and refusing it would make the instrument unreadable during a live wave — which
  // is the failure mode this whole slice exists to end.
  const grew = rosterRun(chain(withLedger({ rows: 7, total: 5 }), withPageLimit(3)));
  assert.notEqual(grew.status, INFRA, 'a roster LONGER than the reported total missed nothing');
  assert.match(token(grew.out), /\broster=7\b/);
});

test('wave 64: an `order` the endpoint DROPS IN SILENCE is caught by reading the rows (ROSTER-UNORDERED)', () => {
  // MEASURED, and the reason the order is verified rather than trusted: `order=_id:asc`
  // came back in the default `_updatedAt:desc` with no error and no signal. `_updatedAt`
  // re-sorts on every pulse, stamp and close, so offset paging over it repeats one row
  // and drops another — a truncation with no full page to notice.
  const unordered = chain(withLedger({ rows: 7, total: 7, descending: true }), withPageLimit(3));

  const refused = rosterRun(unordered);
  assert.equal(refused.status, INFRA);
  assert.match(token(refused.out), /INFRA-FAULT a=UNKNOWN b=UNKNOWN c=UNKNOWN epic=\S+ code=ROSTER-UNORDERED/);
  assert.match(refused.out, /came back OUT OF ORDER at offset 0/);

  // THE CONTROL — without the arm the walk pages happily over a sequence that is not the
  // one it asked for, and says nothing about it.
  const trusted = rosterRun(chain(unordered, (s) => must(s, 'if (at < highWater)', 'if (false)')));
  assert.notEqual(trusted.status, INFRA);
  assert.doesNotMatch(token(trusted.out), /code=ROSTER-UNORDERED/, 'the mutation must actually remove the refusal');
  assert.match(token(trusted.out), /\broster=7\b/);
});

test('wave 64: the roster request actually CARRIES offset, order and count — read off curl\'s own argv', () => {
  // NAMING THE AFFORDANCE IS NOT ENOUGH IF THE REQUEST DOES NOT USE IT. A shim `curl`
  // records the flags it was handed, so the paging parameters are asserted from the wire
  // rather than from the source that claims to send them.
  const shimDir = tmp('seal-pred-curl-args-');
  const argsFile = join(shimDir, 'argv.txt');
  writeFileSync(join(shimDir, 'curl'),
    `#!/bin/sh\nprintf '%s\\n' "$@" >> ${argsFile}\nprintf '{"result":{"documents":[],"count":0,"offset":0,"limit":500,"total":0}}\\n200\\n'\n`);
  spawnSync('chmod', ['+x', join(shimDir, 'curl')]);
  const r = spawnSync('node', [PREDICATE, '--repo', REPO, '--successor', 'TERMINAL'],
    { encoding: 'utf8', timeout: 120000, env: { ...process.env, PATH: `${shimDir}:${process.env.PATH}` } });
  // An empty roster is refused on its own floor (wave 27) — that is not what is under
  // test here; the request is.
  assert.notEqual(r.status, null, 'the predicate produced no exit status');
  const argv = readFileSync(argsFile, 'utf8');
  assert.match(argv, /^offset=0$/m, 'the walk must ASK for a window');
  assert.match(argv, /^order=_createdAt:asc$/m, 'and page by a key that does not move under a live wave');
  assert.match(argv, /^count=true$/m, 'and ask for the total it checks its own work against');
  assert.match(argv, /^limit=500$/m);
  assert.match(argv, /^filter\[parent_id\]=cloud-console-hardening-epic$/m,
    'never a bare parent_id — that returns 500 UNFILTERED rows');
});

test('wave 29: bucket (c) REFUSES an empty gate table instead of certifying c=PASS over zero gates', () => {
  const empty = (s) => {
    const out = s.replace(/^const PERMANENT_HUMAN_GATES = \{[\s\S]*?^\};$/m, 'const PERMANENT_HUMAN_GATES = {};');
    assert.notEqual(out, s, 'the gate-table mutation must actually apply');
    return out;
  };
  const emptied = mutatedRun(empty, ['--repo', REPO, '--successor', 'TERMINAL']);
  assert.equal(emptied.status, REFUSED);
  assert.match(token(emptied.out), /REFUSED reason=EMPTY-GATE-TABLE a=UNEVALUATED b=UNEVALUATED c=UNEVALUATED/);
  assert.match(emptied.out, /would print no row at all and still certify c=PASS over zero gates/);
  assert.doesNotMatch(token(emptied.out), /\bc=PASS\b/, 'the letter this refusal exists to prevent may not be printed');

  // A reading claims nothing about bucket (c) — it prints c=NOT-READ in its own letters —
  // so the floor sits AFTER the --ladder-only divert and must not refuse a reading.
  const reading = mutatedRun(empty, ['--ladder-only', '--repo', REPO]);
  assert.equal(reading.status, SEAL);
  assert.match(token(reading.out), /LADDER-ONLY .* c=NOT-READ/);
});

test('wave 29: a curl failure NAMES the HTTP status and the request_id it had already parsed', () => {
  // `curl -sG` carries no --fail, so an error body parsed FINE and `.result.documents`
  // then threw a bare `TypeError: Cannot read properties of undefined (reading
  // 'documents')` at code=UNSPECIFIED. It failed closed — and told the reader nothing.
  const shimDir = tmp('seal-pred-curl-');
  writeFileSync(join(shimDir, 'curl'),
    '#!/bin/sh\nprintf \'{"error":{"code":"unauthorized","message":"token expired"},"request_id":"req_abc123"}\\n403\\n\'\n');
  spawnSync('chmod', ['+x', join(shimDir, 'curl')]);
  const r = spawnSync('node', [PREDICATE, '--repo', REPO, '--successor', 'TERMINAL'],
    { encoding: 'utf8', timeout: 120000, env: { ...process.env, PATH: `${shimDir}:${process.env.PATH}` } });
  const out = `${r.stdout}${r.stderr}`;
  assert.equal(r.status, INFRA, 'an unreadable ledger is an infra fault, never a verdict');
  assert.match(out, /the ledger answered HTTP 403/);
  assert.match(out, /error\.code=unauthorized/);
  assert.match(out, /request_id=req_abc123/);
  assert.match(token(out), /code=LEDGER-UNREADABLE/);
  assert.doesNotMatch(out, /unexpected TypeError/,
    'the pre-fix shape: a bare TypeError naming neither the status nor the request_id');
});

test('wave 30: a ledger this program could not REACH is an INFRA FAULT that says so by name', () => {
  // THE OUTAGE RED, ASSERTED FOR THE FIRST TIME. Before this test `LEDGER-UNREACHABLE`
  // appeared nowhere in this file: the behaviour was exercised only as a side effect of
  // the wave-11 control's live spawn, and it surfaced as `not ok 56 … 2 !== 1` — a bare
  // exit-code mismatch naming neither the network nor the ledger, which is exactly the
  // shape of red a human cannot triage. Now that the control is hermetic, this is where
  // an unreachable ledger is measured, and it is measured on purpose.
  //
  // A `curl` that cannot connect exits non-zero WITHOUT a body, so there is no HTTP
  // status to name — that is what separates UNREACHABLE from the 403's UNREADABLE above.
  // Exit 7 is curl's own "failed to connect to host"; any non-zero reproduces the arm.
  const shimDir = tmp('seal-pred-curl-dead-');
  writeFileSync(join(shimDir, 'curl'), '#!/bin/sh\nexit 7\n');
  spawnSync('chmod', ['+x', join(shimDir, 'curl')]);
  const r = spawnSync('node', [PREDICATE, '--repo', REPO, '--successor', 'TERMINAL'],
    { encoding: 'utf8', timeout: 120000, env: { ...process.env, PATH: `${shimDir}:${process.env.PATH}` } });
  const out = `${r.stdout}${r.stderr}`;
  // THE CODE AND THE EXIT STATUS, NEVER THE DIAGNOSTIC SENTENCE. `curl failed: …` is
  // truncated at 90 chars and cuts off mid-flag, so its bytes are a moving target;
  // the token's `code=` field and the exit code are the contract.
  assert.equal(r.status, INFRA, 'an unreachable ledger is an infra fault, never a verdict');
  assert.match(token(out), /INFRA-FAULT a=UNKNOWN b=UNKNOWN c=UNKNOWN epic=\S+ .*code=LEDGER-UNREACHABLE/);
  assert.match(out, /INFRA FAULT at /);
  assert.doesNotMatch(token(out), /code=LEDGER-UNREADABLE/,
    'a ledger that never answered must not be reported as one that answered unreadably');
  assert.doesNotMatch(out, /VERDICT: SEAL/, 'nothing may be sealed off a roster that was never fetched');
  assert.doesNotMatch(token(out), /\ba=(PASS|FAIL)\b/,
    'no clause letter may be asserted off a read that did not happen');
});

// ── THE OTHER HALF OF WAVE 64 — THE BY-ID READ ─────────────────────────────────────────
// Wave 64 taught the ROSTER read to page-or-refuse. The BY-ID read next to it kept the
// original disease in miniature: `q([['filter[_id]', id]]).result.documents[0] || null` —
// no `limit`, no `count`, and no check that the row that came back is the row that was
// asked for. Re-measured on the live ledger 2026-08-22: a lost `filter[]` wrapper
// (`?_id=<real id>&limit=3`) answers HTTP 200 with 3 UNFILTERED rows out of 6,994, and a
// filterless read with no `limit` answers a default window of 100. So one dropped wrapper
// makes `fetchById(anything)` return whatever sorted first, silently — and bucket (c),
// whose whole job is to catch a permanent human gate that VANISHED, resolves every gate ✓
// off that stranger and can no longer lose. Truncation and blindness are indistinguishable
// at the call site: that is the thing these four arms fix.

test('wave 65 THE BY-ID READ CAN LOSE (cardinality): a dropped `filter[_id]` REFUSES instead of resolving a stranger', () => {
  // A roster that pages cleanly and carries no residue, so the run reaches BUCKET (c) —
  // the clause that reads `fetchById` — instead of stopping at the TERMINAL refusal.
  const dropped = chain(withLedger({ rows: 4, total: 4, byId: 'unfiltered' }), withPageLimit(3));

  const refused = rosterRun(dropped);
  assert.equal(refused.status, INFRA, 'a lookup this program could not trust is an infra fault, never a verdict');
  assert.match(token(refused.out), /INFRA-FAULT a=UNKNOWN b=UNKNOWN c=UNKNOWN epic=\S+ code=LOOKUP-UNFILTERED/);
  // THE INSTRUMENT REPORTS ITS OWN SAMPLE SIZE — how many rows it got AND how many the
  // server said matched. A refusal that only says "something was wrong" is the same
  // silence one layer up.
  assert.match(refused.out, /came back with 2 rows for ONE _id \(the server's own count says 6994 matched\)/);
  assert.doesNotMatch(refused.out, /VERDICT: SEAL/);

  // CONTROL 1 — the arms are INDEPENDENT and STACKED. Remove cardinality and the identity
  // arm still refuses, by its own name: two different facts about the same broken read.
  const noCardinality = chain(dropped, (s) => must(s, 'if (docs.length > 1)', 'if (false)'));
  const stillCaught = rosterRun(noCardinality);
  assert.equal(stillCaught.status, INFRA, 'with cardinality gone, identity still refuses');
  assert.match(token(stillCaught.out), /code=LOOKUP-WRONG-ROW/);
  assert.doesNotMatch(token(stillCaught.out), /code=LOOKUP-UNFILTERED/,
    'the cardinality mutation must actually apply — otherwise the arm under test never left');

  // CONTROL 2 — WITH BOTH ARMS GONE, THE PRE-FIX DISEASE RETURNS INTACT. Bucket (c)
  // resolves all three permanent human gates ✓ against rows nobody asked for, prints a
  // stranger's `parent=` as if it were the gate's, and reports c=PASS. That is a clause
  // that cannot fail on the one condition it exists to catch.
  const blind = rosterRun(chain(noCardinality, (s) => must(s, 'if (doc._id !== id)', 'if (false)')));
  assert.notEqual(blind.status, INFRA, 'disarmed, the lookup stops refusing');
  assert.doesNotMatch(token(blind.out), /code=LOOKUP-/, 'the mutations must actually remove both refusals');
  assert.match(token(blind.out), /\bc=PASS\b/, 'and bucket (c) certifies gates it never read');
  assert.match(blind.out, /✓ gr-ops-platform-admin-emails {2}status=open parent=null/,
    'the gate line is printed off the stranger row, ✓ and all');
});

test('wave 65 THE BY-ID READ CAN LOSE (identity): ONE row that is the WRONG row is refused by name', () => {
  // The shape cardinality is structurally BLIND to, and the reason both arms exist: a
  // single row comes back, so counting rows proves nothing. Only reading the `_id` off
  // the document — never off the parameter that was sent — can see it.
  const stranger = chain(withLedger({ rows: 4, total: 4, byId: 'wrong-row' }), withPageLimit(3));

  const refused = rosterRun(stranger);
  assert.equal(refused.status, INFRA);
  assert.match(token(refused.out), /INFRA-FAULT a=UNKNOWN b=UNKNOWN c=UNKNOWN epic=\S+ code=LOOKUP-WRONG-ROW/);
  assert.match(refused.out, /came back with cch-w39-s4-a-stranger instead \(the server's own count says 1 matched\)/);
  assert.doesNotMatch(token(refused.out), /code=LOOKUP-UNFILTERED/,
    'one row is one row: the cardinality arm CANNOT see this, which is why identity is not redundant');

  // THE CONTROL — remove identity alone and the run goes green over the stranger, with
  // cardinality still armed and unable to help.
  const trusted = rosterRun(chain(stranger, (s) => must(s, 'if (doc._id !== id)', 'if (false)')));
  assert.notEqual(trusted.status, INFRA);
  assert.doesNotMatch(token(trusted.out), /code=LOOKUP-/, 'the mutation must actually remove the refusal');
  assert.match(token(trusted.out), /\bc=PASS\b/);
  assert.match(trusted.out, /✓ cch-hg-compose-network-recreation {2}status=open parent=null/);
});

test('wave 65 THE PERMIT: an honest by-id read stays green, and the permit is BOUND to the guard', () => {
  // Direction two. A lookup that answers the question it was asked must cost nothing:
  // every gate resolves, no `LOOKUP-` code appears, bucket (c) passes.
  const honest = chain(withLedger({ rows: 4, total: 4, byId: 'honest' }), withPageLimit(3));
  const permitted = rosterRun(honest);
  assert.notEqual(permitted.status, INFRA, `an honest lookup is not an infra fault: ${token(permitted.out)}`);
  assert.doesNotMatch(token(permitted.out), /code=LOOKUP-/);
  assert.match(token(permitted.out), /\bc=PASS\b/);
  assert.match(permitted.out, /✓ gr-ops-platform-admin-emails {2}status=open/,
    'and the gate row printed is the gate row, not a stranger');

  // NON-VACUOUS, PROVED BY MUTATION. A permit assertion that no mutation can red is not
  // evidence — it is a sentence about a code path it never touched. Over-tighten the
  // cardinality arm by ONE character (`> 1` becomes `> 0`) and this exact run REDS: the
  // permit is reading the guard, not reading past it.
  const overEager = rosterRun(chain(honest, (s) => must(s, 'if (docs.length > 1)', 'if (docs.length > 0)')));
  assert.equal(overEager.status, INFRA, 'the permit is bound to the guard: over-tighten it and the healthy read reds');
  assert.match(token(overEager.out), /code=LOOKUP-UNFILTERED/);

  // AND THE GUARD COSTS NOTHING WHERE THERE IS NOTHING TO GUARD. With BOTH arms removed
  // the honest run's verdict token is BYTE-IDENTICAL — so disarming the guard reds only
  // the refusal tests above and moves not one byte of a healthy verdict.
  const disarmed = rosterRun(chain(honest,
    (s) => must(s, 'if (docs.length > 1)', 'if (false)'),
    (s) => must(s, 'if (doc._id !== id)', 'if (false)')));
  assert.equal(token(disarmed.out), token(permitted.out),
    'both arms gone, and an honest read produces the same verdict token byte for byte');
  assert.equal(disarmed.status, permitted.status, 'same exit code');
});

test('wave 65: the by-id request actually CARRIES limit and count — read off curl\'s own argv', () => {
  // NAMING THE AFFORDANCE IS NOT ENOUGH IF THE REQUEST DOES NOT USE IT — the wave-64
  // argv test's rule, pointed at the lookup. `limit=2` IS the cardinality arm: without a
  // window there is no second row to count, and the arm can never fire however well it is
  // written. Asserted from the wire, not from the source that claims to send it.
  const shimDir = tmp('seal-pred-curl-byid-');
  const argsFile = join(shimDir, 'argv.txt');
  writeFileSync(join(shimDir, 'curl'),
    `#!/bin/sh\nprintf '%s\\n' "$@" >> ${argsFile}\nprintf '{"result":{"documents":[],"count":0,"offset":0,"limit":500,"total":0}}\\n200\\n'\n`);
  spawnSync('chmod', ['+x', join(shimDir, 'curl')]);
  // `--successor` names an id, so the lookup runs before any roster floor can end the run.
  const r = spawnSync('node', [PREDICATE, '--repo', REPO, '--successor', 'some-successor-id'],
    { encoding: 'utf8', timeout: 120000, env: { ...process.env, PATH: `${shimDir}:${process.env.PATH}` } });
  assert.notEqual(r.status, null, 'the predicate produced no exit status');
  const argv = readFileSync(argsFile, 'utf8');
  assert.match(argv, /^filter\[_id\]=some-successor-id$/m, 'never a bare _id — measured live, the wrapper-less form returns the whole table');
  assert.match(argv, /^limit=2$/m, 'one row is the answer; the SECOND row is the proof the filter did not hold');
  assert.match(argv, /^count=true$/m, 'so the refusal can state how many rows actually matched');
});

// ─── THE PUBLISHED-ONLY ROSTER NAMES ITS OWN BLIND SPOT ──────────────────────────────
//
// `/v1/data/query` answers from the PUBLISHED perspective and there is no parameter that
// changes it. Measured against the live ledger on 2026-08-24, three requests differing in
// exactly one parameter returned byte-identical bodies:
//
//   …?filter[parent_id]=task-fb4fb869490b4213&limit=1&count=true
//                                     -> {total:348, perspective:"published"}
//   …&perspective=drafts              -> {total:348, perspective:"published"}
//   …&zzz_not_a_real_param=1          -> {total:348, perspective:"published"}
//
// An unknown perspective is DROPPED, not refused — the same silent drop this predicate
// already records for `filter[]` and for `order`. So the roster walk cannot be taught to
// see drafts; it can only be taught to notice that it did not. On the same parent the
// same day, `/v1/tasks/…` reported child_count 349 against this walk's 348, and the row
// in the gap was `drafts.dr-w34-bl-5658-blocks-its-own-routing-fix`, OPEN — a live row
// invisible to the instrument whose whole job is certifying that no live row remains.
test('wave 66: a DRAFT child the published roster cannot see is a REFUSAL, not a clean seal', () => {
  // Seven published rows, and a ledger that says there are eight children. The eighth is
  // a draft. Pre-fix this sealed: clause (a) counted orphans over the seven it could see.
  const blind = rosterRun(chain(withLedger({ rows: 7, total: 7, childCount: 8 }), withPageLimit(3)));
  assert.equal(blind.status, INFRA, 'a population this program could not read whole is an infra fault, never a verdict');
  assert.match(token(blind.out), /INFRA-FAULT a=UNKNOWN b=UNKNOWN c=UNKNOWN epic=\S+ code=ROSTER-DRAFT-BLIND/);
  assert.match(blind.out, /this walk read 7 published rows/);
  assert.match(blind.out, /child_count 8/);
  assert.match(blind.out, /1 child is invisible/, 'the DELTA is named, singular');
  assert.doesNotMatch(blind.out, /VERDICT: SEAL/);

  // BOTH REMEDIES ARE NAMED, because they are opposite and one is destructive: a stale
  // `drafts.<id>` twin published over its parent overwrites the published criteria and can
  // un-stamp a met one. The refusal must not let a reader guess.
  assert.match(blind.out, /TWIN/);
  assert.match(blind.out, /published-wins/);

  // THE CONTROL — mutation-proof that the arm is load-bearing. Soften the refusal into a
  // warning and the identical run certifies clause (a) CLEAN over the seven rows it could
  // see, with an eighth live row it never read. That is the false seal this exists to stop.
  const softened = rosterRun(chain(
    withLedger({ rows: 7, total: 7, childCount: 8 }),
    withPageLimit(3),
    (s) => must(s, 'if (ledgerCount > rows.length) {', 'if (false) {')));
  assert.notEqual(softened.status, INFRA, 'softened, the walk stops refusing');
  assert.doesNotMatch(token(softened.out), /code=ROSTER-DRAFT-BLIND/);
  assert.match(token(softened.out), /\ba=PASS\b/, 'and clause (a) passes over a population it knows is partial');
});

test('wave 66: NO gap is NO refusal — the arm must not fire on a parent with zero drafts', () => {
  // The false-positive floor. `child_count` equal to the published roster is the normal
  // case for the overwhelming majority of parents (measured 2026-08-24: cch-instruments-epic
  // 280==280, dr-backlog-never-started 334==334), and the new read must be silent there.
  const clean = rosterRun(chain(withLedger({ rows: 7, total: 7 }), withPageLimit(3)));
  assert.notEqual(clean.status, INFRA, `a roster with no draft gap is not an infra fault: ${token(clean.out)}`);
  assert.doesNotMatch(token(clean.out), /code=ROSTER-DRAFT-BLIND/);
  assert.match(token(clean.out), /\ba=PASS\b/);
});

test('wave 66: a cross-check that CANNOT BE READ refuses — an unverified population is not a verified one', () => {
  // The property that matters most, and the one a soft cross-check would have destroyed.
  // During this work the bp server dropped 26 consecutive reads; an instrument that treats
  // an unreadable cross-check as "no gap found" reports NO HUMAN GATES REMAIN during the
  // exact incident when someone needs the list. `child_count` absent stands for every way
  // the second read can fail to produce a number.
  const unreadable = rosterRun(chain(
    withLedger({ rows: 7, total: 7 }),
    withPageLimit(3),
    (s) => must(s, 'return { doc: { child_count: 7 } };', 'return { doc: {} };')));
  assert.equal(unreadable.status, INFRA, 'a cross-check that produced no number certifies nothing');
  assert.match(token(unreadable.out), /code=DRAFT-CROSSCHECK-UNREADABLE/);
  assert.match(unreadable.out, /no numeric child_count/);
  assert.doesNotMatch(unreadable.out, /VERDICT: SEAL/);
});

// ─── WAVE 67 — THE REFUSAL THAT WAS HOLDING ITS OWN ANSWER ───────────────────────────
//
// Wave 66 taught the walk to NOTICE a draft child by comparing two numbers from two
// endpoints. It then refused, and told the reader to go run `bp task get <parent>` BY HAND
// to find out WHICH rows were in the gap. The response that produced the count ALREADY
// CARRIES THAT LIST: `/v1/tasks/:id` answers `{child_count, children:[{doc_id,
// lifecycle_status, title, criteria_progress, …}]}`, and `qTasks` was reading exactly one
// field off it and throwing the rest away one line above the refusal.
//
// Measured live against the epic this instrument exists to certify, 2026-09-01:
//
//   the walk read 921 published rows; /v1/tasks/cloud-console-hardening-epic said 925.
//   The four in the gap, straight out of the SAME response's `.children`:
//     drafts.task-c64f2a37d7f97bd8                                        cancelled
//     drafts.cch-w40-bl-probe-packet-audit-x1                             cancelled
//     drafts.cch-w40-s5-followup-reason-only-refusals-invisible-…-lens    cancelled
//     drafts.cch-w64-s5-law-0-repayment-twelve-closes-three-integers      OPEN
//   None of the four had a published twin in the walk — all four are draft-ONLY children.
//
// So the one epic Standing Law 0 is scored against had been UNMEASURABLE since wave 66 for
// want of a field read, while the answer sat in a variable the throw could see. A refusal
// that the program's own payload can discharge is not honesty; it is an unread response.
//
// THE FIX RESOLVES, IT DOES NOT SOFTEN. Draft-only children are ADMITTED into the roster
// carrying the lifecycle_status the task layer reports, so clause (a) counts a live draft
// as residue instead of never seeing it. Every case the walk CANNOT resolve from that list
// still refuses under the same `ROSTER-DRAFT-BLIND` code: no list at all, a list that does
// not account for the gap, a gap row with no lifecycle_status, or a `drafts.<id>` TWIN of a
// row already walked — whose remedy is destructive and stays a human's call.
const withChildren = (kids) => (s) => must(s,
  'return { doc: { child_count: ',
  'return { children: ' + JSON.stringify(kids) + ', doc: { child_count: ');
const pubKids = (n, status) => {
  const out = [];
  for (let i = 0; i < n; i += 1) out.push({ doc_id: 'row-' + i, lifecycle_status: status || 'done' });
  return out;
};

test('wave 67 THE GAP RESOLVES FROM THE RESPONSE ALREADY IN HAND: a draft-only child is ADMITTED, not refused', () => {
  // Seven published rows, a ledger that says eight children, and the eighth NAMED in the
  // same response: a draft-only row that is `done`. Pre-fix this refused ROSTER-DRAFT-BLIND
  // and asserted nothing whatever about clause (a).
  const resolved = rosterRun(chain(
    withLedger({ rows: 7, total: 7, childCount: 8 }),
    withChildren([...pubKids(7), { doc_id: 'drafts.d-dead', lifecycle_status: 'done' }]),
    withPageLimit(3)));
  assert.notEqual(resolved.status, INFRA,
    `a gap the program can resolve from its own payload is not an infra fault: ${token(resolved.out)}`);
  assert.doesNotMatch(token(resolved.out), /code=ROSTER-DRAFT-BLIND/);
  assert.match(token(resolved.out), /\ba=PASS\b/);
  // THE DENOMINATOR IS THE WHOLE POPULATION, not the published half of it.
  assert.match(token(resolved.out), /\broster=8\b/, 'the admitted draft is counted in the roster');
  assert.match(token(resolved.out), /\bdrafts=1\b/,
    'and the token DISCLOSES how many rows came from the task layer rather than the published query');
});

test('wave 67 THE ADMITTED ROW CAN FAIL THE CLAUSE IT WAS INVISIBLE TO: an OPEN draft is residue', () => {
  // The whole point. All seven published rows are `done`, so the ONLY live row in this
  // parent is the one the published query cannot see. Admitting it must make it COUNT —
  // the refutation below is the previously-invisible row doing the work.
  const live = rosterRun(chain(
    withLedger({ rows: 7, total: 7, childCount: 8 }),
    withChildren([...pubKids(7), { doc_id: 'drafts.d-open', lifecycle_status: 'open' }]),
    withPageLimit(3)));
  assert.equal(live.status, REFUSED, `TERMINAL is refuted by the admitted draft: ${token(live.out)}`);
  assert.match(token(live.out), /reason=TERMINAL-CLAIM-REFUTED/);
  assert.match(live.out, /drafts\.d-open/, 'the row that refutes TERMINAL is NAMED, and it is the draft');

  // NON-VACUOUS, PROVED BY MUTATION — and the mutant is WORSE than wave 66, not equal to
  // it. Resolve the gap and then DROP the admission (the one-line push) and the identical
  // run does not go back to refusing: it stops refusing AND never sees the open row, so it
  // certifies clause (a) CLEAN over a population it just finished proving was partial.
  // That is the false seal this arm exists to stop, and it is reachable by deleting one
  // line — so the assertion above is reading the admitted row, not reading past it.
  const notAdmitted = rosterRun(chain(
    withLedger({ rows: 7, total: 7, childCount: 8 }),
    withChildren([...pubKids(7), { doc_id: 'drafts.d-open', lifecycle_status: 'open' }]),
    withPageLimit(3),
    (s) => must(s, 'for (const a of admitted) rows.push(a);', '')));
  assert.notEqual(notAdmitted.status, REFUSED, 'TERMINAL is no longer refuted — the row that refuted it is gone');
  assert.match(token(notAdmitted.out), /\ba=PASS\b/, 'and clause (a) passes over the seven it could see');
  assert.match(token(notAdmitted.out), /\broster=7\b/, 'the denominator silently loses the eighth row');
  assert.doesNotMatch(notAdmitted.out, /drafts\.d-open/, 'the live draft is invisible again');
});

test('wave 67 THE REFUSAL SURVIVES (no list): a gap with no `children` to resolve it still REFUSES', () => {
  // A cross-check endpoint that answers a count and no ids is exactly wave 66's world, and
  // it must still refuse there. `children` absent stands for every shape the list can fail
  // to arrive in.
  const blind = rosterRun(chain(withLedger({ rows: 7, total: 7, childCount: 8 }), withPageLimit(3)));
  assert.equal(blind.status, INFRA, 'an unresolvable gap is still a population this program could not read whole');
  assert.match(token(blind.out), /code=ROSTER-DRAFT-BLIND/);
  assert.match(blind.out, /carried no `children` list/);
  assert.doesNotMatch(blind.out, /VERDICT: SEAL/);
});

test('wave 67 THE REFUSAL SURVIVES (twin): a `drafts.<id>` TWIN of a walked row is NOT admitted', () => {
  // The destructive case, and the reason wave 66 refused to guess at all. A twin is the
  // SAME row twice, so admitting it would double-count the population, and publishing it
  // over its parent can un-stamp a met criterion. It stays a human's call, by name.
  const twin = rosterRun(chain(
    withLedger({ rows: 7, total: 7, childCount: 8 }),
    withChildren([...pubKids(7), { doc_id: 'drafts.row-0', lifecycle_status: 'open' }]),
    withPageLimit(3)));
  assert.equal(twin.status, INFRA, 'a twin is not a row this program may resolve on its own');
  assert.match(token(twin.out), /code=ROSTER-DRAFT-BLIND/);
  assert.match(twin.out, /drafts\.row-0/, 'and the twin is NAMED rather than described');
  assert.match(twin.out, /published-wins/);
});

test('wave 67 THE REFUSAL SURVIVES (short list): a `children` list that does not account for the gap REFUSES', () => {
  // A list that is itself truncated resolves nothing, and a PARTIAL resolution is the exact
  // fail-open this file is written against: nine children claimed, eight named.
  const short = rosterRun(chain(
    withLedger({ rows: 7, total: 7, childCount: 9 }),
    withChildren([...pubKids(7), { doc_id: 'drafts.d-dead', lifecycle_status: 'done' }]),
    withPageLimit(3)));
  assert.equal(short.status, INFRA, 'a list that cannot account for the gap has not resolved it');
  assert.match(token(short.out), /code=ROSTER-DRAFT-BLIND/);
  assert.match(short.out, /accounts for only 1 of the 2/);
});

test('wave 67 THE REFUSAL SURVIVES (no status): a gap row with no lifecycle_status REFUSES', () => {
  // An admitted row is admitted BECAUSE of its lifecycle_status — that is the single field
  // clause (a) reads off it. A row carrying none cannot be placed live or dead, and a row
  // this program cannot place must never be counted as clean.
  const noStatus = rosterRun(chain(
    withLedger({ rows: 7, total: 7, childCount: 8 }),
    withChildren([...pubKids(7), { doc_id: 'drafts.d-mute' }]),
    withPageLimit(3)));
  assert.equal(noStatus.status, INFRA, 'a row with no lifecycle_status cannot be placed');
  assert.match(token(noStatus.out), /code=ROSTER-DRAFT-BLIND/);
  assert.match(noStatus.out, /drafts\.d-mute/);
  assert.match(noStatus.out, /no lifecycle_status/);
});
