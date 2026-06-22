#!/usr/bin/env node
// entrypoints.mjs — the single ENTRY-POINT predicate, shared across the cqv8 passes.
//
// An ENTRY-POINT is a file that ORCHESTRATES a feature rather than being a member
// of one: web-layer controllers/LiveViews (which compose multiple features per
// request) AND Mix CLI tasks under api/lib/mix/tasks/ (`mix onix.import`,
// `mix bokbasen.list`, … — `use Mix.Task` shells that drive a plugin from the
// command line). A feature→feature edge whose SOURCE file is an entry-point is
// ORCHESTRATION, not a domain-coupling boundary violation. The grade pass (P3)
// excludes such edges from its sideways counter; the decycle proposer (P5)
// excludes them from the cycle analysis — both must agree on EXACTLY what
// "entry-point" means, so the predicate lives in one place and is imported by
// both. Entry-point files are also kept OUT of feature-concept membership (the
// second-pass token-fold in concepts.mjs) so a Mix task whose path contains a
// feature token (e.g. api/lib/mix/tasks/onix.import.ex → "tasks") is not
// mis-counted as a member of that feature.
//
// The web match is anything under api/lib/barkpark_web/, plus the Phoenix
// web-role suffixes (*_controller.ex / *_live.ex / *_html.ex) wherever they live.
// The Mix-task match is anything under api/lib/mix/tasks/.
//
// Dependency-free. ESM, node: builtins only — pure path string predicates.

// Web-layer file: a Phoenix controller / LiveView / HTML view. Orchestrates
// features per request.
export function isWebLayerFile(file) {
  return (
    /^api\/lib\/barkpark_web\//.test(file) ||
    /(_controller|_live|_html)\.ex$/.test(file)
  );
}

// Mix CLI task: `use Mix.Task` shell under api/lib/mix/tasks/. Orchestrates a
// feature from the command line — an entry-point, not a feature member. Path
// detection is sufficient and robust (the directory is the Mix.Task convention).
export function isMixTaskFile(file) {
  return /^api\/lib\/mix\/tasks\//.test(file);
}

// Entry-point: web-layer OR Mix-task. The unified notion the passes filter on.
export function isEntryPoint(file) {
  return isWebLayerFile(file) || isMixTaskFile(file);
}
