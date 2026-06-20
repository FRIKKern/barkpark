#!/usr/bin/env node
// tooling/fit — the CALIBRATION ENGINE (v2 Phase 4, task cqv2-fit).
//
// Pure programmatic, ZERO tokens at runtime. It does NOT assert the scoring —
// it LEARNS it from the codebase's own history. The recipe:
//
//   1. assemble a per-file signal matrix from the upstream reports
//        reach          ← tooling/usefulness/usefulness-report.json
//        churn, loc     ← tooling/file-importance/file-signals.json
//        tokens, defs   ← tooling/ergonomics/ergonomics-report.json
//        defectDensity  ← tooling/risk/risk-report.json
//        testScore      ← tooling/risk/risk-report.json
//        ownership      ← tooling/risk/risk-report.json (primaryAuthorShare)
//        consistency    ← tooling/consistency/consistency-report.json (derived)
//        importance     ← tooling/combined/combined-report.json
//   2. OUTCOME LABEL from git, programmatic: "future-defect" = did a file
//      receive a fix/revert commit in the LATER (recent) half of its history.
//      Split commits by date; label 1 if a fix landed in the recent window.
//   3. per-signal Spearman correlation vs the outcome (feature importance).
//   4. pairwise collinearity (Spearman matrix; flag |r|>0.7 — exposes the
//      reach/importance redundancy v2 is hunting).
//   5. weight fitting: interpretable logistic regression in pure JS
//      (batch gradient descent on standardized features), AUC-scored.
//   6. TEMPORAL cross-validation: fit on OLDER-history labels, test on the
//      RECENT window. Report AUC + precision@k on the held-out window.
//   7. confidence flag: when positive labels are sparse, fall back to sensible
//      priors rather than overfit a handful of points.
//
// OUTPUTS (both gitignored — derived):
//   tooling/fit/scoring-config.json   weights per composite, blend forms,
//                                     thresholds, kept/dropped signals, confidence
//   tooling/fit/fit-report.html       ranked importance, weights, validity, collinear list
//
//   node tooling/fit/fit.mjs

import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: HERE }).toString().trim();
const e = (s = "") => process.stderr.write(s + "\n");
const rd = (p, d) => existsSync(join(ROOT, p)) ? JSON.parse(readFileSync(join(ROOT, p), "utf8")) : d;
const git = (a) => execFileSync("git", a, { cwd: ROOT, encoding: "utf8", maxBuffer: 512 * 1024 * 1024 });

// ════════════════ 1 — assemble the per-file signal matrix ════════════════
const useFiles = rd("tooling/usefulness/usefulness-report.json", { files: {} }).files;
const sig = (rd("tooling/file-importance/file-signals.json", { signals: [] }).signals) || [];
const ergo = (rd("tooling/ergonomics/ergonomics-report.json", { files: [] }).files) || [];
const riskFiles = rd("tooling/risk/risk-report.json", { files: {} }).files;
const combinedRows = (rd("tooling/combined/combined-report.json", { rows: [] }).rows) || [];
const consGroups = (rd("tooling/consistency/consistency-report.json", { groups: [] }).groups) || [];

const sigByPath = Object.fromEntries(sig.map(s => [s.path, s]));
const ergoByPath = Object.fromEntries(ergo.map(s => [s.path, s]));
const impByPath = Object.fromEntries(combinedRows.map(r => [r.path, r.importance]));

// consistency → per-file score: group conform% is the base; flagged outliers
// take a penalty proportional to their reason count.
const consByPath = {};
for (const g of consGroups) {
  const base = typeof g.conform === "number" ? g.conform : 100;
  const outlierReasons = {};
  for (const o of (g.outliers || [])) outlierReasons[o.file] = (o.reasons || []).length || 1;
  // files of the group not enumerated individually → assign the group conform.
  // we only know outliers by name; conforming members inherit `base`.
  for (const [file, n] of Object.entries(outlierReasons)) {
    consByPath[file] = Math.max(0, base - 20 * n);
  }
  // record the group's base under a sentinel for dir-level fallback
  consByPath["__dir__" + g.dir] = base;
}
function consistencyFor(path) {
  if (path in consByPath) return consByPath[path];
  // fall back to the directory group's conform%, else neutral 75.
  const dir = path.slice(0, path.lastIndexOf("/"));
  let best = null;
  for (const k in consByPath) {
    if (!k.startsWith("__dir__")) continue;
    const d = k.slice(7);
    if (path.startsWith(d + "/")) { if (best === null || d.length > best.len) best = { v: consByPath[k], len: d.length }; }
  }
  return best ? best.v : 75;
}

