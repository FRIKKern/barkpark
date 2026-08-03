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

const SEAL = 0, NO_SEAL = 1, INFRA = 2;
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
  fx.requiredContexts = [AGG];
  const path = join(tmp('seal-pred-'), 'draft-successor.json');
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
  const r = spawnSync('node', [path, '--ledger', withRequired('sealable.json'), '--repo', REPO, '--guard-cmd', 'true'], { encoding: 'utf8' });
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
  assert.equal(status, NO_SEAL);
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
  assert.equal(status, NO_SEAL, 'a done successor must not seal');
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
  assert.equal(cancelled.status, NO_SEAL);
  assert.match(token(cancelled.out), /REFUSED reason=DEAD-SUCCESSOR/);
  assert.match(cancelled.out, /lifecycle_status=cancelled/);

  // Absent is not live either: a row with no lifecycle at all is unworkable, and the
  // refusal says `(absent)` rather than rendering `undefined` at a reader.
  const absent = run(['--ledger', successorFixture((t) => { delete t.lifecycle_status; }, 'no-lifecycle.json'),
    '--repo', REPO, '--guard-cmd', 'true']);
  assert.equal(absent.status, NO_SEAL);
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
  assert.equal(status, NO_SEAL, 'a child of the epic is not OUT of the epic');
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
  assert.equal(status, NO_SEAL);
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

test('wave 11: --ladder-only reaches the ladder the live refusals never can', () => {
  // The control. The SAME tree, minus the flag, refuses upstream of the ladder and
  // reports every clause UNEVALUATED. That contrast IS this slice.
  const refused = run(['--repo', REPO, '--successor', 'TERMINAL']);
  assert.equal(refused.status, NO_SEAL);
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
  assert.equal(stub.status, NO_SEAL, 'R0 still refuses a live stub — a reading of a stub is not a reading');
  assert.match(token(stub.out), /REFUSED reason=GUARD-OVERRIDE-WITHOUT-FIXTURE/);

  const emptied = mutatedRun(
    (s) => s.replace(/^const KNOWN_DEFECTS = \[[\s\S]*?^\];$/m, 'const KNOWN_DEFECTS = [];'),
    ['--ladder-only', '--repo', REPO]);
  assert.equal(emptied.status, NO_SEAL, 'R1 still refuses an empty register on the reading path too');
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

  // MUTATION CONTROL — remove ONLY the git leg and the identical run reproduces the
  // pre-fix output exactly: six false ancestry sentences, every entry flagged, exit 0.
  const unguarded = mutatedRun(
    (src) => src.replace('if (!top || realpathSync(top) !== realpathSync(REPO))', 'if (false)'),
    ['--ladder-only', '--repo', root]);
  assert.equal(unguarded.status, SEAL, 'pre-fix, a wrong root read clean at exit 0 — that is the defect');
  const invented = unguarded.out.split('\n').filter((l) => / is not an ancestor of origin\/main$/.test(l));
  assert.equal(invented.length, 6,
    `pre-fix, every registered defect was reported unlanded because the DIRECTORY had no .git, got ${invented.length}`);
  assert.match(token(unguarded.out), /LADDER-ONLY/);
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
  assert.equal(refused.status, NO_SEAL, 'a roster of nobody must not exit 0');
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
      'const fetchById = (id) => q([[\'filter[_id]\', id]]).result.documents[0] || null;',
      'const fetchById = (id) => ({ _id: id, lifecycle_status: \'open\', parent_id: \'stub\' });'),
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
      .replace('const fetchById = (id) => q([[\'filter[_id]\', id]]).result.documents[0] || null;',
        'const fetchById = (id) => ({ _id: id, lifecycle_status: \'open\', parent_id: \'stub\' });'),
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
