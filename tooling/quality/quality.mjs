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
import { evalFormula } from "../lib/formula.mjs";
// effort estimate (1–5) for splitting a bloated file, as a bound piecewise
// FUNCTION (cody rung ④) — tunable through a paper, safely evaluated.
const EFFORT_FN = "tokens > 30000 ? 5 : tokens > 15000 ? 4 : 3";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: HERE }).toString().trim();
const rd = (p, d) => existsSync(join(ROOT, p)) ? JSON.parse(readFileSync(join(ROOT, p), "utf8")) : d;

const ledger = rd("tooling/research-coverage/research-ledger.json", { files: {}, meta: {} });
const crep = rd("tooling/consistency/consistency-report.json", { groups: [], layering: [], duplication: [], deadGoPackages: [] });
const erg = rd("tooling/ergonomics/ergonomics-report.json", { files: [], splitCandidates: [], summary: {} });
const riskRpt = rd("tooling/risk/risk-report.json", { files: {}, coverageTotals: {} });
const risk = riskRpt.files;
const deps = rd("tooling/deps/deps-report.json", { totals: {}, skipped: ["all"] });
// FILEBASE critic (Bloat + Aesthetics) — the tree-mess axis Cody was blind to.
const aes = rd("tooling/aesthetics/aesthetics-report.json", { bloat: { score: 100, findings: [] }, aesthetics: { score: 100, findings: [] }, summary: {} });
const covT = riskRpt.coverageTotals || {};
// The batches/record agent cycle writes results/_layering.json + _dup.json; a
// plain `consistency.mjs scan` does NOT. When those issue files are absent the
// grader must not read [] and award a false 100 — fall back to the agent-confirmed
// verdicts persisted in verdict-cache.json. Architecture/Duplication then reflect
// real violations instead of a missing file. (Bug: this path was silently empty,
// hiding 5 confirmed layering violations behind a perfect Architecture score.)
const _vcache = rd("tooling/consistency/verdict-cache.json", { layering: [], duplication: [] });
const layV = existsSync(join(ROOT, "tooling/consistency/results/_layering.json"))
  ? rd("tooling/consistency/results/_layering.json", [])
  : (_vcache.layering || []);
