// ci-boundary.test.mjs — the predicate's own selftest.
//
// Drives compare() on SYNTHETIC baselines, so it needs no symbol graph, no mix,
// and no network — the same dependency-free shape as the rest of concept-map.
//
// WHAT IT IS ACTUALLY DEFENDING. The gate this file tests spent months keyed on
// concept IDENTITY, and a concept identity is a directory name. Every new feature
// folder therefore minted identities the baseline had never seen, and the gate
// read all of them as "new architectural debt". On main it reported 108 identity
// regressions and meant 8. The rule below — compare only the subgraph both sides
// can speak about, report growth apart — is the fix, and these cases pin it in
// BOTH directions: growth must not red, and a real edge between two long-known
// concepts must still red, by name.
//
// The both-directions half is the load-bearing half. A predicate that reds on
// nothing would pass every "growth is not a regression" case in this file, which
// is why every such case is paired with an assertion that the gate DOES still
// fire on the mutation next to it.

import { test } from "node:test";
import assert from "node:assert/strict";

import { compare, baselineConcepts } from "./ci-boundary.mjs";
import {
  isCompositionRootFile,
  isEntryPoint,
  isMixTaskFile,
  isWebLayerFile,
} from "./entrypoints.mjs";

// A baseline that knows exactly four concepts: kernel `core`, features `alpha`,
// `beta`, `gamma`. It carries one sideways edge and one wrong-direction edge.
const BASE = {
  kernel: ["core"],
  counts: { sideways: 1, wrongDirection: 1, featureCycles: 0 },
  edges: { sideways: ["alpha>beta"], wrongDirection: ["core>alpha"] },
  featureCyclePairs: [],
};

const metrics = (sideways = [], wrongDirection = [], featureCyclePairs = []) => ({
  counts: {
    sideways: sideways.length,
    wrongDirection: wrongDirection.length,
    featureCycles: featureCyclePairs.length,
  },
  edges: { sideways, wrongDirection },
  featureCyclePairs,
});

const edgesNamed = (res) =>
  res.regressions.filter((r) => r.kind === "new-edge").map((r) => r.edge);
const cyclesNamed = (res) =>
  res.regressions.filter((r) => r.kind === "new-cycle").map((r) => r.pair);

test("baselineConcepts reads the roster out of the baseline's own text", () => {
  const known = baselineConcepts(BASE);
  assert.deepEqual([...known].sort(), ["alpha", "beta", "core"]);
  // `gamma` is NOT known: the baseline names it nowhere. That is the documented
  // blind spot — a concept that existed but carried no debt is indistinguishable
  // from one that did not exist — and it is asserted here so the trade-off is a
  // fact in the test suite rather than a claim in a comment.
  assert.ok(!known.has("gamma"));
});

test("the baseline's own graph, replayed unchanged, is not a regression", () => {
  const res = compare(metrics(["alpha>beta"], ["core>alpha"]), BASE);
  assert.equal(res.regressed, false, "an unchanged graph must be green");
  assert.deepEqual(res.comparableCounts, { sideways: 1, wrongDirection: 1, featureCycles: 0 });
});

test("GROWTH: a new concept's edges are informational, never a regression", () => {
  // `delta` did not exist at baseline. Everything it touches is growth.
  const res = compare(
    metrics(["alpha>beta", "delta>alpha", "delta>beta", "alpha>delta"], ["core>alpha"]),
    BASE
  );
  assert.equal(res.regressed, false, "growth in a new concept must not red the gate");
  assert.deepEqual(res.growth.newConcepts, ["delta"]);
  assert.equal(res.growth.counts.sideways, 3);
  assert.deepEqual(res.growth.sideways, ["alpha>delta", "delta>alpha", "delta>beta"]);
  // and the comparable slice is untouched by the growth
  assert.equal(res.comparableCounts.sideways, 1);
});

test("REAL: a new edge between two BASELINE-KNOWN concepts still reds, by name", () => {
  // `beta>alpha` is new; both ends were known in June. This is the mutation that
  // proves the growth partition did not blind the gate.
  const res = compare(metrics(["alpha>beta", "beta>alpha"], ["core>alpha"]), BASE);
  assert.equal(res.regressed, true);
  assert.deepEqual(edgesNamed(res), ["beta>alpha"]);
});

