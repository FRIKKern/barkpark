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

// Compare current metrics vs baseline. Returns { regressed, regressions[], growth }.
export function compare(current, baseline) {
  const regressions = [];
  const bc = baseline.counts || {};
  const known = baselineConcepts(baseline);
  const baselineKernel = new Set(baseline.kernel || []);
  const isKnown = (parts) => parts.every((c) => known.has(c));

  // Split every current identity into COMPARABLE (both ends baseline-known) and
  // GROWTH (touches a concept the baseline never saw) BEFORE anything is judged.
  const comparable = { sideways: [], wrongDirection: [], featureCycles: [] };
  const growth = { sideways: [], wrongDirection: [], featureCycles: [], kernelReach: [], newConcepts: [] };
  const newConcepts = new Set();

  const sortInto = (dim, keys, split) => {
    for (const k of keys) {
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
  const { regressed, regressions, comparableCounts, growth } = compare(current, baseline);

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
  try {
    process.exitCode = main();
  } catch (err) {
    if (!(err instanceof GateFault)) throw err;
    process.exitCode = 2; // FAULT — the diagnosis is already on stderr.
  }
}