const dupV = existsSync(join(ROOT, "tooling/consistency/results/_dup.json"))
  ? rd("tooling/consistency/results/_dup.json", [])
  : (_vcache.duplication || []);
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
for (const r of erg.splitCandidates) if (r.refactorWorth > 5000 && !r.contract) findings.push({ kind: "bloat", file: r.path, dim: "Modularity", sev: Math.min(1, r.refactorWorth / 40000), effort: evalFormula(EFFORT_FN, { tokens: r.tokens }), action: `Split god-module (${r.defs} defs, ${r.tokens.toLocaleString()} tok) read every change (churn ${r.churn})`, why: "context-bloat paid on every read" });
// HOTSPOT findings — churn × complexity above the fitted percentile (the refactor gold standard)
for (const [f, c] of allComp) if (c.hotspot >= hotspotCut && c.hotspot >= 60 && (roots[f]?._raw.churn ?? 0) >= 8) findings.push({ kind: "hotspot", file: f, dim: "Hotspot", sev: Math.min(1, c.hotspot / 100), effort: roots[f]._raw.tokens > 20000 ? 4 : 3, action: `Refactor hotspot — churn ${roots[f]._raw.churn} × ${roots[f]._raw.tokens.toLocaleString()} tok (hotspot ${c.hotspot})`, why: "high-churn high-complexity: the field's gold-standard refactor target" });
// CRITICAL-UNTESTED findings — reach × ¬coverage in the danger top-K
for (const { p: f } of critArr.slice(0, dangerTopK)) { const rk = risk[f] || {}; if ((comp[f]?.criticalUntested ?? 0) >= 50) findings.push({ kind: "untested", file: f, dim: "Tested", sev: Math.min(1, comp[f].criticalUntested / 100), effort: 2, action: `Add tests — reach ${reachOf(f)}, ${rk.hasTest ? "sibling test is thin" : "no sibling test"} (crit-untested ${comp[f].criticalUntested})`, why: "high-reach code with little/no coverage" }); }
// FILEBASE findings (Bloat + Aesthetics) — the tree-mess critic (tooling/aesthetics).
// These describe the TREE, not a graph node, so they carry no transitive reach. Give
// each a synthetic "blast" — how widely the mess is paid (root clutter is read on every
// `ls`, artifacts noise every diff) — so the mechanical-but-broad cleanups RANK in the
// plan instead of pinning to impact 1. Bounded below code reach (≤100) so correctness/
// untested still lead. effort: gitignore/close=1, dir regroup=2, root-package move=3.
const AES_BLAST = { "root-clutter": 65, "tracked-artifact": 48, "dir-fanout": 18, "dead-doc": 42, "dead-task": 22, "yagni-orphan": 30 };
const AES_DIM = { "root-clutter": "Bloat", "tracked-artifact": "Bloat", "dir-fanout": "Bloat", "dead-doc": "Aesthetics", "dead-task": "Aesthetics", "yagni-orphan": "Aesthetics" };
const AES_EFFORT = { "root-clutter": 3, "tracked-artifact": 1, "dir-fanout": 2, "dead-doc": 1, "dead-task": 1, "yagni-orphan": 1 };
for (const f of [...(aes.bloat?.findings || []), ...(aes.aesthetics?.findings || [])]) {
  findings.push({ kind: f.kind, file: f.path, dim: AES_DIM[f.kind] || "Bloat", sev: f.severity, effort: AES_EFFORT[f.kind] || 1, action: f.fix, why: f.why, reach: Math.round((f.severity || 0.5) * (AES_BLAST[f.kind] || 20)) });
}

// impact = reach × severity, AMPLIFIED where bugs actually land (defect history).
// Filebase findings arrive with reach pre-set (synthetic blast) — respect it; graph
// findings (reach unset) fall through to reachOf as before.
for (const r of findings) { r.reach = r.reach ?? reachOf(r.file); r.defect = risk[r.file]?.defectDensity || 0; r.impact = Math.round((r.reach || 1) * r.sev * (1 + Math.min(1, r.defect))); r.roi = +(r.impact / r.effort).toFixed(1); }
// dedupe: keep the highest-impact finding per (file, dim)
const seen = new Set(); const deduped = [];
for (const r of findings.sort((a, b) => b.impact - a.impact)) { const k = r.file + "|" + r.dim; if (seen.has(k)) continue; seen.add(k); deduped.push(r); }
deduped.sort((a, b) => b.impact - a.impact || b.roi - a.roi);

