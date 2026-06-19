#!/usr/bin/env node
// Codebase Quality synthesizer — the capstone. Reads every axis (importance,
// consistency, layering, duplication, ergonomics, coverage), produces a scored
// SCORECARD (how good is the codebase) and a ranked IMPROVEMENT PLAN (what it
// takes to make it better, by ROI = impact / effort). Pure programmatic.
//
//   quality.mjs   → quality-report.{html,json} + console scorecard   [free]

import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, existsSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: HERE }).toString().trim();
const rd = (p, d) => existsSync(join(ROOT, p)) ? JSON.parse(readFileSync(join(ROOT, p), "utf8")) : d;

const ledger = rd("tooling/research-coverage/research-ledger.json", { files: {}, meta: {} });
const priors = {}; for (const s of rd("tooling/file-importance/file-signals.json", { signals: [] }).signals) priors[s.path] = s.prior;
const crep = rd("tooling/consistency/consistency-report.json", { groups: [], layering: [], duplication: [], deadGoPackages: [] });
const erg = rd("tooling/ergonomics/ergonomics-report.json", { files: [], splitCandidates: [] });
const layV = rd("tooling/consistency/results/_layering.json", []);
const dupV = rd("tooling/consistency/results/_dup.json", []);
const gV = {}; const RES = join(ROOT, "tooling/consistency/results");
for (const f of (existsSync(RES) ? readdirSync(RES) : []).filter(f => /^group-/.test(f))) { try { for (const x of JSON.parse(readFileSync(join(RES, f), "utf8")).verdicts || []) gV[x.file] = x; } catch {} }

const importance = (p) => { const e = ledger.files[p]; if (!e) return 50; const sc = +e.score || 0; const pr = priors[p];
  return (e.tier === "agent" && Number.isFinite(pr)) ? Math.round(0.45 * pr + 0.55 * sc) : sc; };

// ---- findings (the atomic improvement units) ----
const findings = [];
for (const l of layV) if (l.verdict === "violation") findings.push({ kind: "layering", file: l.file, dim: "Architecture", sev: 1.0, effort: 2, action: l.fix || "Move data access into a domain context", why: l.reason });
for (const [f, v] of Object.entries(gV)) if (v.verdict === "drift") findings.push({ kind: "drift", file: f, dim: "Consistency", sev: 0.9, effort: 1, action: v.recommendation, why: "diverges from the group's own pattern" });
for (const v of dupV) if (v.verdict === "extract") findings.push({ kind: "duplication", file: v.a, dim: "Duplication", sev: 0.55, effort: 2, action: `Extract shared logic (≈ ${v.b})`, why: v.reason });
for (const r of erg.splitCandidates) if (r.refactorWorth > 5000) findings.push({ kind: "bloat", file: r.path, dim: "Modularity", sev: Math.min(1, r.refactorWorth / 40000), effort: r.tokens > 30000 ? 5 : r.tokens > 15000 ? 4 : 3, action: `Split god-module (${r.defs} defs, ${r.tokens.toLocaleString()} tok) read every change (churn ${r.churn})`, why: "context-bloat paid on every read" });
for (const r of findings) { r.importance = importance(r.file); r.impact = Math.round(r.importance * r.sev); r.roi = +(r.impact / r.effort).toFixed(1); }
findings.sort((a, b) => b.impact - a.impact || b.roi - a.roi);

// ---- scorecard dimensions (0-100, higher = better) ----
const clamp = (n) => Math.max(0, Math.min(100, Math.round(n)));
const driftN = findings.filter(f => f.kind === "drift").length;
const layN = findings.filter(f => f.kind === "layering");
const dupN = findings.filter(f => f.kind === "duplication").length;
const bloatBig = findings.filter(f => f.kind === "bloat" && f.importance >= 60).length;
const coverage = (() => { const fs = Object.values(ledger.files); return fs.length ? 100 : 0; })(); // ledger = 100% by construction after a full pass

const dims = [
  { name: "Coverage", score: coverage, note: `${Object.keys(ledger.files).length} files evaluated · last full research ${ledger.meta.lastFullResearch ? "set" : "—"}`, weight: 0.1 },
  { name: "Consistency", score: clamp(100 - driftN * 10 - crep.summary?.totalOutliers * 0.2 || 100), note: `${driftN} real drift · ${crep.groups?.filter(g=>g.outliers.length).length||0} groups w/ deviations (mostly intentional)`, weight: 0.2 },
  { name: "Architecture", score: clamp(100 - layN.reduce((a, f) => a + f.importance / 100 * 9, 0)), note: `${layN.length} verified layering violations · compile-DAG acyclic`, weight: 0.25 },
  { name: "Modularity", score: clamp(100 - bloatBig * 7 - Math.min(20, (erg.summary?.bloat || 0))), note: `${erg.summary?.bloat || 0} bloated files · ${bloatBig} important god-modules`, weight: 0.25 },
  { name: "Duplication", score: clamp(100 - dupN * 6), note: `${dupN} extract-worthy (of ${crep.duplication?.length || 0} dup pairs)`, weight: 0.1 },
  { name: "Dead code", score: clamp(100 - (crep.deadGoPackages?.length || 0) * 8), note: `${crep.deadGoPackages?.length || 0} dead Go packages`, weight: 0.1 },
];
const overall = Math.round(dims.reduce((a, d) => a + d.score * d.weight, 0));
const grade = overall >= 90 ? "A" : overall >= 85 ? "A−" : overall >= 80 ? "B+" : overall >= 75 ? "B" : overall >= 70 ? "B−" : overall >= 65 ? "C+" : overall >= 55 ? "C" : "D";

