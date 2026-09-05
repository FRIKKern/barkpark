#!/usr/bin/env node
// ci-boundary.mjs — the never-worse gate, pointed at architecture.
//
// Wires cqv8's boundary check into CI so NEW architectural debt is rejected
// before it lands, while the existing known debt is grandfathered so it doesn't
// break the build. This is the cqv7 never-worse pattern applied to the feature
// boundary: a change may pay debt down, hold it level, or reshuffle it — but it
// may not ADD a feature→feature sideways cluster, a kernel→feature edge, or a
// feature cycle versus the committed baseline.
//
// Pipeline (same substrate the rest of cqv8 rides — reused, not reinvented):
//   1. rebuild the symbol graph        (tooling/symbol-graph/build-symbols.mjs)
//   2. run grade.mjs  --json           (sanity: the five-gap pass still parses)
//   3. run boundary.mjs --json         (the boundary violations themselves)
//   4. derive three regression dimensions from boundary's gate.violations:
//        - sideways         feature→feature edges        (counts.sideways)
//        - wrongDirection   kernel→feature edges          (counts.wrongDirection)
//        - featureCycles    mutual feature↔feature pairs  (derived: A→B & B→A)
//   5. split those identities into the BASELINE-KNOWN SUBGRAPH and GROWTH
//        (see "the growth partition" below), then compare ONLY the known
//        subgraph vs boundary-baseline.json and EXIT NON-ZERO on REGRESSION:
//        a count rose above baseline, OR a specific edge / cycle pair appears
//        that is not in the baseline set. Equal-or-lower counts AND a subset of
//        the baseline edges pass — that is "never worse, possibly better".
//        Growth — anything touching a concept the baseline never saw — is
//        itemised, counted and printed, and is NEVER a regression.
//
// A reshuffle that keeps the count flat but swaps one known edge for a brand-new
// one is STILL a regression: we check both the aggregate count and the concrete
// edge/cycle identities. Paying debt down (a baseline edge disappears) is
// silently fine.
//
// Modes:
//   node tooling/concept-map/ci-boundary.mjs                  run the gate
//   node tooling/concept-map/ci-boundary.mjs --json           gate + JSON report
//   node tooling/concept-map/ci-boundary.mjs --skip-build     don't rebuild graph
//   node tooling/concept-map/ci-boundary.mjs --allow-cold-index
//        run without the warm mix-xref index. The verdict is then HEURISTIC and
//        may disagree with CI's. See "the fresh-tree preflight" below.
//   node tooling/concept-map/ci-boundary.mjs --write-baseline rewrite the baseline
//        from the current graph (intentional debt re-baseline; prints to stdout
//        unless --out is given). NEVER run this to silence a real regression.
//
// Propose-only ethos: this script reads the graph and reports. It never mutates
// repo source. The only file it may write is the baseline, and only under the
// explicit --write-baseline flag.
//
// Dependency-free Node ESM, same as the rest of tooling/concept-map.

import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(HERE, "..", "..");
const BUILD_SYMBOLS = join(REPO_ROOT, "tooling", "symbol-graph", "build-symbols.mjs");
const BOUNDARY = join(HERE, "boundary.mjs");
const GRADE = join(HERE, "grade.mjs");
const BASELINE_PATH = join(HERE, "boundary-baseline.json");

// The two build artefacts this gate READS but never builds. Both are gitignored,
// so a freshly created worktree has NEITHER of them. See "the fresh-tree
// preflight" below.
const INDEX_REL = "tooling/blast-radius/index.json";
const SYMBOLS_REL = "tooling/symbol-graph/symbols.json";
const INDEX_PATH = join(REPO_ROOT, "tooling", "blast-radius", "index.json");
const SYMBOLS_PATH = join(REPO_ROOT, "tooling", "symbol-graph", "symbols.json");
const BUILD_INDEX_CMD = "node tooling/blast-radius/build-index.mjs";
const BUILD_SYMBOLS_CMD = "node tooling/symbol-graph/build-symbols.mjs";

const argv = process.argv.slice(2);
const flag = (name) => argv.includes(name);
const optVal = (name) => {
  const i = argv.indexOf(name);
  return i >= 0 && i + 1 < argv.length ? argv[i + 1] : null;
};

const AS_JSON = flag("--json");
const SKIP_BUILD = flag("--skip-build");
const WRITE_BASELINE = flag("--write-baseline");
const ALLOW_COLD = flag("--allow-cold-index");

// ── small helpers ───────────────────────────────────────────────────────────

function note(msg) {
  // diagnostics go to stderr so --json stdout stays clean
  process.stderr.write(msg + "\n");
}

// Sentinel for "the gate could not read its instrument". Thrown rather than
// exited so the single exit point below can set process.exitCode and let node
// flush — the same drain race this whole file exists to close.
class GateFault extends Error {}

