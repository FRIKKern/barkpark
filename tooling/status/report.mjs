#!/usr/bin/env node
// Status-Quo Report — the comprehensive overview. Joins EVERY pass into one
// navigable document: quality scorecard, improvement plan, a full per-file
// inventory (every file × every axis), the consistency norms, architecture &
// duplication findings, and the ergonomics distribution. Total coverage, every
// detail. Pure programmatic — assembles from the cached pass outputs.

import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, existsSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { UNTESTED_SCORE } from "../lib/thresholds.mjs";
import { readCoverageReport, coverageLabel, lastFullResearchLabel,
         readQualityReport, qualityLabel, findingsLabel, qualityOrEmpty } from "./measured.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: HERE }).toString().trim();
const rd = (p, d) => existsSync(join(ROOT, p)) ? JSON.parse(readFileSync(join(ROOT, p), "utf8")) : d;

const qRep = readQualityReport(ROOT);
const q = qualityOrEmpty(qRep);
const comb = rd("tooling/combined/combined-report.json", { rows: [], quad: {} });
const risk = rd("tooling/risk/risk-report.json", { files: {} }).files;
const ergRep = rd("tooling/ergonomics/ergonomics-report.json", { files: [], summary: {}, splitCandidates: [], thresholds: {} });
const erg = Object.fromEntries(ergRep.files.map(f => [f.path, f]));
const sig = Object.fromEntries(rd("tooling/file-importance/file-signals.json", { signals: [] }).signals.map(s => [s.path, s]));
const ledger = rd("tooling/research-coverage/research-ledger.json", { files: {}, meta: {} });
// Both reports are derived + gitignored; a numeric default rendered "coverage 0%"
// and "0/100" in the header of every clean-checkout report. See ./measured.mjs.
const cov = readCoverageReport(ROOT);
const crep = rd("tooling/consistency/consistency-report.json", { groups: [], layering: [], duplication: [], deadGoPackages: [] });
const vc = rd("tooling/consistency/verdict-cache.json", { groups: {}, layering: [], dup: [] });

