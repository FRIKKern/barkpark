// seal.test.mjs — the seal predicate's own controls.
//
// The two failures this file exists to catch are the two a green gate cannot:
// a WRONG LENS and a VACUOUS (b'). Both produce a confident, clean-looking
// predicate that HOLDS while a claimable row stands — the exact failure the
// epic exists to refuse. So the lens is tested against a corpus shaped like the
// live one (a depth-2 row under a done parent, a hash-id child a prefix lens
// cannot see, a namesake row outside the tree), and (b') is tested by the only
// mutation that distinguishes a written check from an inherited assumption:
// remove the root from the pool while leaving its status open.
//
// The end-to-end halves run the COMMITTED fixtures, so the credential this file
// earns is re-derivable from a clean checkout — D111's was not.
//
//   node --test tooling/grip/test/seal.test.mjs

import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFileSync, writeFileSync, rmSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

import {
  CLAUSES,
  CLAIMABLE_STATUSES,
  RUN_CLASS,
  ROOT_ID,
  FROZEN_CRITERIA,
  CHARTER_GREP_SPECIMEN,
  classifyRun,
  classifyJson,
  buildLenses,
  refusesAsCharterGrep,
  adjudicateCriterion,
  reconcilePool,
  PAGE,
} from "../seal.mjs";
import { deriveLevel } from "../level.mjs";
import { screenCommand } from "../screen.mjs";
import { admitsAbsenceClaim } from "../rerun.mjs";

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
const seal = (args) => spawnSync("node", [resolve(REPO, "tooling/grip/seal.mjs"), ...args], { cwd: REPO, encoding: "utf8", timeout: 120000 });
const FIX = (n) => resolve(REPO, `tooling/grip/fixtures/seal-${n}.json`);

// --- the four clause names ---------------------------------------------------

test("the clause vocabulary is (a) (b) (b') (c) — never (d)", () => {
  assert.deepEqual(CLAUSES, ["(a)", "(b)", "(b')", "(c)"]);
  assert.ok(!CLAUSES.includes("(d)"), "D94 has three clauses; the fourth printed name is D108's (b')");
});

// --- the four-way classifier -------------------------------------------------
//
// The launder this refuses to inherit: seal-predicate.mjs:171 AND :176 read only
// `r.status !== 0`, so a spawn that NEVER RAN (timeout, signal, ENOENT) is
// reported as one that RAN AND FAILED.

test("classifyRun separates NEVER-RAN from RAN-AND-FAILED", () => {
  assert.equal(classifyRun({ status: 0 }).klass, RUN_CLASS.CLEAN);
  assert.equal(classifyRun({ status: 1 }).klass, RUN_CLASS.FAILED);
  assert.equal(classifyRun({ status: null, signal: "SIGTERM" }).klass, RUN_CLASS.NEVER_RAN);
  assert.equal(classifyRun({ status: null, error: { code: "ENOENT" } }).klass, RUN_CLASS.NEVER_RAN);
  assert.equal(classifyRun(null).klass, RUN_CLASS.INFRA);
  // the naive predicate would call all three of these "failed"
  assert.notEqual(classifyRun({ status: null }).klass, classifyRun({ status: 1 }).klass);
});

test("the run vocabulary is four DISTINCT words, spelled as the output spells them", () => {
  // D115's tripwire is why this is spelled out rather than compared by constant:
  // a class literal no test NAMES is a class nobody can grep back to a control.
  assert.equal(RUN_CLASS.CLEAN, "RAN-CLEAN");
  assert.equal(RUN_CLASS.FAILED, "RAN-AND-FAILED");
  assert.equal(RUN_CLASS.NEVER_RAN, "NEVER-RAN");
  assert.equal(RUN_CLASS.INFRA, "INFRA-FAULT");
  assert.equal(new Set(Object.values(RUN_CLASS)).size, 4);
  assert.equal(classifyRun({ status: 0 }).klass, "RAN-CLEAN");
  assert.equal(classifyRun({ status: 2 }).klass, "RAN-AND-FAILED");
});

test("classifyRun agrees with real spawnSync timeout and ENOENT results", () => {
  const timedOut = spawnSync("sleep", ["5"], { timeout: 300, encoding: "utf8" });
  assert.equal(classifyRun(timedOut).klass, RUN_CLASS.NEVER_RAN);
  const missing = spawnSync("no-such-binary-for-grip-seal", [], { encoding: "utf8" });
  assert.equal(classifyRun(missing).klass, RUN_CLASS.NEVER_RAN);
});

