#!/usr/bin/env node
// build-symbols.mjs — SYMBOL-LEVEL dependency graph for the polyglot monorepo.
//
// Phase 2 of cqv5. Where tooling/blast-radius/index.json is FILE/MODULE-grained,
// this descends one level: individual functions, methods, modules, exports — and
// the edges between them (calls / references / imports / defines).
//
// DEPENDENCY-FREE on purpose. No golang.org/x/tools, no ts-morph, no npm. We
// regex-scan source the same way tooling/blast-radius/build-index.mjs and
// tooling/ergonomics/measure.mjs already do, and we REUSE the warm artifacts in
// index.json (the go import graph + the mix-xref elixir module graph) to lift
// confidence where a real toolchain has already spoken.
//
// Honesty is encoded in a `confidence` tier on every edge:
//   exact     — confirmed by a real toolchain (mix xref module edge, go import graph)
//   static    — an explicit, syntactically unambiguous reference (Module.fun, pkg.Name)
//   heuristic — a best-effort regex match (bare local call, loose TS import)
//
// Node id:  "<lang>:<file>#<symbol>"
// Node:     { id, lang, file, symbol, kind, exported }
// Edge:     { from, to, type, confidence }
//
// Output: tooling/symbol-graph/symbols.json
//   { head, builtAt, byLang:{ go|elixir|ts:{sig,nodeCount,edgeCount} },
//     nodes, edges, reverse:{ go|elixir|ts:{ symId -> [callerIds] } } }
//
// Per-language work is cached behind a content signature (a hash of
// `git ls-files -s` for that language's files + dirty edits) — re-scans only
// when those files change. Per-language failure is NON-FATAL: it skips that
// language, notes it, and keeps the rest.
//
// CLI:
//   node tooling/symbol-graph/build-symbols.mjs                 full build
//        --skip-go --skip-ts --skip-elixir                      drop a language
//        --no-elixir-compile                                    don't warm mix
//
import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { createHash } from "node:crypto";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: HERE }).toString().trim();
const args = new Set(process.argv.slice(2));
const sh = (cmd, a, opts = {}) =>
  execFileSync(cmd, a, { cwd: ROOT, encoding: "utf8", maxBuffer: 256 * 1024 * 1024, ...opts });
const read = (f) => { try { return readFileSync(join(ROOT, f), "utf8"); } catch { return ""; } };
const e = (s) => process.stderr.write(s + "\n");

// Warm file/module graph from blast-radius. Best-effort — may be empty.
const index = (() => {
  try { return JSON.parse(readFileSync(join(ROOT, "tooling/blast-radius/index.json"), "utf8")); }
  catch { return { go: null, js: null, elixir: null }; }
})();

// ---- content signatures (generalized elixirSig) --------------------------
// One signature per language over the git-tracked source for that language,
// folding in uncommitted edits so a dirty tree re-scans.
function langSig(globRe) {
  try {
    const lines = sh("git", ["ls-files", "-s"]).split("\n").filter((l) => globRe.test(l)).sort();
    const dirty = sh("git", ["status", "--porcelain"]).split("\n").filter((l) => globRe.test(l)).sort().join("|");
    return createHash("sha256").update(lines.join("\n") + "##" + dirty).digest("hex").slice(0, 16);
  } catch { return ""; }
}
function lsFiles(...globs) {
  try { return sh("git", ["ls-files", ...globs]).split("\n").filter(Boolean); } catch { return []; }
}

// reverse adjacency for a slice of edges: symId -> sorted unique [callerIds]
function reverseOf(edges) {
  const rev = {};
  for (const ed of edges) (rev[ed.to] ||= []).push(ed.from);
  for (const k of Object.keys(rev)) rev[k] = [...new Set(rev[k])].sort();
  return rev;
}