function runNodeJson(scriptPath, extraArgs = []) {
  const out = execFileSync(process.execPath, [scriptPath, "--json", ...extraArgs], {
    cwd: REPO_ROOT,
    maxBuffer: 64 * 1024 * 1024,
    stdio: ["ignore", "pipe", "inherit"],
  });
  const text = out.toString("utf8");
  try {
    return JSON.parse(text);
  } catch (err) {
    // A gate that cannot READ its own instrument must say HOLD, not "regression".
    // Left bare, JSON.parse throws an uncaught SyntaxError, node exits 1, and 1
    // is this script's REGRESSION code — so an unreadable payload renders as
    // architectural debt that nobody added. Exit 2 (fault) instead, and name the
    // failure we have actually seen: a child that calls process.exit() after
    // writing to a PIPE is torn down before the async write drains, cutting the
    // payload short. That is why no script in this pipeline ends in
    // process.exit().
    //
    // REACHABILITY, measured (5 trials per size, piped through `tee`):
    //   1000 / 30000 / 60000 / 65000 / 65535 / 65536 bytes -> ALWAYS complete
    //   70000 -> cut to 65536 on 2 of 5 runs
    //   200000 -> cut to 65536, 73728 or 81920, on 3 of 5 runs
    // So the cut is NOT always one 65536 buffer — 73728 and 81920 were both
    // observed (the cuts land on 8192-byte boundaries). An earlier version of
    // this check tested `length % 65536 === 0` and would have called those two
    // "malformed", which is the wrong diagnosis pointing at the wrong file.
    //
    // What IS reliable is the floor: at or below PIPE_BUF the write fits the
    // buffer and exit() cannot cut it, so truncation is RULED OUT. Above it,
    // truncation is the first thing to suspect.
    const PIPE_BUF = 65536;
    note(`ci-boundary: FAULT — ${scriptPath} did not emit parseable JSON.`);
    note(`  read ${text.length} bytes; ${err.message}`);
    if (text.length >= PIPE_BUF) {
      note(`  ${text.length} bytes is at or above the ${PIPE_BUF}-byte pipe buffer, so this`);
      note(`  is very likely a TRUNCATED payload rather than a malformed one.`);
      note(`  Check that ${scriptPath} does not call process.exit() after writing`);
      note(`  --json to stdout; use process.exitCode and let node flush.`);
    } else {
      note(`  ${text.length} bytes is below the ${PIPE_BUF}-byte pipe buffer, which RULES OUT`);
      note(`  the process.exit() truncation race — this payload is genuinely malformed.`);
    }
    throw new GateFault();
  }
}

// Canonical edge key — stable, ascii, never trips a shell or a diff.
const edgeKey = (from, to) => `${from}>${to}`;
// Cycle pair key — order-independent so A↔B and B↔A collapse to one identity.
const cyclePairKey = (a, b) => [a, b].sort().join("|");

// Pull the three regression dimensions out of a boundary --json payload.
function deriveMetrics(boundary) {
  const violations = (boundary.gate && boundary.gate.violations) || [];

  const sidewaysEdges = [];
  const wrongDirectionEdges = [];
  const sidewaysSet = new Set();

  for (const v of violations) {
    const from = v.from;
    const to = v.to;
    if (v.type === "sideways") {
      const k = edgeKey(from, to);
      sidewaysEdges.push(k);
      sidewaysSet.add(k);
    } else if (v.type === "wrong-direction") {
      wrongDirectionEdges.push(edgeKey(from, to));
    }
  }

  // A feature cycle is a MUTUAL sideways pair: A→B present AND B→A present.
  // This is exactly the cqv8 decycle target (proposeDecycle is pairwise).
  const cyclePairs = new Set();
  for (const v of violations) {
    if (v.type !== "sideways") continue;
    if (sidewaysSet.has(edgeKey(v.to, v.from))) {
      cyclePairs.add(cyclePairKey(v.from, v.to));
    }
  }

  return {
    counts: {
      sideways: sidewaysEdges.length,
      wrongDirection: wrongDirectionEdges.length,
      featureCycles: cyclePairs.size,
    },
    edges: {
      sideways: [...new Set(sidewaysEdges)].sort(),
      wrongDirection: [...new Set(wrongDirectionEdges)].sort(),
    },
    featureCyclePairs: [...cyclePairs].sort(),
  };
}

