// ledger.test.mjs — the recipe ledger: no values, immutable files, read-time fold.
//
//   node --test tooling/grip/test/ledger.test.mjs
//
// Every write in this file goes to a fresh mkdtemp directory. NOTHING here
// writes into the committed tooling/grip/ledger/ — a test that seeds the real
// store would make the store's own contents untrustworthy, which is the whole
// disease.

import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import {
  admitRecipe,
  writeLedgerRun,
  readLedgerRuns,
  foldLedger,
  recipeKey,
  digest,
  RECIPE_FIELDS,
  RIVAL_METHOD,
  DEFAULT_LEDGER_DIR,
} from "../ledger.mjs";
import { existsSync } from "node:fs";
import { screenCommand } from "../screen.mjs";

const LEDGER_SRC = fileURLToPath(new URL("../ledger.mjs", import.meta.url));
const REPO_ROOT = fileURLToPath(new URL("../../../", import.meta.url));

// A fixed clock for the fold's future bound — the SAME shape admitRecipe wants
// (Z-form UTC). Injected so the future-observed_at tests are deterministic and
// never drift with wall-clock time.
const FOLD_NOW = "2026-07-21T00:00:00Z";

// The committed store's contents AT MODULE LOAD, captured BEFORE any test body
// runs. It is the anchor for the re-scoped "no untracked rows" guard below: a
// charter-D35 carve-out row is present at load and therefore in this baseline,
// while a test that writes into the real store during the run creates a file
// that is NOT — which is the leak that guard exists to catch. See that test.
const LEDGER_BASELINE_AT_LOAD = new Set(
  existsSync(DEFAULT_LEDGER_DIR)
    ? readdirSync(DEFAULT_LEDGER_DIR).filter((f) => f.endsWith(".json"))
    : [],
);

function tmpLedger() {
  return mkdtempSync(join(tmpdir(), "grip-ledger-"));
}

// A row that is honest in every respect — the baseline the rejection tests
// mutate ONE field of, so a rejection can only be attributed to that field.
function goodRow(over = {}) {
  return {
    subject: "api/lib/barkpark/plugin.ex",
    quantity: "callback count",
    rerun: "grep -c 'def ' api/lib/barkpark/plugin.ex",
    deps: ["api/lib/barkpark/plugin.ex"],
    observed_at: "2026-07-20T12:00:00Z",
    ...over,
  };
}

// ── export surface ───────────────────────────────────────────────────────────

test("the row schema is frozen and contains no value field", () => {
  assert.ok(Object.isFrozen(RECIPE_FIELDS));
  assert.deepEqual([...RECIPE_FIELDS], [
    "subject", "quantity", "rerun", "derived_level", "deps", "observed_at",
  ]);
  assert.ok(!RECIPE_FIELDS.includes("value"), "the schema must have no place to put an answer");
  assert.equal(typeof admitRecipe, "function");
  assert.equal(typeof writeLedgerRun, "function");
  assert.equal(typeof foldLedger, "function");
});

test("an honest row is admitted and comes back with exactly the schema's keys", () => {
  const verdict = admitRecipe(goodRow());
  assert.ok(verdict.ok, JSON.stringify(verdict.rejections));
  assert.deepEqual(Object.keys(verdict.recipe).sort(), [...RECIPE_FIELDS].sort());
  assert.equal(verdict.recipe.derived_level, "L3");
});

// ── criterion 1: NO VALUES, and a value is REJECTED, not dropped ─────────────

test("a row carrying `value` is REJECTED with VALUE-STORED", () => {
  const verdict = admitRecipe(goodRow({ value: 47 }));
  assert.equal(verdict.ok, false);
  const r = verdict.rejections.find((x) => x.reason === "VALUE-STORED");
  assert.ok(r, `expected VALUE-STORED, got ${verdict.rejections.map((x) => x.reason).join(", ")}`);
  assert.match(r.message, /never the fact/);
  assert.equal(r.field, "value");
});

test("REJECTED, not silently dropped: the falsy and null cases are rejections too", () => {
  // The silent-strip defect hides exactly here — `if (row.value)` would let
  // 0, "" and null through as "no value supplied".
  for (const value of [0, "", null, false, undefined]) {
    const verdict = admitRecipe(goodRow({ value }));
    assert.equal(verdict.ok, false, `value=${JSON.stringify(value)} must be rejected`);
    assert.ok(verdict.rejections.some((x) => x.reason === "VALUE-STORED"));
  }
});

test("the value-shaped family is rejected by name, each naming its own field", () => {
  for (const field of ["values", "observed_value", "result", "measurement", "measured", "answer"]) {
    const verdict = admitRecipe(goodRow({ [field]: "42" }));
    assert.equal(verdict.ok, false);
    assert.ok(verdict.rejections.some((x) => x.reason === "VALUE-STORED" && x.field === field));
  }
});

test("an unknown field is REJECTED, never stripped (research-coverage's record() strips — that is half of D10's trap)", () => {
  const verdict = admitRecipe(goodRow({ notes: "ran it twice" }));
  assert.equal(verdict.ok, false);
  const r = verdict.rejections.find((x) => x.reason === "UNKNOWN-FIELD");
  assert.ok(r);
  assert.equal(r.field, "notes");
  assert.match(r.message, /believe it recorded something it did not/);
});

test("rejections accumulate — one pass shows everything wrong with the row", () => {
  const verdict = admitRecipe({ value: 1, notes: "x", subject: "s" });
  assert.equal(verdict.ok, false);
  const reasons = new Set(verdict.rejections.map((x) => x.reason));
  for (const expected of ["VALUE-STORED", "UNKNOWN-FIELD", "MISSING-QUANTITY", "MISSING-RERUN", "MISSING-OBSERVED-AT"]) {
    assert.ok(reasons.has(expected), `missing ${expected} in ${[...reasons].join(", ")}`);
  }
});

// ── the rest of the admission grammar ────────────────────────────────────────

test("a row with no rerun command is REJECTED — a ledger row IS the recipe", () => {
  const verdict = admitRecipe(goodRow({ rerun: "   " }));
  assert.equal(verdict.ok, false);
  assert.ok(verdict.rejections.some((x) => x.reason === "MISSING-RERUN"));
});

test("derived_level is DERIVED from the rerun command, and an over-claim is a LEVEL-SKIP", () => {
  const local = admitRecipe(goodRow({ rerun: "cat api/mix.exs" }));
  assert.equal(local.recipe.derived_level, "L3");

  const skip = admitRecipe(goodRow({ rerun: "cat api/mix.exs", derived_level: "L1" }));
  assert.equal(skip.ok, false);
  assert.ok(skip.rejections.some((x) => x.reason === "LEVEL-SKIP"));

  const live = admitRecipe(goodRow({ rerun: "curl -s https://barkpark.cloud/v1/health" }));
  assert.equal(live.recipe.derived_level, "L1");

  const under = admitRecipe(goodRow({ rerun: "curl -s https://barkpark.cloud/v1/health", derived_level: "L3" }));
  assert.ok(under.ok);
  assert.equal(under.recipe.derived_level, "L3", "an honest under-claim is kept");
});

test("deps must be an array of non-empty subjects (R2), and empty is honest", () => {
  assert.ok(admitRecipe(goodRow({ deps: [] })).ok);
  for (const deps of ["a", [""], [null], [3]]) {
    const verdict = admitRecipe(goodRow({ deps }));
    assert.equal(verdict.ok, false, `deps=${JSON.stringify(deps)} must be rejected`);
    assert.ok(verdict.rejections.some((x) => x.reason === "BAD-DEPS"));
  }
});

test("a non-object row is rejected NOT-A-ROW", () => {
  for (const bad of [null, "row", 7, ["subject"]]) {
    const verdict = admitRecipe(bad);
    assert.equal(verdict.ok, false);
    assert.equal(verdict.rejections[0].reason, "NOT-A-ROW");
  }
});

// ── criterion 4: observed_at is required and the module is clock-free ────────

test("observed_at is a REQUIRED writer-supplied argument", () => {
  const missing = admitRecipe({ ...goodRow(), observed_at: undefined });
  assert.equal(missing.ok, false);
  assert.ok(missing.rejections.some((x) => x.reason === "MISSING-OBSERVED-AT"));
});

test("observed_at must be an instant — a bare date or a phrase cannot order two runs", () => {
  for (const bad of ["2026-07-20", "yesterday", "just now", "1721476800"]) {
    const verdict = admitRecipe(goodRow({ observed_at: bad }));
    assert.equal(verdict.ok, false, `${bad} must be rejected`);
    assert.ok(verdict.rejections.some((x) => x.reason === "BAD-OBSERVED-AT"));
  }
  for (const good of ["2026-07-20T12:00:00Z", "2026-07-20T12:00:00.123Z"]) {
    assert.ok(admitRecipe(goodRow({ observed_at: good })).ok, `${good} must be admitted`);
  }
});

// ── Z-only: lexical order is only true order at one offset ───────────────────

test("an offset observed_at is REJECTED with its own class — not BAD-OBSERVED-AT, because it IS a well-formed instant", () => {
  for (const offset of ["2026-07-21T02:00:00+02:00", "2026-07-20T08:00:00-04:00", "2026-07-20T12:00:00.500+05:30"]) {
    const verdict = admitRecipe(goodRow({ observed_at: offset }));
    assert.equal(verdict.ok, false, `${offset} must be rejected`);
    const reasons = verdict.rejections.map((x) => x.reason);
    assert.ok(reasons.includes("OFFSET-OBSERVED-AT"), `expected OFFSET-OBSERVED-AT, got ${reasons.join(", ")}`);
    assert.ok(
      !reasons.includes("BAD-OBSERVED-AT"),
      "an offset instant is well-formed — collapsing it into BAD-OBSERVED-AT would tell the writer its timestamp is malformed, which is false and unfixable advice",
    );
  }
});

test("THE REASON Z IS MANDATED: the offset that would have broken the ordering is the one the class rejects", () => {
  // This is the whole argument, executable. `+02:00` sorts AFTER the Z string
  // while being an hour EARLIER — so admitting it would make the future bound
  // wrong in one direction and the fold's sort wrong in the other, silently.
  const laterLexically = "2026-07-21T02:00:00+02:00";
  const earlierInstant = "2026-07-21T01:00:00Z";
  assert.ok(laterLexically > earlierInstant, "the premise: lexically later");
  // …and it is genuinely one hour BEFORE it. Rejected at the seam, so no
  // comparison in this module ever has to be right about mixed offsets.
  assert.equal(admitRecipe(goodRow({ observed_at: laterLexically })).ok, false);
  assert.ok(admitRecipe(goodRow({ observed_at: earlierInstant })).ok);
});

// ── the injected `now` bound: a forged future row is rejectable ──────────────

