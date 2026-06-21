// Shared scoring thresholds — single source of truth.
//
// These were bare numeric literals duplicated across the suite (change one,
// forget the others, and two reports silently disagree). Consolidated here and
// imported where used. Found by dogfooding the cody bound-variable tool — its
// drift-detection lens surfaces exactly this class of magic-number duplication.

// FRAGILE_DENSITY — bug-fix density at/above which a file is flagged
// "defect-prone". Drives risk.mjs's summary AND quality.mjs's Reliability
// dimension. Was a 0.4 literal duplicated in risk.mjs + quality.mjs (×2).
// COUPLED to the defect-density formula (risk.mjs DEFECT_FORMULA): when that
// formula gained Laplace smoothing — fixes / (churn + 3) — the density scale
// shifted down, so this threshold was re-tuned 0.5 → 0.4 to keep ~the top
// decile of files-with-fixes (24 files), excluding the low-evidence noise the
// old formula over-flagged.
export const FRAGILE_DENSITY = 0.4;

// COLLINEARITY_CUT — |r| above which two signals are treated as collinear (the
// weaker is dropped). Was a 0.7 literal duplicated in fit.mjs as logic (×2) AND
// in its own self-reported `collinearity.threshold` — so the report could lie.
export const COLLINEARITY_CUT = 0.7;

// Default composite worklist cut-points. Duplicated as a literal object in BOTH
// lib/scoring.mjs (DEFAULT_THRESHOLDS fallback) and fit.mjs (emitted config) —
// the fallback and the emitter could drift apart. One source now.
export const HOTSPOT_PERCENTILE = 90;   // hotspot refactor line (churn × complexity)
export const PRIORITY_PERCENTILE = 90;  // priority worklist
export const DANGER_TOPK = 40;          // default top-K for the danger/critical worklist

// UNTESTED_SCORE — testScore below this marks a file "likely untested". Was a
// bare 40 in risk.mjs (the untested count) AND status/report.mjs (the red
// colour-coding) — change one, the count and the report disagree. One source.
export const UNTESTED_SCORE = 40;