// ── the fresh-tree preflight ────────────────────────────────────────────────
//
// WHAT A FRESH WORKTREE ACTUALLY DID, measured on origin/main 7af839d56a with
// node v22.22.0, in a worktree created seconds earlier:
//
//   node tooling/concept-map/ci-boundary.mjs --json
//     -> ran to completion and printed a VERDICT: 11 regressions, exit 1.
//        Its own build step confessed on stderr, one line up:
//          "[elixir] no mix-xref graph in index.json — EXACT module edges
//           unavailable (run build-index.mjs to warm)."
//        So the number was heuristic edges judged against an EXACT-edge
//        baseline. Not a crash — WORSE than a crash: a confident verdict that
//        CI, which warms the graph first, does not produce for the same tree.
//
//   node tooling/concept-map/ci-boundary.mjs --skip-build --json
//     -> TWO uncaught stack traces (grade.mjs "symbol graph not found", then
//        execFileSync "Command failed") and exit 1 — and 1 is this gate's
//        REGRESSION code, so a tree that could not be READ was indistinguishable
//        from a tree carrying new architectural debt.
//
// Both are the same missing precondition wearing two faces: this script READS
// two gitignored build artefacts and builds NEITHER of them. architecture.yml
// builds the index (the "Warm the mix-xref module graph" step) and then REFUSES
// to gate without it (the "Assert the warm graph is present" step, exit 2). A
// local run had no equivalent, so the local instrument and the CI instrument
// answered differently on the same commit.
//
// WHY REFUSE RATHER THAN AUTO-BUILD. build-index.mjs shells out to `mix compile`
// + `mix xref graph` and `go list -deps`; on a fresh worktree that needs
// `mix deps.get` first (architecture.yml spends a whole step on it) and is
// minutes, not seconds. Worse, build-index.mjs is BEST-EFFORT BY DESIGN: it
// catches a failed mix and writes an index with no elixir graph, exiting 0. An
// auto-build would therefore be slow AND could hand back exactly the cold index
// this preflight exists to reject, with the gate now believing it had fixed it.
// So: name the command, exit 2, one line, no stack trace.
//
// EXIT 2, NEVER 1 — same reason architecture.yml's assert step uses 2: 1 is the
// REGRESSION code, and an instrument that cannot be warmed has found no debt.

// Is tooling/blast-radius/index.json present AND carrying the exact mix-xref
// module graph? Returns null when warm, else the reason, in one clause.
// Named against the fixed repo-relative path because that is the only file this
// check is ever pointed at.
export function coldIndexReason(indexPath) {
  if (!existsSync(indexPath)) return `no blast-radius index at ${INDEX_REL} (this tree was never warmed)`;
  let raw;
  try {
    raw = readFileSync(indexPath, "utf8");
  } catch (err) {
    return `${INDEX_REL} could not be read (${err.code || err.message})`;
  }
  if (!raw.trim()) return `${INDEX_REL} is empty`;
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return `${INDEX_REL} is not parseable JSON`;
  }
  const forward = parsed && parsed.elixir && parsed.elixir.forward;
  if (!forward || typeof forward !== "object")
    return `${INDEX_REL} carries no elixir.forward graph (mix compile or mix xref did not run)`;
  if (Object.keys(forward).length === 0) return `${INDEX_REL} has an EMPTY elixir.forward graph`;
  return null;
}

// The whole preflight, as a pure function over paths so ci-boundary.test.mjs can
// plant a tree without the index and drive it with no symbol graph, no mix and
// no network. Returns null when the tree can produce CI's verdict, else THE ONE
// LINE to print before exiting 2. One line is a contract, not a style note: a
// gate that answers a missing precondition with a stack trace teaches every
// reader to ignore its output.
export function preflightRefusal({ indexPath, symbolsPath, skipBuild = false, allowCold = false }) {
  if (!allowCold) {
    const cold = coldIndexReason(indexPath);
    if (cold) {
      return (
        `ci-boundary: REFUSING to gate an unwarmed tree — ${cold}; build it first: ${BUILD_INDEX_CMD} ` +
        `(a cold run compares HEURISTIC edges against an EXACT-edge baseline and silently misstates the debt; ` +
        `pass --allow-cold-index to override)`
      );
    }
  }
  // --skip-build reuses a symbol graph this script did not build. Without one,
  // grade.mjs throws and execFileSync rethrows, two stack traces deep.
  // `allowCold` deliberately does NOT waive this: it is about index WARMTH, not
  // about reading a file that is not there.
  if (skipBuild && !existsSync(symbolsPath)) {
    return (
      `ci-boundary: REFUSING — --skip-build reuses a symbol graph that is not in this tree (${SYMBOLS_REL}); ` +
      `build it first: ${BUILD_SYMBOLS_CMD} (or drop --skip-build and let this script build it)`
    );
  }
  return null;
}

// ── pipeline ──────────────────────────────────────────────────────────────

function rebuildGraph() {
  if (SKIP_BUILD) {
    note("ci-boundary: --skip-build → reusing existing symbol graph");
    return;
  }
  note("ci-boundary: rebuilding symbol graph …");
  execFileSync(process.execPath, [BUILD_SYMBOLS], {
    cwd: REPO_ROOT,
    maxBuffer: 64 * 1024 * 1024,
    stdio: ["ignore", "inherit", "inherit"],
  });
}

function gradeSanity() {
  // We run grade purely as a substrate sanity check: if grade.mjs can't parse
  // the freshly-built graph, the boundary numbers can't be trusted either.
  const g = runNodeJson(GRADE);
  note(
    `ci-boundary: grade ok — ${g.counts.total} concepts ` +
      `(${g.counts.kernel} kernel · ${g.counts.clean} clean · ${g.counts.tangled} tangled)`
  );
  return g;
}

