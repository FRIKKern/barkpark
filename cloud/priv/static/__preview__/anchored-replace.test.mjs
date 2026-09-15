// TESTS FOR anchored-replace.mjs — and the RATCHET that makes its rule mechanical.
//
// The defect this file exists to keep dead: a mutation test that rewrapped a 4-space
// `if: always()` inside cloud.yml's `cloud-gate` job with a bare `String.replace`. The
// workflow grew two STEP-level `if: always()` lines — 8 spaces — ABOVE that job, an
// 8-space line contains the 4-space needle, and the rewrap landed on the first of them.
// The intended site stayed bare, the run still produced a verdict, and the case reported
// GREEN having asserted something about a line it never touched — a vacuous green inside
// the one instrument whose whole job is to prove a test is not vacuous.
//
// Everything here is measured, never asserted from prose. `THE SPECIMEN` below is that
// exact collision, reproduced in eleven lines, and both directions of every repair are
// run against it: the PRE-REPAIR helper lands off target and reports success, the
// repaired one refuses. The ratchet at the bottom is what fires without anyone
// remembering this paragraph.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  MutationNeedleError,
  bareStringNeedlesByFile,
  censusTree,
  classifySource,
  isGovernedPath,
  replaceUnique,
  replaceWholeLine,
} from './anchored-replace.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const STATIC_ROOT = join(HERE, '..');

// ── THE SPECIMEN ────────────────────────────────────────────────────────────
// A step-level `if: always()` at 8 spaces, ABOVE a job-level one at 4. The 4-space
// text is a substring of the 8-space line, and it comes SECOND.
const SPECIMEN = [
  'jobs:',
  '  test:',
  '    runs-on: ubuntu-latest',
  '    steps:',
  '      - name: report',
  '        if: always()',
  '        run: "true"',
  '',
  '  cloud-gate:',
  '    name: Cloud gate',
  '    if: always()',
  '    needs: [changes, test]',
  '',
].join('\n');

const NEEDLE = '    if: always()';

// The span of the `cloud-gate` job — derived, so the test does not carry a line number
// that rots the next time the specimen gains a line.
const cloudGateSpan = (text) => {
  const from = text.search(/^ {2}cloud-gate:$/m);
  assert.notEqual(from, -1, 'the specimen must declare a cloud-gate job');
  const rest = text.slice(from + 1);
  const next = rest.search(/^ {2}[A-Za-z0-9_-]+:$/m);
  return { from: from + 1, to: next === -1 ? text.length : from + 1 + next };
};

// ── THE VACUITY, DEMONSTRATED ───────────────────────────────────────────────
// This is the control the repair is measured against: the PRE-REPAIR shape, run on a
// tree where the property IS broken. It "succeeds" — the string changes, an
// `assert.notEqual(mutated, src)` of the kind the old arms carried is satisfied — and
// the line it was written to mutate is untouched.
test('CONTROL: the PRE-REPAIR bare .replace lands off target and reports success', () => {
  const mutated = SPECIMEN.replace(NEEDLE, '    if: ${{ always() }}');

  assert.notEqual(mutated, SPECIMEN, 'the pre-repair shape reports APPLIED — this is the false green');

  const span = cloudGateSpan(mutated);
  assert.ok(mutated.slice(span.from, span.to).includes('\n    if: always()\n'),
    'and cloud-gate — the subject — still carries the BARE spelling the mutation meant to remove');
  assert.ok(mutated.includes('        if: ${{ always() }}'),
    'because the rewrap landed on the STEP-level line, which merely contains the needle');
});

// MEASURED, and it corrected the expectation this test was written with: the repaired
// door does not need the span to survive the specimen. Requiring the needle to BE a line
// — matched with the newlines around it — already makes `\n        if: always()\n` a
// different string from `\n    if: always()\n`, so the containment that decided the
// original outcome cannot reach it. The span is the SECOND guard, for the case where the
// same line legitimately occurs in two jobs; it is not what defeats the containment.
test('the repaired door is IMMUNE to the containment even with no span at all', () => {
  const mutated = replaceWholeLine(SPECIMEN, NEEDLE, '    if: ${{ always() }}');

  const span = cloudGateSpan(mutated);
  assert.ok(mutated.slice(span.from, span.to).includes('    if: ${{ always() }}'),
    'whole-line matching lands on cloud-gate, the line the mutation names');
  assert.ok(mutated.includes('        if: always()'),
    'and the step-level line that merely CONTAINS the needle is untouched — that is the whole repair');
});

