#!/usr/bin/env node
// boundary-build-cache-tripwire.mjs — the tripwire for architecture.yml's
// api/_build/dev cache.
//
// WHAT IT GUARDS. The boundary gate warms an EXACT mix-xref module graph. To
// stop paying a ~125 s cold `mix compile` on every PR touching five trees,
// architecture.yml now RESTORES api/_build/dev from a cache keyed on runner OS
// + OTP + Elixir + api/mix.lock ONLY — one exact entry per mix.lock lifetime,
// no restore-keys, deliberately NOT keyed on the api sources (a per-push key
// pushed a 38 MB archive per run through a shared, LRU 10 GB cache). So a
// restore routinely hands the job a build tree compiled from OLDER SOURCES.
//
// WHY THAT IS SAFE FOR MODIFIED FILES, AND WHY IT IS NOT THE WHOLE STORY.
// The workflow runs an explicit `mix compile` over the restored tree before
// the graph is built. Mix's compile.elixir manifest records every source path
// with its digest and the module-to-module dependencies between them, so a
// changed file and everything that depends on it are recompiled; that is the
// same incremental compile every developer relies on locally, and it is the
// stated reason the cache may hold first-party .beam files at all.
//
// The residue the manifest does NOT make obvious to a reader is a node that
// should have DISAPPEARED — a source deleted or renamed since the cache was
// written. This tripwire is aimed exactly there: every api/ path the graph
// names must still exist in the working tree. A stale ghost means the restored
// tree outran the sources and the gate is about to compare a graph the repo no
// longer has against the committed baseline.
//
// It also refuses to pass VACUOUSLY: a graph below the floor is a fault, not a
// clean bill of health, so a cache that restored a nearly-empty tree cannot
// buy silence.
//
// EXITS: 0 clean · 1 stale/ghost paths · 2 its own fault (unreadable index,
// no graph, below the floor). 2 matches the neighbouring assert step; 1 is
// ci-boundary.mjs's REGRESSION code and is used here only for a real finding.
//
// Usage: node scripts/boundary-build-cache-tripwire.mjs [indexPath]
//        node scripts/boundary-build-cache-tripwire.mjs --selftest

import { existsSync, readFileSync } from "node:fs";

// Run 33438876591 reported 657 elixir files with dependents and 754 with
// dependencies. The floor is far below both: it is a vacuity guard, not a
// count assertion, and a count assertion here would red on every honest
// refactor.
export const NODE_FLOOR = 300;

export function auditGraphPaths({ index, exists, floor = NODE_FLOOR }) {
  if (!index || typeof index !== "object") return { fault: "index is not an object" };
  const fwd = index.elixir && index.elixir.forward;
  if (!fwd || typeof fwd !== "object")
    return { fault: "index carries no elixir.forward graph" };

  const nodes = new Set();
  for (const [k, v] of Object.entries(fwd)) {
    nodes.add(k);
    for (const d of v || []) nodes.add(d);
  }
  const rev = (index.elixir && index.elixir.reverse) || {};
  for (const k of Object.keys(rev)) nodes.add(k);

  const apiNodes = [...nodes].filter((p) => p.startsWith("api/")).sort();
  if (apiNodes.length < floor)
    return {
      fault:
        "only " + apiNodes.length + " api/ nodes in the graph, floor is " + floor +
        " — the restored build tree is empty or partial, so this check would have passed over nothing",
      checked: apiNodes.length,
    };

  const missing = apiNodes.filter((p) => !exists(p));
  return { checked: apiNodes.length, missing };
}