function loadBaseline() {
  if (!existsSync(BASELINE_PATH)) {
    note(`ci-boundary: FATAL — no baseline at ${BASELINE_PATH}`);
    note("ci-boundary: capture one with --write-baseline before gating.");
    // GateFault, not exit(2): this file states at its single exit point that
    // faults are THROWN so exitCode can be set and node allowed to flush.
    // This one call was the exception to that contract — found by
    // scripts/workflow-run-shell-check.sh arm B, on the very file whose
    // header documents the race.
    throw new GateFault();
  }
  return JSON.parse(readFileSync(BASELINE_PATH, "utf8"));
}

// ── the growth partition ────────────────────────────────────────────────────
//
// WHY THIS EXISTS. The identity check below is keyed on the CONCEPT NAME, and a
// concept name is a directory: concepts.mjs derives it structurally from
// `api/lib/barkpark/<name>` and `api/lib/barkpark/plugins/<name>`. So the moment
// a new feature folder lands, every edge it participates in is an identity the
// baseline has never seen — and a never-worse gate keyed on identity reds on ALL
// of it, forever, for a reason nobody in the PR can act on.
//
// MEASURED, not assumed. Against the June baseline (46 concepts in the tree at
// its own commit, 44 of them named somewhere in the file) the tree on main today
// carries 79 — 33 concepts that did not exist when the baseline was captured.
// Of the 108 identity regressions the WARM gate reported on main, 100 involve at
// least one of those 33. Only 8 are edges between two concepts the baseline
// already knew. The gate was reporting 108 and meaning 8.
//
// THE RULE. A concept is BASELINE-KNOWN if the baseline mentions it at all — in
// `kernel`, as either endpoint of any edge, or as a member of any cycle pair.
// An edge or cycle all of whose concepts are baseline-known is COMPARABLE: it is
// checked by identity and by count exactly as before, and a new one still reds.
// Anything touching a concept the baseline never saw is GROWTH: itemised in the
// report, counted, printed — and never red, because the baseline holds no
// opinion about a module that did not exist.
//
// THE TRADE-OFF, stated rather than buried. Deriving the roster from the
// baseline's own text is inference, not a record: a concept that existed in June
// but had NO boundary debt is indistinguishable from one that did not exist, so
// its first sideways edge lands in the growth bucket instead of reddening. That
// set is exactly two concepts today — `env_config` and `release`, present at the
// baseline commit and named nowhere in the baseline — and neither appears in any
// current violation, so the blind spot costs zero rows right now. Closing it for
// good needs an ADDITIVE `conceptsKnownAtCapture` roster on the baseline; that is
// a separate change, because writing to boundary-baseline.json is exactly the
// move this gate must never make to go green.
//
// THE ONE GROWTH SHAPE THAT IS STILL WORTH SAYING OUT LOUD: a BASELINE KERNEL
// concept reaching a brand-new feature. `content → preview` is not a new module
// misbehaving; it is the substrate acquiring a dependency on a leaf that did not
// exist. It stays informational (the leaf is growth, and reddening it would put
// every new feature's first kernel caller on the hook) but it is bucketed and
// named apart from ordinary growth so it cannot hide in a count.

// Every concept the baseline has an opinion about. Anything else is growth.
export function baselineConcepts(baseline) {
  const known = new Set(baseline.kernel || []);
  const edges = baseline.edges || {};
  for (const dim of ["sideways", "wrongDirection"]) {
    for (const e of edges[dim] || []) for (const c of String(e).split(">")) known.add(c);
  }
  for (const p of baseline.featureCyclePairs || []) {
    for (const c of String(p).split("|")) known.add(c);
  }
  return known;
}

const conceptsOfEdge = (e) => String(e).split(">");
const conceptsOfPair = (p) => String(p).split("|");

// ── ACCEPTED-UNTIL-FIXED: the three arms that let this gate BLOCK ───────────
//
// The gate was advisory for its whole life because today's tree carries real
// regressions and a blocking gate would have reddened every PR for debt nobody
// on that PR added. The accepted list is how it becomes blocking WITHOUT
// pretending the debt is gone: a small, named, row-backed set of identities the
// gate tolerates, and three arms that make the set DECAY.
//
//   (a) NEVER-WORSE — anything not on the list still reds. This is the arm the
//       gate already had; the list only subtracts, it never adds tolerance for
//       an identity that is not written down.
//   (b) ROW CLOSED, DEBT PRESENT — a listed row that is done/cancelled while its
//       identity is STILL in the graph. Somebody closed the row without paying
//       the edge down, and without this arm the acceptance would outlive its
//       justification silently, forever.
//   (c) HEALED — a listed identity that is GONE from the graph. The entry has
//       nothing left to accept, so it must be deleted in the PR that healed it.
//       Without this arm the list only ever grows, and a list that grows stops
//       discriminating: the Nth entry is waved through by the N-1 above it.
//
// (b) needs the ledger. If the ledger cannot be read the arm REFUSES — exit
// non-zero, named — and never falls through to green. An acceptance whose
// justification could not be checked is not an acceptance, it is an allowlist.

export const ACCEPTED_PATH = join(HERE, "accepted-until-fixed.json");

// A row in one of these states no longer owes the fix, so an entry citing it
// cannot keep accepting a debt that is still in the graph.
const CLOSED_LIFECYCLES = new Set(["done", "cancelled"]);

