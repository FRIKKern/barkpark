// __smoke.mjs — the THIN INDEX runner for the decomposed pure-Node smoke suite.
//
// Was a 5275-line god-module (the converter round-trip + canvas projection/diff +
// node-view + echo + slash/palette + markdown + fuzz + source-mode harness). It is now
// a thin index: it imports every per-area module under src/smoke/, EACH of which
// registers + runs its check() blocks against the SHARED harness on import (the harness
// owns the one failures counter + the check() runner), then calls report() ONCE to print
// the aggregate summary and set the exit code (process.exit(1) on any failure). Run:
// node src/__smoke.mjs   (or: npm run smoke). Same total check count + same pass/fail +
// same exit semantics as the monolith — a behavior-preserving, test-only split.
//
// The split is purely MECHANICAL: every check moved VERBATIM (same name, body,
// assertions) into its area module; the cross-section helpers (check/report, applyOps/
// assertFolds, the seeded PRNG + generator vocabulary, canonical/normalize, project→
// reconstruct) live in src/smoke/harness.mjs; each section's own fixtures travel with it.
//
//   round-trip.mjs        S0 prose/marks/list round-trips + the S0 projector fold gates
//   node-views.mjs        S3.x divider/callout/code/diagram/field/sheet/embed projection
//   field-pickers.mjs     TAIL field-image/field-reference picker cases
//   echo.mjs              S4a server-echo reconcile + id-stamp
//   autocomplete-slash.mjs  S-slash direct-insert + P5 command-palette registry/fuzzy
//   projection-fuzz.mjs   the 1000+1000 load-identity / edit-fold property gates
//   markdown.mjs          the blocks⇄markdown converter cases + the 2000-iter fuzz
//   source-mode.mjs       P5 markdown source-mode realignment gates

import "./smoke/round-trip.mjs";
import "./smoke/node-views.mjs";
import "./smoke/field-pickers.mjs";
import "./smoke/echo.mjs";
import "./smoke/autocomplete-slash.mjs";
import "./smoke/projection-fuzz.mjs";
import "./smoke/markdown.mjs";
import "./smoke/source-mode.mjs";
import { report } from "./smoke/harness.mjs";

report();
