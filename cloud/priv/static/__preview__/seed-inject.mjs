// seed-inject.mjs — the SYNCHRONOUS half of a scenario's `seedLocal`.
//
// WHY THIS FILE EXISTS (task-a0258bec59b256d7)
// ────────────────────────────────────────────────────────────────────────────
// scenarios.mjs lets a scenario pre-seed localStorage before first paint:
//
//     "identity-iris": { …, seedLocal: { bp_theme: "iris" } }
//
// That is the ONLY mechanism GR12 ("the persisted identity wins") has. Until
// this file, `seedLocal` was honoured by smoke.mjs alone — its own comment said
// "Optional, smoke-only" — and mock.js, the BROWSER side, never read it at all.
// So every browser shot of identity-iris rendered the evergreen fallback, and
// under the accent axis (`ACCENT=… shoot.sh`, which appends `&accent=<id>`)
// mock.js wrote the SHOT's accent into the very key the scenario seeds. The
// scenario whose entire point is "iris is the ACTIVE state" was therefore
// byte-identical to shell-root at every one of the five accents — the matrix
// built to prove GR12 destroyed it. (Found by the gr-backlog-accent-matrix
// re-review, 2026-09-20.)
//
// WHY AN INJECTED TAG AND NOT AN IMPORT IN mock.js
// ────────────────────────────────────────────────────────────────────────────
// The seed MUST land before app.js's initBpTheme reads `bp_theme`, and app.js
// is a CLASSIC script that runs to completion the moment mock.js returns. A
// classic script cannot synchronously import an ES module, and mock.js's own
// `import("/__preview__/scenarios.mjs")` resolves a tick LATE — after app.js has
// already painted. So the data has to arrive as bytes in the HTML, ahead of
// mock.js. serve.mjs (which already injects mock.js in-flight and never edits
// index.html) emits the tag this file builds.
//
// mock.js then applies the seed AFTER its `?accent=` block, so the scenario
// wins the axis rather than the other way round. `grep -n '__PREVIEW_SEED_LOCAL'
// mock.js` is the consuming end.

import { SCENARIOS } from "./scenarios.mjs";

export const SEED_GLOBAL = "__PREVIEW_SEED_LOCAL";

// The scenario's seedLocal map, or null. DERIVED from scenarios.mjs on every
// call — never a copied list, so a scenario that gains or loses seedLocal is
// picked up without anyone editing this file.
export function seedLocalFor(name) {
  const scen = SCENARIOS[name];
  if (!scen || !scen.seedLocal) return null;
  const out = {};
  for (const k of Object.keys(scen.seedLocal)) out[k] = String(scen.seedLocal[k]);
  return Object.keys(out).length ? out : null;
}

// Every scenario that seeds localStorage — the population this seam serves.
// Used by the tests to prove the seam is non-vacuous (an empty population would
// make every assertion below pass over nothing).
export function seedingScenarios() {
  return Object.keys(SCENARIOS).filter((n) => seedLocalFor(n) !== null).sort();
}

// The scenario name carried by a request URL. serve.mjs sees the RAW url
// ("/?scen=identity-iris&accent=ember"); mock.js reads the same ?scen= out of
// location.search, so the two sides cannot disagree about which scenario this
// page is.
export function scenarioFromUrl(url) {
  const q = String(url || "").indexOf("?");
  if (q === -1) return null;
  const params = new URLSearchParams(String(url).slice(q + 1));
  return params.get("scen");
}

// The <script> tag to inject, or "" when this request seeds nothing.
//
// THE `</` ESCAPE IS LOAD-BEARING, not hygiene theatre: a seed VALUE containing
// the six characters `</scri` + `pt>` would otherwise close the tag early and
// the rest of the JSON would be parsed as HTML. Values come from a committed
// fixture today, which is exactly the reason to escape now rather than after
// someone seeds a value read from anywhere else.
export function seedInjectTag(name) {
  const seed = seedLocalFor(name);
  if (!seed) return "";
  const json = JSON.stringify(seed).replace(/</g, "\\u003c");
  return "<script>window." + SEED_GLOBAL + " = " + json + ";</script>\n    ";
}
