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
//   5. compare vs boundary-baseline.json and EXIT NON-ZERO on REGRESSION:
//        a count rose above baseline, OR a specific edge / cycle pair appears
//        that is not in the baseline set. Equal-or-lower counts AND a subset of
//        the baseline edges pass — that is "never worse, possibly better".
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

const argv = process.argv.slice(2);
const flag = (name) => argv.includes(name);
const optVal = (name) => {
  const i = argv.indexOf(name);
  return i >= 0 && i + 1 < argv.length ? argv[i + 1] : null;
};

const AS_JSON = flag("--json");
const SKIP_BUILD = flag("--skip-build");
const WRITE_BASELINE = flag("--write-baseline");

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

// Compare current metrics vs baseline. Returns { regressed, regressions[] }.
function compare(current, baseline) {
  const regressions = [];
  const bc = baseline.counts || {};
  const cc = current.counts;

  // dimension-by-dimension count check
  for (const dim of ["sideways", "wrongDirection", "featureCycles"]) {
    const base = bc[dim] ?? 0;
    const now = cc[dim] ?? 0;
    if (now > base) {
      regressions.push({
        kind: "count",
        dimension: dim,
        baseline: base,
        current: now,
        delta: now - base,
        reason: `${dim} count rose from ${base} to ${now} (+${now - base})`,
      });
    }
  }

  // concrete-identity check — a NEW edge / cycle that isn't grandfathered,
  // even if the aggregate count happens to be flat (a reshuffle).
  const baseSideways = new Set((baseline.edges && baseline.edges.sideways) || []);
  for (const e of current.edges.sideways) {
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
  for (const e of current.edges.wrongDirection) {
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
  for (const p of current.featureCyclePairs) {
    if (!basePairs.has(p)) {
      regressions.push({
        kind: "new-cycle",
        dimension: "featureCycles",
        pair: p,
        reason: `new feature↔feature cycle "${p.replace("|", " ⇄ ")}" not present in baseline`,
      });
    }
  }

  return { regressed: regressions.length > 0, regressions };
}

// ── main ────────────────────────────────────────────────────────────────────

function main() {
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
  const { regressed, regressions } = compare(current, baseline);

  const report = {
    builtAt: new Date().toISOString(),
    baselineCapturedAt: baseline.capturedAt || null,
    baseline: { counts: baseline.counts },
    current: { counts: current.counts },
    regressed,
    regressions,
  };

  if (AS_JSON) {
    process.stdout.write(JSON.stringify(report, null, 2) + "\n");
  }

  // human summary on stderr (always)
  note("");
  note("cqv8 — architecture boundary gate (never-worse)");
  for (const dim of ["sideways", "wrongDirection", "featureCycles"]) {
    const base = (baseline.counts || {})[dim] ?? 0;
    const now = current.counts[dim] ?? 0;
    const arrow = now > base ? "WORSE" : now < base ? "better" : "flat ";
    note(`  ${dim.padEnd(15)} baseline ${String(base).padStart(3)}  →  now ${String(now).padStart(3)}   [${arrow}]`);
  }
  note("");

  if (regressed) {
    note("ci-boundary: REGRESSION — new architectural debt vs baseline:");
    for (const r of regressions) note(`  ✗ ${r.reason}`);
    note("");
    note("Fix the edge, or — if this debt is intentional and accepted — re-baseline with:");
    note("  node tooling/concept-map/ci-boundary.mjs --write-baseline");
    return 1;
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
try {
  process.exitCode = main();
} catch (err) {
  if (!(err instanceof GateFault)) throw err;
  process.exitCode = 2; // FAULT — the diagnosis is already on stderr.
}