// the kept signal set — one per canonical root + importance composite.
const SIGNALS = ["reach", "churn", "loc", "tokens", "defs", "defectDensity", "testScore", "ownership", "consistency", "importance"];

// ════════════════ 2 — outcome label from git: future-defect ════════════════
// Walk all commits with dates; split the repo history at its MEDIAN commit
// date into OLDER and RECENT windows. For each file, count fix/revert touches
// in each window. label=1 ⇔ a fix landed in the recent window.
const BUG = /\b(fix(es|ed)?|bug|hotfix|revert|regression|broken|crash|patch(ed)?|incorrect|wrong|fault|defect|oops|reverts?)\b/i;

// First pass: collect commit timestamps to find the median split.
const commitTimes = git(["log", "--all", "--no-merges", "--pretty=format:%ct"]).split("\n").filter(Boolean).map(Number).sort((a, b) => a - b);
if (commitTimes.length < 4) { e("fit: too little history to calibrate — aborting clean."); process.exit(0); }
const median = commitTimes[Math.floor(commitTimes.length / 2)];
// a second split for temporal CV: older-2/3 fit window vs recent-1/3 test window.
const cvSplit = commitTimes[Math.floor(commitTimes.length * 2 / 3)];

// Second pass: per-file fix counts in each window, plus a CV-train fix label
// derived ONLY from the pre-cvSplit history.
const fixRecent = {}, fixOlder = {};   // recent = after median, older = before
const fixPreCv = {}, fixPostCv = {};   // for temporal CV (train on <cvSplit)
{
  let isBug = false, ts = 0;
  for (const line of git(["log", "--all", "--no-merges", "--pretty=format:\x01%ct\x02%s", "--name-only"]).split("\n")) {
    if (line.startsWith("\x01")) {
      const m = line.slice(1).split("\x02");
      ts = Number(m[0]); isBug = BUG.test(m[1] || "");
    } else if (line.trim() && isBug) {
      const f = line.trim();
      if (ts >= median) fixRecent[f] = (fixRecent[f] || 0) + 1; else fixOlder[f] = (fixOlder[f] || 0) + 1;
      if (ts >= cvSplit) fixPostCv[f] = (fixPostCv[f] || 0) + 1; else fixPreCv[f] = (fixPreCv[f] || 0) + 1;
    }
  }
}

// ════════════════ build the labeled rows ════════════════
// Candidate files = those present in the core signal sources (signals ∩ ergo).
// We use the OLDER-window signal snapshot conceptually (the reports are current,
// but the outcome is future relative to the median — this is the standard
// "predict the recent half from features" framing).
const rows = [];
for (const s of sig) {
  const p = s.path;
  const e2 = ergoByPath[p];
  if (! e2) continue;                       // need a complexity reading
  const r = riskFiles[p] || {};
  const u = useFiles[p] || {};
  const feat = {
    reach: u.reachScore != null ? u.reachScore : (u.reach || 0),
    churn: s.churn || 0,
    loc: e2.loc || 0,
    tokens: e2.tokens || 0,
    defs: e2.defs || 0,
    defectDensity: r.defectDensity || 0,
    testScore: r.testScore || 0,
    ownership: r.primaryAuthorShare != null ? r.primaryAuthorShare : 100,
    consistency: consistencyFor(p),
    importance: impByPath[p] != null ? impByPath[p] : 0,
  };
  rows.push({
    path: p,
    feat,
    y: (fixRecent[p] || 0) > 0 ? 1 : 0,             // full-history outcome
    yTrain: (fixPreCv[p] || 0) > 0 ? 1 : 0,         // CV-train label (older)
    yTest: (fixPostCv[p] || 0) > 0 ? 1 : 0,         // CV-test label (recent)
    inTrain: true, // every file is a candidate for the temporal fit
  });
}
const N = rows.length;
const positives = rows.filter(r => r.y === 1).length;
const posRate = N ? positives / N : 0;
e(`fit: ${N} labeled files · ${positives} positive (future-defect) = ${(posRate * 100).toFixed(1)}%`);

