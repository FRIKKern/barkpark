#!/usr/bin/env node
// Generate the codebase graph for Barkpark ingest — one NODE per code file
// (all quality metrics + the file's content) and file-level dependency EDGES.
// Schema-agnostic intermediate: emits nodes.json. push.mjs formats + posts it.
//
//   generate.mjs   → nodes.json { nodes:[{id,path,fields,content,deps:[id]}], stats }

import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { dirname, join, basename, extname, resolve, relative } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: HERE }).toString().trim();
const rd = (p, d) => existsSync(join(ROOT, p)) ? JSON.parse(readFileSync(join(ROOT, p), "utf8")) : d;
const read = (f) => { try { return readFileSync(join(ROOT, f), "utf8"); } catch { return ""; } };

const sig = Object.fromEntries(rd("tooling/file-importance/file-signals.json", { signals: [] }).signals.map(s => [s.path, s]));
const comb = Object.fromEntries(rd("tooling/combined/combined-report.json", { rows: [] }).rows.map(r => [r.path, r]));
const risk = rd("tooling/risk/risk-report.json", { files: {} }).files;
const erg = Object.fromEntries(rd("tooling/ergonomics/ergonomics-report.json", { files: [] }).files.map(f => [f.path, f]));
const ledger = rd("tooling/research-coverage/research-ledger.json", { files: {} }).files;
const idx = rd("tooling/blast-radius/index.json", { go: {}, js: {} });
const useful = rd("tooling/usefulness/usefulness-report.json", { files: {} }).files;
const intents = rd("tooling/intentions/intentions-report.json", { taxonomy: [], files: {}, hubs: {} });
const intId = (id) => "intent-" + id;

// universe = code files (the graph nodes)
const universe = Object.values(sig).filter(s => s.kind === "code").map(s => s.path);
const inUniverse = new Set(universe);
const slug = (p) => p.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
const idOf = (p) => slug(p);

const MAX_DEPS = 10; // keep the graph airy (avg degree ~7 is the Obsidian-like sweet spot)

// ---- file-level dependency resolvers (per stack) ----
// Elixir: module → file map, then alias/import/use refs
const exModule = {};
for (const f of universe) if (/\.exs?$/.test(f)) { const m = read(f).match(/defmodule\s+([\w.]+)/); if (m) exModule[m[1]] = f; }
function elixirDeps(f, txt) {
  const out = new Set();
  for (const m of txt.matchAll(/\b(?:alias|import|use|require)\s+([A-Z][\w.]+)/g)) { const t = exModule[m[1]]; if (t && t !== f) out.add(t); }
  // alias Foo.{A, B}
  for (const m of txt.matchAll(/\balias\s+([\w.]+)\.\{([^}]+)\}/g)) for (const part of m[2].split(",")) { const t = exModule[`${m[1]}.${part.trim()}`]; if (t && t !== f) out.add(t); }
  return out;
}
// JS/TS: relative + workspace imports
const jsDirToName = idx.js?.dirToName || {};
const nameToDir = Object.fromEntries(Object.entries(jsDirToName).map(([d, n]) => [n, d]));
function resolveRel(fromDir, spec) {
  const base = resolve("/" + fromDir, spec).slice(1);
  for (const c of [base, base + ".ts", base + ".tsx", base + ".js", base + ".mjs", base + "/index.ts", base + "/index.tsx", base + "/index.js"])
    if (inUniverse.has(c)) return c;
  return null;
}
function jsDeps(f, txt) {
  const out = new Set(), fromDir = dirname(f);
  for (const m of txt.matchAll(/from\s+['"]([^'"]+)['"]/g)) {
    const spec = m[1];
    if (spec.startsWith(".")) { const t = resolveRel(fromDir, spec); if (t && t !== f) out.add(t); }
    else if (spec.startsWith("@barkpark/") || spec === "barkpark") { const dir = nameToDir[spec.split("/").slice(0, 2).join("/")] || nameToDir[spec]; if (dir) for (const idxf of [`${dir}/src/index.ts`, `${dir}/index.ts`]) if (inUniverse.has(idxf) && idxf !== f) out.add(idxf); }
  }
  return out;
}
// Go: imported internal package → representative files in that package dir
const goPkgToDir = {};
for (const [d, p] of Object.entries(idx.go?.dirToPkg || {})) goPkgToDir[p] = d;
const goDirFiles = {};
for (const f of universe) if (f.endsWith(".go")) (goDirFiles[dirname(f)] ||= []).push(f);
function goDeps(f, txt) {
  const out = new Set(), MOD = "github.com/FRIKKern/barkpark/";
  const blk = txt.match(/import\s*\(([\s\S]*?)\)/); const body = blk ? blk[1] : (txt.match(/import\s+"[^"]+"/g) || []).join("\n");
  for (const m of body.matchAll(/"([^"]+)"/g)) {
    if (!m[1].startsWith(MOD)) continue;
    const dir = goPkgToDir[m[1]]; if (!dir) continue;
    for (const tf of (goDirFiles[dir] || []).filter(x => !/_test\.go$/.test(x)).slice(0, 3)) if (tf !== f) out.add(tf);
  }
  return out;
}