// ---- scorecard dimensions (0-100, higher = better) — ROOT-CLEAN ----
const clamp = (n) => Math.max(0, Math.min(100, Math.round(n)));
const driftN = deduped.filter(f => f.kind === "drift").length;
const layN = deduped.filter(f => f.kind === "layering");
const dupN = deduped.filter(f => f.kind === "duplication").length;
// Count god-modules by ABSOLUTE reach (raw transitive-dependent count), not the
// normalized 0–100 reach: normalized reach re-normalizes when the graph gains/loses
// nodes, so a hard cutoff on it flipped borderline files (and swung the grade)
// when decomposing one module added 3 nodes. GOD_MODULE_REACH=15 is the absolute
// equivalent of the old normalized-50 cutoff on the current graph — baseline-neutral
// now, and stable under graph perturbation going forward.
const GOD_MODULE_REACH = 15;
const reachAbsOf = (p) => roots[p]?._raw.reachAbs ?? 0;
// Modularity counts STRUCTURAL god-modules: large by SIZE (ergonomics sizeClass
// "bloat" = >8k tokens) AND high-reach. NOT refactorWorth — that folds in churn,
// which Hotspots already owns, so counting it here double-penalized churn-heavy
// but size-normal files (e.g. content.ex: 5.8k tok, churn 149 — a Hotspot, not a
// god-module). Behaviour-contract modules (@callback-dominated, e.g. plugin.ex)
// are excluded: their bulk is spec, not splittable logic. Each exclusion is
// surfaced in the dimension note so a reader never sees an unexplained number.
const ergFiles = erg.files || [];
const isGodMod = (r) => r.sizeClass === "bloat" && reachAbsOf(r.path) >= GOD_MODULE_REACH;
const godMods = ergFiles.filter((r) => isGodMod(r) && !r.contract);
const bloatBig = godMods.length;
const godExcludedContract = ergFiles.filter((r) => isGodMod(r) && r.contract).length;
// high-reach + refactorWorth-flagged but NOT structurally large → churn-driven
// (counted under Hotspots instead). Reported for transparency only.
const godChurnDriven = deduped.filter((f) => f.kind === "bloat" && reachAbsOf(f.file) >= GOD_MODULE_REACH && !godMods.some((g) => g.path === f.file)).length;
const evaluated = Object.values(ledger.files).length ? 100 : 0;

// HOTSPOT dimension — churn × complexity density (the refactor-target axis)
const hotspots = allComp.filter(([, c]) => c.hotspot >= 70).map(([p]) => p);
const hotspotN = hotspots.length;

// test-presence + defect-history across HIGH-REACH code files (value = reach, the single axis)
const impCode = Object.entries(risk).filter(([f]) => reachOf(f) >= 40);
const testedFrac = impCode.length ? impCode.filter(([, v]) => v.testScore >= 50).length / impCode.length : 1;
const fragileN = impCode.filter(([, v]) => v.defectDensity >= FRAGILE_DENSITY).length;
const critN = critArr.slice(0, dangerTopK).filter(x => x.v >= 50).length;

// ── Contract — cross-language wire-seam guard strength (cheap static check, no generator) ──
// Each seam in blast-radius config declares guard files. A seam is:
//   strong (1.0) — has a present executable/snapshot guard (.exs/.ex or .json snapshot)
//   weak   (0.5) — only present guard(s) are .md docs
//   0            — no guard file exists on disk
// drift on an unguarded/doc-only seam silently breaks the Go CLI / JS SDK.
const brCfg = rd("tooling/blast-radius/config.json", { seam: { surfaces: [] } });
const surfaces = brCfg.seam?.surfaces || [];
let contractGuarded = 0, contractStrong = 0, contractWeak = 0, contractSum = 0;
const contractWeakIds = [], contractUnguardedIds = [];
for (const s of surfaces) {
  const guards = (s.guards || []).map(g => String(g).trim().split(/\s+/)[0]).filter(Boolean);
  let hasExec = false, hasDoc = false;
  for (const g of guards) {
    if (!existsSync(join(ROOT, g))) continue;
    if (/\.(exs?|json)$/.test(g)) hasExec = true;
    else if (/\.md$/.test(g)) hasDoc = true;
  }
  if (hasExec) { contractStrong++; contractGuarded++; contractSum += 1.0; }
  else if (hasDoc) { contractWeak++; contractGuarded++; contractSum += 0.5; contractWeakIds.push(s.id); }
  else { contractUnguardedIds.push(s.id); }
}
const contractTotal = surfaces.length;
const contractScore = clamp(contractTotal ? 100 * contractSum / contractTotal : 100);
const unguardedNote = (contractUnguardedIds.length || contractWeakIds.length)
  ? ` · weak/unguarded: ${[...contractUnguardedIds, ...contractWeakIds].join(", ")}`
  : "";