// Parse + VALIDATE the accepted list. Refuses rather than tolerating: an entry
// with no `row` is exactly the shape this list must never take, so the loader
// is where that is enforced, not review.
export function loadAcceptedEntries(raw) {
  let parsed;
  if (typeof raw === "string") {
    try {
      parsed = JSON.parse(raw);
    } catch (err) {
      throw new Error(`accepted-until-fixed.json is not parseable JSON: ${err.message}`);
    }
  } else {
    parsed = raw;
  }
  const entries = parsed && parsed.entries;
  if (!Array.isArray(entries)) {
    throw new Error("accepted-until-fixed.json must carry an `entries` array");
  }
  const seen = new Set();
  for (const e of entries) {
    if (!e || typeof e.identity !== "string" || !e.identity.trim()) {
      throw new Error("accepted-until-fixed.json: every entry must name an `identity` (the edge or cycle pair)");
    }
    // NO ENTRY WITHOUT A ROW. An acceptance with nobody on the hook is an
    // allowlist, and an allowlist is what this file exists not to be.
    if (typeof e.row !== "string" || !/^task-[0-9a-f]+$/.test(e.row)) {
      throw new Error(
        `accepted-until-fixed.json: entry "${e.identity}" carries no bp task row id ` +
          `(expected a "task-…" id in \`row\`). An acceptance with nobody on the hook is an allowlist.`
      );
    }
    if (seen.has(e.identity)) {
      throw new Error(`accepted-until-fixed.json: "${e.identity}" is listed twice`);
    }
    seen.add(e.identity);
  }
  return entries;
}

// Arms (b) and (c), as one pure function over: the entries, the identities the
// gate found in the CURRENT graph, and a row→lifecycle map. A row missing from
// the map, or mapped to null, means THE LEDGER COULD NOT BE READ for it.
export function auditAccepted({ entries, present, lifecycle }) {
  const failures = [];
  const seen = present instanceof Set ? present : new Set(present || []);
  const statuses = lifecycle instanceof Map ? lifecycle : new Map(Object.entries(lifecycle || {}));

  for (const entry of entries) {
    const here = seen.has(entry.identity);

    // ARM (c) — HEALED. Checked first: a healed entry's row lifecycle is beside
    // the point, the entry has nothing left to accept either way.
    if (!here) {
      failures.push({
        arm: "healed",
        identity: entry.identity,
        row: entry.row,
        reason:
          `HEALED: delete entry ${entry.identity} — it is no longer in the graph, so its ` +
          `acceptance accepts nothing. Remove it from tooling/concept-map/accepted-until-fixed.json ` +
          `in the same PR that healed it (row ${entry.row}).`,
      });
      continue;
    }

    // ARM (b) — the row's lifecycle. Unreadable is a REFUSAL, never a pass.
    const status = statuses.has(entry.row) ? statuses.get(entry.row) : null;
    if (status === null || status === undefined || status === "") {
      failures.push({
        arm: "ledger-unreadable",
        identity: entry.identity,
        row: entry.row,
        reason:
          `REFUSING: the lifecycle of row ${entry.row} (accepting "${entry.identity}") could not be read ` +
          `from the ledger. An acceptance whose justification cannot be checked is an allowlist, so this ` +
          `gate says HOLD rather than green. Provision LEDGER_TOKEN (repo secret BARKPARK_TASK_TOKEN) and re-run.`,
      });
      continue;
    }
    if (CLOSED_LIFECYCLES.has(status)) {
      failures.push({
        arm: "row-closed",
        identity: entry.identity,
        row: entry.row,
        lifecycle: status,
        reason:
          `row ${entry.row} is '${status}' but "${entry.identity}" is STILL in the graph — the acceptance ` +
          `outlived its justification. Either the debt was not actually paid down (reopen the row) or the ` +
          `entry is stale (delete it and let the never-worse arm speak).`,
      });
    }
  }
  return { failed: failures.length > 0, failures };
}

// Read one row's lifecycle_status off the ledger, the same door and the same
// envelope scripts/pr-task-gate.sh reads (/v1/data/doc/<dataset>/task/<id>,
// which flattens `content` to the top level). Returns null on ANY failure —
// unreachable, refused, malformed — and arm (b) turns that null into a refusal.
async function readLifecycle(row, { base, token, dataset }) {
  const url = `${String(base).replace(/\/$/, "")}/v1/data/doc/${dataset}/task/${row}`;
  try {
    const res = await fetch(url, {
      headers: token ? { Authorization: `Bearer ${token}` } : {},
      signal: AbortSignal.timeout(20000),
    });
    if (!res.ok) return null;
    const body = await res.json();
    const doc = body && (body.result || body.doc || body);
    const status = doc && (doc.lifecycle_status || (doc.content && doc.content.lifecycle_status));
    return typeof status === "string" && status ? status : null;
  } catch {
    return null;
  }
}