function depsFor(f) {
  const txt = read(f);
  let d;
  if (/\.exs?$/.test(f)) d = elixirDeps(f, txt);
  else if (/\.(ts|tsx|js|mjs|jsx)$/.test(f)) d = jsDeps(f, txt);
  else if (f.endsWith(".go")) d = goDeps(f, txt);
  else d = new Set();
  return [...d].filter(t => inUniverse.has(t)).slice(0, MAX_DEPS);
}

// ---- build nodes ----
const CONTENT_CAP = 60000; // chars of file content stored on the doc
const nodes = universe.map(p => {
  const s = sig[p] || {}, c = comb[p] || {}, rk = risk[p] || {}, e = erg[p] || {}, l = ledger[p] || {};
  const body = read(p);
  return {
    id: idOf(p), path: p, title: p,
    fields: {
      path: p, basename: basename(p), dir: dirname(p), ext: extname(p).slice(1),
      stack: s.stack || "", importance: c.importance ?? s.prior ?? 0, priority: c.priority ?? 0,
      role: c.role || l.role || "", description: l.description || "",
      tokens: e.tokens ?? 0, loc: s.loc ?? 0, sizeClass: e.sizeClass || "", defs: e.defs ?? 0,
      churn: s.churn ?? 0, fanIn: s.fanIn ?? 0, seam: !!s.seam,
      testScore: rk.testScore ?? null, hasTest: !!rk.hasTest, defectDensity: rk.defectDensity ?? 0,
      consistency: c.status || "clean", whatBreaks: l.whatBreaks || "",
      usefulness: useful[p]?.usefulness ?? null, whyUseful: useful[p]?.why_useful || "",
      intentions: intents.files[p] || [],
    },
    content: body.length > CONTENT_CAP ? body.slice(0, CONTENT_CAP) + `\n\n… (${body.length - CONTENT_CAP} more chars truncated)` : body,
    truncated: body.length > CONTENT_CAP,
    deps: depsFor(p).map(idOf),       // dependency edges (file → file)
    depPaths: depsFor(p),
    intentRefs: (intents.files[p] || []).map(intId),  // intention edges (file → hub)
  };
});

// ---- intention hub nodes (objectives that cluster cross-cutting files) ----
const intentNodes = (intents.taxonomy || []).filter(t => (intents.hubs[t.id] || []).length).map(t => ({
  id: intId(t.id), path: intId(t.id), title: t.title, kind: "intention",
  fields: { kind: "intention", scale: t.scale, title: t.title, description: t.description, members: (intents.hubs[t.id] || []).length },
  content: `${t.title}\n\n${t.description}\n\nScale: ${t.scale}\n\nFiles advancing this intention (${(intents.hubs[t.id] || []).length}):\n` + (intents.hubs[t.id] || []).map(p => "  • " + p).join("\n"),
  deps: [], depPaths: [], intentRefs: [],
}));
nodes.push(...intentNodes);

const edges = nodes.reduce((a, n) => a + n.deps.length, 0);
const intentEdges = nodes.reduce((a, n) => a + (n.intentRefs?.length || 0), 0);
const avgDeg = (edges / nodes.length).toFixed(1);
const orphans = nodes.filter(n => n.deps.length === 0 && !nodes.some(m => m.deps.includes(n.id))).length;
writeFileSync(join(HERE, "nodes.json"), JSON.stringify({ generatedFrom: idx.head || "", nodes, stats: { nodes: nodes.length, edges, avgDegree: +avgDeg, orphans } }, null, 2));

const e = (s) => process.stderr.write(s + "\n");
e(`[generate] ${nodes.length} nodes (${intentNodes.length} intention hubs) · ${edges} dep-edges · ${intentEdges} intention-edges · avg degree ${avgDeg} · ${orphans} orphans`);
const byStack = {}; for (const n of nodes) byStack[n.fields.stack] = (byStack[n.fields.stack] || 0) + 1;
e(`  by stack: ${Object.entries(byStack).map(([k, v]) => `${k} ${v}`).join(" · ")}`);
e(`  sample edges:`); for (const n of nodes.filter(n => n.deps.length).slice(0, 4)) e(`    ${n.path} → ${n.deps.slice(0, 3).join(", ")}`);
e(`  → nodes.json`);