const E = (s) => String(s ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

// ---- master per-file rows (every axis joined) ----
const rows = comb.rows.map(r => {
  const e = erg[r.path] || {}, rk = risk[r.path] || {}, s = sig[r.path] || {}, l = ledger.files[r.path] || {};
  return {
    priority: r.priority, reach: r.reach, path: r.path, stack: r.stack,
    kind: s.kind || "", role: r.role || l.role || "", description: l.description || "",
    tokens: e.tokens ?? "", sizeClass: e.sizeClass || "", defs: e.defs ?? "", loc: s.loc ?? "",
    churn: s.churn ?? "", fanIn: s.fanIn ?? "", seam: s.seam ? "🔗" : "",
    testScore: rk.testScore ?? "", hasTest: rk.hasTest ? "✓" : (rk.testScore === 0 ? "✗" : ""),
    defect: rk.defectDensity ?? "", consistency: r.status, detail: r.detail || "",
  };
}).sort((a, b) => b.priority - a.priority || b.reach - a.reach);

// ---- aggregates ----
const byStack = {}, byKind = {}, bySize = {};
for (const r of rows) { byStack[r.stack] = (byStack[r.stack] || 0) + 1; byKind[r.kind] = (byKind[r.kind] || 0) + 1; if (r.sizeClass) bySize[r.sizeClass] = (bySize[r.sizeClass] || 0) + 1; }
const pill = (o) => Object.entries(o).sort((a, b) => b[1] - a[1]).map(([k, v]) => `<span class=pill>${E(k) || "—"} ${v}</span>`).join(" ");

// ---- HTML pieces ----
const bar = (s) => { const c = s >= 85 ? "#16a34a" : s >= 70 ? "#65a30d" : s >= 55 ? "#ca8a04" : "#dc2626"; return `<div class=track><div class=fill style="width:${s}%;background:${c}"></div></div>`; };
const eff = ["", "low", "med", "high", "high+", "xhigh"];
const stC = (s) => ({ layering: "#fecaca", "layering?": "#fed7aa", drift: "#fed7aa", refactor: "#fde68a", "dup·extract": "#fde68a", dup: "#fef08a", "dup?": "#fef9c3", "off-pattern": "#fef9c3", intentional: "#dcfce7", "layering·ok": "#dcfce7", "dup·ok": "#dcfce7", clean: "#f1f5f9" }[s] || "#f1f5f9");
const sizeC = (s) => ({ bloat: "#ddd6fe", large: "#e9d5ff", fragment: "#fee2e2", ideal: "#dcfce7" }[s] || "");

const mrow = (r, i) => `<tr><td class=rk>${i + 1}</td><td class=n style="background:${r.priority > 0 ? "#fee2e2" : "#f8fafc"}">${r.priority || ""}</td>`
  + `<td class=n style="background:hsl(${Math.round((r.reach || 0) / 100 * 120)},70%,90%)">${r.reach}</td>`
  + `<td class=path title="${E(r.description)}">${E(r.path)}</td><td>${E(r.stack)}</td>`
  + `<td class=n>${r.tokens}</td><td style="background:${sizeC(r.sizeClass)}">${E(r.sizeClass)}</td><td class=n>${r.churn}</td><td class=n>${r.fanIn}${r.seam}</td>`
  + `<td class=n style="color:${r.testScore !== "" && r.testScore < UNTESTED_SCORE ? "#dc2626" : "#16a34a"}">${r.testScore}${r.hasTest}</td>`
  + `<td class=n style="color:${r.defect >= 0.4 ? "#b45309" : "#94a3b8"}">${r.defect}</td>`
  + `<td><span class=st style="background:${stC(r.consistency)}">${E(r.consistency)}</span></td>`
  + `<td class=role>${E(r.role)}</td></tr>`;

const findRow = (f, i) => `<tr><td class=rk>${i + 1}</td><td class=n>${f.impact}</td><td class=n>${f.reach}</td><td><span class=st style="background:${stC(f.kind === "bloat" ? "" : f.kind)}">${f.kind}</span></td><td>${f.dim}</td><td>${eff[f.effort]}</td><td class=path>${E(f.file)}</td><td class=role>${E(f.action)}${f.defect >= 0.4 ? ` <b style=color:#b45309>⚠${f.defect}</b>` : ""}</td></tr>`;

// canonical patterns (the norms) from the verdict cache
const norms = Object.entries(vc.groups || {}).map(([dir, g]) => ({ dir, pattern: g.data?.canonical_pattern, drift: (g.data?.verdicts || []).filter(v => v.verdict === "drift") }))
  .filter(g => g.pattern).sort((a, b) => a.dir.localeCompare(b.dir));
const layV = Object.fromEntries((vc.layering || []).map(l => [l.file, l]));
const dupV = vc.dup || [];

const html = `<!doctype html><meta charset=utf-8><title>Barkpark — Status Quo</title>
<style>
 body{font:13px/1.5 -apple-system,Segoe UI,Roboto,sans-serif;margin:0;color:#1a1a1a}
 header{background:#0f172a;color:#fff;padding:14px 20px;position:sticky;top:0;z-index:5;display:flex;align-items:center;gap:18px;flex-wrap:wrap}
 .grade{font-size:38px;font-weight:800;line-height:1} .meta{font-size:12px;opacity:.85}
 nav{margin-left:auto;display:flex;gap:14px}nav a{color:#cbd5e1;text-decoration:none;font-size:12px}nav a:hover{color:#fff}
 section{padding:8px 20px 22px}h2{font-size:15px;margin:18px 0 4px;border-bottom:2px solid #e2e8f0;padding-bottom:3px}
 .sub{color:#64748b;font-size:12px;margin-bottom:8px}
 .scorecard{display:grid;grid-template-columns:130px 230px 1fr;gap:3px 12px;align-items:center;max-width:900px}
 .track{height:12px;background:#e2e8f0;border-radius:6px;overflow:hidden}.fill{height:100%}
 .pill{display:inline-block;background:#f1f5f9;border:1px solid #e2e8f0;border-radius:10px;padding:1px 8px;font-size:11px;margin:2px}
 table{border-collapse:collapse;width:100%;margin-top:4px}th,td{padding:3px 7px;border-bottom:1px solid #eef2f7;text-align:left;vertical-align:top}
 th{background:#e2e8f0;position:sticky;top:52px;font-size:10px;text-transform:uppercase;cursor:pointer;z-index:2}
 td.n{text-align:right;font-variant-numeric:tabular-nums}td.rk{text-align:right;color:#cbd5e1}
 td.path{font-family:ui-monospace,monospace;font-size:11px}td.role{font-size:12px;color:#334155;max-width:380px}td.detail{font-size:11px;color:#475569}
 .st{font-size:10px;padding:0 5px;border-radius:7px;white-space:nowrap}
 input{padding:5px 8px;width:320px;border:1px solid #94a3b8;border-radius:6px}
 tr:hover{background:#fffbeb}.norm{margin:4px 0;padding:6px 10px;background:#f8fafc;border-left:3px solid #38bdf8;border-radius:4px}
 .norm b{font-family:ui-monospace,monospace;font-size:12px}.norm .p{color:#0369a1;font-size:12px}
</style>
<header>
 <div><div class=grade>${E(q.grade)}</div><div class=meta>${E(qualityLabel(qRep))}</div></div>
 <div><div style="font-size:16px;font-weight:700">Barkpark — Status Quo</div>
 <div class=meta>${rows.length} files · coverage ${E(coverageLabel(cov))} · ${E(findingsLabel(qRep))} · last full research ${E(lastFullResearchLabel(cov))}</div></div>
 <nav><a href=#overview>Overview</a><a href=#plan>Plan</a><a href=#files>Files</a><a href=#norms>Consistency</a><a href=#arch>Architecture</a><a href=#erg>Ergonomics</a></nav>
</header>

<section id=overview><h2>Scorecard</h2>
<div class=scorecard>${q.dimensions.map(d => `<div><b>${d.name}</b> ${d.score}</div><div>${bar(d.score)}</div><div class=meta style="color:#64748b">${E(d.note)} · w${Math.round(d.weight*100)}%</div>`).join("")}</div>
<h2>Inventory</h2>
<div class=sub>by stack: ${pill(byStack)}</div><div class=sub>by kind: ${pill(byKind)}</div>
<div class=sub>code size-class: ${pill(bySize)} <span class=meta>(ideal ${ergRep.thresholds?.idealCeil}tok ceiling · bloat &gt;${ergRep.thresholds?.bloat}tok)</span></div>
</section>

<section id=plan><h2>Improvement plan</h2><div class=sub>${E(findingsLabel(qRep))} · ~${q.effortUnits} effort units · impact = reach × severity × defect-amplifier</div>
<table><thead><tr><th>#</th><th>Impact</th><th>Reach</th><th>Kind</th><th>Dimension</th><th>Effort</th><th>Target</th><th>Action</th></tr></thead>
<tbody>${q.findings.map(findRow).join("")}</tbody></table></section>

<section id=files><h2>Every file — total coverage</h2>
<div class=sub>every file × every axis · sorted by priority. <input id=q placeholder="filter path / role / status…" oninput=flt()> <span id=cnt></span></div>
<table id=ft><thead><tr><th>#</th><th onclick="sb(1,1)">Pri</th><th onclick="sb(2,1)">Reach</th><th onclick="sb(3,0)">Path</th><th>Stack</th><th onclick="sb(5,1)">Tok</th><th>Size</th><th onclick="sb(7,1)">Churn</th><th onclick="sb(8,1)">FanIn</th><th onclick="sb(9,1)">Test</th><th onclick="sb(10,1)">Defect</th><th>Consistency</th><th>Role</th></tr></thead>
<tbody>${rows.map(mrow).join("")}</tbody></table></section>

<section id=norms><h2>Consistency — the canonical patterns (${norms.length} groups judged)</h2>
<div class=sub>the norm a new file in each directory should follow. Only ${q.dimensions.find(d=>d.name==="Consistency")?.note || ""}</div>
${norms.map(n => `<div class=norm><b>${E(n.dir)}/</b><div class=p>${E(n.pattern)}</div>${n.drift.length ? `<div style="color:#b45309;font-size:12px">⚠ drift: ${n.drift.map(d => E(d.file.split("/").pop()) + " — " + E(d.recommendation)).join("; ")}</div>` : ""}</div>`).join("")}
</section>

<section id=arch><h2>Architecture — layering &amp; duplication (verified)</h2>
<div class=sub>Compile-DAG acyclic. Verified layering back-edges:</div>
<table><tbody>${(vc.layering || []).map(l => `<tr><td><span class=st style="background:${l.verdict === "violation" ? "#fecaca" : "#dcfce7"}">${l.verdict}</span></td><td class=path>${E(l.file)}</td><td class=detail>${E(l.reason)}${l.fix ? " — fix: " + E(l.fix) : ""}</td></tr>`).join("") || "<tr><td>none</td></tr>"}</tbody></table>
<div class=sub style="margin-top:10px">Near-duplication (verified):</div>
<table><tbody>${dupV.map(d => `<tr><td><span class=st style="background:${d.verdict === "extract" ? "#fde68a" : "#dcfce7"}">${d.verdict}</span></td><td class=path>${E(d.a)}</td><td class=path>${E(d.b)}</td><td class=detail>${E(d.reason)}</td></tr>`).join("") || "<tr><td>none</td></tr>"}</tbody></table>
<div class=sub style="margin-top:10px">Dead Go packages: ${crep.deadGoPackages?.length ? crep.deadGoPackages.map(E).join(", ") : "none"}</div>
</section>

<section id=erg><h2>Ergonomics — agent-cost / refactor candidates</h2>
<div class=sub>split candidates: bloat × churn × separability (read on every change)</div>
<table><thead><tr><th>worth</th><th>tokens</th><th>defs</th><th>churn</th><th>Path</th></tr></thead>
<tbody>${(ergRep.splitCandidates || []).slice(0, 25).map(r => `<tr><td class=n>${r.refactorWorth.toLocaleString()}</td><td class=n>${r.tokens.toLocaleString()}</td><td class=n>${r.defs}</td><td class=n>${r.churn}</td><td class=path>${E(r.path)}</td></tr>`).join("")}</tbody></table>
</section>

<script>
 const ft=document.getElementById('ft'),tb=ft.tBodies[0],all=[...tb.rows];document.getElementById('cnt').textContent=all.length+' files';
 function flt(){const v=document.getElementById('q').value.toLowerCase();let n=0;for(const r of all){const ok=r.textContent.toLowerCase().includes(v);r.style.display=ok?'':'none';if(ok)n++}document.getElementById('cnt').textContent=n+' shown'}
 let dir=-1;function sb(ci,num){dir=-dir;all.sort((a,b)=>{let x=a.cells[ci].innerText,y=b.cells[ci].innerText;if(num){x=parseFloat(x.replace(/[^0-9.\\-]/g,''))||0;y=parseFloat(y.replace(/[^0-9.\\-]/g,''))||0;return (x-y)*dir}return x.localeCompare(y)*dir});all.forEach((r,i)=>{r.cells[0].textContent=i+1;tb.appendChild(r)})}
</script>`;
writeFileSync(join(HERE, "status-report.html"), html);
process.stderr.write(`[report] comprehensive status-report.html — ${rows.length} files, ${findingsLabel(qRep)}, ${norms.length} norms\n`);
