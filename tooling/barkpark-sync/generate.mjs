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
// The evidence tier merge.mjs computes per file. Until it emitted JSON this was
// spreadsheet-only, so importance below fell through to the deterministic prior
// while the published paper still called the number "importance". Read it here,
// stamp the basis explicitly, and push.mjs refuses anything it cannot label.
const impChart = Object.fromEntries(rd("tooling/file-importance/importance-chart.json", { rows: [] }).rows.map(r => [r.path, r]));
const comb = Object.fromEntries(rd("tooling/combined/combined-report.json", { rows: [] }).rows.map(r => [r.path, r]));
const risk = rd("tooling/risk/risk-report.json", { files: {} }).files;
const erg = Object.fromEntries(rd("tooling/ergonomics/ergonomics-report.json", { files: [] }).files.map(f => [f.path, f]));
const ledger = rd("tooling/research-coverage/research-ledger.json", { files: {} }).files;
const idx = rd("tooling/blast-radius/index.json", { go: {}, js: {}, elixir: null });
const useful = rd("tooling/usefulness/usefulness-report.json", { files: {} }).files;
const intents = rd("tooling/intentions/intentions-report.json", { taxonomy: [], files: {}, hubs: {} });
const intId = (id) => "intent-" + id;
// co-change (3rd relationship edge kind) — additive, gated on the report existing.
// partners: path → [{path,support,confidence}]; files: path → { accidentalCoupling, ... }
const cochange = rd("tooling/cochange/cochange-report.json", { partners: {}, files: {} });

// ---- per-file git history (one pass over the log) ----
const git = (a) => execFileSync("git", a, { cwd: ROOT, encoding: "utf8", maxBuffer: 512 * 1024 * 1024 });
const history = {};
{
  let cur = null;
  for (const line of git(["log", "--no-merges", "--date=short", "--pretty=format:\x01%h\x1f%ad\x1f%an\x1f%s", "--name-only"]).split("\n")) {
    if (line.startsWith("\x01")) { const [hash, date, author, subject] = line.slice(1).split("\x1f"); cur = { hash, date, author, subject }; }
    else if (line.trim() && cur) (history[line.trim()] ||= []).push(cur);
  }
}
const HIST_CAP = 25;
function gitMeta(p) {
  const h = history[p] || [];
  const authors = [...new Set(h.map(c => c.author))];
  return { commits: h.slice(0, HIST_CAP), commitCount: h.length, firstDate: h.length ? h[h.length - 1].date : "", lastDate: h.length ? h[0].date : "", authors };
}

// universe = code files (the graph nodes)
const universe = Object.values(sig).filter(s => s.kind === "code").map(s => s.path);
const inUniverse = new Set(universe);
const slug = (p) => p.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
const idOf = (p) => slug(p);

const MAX_DEPS = 10; // keep the graph airy (avg degree ~7 is the Obsidian-like sweet spot)

// ---- file-level dependency resolvers (per stack) ----
// Elixir: prefer the REAL module→module graph from `mix xref` (blast-radius index,
// keyed file→[files]); fall back to the alias/import/use regex scan when xref is
// absent (no Elixir toolchain / --skip-elixir). The xref graph is ~2x denser and
// makes reach/dependentCount exact for the biggest stack.
const exForward = idx.elixir?.forward || null;
const exModule = {};
for (const f of universe) if (/\.exs?$/.test(f)) { const m = read(f).match(/defmodule\s+([\w.]+)/); if (m) exModule[m[1]] = f; }
function elixirDeps(f, txt) {
  if (exForward && exForward[f]) {
    return new Set(exForward[f].filter(t => t !== f && inUniverse.has(t)));
  }
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
  const m = impChart[p] || null;
  const body = read(p);
  // BASIS, stated rather than implied. `blended` means merge.mjs actually mixed
  // an agent criticality into the prior (45/55) and m.score is that mix;
  // `prior` means the number is the deterministic priorScore and nothing else,
  // and push.mjs will render it under the name `prior`. combined-report.json has
  // no `importance` key at all, which is how every published number became a
  // prior wearing the word "importance" — so it is no longer consulted for it.
  const blended = !!(m && m.agentCrit !== "" && m.agentCrit != null);
  const importance = blended ? m.score : (s.prior ?? 0);
  return {
    id: idOf(p), path: p, title: p,
    fields: {
      path: p, basename: basename(p), dir: dirname(p), ext: extname(p).slice(1),
      stack: s.stack || "", importance, importanceBasis: blended ? "blended" : "prior", priority: c.priority ?? 0,
      provenance: {
        tier: m?.tier ?? (s.prior != null ? "auto" : ""),
        prior: m?.prior ?? s.prior ?? null,
        agentCrit: m?.agentCrit ?? "",
        votes: m?.votes ?? 0, agreement: m?.agreement ?? "", contested: !!m?.contested,
        confidence: m?.confidence ?? "",
        // role/description/whatBreaks come off the research ledger, which stamps
        // its own tier per file ("agent" when an agent wrote it, "auto" when a
        // parser did). Prose and score are judged separately because they are.
        proseTier: l.tier || (c.role ? "auto" : ""),
      },
      role: c.role || l.role || "", description: l.description || "",
      tokens: e.tokens ?? 0, loc: s.loc ?? 0, sizeClass: e.sizeClass || "", defs: e.defs ?? 0,
      churn: s.churn ?? 0, fanIn: s.fanIn ?? 0, seam: !!s.seam,
      testScore: rk.testScore ?? null, hasTest: !!rk.hasTest, defectDensity: rk.defectDensity ?? 0,
      // combine.mjs suffixes an UNVERIFIED issue candidate with "?" (layering?,
      // dup?). That suffix was published verbatim and read as punctuation.
      consistency: c.status || "clean", consistencyUnverified: /\?$/.test(c.status || ""),
      severity: c.severity ?? 0,
      whatBreaks: l.whatBreaks || "",
      // reach = pure programmatic normalized transitive-dependent count (formerly "usefulness").
      // `why` is the agent prose kept as a DESCRIPTION, not a score.
      reach: useful[p]?.reachScore ?? useful[p]?.usefulness ?? null, why: useful[p]?.why || useful[p]?.why_useful || "",
      // ownership = bus-factor (from risk.mjs)
      primaryAuthorShare: rk.primaryAuthorShare ?? null, authorCount: rk.authorCount ?? (gitMeta(p).authors.length || 0),
      intentions: intents.files[p] || [],
      // co-change: temporal-coupling partners + the accidental-coupling smell flag
      accidentalCoupling: !!cochange.files?.[p]?.accidentalCoupling,
      cochangePartners: (cochange.partners?.[p] || []).map(q => q.path),
      git: gitMeta(p),
    },
    content: body.length > CONTENT_CAP ? body.slice(0, CONTENT_CAP) + `\n\n… (${body.length - CONTENT_CAP} more chars truncated)` : body,
    truncated: body.length > CONTENT_CAP,
    deps: depsFor(p).map(idOf),       // dependency edges (file → file)
    depPaths: depsFor(p),
    intentRefs: (intents.files[p] || []).map(intId),  // intention edges (file → hub)
    // co-change edges (file ↔ file) — 3rd relationship kind, only to files in-universe
    cochangePaths: (cochange.partners?.[p] || []).map(q => q.path).filter(t => inUniverse.has(t)),
    cochangeRefs: (cochange.partners?.[p] || []).map(q => q.path).filter(t => inUniverse.has(t)).map(idOf),
  };
});