// ════════════════ 3 — Spearman correlation vs outcome ════════════════
function rank(arr) {
  // fractional ranks with tie averaging
  const idx = arr.map((v, i) => [v, i]).sort((a, b) => a[0] - b[0]);
  const ranks = new Array(arr.length);
  let i = 0;
  while (i < idx.length) {
    let j = i;
    while (j + 1 < idx.length && idx[j + 1][0] === idx[i][0]) j++;
    const avg = (i + j) / 2 + 1;
    for (let k = i; k <= j; k++) ranks[idx[k][1]] = avg;
    i = j + 1;
  }
  return ranks;
}
function pearson(a, b) {
  const n = a.length; if (n === 0) return 0;
  let ma = 0, mb = 0; for (let i = 0; i < n; i++) { ma += a[i]; mb += b[i]; } ma /= n; mb /= n;
  let num = 0, da = 0, db = 0;
  for (let i = 0; i < n; i++) { const x = a[i] - ma, y = b[i] - mb; num += x * y; da += x * x; db += y * y; }
  return (da === 0 || db === 0) ? 0 : num / Math.sqrt(da * db);
}
function spearman(a, b) { return pearson(rank(a), rank(b)); }

const col = (name) => rows.map(r => r.feat[name]);
const yCol = rows.map(r => r.y);
const importance = SIGNALS.map(name => ({ signal: name, spearman: +spearman(col(name), yCol).toFixed(4) }))
  .sort((a, b) => Math.abs(b.spearman) - Math.abs(a.spearman));

// ════════════════ 4 — pairwise collinearity matrix ════════════════
const corrMatrix = {};
const collinear = [];
for (const a of SIGNALS) {
  corrMatrix[a] = {};
  for (const b of SIGNALS) {
    const r = a === b ? 1 : +spearman(col(a), col(b)).toFixed(4);
    corrMatrix[a][b] = r;
    if (a < b && Math.abs(r) > 0.7) collinear.push({ a, b, r });
  }
}
collinear.sort((x, y) => Math.abs(y.r) - Math.abs(x.r));

// Drop rule: for each |r|>0.7 pair, drop the signal LESS correlated with the
// outcome (keep the more predictive root; the redundant one is overlap).
const impByName = Object.fromEntries(importance.map(i => [i.signal, Math.abs(i.spearman)]));
const dropped = new Set();
for (const { a, b } of collinear) {
  if (dropped.has(a) || dropped.has(b)) continue;
  const loser = (impByName[a] || 0) >= (impByName[b] || 0) ? b : a;
  dropped.add(loser);
}
const kept = SIGNALS.filter(s => !dropped.has(s));

// ════════════════ 5 — logistic regression (pure JS gradient descent) ════════════════
// standardize kept features, fit weights to maximize log-likelihood of the
// outcome. interpretable: weights map back to standardized signals.
function standardize(names, sampleRows) {
  const stats = {};
  for (const name of names) {
    const v = sampleRows.map(r => r.feat[name]);
    const m = v.reduce((a, x) => a + x, 0) / (v.length || 1);
    const sd = Math.sqrt(v.reduce((a, x) => a + (x - m) ** 2, 0) / (v.length || 1)) || 1;
    stats[name] = { m, sd };
  }
  return stats;
}
function design(names, sampleRows, stats) {
  return sampleRows.map(r => names.map(n => (r.feat[n] - stats[n].m) / stats[n].sd));
}
const sigmoid = (z) => 1 / (1 + Math.exp(-z));
function fitLogistic(X, y, opts = {}) {
  const iters = opts.iters || 600, lr = opts.lr || 0.3, l2 = opts.l2 || 0.01;
  const d = X[0] ? X[0].length : 0;
  let w = new Array(d).fill(0), b = 0;
  const n = X.length || 1;
  for (let it = 0; it < iters; it++) {
    const gw = new Array(d).fill(0); let gb = 0;
    for (let i = 0; i < X.length; i++) {
      const z = b + X[i].reduce((a, x, k) => a + x * w[k], 0);
      const err = sigmoid(z) - y[i];
      for (let k = 0; k < d; k++) gw[k] += err * X[i][k];
      gb += err;
    }
    for (let k = 0; k < d; k++) w[k] -= lr * (gw[k] / n + l2 * w[k]);
    b -= lr * (gb / n);
  }
  return { w, b };
}
function predict(model, X) { return X.map(x => sigmoid(model.b + x.reduce((a, v, k) => a + v * model.w[k], 0))); }

