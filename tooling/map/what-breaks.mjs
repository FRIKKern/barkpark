#!/usr/bin/env node
// what-breaks.mjs — the blast-radius query.
//
//   "If I touch THIS file, what (transitively) depends on it, and how scared
//    should I be?"
//
// Computes the TRUE reverse-dependency closure of a file by walking the
// reverse-dep edges in tooling/blast-radius/index.json, then overlays the
// codebase map (barkpark-sync nodes + risk-report) onto that closure to grade
// the danger: closure size × seam exposure × untested share → a LOW/MEDIUM/
// HIGH/CRITICAL verdict, plus the top affected files ranked by reach.
//
//   what-breaks.mjs <file>          → console blast-radius report
//   what-breaks.mjs <file> --json   → full structured result on stdout
//
// Granularity note: the blast-radius index is mixed-grain —
//   • elixir reverse edges are keyed by FILE PATH        (api/lib/.../x.ex)
//   • js / go reverse edges are keyed by MODULE / PACKAGE (@barkpark/core, …)
// For js/go we resolve <file> → its dir → module via dirToName / dirToPkg,
// walk the module-level reverse closure, then expand each dependent module
// back to the files under its directory (via the node set). Elixir stays
// file-exact. No deps; pure reads of already-built artifacts.

import { execFileSync } from "node:child_process";
import { readFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { verifyManifest } from "./manifest.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: HERE })
  .toString()
  .trim();

const INDEX = join(ROOT, "tooling/blast-radius/index.json");
const NODES = join(ROOT, "tooling/barkpark-sync/nodes.json");
const RISK = join(ROOT, "tooling/risk/risk-report.json");
const SYMBOLS = join(ROOT, "tooling/symbol-graph/symbols.json");

const readJson = (p) => JSON.parse(readFileSync(p, "utf8"));

function loadMap() {
  for (const p of [INDEX, NODES, RISK]) {
    if (!existsSync(p)) {
      console.error(`missing map artifact: ${p}\n  build the map first (tooling/blast-radius, tooling/barkpark-sync, tooling/risk).`);
      process.exit(2);
    }
  }
  const index = readJson(INDEX);
  const nodesDoc = readJson(NODES);
  const risk = readJson(RISK);
  const nodes = nodesDoc.nodes || nodesDoc.files || nodesDoc;
  const byPath = new Map();
  for (const n of nodes) if (n.path) byPath.set(n.path, n);
  return { index, nodes, byPath, risk: risk.files || {} };
}

// ---- closure -------------------------------------------------------------
// Walk a reverse-edge map { node -> [dependents] } from one or more seeds and
// return the transitive set of dependents (excluding the seeds themselves).
function reverseClosure(reverse, seeds) {
  const seen = new Set();
  const stack = [...seeds];
  const seedSet = new Set(seeds);
  while (stack.length) {
    const cur = stack.pop();
    const dependents = reverse[cur] || [];
    for (const d of dependents) {
      if (!seen.has(d)) {
        seen.add(d);
        stack.push(d);
      }
    }
  }
  for (const s of seedSet) seen.delete(s);
  return seen;
}

// Map a target file to the FILE-level reverse closure across the relevant
// language graph. Returns { lang, files:Set<path>, note }.
function blastFiles(file, { index, nodes }) {
  // Elixir — file-keyed edges, exact.
  if (index.elixir && index.elixir.reverse && fileInRev(index.elixir.reverse, file, index)) {
    const files = reverseClosure(index.elixir.reverse, [file]);
    return { lang: "elixir", files, note: "file-level reverse closure" };
  }

  // JS — module-keyed. Resolve file → dir → module.
  if (file.startsWith("js/") && index.js) {
    const mod = dirToUnit(file, index.js.dirToName);
    if (mod && index.js.reverse[mod] !== undefined) {
      const mods = reverseClosure(index.js.reverse, [mod]);
      const files = filesForUnits(mods, index.js.dirToName, nodes, "js");
      return { lang: "js", unit: mod, units: [...mods], files, note: "module-level reverse closure, expanded to files" };
    }
    if (mod) return { lang: "js", unit: mod, units: [], files: new Set(), note: "module has no recorded dependents" };
  }

  // Go — package-keyed. Resolve file → dir → package.
  if (index.go) {
    const pkg = dirToUnit(file, index.go.dirToPkg);
    if (pkg && index.go.reverse[pkg] !== undefined) {
      const pkgs = reverseClosure(index.go.reverse, [pkg]);
      const files = filesForUnits(pkgs, index.go.dirToPkg, nodes, "go");
      return { lang: "go", unit: pkg, units: [...pkgs], files, note: "package-level reverse closure, expanded to files" };
    }
    if (pkg) return { lang: "go", unit: pkg, units: [], files: new Set(), note: "package has no recorded dependents" };
  }

  // Fall back: maybe it's an elixir file with no recorded dependents.
  if (file.endsWith(".ex") || file.endsWith(".exs")) {
    return { lang: "elixir", files: new Set(), note: "no recorded dependents" };
  }
  return { lang: "unknown", files: new Set(), note: "file not present in any dependency graph" };
}

function fileInRev(reverse, file, index) {
  if (file in reverse) return true;
  // Also true if the file appears as a dependent anywhere, or is a known
  // elixir source under api/. We treat any .ex/.exs as elixir-graph eligible.
  return file.endsWith(".ex") || file.endsWith(".exs");
}

// Longest matching directory prefix → unit name.
function dirToUnit(file, dirMap) {
  let best = null;
  let bestLen = -1;
  for (const dir of Object.keys(dirMap)) {
    if (file === dir || file.startsWith(dir + "/")) {
      if (dir.length > bestLen) {
        bestLen = dir.length;
        best = dirMap[dir];
      }
    }
  }
  return best;
}

// Expand a set of module/package units back to the concrete files that live
// under each unit's directory, using the node set as the file universe.
function filesForUnits(units, dirMap, nodes, langTag) {
  const unitToDirs = new Map(); // unit -> [dirs]
  for (const [dir, unit] of Object.entries(dirMap)) {
    if (!unitToDirs.has(unit)) unitToDirs.set(unit, []);
    unitToDirs.get(unit).push(dir);
  }
  const out = new Set();
  for (const unit of units) {
    const dirs = unitToDirs.get(unit) || [];
    for (const n of nodes) {
      if (!n.path) continue;
      for (const dir of dirs) {
        if (n.path === dir || n.path.startsWith(dir + "/")) {
          out.add(n.path);
          break;
        }
      }
    }
  }
  return out;
}

// ---- symbol-level blast --------------------------------------------------
// Optional, additive. If tooling/symbol-graph/symbols.json exists, descend one
// level below files: which SPECIFIC functions/modules transitively depend on
// the symbols DEFINED in <file>. Pure read of the prebuilt symbol graph; the
// reverse adjacency is precomputed per-language so each step is O(1).
function loadSymbols() {
  if (!existsSync(SYMBOLS)) return null;
  try { return readJson(SYMBOLS); } catch { return null; }
}

// Reverse-closure over the symbol graph, seeded by every symbol defined in
// <file>. Returns the dependent symbol ids (excluding the seeds), grouped.
function blastSymbols(file, sym) {
  // seeds: all node ids whose `file` is the target file
  const seeds = sym.nodes.filter((n) => n.file === file).map((n) => n.id);
  if (!seeds.length) return { defined: [], dependents: [], note: "no symbols indexed for this file" };

  // unified reverse map across all languages (symId -> [callerIds]); the
  // per-language maps already partition cleanly by the "<lang>:" id prefix.
  const reverse = {};
  for (const langRev of Object.values(sym.reverse || {})) Object.assign(reverse, langRev);

  const seen = new Set();
  const stack = [...seeds];
  const seedSet = new Set(seeds);
  while (stack.length) {
    const cur = stack.pop();
    for (const dep of reverse[cur] || []) {
      if (!seen.has(dep)) { seen.add(dep); stack.push(dep); }
    }
  }
  for (const s of seedSet) seen.delete(s);

  const byId = new Map(sym.nodes.map((n) => [n.id, n]));
  const definedNodes = seeds.map((id) => byId.get(id)).filter(Boolean);
  const dependentNodes = [...seen].map((id) => byId.get(id)).filter(Boolean);
  // rank dependents: distinct file count matters, but list symbols directly.
  dependentNodes.sort((a, b) =>
    a.file.localeCompare(b.file) || a.symbol.localeCompare(b.symbol));
  return {
    defined: definedNodes.map((n) => ({ id: n.id, symbol: n.symbol, kind: n.kind, exported: n.exported })),
    dependents: dependentNodes.map((n) => ({ id: n.id, file: n.file, symbol: n.symbol, kind: n.kind })),
    files: [...new Set(dependentNodes.map((n) => n.file))].sort(),
    note: "symbol-level reverse closure over tooling/symbol-graph/symbols.json",
  };
}

// ---- overlay -------------------------------------------------------------
function enrich(paths, { byPath, risk }) {
  const rows = [];
  for (const p of paths) {
    const n = byPath.get(p);
    const f = n && n.fields ? n.fields : {};
    const r = risk[p] || {};
    rows.push({
      path: p,
      reach: typeof f.reach === "number" ? f.reach : null,
      seam: !!f.seam,
      defectDensity: typeof r.defectDensity === "number" ? r.defectDensity : null,
      hasTest: r.hasTest === true,
      testScore: typeof r.testScore === "number" ? r.testScore : null,
      role: f.role || null,
    });
  }
  return rows;
}

const HIGH_REACH = 60; // matches the "high-reach" band used across tooling
const FRAGILE = 0.2; // defectDensity above this = defect-prone

function verdict(rows) {
  const n = rows.length;
  const highReach = rows.filter((r) => r.reach !== null && r.reach >= HIGH_REACH).length;
  const seamTouch = rows.filter((r) => r.seam).length;
  const defectProne = rows.filter((r) => r.defectDensity !== null && r.defectDensity >= FRAGILE).length;
  const untested = rows.filter((r) => !r.hasTest).length;
  const untestedShare = n ? untested / n : 0;

  // Score: closure size × seam exposure × untested share, with high-reach and
  // defect-proneness as multipliers. Tuned to land on intuitive bands.
  let score = 0;
  score += Math.min(n, 60) * 1.0; // raw blast size (capped contribution)
  score += seamTouch * 8; // crossing a seam is expensive
  score += highReach * 4; // each high-reach dependent amplifies
  score += defectProne * 3; // fragile dependents add risk
  score += untestedShare * 40; // an untested blast radius is unverifiable

  let level;
  if (n === 0) level = "NONE";
  else if (score >= 140 || (seamTouch > 0 && n >= 30 && untestedShare > 0.6)) level = "CRITICAL";
  else if (score >= 70) level = "HIGH";
  else if (score >= 25) level = "MEDIUM";
  else level = "LOW";

  return {
    level,
    score: Math.round(score),
    closureSize: n,
    highReach,
    seamTouch,
    defectProne,
    untested,
    untestedShare: Math.round(untestedShare * 100) / 100,
  };
}

// ---- run -----------------------------------------------------------------
const args = process.argv.slice(2);
const wantJson = args.includes("--json");
const noSymbols = args.includes("--no-symbols");
const wantSymbols = args.includes("--symbols");
const file = args.find((a) => !a.startsWith("--"));

if (!file) {
  console.error("usage: what-breaks.mjs <file> [--json] [--symbols|--no-symbols]");
  process.exit(2);
}

const map = loadMap();
const blast = blastFiles(file, map);
const rows = enrich(blast.files, map);
rows.sort((a, b) => (b.reach || 0) - (a.reach || 0) || a.path.localeCompare(b.path));
const v = verdict(rows);

// Currency check — is the map we just queried built against today's tree?
const currency = safeVerify();

// Symbol-level overlay (additive). Auto-use when symbols.json exists unless the
// caller opts out with --no-symbols; --symbols forces it on (and errors loudly
// if the artifact is missing).
let symbolBlast = null;
const sym = (wantSymbols || !noSymbols) ? loadSymbols() : null;
if (sym) {
  symbolBlast = blastSymbols(file, sym);
} else if (wantSymbols) {
  console.error(`--symbols requested but ${SYMBOLS} not found.\n  build it first: node tooling/symbol-graph/build-symbols.mjs`);
  process.exit(2);
}

const result = {
  target: file,
  lang: blast.lang,
  unit: blast.unit || null,
  note: blast.note,
  verdict: v,
  mapCurrent: currency.ok,
  currency: {
    ok: currency.ok,
    reason: currency.reason,
    counts: currency.counts || null,
  },
  self: selfRow(file, map),
  topAffected: rows.slice(0, 25),
  closure: rows.map((r) => r.path),
  ...(symbolBlast ? { symbols: {
    definedCount: symbolBlast.defined.length,
    dependentCount: symbolBlast.dependents.length,
    dependentFiles: symbolBlast.files || [],
    defined: symbolBlast.defined,
    dependents: symbolBlast.dependents.slice(0, 50),
    note: symbolBlast.note,
  } } : {}),
};

if (wantJson) {
  console.log(JSON.stringify(result, null, 2));
  process.exit(0);
}

printReport(result);

function safeVerify() {
  try {
    return verifyManifest();
  } catch {
    return { ok: false, reason: "verify-failed" };
  }
}

function selfRow(file, map) {
  const n = map.byPath.get(file);
  const f = n && n.fields ? n.fields : {};
  const r = map.risk[file] || {};
  return {
    path: file,
    reach: typeof f.reach === "number" ? f.reach : null,
    seam: !!f.seam,
    role: f.role || null,
    whatBreaks: f.whatBreaks || null,
    defectDensity: typeof r.defectDensity === "number" ? r.defectDensity : null,
    hasTest: r.hasTest === true,
  };
}

function printReport(res) {
  const { verdict: v, self } = res;
  const bar = "─".repeat(64);
  console.log(bar);
  console.log(`BLAST RADIUS  ·  ${res.target}`);
  console.log(bar);

  // Currency gate first — never trust a stale map silently.
  if (res.currency.reason === "no-manifest") {
    console.log("⚠ map currency UNKNOWN — no manifest pinned (run `manifest.mjs build`).");
  } else if (!res.mapCurrent) {
    const c = res.currency.counts || {};
    console.log(`⚠ map is STALE — ${c.stale || 0} changed / ${c.added || 0} added / ${c.deleted || 0} deleted / ${c.dirty || 0} dirty. Rebuild before trusting this.`);
  } else {
    console.log("✓ map is current.");
  }

  console.log(`\nlang: ${res.lang}${res.unit ? `  ·  unit: ${res.unit}` : ""}  (${res.note})`);
  if (self.reach !== null || self.role) {
    console.log(`self: reach ${fmt(self.reach)}${self.seam ? " · SEAM" : ""}${self.role ? ` · ${self.role}` : ""}${self.hasTest ? " · tested" : " · untested"}`);
    if (self.whatBreaks) console.log(`      "${truncate(self.whatBreaks, 160)}"`);
  }

  console.log(`\n┌ VERDICT: ${v.level}  (score ${v.score})`);
  console.log(`├ blast radius:   ${v.closureSize} files (in)directly depend on this`);
  console.log(`├ high-reach:     ${v.highReach}  (reach ≥ ${HIGH_REACH})`);
  console.log(`├ touch a seam:   ${v.seamTouch}`);
  console.log(`├ defect-prone:   ${v.defectProne}  (defectDensity ≥ ${FRAGILE})`);
  console.log(`└ untested:       ${v.untested}/${v.closureSize}  (${Math.round(v.untestedShare * 100)}% of the blast radius)`);

  if (res.topAffected.length) {
    console.log(`\nTOP AFFECTED (by reach):`);
    for (const r of res.topAffected) {
      const flags = [
        r.seam ? "SEAM" : "",
        r.reach !== null && r.reach >= HIGH_REACH ? "reach" + r.reach : r.reach !== null ? "r" + r.reach : "",
        r.defectDensity !== null && r.defectDensity >= FRAGILE ? "fragile" : "",
        r.hasTest ? "" : "untested",
      ].filter(Boolean).join(" ");
      console.log(`  ${r.path}${flags ? "   [" + flags + "]" : ""}`);
    }
    if (res.closure.length > res.topAffected.length) {
      console.log(`  … and ${res.closure.length - res.topAffected.length} more (use --json for the full closure)`);
    }
  } else {
    console.log(`\nNo recorded dependents — safe to change in isolation (per the current map).`);
  }

  // Symbol-level overlay — which SPECIFIC functions/modules depend on this file.
  if (res.symbols) {
    const s = res.symbols;
    console.log(`\n${"─".repeat(64)}`);
    console.log(`SYMBOL-LEVEL BLAST  ·  ${s.definedCount} symbols defined here, ${s.dependentCount} dependents across ${s.dependentFiles.length} files`);
    if (s.dependentCount) {
      const shown = s.dependents.slice(0, 25);
      for (const d of shown) {
        console.log(`  ${d.file}#${d.symbol}  [${d.kind}]`);
      }
      if (s.dependentCount > shown.length) {
        console.log(`  … and ${s.dependentCount - shown.length} more dependent symbols (use --json for all)`);
      }
    } else {
      console.log(`  ${s.note}`);
    }
  }
  console.log(bar);
}

function fmt(x) {
  return x === null ? "?" : String(x);
}
function truncate(s, n) {
  return s.length > n ? s.slice(0, n - 1) + "…" : s;
}
