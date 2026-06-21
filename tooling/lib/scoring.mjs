// tooling/lib/scoring.mjs — the orthogonality engine (v2 Phase 2).
//
// One place computes the FOUR composites so quality.mjs and combine.mjs cannot
// drift apart on the SIGNALS.md rule: measure each ROOT once, compose only
// ACROSS roots. Every composite traces back so no root reaches a composite
// twice. Config-driven (tooling/fit/scoring-config.json — fitted weights /
// thresholds); when the file is absent or low-confidence we fall back to the
// sensible defaults baked in here. Dependency-free, no I/O side effects beyond
// reading the cached pass outputs.
//
//   import { loadConfig, gatherRoots, composites } from "../lib/scoring.mjs";
//
// Canonical roots (each owned by ONE pass — see tooling/SIGNALS.md):
//   reach     ← usefulness-report.json  (transitive dependents, 0–100)
//   churn     ← file-signals.json       (git change frequency)
//   tokens    ← ergonomics-report.json  (complexity / context-bloat)
//   defs      ← ergonomics-report.json  (separability proxy)
//   defect    ← risk-report.json        (defectDensity — where bugs land)
//   testScore ← risk-report.json        (coverage proxy / real coverage)

import { readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { DANGER_TOPK, HOTSPOT_PERCENTILE, PRIORITY_PERCENTILE } from "./thresholds.mjs";

const rd = (root, p, d) => existsSync(join(root, p)) ? JSON.parse(readFileSync(join(root, p), "utf8")) : d;

// ── defaults (used when the fit config is absent / low-confidence) ──────────
// Each composite keys ONLY clean roots, each root once. SIGNALS.md forms.
export const DEFAULT_COMPOSITES = {
  hotspot:          { form: "churn × complexity",                roots: ["churn", "tokens"],                 weights: { churn: 0.5, tokens: 0.5 } },
  priority:         { form: "reach × defect-amplifier × untested-boost", roots: ["reach", "defectDensity", "testScore"], weights: { reach: 0.5, defectDensity: 0.3, testScore: 0.2 } },
  refactorWorth:    { form: "bloat × churn × separability",      roots: ["tokens", "churn", "defs"],         weights: { tokens: 0.4, churn: 0.4, defs: 0.2 } },
  criticalUntested: { form: "reach × ¬coverage",                 roots: ["reach", "testScore"],              weights: { reach: 0.6, testScore: 0.4 } },
};
const DEFAULT_THRESHOLDS = { dangerTopK: DANGER_TOPK, hotspotPercentile: HOTSPOT_PERCENTILE, priorityPercentile: PRIORITY_PERCENTILE };

// ── config loader ───────────────────────────────────────────────────────────
// Returns { composites, thresholds, source, confidence }. When the config is
// missing or flagged low-confidence/sparse we keep its thresholds but fall back
// to default composite forms so the suite never depends on a fit run having
// happened. (The fitted weights are blended-in only when confidence is OK.)
export function loadConfig(root) {
  const cfg = rd(root, "tooling/fit/scoring-config.json", null);
  if (!cfg) return { composites: DEFAULT_COMPOSITES, thresholds: DEFAULT_THRESHOLDS, source: "defaults", confidence: "none" };
  const lowConf = cfg.confidence === "low" || cfg.sparse === true;
  const composites = (!lowConf && cfg.composites && Object.keys(cfg.composites).length)
    ? { ...DEFAULT_COMPOSITES, ...cfg.composites } // fitted forms win, defaults backfill any missing key
    : DEFAULT_COMPOSITES;
  const thresholds = { ...DEFAULT_THRESHOLDS, ...(cfg.thresholds || {}) };
  return { composites, thresholds, source: lowConf ? "defaults(low-confidence)" : "tooling/fit/scoring-config.json", confidence: cfg.confidence || "unknown" };
}

// ── gather the canonical roots, one map per file ────────────────────────────
// Every value is normalized into a 0–1 contribution so multiplicative
// composites are scale-free. The RAW values are kept too (for display / notes).
export function gatherRoots(root) {
  const reach = rd(root, "tooling/usefulness/usefulness-report.json", { files: {} }).files;
  const sig = {}; for (const s of rd(root, "tooling/file-importance/file-signals.json", { signals: [] }).signals) sig[s.path] = s;
  const erg = {}; for (const f of rd(root, "tooling/ergonomics/ergonomics-report.json", { files: [] }).files) erg[f.path] = f;
  const risk = rd(root, "tooling/risk/risk-report.json", { files: {} }).files;

  // union of every file any pass knows about
  const paths = new Set([...Object.keys(reach), ...Object.keys(sig), ...Object.keys(erg), ...Object.keys(risk)]);
  const out = {};
  for (const p of paths) {
    const u = reach[p] || {}, s = sig[p] || {}, e = erg[p] || {}, rk = risk[p] || {};
    out[p] = {
      reach: clamp01((u.reachScore ?? u.reach ?? 0) / 100),         // 0–100 → 0–1
      churn: sat(s.churn ?? e.churn ?? 0, 30),                       // commits → saturating
      tokens: sat(e.tokens ?? 0, 8000),                             // complexity / bloat
      defs: sat(e.defs ?? 0, 40),                                    // separability proxy
      defectDensity: clamp01(rk.defectDensity ?? 0),                // already 0–1
      testScore: clamp01((rk.testScore ?? 0) / 100),                // 0–100 → 0–1
      // raw passthroughs for display
      _raw: { reach: u.reachScore ?? u.reach ?? 0, churn: s.churn ?? e.churn ?? 0, tokens: e.tokens ?? 0, defs: e.defs ?? 0, defect: rk.defectDensity ?? 0, testScore: rk.testScore ?? 0, hasTest: !!rk.hasTest },
    };
  }
  return out;
}

// ── the four composites, computed from clean roots ──────────────────────────
// A weighted geometric-ish blend: each root contributes its (normalized value)
// raised to its weight, multiplied. Where the SIGNALS.md form negates a root
// (¬coverage), we use (1 − value). Output scaled to 0–100.
export function composites(rootsForFile, cfg) {
  const C = cfg.composites;
  const v = rootsForFile;
  const neg = (x) => 1 - x;

  const blend = (spec, transform = {}) => {
    let acc = 1, wsum = 0;
    for (const r of spec.roots) {
      const w = spec.weights[r] ?? 1 / spec.roots.length;
      let val = v[r] ?? 0;
      if (transform[r]) val = transform[r](val);
      acc *= Math.pow(Math.max(val, 1e-6), w);
      wsum += w;
    }
    // normalize the exponent base so weights that don't sum to 1 don't skew scale
    return Math.round(Math.pow(acc, wsum ? 1 / wsum : 1) * 100);
  };

  return {
    // HOTSPOT — churn × complexity (the refactor-target gold standard)
    hotspot: blend(C.hotspot),
    // PRIORITY — reach × defect-amplifier × untested-boost. testScore is INVERTED
    // (untested-boost = ¬coverage); defectDensity amplifies as-is.
    priority: blend(C.priority, { testScore: neg }),
    // REFACTOR-WORTH — bloat × churn × separability (more defs = harder to split → lower separability;
    // refactor-worth rises with bloat & churn, so defs enters inverted to mean "few seams, monolithic").
    refactorWorth: blend(C.refactorWorth, { defs: neg }),
    // CRITICAL-UNTESTED — reach × ¬coverage (the danger worklist)
    criticalUntested: blend(C.criticalUntested, { testScore: neg }),
  };
}

// ── helpers ──────────────────────────────────────────────────────────────────
function clamp01(x) { x = +x || 0; return x < 0 ? 0 : x > 1 ? 1 : x; }
// saturating normalizer: 0 → 0, `cap` → ~0.86, asymptotes to 1. Keeps a single
// god-module from dominating a multiplicative product.
function sat(x, cap) { x = +x || 0; if (x <= 0) return 0; return 1 - Math.exp(-x / cap); }

// percentile threshold over a numeric array
export function percentile(values, p) {
  if (!values.length) return 0;
  const s = [...values].sort((a, b) => a - b);
  const idx = Math.min(s.length - 1, Math.floor((p / 100) * s.length));
  return s[idx];
}
