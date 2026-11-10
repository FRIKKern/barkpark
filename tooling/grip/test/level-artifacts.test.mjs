// level-artifacts.test.mjs — the authority-level grammar tests for
// L4: generated-artifact reads, design/emit.mjs emits, the marker-splice
// boundary, tooling/ emitter outputs.
//
// One of the level-*.test.mjs files the single level suite was split into by
// subject (task-f5ca1c7505824cc4). The tests moved unchanged.
//
//   node --test tooling/grip/test/level-artifacts.test.mjs

import { test } from "node:test";
import assert from "node:assert/strict";

import {
  deriveLevel,
} from "../level.mjs";

// --- L4 ----------------------------------------------------------------------

test("a read whose target is a known generated artifact derives L4", () => {
  assert.equal(deriveLevel("cat docs/openapi.json"), "L4");
  assert.equal(deriveLevel("jq '.paths | keys' docs/openapi.json"), "L4");
  assert.equal(deriveLevel("grep -c route tooling/quality/quality-report.json"), "L4");
  assert.equal(deriveLevel("diff a.golden.json b.golden.json"), "L4");
});

// --- L4: design/emit.mjs WHOLE-FILE emits ------------------------------------
//
// Each pattern below is proven in a PAIR: the real emitted path derives L4, and
// its closest hand-authored NEIGHBOUR — same directory, same extension — still
// derives L3. A pattern that cannot be shown to NOT fire is a pattern that
// cries wolf.

test("whole-file Go token emits derive L4; hand-authored Go beside them stays L3", () => {
  // design/emit.mjs ARTIFACTS, kind "go" — build() is the ENTIRE file body.
  assert.equal(deriveLevel("cat internal/semrole/tokens_gen.go"), "L4");
  assert.equal(deriveLevel("cat internal/semrole/chrome_gen.go"), "L4");
  assert.equal(deriveLevel("grep -n Accent internal/taskboard/tokens_gen.go"), "L4");
  assert.equal(deriveLevel("head -40 internal/pdrender/tokens_gen.go"), "L4");
  // NEAR MISS — same directory, hand-authored, must NOT be swallowed.
  assert.equal(deriveLevel("cat internal/semrole/semrole.go"), "L3");
  assert.equal(deriveLevel("grep -n func internal/semrole/semrole_test.go"), "L3");
});

test("whole-file Elixir token emits derive L4; hand-authored .ex beside them stays L3", () => {
  assert.equal(deriveLevel("cat api/lib/barkpark/portable_doc/render/tokens_gen.ex"), "L4");
  assert.equal(deriveLevel("grep -n defmodule api/lib/barkpark_web/studio/tokens_gen.ex"), "L4");
  // NEAR MISS — the hand-authored renderer one directory up, and a file whose
  // name merely ENDS in _<word>.ex (the splice target session_html.ex).
  assert.equal(deriveLevel("cat api/lib/barkpark/portable_doc/render.ex"), "L3");
  assert.equal(deriveLevel("cat api/lib/barkpark_web/controllers/session_html.ex"), "L3");
});

test("whole-file TS token emits derive L4; hand-authored .ts beside them stays L3", () => {
  assert.equal(deriveLevel("head -20 web/lib/tokens.gen.ts"), "L4");
  assert.equal(deriveLevel("cat templates/search-starter/lib/tokens.gen.ts"), "L4");
  // NEAR MISS — the same directory's hand-written modules.
  assert.equal(deriveLevel("cat web/lib/config.ts"), "L3");
  assert.equal(deriveLevel("grep -n export web/lib/barkpark-client.ts"), "L3");
});

// --- L4: the MARKER-SPLICE boundary ------------------------------------------

test("a marker-spliced hand-authored file is NOT L4 — it is partly source", () => {
  // design/emit.mjs kinds "css" and "html" splice a block between BEGIN/END
  // GENERATED markers inside a file whose identity, structure and majority of
  // bytes are hand-written. Levelling these L4 would DEFLATE the authority of
  // an honest source read — the mirror-image bug of the inflation this list
  // exists to stop. Each path below is a splice target in ARTIFACTS. The raw
  // sink api/assets/paper-surface/paper-surface.css is not: fragment 01 is.
  const spliceTargets = [
    "cloud/priv/static/app.css",
    "cloud/priv/static/app.js",
    "cloud/priv/static/styleguide.html",
    "api/assets/paper-editor/src/paper-surface/01-components-generated-theme.css",
    "api/lib/barkpark_web/layouts/root.html.heex",
    "api/lib/barkpark_web/layouts/bulldocs.html.heex",
    "api/lib/barkpark_web/layouts/sheets.html.heex",
    "api/lib/barkpark_web/controllers/session_html.ex",
    "api/lib/barkpark_web/controllers/error_html.ex",
    "api/lib/barkpark_web/controllers/status_controller.ex",
    "web/app/globals.css",
  ];
  for (const path of spliceTargets) {
    assert.equal(deriveLevel(`cat ${path}`), "L3", `${path} must stay L3 (marker splice, not a generated file)`);
  }
});

test("the phantom design/(dist|out|generated|emitted)/ branch is gone", () => {
  // It matched nothing design/emit.mjs has ever written; keeping it while the
  // real emits derived L3 was the authority inflation this slice removed.
  assert.equal(deriveLevel("cat design/dist/tokens.json"), "L3");
  assert.equal(deriveLevel("cat design/generated/tokens.css"), "L3");
});

// --- L4: tooling/ emitter outputs --------------------------------------------