// ---- dependents (inverse of deps): the accurate file-level "depended on by" ----
const dependentsMap = {};
for (const n of nodes) for (const d of n.deps) (dependentsMap[d] ||= []).push(n.id);
const idToPath = Object.fromEntries(nodes.map(n => [n.id, n.path]));
for (const n of nodes) {
  const deps = dependentsMap[n.id] || [];
  n.fields.dependents = deps.map(id => idToPath[id]).filter(Boolean).sort();
  n.fields.dependentCount = deps.length;
}

// ---- intention hub nodes (objectives that cluster cross-cutting files) ----
const intentNodes = (intents.taxonomy || []).filter(t => (intents.hubs[t.id] || []).length).map(t => ({
  id: intId(t.id), path: intId(t.id), title: t.title, kind: "intention",
  // A hub's title and description are an agent taxonomy, so the hub declares a
  // register too — `taxonomy` — rather than riding along unmarked.
  fields: { kind: "intention", scale: t.scale, title: t.title, description: t.description, members: (intents.hubs[t.id] || []).length, provenance: { proseTier: "taxonomy" } },
  content: `${t.title}\n\n${t.description}\n\nScale: ${t.scale}\n\nFiles advancing this intention (${(intents.hubs[t.id] || []).length}):\n` + (intents.hubs[t.id] || []).map(p => "  • " + p).join("\n"),
  deps: [], depPaths: [], intentRefs: [],
}));
nodes.push(...intentNodes);

const edges = nodes.reduce((a, n) => a + n.deps.length, 0);
const intentEdges = nodes.reduce((a, n) => a + (n.intentRefs?.length || 0), 0);
const cochangeEdges = nodes.reduce((a, n) => a + (n.cochangeRefs?.length || 0), 0);
const avgDeg = (edges / nodes.length).toFixed(1);
const orphans = nodes.filter(n => n.deps.length === 0 && !nodes.some(m => m.deps.includes(n.id))).length;
writeFileSync(join(HERE, "nodes.json"), JSON.stringify({ generatedFrom: idx.head || "", nodes, stats: { nodes: nodes.length, edges, avgDegree: +avgDeg, orphans } }, null, 2));

const e = (s) => process.stderr.write(s + "\n");
e(`[generate] ${nodes.length} nodes (${intentNodes.length} intention hubs) · ${edges} dep-edges · ${intentEdges} intention-edges · ${cochangeEdges} cochange-edges · avg degree ${avgDeg} · ${orphans} orphans`);
const byStack = {}; for (const n of nodes) byStack[n.fields.stack] = (byStack[n.fields.stack] || 0) + 1;
e(`  by stack: ${Object.entries(byStack).map(([k, v]) => `${k} ${v}`).join(" · ")}`);
e(`  sample edges:`); for (const n of nodes.filter(n => n.deps.length).slice(0, 4)) e(`    ${n.path} → ${n.deps.slice(0, 3).join(", ")}`);
e(`  → nodes.json`);