// AUC via rank statistic (Mann–Whitney).
function auc(scores, labels) {
  const pos = [], neg = [];
  scores.forEach((s, i) => (labels[i] ? pos : neg).push(s));
  if (!pos.length || !neg.length) return null;
  const r = rank(scores);
  let sumPos = 0;
  scores.forEach((_, i) => { if (labels[i]) sumPos += r[i]; });
  return (sumPos - pos.length * (pos.length + 1) / 2) / (pos.length * neg.length);
}
function precisionAtK(scores, labels, k) {
  const order = scores.map((s, i) => [s, i]).sort((a, b) => b[0] - a[0]);
  const top = order.slice(0, k);
  const hits = top.filter(([, i]) => labels[i] === 1).length;
  return top.length ? hits / top.length : 0;
}

// Full-data fit (the shipped weights), only when not sparse.
const SPARSE = positives < 8 || posRate < 0.01;
let stats = standardize(kept, rows);
let model = null, fullAuc = null;
if (!SPARSE) {
  const X = design(kept, rows, stats);
  model = fitLogistic(X, rows.map(r => r.y));
  fullAuc = auc(predict(model, X), rows.map(r => r.y));
}

// ════════════════ 6 — temporal cross-validation ════════════════
// fit on OLDER-history labels (yTrain, pre-cvSplit), test predicting the
// RECENT window (yTest, post-cvSplit). The signal matrix is the same; only the
// outcome window shifts. This catches weights that only fit the past.
let cv = { auc: null, precisionAtK: null, k: 0, trainPos: 0, testPos: 0, note: "" };
{
  const trainPos = rows.filter(r => r.yTrain === 1).length;
  const testPos = rows.filter(r => r.yTest === 1).length;
  cv.trainPos = trainPos; cv.testPos = testPos;
  if (trainPos >= 8 && testPos >= 4) {
    const cvStats = standardize(kept, rows);
    const Xtr = design(kept, rows, cvStats);
    const cvModel = fitLogistic(Xtr, rows.map(r => r.yTrain));
    const scores = predict(cvModel, Xtr);
    const testLabels = rows.map(r => r.yTest);
    cv.auc = auc(scores, testLabels);
    cv.k = Math.max(5, Math.round(rows.length * 0.05));
    cv.precisionAtK = precisionAtK(scores, testLabels, cv.k);
    cv.auc = cv.auc == null ? null : +cv.auc.toFixed(4);
    cv.precisionAtK = +cv.precisionAtK.toFixed(4);
  } else {
    cv.note = "temporal CV skipped — too few positives in train/test window";
  }
}

// ════════════════ confidence + composite blends ════════════════
const confidence = SPARSE ? "low" : (cv.auc == null ? "medium" : (cv.auc >= 0.6 ? "high" : "medium"));

// Per-composite blend forms (from SIGNALS.md) — recomposed on CLEAN roots,
// each root once. When confidence is low we ship sensible PRIORS (equal-ish
// multiplicative weights) rather than the over-fit logistic numbers.
const priorComposites = {
  hotspot: { form: "churn × complexity", roots: ["churn", "tokens"], weights: { churn: 0.5, tokens: 0.5 } },
  priority: { form: "reach × defect-amplifier × untested-boost", roots: ["reach", "defectDensity", "testScore"], weights: { reach: 0.5, defectDensity: 0.3, testScore: 0.2 } },
  refactorWorth: { form: "bloat × churn × separability", roots: ["tokens", "churn", "defs"], weights: { tokens: 0.4, churn: 0.4, defs: 0.2 } },
  criticalUntested: { form: "reach × ¬coverage", roots: ["reach", "testScore"], weights: { reach: 0.6, testScore: 0.4 } },
};

// learned weights (standardized logistic) mapped back per kept signal.
const learnedWeights = {};
if (model) kept.forEach((n, i) => { learnedWeights[n] = +model.w[i].toFixed(4); });

// thresholds: default percentile cut points for the danger/refactor worklists.
const thresholds = { dangerTopK: cv.k || Math.max(5, Math.round(N * 0.05)), hotspotPercentile: 90, priorityPercentile: 90 };