test("a non-JSON body is INFRA-FAULT, never a red clause", () => {
  assert.equal(classifyJson({ klass: RUN_CLASS.CLEAN, detail: "" }, "<html>502</html>").klass, RUN_CLASS.INFRA);
  assert.equal(classifyJson({ klass: RUN_CLASS.CLEAN, detail: "" }, '{"ok":true}').json.ok, true);
});

// --- the lens ----------------------------------------------------------------

const CORPUS = new Map([
  ["truth-grip-epic", { _id: "truth-grip-epic", parent_id: null, lifecycle_status: "open" }],
  ["tgw1-workflow-gate-wiring", { _id: "tgw1-workflow-gate-wiring", parent_id: "truth-grip-epic", lifecycle_status: "done" }],
  // depth 2 under a DONE parent — the row filter[parent_id] cannot see
  ["tgw2-verify-writes-back", { _id: "tgw2-verify-writes-back", parent_id: "tgw1-workflow-gate-wiring", lifecycle_status: "open" }],
  // hash id — the row an id-prefix lens cannot see
  ["task-a965c4fbfe3710f5", { _id: "task-a965c4fbfe3710f5", parent_id: "truth-grip-epic", lifecycle_status: "open" }],
  // namesake filed OUTSIDE the tree — the row the closure cannot see
  ["tgw-filed-elsewhere", { _id: "tgw-filed-elsewhere", parent_id: "another-epic", lifecycle_status: "open" }],
  ["unrelated-row", { _id: "unrelated-row", parent_id: "another-epic", lifecycle_status: "open" }],
]);

test("every single lens leaks a row another lens catches; the union catches all three", () => {
  const l = buildLenses(CORPUS, ROOT_ID, null);
  assert.ok(!l.direct.has("tgw2-verify-writes-back"), "direct lens is depth-1 only");
  assert.ok(!l.prefix.has("task-a965c4fbfe3710f5"), "prefix lens cannot see a hash id");
  assert.ok(!l.closure.has("tgw-filed-elsewhere"), "closure cannot see a namesake outside the tree");
  for (const id of ["tgw2-verify-writes-back", "task-a965c4fbfe3710f5", "tgw-filed-elsewhere"]) {
    assert.ok(l.union.has(id), `${id} must survive into the union`);
  }
  assert.ok(!l.union.has("unrelated-row"));
});

test("the root is excluded from every lens, so clause (b) can never be blocked by the root itself", () => {
  const l = buildLenses(CORPUS, ROOT_ID, null);
  for (const [name, s] of Object.entries({ closure: l.closure, prefix: l.prefix, direct: l.direct, union: l.union })) {
    assert.ok(!s.has(ROOT_ID), `${name} must not contain the root`);
  }
});

test("claimable is open|blocked — `considering` is a legitimate third disposition", () => {
  assert.deepEqual([...CLAIMABLE_STATUSES].sort(), ["blocked", "open"]);
  assert.ok(!CLAIMABLE_STATUSES.has("considering"));
  assert.ok(!CLAIMABLE_STATUSES.has("done"));
});

// --- polarity ----------------------------------------------------------------

test("an absence claim on a diff that exited 1 WITH content is REFUSED, not accepted", () => {
  const r = adjudicateCriterion(
    { index: 0, polarity: "absence", covers: true, criterion: "x", rerun: "diff tooling/grip/record.mjs tooling/grip/provenance.mjs" },
    REPO,
  );
  assert.equal(r.verdict, "FAILED");
  assert.equal(r.absenceEligible, false);
  assert.equal(r.ok, false, "a bare `verdict === FAILED` seal would accept a multi-kilobyte diff as an absence");
  assert.equal(r.failCode, "NOT-ADMITTED");
});

test("a rerun that ADMITS but covers only half the criterion is PARTIAL-COVERAGE, not a pass", () => {
  // The shape of root criterion 3 under D97: the positive half re-derives at L2,
  // the stored wording's other clause is unsatisfiable. Half a criterion is not a
  // criterion, so it fails closed with its own word rather than borrowing NOT-ADMITTED.
  const r = adjudicateCriterion(
    { index: 2, polarity: "pass", covers: false, criterion: "x", rerun: "git show origin/main:tooling/grip/level.mjs | grep -n checkCeiling", why: "half only" },
    REPO,
  );
  assert.equal(r.admits, true);
  assert.equal(r.ok, false);
  assert.equal(r.failCode, "PARTIAL-COVERAGE");
});