test("the tooling report family covers its .html and .csv renderings too", () => {
  assert.equal(deriveLevel("cat tooling/consistency/consistency-report.html"), "L4");
  assert.equal(deriveLevel("cat tooling/combined/combined-report.csv"), "L4");
  assert.equal(deriveLevel("jq .rows tooling/combined/combined-report.json"), "L4");
  // NEAR MISS — the emitter's own source, and the human README beside it.
  assert.equal(deriveLevel("cat tooling/combined/combine.mjs"), "L3");
  assert.equal(deriveLevel("cat tooling/grip/README.md"), "L3");
});

test("named tooling emitter outputs derive L4; hand-authored config beside them stays L3", () => {
  // Each L4 path resolved from its emitter's output constant.
  const emitted = [
    "tooling/blast-radius/index.json",        // build-index.mjs:150 out
    "tooling/blast-radius/last-impact.json",  // check.mjs:152
    "tooling/blast-radius/verdict-cache.json", // dossier.mjs:33 CACHE_PATH
    "tooling/symbol-graph/symbols.json",      // build-symbols.mjs:435 out
    "tooling/map/manifest.json",              // manifest.mjs:28 MANIFEST
    "tooling/file-importance/file-signals.json", // build-signals.mjs:117
    "tooling/file-importance/file-batches.json", // build-signals.mjs:118
    "tooling/consistency/verdict-cache.json", // consistency.mjs:26 VCACHE
    "tooling/fit/scoring-config.json",        // fit.mjs:341
    "tooling/research-coverage/research-ledger.json", // coverage.mjs:24 LEDGER
    "tooling/barkpark-sync/nodes.json",       // generate.mjs:179
    "tooling/concept-map/boundary-baseline.json", // ci-boundary.mjs:53
  ];
  for (const path of emitted) {
    assert.equal(deriveLevel(`jq . ${path}`), "L4", `${path} is emitted — must derive L4`);
  }
  assert.equal(deriveLevel("cat tooling/file-importance/importance-chart.csv"), "L4");
  assert.equal(deriveLevel("cat tooling/barkpark-sync/codebase-graph.html"), "L4");

  // NEAR MISS — hand-authored JSON living in the SAME directories. These are
  // inputs to the emitters, not outputs, and must keep deriving L3.
  const handAuthored = [
    "tooling/blast-radius/config.json",
    "tooling/consistency/config.json",
    "tooling/cody/bindings.json",
    "tooling/doc-truth/doc-refs.json",
    "tooling/map/manifest.mjs",
    "tooling/symbol-graph/build-symbols.mjs",
  ];
  for (const path of handAuthored) {
    assert.equal(deriveLevel(`jq . ${path}`), "L3", `${path} is hand-authored — must stay L3`);
  }
});

test("the two-levels-deep fan-out directories derive L4; hand-authored fixtures stay L3", () => {
  // batches/ results/ review-batches/ dossiers/ are rmSync'd and rebuilt whole
  // on every run of their emitter.
  assert.equal(deriveLevel("cat tooling/intentions/review-batches/sub-001.json"), "L4");
  assert.equal(deriveLevel("cat tooling/usefulness/batches/batch-00.json"), "L4");
  assert.equal(deriveLevel("jq . tooling/consistency/results/_layering.json"), "L4");
  assert.equal(deriveLevel("cat tooling/blast-radius/dossiers/manifest.json"), "L4");
  // NEAR MISS — fixtures/ is ALSO two levels deep and ALSO .json, but is
  // hand-ratified input. level-skip-specimens.json in particular is read by
  // harvest.mjs and never written by it.
  assert.equal(deriveLevel("cat tooling/grip/fixtures/level-skip-specimens.json"), "L3");
  assert.equal(deriveLevel("cat tooling/doc-truth/fixtures/citation-corpus-2026-07.json"), "L3");
});

// The one census entry knowingly NOT applied — pinned so the gap is visible in
// the suite rather than living only in a backlog task. harvest.mjs WRITES
// evidence-corpus.json, so the census rule says L4; it is held at L3 because L4
// sits below L3 and promoting the rule mid-wave would reject the sibling
// slices' in-flight L3 citations of it. When tgw2-l4-grip-corpus-selfref is
// taken, this expectation flips to L4 and that is the intended change, not a
// regression — which is exactly why it is written down here.
test("the frozen corpus is knowingly held at L3 despite being an emitted artifact", () => {
  assert.equal(
    deriveLevel("cat tooling/grip/fixtures/evidence-corpus.json"),
    "L3",
    "held at L3 on purpose (tgw2-l4-grip-corpus-selfref) — see the KNOWN, DELIBERATE OMISSION note in level.mjs",
  );
});

test("the scalar hand-off .txt files derive L4 at their real depth only", () => {
  assert.equal(deriveLevel("cat tooling/intentions/batch-count.txt"), "L4");
  assert.equal(deriveLevel("cat tooling/intentions/review-count.txt"), "L4");
  assert.equal(deriveLevel("cat tooling/consistency/issues-stale.txt"), "L4");
  assert.equal(deriveLevel("cat tooling/intentions/taxonomy-input.txt"), "L4");
  // NEAR MISS — same basename one directory shallower is not an emitter output.
  assert.equal(deriveLevel("cat tooling/batch-count.txt"), "L3");
  assert.equal(deriveLevel("cat notes/batch-count.txt"), "L3");
});

test("regenerating an artifact is still a local run (L3), not an artifact read", () => {
  // The READER_HEADS gate: only reader-shaped heads can reach L4.
  assert.equal(deriveLevel("node tooling/symbol-graph/build-symbols.mjs"), "L3");
  assert.equal(deriveLevel("node tooling/map/manifest.mjs --write"), "L3");
});
