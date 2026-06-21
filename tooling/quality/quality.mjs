#!/usr/bin/env node
// Codebase Quality synthesizer — the capstone, v2 (root-clean, config-driven).
//
// Reads every CLEAN root once (SIGNALS.md), produces a ROOT-CLEAN scorecard and
// the FOUR composite worklists. No dimension double-counts reach: the old
// importance/reusability blend collapses into the single reach axis. Composite
// math (config-driven from tooling/fit/scoring-config.json) lives in the shared
// orthogonality engine. Pure programmatic.
//
//   quality.mjs → quality-report.{html,json} + console scorecard   [free]
//
// FOUR composites (each root once):
//   HOTSPOT          = churn × complexity        → headline dimension + worklist
//   PRIORITY         = reach × defect × ¬test     → recomposed in combine.mjs
//   REFACTOR-WORTH   = bloat × churn × separability → from ergonomics
//   CRITICAL-UNTESTED= reach × ¬coverage          → the danger worklist

import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, existsSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { loadConfig, gatherRoots, composites, percentile } from "../lib/scoring.mjs";
import { FRAGILE_DENSITY } from "../lib/thresholds.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: HERE }).toString().trim();
const rd = (p, d) => existsSync(join(ROOT, p)) ? JSON.parse(readFileSync(join(ROOT, p), "utf8")) : d;

const ledger = rd("tooling/research-coverage/research-ledger.json", { files: {}, meta: {} });
const crep = rd("tooling/consistency/consistency-report.json", { groups: [], layering: [], duplication: [], deadGoPackages: [] });
const erg = rd("tooling/ergonomics/ergonomics-report.json", { files: [], splitCandidates: [], summary: {} });
const risk = rd("tooling/risk/risk-report.json", { files: {} }).files;
const layV = rd("tooling/consistency/results/_layering.json", []);
const dupV = rd("tooling/consistency/results/_dup.json", []);
const gV = {}; const RES = join(ROOT, "tooling/consistency/results");
for (const f of (existsSync(RES) ? readdirSync(RES) : []).filter(f => f.endsWith(".json") && !f.startsWith("_"))) { try { for (const x of JSON.parse(readFileSync(join(RES, f), "utf8")).verdicts || []) gV[x.file] = x; } catch {} }

// ── canonical roots + composites (each root once) ───────────────────────────
const cfg = loadConfig(ROOT);
const roots = gatherRoots(ROOT);
const comp = {}; for (const [p, r] of Object.entries(roots)) comp[p] = composites(r, cfg);
// reach (0–100) is the single VALUE axis — pure programmatic, replaces importance.
const reachOf = (p) => roots[p]?._raw.reach ?? 0;
const allComp = Object.entries(comp);

// percentile thresholds (config-driven) over the composite distributions
const hotspotCut = percentile(allComp.map(([, c]) => c.hotspot), cfg.thresholds.hotspotPercentile);
const critArr = allComp.map(([p, c]) => ({ p, v: c.criticalUntested })).sort((a, b) => b.v - a.v);
const dangerTopK = Math.max(1, cfg.thresholds.dangerTopK || 40);

// ---- findings (the atomic improvement units) ----
// value = reach (clean root). defect amplifies; testScore gates the untested set.
const findings = [];
for (const l of layV) if (l.verdict === "violation") findings.push({ kind: "layering", file: l.file, dim: "Architecture", sev: 1.0, effort: 2, action: l.fix || "Move data access into a domain context", why: l.reason });
for (const [f, v] of Object.entries(gV)) if (v.verdict === "drift") findings.push({ kind: "drift", file: f, dim: "Consistency", sev: 0.9, effort: 1, action: v.recommendation, why: "diverges from the group's own pattern" });
for (const v of dupV) if (v.verdict === "extract") findings.push({ kind: "duplication", file: v.a, dim: "Duplication", sev: 0.55, effort: 2, action: `Extract shared logic (≈ ${v.b})`, why: v.reason });
for (const r of erg.splitCandidates) if (r.refactorWorth > 5000) findings.push({ kind: "bloat", file: r.path, dim: "Modularity", sev: Math.min(1, r.refactorWorth / 40000), effort: r.tokens > 30000 ? 5 : r.tokens > 15000 ? 4 : 3, action: `Split god-module (${r.defs} defs, ${r.tokens.toLocaleString()} tok) read every change (churn ${r.churn})`, why: "context-bloat paid on every read" });
// HOTSPOT findings — churn × complexity above the fitted percentile (the refactor gold standard)
for (const [f, c] of allComp) if (c.hotspot >= hotspotCut && c.hotspot >= 60 && (roots[f]?._raw.churn ?? 0) >= 8) findings.push({ kind: "hotspot", file: f, dim: "Hotspot", sev: Math.min(1, c.hotspot / 100), effort: roots[f]._raw.tokens > 20000 ? 4 : 3, action: `Refactor hotspot — churn ${roots[f]._raw.churn} × ${roots[f]._raw.tokens.toLocaleString()} tok (hotspot ${c.hotspot})`, why: "high-churn high-complexity: the field's gold-standard refactor target" });
// CRITICAL-UNTESTED findings — reach × ¬coverage in the danger top-K
for (const { p: f } of critArr.slice(0, dangerTopK)) { const rk = risk[f] || {}; if ((comp[f]?.criticalUntested ?? 0) >= 50) findings.push({ kind: "untested", file: f, dim: "Tested", sev: Math.min(1, comp[f].criticalUntested / 100), effort: 2, action: `Add tests — reach ${reachOf(f)}, ${rk.hasTest ? "sibling test is thin" : "no sibling test"} (crit-untested ${comp[f].criticalUntested})`, why: "high-reach code with little/no coverage" }); }