test('a needle that exists only as a SUBSTRING of a longer line REFUSES, and says which', () => {
  // No indentation: `if: always()` appears inside both lines and is a whole line in
  // neither. The pre-repair shape would have taken the step-level one.
  assert.throws(
    () => replaceWholeLine(SPECIMEN, 'if: always()', 'x'),
    (e) => e instanceof MutationNeedleError
      && /never as a WHOLE LINE/.test(e.message)
      && /appears 2 time\(s\)/.test(e.message),
    'the refusal must distinguish "your needle is a fragment" from "your anchor has drifted"');
});

test('…and with the span it was searched in, the repaired door lands on the subject', () => {
  const span = cloudGateSpan(SPECIMEN);
  const mutated = replaceWholeLine(SPECIMEN, NEEDLE, '    if: ${{ always() }}', { span });

  const after = cloudGateSpan(mutated);
  assert.ok(mutated.slice(after.from, after.to).includes('    if: ${{ always() }}'),
    'the rewrap must land inside cloud-gate');
  assert.ok(!mutated.slice(after.from, after.to).includes('\n    if: always()\n'),
    'and the bare spelling must be GONE from cloud-gate, or this resolves through the old form');
  assert.ok(mutated.includes('        if: always()'),
    'the step-level line is somebody else’s business and must be untouched');
});

// ── replaceWholeLine — the three refusals ───────────────────────────────────
test('replaceWholeLine REFUSES a needle that matches nothing', () => {
  assert.throws(
    () => replaceWholeLine(SPECIMEN, '    if: never()', 'x'),
    (e) => e instanceof MutationNeedleError && /matches NOTHING/.test(e.message));
});

test('replaceWholeLine REFUSES a needle that is a whole line more than once', () => {
  const twice = `${SPECIMEN}  cloud-gate-decoy:\n    if: always()\n`;
  assert.throws(
    () => replaceWholeLine(twice, NEEDLE, 'x'),
    (e) => e instanceof MutationNeedleError && /is a whole line 2 times/.test(e.message));
});

test('replaceWholeLine REFUSES a needle that is itself multi-line', () => {
  assert.throws(
    () => replaceWholeLine(SPECIMEN, 'jobs:\n  test:', 'x'),
    (e) => e instanceof MutationNeedleError && /cannot itself contain a newline/.test(e.message));
});

test('replaceWholeLine reaches the FIRST and LAST lines of its span', () => {
  const text = 'alpha\nbeta\ngamma';
  assert.equal(replaceWholeLine(text, 'alpha', 'A'), 'A\nbeta\ngamma');
  assert.equal(replaceWholeLine(text, 'gamma', 'G'), 'alpha\nbeta\nG');
});

// ── replaceUnique — the three refusals ──────────────────────────────────────
test('replaceUnique applies when the needle occurs exactly once', () => {
  assert.equal(replaceUnique('a-b-c', '-b-', '+B+'), 'a+B+c');
});

test('replaceUnique REFUSES a drifted needle rather than returning the text unchanged', () => {
  assert.throws(
    () => replaceUnique('a-b-c', '-z-', '+Z+'),
    (e) => e instanceof MutationNeedleError && /matches NOTHING/.test(e.message),
    'a silent no-op is the failure that started all of this');
});

test('replaceUnique REFUSES an ambiguous needle instead of taking the first one', () => {
  assert.throws(
    () => replaceUnique('x.x.', 'x.', 'y.'),
    (e) => e instanceof MutationNeedleError && /matches 2 times/.test(e.message));
});