test("REAL survives a flood of growth around it", () => {
  // The failure mode that mattered: one real edge drowned in 100 growth rows.
  // Here the real edge must be the ONLY thing named.
  const noise = ["delta>alpha", "delta>beta", "epsilon>delta", "alpha>epsilon", "beta>delta"];
  const res = compare(metrics(["alpha>beta", "beta>alpha", ...noise], ["core>alpha"]), BASE);
  assert.equal(res.regressed, true);
  assert.deepEqual(edgesNamed(res), ["beta>alpha"], "growth must not appear in the red list");
  assert.equal(res.growth.counts.sideways, 5);
});

test("a wrong-direction edge into a known concept reds; into a new one does not", () => {
  const red = compare(metrics(["alpha>beta"], ["core>alpha", "core>beta"]), BASE);
  assert.equal(red.regressed, true);
  assert.deepEqual(edgesNamed(red), ["core>beta"]);

  const informational = compare(metrics(["alpha>beta"], ["core>alpha", "core>delta"]), BASE);
  assert.equal(informational.regressed, false);
  assert.deepEqual(informational.growth.wrongDirection, ["core>delta"]);
});

test("a baseline KERNEL reaching a new concept is bucketed NOTABLE, not red", () => {
  const res = compare(metrics(["alpha>beta"], ["core>alpha", "core>delta"]), BASE);
  assert.equal(res.regressed, false);
  assert.deepEqual(res.growth.kernelReach, ["core>delta"]);
  // A feature reaching a new concept is ordinary growth, NOT kernelReach.
  const plain = compare(metrics(["alpha>beta", "alpha>delta"], ["core>alpha"]), BASE);
  assert.deepEqual(plain.growth.kernelReach, []);
});

test("COUNTS are compared on the known subgraph, not on the whole graph", () => {
  // 6 sideways edges in total, but only the 1 baseline edge is comparable. The
  // old predicate reported "count rose from 1 to 6"; the fixed one reports flat.
  const res = compare(
    metrics(["alpha>beta", "delta>alpha", "delta>beta", "epsilon>alpha", "epsilon>beta", "delta>epsilon"], [
      "core>alpha",
    ]),
    BASE
  );
  assert.equal(res.regressed, false);
  assert.equal(res.comparableCounts.sideways, 1);
  assert.equal(res.growth.counts.sideways, 5);
});

test("a count rise WITHIN the known subgraph still reds", () => {
  // Same shape as above but with one extra KNOWN-to-KNOWN edge. The count row
  // must come back — otherwise the previous case is passing on blindness.
  const res = compare(
    metrics(["alpha>beta", "beta>alpha", "delta>alpha", "delta>beta"], ["core>alpha"]),
    BASE
  );
  const counts = res.regressions.filter((r) => r.kind === "count");
  assert.equal(counts.length, 1);
  assert.equal(counts[0].dimension, "sideways");
  assert.equal(counts[0].baseline, 1);
  assert.equal(counts[0].current, 2);
});

test("paying debt down is silently fine, and never negative", () => {
  const res = compare(metrics([], []), BASE);
  assert.equal(res.regressed, false);
  assert.deepEqual(res.comparableCounts, { sideways: 0, wrongDirection: 0, featureCycles: 0 });
});

test("cycles follow the same partition, in both directions", () => {
  const growthOnly = compare(metrics(["delta>alpha", "alpha>delta"], [], ["alpha|delta"]), BASE);
  assert.equal(growthOnly.regressed, false);
  assert.deepEqual(growthOnly.growth.featureCycles, ["alpha|delta"]);

  const real = compare(
    metrics(["alpha>beta", "beta>alpha"], ["core>alpha"], ["alpha|beta"]),
    BASE
  );
  assert.equal(real.regressed, true);
  assert.deepEqual(cyclesNamed(real), ["alpha|beta"]);
});

test("a reshuffle inside the known subgraph is still a regression", () => {
  // Flat count, one known edge swapped for another known-to-known edge. The
  // identity check is what catches this, and the growth partition must not have
  // cost us it.
  const res = compare(metrics(["beta>alpha"], ["core>alpha"]), BASE);
  assert.equal(res.regressed, true);
  assert.deepEqual(edgesNamed(res), ["beta>alpha"]);
  assert.equal(
    res.regressions.filter((r) => r.kind === "count").length,
    0,
    "the count is flat; only the identity row should fire"
  );
});

