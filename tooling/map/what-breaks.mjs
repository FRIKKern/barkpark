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
// <file> — or, when symbolSeed is given, by just that one symbol's node(s).
// BFS the reverse adjacency to the FULL transitive set (worklist + seen-set to
// fixpoint), tracking the max hop-depth. Returns the dependent symbol ids
// (excluding the seeds), grouped, plus { depth: maxDepth }.
function blastSymbols(file, sym, symbolSeed) {
  const byId = new Map(sym.nodes.map((n) => [n.id, n]));

  // seeds: a specific symbol if asked, else every symbol defined in <file>.
  let seeds;
  if (symbolSeed) {
    const matched = matchSymbolNodes(sym.nodes, file, symbolSeed);
    seeds = matched.map((n) => n.id);
    if (!seeds.length) {
      return { defined: [], dependents: [], files: [], depth: 0,
        note: `no symbol matched "${symbolSeed}"${file ? ` in ${file}` : ""}` };
    }
  } else {
    seeds = sym.nodes.filter((n) => n.file === file).map((n) => n.id);
    if (!seeds.length) return { defined: [], dependents: [], files: [], depth: 0, note: "no symbols indexed for this file" };
  }

  // unified reverse map across all languages (symId -> [callerIds]); the
  // per-language maps already partition cleanly by the "<lang>:" id prefix.
  const reverse = {};
  for (const langRev of Object.values(sym.reverse || {})) Object.assign(reverse, langRev);

  // BFS (not DFS) so the first time we reach a node records its true min-depth.
  const seen = new Set();
  const depthOf = new Map();
  const seedSet = new Set(seeds);
  let frontier = [...seeds];
  let depth = 0;
  let maxDepth = 0;
  while (frontier.length) {
    depth++;
    const next = [];
    for (const cur of frontier) {
      for (const dep of reverse[cur] || []) {
        if (!seen.has(dep)) {
          seen.add(dep);
          depthOf.set(dep, depth);
          next.push(dep);
        }
      }
    }
    if (next.length) maxDepth = depth;
    frontier = next;
  }
  for (const s of seedSet) seen.delete(s);

  const definedNodes = seeds.map((id) => byId.get(id)).filter(Boolean);
  const dependentNodes = [...seen].map((id) => byId.get(id)).filter(Boolean);
  // rank dependents: distinct file count matters, but list symbols directly.
  dependentNodes.sort((a, b) =>
    a.file.localeCompare(b.file) || a.symbol.localeCompare(b.symbol));
  return {
    defined: definedNodes.map((n) => ({ id: n.id, symbol: n.symbol, kind: n.kind, exported: n.exported })),
    dependents: dependentNodes.map((n) => ({ id: n.id, file: n.file, symbol: n.symbol, kind: n.kind, depth: depthOf.get(n.id) || null })),
    files: [...new Set(dependentNodes.map((n) => n.file))].sort(),
    depth: maxDepth,
    note: symbolSeed
      ? `symbol-seeded transitive reverse closure over tooling/symbol-graph/symbols.json`
      : "transitive symbol-level reverse closure over tooling/symbol-graph/symbols.json",
  };
}

// Resolve a --symbol query ("Module" or "Module.fun" or bare "fun") to the
// matching node(s). When `file` is given we restrict to that file first; the
// query may name the module, a "Module.fun" pair, or just the function/symbol.
function matchSymbolNodes(nodes, file, query) {
  const scope = file ? nodes.filter((n) => n.file === file) : nodes;
  const pool = scope.length ? scope : nodes; // if file had nothing, search wide
  // 1) exact module / symbol name match
  let hits = pool.filter((n) => n.symbol === query);
  if (hits.length) return hits;
  // 2) "Module.fun" — split last dot, match the function within that module file
  if (query.includes(".")) {
    const fun = query.slice(query.lastIndexOf(".") + 1);
    const mod = query.slice(0, query.lastIndexOf("."));
    hits = pool.filter((n) => n.symbol === fun &&
      (n.id.includes(`#${mod}.`) || n.file.length)); // function node lives in mod's file
    if (hits.length) return hits;
    // module-name match (the dotted query *is* the module)
    hits = nodes.filter((n) => n.symbol === query);
    if (hits.length) return hits;
  }
  // 3) bare function name anywhere in scope
  hits = pool.filter((n) => n.symbol === query);
  return hits;
}