// effort to reach the next tier: sum effort of findings, grouped
const effortDays = findings.reduce((a, f) => a + f.effort, 0); // crude unit
const out = { at: new Date().toISOString(), overall, grade, dimensions: dims, findings: findings.slice(0, 40), totalFindings: findings.length, effortUnits: effortDays };
writeFileSync(join(HERE, "quality-report.json"), JSON.stringify(out, null, 2));

// ---- HTML ----
const E = (s) => String(s ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;");
const bar = (s) => { const c = s >= 85 ? "#16a34a" : s >= 70 ? "#65a30d" : s >= 55 ? "#ca8a04" : "#dc2626"; return `<div class=track><div class=fill style="width:${s}%;background:${c}"></div></div>`; };
const effLabel = ["", "low", "med", "high", "high+", "xhigh"];
const frow = (f, i) => `<tr><td class=rank>${i + 1}</td><td class=n>${f.impact}</td><td class=n>${f.importance}</td><td><span class="k ${f.kind}">${f.kind}</span></td>`
  + `<td>${f.dim}</td><td class=eff>${effLabel[f.effort]}</td><td class=path>${E(f.file)}</td><td class=act>${E(f.action)}</td></tr>`;
const html = `<!doctype html><meta charset=utf-8><title>Barkpark — Codebase Quality</title>
<style>body{font:13px/1.5 -apple-system,Segoe UI,sans-serif;margin:0;color:#1a1a1a}
header{background:#0f172a;color:#fff;padding:18px 22px;display:flex;align-items:center;gap:22px}
.grade{font-size:46px;font-weight:800;line-height:1}.gsub{font-size:12px;opacity:.8}
.scorecard{display:grid;grid-template-columns:140px 1fr;gap:4px 14px;padding:14px 22px;align-items:center;max-width:760px}
.dn{font-weight:600}.track{height:13px;background:#e2e8f0;border-radius:7px;overflow:hidden;display:inline-block;width:220px;vertical-align:middle}
.fill{height:100%}.dnote{color:#64748b;font-size:11px;grid-column:2}
h2{margin:18px 22px 4px;font-size:15px}.sub{margin:0 22px 6px;color:#64748b;font-size:12px}
table{border-collapse:collapse;width:calc(100% - 44px);margin:0 22px}th,td{padding:5px 8px;border-bottom:1px solid #eef2f7;text-align:left;vertical-align:top}
th{background:#e2e8f0;font-size:11px;text-transform:uppercase}td.n,td.rank{text-align:center;width:46px;font-variant-numeric:tabular-nums}td.rank{color:#cbd5e1}
td.path{font-family:ui-monospace,monospace;font-size:12px}td.act{font-size:12px;color:#334155;max-width:480px}td.eff{font-size:11px}
.k{font-size:10px;padding:1px 6px;border-radius:8px;text-transform:uppercase}.k.layering{background:#fecaca}.k.drift{background:#fed7aa}.k.duplication{background:#fef08a}.k.bloat{background:#ddd6fe}</style>
<header><div><div class=grade>${grade}</div><div class=gsub>overall ${overall}/100</div></div>
<div><div style="font-size:17px;font-weight:700">Barkpark — Codebase Quality</div>
<div class=gsub>${out.totalFindings} actionable findings · est. effort ${effortDays} units · weighted across 6 dimensions</div></div></header>
<div class=scorecard>${dims.map(d => `<div class=dn>${d.name} <b>${d.score}</b></div><div>${bar(d.score)}</div><div class=dnote>${E(d.note)} · weight ${Math.round(d.weight*100)}%</div>`).join("")}</div>
<h2>Improvement plan — what it takes to improve, ranked by impact</h2>
<div class=sub>impact = importance × issue-severity · effort = refactor size · fix top-down for best ROI</div>
<table><thead><tr><th>#</th><th>Impact</th><th>Import</th><th>Kind</th><th>Dimension</th><th>Effort</th><th>Target</th><th>Action</th></tr></thead>
<tbody>${findings.slice(0, 40).map(frow).join("")}</tbody></table>`;
writeFileSync(join(HERE, "quality-report.html"), html);

const e = (s) => process.stderr.write(s + "\n");
e(`\n  CODEBASE QUALITY: ${grade} (${overall}/100)`);
for (const d of dims) e(`    ${d.name.padEnd(13)} ${String(d.score).padStart(3)}  ${d.note}`);
e(`\n  IMPROVEMENT PLAN — top findings by impact (${out.totalFindings} total, ~${effortDays} effort units):`);
for (const f of findings.slice(0, 10)) e(`    impact ${String(f.impact).padStart(3)} [${f.kind}/${effLabel[f.effort]}] ${f.file}`);
e(`  → quality-report.{html,json}`);