test("importing this module does not run the gate", () => {
  // The CLI guard in ci-boundary.mjs. Without it, this whole file would have
  // rebuilt the symbol graph and run the real gate as an import side effect —
  // and the tests would have been measuring the repo, not the predicate.
  assert.equal(typeof compare, "function");
  assert.equal(typeof baselineConcepts, "function");
});

// ── the fresh-tree preflight ────────────────────────────────────────────────
//
// A freshly created git worktree has NEITHER of the two artefacts this gate
// reads: tooling/blast-radius/index.json and tooling/symbol-graph/symbols.json
// are both gitignored, and this script builds neither. Measured on origin/main
// 7af839d56a, node v22.22.0, in a worktree seconds old:
//
//   ci-boundary.mjs --json               -> a CONFIDENT VERDICT (11 regressions,
//                                           exit 1) computed from heuristic
//                                           edges against an exact-edge
//                                           baseline. CI does not produce that
//                                           verdict for the same tree.
//   ci-boundary.mjs --skip-build --json  -> two uncaught stack traces and exit 1
//                                           — the REGRESSION code, for a tree
//                                           that could not be READ.
//
// The cases below PLANT such a tree (a temp dir with the artefacts absent,
// empty, malformed, or cold) and pin the refusal: one line, naming the build
// command, exit 2. As with the growth cases above, every "refuses" case is
// paired with a "does NOT refuse" case, because a preflight that refused
// everything would pass every refusal assertion in this file and make the gate
// unrunnable rather than honest.

import { mkdtempSync, writeFileSync as _write, mkdirSync, copyFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join as _join } from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath, pathToFileURL } from "node:url";

import { coldIndexReason, preflightRefusal } from "./ci-boundary.mjs";

// Plant a tree: a temp repo root with tooling/blast-radius and
// tooling/symbol-graph, populated only with what the case asks for.
function plantTree({ index, symbols } = {}) {
  const root = mkdtempSync(_join(tmpdir(), "ci-boundary-freshtree-"));
  mkdirSync(_join(root, "tooling", "blast-radius"), { recursive: true });
  mkdirSync(_join(root, "tooling", "symbol-graph"), { recursive: true });
  const indexPath = _join(root, "tooling", "blast-radius", "index.json");
  const symbolsPath = _join(root, "tooling", "symbol-graph", "symbols.json");
  if (index !== undefined) _write(indexPath, index);
  if (symbols !== undefined) _write(symbolsPath, symbols);
  return { root, indexPath, symbolsPath };
}

const WARM_INDEX = JSON.stringify({ elixir: { forward: { "api/lib/barkpark/content.ex": [] } } });

test("a planted tree with NO blast-radius index refuses, in one line, naming the build command", () => {
  const t = plantTree();
  const msg = preflightRefusal({ indexPath: t.indexPath, symbolsPath: t.symbolsPath });
  assert.ok(msg, "a tree without the index must not be gated");
  assert.equal(msg.split("\n").length, 1, "the refusal is ONE line — a stack trace is the thing being replaced");
  assert.match(msg, /node tooling\/blast-radius\/build-index\.mjs/);
  assert.match(msg, /tooling\/blast-radius\/index\.json/);
});

test("the refusal never carries a stack frame", () => {
  const t = plantTree();
  const msg = preflightRefusal({ indexPath: t.indexPath, symbolsPath: t.symbolsPath });
  assert.doesNotMatch(msg, /^\s+at /m);
  assert.doesNotMatch(msg, /\.mjs:\d+:\d+/);
});

test("an empty, a malformed, a graph-less and an EMPTY-graph index each refuse by their own reason", () => {
  // Four distinct cold shapes. build-index.mjs is best-effort by design — it
  // catches a failed `mix xref` and writes an index with no elixir graph,
  // exiting 0 — so "the file is there" is NOT the question the gate must ask.
  const cases = [
    ["", /is empty/],
    ["{not json", /not parseable JSON/],
    [JSON.stringify({ js: {} }), /no elixir\.forward graph/],
    [JSON.stringify({ elixir: { forward: {} } }), /EMPTY elixir\.forward graph/],
  ];
  for (const [body, expected] of cases) {
    const t = plantTree({ index: body });
    const reason = coldIndexReason(t.indexPath);
    assert.ok(reason, `cold shape ${JSON.stringify(body).slice(0, 30)} must be rejected`);
    assert.match(reason, expected);
    const msg = preflightRefusal({ indexPath: t.indexPath, symbolsPath: t.symbolsPath });
    assert.equal(msg.split("\n").length, 1);
    assert.match(msg, /node tooling\/blast-radius\/build-index\.mjs/);
  }
});

