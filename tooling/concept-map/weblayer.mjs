#!/usr/bin/env node
// weblayer.mjs — the single web-layer predicate, shared across the cqv8 passes.
//
// A feature→feature edge whose SOURCE file is a web-layer file is ORCHESTRATION,
// not a domain-coupling boundary violation: controllers and LiveViews legitimately
// compose multiple features. The grade pass (P3) excludes such edges from its
// sideways counter; the decycle proposer (P5) excludes them from the cycle
// analysis — both must agree on EXACTLY what "web-layer" means, so the predicate
// lives in one place and is imported by both. The match is anything under
// api/lib/barkpark_web/, plus the Phoenix web-role suffixes
// (*_controller.ex / *_live.ex / *_html.ex) wherever they live.
//
// Dependency-free. ESM, node: builtins only — pure path string predicate.

export function isWebLayerFile(file) {
  return (
    /^api\/lib\/barkpark_web\//.test(file) ||
    /(_controller|_live|_html)\.ex$/.test(file)
  );
}