test('replaceUnique honours its span — a match outside it is not a match', () => {
  const text = 'HEAD needle TAIL needle';
  assert.throws(
    () => replaceUnique(text, 'needle', 'x', { span: { from: 0, to: 4 } }),
    (e) => e instanceof MutationNeedleError && /matches NOTHING/.test(e.message));
  assert.equal(replaceUnique(text, 'needle', 'X', { span: { from: 0, to: 11 } }), 'HEAD X TAIL needle');
});

test('replaceUnique REFUSES a span that is not a range inside the text', () => {
  assert.throws(
    () => replaceUnique('abc', 'a', 'x', { span: { from: 2, to: 99 } }),
    (e) => e instanceof MutationNeedleError && /not a range inside the text/.test(e.message));
});

test('a refusal NAMES the needle, so the reader is not sent hunting', () => {
  try {
    replaceUnique('abc', 'zzz-the-anchor', 'x');
    assert.fail('must have refused');
  } catch (e) {
    assert.match(e.message, /zzz-the-anchor/);
    assert.equal(e.name, 'MutationNeedleError');
  }
});

// ── THE CENSUS — it must be able to say YES and to say NO ───────────────────
// A scan that cannot find the known specimen reports a clean tree and a broken scanner
// identically. Both arms below are the price of quoting this census at all.

const PRE_REPAIR_SOURCE = [
  'const mutate = (src) => {',
  '  const bare = src.match(/^ {4}if: always\\(\\)$/m);',
  '  return src.replace(bare[0], "    if: ${{ always() }}");',
  '};',
].join('\n');

const REPAIRED_SOURCE = [
  "import { replaceWholeLine } from './anchored-replace.mjs';",
  'const mutate = (src, span) => {',
  '  const bare = src.slice(span.from, span.to).match(/^ {4}if: always\\(\\)$/m);',
  '  return replaceWholeLine(src, bare[0], "    if: ${{ always() }}", { span });',
  '};',
].join('\n');

test('POSITIVE CONTROL: the census FINDS the pre-repair specimen', () => {
  const found = classifySource(PRE_REPAIR_SOURCE, 'specimen.mjs').filter((f) => f.needleClass === 'DYNAMIC');
  assert.equal(found.length, 1, 'the scan must flag the bare .replace whose needle is a match result');
  assert.equal(found[0].receiver, 'src');
  assert.equal(found[0].needle, 'bare[0]');
});

test('NEGATIVE CONTROL: the census finds NOTHING in the repaired shape', () => {
  const found = classifySource(REPAIRED_SOURCE, 'specimen.mjs').filter((f) => f.needleClass === 'DYNAMIC');
  assert.equal(found.length, 0, 'a mutation routed through the door is not a finding');
  assert.ok(classifySource(REPAIRED_SOURCE, 'specimen.mjs').some((f) => f.needleClass === 'GUARDED'),
    'and the door it went through is counted, so a file can prove it used one');
});

test('the census reads CODE only — a .replace in a comment or a string is not a call site', () => {
  const decoys = [
    '// const x = src.replace(needle, other);',
    '/* const y = src.replace(needle, other); */',
    'const s = "src.replace(needle, other)";',
    'const t = `src.replace(${needle}, other)`;',
  ].join('\n');
  assert.deepEqual(classifySource(decoys, 'decoys.mjs'), [],
    'a scanner that reads its own prose as findings cannot be quoted');
});

test('the census classifies by what `replace` DOES with the needle', () => {
  const src = [
    'a.replace(/^x$/m, "1");',
    'b.replace(/x/g, "2");',
    'c.replace("x", "3");',
    'd.replace(needle, "4");',
    'const RX = /^z$/m;',
    'e.replace(RX, "5");',
  ].join('\n');
  const got = classifySource(src, 'k.mjs').map((f) => f.needleClass);
  assert.deepEqual(got, [
    'REGEX_ANCHORED', 'REGEX_UNANCHORED', 'STRING_LITERAL', 'DYNAMIC', 'REGEX_ANCHORED',
  ], 'a binding is followed only far enough to prove the needle is a REGEX — the one resolution that changes the matching rule');
});