// impact = reach × severity, AMPLIFIED where bugs actually land (defect history)
for (const r of findings) { r.reach = reachOf(r.file); r.defect = risk[r.file]?.defectDensity || 0; r.impact = Math.round((r.reach || 1) * r.sev * (1 + Math.min(1, r.defect))); r.roi = +(r.impact / r.effort).toFixed(1); }
// dedupe: keep the highest-impact finding per (file, dim)
const seen = new Set(); const deduped = [];
for (const r of findings.sort((a, b) => b.impact - a.impact)) { const k = r.file + "|" + r.dim; if (seen.has(k)) continue; seen.add(k); deduped.push(r); }
deduped.sort((a, b) => b.impact - a.impact || b.roi - a.roi);

// ---- scorecard dimensions (0-100, higher = better) — ROOT-CLEAN ----
const clamp = (n) => Math.max(0, Math.min(100, Math.round(n)));
const driftN = deduped.filter(f => f.kind === "drift").length;
const layN = deduped.filter(f => f.kind === "layering");
const dupN = deduped.filter(f => f.kind === "duplication").length;
const bloatBig = deduped.filter(f => f.kind === "bloat" && f.reach >= 50).length;
const evaluated = Object.values(ledger.files).length ? 100 : 0;

// HOTSPOT dimension — churn × complexity density (the refactor-target axis)
const hotspots = allComp.filter(([, c]) => c.hotspot >= 70).map(([p]) => p);
const hotspotN = hotspots.length;

// test-presence + defect-history across HIGH-REACH code files (value = reach, the single axis)
const impCode = Object.entries(risk).filter(([f]) => reachOf(f) >= 40);
const testedFrac = impCode.length ? impCode.filter(([, v]) => v.testScore >= 50).length / impCode.length : 1;
const fragileN = impCode.filter(([, v]) => v.defectDensity >= FRAGILE_DENSITY).length;
const critN = critArr.slice(0, dangerTopK).filter(x => x.v >= 50).length;

const dims = [
  { name: "Evaluated", root: "—", score: evaluated, note: `${Object.keys(ledger.files).length} files researched · last full ${ledger.meta.lastFullResearch ? "set" : "—"}`, weight: 0.06 },
  { name: "Consistency", root: "conventions", score: clamp(100 - driftN * 10 - (crep.summary?.totalOutliers || 0) * 0.2), note: `${driftN} real drift · ${crep.groups?.filter(g=>g.outliers.length).length||0} groups w/ deviations (mostly intentional)`, weight: 0.13 },
  { name: "Architecture", root: "relationships", score: clamp(100 - layN.reduce((a, f) => a + (f.reach || 50) / 100 * 9, 0)), note: `${layN.length} verified layering violations · compile-DAG acyclic`, weight: 0.15 },
  { name: "Hotspots", root: "churn × complexity", score: clamp(100 - hotspotN * 4), note: `${hotspotN} files churn×complexity ≥70 · ${deduped.filter(f=>f.kind==="hotspot").length} above the ${cfg.thresholds.hotspotPercentile}th-pct refactor line`, weight: 0.16 },
  { name: "Modularity", root: "complexity", score: clamp(100 - bloatBig * 7 - Math.min(20, (erg.summary?.bloat || 0))), note: `${erg.summary?.bloat || 0} bloated files · ${bloatBig} high-reach god-modules`, weight: 0.12 },
  { name: "Tested", root: "tests", score: clamp(testedFrac * 100), note: `${Math.round(testedFrac*100)}% of high-reach code has coverage · ${critN} critical-untested (reach × ¬coverage)`, weight: 0.15 },
  { name: "Reliability", root: "defects", score: clamp(100 - fragileN * 5), note: `${fragileN} high-reach files are defect-prone (bug-fix density ≥${FRAGILE_DENSITY})`, weight: 0.10 },
  { name: "Duplication", root: "relationships", score: clamp(100 - dupN * 6), note: `${dupN} extract-worthy (of ${crep.duplication?.length || 0} dup pairs)`, weight: 0.06 },
  { name: "Dead code", root: "reach", score: clamp(100 - (crep.deadGoPackages?.length || 0) * 8), note: `${crep.deadGoPackages?.length || 0} dead Go packages`, weight: 0.07 },
];
const overall = Math.round(dims.reduce((a, d) => a + d.score * d.weight, 0));
const grade = overall >= 90 ? "A" : overall >= 85 ? "A−" : overall >= 80 ? "B+" : overall >= 75 ? "B" : overall >= 70 ? "B−" : overall >= 65 ? "C+" : overall >= 55 ? "C" : "D";

