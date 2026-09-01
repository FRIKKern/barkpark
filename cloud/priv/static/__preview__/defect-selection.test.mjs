// defect-selection.test.mjs — the guard's argv → leg-set resolution, proven
// without a browser.
//
// WHAT THIS FILE IS FOR (cch-w17-bl-overflow-guard-honours-one-defect-flag).
// `overflow-guard.mjs` resolved its selection with `argv.indexOf("--defect")`,
// which returns the FIRST match. `--defect A --defect B` measured A, dropped B
// WITHOUT A WORD, and printed `OVERFLOW GUARD PASS` at exit 0 — a green that
// covered one of the two legs the caller asked for, with nothing in the output
// saying so. Measured live on origin/main at 4d223c151a: two flags,
// `W13-detail-route-band — … (108 cells)` printed, `W15-fleet-row-text-bounded`
// absent from the run entirely, exit 0.
//
// COVERAGE BEFORE THIS FILE WAS ZERO, not vacuous: no test anywhere drove the
// guard's argv at all. `__app.test.mjs` read the guard's SOURCE for two other
// rows, and `seal-predicate.test.mjs` asserts a guard's exit 2 through an
// `--guard-cmd 'exit 2'` STUB that never spawns overflow-guard.mjs. So the
// pre-fix behaviour was not pinned as correct anywhere — nothing had to be
// unwound, only added.
//
// THE LOAD-BEARING ASSERTION is `two --defect flags are BOTH honoured`. Revert
// the loop in defect-selection.mjs to the `indexOf` shape and that named test
// reds with `[ 'W13…' ] !== [ 'W13…', 'W15…' ]` — it names the repetition, not a
// generic failure.
//
// THE REFUSALS ARE ASSERTED TOO, and they are the fail-closed half: this guard's
// exit 2 means REFUSED TO MEASURE and makes no claim about the CSS, so a
// refusal that stopped firing would turn a usage mistake into a silent partial
// measurement — the same defect one level down.
//
// NOT YET WIRED INTO CI as its own step: console-harness.yml enumerates each
// `node --test` file by name and `.github/` is outside this row's edit scope.
// The load-bearing case is therefore MIRRORED into `__app.test.mjs`, which the
// required `Console gate` already runs, so the assertion is live on the merge
// path today. Adding
// `- run: node --test cloud/priv/static/__preview__/defect-selection.test.mjs`
// beside the other four `__preview__` suites in the `console-unit` job is the
// one line that would bring the rest of this file onto the gate.

import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

import { DEFECT_FLAG, selectDefects } from "./defect-selection.mjs";

// Stand-in ids, deliberately NOT the guard's real ones: this module's contract
// is "whatever list you hand me", and pinning the real DEFECTS array here would
// make the suite red every time a leg is added, which is a test that fails for
// a reason that is not a defect.
const KNOWN = ["alpha-leg", "beta-leg", "gamma-leg"];

const GUARD = new URL("./overflow-guard.mjs", import.meta.url);

// ── THE ROW ─────────────────────────────────────────────────────────────────

test("two --defect flags are BOTH honoured — the second must never be silently dropped", () => {
  const sel = selectDefects([DEFECT_FLAG, "alpha-leg", DEFECT_FLAG, "gamma-leg"], KNOWN);

  assert.equal(sel.refusal, undefined,
    "a repeated --defect is a well-formed request, not an environment fault: it must not refuse");
  assert.deepEqual(sel.requested, ["alpha-leg", "gamma-leg"],
    "argv.indexOf(\"--defect\") returns the FIRST match — the pre-fix parser measured alpha-leg, " +
    "dropped gamma-leg without a word, and printed PASS. Both legs, in the order asked.");
});

test("a THIRD --defect flag is honoured too — the fix is a loop, not a special case for two", () => {
  const sel = selectDefects(
    [DEFECT_FLAG, "gamma-leg", DEFECT_FLAG, "alpha-leg", DEFECT_FLAG, "beta-leg"],
    KNOWN,
  );
  assert.deepEqual(sel.requested, ["gamma-leg", "alpha-leg", "beta-leg"]);
});

test("the SECOND flag's value is validated — a repeated flag must not smuggle an unknown id past the check", () => {
  // The pre-fix parser never looked at argv beyond the first flag, so a typo in
  // the second one was doubly invisible: not measured AND not refused.
  const sel = selectDefects([DEFECT_FLAG, "alpha-leg", DEFECT_FLAG, "delta-leg"], KNOWN);
  assert.equal(sel.requested, undefined, "a refusal makes no leg claim at all");
  assert.match(sel.refusal, /unknown --defect "delta-leg"/);
});

test("the SAME id twice is ONE leg and the repetition is stated, never dropped in silence", () => {
  const sel = selectDefects([DEFECT_FLAG, "beta-leg", DEFECT_FLAG, "beta-leg"], KNOWN);
  assert.deepEqual(sel.requested, ["beta-leg"], "one leg, measured once");
  assert.equal(sel.notes.length, 1, "the repeat is reported — the whole point of this row is that argv is never eaten quietly");
  assert.match(sel.notes[0], /beta-leg was given 2 times/);
});

// ── THE CALLERS THAT EXIST TODAY MUST NOT MOVE ──────────────────────────────