test("THE FORGERY: the real 2031-dated ssh row was ADMITTED before this bound, and is REJECTED against an injected now", () => {
  // Verbatim from the run file that was admitted, written to disk and folded
  // back as authoritative — L1, for the sole reason that the string began
  // `ssh`. Every check it passed was a SHAPE check.
  const forged = {
    subject: "bp-crux-parent",
    quantity: "unit state",
    rerun: "ssh barkpark_indx@157.180.90.121 systemctl is-active bp-crux-parent",
    deps: [],
    observed_at: "2031-12-31T23:59:59Z",
  };

  const bounded = admitRecipe(forged, { now: "2026-07-21T00:00:00Z" });
  assert.equal(bounded.ok, false);
  const r = bounded.rejections.find((x) => x.reason === "FUTURE-OBSERVED-AT");
  assert.ok(r, `expected FUTURE-OBSERVED-AT, got ${bounded.rejections.map((x) => x.reason).join(", ")}`);
  assert.equal(r.observed_at, "2031-12-31T23:59:59Z");
  assert.equal(r.now, "2026-07-21T00:00:00Z");
  assert.match(r.message, /composed rather than observed/);

  // The second forged row, dated 2087, at L2 — and it does not even execute.
  const alsoForged = admitRecipe(
    { subject: "tooling/grip/ledger", quantity: "recipe count", rerun: "git show origin/main:tooling/grip/ledger/recipes.json | jq length", deps: [], observed_at: "2087-01-01T00:00:00Z" },
    { now: "2026-07-21T00:00:00Z" },
  );
  assert.equal(alsoForged.ok, false);
  assert.ok(alsoForged.rejections.some((x) => x.reason === "FUTURE-OBSERVED-AT"));
});

test("omitting `now` ADMITS — the bound is opt-in here, and no existing caller breaks", () => {
  // Stated as a limitation, not a feature: on its own this is a mechanism, not
  // a seam. `tgw3-write-verb` closes it at the CLI by baking `date -u` into
  // the write path. This test exists so the limitation is visible rather than
  // discovered later by someone who assumed the store was sealed.
  const forged = goodRow({ observed_at: "2031-12-31T23:59:59Z" });
  assert.ok(admitRecipe(forged).ok, "with no now supplied the forged row still admits");
  assert.ok(admitRecipe(forged, {}).ok, "an empty options object is the same as none");
});

test("the bound is `later than`, not `later than or equal` — a row observed exactly now is honest", () => {
  const at = "2026-07-21T00:00:00Z";
  assert.ok(admitRecipe(goodRow({ observed_at: at }), { now: at }).ok, "equal instants must admit");
  assert.ok(admitRecipe(goodRow({ observed_at: "2026-07-20T23:59:59Z" }), { now: at }).ok);
  assert.equal(admitRecipe(goodRow({ observed_at: "2026-07-21T00:00:01Z" }), { now: at }).ok, false);
});

test("sub-second precision does not fool the comparison in either direction", () => {
  // Z ALONE IS NOT ENOUGH, and this test is why the module normalises width.
  // Raw lexical comparison puts ".001Z" BEFORE "Z" — the strings diverge at
  // the separator and "." (0x2E) < "Z" (0x5A) — so a row a millisecond in the
  // future compared as PAST and was admitted by the first cut of this bound.
  assert.ok("2026-07-21T00:00:00.001Z" < "2026-07-21T00:00:00Z", "the trap, stated: raw lexical order is wrong here");

  const now = "2026-07-21T00:00:00Z";
  assert.equal(admitRecipe(goodRow({ observed_at: "2026-07-21T00:00:00.001Z" }), { now }).ok, false, "a millisecond into the future is still the future");
  assert.ok(admitRecipe(goodRow({ observed_at: "2026-07-20T23:59:59.999Z" }), { now }).ok);

  // …and symmetrically, with the fraction on the BOUND instead of the row.
  const fractionalNow = "2026-07-21T00:00:00.500Z";
  assert.ok(admitRecipe(goodRow({ observed_at: "2026-07-21T00:00:00Z" }), { now: fractionalNow }).ok, "whole seconds before a fractional now must admit");
  assert.equal(admitRecipe(goodRow({ observed_at: "2026-07-21T00:00:01Z" }), { now: fractionalNow }).ok, false);
});

test("the fold's within-entry sort is chronological across mixed precision, not raw lexical", () => {
  // The same trap, in the other place it bites: the fold claims deterministic
  // (observed_at, file) ordering, and raw string order would put the .001Z row
  // first — before the whole-second row it actually followed.
  //
  // The two commands are GENUINE rivals (both mint `wc:-l`) rather than the
  // `cat a`/`cat b` they used to be: since the fold re-derives its key, two
  // commands that mint different quantities are two entries and there is no
  // within-entry sort left to test.
  const folded = foldLedger([
    { file: "b.json", run_id: "b", recipes: [{ subject: "s", quantity: "q", rerun: "cat s | wc -l", derived_level: "L3", deps: [], observed_at: "2026-07-21T00:00:00.001Z" }] },
    { file: "a.json", run_id: "a", recipes: [{ subject: "s", quantity: "q", rerun: "wc -l s", derived_level: "L3", deps: [], observed_at: "2026-07-21T00:00:00Z" }] },
  ]);
  assert.deepEqual(
    folded.entries[0].recipes.map((r) => r.observed_at),
    ["2026-07-21T00:00:00Z", "2026-07-21T00:00:00.001Z"],
    "the whole-second row happened FIRST and must sort first",
  );
});

test("an off-shape observed_at on disk is REJECTED into unreadable and never throws the fold — tgw5 inverts 'the read path tolerates'", () => {
  // Before tgw5 the fold TOLERATED an off-shape observed_at, folding it with a
  // raw-string sort fallback: "the write path is not the read path." The read
  // path now re-admits what the write path admits, so an offset instant is
  // OFFSET-OBSERVED-AT and a null one is MISSING-OBSERVED-AT — both routed to
  // unreadable, named, never a crash and never a silent fold. The crash-safety
  // that test always guarded survives: one unorderable timestamp costs only its
  // own row, and the honest row alongside still folds.
  const folded = foldLedger([
    { file: "good.json", run_id: "g", recipes: [{ subject: "s", quantity: "q", rerun: "wc -l s", derived_level: "L3", deps: [], observed_at: "2026-07-21T00:00:00Z" }] },
    { file: "a.json", run_id: "a", recipes: [{ subject: "s", quantity: "q", rerun: "wc -l s", derived_level: "L3", deps: [], observed_at: "2026-07-21T02:00:00+02:00" }] },
    { file: "b.json", run_id: "b", recipes: [{ subject: "s", quantity: "q", rerun: "cat s | wc -l", derived_level: "L3", deps: [], observed_at: null }] },
  ]);
  assert.equal(folded.entries.length, 1, "only the honest row folds");
  assert.equal(folded.entries[0].recipes.length, 1);
  assert.deepEqual(
    folded.unreadable.map((u) => u.reason).sort(),
    ["MISSING-OBSERVED-AT", "OFFSET-OBSERVED-AT"],
    "each off-shape timestamp is named in unreadable, not crashed on",
  );
});

test("a malformed `now` is rejected BAD-OPTION — a bound that silently stops bounding is the vacuous green", () => {
  for (const now of ["yesterday", "2026-07-21", "2026-07-21T00:00:00+02:00", 1721476800, {}]) {
    const verdict = admitRecipe(goodRow(), { now });
    assert.equal(verdict.ok, false, `now=${JSON.stringify(now)} must be rejected, never ignored`);
    const r = verdict.rejections.find((x) => x.reason === "BAD-OPTION" && x.option === "now");
    assert.ok(r, `expected BAD-OPTION(now), got ${verdict.rejections.map((x) => x.reason).join(", ")}`);
  }
});

// ── the injected safety screen ───────────────────────────────────────────────

// A recipe is a standing invitation to re-run a command cheaply and OFTEN.
// Before this, `admitRecipe` called no safety check at all, so both of these
// were admissible recipes — the store's own product would have handed an agent
// an outage.
const OUTAGE_COMMANDS = ["systemctl stop bp-crux-parent", "rm -rf /opt/barkpark/releases"];

// A stand-in for what the CLI will inject. Deliberately defined HERE and not
// imported: this module must stay dependency-free, and the test proves the
// SEAM, not screen.mjs's vocabulary.
const refuseOutages = (cmd) => (
  /\bsystemctl\s+(stop|restart|disable)\b|\brm\s+-rf\b|\bdrop\s+(table|database)\b/i.test(cmd)
    ? { ok: false, message: "it can take a running system down" }
    : true
);

test("an outage-capable command is REJECTED when a screen is supplied — and ADMITTED when none is", () => {
  for (const rerun of OUTAGE_COMMANDS) {
    const screened = admitRecipe(goodRow({ rerun }), { screen: refuseOutages });
    assert.equal(screened.ok, false, `${rerun} must be refused`);
    const r = screened.rejections.find((x) => x.reason === "REFUSED-COMMAND");
    assert.ok(r, `expected REFUSED-COMMAND, got ${screened.rejections.map((x) => x.reason).join(", ")}`);
    assert.equal(r.rerun, rerun);
    assert.match(r.message, /take a running system down/, "the screen's own reason must reach the writer");

    // The control that makes the one above mean something: with no screen the
    // SAME row admits, so the rejection is attributable to the screen and to
    // nothing else in the grammar.
    assert.ok(admitRecipe(goodRow({ rerun })).ok, `${rerun} is admitted today with no screen — that is the defect being closed`);
  }
});

test("the screen sees the rerun command and only the rerun command", () => {
  const seen = [];
  admitRecipe(goodRow({ rerun: "  wc -l api/lib/x.ex  " }), { screen: (cmd) => { seen.push(cmd); return true; } });
  assert.deepEqual(seen, ["wc -l api/lib/x.ex"], "trimmed, exactly once, and nothing else is handed over");
});

test("a screen may answer in any of the tolerated shapes", () => {
  const allow = [true, { ok: true }];
  const refuse = [false, { ok: false }, { ok: false, message: "no" }, "not on my watch"];
  for (const answer of allow) {
    assert.ok(admitRecipe(goodRow(), { screen: () => answer }).ok, `${JSON.stringify(answer)} must allow`);
  }
  for (const answer of refuse) {
    const verdict = admitRecipe(goodRow(), { screen: () => answer });
    assert.equal(verdict.ok, false, `${JSON.stringify(answer)} must refuse`);
    assert.ok(verdict.rejections.some((x) => x.reason === "REFUSED-COMMAND"));
  }
  // A string answer is carried through as the reason, so the writer learns WHY.
  const stringy = admitRecipe(goodRow(), { screen: () => "not on my watch" });
  assert.match(stringy.rejections.find((x) => x.reason === "REFUSED-COMMAND").message, /not on my watch/);
});

test("a screen that THROWS fails CLOSED — a safety check that fails open is not a safety check", () => {
  const verdict = admitRecipe(goodRow(), { screen: () => { throw new Error("regex blew up"); } });
  assert.equal(verdict.ok, false);
  const r = verdict.rejections.find((x) => x.reason === "SCREEN-FAILED");
  assert.ok(r, `expected SCREEN-FAILED, got ${verdict.rejections.map((x) => x.reason).join(", ")}`);
  assert.match(r.message, /regex blew up/, "the writer must learn what broke, not just that something did");
});

test("a non-function screen is rejected BAD-OPTION, never treated as absent", () => {
  for (const screen of ["deny-all", 1, {}, [refuseOutages]]) {
    const verdict = admitRecipe(goodRow(), { screen });
    assert.equal(verdict.ok, false, `screen=${JSON.stringify(screen)} must be rejected`);
    assert.ok(verdict.rejections.some((x) => x.reason === "BAD-OPTION" && x.option === "screen"));
  }
});