test("a criterion that never ran carries the verdict NOT-RUN, never a borrowed execution verdict", () => {
  const noPolarity = adjudicateCriterion({ index: 0, polarity: null, covers: true, criterion: "x", rerun: "true", why: "none" }, REPO);
  assert.equal(noPolarity.verdict, "NOT-RUN");
  const noRerun = adjudicateCriterion({ index: 0, polarity: "pass", covers: true, criterion: "x", rerun: "" }, REPO);
  assert.equal(noRerun.verdict, "NOT-RUN");
  assert.equal(noRerun.failCode, "NO-RERUN");
});

test("an honest zero-match probe reads the SAME verdict and IS admitted", () => {
  const r = adjudicateCriterion(
    { index: 0, polarity: "absence", covers: true, criterion: "x", rerun: "git show origin/main:tooling/grip/record.mjs | grep -c mkdirSync" },
    REPO,
  );
  assert.equal(r.verdict, "FAILED");
  assert.equal(r.ok, true);
});

test("evidence with no declared polarity fails CLOSED even when the command is ADMITTED at L2", () => {
  const cmd = "git show origin/main:tooling/grip/level.mjs | grep -n checkCeiling";
  assert.equal(deriveLevel(cmd), "L2");
  assert.equal(screenCommand(cmd).ok, true);
  const r = adjudicateCriterion({ index: 0, polarity: null, covers: true, criterion: "x", rerun: cmd }, REPO);
  assert.equal(r.ok, false);
  assert.equal(r.failCode, "NO-POLARITY");
});

test("the polarity helpers are TOTAL over the undecorated refusal literal — no optional chaining needed", () => {
  // adjudicate.mjs:122-134 hand-builds a 6-key literal with no `admits`, so
  // reading ruling.rerun.admits.absence TypeErrors on every REFUSED command,
  // including this seal's own ceiling probe. That seam belongs to open task
  // tgw4-absence-veto-stops-at-the-rerun-seam; it is cited, not re-solved.
  const refusal = { command: "node x.mjs", verdict: "UNSAFE-RERUN", scope: null, ran: false, ms: 0, reason: "refused" };
  assert.equal(refusal.admits, undefined);
  assert.throws(() => refusal.admits.absence, TypeError);
  assert.equal(admitsAbsenceClaim(refusal), false);
  assert.equal(admitsAbsenceClaim(null), false);
  assert.equal(admitsAbsenceClaim(undefined), false);
});

// --- the charter-grep path rule ---------------------------------------------

test("the charter grep is REFUSED BY PATH whatever the level grammar makes of it", () => {
  // REVIEW FIX (wave 11): this asserted `deriveLevel(…) === "L2"`, which is
  // MERGE-ORDER DEPENDENT. `tgw5-bl-level-mention-promotion` ships in this same
  // wave and closes exactly D65's mention-promotion, so the identical command
  // re-derives L3 the moment that branch lands — this file and that one are
  // file-disjoint, and the pair would have turned main red whichever merged
  // second. Measured both ways at this head: L2 before tgw5, L3 after.
  //
  // Pinning the level was never the point anyway. The load-bearing property is
  // that the PATH rule refuses a charter grep in BOTH worlds — that is what
  // "defence in depth" means, and asserting it that way is what makes the
  // assertion independent of the level grammar it is defending against.
  assert.ok(["L2", "L3"].includes(deriveLevel(CHARTER_GREP_SPECIMEN)), `unexpected level ${deriveLevel(CHARTER_GREP_SPECIMEN)}`);
  assert.equal(screenCommand(CHARTER_GREP_SPECIMEN).ok, true);
  assert.equal(refusesAsCharterGrep(CHARTER_GREP_SPECIMEN), true);
  const r = adjudicateCriterion({ index: 0, polarity: "pass", covers: true, criterion: "x", rerun: CHARTER_GREP_SPECIMEN }, REPO);
  assert.equal(r.ok, false);
  assert.equal(r.failCode, "CHARTER-GREP");
  // and it does not over-refuse a non-charter grep
  assert.equal(refusesAsCharterGrep("grep -n checkCeiling tooling/grip/level.mjs"), false);
});

