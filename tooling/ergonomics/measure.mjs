#!/usr/bin/env node
// Agent-ergonomics measurement: gather the DATA to decide what's worth refactoring
// for AI-agent efficiency. Two opposing costs:
//   call-waste  — files too small → many Reads to understand one concept
//   context-bloat — files too large → one Read swamps the model's window
// Joined with churn (read-frequency) — a cost paid often matters more.

import { execFileSync } from "node:child_process";
import { readFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: HERE }).toString().trim();
const sig = JSON.parse(readFileSync(join(ROOT, "tooling/file-importance/file-signals.json"), "utf8")).signals;

const tokens = (txt) => Math.ceil(txt.length / 4);
function defCount(f, txt) {
  let re;
  if (f.endsWith(".go")) re = /^func\s/gm;
  else if (/\.exs?$/.test(f)) re = /^\s*defp?\s/gm;
  else re = /^\s*export\s+(async\s+)?(function|const|class|interface|type)\s|^(async\s+)?function\s|^class\s/gm;
  return (txt.match(re) || []).length;
}

const code = sig.filter(s => s.kind === "code" || s.kind === "test");
const rows = code.map(s => {
  let txt = ""; try { txt = readFileSync(join(ROOT, s.path), "utf8"); } catch {}
  const t = tokens(txt), d = Math.max(1, defCount(s.path, txt));
  return { path: s.path, stack: s.stack, loc: s.loc, churn: s.churn, fanIn: s.fanIn, tokens: t, defs: d, tokPerDef: Math.round(t / d) };
});

const pct = (arr, p) => { const a = [...arr].sort((x, y) => x - y); return a[Math.min(a.length - 1, Math.floor(p / 100 * a.length))]; };
const T = rows.map(r => r.tokens), L = rows.map(r => r.loc);
const fmt = (n) => n.toLocaleString();

console.log(`=== ${rows.length} code/test files ===`);
console.log(`tokens/file  p10=${fmt(pct(T,10))}  p25=${fmt(pct(T,25))}  median=${fmt(pct(T,50))}  p75=${fmt(pct(T,75))}  p90=${fmt(pct(T,90))}  p95=${fmt(pct(T,95))}  p99=${fmt(pct(T,99))}  max=${fmt(Math.max(...T))}`);
console.log(`lines/file   p10=${pct(L,10)}  p25=${pct(L,25)}  median=${pct(L,50)}  p75=${pct(L,75)}  p90=${pct(L,90)}  p95=${pct(L,95)}  max=${Math.max(...L)}`);

// distribution buckets (tokens)
const buckets = [[0,250,"<250 (fragment?)"],[250,800,"250-800 (tight)"],[800,2500,"800-2.5k (ideal?)"],[2500,6000,"2.5k-6k (large)"],[6000,1e9,">6k (bloat?)"]];
console.log(`\ntoken-size distribution:`);
for (const [lo,hi,label] of buckets) { const n = rows.filter(r=>r.tokens>=lo&&r.tokens<hi).length; console.log(`  ${label.padEnd(20)} ${String(n).padStart(4)}  ${"█".repeat(Math.round(n/rows.length*60))}`); }

// BLOAT candidates: big files, weighted by churn (read often = waste paid often)
console.log(`\n=== BLOAT candidates (tokens × churn = read-amplified waste), top 15 ===`);
const bloat = rows.filter(r => r.tokens > 4000).map(r => ({ ...r, waste: (r.tokens - 4000) * (1 + r.churn) }))
  .sort((a, b) => b.waste - a.waste).slice(0, 15);
for (const r of bloat) console.log(`  ${fmt(r.tokens).padStart(7)}tok ${String(r.defs).padStart(3)}defs churn${String(r.churn).padStart(4)}  ${r.path}`);

// FRAGMENTATION: directories with many small files (call-waste to understand the concept)
console.log(`\n=== FRAGMENTATION candidates (dirs: many files, small median) ===`);
const byDir = {};
for (const r of rows) (byDir[dirname(r.path)] ||= []).push(r);
const frag = Object.entries(byDir).map(([dir, rs]) => ({ dir, n: rs.length, medTok: pct(rs.map(x=>x.tokens),50), tiny: rs.filter(x=>x.tokens<250).length }))
  .filter(g => g.n >= 6 && g.medTok < 600).sort((a, b) => (b.n*b.tiny) - (a.n*a.tiny)).slice(0, 12);
for (const g of frag) console.log(`  ${String(g.n).padStart(3)} files, median ${fmt(g.medTok)}tok, ${g.tiny} tiny  ${g.dir}`);

// def-density extremes (responsibilities crammed in)
console.log(`\n=== high responsibility-density (big files, many defs = split surface) ===`);
const dense = rows.filter(r => r.tokens > 3000 && r.defs > 20).sort((a,b)=>b.defs-a.defs).slice(0,10);
for (const r of dense) console.log(`  ${String(r.defs).padStart(3)}defs ${fmt(r.tokens).padStart(7)}tok  ${r.path}`);