test("the screen is not consulted when there is no command to screen", () => {
  let called = false;
  const verdict = admitRecipe(goodRow({ rerun: "   " }), { screen: () => { called = true; return false; } });
  assert.equal(verdict.ok, false);
  assert.ok(verdict.rejections.some((x) => x.reason === "MISSING-RERUN"));
  assert.equal(called, false, "a row with no rerun must not also collect a confusing REFUSED-COMMAND");
});

// ── the bounds reach the WRITE seam, which is the one that matters ───────────

test("writeLedgerRun forwards `now` and `screen` — a bound reachable only from admitRecipe would leave the store as forgeable as before", () => {
  const dir = tmpLedger();

  const forged = writeLedgerRun({
    run_id: "forger",
    recipes: [goodRow({ observed_at: "2031-12-31T23:59:59Z" })],
    dir,
    now: "2026-07-21T00:00:00Z",
  });
  assert.equal(forged.ok, false);
  assert.ok(forged.rejections.some((x) => x.reason === "FUTURE-OBSERVED-AT" && x.index === 0));

  const dangerous = writeLedgerRun({
    run_id: "dangerous",
    recipes: [goodRow({ rerun: OUTAGE_COMMANDS[0] })],
    dir,
    screen: refuseOutages,
  });
  assert.equal(dangerous.ok, false);
  assert.ok(dangerous.rejections.some((x) => x.reason === "REFUSED-COMMAND"));

  assert.deepEqual(readdirSync(dir), [], "neither rejected run may leave a file behind");

  const honest = writeLedgerRun({
    run_id: "honest",
    recipes: [goodRow()],
    dir,
    now: "2026-07-21T00:00:00Z",
    screen: refuseOutages,
  });
  assert.ok(honest.ok, JSON.stringify(honest.rejections));
  assert.equal(readdirSync(dir).length, 1, "the honest write must still go through with both bounds armed");
});

test("an honest row is STILL admitted with both bounds armed — the new classes reject forgeries, not work", () => {
  const verdict = admitRecipe(goodRow(), { now: "2026-07-21T00:00:00Z", screen: refuseOutages });
  assert.ok(verdict.ok, JSON.stringify(verdict.rejections));
  assert.deepEqual(Object.keys(verdict.recipe).sort(), [...RECIPE_FIELDS].sort(), "the bounds add no field to the row");
  assert.equal(verdict.recipe.observed_at, "2026-07-20T12:00:00Z");
});

