#!/usr/bin/env node
// Usefulness axis — distinct from importance. Importance = risk if wrong;
// USEFULNESS = value/leverage delivered (how reusable + relied-upon a file is,
// what capability it gives the system). Programmatic prior = reach (transitive
// dependents) × leverage (entrypoint/seam/public) × reliability (tested). Agents
// score usefulness + write a concrete "why it's useful" per file.
//
//   usefulness.mjs batches  → per-file agent tasks (prior seeded)   [free]
//   usefulness.mjs merge     → usefulness-report.json from results   [free]

import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, existsSync, readdirSync, mkdirSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: HERE }).toString().trim();
const cmd = process.argv[2] || "batches";
const BATCH = 10;

const nodes = JSON.parse(readFileSync(join(ROOT, "tooling/barkpark-sync/nodes.json"), "utf8")).nodes;
const risk = (existsSync(join(ROOT, "tooling/risk/risk-report.json")) ? JSON.parse(readFileSync(join(ROOT, "tooling/risk/risk-report.json"), "utf8")).files : {});

// reverse the file-level dependency graph → dependents
const byId = Object.fromEntries(nodes.map(n => [n.id, n]));
const dependents = {}; for (const n of nodes) for (const d of n.deps) (dependents[d] ||= []).push(n.id);
// transitive reach = how many files (transitively) depend on this one
function reach(id) {
  const seen = new Set(); const q = [...(dependents[id] || [])];
  while (q.length) { const x = q.shift(); if (seen.has(x)) continue; seen.add(x); for (const up of dependents[x] || []) if (!seen.has(up)) q.push(up); }
  return seen.size;
}

function prior(n) {
  const r = reach(n.id), f = n.fields, rk = risk[n.path] || {};
  let v = Math.min(45, Math.log2(1 + r) * 12);            // reach — the core usefulness signal
  if (f.fanIn >= 3) v += 8;                                // directly depended-upon
  if (f.entrypoint) v += 12;                               // an entry surface
  if (f.seam) v += 10;                                     // public wire contract = broadly leveraged
  if ((rk.testScore ?? 0) >= 50) v += 8;                   // reliable → safe to rely on
  if (f.stack === "elixir" && /\/(content|plugin|portable_doc|search|sheets)\b/.test(n.path)) v += 6;
  return { reach: r, prior: Math.max(1, Math.min(100, Math.round(v))) };
}

if (cmd === "batches") {
  const BDIR = join(HERE, "batches"); rmSync(BDIR, { recursive: true, force: true }); mkdirSync(BDIR, { recursive: true });
  if (!existsSync(join(HERE, "results"))) mkdirSync(join(HERE, "results"));
  const rows = nodes.map(n => { const p = prior(n); return { path: n.path, id: n.id, stack: n.fields.stack, role: n.fields.role, importance: n.fields.importance, fanIn: n.fields.fanIn, reach: p.reach, usefulnessPrior: p.prior, description: n.fields.description }; });
  const pad = (i) => String(i).padStart(3, "0");
  let b = 0; for (let i = 0; i < rows.length; i += BATCH) { writeFileSync(join(BDIR, `batch-${pad(b)}.json`), JSON.stringify({ batch: b, files: rows.slice(i, i + BATCH) }, null, 2)); b++; }
  writeFileSync(join(HERE, "batch-count.txt"), String(b));
  process.stderr.write(`[usefulness] ${rows.length} files → ${b} batches (prior = reach × leverage × reliability)\n`);
  const top = [...rows].sort((a, x) => x.usefulnessPrior - a.usefulnessPrior).slice(0, 8);
  for (const r of top) process.stderr.write(`  prior ${String(r.usefulnessPrior).padStart(3)} reach ${String(r.reach).padStart(3)}  ${r.path}\n`);
}

if (cmd === "merge") {
  const RDIR = join(HERE, "results");
  const out = {};
  for (const f of (existsSync(RDIR) ? readdirSync(RDIR) : []).filter(f => f.endsWith(".json"))) {
    try { for (const r of JSON.parse(readFileSync(join(RDIR, f), "utf8"))) if (r?.path) out[r.path] = { usefulness: r.usefulness, why_useful: r.why_useful }; } catch {}
  }
  // blend agent usefulness with the reach prior (anchor)
  const report = { at: new Date().toISOString(), files: {} };
  for (const n of nodes) { const a = out[n.path]; const p = prior(n); report.files[n.path] = { usefulness: a ? Math.round(0.4 * p.prior + 0.6 * (+a.usefulness || p.prior)) : p.prior, why_useful: a?.why_useful || "", reach: p.reach, prior: p.prior }; }
  writeFileSync(join(HERE, "usefulness-report.json"), JSON.stringify(report, null, 2));
  const n = Object.values(report.files).filter(x => x.why_useful).length;
  process.stderr.write(`[usefulness] merged ${n}/${nodes.length} with agent 'why useful' → usefulness-report.json\n`);
}
