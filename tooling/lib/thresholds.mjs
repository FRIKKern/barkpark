// Shared scoring thresholds — single source of truth.
//
// FRAGILE_DENSITY — bug-fix density at/above which a file is flagged
// "defect-prone". Drives risk.mjs's defect-prone summary AND quality.mjs's
// Reliability scorecard dimension. It was previously a bare `0.4` literal
// duplicated across risk.mjs and quality.mjs (×2) — change one, forget the
// others, and the two reports silently disagreed. Deduped here.
//
// Tuned to 0.5: the top quartile (p75) of files that carry any defect history.
// The old 0.4 flagged 88 files — 13% of the codebase — too broad to act on;
// 0.5 isolates the genuinely defect-dense files (70).
export const FRAGILE_DENSITY = 0.5;