function realMain(indexPath) {
  let index;
  try {
    const raw = readFileSync(indexPath, "utf8");
    if (!raw.trim()) throw new Error("file is empty");
    index = JSON.parse(raw);
  } catch (e) {
    console.error("FAULT: cannot read " + indexPath + ": " + e.message);
    process.exit(2);
  }
  const r = auditGraphPaths({ index, exists: (p) => existsSync(p) });
  if (r.fault) {
    console.error("FAULT: " + r.fault);
    process.exit(2);
  }
  if (r.missing.length) {
    console.error(
      "STALE BUILD CACHE: " + r.missing.length + " of " + r.checked +
      " api/ nodes in the mix-xref graph name files that do not exist in the working tree."
    );
    for (const p of r.missing.slice(0, 25)) console.error("  ghost: " + p);
    if (r.missing.length > 25) console.error("  ... and " + (r.missing.length - 25) + " more");
    console.error("The restored api/_build/dev tree is older than the sources and `mix compile` did not prune it.");
    console.error("Bump the cache key version in .github/workflows/architecture.yml rather than trusting this graph.");
    process.exit(1);
  }
  console.log("build-cache tripwire OK: all " + r.checked + " api/ graph nodes exist in the working tree");
}

// ---------------------------------------------------------------- selftest ---
// A tripwire nobody has watched fail is not a tripwire. Five cases, in-process,
// milliseconds: it proves the check REDS on a ghost path, FAULTS on a missing
// graph, and cannot be made to pass by shrinking its input to nothing.
function selftest() {
  const fails = [];
  const t = (name, fn) => {
    try { fn(); } catch (e) { fails.push(name + ": " + e.message); }
  };
  const ok = (cond, msg) => { if (!cond) throw new Error(msg); };

  const bigGraph = (n, extra = {}) => {
    const forward = {};
    for (let i = 0; i < n; i++) forward["api/lib/m" + i + ".ex"] = ["api/lib/m" + ((i + 1) % n) + ".ex"];
    return { elixir: { forward: { ...forward, ...extra }, reverse: {} } };
  };
  const allExist = () => true;

  t("clean tree passes", () => {
    const r = auditGraphPaths({ index: bigGraph(400), exists: allExist });
    ok(!r.fault, "unexpected fault: " + r.fault);
    ok(r.missing.length === 0, "expected no missing, got " + r.missing.length);
    ok(r.checked === 400, "expected 400 checked, got " + r.checked);
  });

  t("a ghost path is caught", () => {
    const idx = bigGraph(400, { "api/lib/deleted_module.ex": [] });
    const r = auditGraphPaths({ index: idx, exists: (p) => p !== "api/lib/deleted_module.ex" });
    ok(!r.fault, "unexpected fault: " + r.fault);
    ok(r.missing.length === 1 && r.missing[0] === "api/lib/deleted_module.ex",
      "expected the ghost to be named, got " + JSON.stringify(r.missing));
  });

  t("a ghost reached only as an edge TARGET is caught", () => {
    const idx = bigGraph(400);
    idx.elixir.forward["api/lib/m0.ex"] = ["api/lib/gone.ex"];
    const r = auditGraphPaths({ index: idx, exists: (p) => p !== "api/lib/gone.ex" });
    ok(r.missing && r.missing.includes("api/lib/gone.ex"), "edge target not audited");
  });

  t("an empty graph faults instead of passing", () => {
    const r = auditGraphPaths({ index: { elixir: { forward: {} } }, exists: allExist });
    ok(!!r.fault, "an empty graph must fault, it returned " + JSON.stringify(r));
  });

  t("shrinking the input cannot buy a pass", () => {
    const r = auditGraphPaths({ index: bigGraph(2), exists: allExist });
    ok(!!r.fault, "a 2-node graph must fault (below the floor), it returned " + JSON.stringify(r));
    const r2 = auditGraphPaths({ index: {}, exists: allExist });
    ok(!!r2.fault, "an index with no elixir graph must fault");
  });

  if (fails.length) {
    console.error("SELFTEST FAILED (" + fails.length + "):");
    for (const f of fails) console.error("  " + f);
    process.exit(2);
  }
  console.log("boundary-build-cache-tripwire selftest: 5 cases passed");
}

const argv = process.argv.slice(2);
if (argv.includes("--selftest")) selftest();
else realMain(argv[0] || "tooling/blast-radius/index.json");
