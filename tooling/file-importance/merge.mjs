#!/usr/bin/env node
// Merge agent results + programmatic signals into the final importance chart.
// PURE programmatic (zero tokens). final = blend(deterministic prior, agent
// criticality) for code/test files; prior alone for data/asset/doc files.
// Emits importance-chart.csv + importance-chart.json + importance-chart.html.

import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, readdirSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { collectVotes, numericConsensus } from "../lib/consensus.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: HERE }).toString().trim();

const sig = JSON.parse(readFileSync(join(HERE, "file-signals.json"), "utf8")).signals;
const RDIR = join(HERE, "results");

// ---- ingest agent results — MULTI-VOTE (cqv3-p2) ----
// collectVotes returns path -> [vote, …]: flat results/ = 1 vote; results/vote-*/
// subdirs = N independent votes. criticality is consensus'd; a panel that
// disagrees is flagged `contested`, not silently averaged into a confident score.
const votesByPath = collectVotes(RDIR, "path");
const seenBatches = new Set((existsSync(RDIR) ? readdirSync(RDIR) : []).filter(f => f.endsWith(".json")));
const badBatches = [];
// representative metadata (role/description/whatBreaks): take the highest-confidence
// vote, falling back to the first — prose doesn't vote, but the most-confident
// agent's wording is the best single label.
const confRank = { high: 3, medium: 2, low: 1, "": 0 };
const repOf = (votes) => [...votes].sort((a, b) => (confRank[b?.confidence] ?? 0) - (confRank[a?.confidence] ?? 0))[0] || {};

// ---- blend ----
const clamp = (n) => Math.max(1, Math.min(100, Math.round(n)));
const rows = sig.map((s) => {
  const votes = votesByPath[s.path] || [];
  const a = repOf(votes);
  const scored = (s.kind === "code" || s.kind === "test");
  const con = numericConsensus(votes.map((v) => v?.criticality));
  const crit = con.value;
  const finalScore = (scored && crit != null) ? clamp(0.45 * s.prior + 0.55 * crit) : s.prior;
  return {
    score: finalScore, path: s.path, stack: s.stack, kind: s.kind,
    fanIn: s.fanIn, churn: s.churn, loc: s.loc, seam: s.seam, entrypoint: s.entrypoint,
    role: a?.role || "",
    description: a?.description || s.autoDescription,
    whatBreaks: a?.what_breaks_if_wrong || a?.whatBreaks || "",
    confidence: a?.confidence ?? "",
    prior: s.prior, agentCrit: crit ?? "",
    votes: con.votes, agreement: con.agreement ?? "", contested: con.contested,
    tier: (scored ? (crit != null ? (con.contested ? "contested" : "agent") : "MISSING") : "auto"),
  };
}).sort((x, y) => y.score - x.score);

// ---- CSV ----
const esc = (v) => `"${String(v).replace(/"/g, '""').replace(/\n/g, " ")}"`;
const cols = ["score","path","stack","kind","fanIn","churn","loc","seam","entrypoint","tier","prior","agentCrit","votes","agreement","contested","confidence","role","description","whatBreaks"];
writeFileSync(join(HERE, "importance-chart.csv"),
  [cols.join(","), ...rows.map(r => cols.map(c => esc(r[c])).join(","))].join("\n"));

// ---- JSON ----
// Same rows, same scoring — the blend above is untouched. The chart used to
// exist only as a spreadsheet and a web page, so the ONE consumer that needed
// the evidence tier (tooling/barkpark-sync, which publishes these numbers as
// durable papers) had nothing machine-readable to read and fell back to the
// deterministic prior while still calling it "importance". This file is that
// fallback's replacement; it adds no judgment, it only stops discarding one.
writeFileSync(join(HERE, "importance-chart.json"), JSON.stringify({
  blend: { prior: 0.45, agentCrit: 0.55, appliesTo: ["code", "test"], note: "kind outside appliesTo scores prior alone (tier 'auto')" },
  rows,
}, null, 2));

// ---- stats ----
const missing = rows.filter(r => r.tier === "MISSING");
const byStack = {};
for (const r of rows) { (byStack[r.stack] ||= { n: 0, sum: 0 }); byStack[r.stack].n++; byStack[r.stack].sum += r.score; }
const stackRows = Object.entries(byStack).map(([k, v]) => `${k}: ${v.n} files, avg ${Math.round(v.sum / v.n)}`).join(" · ");

// ---- HTML ----
const color = (s) => { const h = Math.round((s / 100) * 120); return `hsl(${h},70%,88%)`; }; // red→green
const cell = (v) => `<td>${String(v ?? "").replace(/&/g,"&amp;").replace(/</g,"&lt;")}</td>`;
const tr = (r, i) => `<tr data-s="${r.score}"><td class="rank">${i + 1}</td>`
  + `<td class="score" style="background:${color(r.score)}"><b>${r.score}</b></td>`
  + `<td class="path">${r.path}</td>`
  + `<td>${r.stack}</td><td>${r.kind}</td><td class="n">${r.fanIn}</td><td class="n">${r.churn}</td><td class="n">${r.loc}</td>`
  + `<td>${r.seam ? "🔗" : ""}${r.entrypoint ? "▶" : ""}</td>`
  + cell(r.role) + cell(r.description) + cell(r.whatBreaks)
  + `<td class="tier ${r.tier}">${r.tier}</td></tr>`;

