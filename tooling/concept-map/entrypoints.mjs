#!/usr/bin/env node
// entrypoints.mjs — the single ENTRY-POINT predicate, shared across the cqv8 passes.
//
// An ENTRY-POINT is a file that ORCHESTRATES a feature rather than being a member
// of one: web-layer controllers/LiveViews (which compose multiple features per
// request), Mix CLI tasks under api/lib/mix/tasks/ (`mix onix.import`,
// `mix bokbasen.list`, … — `use Mix.Task` shells that drive a plugin from the
// command line) AND the OTP composition root, api/lib/barkpark/application.ex.
// A feature→feature edge whose SOURCE file is an entry-point is
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
// The Mix-task match is anything under api/lib/mix/tasks/. The composition-root
// match is the one exact path.
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

// OTP composition root: the `use Application` module whose start/2 assembles the
// supervision child list. Naming every supervised child IS what a composition
// root is for, so it mints one feature→feature edge per child — wiring, not
// domain coupling — which is the same orchestration shape as a Mix task, and the
// reason the baseline already grandfathered ten `application>*` edges rather than
// treating any of them as debt to pay down. Matched by EXACT path, not a
// `*application.ex` pattern: there is exactly one composition root in this repo,
// and a pattern would silently re-band any future file that happened to end in
// that name.
export function isCompositionRootFile(file) {
  return file === "api/lib/barkpark/application.ex";
}

// Entry-point: web-layer OR Mix-task OR composition root. The unified notion the
// passes filter on.
export function isEntryPoint(file) {
  return isWebLayerFile(file) || isMixTaskFile(file) || isCompositionRootFile(file);
}