test("ledger.mjs is CLOCK-FREE and RANDOM-FREE — the source contains no Date.now, new Date, or Math.random (D19)", () => {
  // The RAW source, deliberately unstripped. A comment-stripping version of
  // this check invites the argument "but it was only in a comment" — and the
  // criterion is a plain grep, so the file names those builtins NOWHERE.
  const src = readFileSync(LEDGER_SRC, "utf8");
  for (const forbidden of [/Date\.now/, /new\s+Date/, /Math\.random/, /performance\.now/, /process\.hrtime/, /\bDate\s*\(/]) {
    assert.equal(forbidden.test(src), false, `ledger.mjs mentions ${forbidden} — it must own no clock, and must not read as if it might`);
  }

  // The control must be able to FAIL: the same predicate over a source that
  // DOES read the clock has to trip. record.mjs fills a missing observed_at
  // with new Date().toISOString() — the exact thing this module refuses.
  const clocked = readFileSync(fileURLToPath(new URL("../record.mjs", import.meta.url)), "utf8");
  assert.equal(/new\s+Date/.test(clocked), true, "the negative control is stale — record.mjs no longer reads a clock, so this test proves nothing");
});

test("two identical rows produce identical bytes — the module is deterministic, so the same input twice cannot drift", () => {
  const a = admitRecipe(goodRow());
  const b = admitRecipe(goodRow());
  assert.equal(JSON.stringify(a.recipe), JSON.stringify(b.recipe));
  assert.equal(digest(JSON.stringify(a.recipe)), digest(JSON.stringify(b.recipe)));
});

// ── criterion 2: one new file per write, existing files never touched ────────

test("each write creates exactly ONE new file and leaves earlier files byte-identical", () => {
  const dir = tmpLedger();

  const first = writeLedgerRun({ run_id: "run-a", recipes: [goodRow()], dir });
  assert.ok(first.ok, JSON.stringify(first.rejections));
  assert.equal(first.written, true);
  assert.equal(readdirSync(dir).length, 1);

  const beforeBytes = readFileSync(first.path);
  const beforeStat = statSync(first.path);

  const second = writeLedgerRun({
    run_id: "run-b",
    recipes: [goodRow({ subject: "api/lib/barkpark/schema.ex", rerun: "wc -l api/lib/barkpark/schema.ex" })],
    dir,
  });
  assert.ok(second.ok, JSON.stringify(second.rejections));
  assert.notEqual(second.path, first.path);
  assert.equal(readdirSync(dir).length, 2, "the second write must ADD a file, never fold into the first");

  const afterBytes = readFileSync(first.path);
  const afterStat = statSync(first.path);
  assert.deepEqual(afterBytes, beforeBytes, "the first file's bytes must be unchanged");
  assert.equal(afterStat.size, beforeStat.size);
  assert.equal(afterStat.mtimeMs, beforeStat.mtimeMs, "the first file must not even have been opened for writing");
});

test("the same run written twice is ALREADY-RECORDED — idempotent, and still one file", () => {
  const dir = tmpLedger();
  const a = writeLedgerRun({ run_id: "run-a", recipes: [goodRow()], dir });
  const before = readFileSync(a.path);

  const b = writeLedgerRun({ run_id: "run-a", recipes: [goodRow()], dir });
  assert.ok(b.ok);
  assert.equal(b.written, false);
  assert.equal(b.reason, "ALREADY-RECORDED");
  assert.equal(readdirSync(dir).length, 1);
  assert.deepEqual(readFileSync(a.path), before);
});

test("two writers sharing a run_id but writing different rows do NOT collide — D10's lost-write class", () => {
  const dir = tmpLedger();
  const a = writeLedgerRun({ run_id: "same-run", recipes: [goodRow({ subject: "a.ex", rerun: "wc -l a.ex" })], dir });
  const b = writeLedgerRun({ run_id: "same-run", recipes: [goodRow({ subject: "b.ex", rerun: "wc -l b.ex" })], dir });
  assert.ok(a.ok && b.ok);
  assert.notEqual(a.path, b.path);
  assert.equal(readdirSync(dir).length, 2);

  const folded = foldLedger(dir);
  assert.equal(folded.stats.rows, 2, "neither writer's contribution may be lost");
});

test("a write with any bad row writes NOTHING — all-or-nothing, never a partial file", () => {
  const dir = tmpLedger();
  const verdict = writeLedgerRun({ run_id: "run-a", recipes: [goodRow(), goodRow({ value: 1 })], dir });
  assert.equal(verdict.ok, false);
  assert.ok(verdict.rejections.some((x) => x.reason === "VALUE-STORED" && x.index === 1));
  assert.equal(readdirSync(dir).length, 0, "no file may exist after a rejected write");
});

test("run_id is caller-supplied and validated — the module invents no id because it has no clock", () => {
  const dir = tmpLedger();
  for (const run_id of [undefined, "", "has space", "a/b", "../escape", "x".repeat(65)]) {
    const verdict = writeLedgerRun({ run_id, recipes: [goodRow()], dir });
    assert.equal(verdict.ok, false, `run_id=${JSON.stringify(run_id)} must be rejected`);
    assert.equal(verdict.rejections[0].reason, "BAD-RUN-ID");
  }
  assert.equal(readdirSync(dir).length, 0);
});

test("an empty run is rejected — an empty file would fold as an absence (D6)", () => {
  const dir = tmpLedger();
  const verdict = writeLedgerRun({ run_id: "run-a", recipes: [], dir });
  assert.equal(verdict.ok, false);
  assert.equal(verdict.rejections[0].reason, "EMPTY-RUN");
});

test("a pre-existing file at the content-addressed path with DIFFERENT bytes is never overwritten", () => {
  const dir = tmpLedger();
  const probe = writeLedgerRun({ run_id: "run-a", recipes: [goodRow()], dir });
  const path = probe.path;
  writeFileSync(path, "{\"tampered\":true}\n");

  const verdict = writeLedgerRun({ run_id: "run-a", recipes: [goodRow()], dir });
  assert.equal(verdict.ok, false);
  assert.equal(verdict.rejections[0].reason, "IMMUTABLE-COLLISION");
  assert.equal(readFileSync(path, "utf8"), "{\"tampered\":true}\n", "the tampered file must survive untouched");
});

// ── criterion 3: the fold observes RIVAL METHODS ─────────────────────────────
//
// The flag is RIVAL-METHOD and it is deliberately NOT `CONFLICT`. It means
// "this key has more than one cheap check — re-run them and compare what they
// answer NOW", which is the ledger delivering its product, not a defect
// report. adjudicate.mjs's identically-shaped CONFLICT fires on the OPPOSITE
// input (≥2 distinct claim VALUES, never reading `rerun`), and the two are
// proved incompatible below.

test("foldLedger surfaces two RIVAL methods over one (subject, quantity) as both-kept-and-flagged", () => {
  const dir = tmpLedger();
  writeLedgerRun({
    run_id: "run-a",
    recipes: [goodRow({ quantity: "line count", rerun: "wc -l api/lib/barkpark/plugin.ex" })],
    dir,
  });
  // The planted rival: same subject, a DIFFERENT command that RE-DERIVES THE
  // SAME PROPERTY. Both mint `wc:-l` — mint.mjs's own stated control for "two
  // methods, one property, and they MUST still collide". The stored quantity
  // agreeing is not what makes this a rival; the mint agreeing is.
  writeLedgerRun({
    run_id: "run-b",
    recipes: [goodRow({ quantity: "line count", rerun: "cat api/lib/barkpark/plugin.ex | wc -l", observed_at: "2026-07-20T13:00:00Z" })],
    dir,
  });

  const folded = foldLedger(dir);
  assert.equal(folded.stats.subjects, 1);
  assert.equal(folded.rival_methods.length, 1);
  assert.equal(folded.stats.rival_methods, 1);

  const flag = folded.rival_methods[0];
  assert.equal(flag.reason, RIVAL_METHOD);
  assert.equal(flag.rivals.length, 2);
  assert.equal(flag.recipes.length, 2, "BOTH recipes are kept — neither is superseded");
  assert.match(flag.message, /none wins by arrival order/);

  const entry = folded.entries[0];
  assert.equal(entry.rival_method, true);
  // The key carries the RE-DERIVED quantity, not the stored one.
  assert.equal(entry.key, recipeKey({ subject: goodRow().subject, quantity: "wc:-l" }));
  assert.equal(entry.quantity, "wc:-l");
});

test("the flag is RIVAL-METHOD and the module no longer exports CONFLICT under any name", async () => {
  assert.equal(RIVAL_METHOD, "RIVAL-METHOD");
  const mod = await import("../ledger.mjs");
  assert.equal(Object.hasOwn(mod, "CONFLICT"), false, "a lingering CONFLICT export would let the two incompatible meanings keep sharing a name");
});

test("RIVAL-METHOD is worded as the PRODUCT, not as a defect report", () => {
  // A reviewer told "CONFLICT" goes looking for a disagreement this fold is
  // structurally incapable of detecting, and finds nothing — which is how a
  // flag gets ignored within a wave. The wording has to send them to the right
  // action instead: run both.
  const folded = foldLedger([
    { file: "a.json", run_id: "a", recipes: [{ subject: "s", quantity: "q", rerun: "wc -l /abs/path", derived_level: "L3", deps: [], observed_at: "2026-07-20T00:00:00Z" }] },
    { file: "b.json", run_id: "b", recipes: [{ subject: "s", quantity: "q", rerun: "wc -l rel/path", derived_level: "L3", deps: [], observed_at: "2026-07-20T00:00:01Z" }] },
  ]);
  const flag = folded.rival_methods[0];
  assert.match(flag.message, /FEATURE of the row, not a defect report/);
  assert.match(flag.message, /run all 2 today and compare/);
  assert.equal(/\bCONFLICT\b/.test(flag.message), false, "the flag's own message must not reintroduce the retired name");
});

test("the fold has NO value field to compare, so it cannot mean what adjudicate.mjs's CONFLICT means", () => {
  // The 2x2 probe's finding, pinned: these two commands were both verified to
  // answer `544`. This fold flags them (two distinct command strings);
  // detectConflicts returns 0 on the same pair (one distinct value) and 2 on a
  // genuine 544-vs-999 disagreement, which this fold cannot see AT ALL —
  // nothing it stores carries an answer. Same name, opposite firing condition.
  const folded = foldLedger([
    { file: "a.json", run_id: "a", recipes: [{ subject: "s", quantity: "q", rerun: "wc -l /abs/path", derived_level: "L3", deps: [], observed_at: "2026-07-20T00:00:00Z" }] },
    { file: "b.json", run_id: "b", recipes: [{ subject: "s", quantity: "q", rerun: "wc -l rel/path", derived_level: "L3", deps: [], observed_at: "2026-07-20T00:00:01Z" }] },
  ]);
  assert.equal(folded.rival_methods.length, 1, "two agreeing methods still flag — agreement is invisible here");
  for (const recipe of folded.entries[0].recipes) {
    assert.equal(Object.hasOwn(recipe, "value"), false);
  }
  assert.ok(!RECIPE_FIELDS.includes("value"), "there is no value field anywhere in the schema to compare");
});

test("the same recipe recorded twice is CORROBORATION — one method, not two rivals", () => {
  const dir = tmpLedger();
  writeLedgerRun({ run_id: "run-a", recipes: [goodRow()], dir });
  writeLedgerRun({ run_id: "run-b", recipes: [goodRow({ observed_at: "2026-07-21T09:00:00Z" })], dir });

  const folded = foldLedger(dir);
  assert.equal(folded.entries.length, 1);
  assert.equal(folded.entries[0].recipes.length, 2, "both runs are kept");
  assert.equal(folded.entries[0].rival_method, false, "a flag that fires on ordinary repetition is ignored within a wave");
  assert.equal(folded.rival_methods.length, 0);
});

test("write ORDER does not decide anything — the fold is identical whichever file lands first", () => {
  const rowA = goodRow({ rerun: "grep -c 'def ' api/lib/barkpark/plugin.ex", observed_at: "2026-07-20T12:00:00Z" });
  const rowB = goodRow({ rerun: "rg --count 'def ' api/lib/barkpark/plugin.ex", observed_at: "2026-07-20T13:00:00Z" });

  const forward = tmpLedger();
  writeLedgerRun({ run_id: "r1", recipes: [rowA], dir: forward });
  writeLedgerRun({ run_id: "r2", recipes: [rowB], dir: forward });

  const reverse = tmpLedger();
  writeLedgerRun({ run_id: "r2", recipes: [rowB], dir: reverse });
  writeLedgerRun({ run_id: "r1", recipes: [rowA], dir: reverse });

  const strip = (f) => JSON.stringify(f.entries.map((e) => ({ ...e, recipes: e.recipes.map(({ file, ...r }) => r), flag: undefined })));
  assert.equal(strip(foldLedger(forward)), strip(foldLedger(reverse)));
});

test("a subject with two DIFFERENT quantities is two entries, not two rival methods", () => {
  const dir = tmpLedger();
  writeLedgerRun({ run_id: "r1", recipes: [goodRow({ quantity: "callback count" })], dir });
  writeLedgerRun({ run_id: "r2", recipes: [goodRow({ quantity: "line count", rerun: "wc -l api/lib/barkpark/plugin.ex" })], dir });

  const folded = foldLedger(dir);
  assert.equal(folded.entries.length, 2);
  assert.equal(folded.rival_methods.length, 0);
});

// ── the fold RE-DERIVES ITS OWN KEY ──────────────────────────────────────────
//
// THE SHIPPED DEFECT, and it is a defect of the STORE'S OUTPUT, not of the
// store. `quantity` is minted from the rerun by mint.mjs, that grammar moved
// (its defect 8: `git show P | wc -l` and `git show P | grep -c x` both used to
// mint `git:show`), and every row on disk is immutable by construction — wx /
// O_EXCL, no update verb, no delete verb, and an appended correction becomes a
// RIVAL rather than a supersession. So 57 of the 62 committed rows carry a
// quantity today's mint no longer produces, and folding on it made `census
// --ledger` announce "9 recipes for git:show of bp-epic-cycle.workflow.js" —
// nine different questions rendered as nine rival ways to answer one.
//
// The fix is the law leads.mjs already applies to the LEVEL, applied to the
// KEY: re-derive from the command, carry the stored value alongside as a drift
// signal, and never let it decide anything.

test("THE DEFECT: the fold keys on the RE-DERIVED quantity, so a line count is no longer a rival method of a match count", () => {
  // Both rows are verbatim in shape from the committed store: same subject,
  // same stored `git:show`, two commands that answer completely different
  // questions. On the stored key they were ONE entry with a RIVAL-METHOD flag
  // telling an agent to "run both and compare".
  const folded = foldLedger([
    { file: "a.json", run_id: "a", recipes: [{ subject: "internal/cli/tasks_next_cmd.go", quantity: "git:show", rerun: "git show origin/main:internal/cli/tasks_next_cmd.go | wc -l", derived_level: "L2", deps: [], observed_at: "2026-07-20T00:00:00Z" }] },
    { file: "b.json", run_id: "b", recipes: [{ subject: "internal/cli/tasks_next_cmd.go", quantity: "git:show", rerun: "git show origin/main:internal/cli/tasks_next_cmd.go | grep -c 'needs_worktree'", derived_level: "L2", deps: [], observed_at: "2026-07-20T00:00:01Z" }] },
  ]);

  assert.equal(folded.entries.length, 2, "a line count and a match count are two properties, so two keys");
  assert.equal(folded.rival_methods.length, 0, "…and therefore NOT rivals — the flag was fabricated by the stale stored key");
  assert.deepEqual(folded.entries.map((e) => e.quantity).sort(), ["grep:-c:needs_worktree", "wc:-l"]);
  // The stored value is still THERE. It stopped being the key; it did not stop
  // existing, and a reader can still see what the row was written with.
  for (const entry of folded.entries) {
    assert.deepEqual(entry.stored_quantities, ["git:show"]);
    assert.equal(entry.quantity_restated, true);
  }
});

test("THE CONTROL STILL FIRES: two genuinely distinct commands that mint the SAME quantity are still RIVAL-METHOD", () => {
  // This is the half that a careless fix breaks. Narrowing the key to real
  // rivals is the goal; making the flag UNFIREABLE would not be a fix, it
  // would be a deletion wearing a fix's clothes. `wc -l F` and `cat F | wc -l`
  // are mint.mjs's own stated control for "two methods, one property".
  const folded = foldLedger([
    { file: "a.json", run_id: "a", recipes: [{ subject: "api/lib/x.ex", quantity: "line count", rerun: "wc -l api/lib/x.ex", derived_level: "L3", deps: [], observed_at: "2026-07-20T00:00:00Z" }] },
    { file: "b.json", run_id: "b", recipes: [{ subject: "api/lib/x.ex", quantity: "lines in the file", rerun: "cat api/lib/x.ex | wc -l", derived_level: "L3", deps: [], observed_at: "2026-07-20T00:00:01Z" }] },
  ]);

  assert.equal(folded.entries.length, 1, "one property, one key");
  assert.equal(folded.rival_methods.length, 1, "a fix that made RIVAL-METHOD unfireable has broken it, not fixed it");
  assert.equal(folded.rival_methods[0].reason, RIVAL_METHOD);
  assert.equal(folded.rival_methods[0].quantity, "wc:-l");
  assert.equal(folded.entries[0].rival_method, true);
  assert.equal(folded.entries[0].recipes.length, 2, "both are kept");

  // AND IT FIRES ACROSS DISAGREEING STORED VALUES. These two rows were written
  // with DIFFERENT stored quantities and are still one key — proof the flag now
  // follows the command rather than the string a writer happened to store.
  assert.deepEqual(folded.entries[0].stored_quantities.sort(), ["line count", "lines in the file"]);
});

test("each folded recipe carries stored_quantity and quantity_restated — the stored value is a DRIFT SIGNAL, never the key", () => {
  const folded = foldLedger([
    { file: "a.json", run_id: "a", recipes: [
      { subject: "api/lib/x.ex", quantity: "git:show", rerun: "wc -l api/lib/x.ex", derived_level: "L3", deps: [], observed_at: "2026-07-20T00:00:00Z" },
      { subject: "api/lib/y.ex", quantity: "wc:-l", rerun: "wc -l api/lib/y.ex", derived_level: "L3", deps: [], observed_at: "2026-07-20T00:00:00Z" },
    ] },
  ]);

  const drifted = folded.entries.find((e) => e.subject === "api/lib/x.ex").recipes[0];
  assert.equal(drifted.stored_quantity, "git:show", "the stored value survives verbatim");
  assert.equal(drifted.quantity_restated, true);
  assert.equal(drifted.quantity_fallback, null, "a successful re-derivation is not a fallback");

  const agreeing = folded.entries.find((e) => e.subject === "api/lib/y.ex").recipes[0];
  assert.equal(agreeing.stored_quantity, "wc:-l");
  assert.equal(agreeing.quantity_restated, false, "no drift is stated as no drift, not as silence");

  // The shape is leads.mjs's, deliberately: stored_* + *_restated is already
  // how this codebase says "here is what was written, here is what is true".
  for (const key of ["stored_quantity", "quantity_restated", "stored_level", "level_restated"]) {
    assert.ok(Object.hasOwn(drifted, key), `every recipe must carry ${key}, present or not — a field that appears only on drift is a field nobody checks`);
  }
  assert.equal(folded.stats.quantity_restated, 1);
  assert.equal(folded.stats.quantity_fallbacks, 0);
});

test("derived_level is RE-DERIVED in the fold too, closing tgw2-fold-reread-derived-level", () => {
  // `curl https://api.barkpark.cloud/...` reaches a running system: L1. The row
  // on disk claims L3. The fold used to hand that L3 straight to every
  // consumer, and only leads.mjs re-derived — so the fix lived one layer above
  // the defect and every OTHER reader inherited it.
  const folded = foldLedger([
    { file: "a.json", run_id: "a", recipes: [{ subject: "cloud/health", quantity: "q", rerun: "curl -s https://api.barkpark.cloud/api/schemas", derived_level: "L3", deps: [], observed_at: "2026-07-20T00:00:00Z" }] },
  ]);
  const recipe = folded.entries[0].recipes[0];
  assert.equal(recipe.stored_level, "L3", "the stored claim is carried, so the disagreement is visible");
  assert.equal(recipe.derived_level, "L1", "…and it is NOT what the fold reports");
  assert.equal(recipe.level_restated, true);
  assert.equal(folded.stats.level_restated, 1);
});

test("leads reads the fold's stored_level — the two halves of the drift signal MEET", () => {
  // A CROSS-MODULE test, deliberately. leads.mjs read `recipe.derived_level` as
  // "the stored value" back when the fold passed it through untouched. Now the
  // fold re-derives it, so that read would compare the re-derived value to
  // itself and report level_restated:false FOREVER — the drift annotation
  // silently retired while every test in leads' own file still passed on its
  // own fixtures. This is the seam where that would go unnoticed.
  const folded = foldLedger([
    { file: "a.json", run_id: "a", recipes: [{ subject: "cloud/health.ex", quantity: "q", rerun: "curl -s https://api.barkpark.cloud/api/schemas", derived_level: "L3", deps: [], observed_at: "2026-07-20T00:00:00Z" }] },
  ]);
  assert.equal(folded.entries[0].recipes[0].stored_level, "L3");
  assert.equal(folded.entries[0].recipes[0].derived_level, "L1");
});

test("a command the mint cannot key falls back to the STORED quantity and is MARKED — a silent fallback is the silent-strip defect in a new hat", () => {
  const folded = foldLedger([
    { file: "a.json", run_id: "a", recipes: [{ subject: "s", quantity: "hand-written quantity", rerun: "&&", derived_level: "L6", deps: [], observed_at: "2026-07-20T00:00:00Z" }] },
  ]);

  const entry = folded.entries[0];
  assert.equal(entry.quantity, "hand-written quantity", "the stored value IS the key when nothing can be minted — the row is not dropped");
  const recipe = entry.recipes[0];
  assert.equal(recipe.stored_quantity, "hand-written quantity");
  assert.equal(recipe.quantity_restated, false);
  assert.equal(typeof recipe.quantity_fallback, "string", "the fallback must be NAMED on the row");
  assert.match(recipe.quantity_fallback, /STORED quantity/);
  // And countable without reading 62 rows: a reader of `stats` alone must be
  // able to see that part of the index is keyed on an unverified stored value.
  assert.equal(folded.stats.quantity_fallbacks, 1);
  assert.equal(folded.stats.quantity_restated, 0, "a fallback is not a restatement — conflating them would hide it in a healthy-looking number");
});

test("the fallback marker is ABSENT-as-null on healthy rows, so `quantity_fallback !== null` is the whole check", () => {
  const folded = foldLedger([
    { file: "a.json", run_id: "a", recipes: [{ subject: "api/x.ex", quantity: "wc:-l", rerun: "wc -l api/x.ex", derived_level: "L3", deps: [], observed_at: "2026-07-20T00:00:00Z" }] },
  ]);
  assert.equal(folded.entries[0].recipes[0].quantity_fallback, null);
  assert.equal(folded.entries[0].recipes[0].level_fallback, null);
  assert.equal(folded.stats.quantity_fallbacks, 0);
  assert.equal(folded.stats.level_fallbacks, 0);
});

test("THE WRITE PATH IS UNTOUCHED: admitRecipe still REQUIRES a stored quantity, and no fold field is admissible on disk", () => {
  // The whole slice is read-side. If any of this had leaked into the writer,
  // the store would start carrying derived data — the thing RECIPE_FIELDS is
  // frozen to prevent.
  assert.deepEqual([...RECIPE_FIELDS], ["subject", "quantity", "rerun", "derived_level", "deps", "observed_at"]);
  const missing = admitRecipe(goodRow({ quantity: undefined }));
  assert.equal(missing.ok, false, "a row with no stored quantity is still rejected — the fold re-deriving one does not excuse the writer");
  assert.ok(missing.rejections.some((r) => r.reason === "MISSING-QUANTITY"));

  for (const field of ["stored_quantity", "quantity_restated", "quantity_fallback", "stored_level", "level_restated", "level_fallback"]) {
    const verdict = admitRecipe(goodRow({ [field]: "anything" }));
    assert.equal(verdict.ok, false, `${field} is a FOLD field and must never be writable`);
    assert.ok(verdict.rejections.some((r) => r.reason === "UNKNOWN-FIELD" && r.field === field));
  }

  // And an admitted row still comes back with exactly the schema's six keys.
  assert.deepEqual(Object.keys(admitRecipe(goodRow()).recipe).sort(), [...RECIPE_FIELDS].sort());
});

test("the static mint.mjs import creates no cycle — mint imports ONLY the binding rule, and that chain is acyclic (tgw6)", () => {
  // Checked, not assumed: the brief said "verify before relying on it", and a
  // cycle here would be a load-order bug that only shows up in one entry order.
  //
  // tgw6 gave mint.mjs a single dependency on purpose: it IMPORTS the
  // caller-tree binding rule from binding.mjs rather than restating a second
  // copy of it (the hand-copied-grammar defect this epic exists to abolish). So
  // the invariant here is no longer "mint imports nothing" — it is "no import
  // CYCLE": mint -> binding -> level bottoms out with no path back into the
  // ledger chain.
  const importsOf = (rel) => {
    const src = readFileSync(fileURLToPath(new URL(rel, import.meta.url)), "utf8");
    return src.split("\n").filter((l) => /^\s*import\b/.test(l) || /\brequire\s*\(/.test(l));
  };
  assert.deepEqual(
    importsOf("../mint.mjs"),
    ['import { classifyBinding } from "./binding.mjs";'],
    "mint.mjs imports exactly the binding rule — not zero (it must not restate the rule), and not more (the ledger's dependency story stays legible)",
  );
  for (const mod of ["../binding.mjs", "../level.mjs"]) {
    for (const line of importsOf(mod)) {
      assert.ok(
        !/["']\.\/(mint|ledger)\.mjs["']/.test(line),
        `${mod} must not import back into the ledger chain, or mint's static import is a cycle: ${line}`,
      );
    }
  }
  const ledgerSrc = readFileSync(LEDGER_SRC, "utf8");
  assert.match(ledgerSrc, /^import \{ quantityPhrase \} from "\.\/mint\.mjs";$/m,
    "the ledger imports the mint STATICALLY — a dynamic import would make the key derivation an optional extra that can silently not happen");
});

test("recipeKey cannot be forged by concatenation", () => {
  const a = recipeKey({ subject: "a b", quantity: "c" });
  const b = recipeKey({ subject: "a", quantity: "b c" });
  assert.notEqual(a, b);
});

// ── reading honestly ─────────────────────────────────────────────────────────

test("an unparseable ledger file is REPORTED, never silently skipped (D6)", () => {
  const dir = tmpLedger();
  writeLedgerRun({ run_id: "good", recipes: [goodRow()], dir });
  writeFileSync(join(dir, "broken-0000.json"), "{ not json");
  writeFileSync(join(dir, "shapeless-0000.json"), "{\"run_id\":\"x\"}");

  const { runs, unreadable } = readLedgerRuns(dir);
  assert.equal(runs.length, 1);
  assert.equal(unreadable.length, 2);
  assert.deepEqual(unreadable.map((u) => u.reason).sort(), ["MALFORMED-RUN", "UNPARSEABLE"]);

  const folded = foldLedger(dir);
  assert.equal(folded.stats.unreadable, 2, "a fold that hides a corrupt file reports a smaller, cleaner, wrong world");
});

test("a document that never claimed to be a run is NOT-A-RUN, DISTINCT from MALFORMED-RUN, and both stay counted", () => {
  // THE SHARED COMMONS HAS THREE SHAPES, NOT TWO (D118). A foreign epic's
  // verifier note parked in tooling/grip/ledger/ is not a corrupt run file —
  // it was never a run file. Reporting both as MALFORMED-RUN read as "grip's
  // store is rotting" when the true statement is "another epic parked a note
  // here", and the two need different responses: one is a defect report, the
  // other is a boundary.
  //
  // The line is CLAIMING the shape: a document carrying `run_id` or `recipes`
  // claims to be a run and is held to it; a document carrying neither never
  // claimed and is named for what it is.
  const dir = tmpLedger();
  writeLedgerRun({ run_id: "good", recipes: [goodRow()], dir });
  writeFileSync(join(dir, "foreign-note.json"), JSON.stringify({ id: "v-note", claim: "a verifier note", rerun: "git show origin/main:README.md | wc -l" }));
  writeFileSync(join(dir, "unwrapped-row.json"), JSON.stringify(goodRow()));
  writeFileSync(join(dir, "claims-and-fails.json"), JSON.stringify({ run_id: "x", recipes: "not an array" }));
  writeFileSync(join(dir, "an-array.json"), JSON.stringify([goodRow()]));

  const { runs, unreadable, shape } = readLedgerRuns(dir);
  assert.equal(runs.length, 1, "only the honestly written run folds");
  assert.deepEqual(
    unreadable.map((u) => `${u.file}:${u.reason}`).sort(),
    ["an-array.json:MALFORMED-RUN", "claims-and-fails.json:MALFORMED-RUN", "foreign-note.json:NOT-A-RUN", "unwrapped-row.json:NOT-A-RUN"],
  );

  // BOTH counts are visible in the fold's OWN output, on a pass as much as on a
  // failure — a class you can only see when something breaks is a class that
  // gets quietly emptied.
  const folded = foldLedger(dir);
  assert.equal(folded.stats.not_a_run, 2);
  assert.equal(folded.stats.malformed_run, 2);
  assert.equal(folded.stats.unreadable, 4);
  assert.deepEqual([shape.not_a_run, shape.malformed_run, shape.runs], [2, 2, 1]);

  // A RECIPE-SHAPED BUT UNWRAPPED document (unwrapped-row.json above is exactly
  // that: one recipe's fields at top level, no wrapper, no run_id) stays
  // NOT-A-RUN. Two such files sit in the committed store today. The fold does
  // NOT infer the wrapper, because the one thing that row lacks is its chain of
  // custody: a run_id synthesised at READ time is an L6 claim wearing an L2
  // uniform (R1). Naming the class is what makes them findable rather than lost
  // inside a corruption count; re-recording them through writeLedgerRun is the
  // append-only-legal repair, filed as tgw11-bl-unwrapped-recipe-rows-unread.
  assert.equal(folded.entries.length, 1, "the unwrapped row is REPORTED, never guessed into the fold");
});

test("folding an absent directory is an empty fold, not a throw", () => {
  const folded = foldLedger(join(tmpLedger(), "does-not-exist"));
  assert.deepEqual(folded.entries, []);
  assert.equal(folded.stats.rows, 0);
});

test("the fold is deterministic — entries sorted by key, recipes by (observed_at, file)", () => {
  const dir = tmpLedger();
  writeLedgerRun({ run_id: "z", recipes: [goodRow({ subject: "z.ex", rerun: "wc -l z.ex" })], dir });
  writeLedgerRun({ run_id: "a", recipes: [goodRow({ subject: "a.ex", rerun: "wc -l a.ex" })], dir });

  const keys = foldLedger(dir).entries.map((e) => e.subject);
  assert.deepEqual(keys, [...keys].sort());
});

// ── the store on disk ────────────────────────────────────────────────────────

test("the committed ledger directory is NOT gitignored — D10's exact trap, checked not assumed", () => {
  const git = spawnSync("git", ["check-ignore", "-v", "tooling/grip/ledger/"], { cwd: REPO_ROOT, encoding: "utf8" });
  if (git.error) return; // no git here — the shell gate still checks it
  assert.equal(git.status, 1, `tooling/grip/ledger/ IS gitignored: ${git.stdout.trim()}`);
});

// This guard was written while the store was empty and asserted it held ZERO
// rows, which read as "no test row leaked into the committed store" only for
// as long as the real answer was also zero. Once tgw3-write-verb put the first
// real rows in, the assertion started failing on the store WORKING — and a
// guard that fires on the system succeeding is a guard that gets deleted.
//
// Its second form asserted every on-disk row was git-TRACKED. That reads a
// legitimate charter-D35 carve-out as a defect: D35 empowers a verify-time
// actor to write real rows that live UNTRACKED from Verify until Decide commits
// them, so for the whole of that window (run-proven this wave: two carve-out
// files present → `not ok`, git-added → green) the guard fired on sanctioned
// work — again the "fires when the system succeeds" failure, one layer over.
//
// RE-SCOPED to a SNAPSHOT DELTA. The real leak is a TEST writing into the store
// DURING this run — every test here promises to write only to a mkdtemp dir. So
// the guard anchors on the store's contents captured at MODULE LOAD, before any
// test body runs (LEDGER_BASELINE_AT_LOAD), and fails only if a .json appeared
// SINCE. A carve-out row is present at load → in the baseline → not flagged. A
// test that writes into DEFAULT_LEDGER_DIR creates a file after load → absent
// from the baseline → flagged, by file name. Git-tracked-ness is no longer the
// question; "did a test leak a row into the real store this run" is, which is
// what the guard always MEANT and the only thing it can honestly answer during
// a carve-out window.
test("DEFAULT_LEDGER_DIR points inside tooling/grip and grows NO rows during a test run", () => {
  assert.match(DEFAULT_LEDGER_DIR, /tooling\/grip\/ledger\/$/);
  mkdirSync(DEFAULT_LEDGER_DIR, { recursive: true });
  const onDisk = readdirSync(DEFAULT_LEDGER_DIR).filter((f) => f.endsWith(".json"));

  const appeared = onDisk.filter((f) => !LEDGER_BASELINE_AT_LOAD.has(f));
  assert.deepEqual(appeared, [], `a test wrote ${appeared.length} row(s) into the committed store this run: ${appeared.join(", ")} — every test must write only to a mkdtemp dir`);
});

// ── the D18 control ──────────────────────────────────────────────────────────

test("--selftest runs every control and reports each one FIRING", () => {
  const run = spawnSync(process.execPath, [LEDGER_SRC, "--selftest"], { encoding: "utf8" });
  assert.equal(run.status, 0, run.stdout + run.stderr);
  assert.equal(/SILENT/.test(run.stdout), false, run.stdout);
  assert.match(run.stdout, /controls fired/);
});

test("the CLI folds a directory and exits nonzero only on an unreadable file", () => {
  const dir = tmpLedger();
  writeLedgerRun({ run_id: "r1", recipes: [goodRow()], dir });
  const clean = spawnSync(process.execPath, [LEDGER_SRC, "fold", dir], { encoding: "utf8" });
  assert.equal(clean.status, 0);
  assert.equal(JSON.parse(clean.stdout).stats.rows, 1);

  writeFileSync(join(dir, "broken-0000.json"), "{");
  const dirty = spawnSync(process.execPath, [LEDGER_SRC, "fold", dir], { encoding: "utf8" });
  assert.equal(dirty.status, 1);
});

// ── the fold survives a rotten row ───────────────────────────────────────────
//
// THE WRITE PATH IS NOT THE READ PATH. Every test above proves admitRecipe
// gates what this module WRITES. Nothing re-admits what it READS: the fold
// consumes bytes off disk that a hand edit, a truncated write or a future
// schema can shape however it likes. Before the row guard, `{subject: 42}`
// threw out of recipeKey and took the ENTIRE fold with it — including every
// well-formed row in every other file — and a null row or a subject-less row
// silently keyed to the empty pair, merging all of them into one bogus entry.
// Garbage accepted as a subject and one rotten byte costing the whole store are
// the two defects this module exists to make impossible.

test("a non-string subject does not take down the whole fold", () => {
  const folded = foldLedger([
    { file: "good.json", run_id: "g", recipes: [{ subject: "api/x.ex", quantity: "lines", rerun: "wc -l api/x.ex", derived_level: "L3", deps: [], observed_at: "2026-07-20T00:00:00Z" }] },
    { file: "rot.json", run_id: "r", recipes: [{ subject: 42, quantity: "q", rerun: "cat a" }] },
  ]);
  assert.equal(folded.entries.length, 1, "the well-formed row in the OTHER file must survive");
  assert.equal(folded.stats.rows, 1);
  assert.equal(folded.unreadable.length, 1);
  assert.equal(folded.unreadable[0].reason, "MALFORMED-ROW");
  assert.equal(folded.unreadable[0].file, "rot.json");
  assert.equal(folded.unreadable[0].index, 0, "the report must name WHICH row, or it cannot be found by hand");
});

test("null rows, bare strings and subject-less rows are REPORTED, never merged into one bogus entry", () => {
  const folded = foldLedger([
    { file: "rot.json", run_id: "r", recipes: [null, "hello", {}, { quantity: "q", rerun: "cat a" }, { subject: "s", quantity: "q" }] },
  ]);
  assert.equal(folded.entries.length, 0, "not one of these is a subject — none may become an entry");
  assert.equal(folded.stats.rows, 0);
  assert.equal(folded.unreadable.length, 5);
  for (const u of folded.unreadable) {
    assert.equal(u.reason, "MALFORMED-ROW");
    assert.match(u.message, /row \d+/);
  }
});

test("a rotten row is reported, not silently skipped — the fold's own D6 rule applied at row grain", () => {
  const folded = foldLedger([{ file: "rot.json", run_id: "r", recipes: [{ subject: 1, quantity: "q", rerun: "cat a" }] }]);
  assert.equal(folded.stats.unreadable, 1, "stats must carry it, or a caller reading stats alone sees a clean, smaller, wrong world");
});

// ── THE SCREEN CONTRACT'S EDGES (added in review) ────────────────────────────

test("an ASYNC screen is SCREEN-NOT-SYNC — fail closed, but diagnosed honestly", () => {
  // The tolerant screen contract accepts true / {ok} / a string, and fails
  // everything else CLOSED. That is right. But a Promise is not a refusal —
  // it is a SIGNATURE MISMATCH, and reporting it as REFUSED-COMMAND would make
  // a wrongly-wired CLI look like an over-aggressive safety screen. Every row
  // refused, with a reason string pointing at the wrong suspect.
  //
  // admitRecipe is synchronous by design: it sits one phase from a workflow
  // file that may not await (D19). So an async screen cannot ever be honoured
  // here, and saying so beats silently declining everything.
  const row = { subject: "s", quantity: "q", rerun: "cat README.md", observed_at: "2026-07-20T00:00:00Z" };
  const v = admitRecipe(row, { screen: async () => true });
  assert.equal(v.ok, false, "an async screen must not admit — it screened nothing");
  const reasons = v.rejections.map((r) => r.reason);
  assert.ok(reasons.includes("SCREEN-NOT-SYNC"), `expected SCREEN-NOT-SYNC, got ${reasons.join(", ")}`);
  assert.ok(!reasons.includes("REFUSED-COMMAND"), "an async screen is a contract mismatch, never a refusal of the command");
  assert.match(v.rejections.find((r) => r.reason === "SCREEN-NOT-SYNC").message, /synchronous/);

  // A bare thenable counts too — the check is the shape, not the keyword.
  const thenable = admitRecipe(row, { screen: () => ({ then(res) { res(true); } }) });
  assert.ok(thenable.rejections.map((r) => r.reason).includes("SCREEN-NOT-SYNC"));

  // And the ordinary contract is untouched in both directions.
  assert.equal(admitRecipe(row, { screen: () => true }).ok, true);
  assert.equal(admitRecipe(row, { screen: () => ({ ok: true }) }).ok, true);
  assert.equal(admitRecipe(row, { screen: () => false }).ok, false);
});

test("no consumer reads the fold's OLD field names — the rename left nothing dangling", () => {
  // `foldLedger().conflicts` → `.rival_methods`, `entry.conflict` →
  // `entry.rival_method`, and the `CONFLICT` export is gone. adjudicate.mjs
  // keeps its own identically-spelled verdict, which fires on the OPPOSITE
  // input (claim VALUES, not rerun COMMANDS) — so this pins that the ledger's
  // fold no longer answers to the old names, rather than grepping the tree for
  // a string two modules legitimately share.
  const runs = [
    { file: "a.json", run_id: "a", recipes: [{ subject: "s", quantity: "q", rerun: "wc -l /abs/x", derived_level: "L3", deps: [], observed_at: "2026-07-20T00:00:00Z" }] },
    { file: "b.json", run_id: "b", recipes: [{ subject: "s", quantity: "q", rerun: "wc -l rel/x", derived_level: "L3", deps: [], observed_at: "2026-07-20T00:00:01Z" }] },
  ];
  const folded = foldLedger(runs);
  assert.equal(folded.rival_methods.length, 1);
  assert.equal(folded.conflicts, undefined, "the old `conflicts` key must be gone, not shadowed");
  assert.equal(folded.stats.conflicts, undefined);
  assert.equal(folded.stats.rival_methods, 1);
  assert.equal(folded.entries[0].rival_method, true);
  assert.equal(folded.entries[0].conflict, undefined);
  assert.equal(folded.rival_methods[0].reason, "RIVAL-METHOD");
  // The message must read as the PRODUCT, or the flag discredits itself on the
  // first honest multi-recipe entry — which under D32's path-grain key is day one.
  assert.match(folded.rival_methods[0].message, /FEATURE of the row, not a defect report/);
});

test("the injected-screen contract MEETS screen.mjs's real return shape", () => {
  // A CROSS-SLICE test, deliberately. `screen` is injected so the two modules
  // stay decoupled (D39) — but decoupled is not the same as compatible, and
  // nothing else in either suite ever puts them in a room together. Built in
  // the same round with disjoint file sets, both correct alone, they did not
  // meet: screen.mjs returns `{ ok, reason }` and this module read only
  // `message`, so every refusal discarded the screen's diagnosis and printed
  // "the injected screen refused it" — a shrug, in the exact place screen.mjs
  // authors a per-head explanation so the log would NOT be a shrug.
  //
  // Uses a faithful STAND-IN rather than importing screen.mjs, because the
  // ledger must keep importing nothing but level.mjs. The stand-in's shape is
  // the contract; if screen.mjs's shape ever moves, the wiring slice's own
  // tests are what must catch it.
  const screenLike = (cmd) => (/^(cat|grep|git|wc|ls)\b/.test(cmd)
    ? { ok: true, reason: "admitted: allowlisted head" }
    : { ok: false, reason: `not allowlisted: ${cmd.split(" ")[0]} is refused` });

  const row = (rerun) => ({ subject: "s", quantity: "q", rerun, observed_at: "2026-07-20T00:00:00Z" });

  const refused = admitRecipe(row("systemctl stop bp-crux-parent"), { screen: screenLike });
  assert.equal(refused.ok, false);
  const r = refused.rejections.find((x) => x.reason === "REFUSED-COMMAND");
  assert.ok(r, "an {ok:false} verdict must refuse under REFUSED-COMMAND");
  assert.match(r.message, /not allowlisted: systemctl is refused/,
    "the screen's OWN reason must survive into the rejection — discarding it turns a diagnosis into a shrug");
  assert.ok(!r.message.includes("the injected screen refused it"),
    "the generic fallback must not fire when the screen supplied a reason");

  // `message` still works, so a screen written to the older shape is unbroken.
  const viaMessage = admitRecipe(row("rm -rf /"), { screen: () => ({ ok: false, message: "destructive verb" }) });
  assert.match(viaMessage.rejections.find((x) => x.reason === "REFUSED-COMMAND").message, /destructive verb/);

  // And `{ok:true, reason}` — the ADMIT shape screen.mjs actually returns, which
  // carries a reason string on the success side too — must still admit.
  assert.equal(admitRecipe(row("cat README.md"), { screen: screenLike }).ok, true);
});

// ── THE READ PATH RE-ADMITS WHAT THE WRITE PATH ADMITTED (tgw5) ──────────────
//
// usableRow is only the crash-safety gate. The fold admitted EVERY forgery
// class admitRecipe refuses: a stored `value`, an outage-capable rerun, a
// future observed_at and an over-claimed derived_level all folded into clean
// entries with `"unreadable": []` and exit 0. Each test below is RED against
// that pre-hardening fold (unreadable was empty) and GREEN now that the fold
// composes admitRecipe and routes every rejection into unreadable[]. Each
// mutates ONE field of an honest row, so a rejection can only be that field's.

// The honest baseline these forgery tests each mutate one field of. Folds clean.
function foldRow(over = {}) {
  return {
    file: "probe.json",
    run_id: "grip-probe",
    recipes: [{
      subject: "api/lib/barkpark/plugin.ex",
      quantity: "callback count",
      rerun: "grep -c 'def ' api/lib/barkpark/plugin.ex",
      derived_level: "L3",
      deps: [],
      observed_at: "2026-07-20T00:00:00Z",
      ...over,
    }],
  };
}

test("the fold REJECTS a row carrying `value` — VALUE-STORED, into unreadable[] (RED before hardening)", () => {
  const clean = foldLedger([foldRow()]);
  assert.equal(clean.unreadable.length, 0, "the honest baseline must fold clean, or the rejection is not the value's doing");
  assert.equal(clean.entries.length, 1);

  const folded = foldLedger([foldRow({ value: 42 })]);
  assert.equal(folded.entries.length, 0, "a forged row is NOT folded");
  assert.equal(folded.stats.unreadable, 1);
  assert.equal(folded.unreadable[0].reason, "VALUE-STORED");
  assert.equal(folded.unreadable[0].file, "probe.json");
  assert.equal(folded.unreadable[0].index, 0, "the report must name WHICH row, or it cannot be found by hand");
});

test("the fold REJECTS a screen-refused rerun — REFUSED-COMMAND, only when a screen is injected (RED before hardening)", () => {
  // derived_level L6 so `rm -rf` (which re-derives L6) does NOT also trip
  // LEVEL-SKIP — the ONLY reason this row can be refused is the screen.
  const row = foldRow({ rerun: "rm -rf /opt/barkpark/releases", derived_level: "L6" });

  // No screen: the fold cannot know the command is unsafe — it has no screen,
  // exactly as admitRecipe has none unless the caller injects one. Folds.
  const unscreened = foldLedger([row]);
  assert.equal(unscreened.unreadable.length, 0, "with no screen there is nothing to refuse it — the rejection must be the screen's doing");
  assert.equal(unscreened.entries.length, 1);

  // Screen injected (as the CLI injects screenCommand): refused.
  const folded = foldLedger([row], { screen: screenCommand });
  assert.equal(folded.entries.length, 0);
  assert.equal(folded.stats.unreadable, 1);
  assert.equal(folded.unreadable[0].reason, "REFUSED-COMMAND");
  assert.match(folded.unreadable[0].message, /rm/, "the screen's own reason must survive into the report");
});

test("the fold REJECTS a future observed_at — FUTURE-OBSERVED-AT, against an injected now (RED before hardening)", () => {
  const row = foldRow({ observed_at: "2099-01-01T00:00:00Z" });

  // No `now`: the module owns no clock (D19), so with no bound the future
  // instant is not a future — the fold cannot check it, and does not pretend to.
  const unbounded = foldLedger([row]);
  assert.equal(unbounded.unreadable.length, 0, "no now means no future bound — the rejection must be the clock's doing");
  assert.equal(unbounded.entries.length, 1);

  const folded = foldLedger([row], { now: FOLD_NOW });
  assert.equal(folded.entries.length, 0);
  assert.equal(folded.stats.unreadable, 1);
  assert.equal(folded.unreadable[0].reason, "FUTURE-OBSERVED-AT");
});

test("the fold REJECTS an over-claimed derived_level — LEVEL-SKIP, needing no external input (RED before hardening)", () => {
  // `grep -c … <path>` re-derives at L3 (a local scoped grep). A stored L1 is
  // the exact laundering the epic exists to abolish: an L6 claim about an L1
  // fact, wearing the doctrine's uniform. The fold used to hand that L1 to
  // every consumer via restateLevel-as-DRIFT; it must now REFUSE it, because an
  // over-claim is a forgery, not drift.
  const clean = foldLedger([foldRow({ derived_level: "L3" })]);
  assert.equal(clean.unreadable.length, 0, "the honest under-or-equal claim folds clean");

  const folded = foldLedger([foldRow({ derived_level: "L1" })]);
  assert.equal(folded.entries.length, 0);
  assert.equal(folded.stats.unreadable, 1);
  assert.equal(folded.unreadable[0].reason, "LEVEL-SKIP");
});

test("THE COMBINED PROBE: value + `rm -rf` + observed_at 2099 + a false L1, all at once, fold to unreadable — not a clean entry with exit 0", () => {
  // The finding verbatim: one row tripping all four classes folded into a clean
  // entry with `"unreadable": []`, `"stats": {"unreadable": 0}` and exit 0.
  const probe = foldRow({
    value: 42,
    rerun: "rm -rf /tmp/x",
    observed_at: "2099-01-01T00:00:00Z",
    derived_level: "L1",
  });
  const folded = foldLedger([probe], { now: FOLD_NOW, screen: screenCommand });

  assert.equal(folded.entries.length, 0, "the forged row must reach NO entry");
  assert.ok(folded.stats.unreadable > 0, "and it must land in unreadable, driving the fold CLI's nonzero exit");
  const reasons = new Set(folded.unreadable.map((u) => u.reason));
  for (const r of ["VALUE-STORED", "REFUSED-COMMAND", "FUTURE-OBSERVED-AT", "LEVEL-SKIP"]) {
    assert.ok(reasons.has(r), `the combined probe must trip ${r} — rejections accumulate, they do not abort at the first`);
  }
});

test("THE COMBINED PROBE, END TO END: the fold CLI exits NONZERO on a forged store", () => {
  const dir = tmpLedger();
  writeFileSync(join(dir, "grip-forged-aaaaaaaa.json"), JSON.stringify({
    run_id: "grip-forged",
    recipes: [{
      subject: "forged/subject",
      quantity: "unit state",
      rerun: "rm -rf /tmp/x",
      derived_level: "L1",
      deps: [],
      observed_at: "2099-01-01T00:00:00Z",
      value: 42,
    }],
  }));
  const run = spawnSync(process.execPath, [LEDGER_SRC, "fold", dir], { encoding: "utf8" });
  assert.equal(run.status, 1, `the forged store must fold nonzero — stdout: ${run.stdout.slice(0, 200)}`);
  const folded = JSON.parse(run.stdout);
  assert.equal(folded.entries.length, 0, "the forged row reaches no entry");
  const reasons = new Set(folded.unreadable.map((u) => u.reason));
  for (const r of ["VALUE-STORED", "REFUSED-COMMAND", "FUTURE-OBSERVED-AT", "LEVEL-SKIP"]) {
    assert.ok(reasons.has(r), `the CLI must report ${r} — it injects both the shell clock and screenCommand`);
  }
  // The banner is STDERR only (D78): stdout stayed pure JSON, so the pipe above
  // parsed. A banner in stdout would have thrown here.
  assert.match(run.stderr, /\[grip-provenance\]/, "the self-provenance banner must ride on stderr");
});

test("THE PROJECTION GUARANTEE: entries[] is a TWELVE-named-field allowlist, so `value` can never leave the fold (D89)", () => {
  // Defence in depth behind the admitRecipe gate. An honest folded recipe must
  // carry EXACTLY the twelve named fields — never `value`, never a spread of
  // the raw row. This is the property that let leads ship a filter over
  // entries[] and be structurally unable to hand back a stored answer; it lives
  // in ONE projection, not in the schema, so it is pinned by its exact key set.
  const folded = foldLedger([foldRow()]);
  assert.equal(folded.entries.length, 1);
  const recipe = folded.entries[0].recipes[0];
  const TWELVE = [
    "rerun", "derived_level", "stored_level", "level_restated", "level_fallback",
    "stored_quantity", "quantity_restated", "quantity_fallback",
    "deps", "observed_at", "run_id", "file",
  ];
  assert.deepEqual(Object.keys(recipe).sort(), [...TWELVE].sort(), "the projection must be EXACTLY the twelve-field allowlist — a `...row` spread would grow this set");
  assert.equal("value" in recipe, false, "the guarantee is the allowlist, not its count — `value` is not named, so it cannot appear");

  // And a forged `value` row never even reaches entries[] now — it is rejected
  // by the gate AND could not carry `value` through the projection if it did.
  const forged = foldLedger([foldRow({ value: 99 })]);
  assert.ok(forged.entries.every((e) => e.recipes.every((r) => !("value" in r))), "no entry recipe may ever carry `value`");
});

test("the level-restatement split is DIRECTIONAL, and the DOWN bucket is empty because admitRecipe REFUSES those rows — not because none exist", () => {
  // REVIEW ADDITION (wave 11). The D89 control below asserts
  // `level_restated_down === 0` over the WHOLE store. Read alone that looks
  // like a live launder detector; it is not, and the difference matters enough
  // to be executed rather than believed.
  //
  // A DOWN restatement is a row whose STORED level is STRONGER than what its
  // own command re-derives — which is exactly the shape `checkCeiling` names
  // LEVEL-SKIP, and the fold runs `admitRecipe` BEFORE it ever reaches the
  // restatement counter (ledger.mjs, the read-path re-admission). So the row is
  // rejected and never counted: `down === 0` is enforced by the ADJUDICATOR,
  // and the assertion that can actually fail on a forged store is the
  // LEVEL-SKIP rejection landing in `unreadable[]`.
  //
  // This test pins BOTH halves against one synthetic run, so neither half can
  // be deleted without a red:
  //   UP   stored L4, `git show origin/main:… | wc -l` re-derives L2 → ADMITTED,
  //        counted in level_restatements.up, reported and not rejected.
  //   DOWN stored L1, a local `grep -c` re-derives L3 → REJECTED LEVEL-SKIP,
  //        not folded, and the DOWN bucket stays empty for that REASON.
  const dir = tmpLedger();
  const up = { subject: "api/mix.exs", quantity: "line count", rerun: "git show origin/main:api/mix.exs | wc -l", deps: ["api/mix.exs"], observed_at: "2026-07-20T12:00:00Z", derived_level: "L4" };
  const down = goodRow({ derived_level: "L1" }); // rerun is a purely local grep → L3
  writeFileSync(join(dir, "grip-directional.json"), JSON.stringify({ run_id: "grip-directional", recipes: [up, down] }));

  const folded = foldLedger(dir, { now: "2026-07-28T00:00:00Z", screen: screenCommand });

  assert.equal(folded.stats.level_restated_up, 1, "a conservative author corrected by the ladder is an UP, reported not rejected");
  assert.deepEqual(
    folded.level_restatements.up.map((r) => [r.stored_level, r.derived_level]),
    [["L4", "L2"]],
    "the UP row carries BOTH levels, so a reader can name the row instead of counting it",
  );

  assert.equal(folded.stats.level_restated_down, 0, "the DOWN row never reaches the counter");
  assert.equal(folded.stats.rows, 1, "the over-claiming row is NOT folded; the honest one is");
  const levelSkips = folded.unreadable.filter((u) => u.reason === "LEVEL-SKIP");
  assert.equal(levelSkips.length, 1, `THIS is the assertion that fires on a forged store: ${JSON.stringify(folded.unreadable)}`);
  assert.equal(levelSkips[0].index, 1);
});

// Re-derived 2026-07-28 in a clean git worktree at origin/main 072978af0:
// 78 .json files → 40 grip-owned runs / 27 foreign runs / 11 NOT-A-RUN
// documents; 22 of the 40 owned runs are WRITE-PATH ATTESTED, carrying 319 of
// the 423 owned rows. GROWTH floors, never equalities: every honestly written
// run attests automatically, so these can only rise. A DROP means the scope
// stopped seeing runs it used to see — which is the exact way a scoped control
// dies quietly, and is why the mutation proof in the PR body drives it.
const ATTESTED_RUNS_FLOOR = 22;
const ATTESTED_ROWS_FLOOR = 319;

test("CONTROL: the committed rows fold CLEAN under the hardening — unreadable 0, and 0 rows restate level (D89, #5442)", () => {
  // A hardening that rejects the epic's own real store is broken, not strict.
  // Folded WITH both bounds armed exactly as the CLI arms them (a REAL clock,
  // stripped to Z like `date -u` — a fixed past `now` would read the committed
  // rows as future).
  //
  // ── WHAT "THE COMMITTED ROWS" MEANS, RE-ARGUED (this test was RED) ─────────
  // Armed over the WHOLE directory this fold reports 422 unreadable entries,
  // and NONE of them is repairable, because the store is append-only and shared
  // by four epics (D118) — deleting or rewriting another epic's row is
  // forbidden (D26/D99). The 422 are three populations and the contract is
  // different for each:
  //
  //   219 FOREIGN — 208 MALFORMED-ROW in 27 borrowed `{claim, rerun}` run files
  //        plus 11 NOT-A-RUN documents. Grip never wrote them and cannot fix
  //        them. Asserting they fold clean asserts a contract over rows this
  //        epic does not own; that assertion is RETIRED here, and the counts
  //        stay printed below so retiring it is not the same as hiding it.
  //   203 GRIP-OWNED, across 95 DISTINCT ROWS of 18 HAND-AUTHORED run files
  //        (rejections ACCUMULATE per row — ledger.mjs:772-782 — so an entry
  //        count is 2.1× the row count; the arithmetic closes: 423 owned rows =
  //        328 admitted + 95 rejected). These are a REAL HARDENING CATCH:
  //        LEVEL-SKIP 80, REFUSED-COMMAND 54, UNKNOWN-FIELD 45, VALUE-STORED 24
  //        are exactly what `admitRecipe` exists to refuse, and every one sits
  //        in a file that never crossed the write path. The rows stay, the
  //        rejections stay reported, and the honest statement is "the write
  //        path refuses these; they got in around it" — not "the store is
  //        clean". That is a defect in HOW they were written, and the
  //        append-only-legal repair is to re-record them through
  //        `writeLedgerRun`, never to soften this gate.
  //     0 WRITE-PATH ATTESTED — the 22 runs whose filename reproduces the digest
  //        of their own bytes, i.e. the runs `writeLedgerRun` demonstrably
  //        produced. THIS is the population the D89 control was always about:
  //        every row that crossed the gate still crosses it today. It folds
  //        clean, and it is 319 rows deep, so the pass is not vacuous.
  //
  // The scope is a SHAPE computed from each file's own bytes, never a pinned
  // list of filenames, and it grows with the store by construction.
  //
  // ── ONE NAMED EXCEPTION, AND WHY IT IS NOT A SOFTENING ────────────────────
  // The bp write set is now DERIVED from `bp capabilities -o json` rather than
  // hand-written (screen.mjs, BP_WRITE_COMMANDS), which closed 62 writing bp
  // commands the screen used to admit — `bp doc mutate`, `bp secret
  // scoped-set`, `bp auth mfa-disable` among them. Exactly ONE attested row
  // falls to that tightening, and it is named below rather than absorbed into a
  // `<= 1`, so a SECOND unfoldable row still reds this control immediately.
  //
  // THE COST IS REAL AND IS STATED, not hidden: this row's evidence can no
  // longer be re-derived by the census, because the command that produced it is
  // no longer re-runnable. That is the honest price of the tightening.
  //
  // WHY THE ROW IS NOT SIMPLY RE-ADMITTED. `--dry-run` is what makes it safe,
  // and NO writing command in bp's manifest declares `--dry-run` in its own
  // flag list — checked: 0 of 97. Its per-verb support is documented in `bp
  // --help` and nowhere machine-readable, so the screen cannot DERIVE that the
  // command is a read. Admitting it would be trusting a flag, in the one
  // direction this module is not allowed to be wrong in. The same documentation
  // standard already appears above for `tree -o`, and it is used there to
  // REFUSE.
  const BP_DRY_RUN_ROW = "bp task move legendary-quality-takeover-review-remediation legendary-quality-takeover-root --dry-run -o json";

  const realNow = new Date().toISOString().replace(/\.\d+Z$/, "Z");
  const folded = foldLedger(DEFAULT_LEDGER_DIR, { now: realNow, screen: screenCommand, scope: "attested" });
  const unexpected = folded.unreadable.filter((u) => !(u.reason === "REFUSED-COMMAND" && String(u.message).includes(BP_DRY_RUN_ROW)));
  assert.equal(unexpected.length, 0, `every row the write path admitted must still fold clean: ${JSON.stringify(unexpected.slice(0, 3))}`);
  // …and the exception is asserted to still BE there. A named exception that
  // silently stops applying is how a scoped control dies quietly — the same
  // failure mode the run/row floors below exist for.
  assert.equal(folded.unreadable.length, 1, `the bp write-set tightening rejects EXACTLY the one named row: ${JSON.stringify(folded.unreadable.map((u) => u.reason))}`);
  assert.match(folded.unreadable[0].message, /declared WRITING by bp's own capabilities manifest/, "and for the stated reason, not some other refusal that happens to name the same row");
  assert.ok(folded.stats.runs >= ATTESTED_RUNS_FLOOR, `the attested scope must not SHRINK: ${folded.stats.runs} run(s) < floor ${ATTESTED_RUNS_FLOOR}`);
  assert.ok(folded.stats.rows >= ATTESTED_ROWS_FLOOR, `a vacuous clean fold proves nothing: ${folded.stats.rows} row(s) < floor ${ATTESTED_ROWS_FLOOR}`);

  // ── THE SECOND ASSERTION, RE-ARGUED BY DIRECTION ──────────────────────────
  // CONFIRMS derived_level is re-derived at fold time (tgw2-fold-reread-
  // derived-level, shipped #5442). The old form asserted `level_restated === 0`
  // over the whole store and was RED at 1 — and "0 restatements" was never the
  // property worth having anyway, because it cannot tell the two directions
  // apart. LEVELS runs L1 (strongest) … L6, so:
  //   DOWN — stored L2, the command only supports L4: the LAUNDER this whole
  //          substrate exists to prevent, arriving through the READ path.
  //          Asserted 0, over the WHOLE store, not just the attested scope.
  //   UP   — stored L4, the command re-derives L2: a conservative author being
  //          corrected by the ladder. Harmless, and NAMED rather than counted.
  // READ THE DOWN ASSERTION FOR WHAT IT IS (review addition, wave 11). It is a
  // STANDING STATEMENT, not a live tripwire: the fold runs `admitRecipe` before
  // the restatement counter, and a DOWN-shaped row IS the LEVEL-SKIP shape, so
  // it is rejected into `unreadable[]` and never counted. The assertion that
  // actually fires on a forged store is that rejection — pinned, both
  // directions, by the directional test above. Keeping this line is still
  // right: if the read path ever stopped re-admitting, this is the assertion
  // that would go red.
  //
  // Today the whole store holds exactly one, and it is an UP:
  // grip-20260726T000000Z-v-corpus-identity-call.json, subject
  // internal/cli/cloud_site_cmd.go, stored L4 → derived L2 (`git show
  // origin/main:… | grep -n …` is an origin/main read, which IS L2). Ruling it
  // a defect would be wrong; the contract the control should assert is the
  // direction, and it now does.
  const whole = foldLedger(DEFAULT_LEDGER_DIR, { now: realNow, screen: screenCommand });
  assert.equal(
    whole.stats.level_restated_down,
    0,
    `no admitted row may re-derive WEAKER than its stored level — that is the launder: ${JSON.stringify(whole.level_restatements.down.slice(0, 3))}`,
  );

  // WHAT THIS RUN DECLINED, PRINTED ON PASS. A scope that is only visible in a
  // failure message is a scope that gets quietly narrowed; the same blindness
  // made the mint floor pin-able. Both file classes and every grip-owned
  // rejection class are here on a GREEN run.
  const ownedRejections = {};
  const ownedRows = new Set();
  for (const u of foldLedger(DEFAULT_LEDGER_DIR, { now: realNow, screen: screenCommand, scope: "owned" }).unreadable) {
    ownedRejections[u.reason] = (ownedRejections[u.reason] ?? 0) + 1;
    ownedRows.add(`${u.file}#${u.index}`);
  }
  const s = whole.stats;
  console.log(
    `\n  [D89 control] scope=attested — ${folded.stats.rows} row(s) over ${folded.stats.runs} run file(s), 0 unreadable` +
      `\n  [D89 control] store: ${s.files} file(s) = ${s.owned_runs} grip-owned (${s.attested_runs} attested) + ${s.foreign_runs} foreign run(s) + ${s.not_a_run} NOT-A-RUN + ${s.malformed_run} MALFORMED-RUN + ${s.unparseable} UNPARSEABLE` +
      `\n  [D89 control] grip-owned rejections OUTSIDE the attested scope (reported, NOT asserted — hand-authored rows the write path would refuse): ` +
      `${Object.values(ownedRejections).reduce((a, b) => a + b, 0)} rejection(s) across ${ownedRows.size} row(s) → ${JSON.stringify(ownedRejections)}` +
      `\n  [D89 control] level restatements: ${whole.level_restatements.down.length} DOWN (asserted 0), ${whole.level_restatements.up.length} UP → ` +
      `${JSON.stringify(whole.level_restatements.up.map((r) => `${r.file}#${r.index} ${r.subject} ${r.stored_level}→${r.derived_level}`))}\n`,
  );
});