test("no --defect at all still means EVERY defect — console-harness.yml's only invocation", () => {
  const sel = selectDefects([], KNOWN);
  assert.equal(sel.refusal, undefined);
  assert.deepEqual(sel.requested, KNOWN);
  assert.notEqual(sel.requested, KNOWN, "a COPY, so a caller mutating `requested` cannot corrupt DEFECTS");
  assert.deepEqual(sel.notes, []);
});

test("a single --defect still means exactly that leg — seal-predicate.mjs's spawn shape", () => {
  const sel = selectDefects([DEFECT_FLAG, "beta-leg"], KNOWN);
  assert.equal(sel.refusal, undefined);
  assert.deepEqual(sel.requested, ["beta-leg"]);
  assert.deepEqual(sel.notes, []);
});

test("an unknown --defect refuses with the PRE-FIX WORDING, byte for byte", () => {
  // seal-predicate.mjs's doctrine block cites this refusal by name. Changing the
  // sentence would be a silent contract change for a reader of the guard's log.
  const sel = selectDefects([DEFECT_FLAG, "delta-leg"], KNOWN);
  assert.equal(sel.requested, undefined);
  assert.equal(
    sel.refusal,
    `!! GUARD (exit 2): unknown --defect "delta-leg". Known: alpha-leg, beta-leg, gamma-leg\n`,
  );
});

// ── THE SIBLING SILENT DROP, CLOSED ─────────────────────────────────────────

test("a bare id after a leg REFUSES — `--defect A B` must not drop B the way `--defect A --defect B` used to", () => {
  const sel = selectDefects([DEFECT_FLAG, "alpha-leg", "beta-leg"], KNOWN);
  assert.equal(sel.requested, undefined, "half a request is not a measurement");
  assert.match(sel.refusal, /unrecognised argument "beta-leg" at position 3/);
  assert.match(sel.refusal, /may be REPEATED/, "the refusal must teach the shape that does work");
});

test("a --defect with nothing after it REFUSES instead of resolving to undefined", () => {
  const sel = selectDefects([DEFECT_FLAG], KNOWN);
  assert.equal(sel.requested, undefined);
  assert.match(sel.refusal, /has no defect id after it \(next argument: end of arguments\)/);
});

test("a --defect immediately followed by another --defect REFUSES and names what it found", () => {
  const sel = selectDefects([DEFECT_FLAG, DEFECT_FLAG, "alpha-leg"], KNOWN);
  assert.equal(sel.requested, undefined);
  assert.match(sel.refusal, /has no defect id after it \(next argument: "--defect"\)/);
});

test("every refusal speaks this guard's exit-2 vocabulary", () => {
  const refusals = [
    selectDefects([DEFECT_FLAG, "delta-leg"], KNOWN),
    selectDefects([DEFECT_FLAG, "alpha-leg", "beta-leg"], KNOWN),
    selectDefects([DEFECT_FLAG], KNOWN),
    selectDefects(["--render"], KNOWN),
  ];
  for (const r of refusals) {
    assert.equal(r.requested, undefined);
    assert.match(r.refusal, /^!! GUARD \(exit 2\): /,
      "the caller writes this straight to stderr and exits 2 — the prefix IS the contract");
    assert.match(r.refusal, /\n$/, "one line, newline-terminated, like every other refusal in the guard");
  }
});

// ── THE GUARD MUST ACTUALLY USE THIS MODULE ─────────────────────────────────
//
// A parser nothing calls is not a fix. These two reds are what stops a future
// edit from re-inlining the buggy shape while this suite stays green.

// CODE, NOT PROSE. The guard's new comment QUOTES the deleted expression on
// purpose — that is the search vocabulary a reader greps for, and it must
// survive. So the detector reads the file with its line comments stripped;
// otherwise the doctrine that keeps the old name findable would be the thing
// defeating the check that the old name is gone.
const codeOnly = (s) => s.split("\n").filter((l) => !/^\s*\/\//.test(l)).join("\n");

test("overflow-guard.mjs no longer resolves its selection with argv.indexOf", () => {
  const guard = fs.readFileSync(GUARD, "utf8");
  const code = codeOnly(guard);
  assert.ok(!/argv\.indexOf\("--defect"\)/.test(code),
    "indexOf returns the FIRST match — that expression IS the defect this row closed");
  assert.ok(!/const requested = only \? \[only\] : DEFECTS/.test(code),
    "the single-value `only` shape cannot represent two legs and must not come back");

  // …and this detector must not be vacuous: it only means something while the
  // expression it forbids is still reachable by the regex it uses. The guard's
  // own comment is the control — the deleted shape is quoted there, so a regex
  // that has rotted into matching nothing at all reds here.
  assert.match(guard, /argv\.indexOf\("--defect"\)/,
    "the guard's comment must keep quoting the deleted expression — it is the search " +
    "vocabulary for this row, and it doubles as this test's non-vacuity control");
});

test("overflow-guard.mjs routes argv through selectDefects and honours its refusal", () => {
  const guard = fs.readFileSync(GUARD, "utf8");
  assert.match(guard, /import \{ selectDefects \} from "\.\/defect-selection\.mjs";/);
  assert.match(guard, /const selection = selectDefects\(argv, DEFECTS\);/);
  assert.match(guard, /if \(selection\.refusal\) \{\s*\n\s*process\.stderr\.write\(selection\.refusal\);\s*\n\s*process\.exit\(2\);/,
    "a refusal must still be exit 2 — this guard's exit 2 makes NO claim about the CSS, and " +
    "downgrading it to a warning would turn a usage mistake into a silent partial measurement");
  assert.match(guard, /const requested = selection\.requested;/);
});