export async function readLifecycles(rows, env = process.env) {
  const cfg = {
    base: env.LEDGER_BASE || "https://guerrilla.barkpark.cloud",
    token: env.LEDGER_TOKEN || env.BARKPARK_TASK_TOKEN || "",
    dataset: env.LEDGER_DATASET || "production",
  };
  const out = new Map();
  for (const row of new Set(rows)) out.set(row, await readLifecycle(row, cfg));
  return out;
}

// Compare current metrics vs baseline. Returns { regressed, regressions[], growth }.
export function compare(current, baseline, acceptedEntries = []) {
  const regressions = [];
  const bc = baseline.counts || {};
  const known = baselineConcepts(baseline);
  const baselineKernel = new Set(baseline.kernel || []);
  const isKnown = (parts) => parts.every((c) => known.has(c));

  // ARM (a), the never-worse arm, with the accepted list subtracted. This ONE
  // line is the whole tolerance surface: an identity is waved through if and
  // only if it is written down in accepted-until-fixed.json with a row id.
  // Anything else — a brand-new edge, a reshuffle, a count rise the accepted
  // set does not explain — still reds, exactly as before.
  const acceptedSet = new Set((acceptedEntries || []).map((e) => String(e.identity)));
  const isAccepted = (k) => acceptedSet.has(String(k));
  const accepted = { sideways: [], wrongDirection: [], featureCycles: [] };

  // Split every current identity into COMPARABLE (both ends baseline-known) and
  // GROWTH (touches a concept the baseline never saw) BEFORE anything is judged.
  const comparable = { sideways: [], wrongDirection: [], featureCycles: [] };
  const growth = { sideways: [], wrongDirection: [], featureCycles: [], kernelReach: [], newConcepts: [] };
  const newConcepts = new Set();

  const sortInto = (dim, keys, split) => {
    for (const k of keys) {
      // Accepted FIRST, before the known/growth split: an accepted identity must
      // not raise the comparable COUNT either, or the count arm would red for the
      // very edge the entry accepts and the acceptance would buy nothing.
      if (isAccepted(k)) {
        accepted[dim].push(k);
        continue;
      }
      const parts = split(k);
      if (isKnown(parts)) {
        comparable[dim].push(k);
      } else {
        growth[dim].push(k);
        for (const c of parts) if (!known.has(c)) newConcepts.add(c);
        // A kernel concept the baseline DID know, reaching a concept it did not.
        if (baselineKernel.has(parts[0]) && !known.has(parts[parts.length - 1])) {
          growth.kernelReach.push(k);
        }
      }
    }
  };
  sortInto("sideways", current.edges.sideways, conceptsOfEdge);
  sortInto("wrongDirection", current.edges.wrongDirection, conceptsOfEdge);
  sortInto("featureCycles", current.featureCyclePairs, conceptsOfPair);
  growth.newConcepts = [...newConcepts].sort();
  for (const dim of ["sideways", "wrongDirection", "featureCycles", "kernelReach"]) {
    growth[dim] = growth[dim].sort();
  }

  // dimension-by-dimension count check — on the BASELINE-KNOWN SUBGRAPH ONLY.
  // Comparing the whole current graph against a baseline captured over a smaller
  // one is not a never-worse comparison, it is a size comparison.
  const comparableCounts = {
    sideways: comparable.sideways.length,
    wrongDirection: comparable.wrongDirection.length,
    featureCycles: comparable.featureCycles.length,
  };
  for (const dim of ["sideways", "wrongDirection", "featureCycles"]) {
    const base = bc[dim] ?? 0;
    const now = comparableCounts[dim];
    if (now > base) {
      regressions.push({
        kind: "count",
        dimension: dim,
        baseline: base,
        current: now,
        delta: now - base,
        reason:
          `${dim} count among BASELINE-KNOWN concepts rose from ${base} to ${now} ` +
          `(+${now - base}); growth in concepts absent at baseline is excluded`,
      });
    }
  }

  // concrete-identity check — a NEW edge / cycle that isn't grandfathered, even
  // if the aggregate count happens to be flat (a reshuffle). Growth identities
  // never reach here.
  const baseSideways = new Set((baseline.edges && baseline.edges.sideways) || []);
  for (const e of comparable.sideways) {
    if (!baseSideways.has(e)) {
      regressions.push({
        kind: "new-edge",
        dimension: "sideways",
        edge: e,
        reason: `new feature→feature sideways edge "${e}" not present in baseline`,
      });
    }
  }

  const baseWrong = new Set((baseline.edges && baseline.edges.wrongDirection) || []);
  for (const e of comparable.wrongDirection) {
    if (!baseWrong.has(e)) {
      regressions.push({
        kind: "new-edge",
        dimension: "wrongDirection",
        edge: e,
        reason: `new kernel→feature (wrong-direction) edge "${e}" not present in baseline`,
      });
    }
  }

  const basePairs = new Set(baseline.featureCyclePairs || []);
  for (const p of comparable.featureCycles) {
    if (!basePairs.has(p)) {
      regressions.push({
        kind: "new-cycle",
        dimension: "featureCycles",
        pair: p,
        reason: `new feature↔feature cycle "${p.replace("|", " ⇄ ")}" not present in baseline`,
      });
    }
  }

  return {
    regressed: regressions.length > 0,
    regressions,
    comparableCounts,
    // Every identity the CURRENT graph carries, accepted ones included. Arm (c)
    // reads this: an entry whose identity is absent HERE has been healed.
    present: [
      ...current.edges.sideways,
      ...current.edges.wrongDirection,
      ...current.featureCyclePairs,
    ].map(String),
    accepted: {
      counts: {
        sideways: accepted.sideways.length,
        wrongDirection: accepted.wrongDirection.length,
        featureCycles: accepted.featureCycles.length,
      },
      sideways: accepted.sideways.sort(),
      wrongDirection: accepted.wrongDirection.sort(),
      featureCycles: accepted.featureCycles.sort(),
    },
    growth: {
      newConcepts: growth.newConcepts,
      counts: {
        sideways: growth.sideways.length,
        wrongDirection: growth.wrongDirection.length,
        featureCycles: growth.featureCycles.length,
      },
      sideways: growth.sideways,
      wrongDirection: growth.wrongDirection,
      featureCycles: growth.featureCycles,
      kernelReach: growth.kernelReach,
    },
  };
}