test('the census can say NO about a receiver — location.replace is navigation, not surgery', () => {
  const found = bareStringNeedlesByFile(
    classifySource('location.replace(url);\nsrc.replace(needle, "x");', 'k.test.mjs'));
  assert.deepEqual([...found.keys()], ['k.test.mjs']);
  assert.equal(found.get('k.test.mjs').length, 1, 'only the source-text surgery is a member');
});

test('the governed corpus is a PREDICATE, not a list of files', () => {
  assert.ok(isGovernedPath('cloud/priv/static/__app.test.mjs'));
  assert.ok(isGovernedPath('cloud/priv/static/__preview__/serve.mjs'));
  assert.ok(!isGovernedPath('cloud/priv/static/app.js'),
    'app.js is the SUBJECT of mutations, never the mutator');
});

// ── THE RATCHET ─────────────────────────────────────────────────────────────
// Measured on origin/main c42fde07c, 2026-09-14, after this wave routed every mutation
// in seal-predicate.test.mjs through the door above (it held 23).
//
// The rule, not the snapshot: a file may hold NO MORE bare string-needle replaces than
// its record, a file with no record must hold NONE, and seal-predicate.test.mjs is
// pinned TWO-SIDED at zero because it is the file the defect was measured in. Lowering
// a number is the intended direction — route the mutation through the door and drop the
// record in the same commit.
const RECORD = {
  '__app.test.mjs': 20,
  // THE ONE IN THIS FILE IS THE CONTROL ITSELF. `CONTROL: the PRE-REPAIR bare .replace
  // lands off target` must call the bare form to demonstrate it; a ratchet that could not
  // see its own demonstration would not be seeing anything. It found this on the first
  // run, before a human read the output.
  '__preview__/anchored-replace.test.mjs': 1,
  '__preview__/breakpoint-sweep.mjs': 1,
  '__preview__/breakpoint-sweep.test.mjs': 4,
  '__preview__/overflow-guard.mjs': 4,
  '__preview__/same-document-nav-census.test.mjs': 1,
  '__preview__/serve.mjs': 1,
  '__preview__/width-drivers.test.mjs': 2,
};
const PINNED_AT_ZERO = '__preview__/seal-predicate.test.mjs';

const relativeCounts = () => {
  const byFile = bareStringNeedlesByFile(censusTree(STATIC_ROOT));
  const counts = {};
  for (const [file, hits] of byFile) counts[file.slice(STATIC_ROOT.length + 1)] = hits.length;
  return counts;
};

test('RATCHET: no governed file holds more bare string-needle replaces than its record', () => {
  const counts = relativeCounts();
  const over = Object.entries(counts)
    .filter(([file, n]) => n > (RECORD[file] || 0))
    .map(([file, n]) => `${file}: ${n} > ${RECORD[file] || 0}`);
  assert.deepEqual(over, [],
    'a bare `.replace` with a string needle takes the first match anywhere and is silent when the needle drifts — route it through replaceUnique/replaceWholeLine in anchored-replace.mjs, or, if the record is genuinely meant to grow, raise it here deliberately');
});

test('RATCHET: the file the defect was measured in is pinned TWO-SIDED at zero', () => {
  assert.equal(relativeCounts()[PINNED_AT_ZERO] || 0, 0,
    `${PINNED_AT_ZERO} mutates the seal predicate's own source in dozens of places; every one of them goes through the door, and a new one must too`);
});

test('RATCHET CONTROL: it can lose — a zeroed record reports the files it governs', () => {
  const counts = relativeCounts();
  const over = Object.entries(counts).filter(([, n]) => n > 0);
  assert.ok(over.length > 0,
    'against an empty record the ratchet must name members; if it names none the census has gone blind and its green means nothing');
  assert.ok(over.some(([file]) => file === '__app.test.mjs'),
    'and the largest known holder must be among them');
});

test('RATCHET CONTROL: a record entry for a file that no longer exists is itself a red', () => {
  const counts = relativeCounts();
  const stale = Object.keys(RECORD).filter((file) => !(file in counts) && RECORD[file] > 0);
  assert.deepEqual(stale, [],
    'a record that outlives its file is a number nobody can re-derive — delete the entry in the commit that clears the file');
});