// --- the frozen table --------------------------------------------------------

test("the frozen root criteria declare a polarity or say WHY they cannot, and criterion 2 is never green", () => {
  assert.equal(FROZEN_CRITERIA.length, 4);
  for (const c of FROZEN_CRITERIA) {
    assert.ok(typeof c.criterion === "string" && c.criterion.length > 0);
    if (!c.polarity) assert.ok(c.why, `criterion ${c.index} must say why it has no polarity`);
    if (c.polarity) assert.ok(["pass", "absence"].includes(c.polarity));
  }
  const unmeasured = FROZEN_CRITERIA[1];
  assert.equal(unmeasured.polarity, null, "criterion 2 has no storable rerun until grip CI exists");
  assert.equal(adjudicateCriterion(unmeasured, REPO).ok, false);
});

// --- end to end, on the COMMITTED fixtures ----------------------------------

test("the committed CLEAN fixture exits 0 — the command is able to PASS", () => {
  const r = seal(["--ledger", FIX("clean")]);
  assert.equal(r.status, 0, r.stdout + r.stderr);
  assert.match(r.stdout, /VERDICT-TOKEN: SEAL-PREDICATE HOLDS a=PASS b=PASS b'=PASS c=PASS/);
});

test("the committed DIRTY fixture exits 1 and names ALL FOUR clauses separately", () => {
  const r = seal(["--ledger", FIX("dirty")]);
  assert.equal(r.status, 1);
  for (const clause of CLAUSES) assert.ok(r.stdout.includes(`clause ${clause} fails`), `clause ${clause} must be named`);
  assert.match(r.stdout, /VERDICT-TOKEN: SEAL-PREDICATE NOT-YET a=FAIL b=FAIL b'=FAIL c=FAIL/);
});

test("the dirty fixture's blocking row is one the prior art's direct lens could not see", () => {
  const r = seal(["--ledger", FIX("dirty")]);
  assert.match(r.stdout, /direct lens would MISS 1 row\(s\), 1 of them pooled: tgw2-verify-writes-back/);
});

test("(b') IS A WRITTEN CHECK: removing the root from the pool reds it while its status stays open", () => {
  // The mutation that distinguishes a written (b') from an inherited assumption.
  // The prior art excludes its root by construction — there is nothing to fail.
  const fx = JSON.parse(readFileSync(FIX("clean"), "utf8"));
  assert.equal(fx.root_doc.lifecycle_status, "open");
  assert.ok(fx.pool.includes(ROOT_ID));
  const before = seal(["--ledger", FIX("clean")]);
  assert.equal(before.status, 0);
  assert.match(before.stdout, /=> \(b'\) PASS/);
  const mutated = { ...fx, pool: fx.pool.filter((id) => id !== ROOT_ID) };
  const path = resolve(REPO, "tooling/grip/fixtures/.seal-bprime-mutation.json");
  writeFileSync(path, JSON.stringify(mutated));
  try {
    const after = seal(["--ledger", path]);
    assert.equal(after.status, 1, "a vacuous (b') would still exit 0 here");
    assert.match(after.stdout, /=> \(b'\) FAIL/);
    assert.match(after.stdout, /CLAUSE \(c\) the root closes LAST[\s\S]*lifecycle_status = open/);
    assert.match(after.stdout, /VERDICT-TOKEN: SEAL-PREDICATE NOT-YET a=PASS b=PASS b'=FAIL c=PASS/);
  } finally {
    rmSync(path, { force: true });
  }
});

// --- the honest ceiling ------------------------------------------------------

test("the seal cannot adjudicate its own execution, and says so mechanically", () => {
  const s = screenCommand("node tooling/grip/seal.mjs");
  assert.equal(s.ok, false);
  assert.match(s.reason, /node executes arbitrary JavaScript/);
  assert.equal(deriveLevel("node tooling/grip/seal.mjs"), "L3");
  // and its own live fetch is host-bound-refused three ways
  assert.equal(screenCommand("curl -sG https://guerrilla.barkpark.cloud/v1/data/query/production/task").ok, false);
  // the asymmetry: concealing the host is ADMITTED, declaring it is REFUSED
  assert.equal(screenCommand("bp task list -o json").ok, true);
  assert.equal(screenCommand("bp -s https://guerrilla.barkpark.cloud task list").ok, false);
});

test("the word SEALED never appears in any output path", () => {
  for (const fx of ["clean", "dirty"]) {
    const r = seal(["--ledger", FIX(fx)]);
    assert.ok(!/SEALED/.test(r.stdout + r.stderr), `${fx} printed SEALED`);
  }
  const src = readFileSync(resolve(REPO, "tooling/grip/seal.mjs"), "utf8");
  const inStrings = src.match(/say\([^\n]*SEALED[^\n]*\)/g);
  assert.equal(inStrings, null, "no say() line may carry the word");
});

test("an unreadable --ledger path is an INFRA FAULT path, never a NOT YET", () => {
  const r = seal(["--ledger", resolve(REPO, "tooling/grip/fixtures/NO-SUCH-FIXTURE.json")]);
  assert.notEqual(r.status, 1, "exit 1 must mean NOT YET and nothing else");
});

// ── THE FIXTURE FLOOR ───────────────────────────────────────────────────────
// `(fx.namespace || [])` and `(fx.criteria || [])` used to turn a missing or
// empty key into a LEGAL zero-length corpus: clause (a) is an
// Array.prototype.every over zero items (true by definition) and clause (b)
// walks zero rows, so an empty fixture printed "0 published task rows" and
// still exited 0 with "VERDICT: THE PREDICATE HOLDS". These are the mutation
// controls that catch a regression back to that `|| []` default.

function tmpFixture(name, patch) {
  const base = JSON.parse(readFileSync(FIX("clean"), "utf8"));
  const path = resolve(REPO, `tooling/grip/fixtures/.seal-${name}-mutation.json`);
  writeFileSync(path, JSON.stringify({ ...base, ...patch }));
  return path;
}

test("an empty namespace fixture is refused as INFRA, never a vacuous HOLDS", () => {
  const path = tmpFixture("empty-namespace", { namespace: [] });
  try {
    const r = seal(["--ledger", path]);
    assert.equal(r.status, 2, r.stdout + r.stderr);
    assert.ok(!r.stdout.includes("THE PREDICATE HOLDS"), "an empty namespace must never print a HOLDS verdict");
    assert.match(r.stdout, /fixture key "namespace" is missing or empty/);
    assert.ok(r.stdout.includes(path), "the refusal must name the fixture path");
  } finally {
    rmSync(path, { force: true });
  }
});

test("an empty criteria fixture is refused as INFRA, never a vacuous HOLDS", () => {
  const path = tmpFixture("empty-criteria", { criteria: [] });
  try {
    const r = seal(["--ledger", path]);
    assert.equal(r.status, 2, r.stdout + r.stderr);
    assert.ok(!r.stdout.includes("THE PREDICATE HOLDS"), "an empty criteria must never print a HOLDS verdict");
    assert.match(r.stdout, /fixture key "criteria" is missing or empty/);
    assert.ok(r.stdout.includes(path), "the refusal must name the fixture path");
  } finally {
    rmSync(path, { force: true });
  }
});

test("a fixture missing the namespace/criteria key entirely (not just []) is refused the same way", () => {
  const base = JSON.parse(readFileSync(FIX("clean"), "utf8"));
  const { namespace, ...withoutNamespace } = base;
  const path = resolve(REPO, "tooling/grip/fixtures/.seal-missing-namespace-key-mutation.json");
  writeFileSync(path, JSON.stringify(withoutNamespace));
  try {
    const r = seal(["--ledger", path]);
    assert.equal(r.status, 2, r.stdout + r.stderr);
    assert.ok(!r.stdout.includes("THE PREDICATE HOLDS"));
    assert.match(r.stdout, /fixture key "namespace" is missing or empty/);
  } finally {
    rmSync(path, { force: true });
  }
});

test("a fixture whose root is absent from its own namespace is refused as INFRA, not trusted off root_doc", () => {
  // rootDoc is derived from rows.get(ROOT_ID), never from a separate `root_doc`
  // field: a fixture can otherwise CLAIM a root status with no row to back it.
  const base = JSON.parse(readFileSync(FIX("clean"), "utf8"));
  const namespace = base.namespace.filter((r) => r._id !== ROOT_ID);
  assert.ok(namespace.length > 0, "the premise of this test is a non-empty namespace missing only the root");
  const path = tmpFixture("absent-root", { namespace });
  try {
    const r = seal(["--ledger", path]);
    assert.equal(r.status, 2, r.stdout + r.stderr);
    assert.ok(!r.stdout.includes("THE PREDICATE HOLDS"));
    assert.match(r.stdout, new RegExp(`${ROOT_ID} is not in the walked corpus`));
  } finally {
    rmSync(path, { force: true });
  }
});

test("MUTATION PROOF: a well-formed fixture still exits 0 with the unchanged verdict — the floor does not break the happy path", () => {
  const r = seal(["--ledger", FIX("clean")]);
  assert.equal(r.status, 0, r.stdout + r.stderr);
  assert.match(r.stdout, /VERDICT: THE PREDICATE HOLDS — all four clauses pass\. The root may close, LAST\./);
  assert.match(r.stdout, /VERDICT-TOKEN: SEAL-PREDICATE HOLDS a=PASS b=PASS b'=PASS c=PASS/);
});

// ── THE POOL RECONCILIATION ─────────────────────────────────────────────────
// The merged gate asserted `allUnique === allCount` and so faulted on a
// duplicate doc_id in the SERVER's own listing. That is a real live condition —
// `akbr-feedback-2026-08-epic` is served twice by `bp task ready --all`, filed
// as the still-open `tgw12-bl-seal-infra-fault-ready-pool-ghost` — and it made
// every live run exit 2 with a=UNKNOWN, so no clause was ever evaluated. These
// controls pin BOTH halves: the live shape must reconcile, and a genuinely
// partial read must still fault.

const poolReport = (walk, all) => ({
  ids: new Set(walk), walked: walk.length, duplicates: walk.length - new Set(walk).size,
  allIds: new Set(all), allCount: all.length, allUnique: new Set(all).size,
  allDuplicates: all.length - new Set(all).size, pages: [walk.length],
});

test("a duplicate doc_id in the server's listing is DEDUPED and reported, never an INFRA FAULT", () => {
  // The live shape, reproduced: one doc_id served twice by both reads.
  const r = reconcilePool(poolReport(["a", "b", "b", "c"], ["a", "b", "b", "c"]));
  assert.equal(r.ok, true, "the merged gate faulted here and made the command permanently inert");
  assert.match(r.detail, /DEDUPED/);
  assert.match(r.detail, /1 duplicate doc_id\(s\) in --all and 1 in the walk/);
});

test("EQUAL TOTALS ARE NOT AN EQUAL SET — a skip and a duplicate cancel, and the sets still catch it", () => {
  // The walk skipped "c" and served "b" twice. Both totals read 4. A size-only
  // reconciliation passes this; the set difference does not.
  const rep = poolReport(["a", "b", "b", "d"], ["a", "b", "c", "d"]);
  assert.equal(rep.walked, rep.allCount, "the premise of this test is that the TOTALS agree");
  const r = reconcilePool(rep);
  assert.equal(r.ok, false);
  assert.match(r.detail, /agree on the TOTAL \(4\) but not on the SET/);
  assert.match(r.detail, /the walk misses 1 \(c\)/);
});

test("a walk that carries a row --all does not list is a fault, and the row is NAMED", () => {
  const r = reconcilePool(poolReport(["a", "b", "ghost"], ["a", "b", "c"]));
  assert.equal(r.ok, false);
  assert.match(r.detail, /carries 1 that --all does not list \(ghost\)/);
});

test("a raw total mismatch faults before the sets are even differenced", () => {
  const r = reconcilePool(poolReport(["a", "b"], ["a", "b", "c"]));
  assert.equal(r.ok, false);
  assert.match(r.detail, /offset walk returned 2 row\(s\), --all returned 3/);
  assert.doesNotMatch(r.detail, /SET/, "a size mismatch is its own finding, not a set report");
});

test("the clamp guard sits on PAGE, not on the pool size — a healthy 3010-row pool must reconcile", () => {
  assert.ok(PAGE < 1000, "PAGE must stay under the server's silent 1000 clamp");
  const big = Array.from({ length: 3010 }, (_, i) => `t${i}`);
  assert.equal(reconcilePool(poolReport(big, big)).ok, true,
    "the merged gate faulted on any pool >= 1000, which is every live pool today");
});

test("a missing pool report is a fault, never a silent pass", () => {
  assert.equal(reconcilePool(null).ok, false);
  assert.equal(reconcilePool(undefined).ok, false);
});