// ---- surface reach -------------------------------------------------------
// Classify which reached symbols are the USER-FACING SURFACE — the blast that
// actually changes observable behaviour:
//   • Elixir modules ending Controller / Live / Channel, or under barkpark_web/router
//   • Go funcs in package main / under a cmd/ directory
//   • TS exports from a package root (src/index.ts) or a Next.js app/ route|page|layout
function isSurface(n) {
  if (n.lang === "elixir") {
    if (n.kind === "module" && /(Controller|Live|Channel)$/.test(n.symbol)) return true;
    if (/(^|\/)barkpark_web\/router(\.|\/|$)/.test(n.file)) return true;
    return false;
  }
  if (n.lang === "go") {
    if (/(^|\/)cmd\//.test(n.file)) return true;
    if (/(^|\/)main\.go$/.test(n.file)) return true; // package main entrypoint
    return false;
  }
  if (n.lang === "ts") {
    if (/(^|\/)src\/index\.ts$/.test(n.file)) return true;            // package root
    if (/(^|\/)app\/.*\/(page|route|layout)\.tsx?$/.test(n.file)) return true; // Next.js route
    if (/(^|\/)app\/(page|route|layout)\.tsx?$/.test(n.file)) return true;
    return false;
  }
  return false;
}

function surfaceReach(dependentNodes) {
  const surface = dependentNodes.filter(isSurface);
  // dedupe to one row per (file#symbol); rank Elixir Controllers/Lives first
  const rank = (n) => (/Controller$/.test(n.symbol) ? 0 : /Live$/.test(n.symbol) ? 1 : /Channel$/.test(n.symbol) ? 2 : 3);
  surface.sort((a, b) => rank(a) - rank(b) || a.file.localeCompare(b.file) || a.symbol.localeCompare(b.symbol));
  return {
    count: surface.length,
    points: surface.map((n) => ({ file: n.file, symbol: n.symbol, kind: n.kind, lang: n.lang, depth: n.depth || null })),
  };
}

// ---- cross-language seam crossing ----------------------------------------
// A wire-contract SEAM is the boundary where a change ripples ACROSS languages.
// Seed is a seam when: nodes.json fields.seam is truthy, OR the path is a
// barkpark_web/controllers/* handler / api .../v1 route, OR a /v1 route string.
function isSeamSeed(file, selfFields) {
  if (selfFields && selfFields.seam) return true;
  if (/barkpark_web\/controllers\//.test(file)) return true;
  if (/\/v1(\/|\.|$)/.test(file)) return true;
  if (/barkpark_web\/router/.test(file)) return true;
  return false;
}

// The OTHER-language contract consumers that a seam change ripples into. These
// are the cross-language bindings generated from / coupled to the HTTP/v1
// contract: the Go apiclient, the TS @barkpark/core bindings, and the doc.
function crossLanguageSeam(blastFilesSet, dependentNodes, map) {
  const langs = new Set();
  const consumers = [];
  const add = (lang, path, why) => { langs.add(lang); consumers.push({ lang, path, why }); };

  // 1) Direct: any reached symbol/file in another language.
  const langByFile = new Map();
  for (const n of dependentNodes) langByFile.set(n.file, n.lang);
  for (const [f, l] of langByFile) {
    if (l === "go") add("go", f, "reached via symbol closure");
    else if (l === "ts") add("ts", f, "reached via symbol closure");
  }

  // 2) Contract-coupled bindings — present regardless of whether the symbol
  //    graph linked them (the wire contract couples them by convention).
  const known = [
    { lang: "go", path: "internal/apiclient/client.go", why: "Go API client bound to the v1 contract" },
    { lang: "go", path: "internal/apiclient/schema.go", why: "Go API client schema bound to the v1 contract" },
    { lang: "ts", path: "js/packages/core/src/index.ts", why: "@barkpark/core TS bindings to the v1 contract" },
    { lang: "docs", path: "docs/api-v1.md", why: "v1 API contract documentation" },
  ];
  for (const k of known) {
    if (existsSync(join(ROOT, k.path))) { langs.add(k.lang); consumers.push({ ...k, contract: true }); }
  }

  // collapse dup paths, keep first reason
  const byPath = new Map();
  for (const c of consumers) if (!byPath.has(c.path)) byPath.set(c.path, c);
  return {
    crosses: langs.size > 0,
    languages: [...langs].filter((l) => l !== "elixir"),
    consumers: [...byPath.values()],
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

// verdict — refined risk formula.
//
//   score = min(closure,60)·1            raw blast size (capped)
//         + seamTouch·8                  dependents that themselves sit on a seam
//         + highReach·4                  each high-reach dependent amplifies
//         + defectProne·3                fragile dependents add risk
//         + untestedShare·40             an untested blast radius is unverifiable
//         + surfaceReach·6               NEW: each user-facing surface point reached
//         + (crossesSeam ? 25 : 0)       NEW: a contract change that crosses a
//                                              language seam ripples beyond Elixir
//
// Rationale for the two new terms: a change reaching many surface points
// (Controllers / Lives / Channels / routes / cmd entrypoints) changes OBSERVABLE
// behaviour, and a seam crossing means the blast escapes one language's test
// net into hand-written cross-language bindings (Go apiclient, TS @barkpark/core)
// — both are strictly higher risk than the same closure size buried internally.
// The original closure × untested factors are preserved verbatim.
function verdict(rows, extra = {}) {
  const { surfaceCount = 0, crossesSeam = false } = extra;
  const n = rows.length;
  const highReach = rows.filter((r) => r.reach !== null && r.reach >= HIGH_REACH).length;
  const seamTouch = rows.filter((r) => r.seam).length;
  const defectProne = rows.filter((r) => r.defectDensity !== null && r.defectDensity >= FRAGILE).length;
  const untested = rows.filter((r) => !r.hasTest).length;
  const untestedShare = n ? untested / n : 0;

  let score = 0;
  score += Math.min(n, 60) * 1.0; // raw blast size (capped contribution)
  score += seamTouch * 8; // crossing a seam is expensive
  score += highReach * 4; // each high-reach dependent amplifies
  score += defectProne * 3; // fragile dependents add risk
  score += untestedShare * 40; // an untested blast radius is unverifiable
  score += surfaceCount * 6; // each user-facing surface point reached
  score += crossesSeam ? 25 : 0; // a cross-language contract crossing

  let level;
  if (n === 0 && surfaceCount === 0) level = "NONE";
  else if (score >= 140 || (seamTouch > 0 && n >= 30 && untestedShare > 0.6) || (crossesSeam && surfaceCount >= 10))
    level = "CRITICAL";
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
    surfaceReach: surfaceCount,
    crossesSeam: !!crossesSeam,
  };
}

// ---- run -----------------------------------------------------------------
const args = process.argv.slice(2);
const wantJson = args.includes("--json");
const noSymbols = args.includes("--no-symbols");
const wantSymbols = args.includes("--symbols");

// --symbol <Module|Module.fun> seeds the closure from a specific symbol instead
// of the whole file. Accept "--symbol X" and "--symbol=X".
let symbolSeed = null;
const symFlagIdx = args.findIndex((a) => a === "--symbol" || a.startsWith("--symbol="));
if (symFlagIdx !== -1) {
  const a = args[symFlagIdx];
  symbolSeed = a.includes("=") ? a.slice(a.indexOf("=") + 1) : args[symFlagIdx + 1];
}

// Positional file arg: first bareword that isn't the --symbol value.
const symValue = symFlagIdx !== -1 && !args[symFlagIdx].includes("=") ? args[symFlagIdx + 1] : null;
let file = args.find((a, i) => !a.startsWith("--") && a !== symValue) || null;

if (!file && !symbolSeed) {
  console.error("usage: what-breaks.mjs <file> [--symbol <Module|Module.fun>] [--json] [--symbols|--no-symbols]");
  process.exit(2);
}

// When seeding from a symbol and no file is given, derive the file from the
// symbol's node so file-level overlays still work.
const map = loadMap();
const symEarly = (wantSymbols || !noSymbols || symbolSeed) ? loadSymbols() : null;
if (symbolSeed && !file && symEarly) {
  const m = matchSymbolNodes(symEarly.nodes, null, symbolSeed);
  if (m.length) file = m[0].file;
}
if (!file) {
  console.error(`could not resolve a file for --symbol "${symbolSeed}" (symbols.json absent or symbol unknown).`);
  process.exit(2);
}

const blast = blastFiles(file, map);
const rows = enrich(blast.files, map);
rows.sort((a, b) => (b.reach || 0) - (a.reach || 0) || a.path.localeCompare(b.path));

// Currency check — is the map we just queried built against today's tree?
const currency = safeVerify();

// Symbol-level overlay (additive). Auto-use when symbols.json exists unless the
// caller opts out with --no-symbols; --symbols (or --symbol) forces it on and
// errors loudly if the artifact is missing.
let symbolBlast = null;
let surface = { count: 0, points: [] };
let seam = { crosses: false, languages: [], consumers: [] };
const sym = symEarly;
if (sym) {
  symbolBlast = blastSymbols(file, sym, symbolSeed);
  // resolve dependent node objects (with their depth) for surface/seam classification
  const byId = new Map(sym.nodes.map((n) => [n.id, n]));
  const depNodes = symbolBlast.dependents.map((d) => {
    const node = byId.get(d.id);
    return node ? { ...node, depth: d.depth } : d;
  });
  surface = surfaceReach(depNodes);
  if (isSeamSeed(file, (map.byPath.get(file) || {}).fields)) {
    seam = crossLanguageSeam(blast.files, depNodes, map);
  }
} else if (wantSymbols || symbolSeed) {
  console.error(`symbol query requested but ${SYMBOLS} not found.\n  build it first: node tooling/symbol-graph/build-symbols.mjs --skip-go --skip-ts`);
  console.error(`  falling back to file-level mode.`);
}

const v = verdict(rows, { surfaceCount: surface.count, crossesSeam: seam.crosses });

const result = {
  target: file,
  symbolSeed: symbolSeed || null,
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
    maxDepth: symbolBlast.depth || 0,
    defined: symbolBlast.defined,
    dependents: symbolBlast.dependents.slice(0, 50),
    note: symbolBlast.note,
    surface: { count: surface.count, points: surface.points.slice(0, 25) },
    seam,
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
  if (typeof v.surfaceReach === "number" && (v.surfaceReach > 0 || v.crossesSeam)) {
    console.log(`├ surface reach:  ${v.surfaceReach} user-facing point(s)`);
    console.log(`├ cross-lang seam:${v.crossesSeam ? " YES — contract change ripples across languages" : " no"}`);
  }
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

  // Symbol-level overlay — which SPECIFIC functions/modules depend on this
  // file/symbol, transitively, plus surface reach and cross-language seam.
  if (res.symbols) {
    const s = res.symbols;
    console.log(`\n${"─".repeat(64)}`);
    const seedLabel = res.symbolSeed ? `symbol ${res.symbolSeed}` : `${s.definedCount} symbols defined here`;
    console.log(`SYMBOL-LEVEL BLAST  ·  seed: ${seedLabel}`);
    console.log(`  transitive closure: ${s.dependentCount} dependent symbols across ${s.dependentFiles.length} files, max depth ${s.maxDepth}`);

    // Surface reach.
    if (s.surface) {
      console.log(`  reaches ${s.surface.count} surface point(s) (user-facing: Controllers · Lives · Channels · routes · cmd entrypoints)`);
      const shown = s.surface.points.slice(0, 12);
      for (const p of shown) {
        console.log(`    ▸ ${p.symbol}  [${p.lang}/${p.kind}]  ${p.file}${p.depth ? `  (depth ${p.depth})` : ""}`);
      }
      if (s.surface.count > shown.length) {
        console.log(`    … and ${s.surface.count - shown.length} more surface point(s)`);
      }
    }

    // Cross-language seam crossing.
    if (s.seam && s.seam.crosses) {
      const langs = s.seam.languages.length ? s.seam.languages.join(", ") : "(none)";
      console.log(`\n  ⚠ CROSS-LANGUAGE SEAM — this is a wire contract; a change ripples beyond Elixir into: ${langs}`);
      for (const c of s.seam.consumers) {
        console.log(`    → [${c.lang}] ${c.path}${c.contract ? "  (contract-coupled)" : ""}  — ${c.why}`);
      }
    }

    // Raw dependent listing (still useful for symbol-precise work).
    if (s.dependentCount) {
      console.log(`\n  dependent symbols:`);
      const shown = s.dependents.slice(0, 20);
      for (const d of shown) {
        console.log(`    ${d.file}#${d.symbol}  [${d.kind}]${d.depth ? `  d${d.depth}` : ""}`);
      }
      if (s.dependentCount > shown.length) {
        console.log(`    … and ${s.dependentCount - shown.length} more dependent symbols (use --json for all)`);
      }
    } else if (!s.surface || !s.surface.count) {
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
