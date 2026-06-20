#!/usr/bin/env node
// REACH axis (formerly "usefulness"). v2 Phase 0: reach is a PURE PROGRAMMATIC
// value — the normalized (0-100) transitive-dependent count. No agent pass is
// needed to produce the number; it is computed from the dependency graph.
//
// The agent "why it's useful" prose is KEPT as a `why` DESCRIPTION (graded
// "reusability") — it explains why a file is reusable; it is NOT a score.
//
//   usefulness.mjs batches  → per-file agent tasks (reach prior seeded)   [free]
//   usefulness.mjs merge     → usefulness-report.json (reach + why)        [free]
//
// usefulness-report.json keeps its filename for back-compat; each entry now
// carries: reach (raw transitive count), reachScore (0-100 surfaced value),
// why (description text), plus legacy `usefulness`/`why_useful` mirrors.

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
  // The agent prose stays only as a DESCRIPTION (the `why`); the score is computed.
  const out = {};
  for (const f of (existsSync(RDIR) ? readdirSync(RDIR) : []).filter(f => f.endsWith(".json"))) {
    try { for (const r of JSON.parse(readFileSync(join(RDIR, f), "utf8"))) if (r?.path) out[r.path] = { why_useful: r.why_useful }; } catch {}
  }
  // reach = pure programmatic: normalize the transitive-dependent count to 0-100.
  // Distribution is heavily skewed, so log-scale against the corpus max.
  const reachByPath = {}; let maxReach = 0;
  for (const n of nodes) { const r = reach(n.id); reachByPath[n.path] = r; if (r > maxReach) maxReach = r; }
  const denom = Math.log2(1 + maxReach) || 1;
  const reachScore = (r) => Math.round((Math.log2(1 + r) / denom) * 100);
  const report = { at: new Date().toISOString(), files: {} };
  for (const n of nodes) {
    const a = out[n.path]; const r = reachByPath[n.path]; const score = reachScore(r);
    const why = a?.why_useful || "";
    report.files[n.path] = {
      reach: r, reachScore: score, why,
      // legacy mirrors so older readers keep working; treat the score as reach.
      usefulness: score, why_useful: why,
    };
  }
  writeFileSync(join(HERE, "usefulness-report.json"), JSON.stringify(report, null, 2));
  const n = Object.values(report.files).filter(x => x.why).length;
  process.stderr.write(`[reach] computed reach for ${nodes.length} files (normalized 0-100) · ${n} carry a 'why' description → usefulness-report.json\n`);
}