// ── main ────────────────────────────────────────────────────────────────────

async function main() {
  // FIRST, before the graph rebuild and before anything is read: can this tree
  // produce the verdict CI produces? If not, say so in one line and stop.
  const refusal = preflightRefusal({
    indexPath: INDEX_PATH,
    symbolsPath: SYMBOLS_PATH,
    skipBuild: SKIP_BUILD,
    allowCold: ALLOW_COLD,
  });
  if (refusal) {
    note(refusal);
    throw new GateFault(); // exit 2 — a FAULT, never 1 (that is REGRESSION).
  }
  if (ALLOW_COLD) {
    note("ci-boundary: --allow-cold-index → preflight waived; this verdict may DISAGREE with CI's.");
  }

  rebuildGraph();

  if (WRITE_BASELINE) {
    gradeSanity();
    const boundary = runNodeJson(BOUNDARY);
    const m = deriveMetrics(boundary);
    const baseline = {
      note:
        "Architecture-debt baseline for ci-boundary.mjs (the never-worse gate, pointed at architecture). " +
        "Captured via `node tooling/concept-map/ci-boundary.mjs --write-baseline`. The CI gate fails ONLY on " +
        "regression beyond these counts / sets — existing known debt is grandfathered, never an error. " +
        "Regenerate intentionally when debt is genuinely paid down; NEVER to silence a real regression.",
      capturedAt: new Date().toISOString(),
      kernel: boundary.kernel || (boundary.gate && boundary.gate.context && boundary.gate.context.kernel) || [],
      counts: m.counts,
      edges: m.edges,
      featureCyclePairs: m.featureCyclePairs,
    };
    const json = JSON.stringify(baseline, null, 2) + "\n";
    const out = optVal("--out");
    if (out) {
      writeFileSync(resolve(REPO_ROOT, out), json);
      note(`ci-boundary: baseline written to ${out}`);
    } else {
      writeFileSync(BASELINE_PATH, json);
      note(`ci-boundary: baseline written to ${BASELINE_PATH}`);
    }
    return 0;
  }

  gradeSanity();
  const boundary = runNodeJson(BOUNDARY);
  const current = deriveMetrics(boundary);
  const baseline = loadBaseline();
  // The accepted list is loaded HERE, not lazily inside compare: a malformed or
  // row-less list must stop the gate outright (exit 2), never degrade it to a
  // run with an empty tolerance set that reds on today's known debt and reads as
  // a real finding.
  let acceptedEntries;
  try {
    acceptedEntries = existsSync(ACCEPTED_PATH)
      ? loadAcceptedEntries(readFileSync(ACCEPTED_PATH, "utf8"))
      : [];
  } catch (err) {
    note(`ci-boundary: ${err.message}`);
    throw new GateFault();
  }
  const { regressed, regressions, comparableCounts, growth, present, accepted } = compare(
    current,
    baseline,
    acceptedEntries
  );

  // ARMS (b) and (c). They run on EVERY run, red or green: an acceptance that
  // has outlived its row, or its edge, is a finding in its own right and must
  // not wait for some other regression to surface it.
  const lifecycle = await readLifecycles(
    acceptedEntries.map((e) => e.row),
    process.env
  );
  const audit = auditAccepted({ entries: acceptedEntries, present: new Set(present), lifecycle });

  const report = {
    builtAt: new Date().toISOString(),
    baselineCapturedAt: baseline.capturedAt || null,
    baseline: { counts: baseline.counts },
    // THREE numbers, deliberately labelled apart, because collapsing them is the
    // defect this gate had. `current` is the whole graph. `comparable` is the
    // slice the baseline can actually speak to. `growth` is everything the
    // baseline never saw. Only `comparable` is compared.
    current: { counts: current.counts },
    comparable: { counts: comparableCounts },
    growth,
    accepted,
    acceptedEntries,
    acceptedAudit: audit,
    regressed,
    regressions,
  };

  if (AS_JSON) {
    process.stdout.write(JSON.stringify(report, null, 2) + "\n");
  }

  // human summary on stderr (always)
  note("");
  note("cqv8 — architecture boundary gate (never-worse)");
  note("  compared on the BASELINE-KNOWN subgraph; growth reported apart, never red.");
  for (const dim of ["sideways", "wrongDirection", "featureCycles"]) {
    const base = (baseline.counts || {})[dim] ?? 0;
    const now = comparableCounts[dim] ?? 0;
    const whole = current.counts[dim] ?? 0;
    const arrow = now > base ? "WORSE" : now < base ? "better" : "flat ";
    note(
      `  ${dim.padEnd(15)} baseline ${String(base).padStart(3)}  →  comparable ${String(now).padStart(3)}   [${arrow}]` +
        `   (whole graph ${whole}, growth ${growth.counts[dim] ?? 0})`
    );
  }
  note("");
  note(
    `ci-boundary: GROWTH (informational, never a regression) — ${growth.newConcepts.length} concepts absent at baseline:`
  );
  note(`  ${growth.newConcepts.join(", ") || "(none)"}`);
  note(
    `  carrying ${growth.counts.sideways} sideways, ${growth.counts.wrongDirection} wrong-direction, ` +
      `${growth.counts.featureCycles} cycle identities the baseline cannot speak to.`
  );
  if (growth.kernelReach.length) {
    // NOT red, but never silent: the substrate acquiring a dependency on a leaf
    // that did not exist at baseline is the one growth shape worth reading.
    note(`  NOTABLE — a BASELINE KERNEL concept reaches a concept absent at baseline:`);
    for (const e of growth.kernelReach) note(`    · ${e}`);
  }
  note("");

  // The accepted list, printed in full on every run — a tolerance nobody reads
  // is an allowlist. Each line names its row so the debt has an owner on screen.
  note(
    `ci-boundary: ACCEPTED-UNTIL-FIXED — ${acceptedEntries.length} identit${
      acceptedEntries.length === 1 ? "y" : "ies"
    } tolerated, each with a row that owes the fix:`
  );
  for (const e of acceptedEntries) {
    note(`  · ${e.identity}  [${e.dimension || "?"}]  ${e.row}  (since ${e.since || "?"})`);
  }
  if (!acceptedEntries.length) note("  (none — the gate is tolerating nothing)");
  note("");

  if (audit.failed) {
    note("ci-boundary: THE ACCEPTED LIST IS NO LONGER HONEST:");
    for (const f of audit.failures) note(`  ✗ [${f.arm}] ${f.reason}`);
    note("");
  }

  if (regressed) {
    note("ci-boundary: REGRESSION — new architectural debt vs baseline:");
    for (const r of regressions) note(`  ✗ ${r.reason}`);
    note("");
    // DO NOT print a --write-baseline invitation here. Every row above is an
    // edge between two concepts the baseline ALREADY KNEW — growth was filtered
    // out before this list was built — so a re-baseline would not be paying debt
    // down, it would be erasing a measurement that is working. A loud red is
    // exactly where a gate gets talked into regenerating its own baseline; the
    // remedy is the edge.
    note("Fix the edge, or route it for an explicit intent decision.");
    note("A re-baseline is NOT the remedy for these rows: every one is between two");
    note("concepts the baseline already knew, so --write-baseline would erase a real");
    note("measurement rather than record a paid-down one.");
    return 1;
  }

  // A ledger the gate could not read is a FAULT (2), not a regression (1): no
  // architectural debt was found, the instrument simply could not be completed.
  // Every other accepted-list failure is a real finding about this repo (1).
  if (audit.failed) {
    return audit.failures.every((f) => f.arm === "ledger-unreadable") ? 2 : 1;
  }

  note("ci-boundary: PASS — no new feature→feature, kernel→feature, or cycle debt vs baseline.");
  return 0;
}

// process.exitCode, NOT process.exit() — same reason grade.mjs and boundary.mjs
// no longer call it. main() writes the --json report to stdout immediately
// before this line, and architecture.yml pipes this script into `tee`; an
// exit() here would race the async pipe drain and cut the report at one 65536-
// byte buffer. Assigning exitCode lets node flush and then exit with the same
// status, so the gate keeps its 0 / 1 (regression) / 2 (fault) contract.
//
// RUN ONLY WHEN INVOKED AS THE CLI. `compare` and `baselineConcepts` are exported
// so ci-boundary.test.mjs can drive the predicate on synthetic baselines without
// a symbol graph; without this guard, importing the module would rebuild the
// graph and run the whole gate as an import side effect.
const INVOKED_DIRECTLY =
  !!process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url);

if (INVOKED_DIRECTLY) {
  // await, not .then(): an unawaited main() would let this module finish and
  // node exit 0 before the ledger reads (arm b) resolved — the accepted-list
  // arms would be structurally dead in exactly the way this gate's job-level
  // continue-on-error already was once.
  try {
    process.exitCode = await main();
  } catch (err) {
    if (!(err instanceof GateFault)) throw err;
    process.exitCode = 2; // FAULT — the diagnosis is already on stderr.
  }
}