test("a WARM index is not refused — the preflight can still say yes", () => {
  // The non-vacuity arm. Without it every assertion above is satisfied by a
  // preflight that refuses unconditionally, which would not fix the gate, it
  // would retire it.
  const t = plantTree({ index: WARM_INDEX });
  assert.equal(coldIndexReason(t.indexPath), null);
  assert.equal(preflightRefusal({ indexPath: t.indexPath, symbolsPath: t.symbolsPath }), null);
});

test("--skip-build on a tree with no symbol graph refuses, naming build-symbols.mjs", () => {
  // The shape that produced TWO stack traces and exit 1 on a fresh worktree.
  const t = plantTree({ index: WARM_INDEX });
  const msg = preflightRefusal({ indexPath: t.indexPath, symbolsPath: t.symbolsPath, skipBuild: true });
  assert.ok(msg);
  assert.equal(msg.split("\n").length, 1);
  assert.match(msg, /node tooling\/symbol-graph\/build-symbols\.mjs/);
  assert.doesNotMatch(msg, /^\s+at /m);
});

test("--skip-build WITH a symbol graph present is not refused", () => {
  const t = plantTree({ index: WARM_INDEX, symbols: "{}" });
  assert.equal(
    preflightRefusal({ indexPath: t.indexPath, symbolsPath: t.symbolsPath, skipBuild: true }),
    null
  );
});

test("--allow-cold-index waives the index check and ONLY the index check", () => {
  // The override is about index WARMTH. It must not talk a run into reading a
  // symbol graph that is not in the tree — that is the stack-trace path again.
  const cold = plantTree({ symbols: "{}" });
  assert.equal(
    preflightRefusal({ indexPath: cold.indexPath, symbolsPath: cold.symbolsPath, allowCold: true }),
    null
  );
  const noSymbols = plantTree();
  const msg = preflightRefusal({
    indexPath: noSymbols.indexPath,
    symbolsPath: noSymbols.symbolsPath,
    skipBuild: true,
    allowCold: true,
  });
  assert.ok(msg, "allowCold must not waive a missing symbol graph under --skip-build");
  assert.match(msg, /build-symbols\.mjs/);
});