// ================================================================ ELIXIR ===
// Highest fidelity. We know every module's file, every def/defp it owns, and
// (via mix xref in index.json) the confirmed module→module graph. We turn the
// module graph into module-node edges (exact), and explicit `Module.fun(` call
// sites into symbol→symbol edges (static), bare local calls into heuristic.
function buildElixir(files) {
  const nodes = [];
  const edges = [];
  const id = (file, sym) => `elixir:${file}#${sym}`;

  // Pass 1 — index every module and its symbols.
  const moduleFile = {};        // "Barkpark.Content" -> "api/lib/.../content.ex"
  const moduleSymbols = {};     // module -> Map(funcName -> {file, exported})
  const fileModule = {};        // file -> module (primary)
  const aliasExpansions = {};   // file -> Map(localAlias -> fullModule)

  for (const f of files) {
    const txt = read(f);
    // A file can hold several defmodules; bind defs to the nearest preceding one.
    let curMod = null;
    const lines = txt.split("\n");
    for (const line of lines) {
      const dm = line.match(/^\s*defmodule\s+([A-Z][\w.]+)\s+do/);
      if (dm) {
        curMod = dm[1];
        if (!(curMod in moduleFile)) moduleFile[curMod] = f;
        if (!(f in fileModule)) fileModule[f] = curMod;
        moduleSymbols[curMod] ||= new Map();
        // the module itself is a node (kind: module)
        nodes.push({ id: id(f, curMod), lang: "elixir", file: f, symbol: curMod, kind: "module", exported: true });
        continue;
      }
      // def / defp  (exported = def, private = defp)
      const fn = line.match(/^\s*(defp?)\s+([a-z_][\w?!]*)/);
      if (fn && curMod) {
        const name = fn[2];
        const exported = fn[1] === "def";
        const m = moduleSymbols[curMod];
        if (!m.has(name)) {
          m.set(name, { file: f, exported });
          nodes.push({ id: id(f, name), lang: "elixir", file: f, symbol: name, kind: "func", exported });
        } else if (exported) {
          m.get(name).exported = true; // multi-clause: any public clause makes it public
        }
      }
    }
    // alias resolution for this file (used to resolve short Module.fun calls)
    const am = new Map();
    for (const a of txt.matchAll(/\balias\s+([A-Z][\w.]+)(?:,\s*as:\s*([A-Z][\w.]+))?/g)) {
      const full = a[1];
      const as = a[2] || full.split(".").pop();
      am.set(as, full);
    }
    for (const a of txt.matchAll(/\balias\s+([A-Z][\w.]+)\.\{([^}]+)\}/g)) {
      for (const part of a[2].split(",")) {
        const p = part.trim();
        if (p) am.set(p.split(".").pop(), `${a[1]}.${p}`);
      }
    }
    aliasExpansions[f] = am;
  }

  const symKnown = new Set(nodes.map((n) => n.id));

  // Pass 2 — module-level EXACT edges from the warm mix-xref graph.
  // index.elixir.forward: file -> [files it references]. Lift to module nodes.
  const exForward = index.elixir?.forward || {};
  for (const [fromFile, toFiles] of Object.entries(exForward)) {
    const fromMod = fileModule[fromFile];
    if (!fromMod) continue;
    for (const toFile of toFiles) {
      const toMod = fileModule[toFile];
      if (!toMod || toMod === fromMod) continue;
      const fromId = id(fromFile, fromMod), toId = id(toFile, toMod);
      if (symKnown.has(fromId) && symKnown.has(toId))
        edges.push({ from: fromId, to: toId, type: "imports", confidence: "exact" });
    }
  }

  // Pass 3 — call-site edges per file.
  for (const f of files) {
    const txt = read(f);
    const fromMod = fileModule[f];
    if (!fromMod) continue;
    const am = aliasExpansions[f] || new Map();
    const seen = new Set();

    // Explicit Module.fun(  → STATIC. Resolve Module via alias table, then by full name.
    for (const m of txt.matchAll(/\b([A-Z][\w.]*)\.([a-z_][\w?!]*)\s*\(/g)) {
      const modRef = m[1], fn = m[2];
      // resolve modRef → full module name
      let full = am.get(modRef);
      if (!full) {
        // maybe modRef is already a full module we know, or an aliased head segment
        if (moduleFile[modRef]) full = modRef;
        else {
          const head = modRef.split(".")[0];
          const headFull = am.get(head);
          if (headFull) full = headFull + modRef.slice(head.length);
          else full = modRef;
        }
      }
      const defFile = moduleFile[full];
      if (!defFile) continue;
      const toId = id(defFile, fn);
      if (!symKnown.has(toId)) continue;
      const fromId = id(f, fromMod);
      const key = fromId + ">" + toId;
      if (seen.has(key)) continue;
      seen.add(key);
      edges.push({ from: fromId, to: toId, type: "calls", confidence: "static" });
    }

    // Bare local calls  fun(  resolved within the SAME module → HEURISTIC.
    const ownSyms = moduleSymbols[fromMod] || new Map();
    for (const m of txt.matchAll(/(?:^|[^.\w])([a-z_][\w?!]*)\s*\(/g)) {
      const fn = m[1];
      if (!ownSyms.has(fn)) continue;
      const def = ownSyms.get(fn);
      const toId = id(def.file, fn);
      const fromId = id(f, fromMod);
      if (toId === fromId) continue;
      const key = "h:" + fromId + ">" + toId;
      if (seen.has(key)) continue;
      seen.add(key);
      edges.push({ from: fromId, to: toId, type: "references", confidence: "heuristic" });
    }
  }

  return { nodes, edges };
}

// ==================================================================== GO ===
// func defs (incl. methods), resolved call sites via the go import graph in
// index.json. pkg.Name( where pkg is an imported INTERNAL package → static.
function buildGo(files) {
  const nodes = [];
  const edges = [];
  const id = (file, sym) => `go:${file}#${sym}`;
  const MOD = "github.com/FRIKKern/barkpark";

  // dir -> internal import path (from warm index)
  const dirToPkg = index.go?.dirToPkg || {};
  const pkgToDir = {};
  for (const [d, p] of Object.entries(dirToPkg)) pkgToDir[p] = d;

  // Pass 1 — defs. Track each file's package dir + its exported func/method names.
  const fileDir = {};
  const pkgDirSymbols = {};   // dir -> Map(funcName -> {file, exported})
  const pkgDirPkgName = {};    // dir -> local `package x` name
  for (const f of files) {
    const txt = read(f);
    const dir = dirname(f);
    fileDir[f] = dir;
    pkgDirSymbols[dir] ||= new Map();
    const pn = txt.match(/^package\s+(\w+)/m);
    if (pn && !(dir in pkgDirPkgName)) pkgDirPkgName[dir] = pn[1];
    for (const line of txt.split("\n")) {
      // func (recv T) Name(   OR   func Name(
      let m = line.match(/^func\s+\([^)]*\)\s+([A-Za-z_]\w*)\s*\(/);
      let kind = "method";
      if (!m) { m = line.match(/^func\s+([A-Za-z_]\w*)\s*\(/); kind = "func"; }
      if (!m) continue;
      const name = m[1];
      const exported = /^[A-Z]/.test(name);
      const map = pkgDirSymbols[dir];
      // method names can collide across receivers; keep first-seen def file.
      if (!map.has(name)) {
        map.set(name, { file: f, exported });
        nodes.push({ id: id(f, name), lang: "go", file: f, symbol: name, kind, exported });
      }
    }
  }

  const symKnown = new Set(nodes.map((n) => n.id));

  // Pass 2 — call sites. For each file, find imported internal pkgs (local
  // alias -> dir), then pkgAlias.Name( resolves to a def in that pkg's dir.
  for (const f of files) {
    const txt = read(f);
    const fromDir = fileDir[f];
    // collect imports: "<path>" or alias "<path>" inside import ( ... ) or single
    const aliasToDir = {};   // localName -> dir (internal only)
    const importBlock = txt.match(/import\s*\(([\s\S]*?)\)/);
    const importLines = importBlock
      ? importBlock[1].split("\n")
      : (txt.match(/^import\s+(?:\w+\s+)?"[^"]+"/gm) || []);
    for (const line of importLines) {
      const im = line.match(/^\s*(?:(\w+)\s+)?"([^"]+)"/);
      if (!im) continue;
      const alias = im[1], path = im[2];
      if (!path.startsWith(MOD)) continue;
      const dir = pkgToDir[path];
      if (!dir) continue;
      const local = alias || pkgDirPkgName[dir] || path.split("/").pop();
      aliasToDir[local] = dir;
    }
    if (!Object.keys(aliasToDir).length) continue;

    // representative "from" symbol: the file's package node-set is symbol-level,
    // but a call's enclosing func is cheap to track by scanning blocks. We use a
    // lightweight enclosing-func tracker.
    const lines = txt.split("\n");
    let enclosing = null;
    const seen = new Set();
    const ownMap = pkgDirSymbols[fromDir] || new Map();
    for (const line of lines) {
      const fm = line.match(/^func\s+(?:\([^)]*\)\s+)?([A-Za-z_]\w*)\s*\(/);
      if (fm && ownMap.has(fm[1])) enclosing = id(ownMap.get(fm[1]).file, fm[1]);
      for (const cm of line.matchAll(/\b(\w+)\.([A-Z]\w*)\s*\(/g)) {
        const pkgAlias = cm[1], name = cm[2];
        const dir = aliasToDir[pkgAlias];
        if (!dir) continue;
        const def = (pkgDirSymbols[dir] || new Map()).get(name);
        if (!def) continue;
        const toId = id(def.file, name);
        if (!symKnown.has(toId)) continue;
        const fromId = enclosing || id(f, "(file)");
        if (fromId === toId) continue;
        const key = fromId + ">" + toId;
        if (seen.has(key)) continue;
        seen.add(key);
        if (fromId.endsWith("#(file)") && !symKnown.has(fromId)) {
          nodes.push({ id: fromId, lang: "go", file: f, symbol: "(file)", kind: "module", exported: false });
          symKnown.add(fromId);
        }
        edges.push({ from: fromId, to: toId, type: "calls", confidence: "static" });
      }
    }
  }

  return { nodes, edges };
}

// ==================================================================== TS ===
// export function/const/class/interface/type/enum (defs). Imports + call sites
// resolved by relative path; loose by nature → heuristic, static for the
// import edge itself when the target file+symbol both resolve.
function buildTs(files) {
  const nodes = [];
  const edges = [];
  const id = (file, sym) => `ts:${file}#${sym}`;
  const fileSet = new Set(files);

  // Pass 1 — exported defs.
  const fileExports = {};   // file -> Set(symbolName)
  for (const f of files) {
    const txt = read(f);
    fileExports[f] = new Set();
    for (const line of txt.split("\n")) {
      // export [default] function|const|class|interface|type|enum NAME
      const m = line.match(/^\s*export\s+(?:default\s+)?(?:async\s+)?(function|const|class|interface|type|enum)\s+([A-Za-z_$][\w$]*)/);
      if (m) {
        const name = m[2];
        const kind = m[1] === "function" || m[1] === "const" ? "function" : m[1] === "class" ? "export" : "export";
        if (!fileExports[f].has(name)) {
          fileExports[f].add(name);
          nodes.push({ id: id(f, name), lang: "ts", file: f, symbol: name, kind: "export", exported: true });
        }
        continue;
      }
      // export { A, B } [from '...']  — re-exports / named export lists
      const me = line.match(/^\s*export\s+(?:type\s+)?\{([^}]+)\}/);
      if (me) {
        for (const part of me[1].split(",")) {
          const name = part.trim().split(/\s+as\s+/)[0].trim();
          if (name && /^[A-Za-z_$][\w$]*$/.test(name) && !fileExports[f].has(name)) {
            fileExports[f].add(name);
            nodes.push({ id: id(f, name), lang: "ts", file: f, symbol: name, kind: "export", exported: true });
          }
        }
      }
    }
  }

  const symKnown = new Set(nodes.map((n) => n.id));

  // resolve a relative import spec from a file to an in-universe file.
  const resolveRel = (fromFile, spec) => {
    const base = join(dirname(fromFile), spec);
    for (const c of [base, base + ".ts", base + ".tsx", base + ".js", base + ".mjs",
                     base + "/index.ts", base + "/index.tsx", base + "/index.js"])
      if (fileSet.has(c)) return c;
    return null;
  };

  // Pass 2 — imports + call references.
  for (const f of files) {
    const txt = read(f);
    // imported name -> target file (relative imports only; bare specifiers skipped)
    const importedFrom = {};
    const seen = new Set();
    for (const m of txt.matchAll(/import\s+(?:type\s+)?(?:\{([^}]+)\}|(\*\s+as\s+\w+)|([A-Za-z_$][\w$]*))?\s*(?:,\s*\{([^}]+)\})?\s*from\s+['"]([^'"]+)['"]/g)) {
      const spec = m[5];
      if (!spec.startsWith(".")) continue;
      const target = resolveRel(f, spec);
      if (!target) continue;
      const named = [m[1], m[4]].filter(Boolean).join(",");
      for (const part of named.split(",")) {
        const name = part.trim().split(/\s+as\s+/)[0].trim();
        if (!name) continue;
        importedFrom[name] = target;
        const toId = id(target, name);
        if (symKnown.has(toId)) {
          // the importing file as a unit (module node) -> the imported symbol
          const fromId = id(f, "(module)");
          if (!symKnown.has(fromId)) {
            nodes.push({ id: fromId, lang: "ts", file: f, symbol: "(module)", kind: "module", exported: false });
            symKnown.add(fromId);
          }
          const key = "i:" + fromId + ">" + toId;
          if (!seen.has(key)) { seen.add(key); edges.push({ from: fromId, to: toId, type: "imports", confidence: "static" }); }
        }
      }
    }
    // call sites: importedName( → edge from this module to that symbol (heuristic)
    for (const m of txt.matchAll(/\b([A-Za-z_$][\w$]*)\s*\(/g)) {
      const name = m[1];
      const target = importedFrom[name];
      if (!target) continue;
      const toId = id(target, name);
      if (!symKnown.has(toId)) continue;
      const fromId = id(f, "(module)");
      if (!symKnown.has(fromId)) {
        nodes.push({ id: fromId, lang: "ts", file: f, symbol: "(module)", kind: "module", exported: false });
        symKnown.add(fromId);
      }
      if (fromId === toId) continue;
      const key = "c:" + fromId + ">" + toId;
      if (seen.has(key)) continue;
      seen.add(key);
      edges.push({ from: fromId, to: toId, type: "calls", confidence: "heuristic" });
    }
  }

  return { nodes, edges };
}

// ------------------------------------------------------------------- main ---
// Warm Elixir compile if needed (mirrors build-index.mjs) — only when we're
// actually building Elixir and the xref forward graph is absent from index.json.
function maybeWarmElixir() {
  if (args.has("--skip-elixir") || args.has("--no-elixir")) return;
  if (index.elixir?.forward) return; // already have the warm graph
  if (args.has("--no-elixir-compile")) { e("[elixir] index.json has no mix-xref graph; module edges will be regex-only"); return; }
  // We don't strictly need to compile — the regex def/call scan stands alone and
  // only the EXACT module edges depend on index.json. Note it and move on.
  e("[elixir] no mix-xref graph in index.json — EXACT module edges unavailable (run build-index.mjs to warm). Proceeding with static/heuristic edges.");
}

const out = join(HERE, "symbols.json");
const prior = existsSync(out) ? (() => { try { return JSON.parse(readFileSync(out, "utf8")); } catch { return {}; } })() : {};

const SIG_RE = { go: /\.go$/, elixir: /\.exs?$/, ts: /\.(ts|tsx|mjs|js|jsx)$/ };

const allNodes = [];
const allEdges = [];
const byLang = {};
const reverse = {};

function runLang(name, skipFlag, fileGlobs, fileFilter, builder) {
  if (args.has(skipFlag)) { e(`[${name}] skipped (${skipFlag})`);
    // preserve prior cached slice if present so the file stays whole
    if (prior.byLang?.[name] && prior.nodes && prior.edges) {
      const pn = prior.nodes.filter((n) => n.lang === name);
      const pe = prior.edges.filter((ed) => ed.from.startsWith(name + ":"));
      allNodes.push(...pn); allEdges.push(...pe);
      byLang[name] = prior.byLang[name];
      reverse[name] = prior.reverse?.[name] || reverseOf(pe);
      e(`[${name}] reused prior slice (${pn.length} nodes, ${pe.length} edges)`);
    }
    return;
  }
  const sig = langSig(SIG_RE[name]);
  if (sig && prior.byLang?.[name]?.sig === sig && prior.nodes && prior.edges) {
    const pn = prior.nodes.filter((n) => n.lang === name);
    const pe = prior.edges.filter((ed) => ed.from.startsWith(name + ":"));
    allNodes.push(...pn); allEdges.push(...pe);
    byLang[name] = prior.byLang[name];
    reverse[name] = prior.reverse?.[name] || reverseOf(pe);
    e(`[${name}] reused cache — no ${name} changes (sig ${sig})`);
    return;
  }
  let files = lsFiles(...fileGlobs).filter(fileFilter);
  try {
    const { nodes, edges } = builder(files);
    allNodes.push(...nodes); allEdges.push(...edges);
    byLang[name] = { sig, nodeCount: nodes.length, edgeCount: edges.length };
    reverse[name] = reverseOf(edges);
    e(`[${name}] ${nodes.length} symbols · ${edges.length} edges`);
  } catch (err) {
    e(`[${name}] FAILED (non-fatal): ${(err.message || String(err)).split("\n")[0]}`);
    byLang[name] = { sig, nodeCount: 0, edgeCount: 0, error: (err.message || String(err)).split("\n")[0] };
    reverse[name] = {};
  }
}

maybeWarmElixir();

runLang("elixir", "--skip-elixir",
  ["api/**/*.ex", "api/**/*.exs"],
  (f) => /\.exs?$/.test(f) && !/\.exs$/.test(f), // .ex only for defs (skip .exs scripts/tests)
  buildElixir);

runLang("go", "--skip-go",
  ["**/*.go"],
  (f) => f.endsWith(".go") && !/_test\.go$/.test(f),
  buildGo);

runLang("ts", "--skip-ts",
  ["js/**/*.ts", "js/**/*.tsx", "web/**/*.ts", "web/**/*.tsx", "sdk/**/*.ts", "sdk/**/*.tsx"],
  (f) => /\.(ts|tsx)$/.test(f) && !/\.d\.ts$/.test(f),
  buildTs);

const symbols = {
  builtAtNote: "regenerate with: node tooling/symbol-graph/build-symbols.mjs",
  head: (() => { try { return sh("git", ["rev-parse", "HEAD"]).trim(); } catch { return ""; } })(),
  builtAt: new Date().toISOString(),
  byLang,
  nodes: allNodes,
  edges: allEdges,
  reverse,
};
writeFileSync(out, JSON.stringify(symbols, null, 2));

// ---- summary footer (mirrors build-index.mjs) ----
e(`[symbol-graph] written: tooling/symbol-graph/symbols.json`);
for (const lang of ["elixir", "go", "ts"]) {
  const b = byLang[lang];
  if (!b) { e(`  ${lang.padEnd(7)} (skipped)`); continue; }
  const revKeys = Object.keys(reverse[lang] || {}).length;
  e(`  ${lang.padEnd(7)} ${String(b.nodeCount).padStart(5)} symbols · ${String(b.edgeCount).padStart(5)} edges · ${String(revKeys).padStart(5)} symbols with callers${b.error ? ` · ERROR ${b.error}` : ""}`);
}
e(`  total   ${allNodes.length} nodes · ${allEdges.length} edges`);