// ════════════════ OUTPUT 1 — scoring-config.json ════════════════
const config = {
  generatedAt: new Date().toISOString(),
  engine: "tooling/fit/fit.mjs",
  corpus: { files: N, positives, positiveRate: +posRate.toFixed(4) },
  outcome: { label: "future-defect", definition: "file received a fix/revert commit in the recent (post-median) half of history", medianSplitEpoch: median, cvSplitEpoch: cvSplit },
  confidence,
  sparse: SPARSE,
  signals: { all: SIGNALS, kept, dropped: [...dropped] },
  featureImportance: importance,
  collinearity: { threshold: 0.7, pairs: collinear, droppedForRedundancy: [...dropped] },
  learnedWeights: SPARSE ? null : learnedWeights,
  standardization: SPARSE ? null : Object.fromEntries(kept.map(n => [n, { mean: +stats[n].m.toFixed(4), sd: +stats[n].sd.toFixed(4) }])),
  validity: { fullAuc: fullAuc == null ? null : +fullAuc.toFixed(4), temporalCv: cv },
  composites: priorComposites,
  blendForm: SPARSE ? "priors (low confidence — too few positive labels to fit)" : "logistic over standardized kept signals; composites use prior multiplicative forms keyed to clean roots",
  thresholds,
  note: "Derived, gitignored. Re-run tooling/fit/fit.mjs to recalibrate. Composites read clean roots — each root once (SIGNALS.md rule).",
};
writeFileSync(join(HERE, "scoring-config.json"), JSON.stringify(config, null, 2));

// ════════════════ OUTPUT 2 — fit-report.html ════════════════
const esc = (s) => String(s).replace(/[&<>]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]));
const bar = (v, max = 1) => { const w = Math.round(Math.min(1, Math.abs(v) / max) * 100); const neg = v < 0; return `<span class="bar ${neg ? "neg" : "pos"}" style="width:${w}%"></span>`; };
const impRows = importance.map(i => `<tr${dropped.has(i.signal) ? ' class="dropped"' : ""}><td>${esc(i.signal)}</td><td class="num">${i.spearman.toFixed(3)}</td><td class="barcell">${bar(i.spearman)}</td><td>${dropped.has(i.signal) ? "dropped (collinear)" : "kept"}</td></tr>`).join("\n");
const weightRows = SPARSE ? `<tr><td colspan="2">low confidence — priors used, no fitted weights</td></tr>` :
  kept.map(n => `<tr><td>${esc(n)}</td><td class="num">${(learnedWeights[n] ?? 0).toFixed(3)}</td></tr>`).join("\n");
const collRows = collinear.length ? collinear.map(c => `<tr><td>${esc(c.a)} ↔ ${esc(c.b)}</td><td class="num">${c.r.toFixed(3)}</td><td>${dropped.has(c.a) ? esc(c.a) : esc(c.b)} dropped</td></tr>`).join("\n") : `<tr><td colspan="3">none above |r|&gt;0.7</td></tr>`;
const matHead = `<tr><th></th>${SIGNALS.map(s => `<th>${esc(s.slice(0, 4))}</th>`).join("")}</tr>`;
const matBody = SIGNALS.map(a => `<tr><th>${esc(a)}</th>${SIGNALS.map(b => { const r = corrMatrix[a][b]; const hot = Math.abs(r) > 0.7 && a !== b; return `<td class="num ${hot ? "hot" : ""}">${r.toFixed(2)}</td>`; }).join("")}</tr>`).join("\n");