test("END TO END: the wrapper run inside a planted tree exits 2 with one line and no stack trace", () => {
  // The whole point, exercised through the real CLI rather than its parts.
  // ci-boundary.mjs derives its repo root from its OWN location, so copying the
  // file into a temp tree whose tooling/blast-radius is empty IS a fresh
  // worktree as far as the script can tell — no symbol graph, no mix, no
  // network, and none of its sibling scripts present either.
  //
  // Against the PRE-FIX wrapper this run reaches rebuildGraph() first and dies
  // on the absent build-symbols.mjs: a stack trace and exit 1 — the REGRESSION
  // code. Both assertions below fail there.
  const root = mkdtempSync(_join(tmpdir(), "ci-boundary-e2e-"));
  mkdirSync(_join(root, "tooling", "concept-map"), { recursive: true });
  mkdirSync(_join(root, "tooling", "blast-radius"), { recursive: true });
  const planted = _join(root, "tooling", "concept-map", "ci-boundary.mjs");
  copyFileSync(fileURLToPath(new URL("./ci-boundary.mjs", import.meta.url)), planted);

  let status = null;
  let stderr = "";
  try {
    execFileSync(process.execPath, [planted, "--json"], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
    status = 0;
  } catch (err) {
    status = err.status;
    stderr = String(err.stderr || "");
  }

  assert.equal(status, 2, "a tree that cannot be gated is a FAULT (2), never a REGRESSION (1)");
  const lines = stderr.split("\n").filter((l) => l.trim());
  assert.equal(lines.length, 1, `expected exactly one line of output, got:\n${stderr}`);
  assert.match(lines[0], /node tooling\/blast-radius\/build-index\.mjs/);
  assert.doesNotMatch(stderr, /^\s+at /m, "no stack frames");
  assert.doesNotMatch(stderr, /Command failed/);
});

// ── the ENTRY-POINT predicate itself ──────────────────────────────────────────
//
// entrypoints.mjs is the other half of what this workflow step calls "the
// boundary predicate": compare() decides whether an edge is a REGRESSION, and
// isEntryPoint() decides whether the edge is counted at all. It is pinned HERE
// rather than in a file of its own because this is the only concept-map test the
// architecture workflow executes — a selftest CI never runs defends nothing.
//
// Both directions, per the rule at the top of this file: the composition root is
// an entry-point, and the things next to it in the tree still are not.

test("the OTP composition root is an entry-point; its neighbours are not", () => {
  assert.equal(isCompositionRootFile("api/lib/barkpark/application.ex"), true);
  assert.equal(isEntryPoint("api/lib/barkpark/application.ex"), true);

  // It is the COMPOSITION-ROOT rule that admits it, not the web or Mix rule —
  // otherwise this case would still pass with the new predicate deleted.
  assert.equal(isWebLayerFile("api/lib/barkpark/application.ex"), false);
  assert.equal(isMixTaskFile("api/lib/barkpark/application.ex"), false);

  // The RED-WITHOUT half: ordinary domain modules, including the two whose
  // edges from start/2 prompted the re-banding, stay feature members.
  for (const f of [
    "api/lib/barkpark/tasks/compactor.ex",
    "api/lib/barkpark/sheets/supervisor.ex",
    "api/lib/barkpark/telemetry.ex",
    "api/lib/barkpark/vault.ex",
  ]) {
    assert.equal(isEntryPoint(f), false, `${f} must NOT be an entry-point`);
  }
});

test("the composition-root rule is EXACT-PATH, not a *application.ex pattern", () => {
  // A pattern would silently re-band a future unrelated file and quietly drop
  // its edges from the gate. There is one composition root; match only it.
  for (const f of [
    "api/lib/barkpark/plugins/tasks/application.ex",
    "api/lib/other_app/application.ex",
    "api/lib/barkpark/application/child_spec.ex",
    "api/lib/barkpark/application_config.ex",
  ]) {
    assert.equal(isCompositionRootFile(f), false, `${f} must NOT match the composition root`);
    assert.equal(isEntryPoint(f), false, `${f} must NOT be an entry-point`);
  }
});

// ── ACCEPTED-UNTIL-FIXED: the three arms, and their mutation harness ────────
//
// The list is what lets this gate BLOCK on a tree that still carries real debt,
// so it is the one place a blocking gate can be talked into silence. Three arms
// keep it honest, and each is pinned here BOTH ways: a case that fires it, and
// — below — a MUTATION that neuters that arm in a copy of the module and proves
// the case stops firing. An arm nobody has ever seen fail is not an arm.

import { readFileSync as _read } from "node:fs";
import {
  loadAcceptedEntries,
  auditAccepted,
  ACCEPTED_PATH,
} from "./ci-boundary.mjs";

const CI_BOUNDARY_SRC = fileURLToPath(new URL("./ci-boundary.mjs", import.meta.url));

const entry = (identity, row, dimension = "wrongDirection") => ({
  identity,
  dimension,
  row,
  intent: "test fixture",
  since: "2026-09-05",
});

// ── the loader ──────────────────────────────────────────────────────────────

test("the loader REFUSES an entry with no row id — an acceptance with nobody on the hook", () => {
  assert.throws(
    () => loadAcceptedEntries({ entries: [{ identity: "alpha>beta", intent: "because" }] }),
    /carries no bp task row id/
  );
  // and the paired direction: a well-formed entry loads.
  const ok = loadAcceptedEntries({ entries: [entry("alpha>beta", "task-9d06bca37668f76a")] });
  assert.equal(ok.length, 1);
});

test("the loader refuses a duplicate identity and a non-array entries key", () => {
  assert.throws(
    () =>
      loadAcceptedEntries({
        entries: [entry("alpha>beta", "task-1111"), entry("alpha>beta", "task-2222")],
      }),
    /listed twice/
  );
  assert.throws(() => loadAcceptedEntries({}), /`entries` array/);
});

test("the SHIPPED accepted-until-fixed.json satisfies its own loader", () => {
  // Not a formality: the loader is the only thing standing between this list and
  // an allowlist, and a list that ships unparseable would take the gate to a
  // FAULT on every run of every PR.
  const entries = loadAcceptedEntries(_read(ACCEPTED_PATH, "utf8"));
  // An EMPTY list is the documented end-state ("the durable fix is a SHORTER
  // list, never a longer one"), and arm (a) reds any unlisted identity, so
  // emptiness cannot silence the gate. What must hold is that it LOADS.
  assert.ok(Array.isArray(entries), "the shipped list must load through its own loader");
  for (const e of entries) assert.match(e.row, /^task-[0-9a-f]+$/);
});

// ── ARM (a): never-worse, with the accepted set subtracted ──────────────────

test("ARM (a): an ACCEPTED edge is waved through; an UNACCEPTED one still reds", () => {
  const cur = metrics([], ["core>alpha", "core>beta"]);
  // Unaccepted: both the identity row and the count row fire.
  const bare = compare(cur, BASE);
  assert.deepEqual(edgesNamed(bare), ["core>beta"]);
  assert.ok(bare.regressed);

  // Accepted: silent, AND the comparable count drops so the count arm does not
  // red for the very edge the entry accepts.
  const held = compare(cur, BASE, [entry("core>beta", "task-5641006da86bfa74")]);
  assert.deepEqual(edgesNamed(held), []);
  assert.equal(held.regressed, false, "an accepted identity must not red the gate");
  assert.equal(held.comparableCounts.wrongDirection, 1);
  assert.deepEqual(held.accepted.wrongDirection, ["core>beta"]);
});

test("ARM (a): accepting one edge does NOT wave through its neighbour", () => {
  // The failure this pins: a tolerance keyed on anything looser than the exact
  // identity (a concept, a prefix, a dimension) would swallow the next edge too.
  // A baseline that also KNOWS `gamma` (it names it in a cycle pair), so
  // core>gamma is a comparable identity rather than growth — otherwise this case
  // would pass for the wrong reason.
  const WIDE = {
    kernel: ["core"],
    counts: { sideways: 1, wrongDirection: 1, featureCycles: 0 },
    edges: { sideways: ["alpha>beta"], wrongDirection: ["core>alpha"] },
    featureCyclePairs: ["beta|gamma"],
  };
  const cur = metrics(["alpha>beta"], ["core>alpha", "core>beta", "core>gamma"]);
  const held = compare(cur, WIDE, [entry("core>beta", "task-5641006da86bfa74")]);
  assert.deepEqual(edgesNamed(held), ["core>gamma"]);
  assert.ok(held.regressed, "an edge outside the list must still red");
});

// ── ARM (b): the row closed while the debt is still here ────────────────────

test("ARM (b): a listed row that is done/cancelled while its edge is PRESENT reds, naming the row", () => {
  const entries = [entry("core>beta", "task-5641006da86bfa74")];
  const present = new Set(["core>beta"]);
  for (const closed of ["done", "cancelled"]) {
    const res = auditAccepted({
      entries,
      present,
      lifecycle: new Map([["task-5641006da86bfa74", closed]]),
    });
    assert.ok(res.failed, `lifecycle '${closed}' must red while the edge is present`);
    assert.equal(res.failures[0].arm, "row-closed");
    assert.match(res.failures[0].reason, /task-5641006da86bfa74/);
  }
  // Paired direction: an OPEN row with the edge present is exactly the state the
  // list exists to describe, and must be silent.
  const live = auditAccepted({
    entries,
    present,
    lifecycle: new Map([["task-5641006da86bfa74", "in_progress"]]),
  });
  assert.equal(live.failed, false);
});

test("ARM (b): an UNREADABLE ledger REFUSES loudly — it never reads as green", () => {
  const entries = [entry("core>beta", "task-5641006da86bfa74")];
  const present = new Set(["core>beta"]);
  for (const unreadable of [new Map(), new Map([["task-5641006da86bfa74", null]])]) {
    const res = auditAccepted({ entries, present, lifecycle: unreadable });
    assert.ok(res.failed, "an unreadable ledger must not be a pass");
    assert.equal(res.failures[0].arm, "ledger-unreadable");
    assert.match(res.failures[0].reason, /REFUSING/);
  }
});

// ── ARM (c): healed, so the entry must go ───────────────────────────────────

test("ARM (c): an entry whose edge has DISAPPEARED reds with 'HEALED: delete entry X'", () => {
  const res = auditAccepted({
    entries: [entry("core>beta", "task-5641006da86bfa74")],
    present: new Set(["core>alpha"]),
    lifecycle: new Map([["task-5641006da86bfa74", "in_progress"]]),
  });
  assert.ok(res.failed);
  assert.equal(res.failures[0].arm, "healed");
  assert.match(res.failures[0].reason, /HEALED: delete entry core>beta/);
});

test("all three arms silent together is the ONLY green shape", () => {
  const res = auditAccepted({
    entries: [entry("core>beta", "task-5641006da86bfa74")],
    present: new Set(["core>beta"]),
    lifecycle: new Map([["task-5641006da86bfa74", "open"]]),
  });
  assert.equal(res.failed, false);
  assert.deepEqual(res.failures, []);
});

// ── THE MUTATION HARNESS ────────────────────────────────────────────────────
//
// Copy the module, neuter ONE arm by an exact anchor, and prove the case above
// stops firing. Each mutation asserts its anchor appears EXACTLY ONCE and that
// the rewrite produced a NON-EMPTY diff — a mutation that did not apply is not
// a catch, it is a green test measuring the unmutated file.

let mutantSeq = 0;
async function neuter(anchor, replacement) {
  const src = _read(CI_BOUNDARY_SRC, "utf8");
  const hits = src.split(anchor).length - 1;
  assert.equal(hits, 1, `anchor must appear EXACTLY ONCE in ci-boundary.mjs, found ${hits}: ${anchor}`);
  const mutated = src.replace(anchor, replacement);
  assert.notEqual(mutated, src, "the mutation must produce a non-empty diff");
  const dir = mkdtempSync(_join(tmpdir(), "ci-boundary-mutant-"));
  const file = _join(dir, `mutant-${mutantSeq++}.mjs`);
  _write(file, mutated);
  return await import(pathToFileURL(file).href);
}

test("MUTATION arm (a): a tolerance that accepts EVERYTHING stops the never-worse case firing", async () => {
  const m = await neuter(
    "const isAccepted = (k) => acceptedSet.has(String(k));",
    "const isAccepted = (k) => true;"
  );
  const cur = metrics([], ["core>alpha", "core>beta"]);
  const bare = m.compare(cur, BASE);
  // The un-mutated assertion above is `edgesNamed(bare) === ["core>beta"]`.
  // Under the mutation it is empty — so the arm-(a) case reds, naming arm (a).
  assert.deepEqual(
    bare.regressions.filter((r) => r.kind === "new-edge").map((r) => r.edge),
    [],
    "ARM (a) NEUTERED: with the accept filter always true, an unaccepted edge no longer reds"
  );
});

test("MUTATION arm (b): a lifecycle check that matches nothing stops the closed-row case firing", async () => {
  const m = await neuter("if (CLOSED_LIFECYCLES.has(status)) {", "if (false) {");
  const res = m.auditAccepted({
    entries: [entry("core>beta", "task-5641006da86bfa74")],
    present: new Set(["core>beta"]),
    lifecycle: new Map([["task-5641006da86bfa74", "done"]]),
  });
  assert.equal(res.failed, false, "ARM (b) NEUTERED: a done row with the debt present no longer reds");
});

test("MUTATION arm (b, refusal): an unreadable ledger read as green stops the refusal firing", async () => {
  const m = await neuter(
    'if (status === null || status === undefined || status === "") {',
    "if (false) {"
  );
  const res = m.auditAccepted({
    entries: [entry("core>beta", "task-5641006da86bfa74")],
    present: new Set(["core>beta"]),
    lifecycle: new Map(),
  });
  assert.equal(res.failed, false, "ARM (b) REFUSAL NEUTERED: an unreadable ledger now passes silently");
});

test("MUTATION arm (c): a healed check that never triggers stops the HEALED case firing", async () => {
  const m = await neuter("if (!here) {", "if (false) {");
  const res = m.auditAccepted({
    entries: [entry("core>beta", "task-5641006da86bfa74")],
    present: new Set(["core>alpha"]),
    lifecycle: new Map([["task-5641006da86bfa74", "in_progress"]]),
  });
  assert.equal(res.failed, false, "ARM (c) NEUTERED: a healed entry survives forever");
});