// ── Dependencies — supply-chain vuln load from the deps generator ──
// A GRADIENT, not a cliff. The old linear `100 - high*10 - …` saturated to 0
// well before the tree was clean (14 highs alone = −140), so it couldn't tell
// "2 crit + 19 high" (dire) from "0 crit + 14 high" (improved) — fixing the
// criticals moved nothing. Now: criticals dominate LINEARLY and steeply (an RCE
// should tank the score, ~3 crit ≈ fatal), while high/moderate/low feed a
// SATURATING curve so the number keeps moving as you triage (clearing 14→7 highs
// visibly helps) and only approaches 100 when genuinely clean. Never rewards
// leaving a critical. NOT tuned to a target — magnitudes chosen for the curve shape.
const dv = deps.totals || {};
const critPenalty = (dv.critical || 0) * 45;
const restLoad = (dv.high || 0) * 8 + (dv.moderate || 0) * 2.5 + (dv.low || 0) * 0.5;
const restPenalty = 65 * (1 - Math.pow(0.5, restLoad / 55));
const depScore = clamp(100 - critPenalty - restPenalty);

const dims = [
  { name: "Evaluated", root: "—", score: evaluated, note: `${Object.keys(ledger.files).length} files researched · last full ${ledger.meta.lastFullResearch ? "set" : "—"}`, weight: 0.06 },
  { name: "Consistency", root: "conventions", score: clamp(100 - driftN * 10 - (crep.summary?.totalOutliers || 0) * 0.2), note: `${driftN} real drift · ${crep.groups?.filter(g=>g.outliers.length).length||0} groups w/ deviations (mostly intentional)`, weight: 0.13 },
  { name: "Architecture", root: "relationships", score: clamp(100 - layN.reduce((a, f) => a + (f.reach || 50) / 100 * 9, 0)), note: `${layN.length} verified layering violations · compile-DAG acyclic`, weight: 0.15 },
  { name: "Hotspots", root: "churn × complexity", score: clamp(100 - hotspotN * 4), note: `${hotspotN} files churn×complexity ≥70 · ${deduped.filter(f=>f.kind==="hotspot").length} above the ${cfg.thresholds.hotspotPercentile}th-pct refactor line`, weight: 0.16 },
  { name: "Modularity", root: "complexity", score: clamp(100 - bloatBig * 7 - Math.min(20, (erg.summary?.bloat || 0))), note: `${bloatBig} high-reach god-modules (>8k tok)${godExcludedContract ? ` · ${godExcludedContract} behaviour-contract excluded` : ""}${godChurnDriven ? ` · ${godChurnDriven} churn-driven → Hotspots` : ""} · ${erg.summary?.bloat || 0} bloated files (−7/god, −1/bloat≤20)`, weight: 0.12 },
  { name: "Tested", root: "tests", score: clamp(testedFrac * 100), note: `${Math.round(testedFrac*100)}% of high-reach code covered — measured: elixir ${covT.elixir ?? "—"}% · go ${covT.go ?? "—"}% · js ${covT.js ?? "—"}% · web/ UNTESTED (reach-0, excluded not failed) · ${critN} critical-untested`, weight: 0.15 },
  { name: "Reliability", root: "defects", score: clamp(100 - fragileN * 5), note: `${fragileN} high-reach files are defect-prone (bug-fix density ≥${FRAGILE_DENSITY})`, weight: 0.10 },
  { name: "Duplication", root: "relationships", score: clamp(100 - dupN * 6), note: `${dupN} extract-worthy (of ${crep.duplication?.length || 0} dup pairs)`, weight: 0.06 },
  { name: "Dead code", root: "reach", score: clamp(100 - (crep.deadGoPackages?.length || 0) * 8), note: `${crep.deadGoPackages?.length || 0} dead Go packages`, weight: 0.07 },
  { name: "Contract", root: "wire seams", score: contractScore, note: `${contractGuarded}/${contractTotal} cross-language wire seams guarded (${contractStrong} executable, ${contractWeak} doc-only) · drift breaks the Go CLI / JS SDK${unguardedNote}`, weight: 0.05 },
  { name: "Dependencies", root: "supply chain", score: depScore, note: `${dv.critical || 0} crit · ${dv.high || 0} high · ${dv.moderate || 0} moderate vulns${deps.skipped?.length ? ` · unaudited: ${deps.skipped.join("/")}` : ""}`, weight: 0.05 },
  // FILEBASE critic — the tree-mess axis (tooling/aesthetics). Two dims at 0.05 each:
  // meaningful (8% combined of wsum 1.20 — moves the grade when the tree is messy) but
  // it does NOT swamp the 11 code dims (~0.92 of the weight stays on code quality).
  { name: "Bloat", root: "filebase", score: aes.bloat?.score ?? 100, note: `${aes.summary?.rootClutter ?? 0} source files in repo ROOT (${aes.summary?.rootClutterExt ?? "—"}) · ${aes.summary?.trackedArtifacts ?? 0} tracked build artifacts (${aes.summary?.buildOutput ?? 0} build-output, ${aes.summary?.servedOrTyped ?? 0} served/typed) · ${aes.summary?.fanoutDirs ?? 0} over-flat dirs`, weight: 0.05 },
  { name: "Aesthetics", root: "YAGNI / mess", score: aes.aesthetics?.score ?? 100, note: `${aes.summary?.deadDocsAttic ?? 0} dead docs (_attic grave) · ${aes.summary?.junkTasks ?? 0} junk + ${aes.summary?.unscopedOpenTasks ?? 0} unscoped open tasks · ${aes.summary?.orphanDocs ?? 0} live-tree orphans · ${aes.summary?.yagniOrphans ?? 0} yagni-orphans · staleness: ${aes.summary?.taskStaleness ? "heuristic" : "—"}`, weight: 0.05 },
];
const wsum = dims.reduce((a, d) => a + d.weight, 0);
const overall = Math.round(dims.reduce((a, d) => a + d.score * d.weight, 0) / wsum);
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
.k{font-size:10px;padding:1px 6px;border-radius:8px;text-transform:uppercase}.k.layering{background:#fecaca}.k.drift{background:#fed7aa}.k.duplication{background:#fef08a}.k.bloat{background:#ddd6fe}.k.untested{background:#bae6fd}.k.hotspot{background:#fca5a5}.k.root-clutter,.k.tracked-artifact,.k.dir-fanout{background:#fde68a}.k.dead-doc,.k.dead-task,.k.yagni-orphan{background:#fbcfe8}</style>
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
// FILEBASE rows rank below the high-reach untested-code cluster (honest: adding tests
// to reach-90 code out-leverages deleting attic docs), so surface them on their own line.
const _fbKinds = new Set(["root-clutter", "tracked-artifact", "dir-fanout", "dead-doc", "dead-task", "yagni-orphan"]);
const _fb = deduped.filter((f) => _fbKinds.has(f.kind));
if (_fb.length) { e(`\n  🧹 FILEBASE (Bloat + Aesthetics) — ${_fb.length} tree-mess findings:`); for (const f of _fb.slice(0, 7)) e(`    impact ${String(f.impact).padStart(3)} [${f.kind}/${effLabel[f.effort]}] ${f.file} — ${String(f.action).slice(0, 64)}`); }
e(`\n  ⭑ PRIORITY (reach × severity × defect × untested): ${worklists.priority.slice(0,5).map(x => x.path.split("/").pop() + " " + x.score).join(" · ")}`);
e(`  🔥 HOTSPOT MAP (churn × complexity): ${worklists.hotspot.slice(0,5).map(x => x.path.split("/").pop() + " " + x.score).join(" · ")}`);
e(`  ⚠ CRITICAL-UNTESTED (reach × ¬coverage): ${worklists.criticalUntested.slice(0,5).map(x => x.path.split("/").pop() + " " + x.score).join(" · ")}`);
e(`  → quality-report.{html,json}`);