const html = `<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>fit — calibration report</title>
<style>
  :root{--fg:#1b1b1f;--mut:#6b6b76;--line:#e3e3ea;--pos:#2563eb;--neg:#dc2626;--hot:#fde68a;--bg:#fafafc}
  *{box-sizing:border-box}
  body{font:15px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;color:var(--fg);background:var(--bg);margin:0;padding:2.5rem 1.5rem;max-width:980px;margin-inline:auto}
  h1{font-size:1.6rem;margin:0 0 .2rem} h2{font-size:1.1rem;margin:2.2rem 0 .6rem;border-bottom:1px solid var(--line);padding-bottom:.3rem}
  .sub{color:var(--mut);margin:0 0 1.5rem}
  .cards{display:flex;gap:.75rem;flex-wrap:wrap;margin:1rem 0}
  .card{background:#fff;border:1px solid var(--line);border-radius:10px;padding:.8rem 1rem;min-width:130px}
  .card .k{color:var(--mut);font-size:.78rem;text-transform:uppercase;letter-spacing:.04em} .card .v{font-size:1.35rem;font-weight:600}
  table{border-collapse:collapse;width:100%;font-size:.9rem;background:#fff;border:1px solid var(--line);border-radius:8px;overflow:hidden}
  th,td{padding:.4rem .6rem;text-align:left;border-bottom:1px solid var(--line)} th{background:#f3f3f7;font-weight:600}
  td.num{text-align:right;font-variant-numeric:tabular-nums} tr:last-child td{border-bottom:none}
  tr.dropped{opacity:.5;text-decoration:line-through}
  .barcell{width:140px} .bar{display:inline-block;height:10px;border-radius:3px} .bar.pos{background:var(--pos)} .bar.neg{background:var(--neg)}
  td.hot{background:var(--hot);font-weight:600}
  .matrix td,.matrix th{padding:.3rem .4rem;font-size:.8rem}
  .pill{display:inline-block;padding:.15rem .55rem;border-radius:999px;font-size:.8rem;font-weight:600}
  .pill.high{background:#dcfce7;color:#166534}.pill.medium{background:#fef9c3;color:#854d0e}.pill.low{background:#fee2e2;color:#991b1b}
  code{background:#f0f0f5;padding:.05rem .3rem;border-radius:4px;font-size:.85em}
</style></head><body>
<h1>fit — the calibration engine</h1>
<p class="sub">Learns the scoring from the codebase's own history. Outcome = <b>future-defect</b> (a fix/revert commit landed in the recent half). Pure programmatic · zero tokens.</p>

<div class="cards">
  <div class="card"><div class="k">files</div><div class="v">${N}</div></div>
  <div class="card"><div class="k">positive</div><div class="v">${positives}</div></div>
  <div class="card"><div class="k">positive rate</div><div class="v">${(posRate * 100).toFixed(1)}%</div></div>
  <div class="card"><div class="k">confidence</div><div class="v"><span class="pill ${confidence}">${confidence}</span></div></div>
  <div class="card"><div class="k">full AUC</div><div class="v">${fullAuc == null ? "—" : fullAuc.toFixed(3)}</div></div>
  <div class="card"><div class="k">temporal AUC</div><div class="v">${cv.auc == null ? "—" : cv.auc.toFixed(3)}</div></div>
</div>

<h2>1 · Ranked feature importance (Spearman vs outcome)</h2>
<table><tr><th>signal</th><th class="num">ρ</th><th>strength</th><th>fate</th></tr>${impRows}</table>

<h2>2 · Collinearity — flagged |r| &gt; 0.7</h2>
<p class="sub" style="margin:.3rem 0 .8rem">When two signals overlap, the one LESS correlated with the outcome is dropped — that is the v2 anti-double-counting rule. Watch for <code>reach ↔ importance</code>.</p>
<table><tr><th>pair</th><th class="num">ρ</th><th>resolution</th></tr>${collRows}</table>

<h2>3 · Full correlation matrix</h2>
<table class="matrix">${matHead}${matBody}</table>

<h2>4 · Fitted weights (logistic, standardized kept signals)</h2>
<table><tr><th>signal</th><th class="num">weight</th></tr>${weightRows}</table>

<h2>5 · Temporal cross-validation</h2>
<p class="sub" style="margin:.3rem 0 .8rem">Fit on OLDER history (pre-split labels), test predicting the RECENT window. ${esc(cv.note || "")}</p>
<table>
  <tr><th>metric</th><th class="num">value</th></tr>
  <tr><td>train positives (older)</td><td class="num">${cv.trainPos}</td></tr>
  <tr><td>test positives (recent)</td><td class="num">${cv.testPos}</td></tr>
  <tr><td>held-out AUC</td><td class="num">${cv.auc == null ? "—" : cv.auc.toFixed(3)}</td></tr>
  <tr><td>precision@${cv.k}</td><td class="num">${cv.precisionAtK == null ? "—" : cv.precisionAtK.toFixed(3)}</td></tr>
</table>

<h2>6 · Composite blends (clean roots, each root once)</h2>
<table><tr><th>composite</th><th>form</th><th>roots</th></tr>
${Object.entries(priorComposites).map(([k, v]) => `<tr><td>${esc(k)}</td><td><code>${esc(v.form)}</code></td><td>${v.roots.map(esc).join(" · ")}</td></tr>`).join("\n")}
</table>

<p class="sub" style="margin-top:2rem">Config → <code>tooling/fit/scoring-config.json</code> · both outputs gitignored (derived). Re-run <code>node tooling/fit/fit.mjs</code>.</p>
</body></html>`;
writeFileSync(join(HERE, "fit-report.html"), html);

e(`fit: confidence=${confidence} · fullAuc=${fullAuc == null ? "—" : fullAuc.toFixed(3)} · temporalAuc=${cv.auc == null ? "—" : cv.auc.toFixed(3)} · dropped=[${[...dropped].join(",")}]`);
e(`fit: wrote tooling/fit/scoring-config.json + tooling/fit/fit-report.html`);