const html = `<!doctype html><meta charset="utf-8"><title>Barkpark — File Importance Chart</title>
<style>
 body{font:13px/1.45 -apple-system,Segoe UI,Roboto,sans-serif;margin:0;color:#1a1a1a}
 header{padding:16px 20px;background:#0f172a;color:#fff;position:sticky;top:0;z-index:2}
 header h1{margin:0 0 4px;font-size:18px} header .meta{font-size:12px;opacity:.85}
 .controls{padding:8px 20px;background:#f1f5f9;position:sticky;top:62px;z-index:2;border-bottom:1px solid #cbd5e1}
 input{padding:5px 8px;width:280px;border:1px solid #94a3b8;border-radius:6px}
 table{border-collapse:collapse;width:100%} th,td{padding:5px 8px;border-bottom:1px solid #e2e8f0;vertical-align:top;text-align:left}
 th{background:#e2e8f0;position:sticky;top:104px;cursor:pointer;font-size:11px;text-transform:uppercase;letter-spacing:.04em}
 td.score{text-align:center;font-size:14px;width:42px} td.rank{color:#94a3b8;text-align:right} td.n{text-align:right;font-variant-numeric:tabular-nums}
 td.path{font-family:ui-monospace,monospace;font-size:12px;max-width:340px;word-break:break-all}
 td:nth-child(11),td:nth-child(12){max-width:340px} .tier.agent{color:#16a34a} .tier.auto{color:#64748b} .tier.MISSING{color:#dc2626;font-weight:700}
 tr:hover{background:#fffbeb}
</style>
<header>
 <h1>Barkpark — File Importance Chart</h1>
 <div class="meta">${rows.length} files · score = blend(deterministic prior 45%, agent criticality 55%) · ${stackRows}${missing.length ? ` · <b style="color:#fca5a5">${missing.length} MISSING agent verdicts</b>` : ""}</div>
</header>
<div class="controls"><input id="q" placeholder="filter by path / role / description…" oninput="filter()"> <span id="count"></span></div>
<table id="t"><thead><tr>
 <th>#</th><th onclick="sortBy('score')">Score</th><th onclick="sortBy('path')">Path</th><th>Stack</th><th>Kind</th>
 <th onclick="sortBy('fanIn')">FanIn</th><th onclick="sortBy('churn')">Churn</th><th onclick="sortBy('loc')">LOC</th><th>Flags</th>
 <th>Role</th><th>Description</th><th>What breaks if wrong</th><th>Tier</th>
</tr></thead><tbody>
${rows.map(tr).join("\n")}
</tbody></table>
<script>
 const tb=document.querySelector('#t tbody'); const all=[...tb.rows];
 document.getElementById('count').textContent=all.length+' shown';
 function filter(){const q=document.getElementById('q').value.toLowerCase();let n=0;for(const r of all){const ok=r.textContent.toLowerCase().includes(q);r.style.display=ok?'':'none';if(ok)n++;}document.getElementById('count').textContent=n+' shown';}
 let dir=-1;
 function sortBy(k){const idx={score:1,path:2,fanIn:5,churn:6,loc:7}[k];dir=-dir;const num=k!=='path';
  all.sort((a,b)=>{let x=a.cells[idx].innerText,y=b.cells[idx].innerText;if(num){x=+x.replace(/[^0-9.-]/g,'')||0;y=+y.replace(/[^0-9.-]/g,'')||0;return (x-y)*dir;}return x.localeCompare(y)*dir;});
  all.forEach((r,i)=>{r.cells[0].textContent=i+1;tb.appendChild(r);});}
</script>`;
writeFileSync(join(HERE, "importance-chart.html"), html);

const multiVoted = rows.filter(r => r.votes > 1);
const contested = rows.filter(r => r.contested);
console.error(`[merge] ${rows.length} files → importance-chart.{csv,json,html}`);
console.error(`  agent-scored: ${rows.filter(r=>r.tier==="agent"||r.tier==="contested").length} · auto: ${rows.filter(r=>r.tier==="auto").length} · MISSING: ${missing.length}`);
if (multiVoted.length) {
  console.error(`  multi-vote: ${multiVoted.length} file(s) panel-judged · ${contested.length} CONTESTED (panel disagreed — review before trusting)`);
  for (const r of contested.slice(0, 8)) console.error(`    ⚖ ${r.path}  crit ${r.agentCrit} · ${r.votes} votes · agreement ${r.agreement}`);
} else {
  console.error(`  single-vote (no results/vote-*/ subdirs) — dispatch N passes for multi-vote consensus (cqv3-p2)`);
}
console.error(`  result batches ingested: ${seenBatches.size}/109${badBatches.length?` · ${badBatches.length} malformed`:""}`);
if (badBatches.length) badBatches.forEach(b => console.error(`    ✗ ${b}`));
if (missing.length) console.error(`  re-run batches containing: ${missing.slice(0,8).map(m=>m.path).join(", ")}${missing.length>8?` …(+${missing.length-8})`:""}`);
console.error(`  TOP 15:`);
for (const r of rows.slice(0,15)) console.error(`    ${String(r.score).padStart(3)} ${r.path}`);