// ── the four composite worklists (top entries, for the dashboard + JSON) ──
const topBy = (key, n = 15) => allComp.map(([p, c]) => ({ path: p, score: c[key], raw: roots[p]._raw })).sort((a, b) => b.score - a.score).slice(0, n).filter(x => x.score > 0);
const worklists = {
  hotspot: topBy("hotspot"),
  criticalUntested: topBy("criticalUntested"),
  refactorWorth: topBy("refactorWorth"),
  priority: topBy("priority"),
};

const effortDays = deduped.reduce((a, f) => a + f.effort, 0);
const out = {
  at: new Date().toISOString(), overall, grade, dimensions: dims,
  findings: deduped.slice(0, 40), totalFindings: deduped.length, effortUnits: effortDays,
  composites: { config: { source: cfg.source, confidence: cfg.confidence, forms: Object.fromEntries(Object.entries(cfg.composites).map(([k, v]) => [k, v.form])) }, worklists },
};
writeFileSync(join(HERE, "quality-report.json"), JSON.stringify(out, null, 2));

// ---- HTML ----
const E = (s) => String(s ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;");
const bar = (s) => { const c = s >= 85 ? "#16a34a" : s >= 70 ? "#65a30d" : s >= 55 ? "#ca8a04" : "#dc2626"; return `<div class=track><div class=fill style="width:${s}%;background:${c}"></div></div>`; };
const effLabel = ["", "low", "med", "high", "high+", "xhigh"];
const frow = (f, i) => `<tr><td class=rank>${i + 1}</td><td class=n>${f.impact}</td><td class=n>${f.reach}</td><td><span class="k ${f.kind}">${f.kind}</span></td>`
  + `<td>${f.dim}</td><td class=eff>${effLabel[f.effort]}</td><td class=path>${E(f.file)}</td><td class=act>${E(f.action)}${f.defect >= FRAGILE_DENSITY ? ` <b style="color:#b45309">⚠ defect ${f.defect}</b>` : ""}</td></tr>`;
const wlRow = (x, i) => `<tr><td class=rank>${i + 1}</td><td class=n>${x.score}</td><td class=path>${E(x.path)}</td><td class=meta>churn ${x.raw.churn} · ${x.raw.tokens.toLocaleString()}tok · reach ${x.raw.reach} · test ${x.raw.testScore}</td></tr>`;
const wlTable = (title, sub, rows) => `<h2>${title}</h2><div class=sub>${sub}</div><table><thead><tr><th>#</th><th>Score</th><th>Path</th><th>Roots</th></tr></thead><tbody>${rows.map(wlRow).join("") || "<tr><td colspan=4 class=sub>none</td></tr>"}</tbody></table>`;

const html = `<!doctype html><meta charset=utf-8><title>Barkpark — Codebase Quality (v2)</title>
<style>body{font:13px/1.5 -apple-system,Segoe UI,sans-serif;margin:0;color:#1a1a1a}
header{background:#0f172a;color:#fff;padding:18px 22px;display:flex;align-items:center;gap:22px}
.grade{font-size:46px;font-weight:800;line-height:1}.gsub{font-size:12px;opacity:.8}
.scorecard{display:grid;grid-template-columns:170px 1fr;gap:4px 14px;padding:14px 22px;align-items:center;max-width:820px}
.dn{font-weight:600}.dn .rt{font-weight:400;color:#94a3b8;font-size:11px}.track{height:13px;background:#e2e8f0;border-radius:7px;overflow:hidden;display:inline-block;width:220px;vertical-align:middle}
.fill{height:100%}.dnote{color:#64748b;font-size:11px;grid-column:2}
h2{margin:18px 22px 4px;font-size:15px}.sub{margin:0 22px 6px;color:#64748b;font-size:12px}
table{border-collapse:collapse;width:calc(100% - 44px);margin:0 22px}th,td{padding:5px 8px;border-bottom:1px solid #eef2f7;text-align:left;vertical-align:top}
th{background:#e2e8f0;font-size:11px;text-transform:uppercase}td.n,td.rank{text-align:center;width:46px;font-variant-numeric:tabular-nums}td.rank{color:#cbd5e1}
td.path{font-family:ui-monospace,monospace;font-size:12px}td.act,td.meta{font-size:12px;color:#334155;max-width:480px}td.eff{font-size:11px}
.k{font-size:10px;padding:1px 6px;border-radius:8px;text-transform:uppercase}.k.layering{background:#fecaca}.k.drift{background:#fed7aa}.k.duplication{background:#fef08a}.k.bloat{background:#ddd6fe}.k.untested{background:#bae6fd}.k.hotspot{background:#fca5a5}</style>
<header><div><div class=grade>${grade}</div><div class=gsub>overall ${overall}/100</div></div>
<div><div style="font-size:17px;font-weight:700">Barkpark — Codebase Quality (v2 · root-clean)</div>
<div class=gsub>${out.totalFindings} findings · est. effort ${effortDays} units · each dimension keys ONE canonical root · composites: ${E(cfg.source)} (${E(cfg.confidence)})</div></div></header>
<div class=scorecard>${dims.map(d => `<div class=dn>${d.name} <b>${d.score}</b> <span class=rt>· ${E(d.root)}</span></div><div>${bar(d.score)}</div><div class=dnote>${E(d.note)} · weight ${Math.round(d.weight*100)}%</div>`).join("")}</div>
<h2>Improvement plan — ranked by impact (impact = reach × severity × defect-amplifier)</h2>
<div class=sub>value axis is reach (transitive dependents) — the single value root, no importance/reusability double-count · fix top-down for best ROI</div>
<table><thead><tr><th>#</th><th>Impact</th><th>Reach</th><th>Kind</th><th>Dimension</th><th>Effort</th><th>Target</th><th>Action</th></tr></thead>
<tbody>${deduped.slice(0, 40).map(frow).join("")}</tbody></table>
${wlTable("⭑ Priority worklist — reach × severity × defect × untested", "fix top-down: highest-leverage code carrying the most risk", worklists.priority)}
${wlTable("🔥 Hotspot map — churn × complexity", "the refactor-target gold standard: high-churn × high-complexity files", worklists.hotspot)}
${wlTable("⚠ Critical-untested — reach × ¬coverage", "the danger worklist: high-reach files with little/no coverage", worklists.criticalUntested)}
${wlTable("Refactor-worth — bloat × churn × separability", "agent-ergonomics axis: big monolithic files read on every change", worklists.refactorWorth)}`;
writeFileSync(join(HERE, "quality-report.html"), html);

const e = (s) => process.stderr.write(s + "\n");
e(`\n  CODEBASE QUALITY (v2): ${grade} (${overall}/100) — composites: ${cfg.source} (${cfg.confidence})`);
for (const d of dims) e(`    ${d.name.padEnd(13)} ${String(d.score).padStart(3)}  [${d.root}]  ${d.note}`);
e(`\n  IMPROVEMENT PLAN — top findings by impact (${out.totalFindings} total, ~${effortDays} effort units):`);
for (const f of deduped.slice(0, 10)) e(`    impact ${String(f.impact).padStart(3)} [${f.kind}/${effLabel[f.effort]}] ${f.file}`);
e(`\n  ⭑ PRIORITY (reach × severity × defect × untested): ${worklists.priority.slice(0,5).map(x => x.path.split("/").pop() + " " + x.score).join(" · ")}`);
e(`  🔥 HOTSPOT MAP (churn × complexity): ${worklists.hotspot.slice(0,5).map(x => x.path.split("/").pop() + " " + x.score).join(" · ")}`);
e(`  ⚠ CRITICAL-UNTESTED (reach × ¬coverage): ${worklists.criticalUntested.slice(0,5).map(x => x.path.split("/").pop() + " " + x.score).join(" · ")}`);
e(`  → quality-report.{html,json}`);
