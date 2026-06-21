// Shared scoring thresholds — single source of truth.
//
// These were bare numeric literals duplicated across the suite (change one,
// forget the others, and two reports silently disagree). Consolidated here and
// imported where used. Found by dogfooding the cody bound-variable tool — its
// drift-detection lens surfaces exactly this class of magic-number duplication.

// FRAGILE_DENSITY — bug-fix density at/above which a file is flagged
// "defect-prone". Drives risk.mjs's summary AND quality.mjs's Reliability
// dimension. Was a 0.4 literal in risk.mjs + quality.mjs (×2). Tuned to 0.5:
// the top quartile (p75) of files carrying any defect history (0.4 flagged 13%
// of the codebase — too broad; 0.5 isolates the genuinely defect-dense set).
export const FRAGILE_DENSITY = 0.5;

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
