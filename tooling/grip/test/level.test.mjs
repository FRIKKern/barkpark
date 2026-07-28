// level.test.mjs — the real-invocation corpus for the authority-level grammar.
//
// The corpus is REAL flag-bearing invocations lifted from this repo's own
// evidence trails, not invented tidy ones. The acceptance bar that matters is
// ZERO FALSE DEMOTIONS of honest L1/L2 commands — a gate that punishes honest
// evidence gets routed around within a wave.
//
//   node --test tooling/grip/test/level.test.mjs

import { test } from "node:test";
import assert from "node:assert/strict";

import { readFileSync } from "node:fs";

import {
  deriveLevel,
  LEVELS,
  checkCeiling,
  classifyRef,
  isDiscretePredicate,
  GENERATED_ARTIFACT_PATTERNS,
  L3_HEADS,
  looksLikeProse,
} from "../level.mjs";
import { admitFact, findRefs, FACT_FIELDS } from "../record.mjs";

// --- export shape ------------------------------------------------------------

test("level.mjs exposes the named export surface and a frozen ladder", () => {
  assert.equal(typeof deriveLevel, "function");
  assert.equal(typeof checkCeiling, "function");
  assert.equal(typeof classifyRef, "function");
  assert.equal(typeof isDiscretePredicate, "function");
  assert.ok(Object.isFrozen(LEVELS));
  assert.deepEqual(Object.keys(LEVELS), ["L1", "L2", "L3", "L4", "L5", "L6"]);
  assert.ok(Object.isFrozen(GENERATED_ARTIFACT_PATTERNS));
  assert.ok(Array.isArray(FACT_FIELDS) && FACT_FIELDS.includes("rerun"));
});

// --- L1: zero false demotions on honest flag-bearing invocations -------------

test("ssh with flags between ssh and user@host derives L1 (the false-demotion regression)", () => {
  assert.equal(
    deriveLevel("ssh -o BatchMode=yes -o ConnectTimeout=8 root@89.167.28.206 'echo ok'"),
    "L1",
  );
});

test("ssh with -i identity flag derives L1", () => {
  assert.equal(
    deriveLevel("ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'systemctl is-active barkpark'"),
    "L1",
  );
});

test("curl to a non-loopback IP with write-out and max-time flags derives L1", () => {
  assert.equal(
    deriveLevel("curl -s -o /dev/null -w '%{http_code}' -m 10 http://89.167.28.206/api/schemas"),
    "L1",
  );
});

test("curl to a public DNS host behind a timeout wrapper derives L1", () => {
  assert.equal(
    deriveLevel("timeout 10 curl -fsS https://api.barkpark.cloud/v1/capabilities"),
    "L1",
  );
});

test("loopback curl does NOT derive L1 — it is a read of the local dev system", () => {
  const level = deriveLevel("curl -s http://localhost:4000/v1/capabilities");
  assert.notEqual(level, "L1");
  assert.equal(level, "L3");
  assert.notEqual(deriveLevel("curl -s http://127.0.0.1:4000/api/schemas"), "L1");
  assert.notEqual(deriveLevel("curl -s http://0.0.0.0:4000/api/schemas"), "L1");
});

// REGRESSION: the original host extractor stopped at the first colon, so
// http://[::1]:4000 yielded the host "[" — which is not loopback — and the
// grammar promoted a local dev-server read to L1. A ceiling set too high is
// precisely the level-skip this module exists to make impossible, so the IPv6
// loopback form is pinned in both the bracketed-with-port and bare shapes.
test("IPv6 loopback curl does NOT derive L1, bracketed and with a port", () => {
  assert.equal(deriveLevel("curl -s http://[::1]:4000/api/schemas"), "L3");
  assert.equal(deriveLevel("curl -s http://[::1]/api/schemas"), "L3");
  assert.equal(deriveLevel("wget -qO- http://[::1]:4000/v1/capabilities"), "L3");
});

test("a bracketed NON-loopback IPv6 host still derives L1", () => {
  assert.equal(deriveLevel("curl -s http://[2a01:4f9:c010:1234::1]/api/schemas"), "L1");
});

// --- L2 ----------------------------------------------------------------------

test("git show against a remote ref derives L2", () => {
  assert.equal(deriveLevel("git show origin/main:.github/workflows/doc-gates.yml"), "L2");
  assert.equal(deriveLevel("git show refs/remotes/origin/main:Makefile"), "L2");
});

test("gh api derives L2", () => {
  assert.equal(deriveLevel("gh api repos/FRIKKern/barkpark/pulls/4294 --jq .state"), "L2");
});

test("git show of a LOCAL ref is a local-checkout read: L3, not L2", () => {
  assert.equal(deriveLevel("git show HEAD:Makefile"), "L3");
});

// --- L3 ----------------------------------------------------------------------

test("scoped grep of a source file derives L3", () => {
  assert.equal(
    deriveLevel("grep -n 'def platform_admin_emails' cloud/lib/barkpark_cloud/notifications.ex"),
    "L3",
  );
});

test("node <script> derives L3 — a local run, even when the script EMITS artifacts", () => {
  assert.equal(deriveLevel("node design/emit.mjs"), "L3");
});

test("local test runs derive L3", () => {
  assert.equal(deriveLevel("go test ./internal/cli/..."), "L3");
  assert.equal(deriveLevel("node --test tooling/grip/test/level.test.mjs"), "L3");
});

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
  // exists to stop. Every splice target in ARTIFACTS is pinned here.
  const spliceTargets = [
    "cloud/priv/static/app.css",
    "cloud/priv/static/app.js",
    "cloud/priv/static/styleguide.html",
    "api/assets/paper-surface/paper-surface.css",
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

// --- L6 ----------------------------------------------------------------------

test("no rerun command derives L6 — demoted, never rejected", () => {
  assert.equal(deriveLevel(""), "L6");
  assert.equal(deriveLevel("   "), "L6");
  assert.equal(deriveLevel(undefined), "L6");
  assert.equal(deriveLevel(null), "L6");
});

test("an unclassifiable command demotes to L6 rather than guessing", () => {
  assert.equal(deriveLevel("frobnicate --all --please"), "L6");
});

// --- the grammar never reads the evidence prose ------------------------------

test("evidence prose full of L1/L2 markers with an empty rerun derives L6", () => {
  // The refuted prose scanner stamped L1 on strings like these. The grammar
  // takes only the rerun command — the markers in the narrative are inert.
  const admitted = admitFact({
    subject: "prod schemas endpoint",
    claim: "the deployed build serves /api/schemas",
    evidence:
      "OPEN — requires a run against the deployed build; curl http://89.167.28.206/api/schemas " +
      "returned served bytes matching origin/main per https://api.barkpark.cloud",
    rerun: "",
  });
  assert.equal(admitted.ok, true);
  assert.equal(admitted.fact.level, "L6");
});

test("a mention of an https:// literal inside a locally-read file cannot raise a local read above L3", () => {
  // The prose scanner stamped L1 on a source read whose file merely CONTAINED
  // an https:// literal. Leveling the command, a grep is L3 regardless of what
  // the file contents mention.
  assert.equal(
    deriveLevel("grep -n 'https://api.anthropic.com/v1/messages' js/packages/client/src/http.ts"),
    "L3",
  );
});

// --- the ceiling -------------------------------------------------------------

test("a claim above the derived level is REJECTED with LEVEL-SKIP naming both levels", () => {
  const verdict = checkCeiling("L1", "L3");
  assert.equal(verdict.ok, false);
  assert.equal(verdict.reason, "LEVEL-SKIP");
  assert.equal(verdict.claimed, "L1");
  assert.equal(verdict.derived, "L3");
  assert.match(verdict.message, /LEVEL-SKIP/);
  assert.match(verdict.message, /L1/);
  assert.match(verdict.message, /L3/);
});

test("a claim equal to the derived level is accepted", () => {
  assert.equal(checkCeiling("L3", "L3").ok, true);
});

test("an under-claim (below the ceiling) is accepted — honest modesty is kept", () => {
  assert.equal(checkCeiling("L4", "L3").ok, true);
  assert.equal(checkCeiling("L6", "L1").ok, true);
});

test("admitFact rejects a fact whose claimed level outranks its rerun command", () => {
  const rejected = admitFact({
    subject: "PLATFORM_ADMIN_EMAILS on prod",
    claim: "prod resolves platform admin emails",
    rerun: "grep -n 'def platform_admin_emails' cloud/lib/barkpark_cloud/notifications.ex",
    level: "L1",
  });
  assert.equal(rejected.ok, false);
  const skip = rejected.rejections.find((r) => r.reason === "LEVEL-SKIP");
  assert.ok(skip, "expected a LEVEL-SKIP rejection");
  assert.equal(skip.claimed, "L1");
  assert.equal(skip.derived, "L3");
});

test("admitFact keeps an honest under-claim", () => {
  const admitted = admitFact({
    subject: "prod schemas endpoint",
    claim: "the deployed build serves /api/schemas",
    rerun: "curl -s -o /dev/null -w '%{http_code}' -m 10 http://89.167.28.206/api/schemas",
    level: "L3",
  });
  assert.equal(admitted.ok, true);
  assert.equal(admitted.fact.level, "L3");
});

// --- PATHLESS-REF (D9) -------------------------------------------------------

test("a path-less line reference is REJECTED with PATHLESS-REF", () => {
  const verdict = classifyRef("notifications.ex:389-397");
  assert.equal(verdict.ok, false);
  assert.equal(verdict.reason, "PATHLESS-REF");
  assert.match(verdict.message, /PATHLESS-REF/);
});

test("a directory-bearing reference is accepted with parsed lines", () => {
  const verdict = classifyRef("cloud/lib/barkpark_cloud/notifications.ex:389-397");
  assert.equal(verdict.ok, true);
  assert.equal(verdict.path, "cloud/lib/barkpark_cloud/notifications.ex");
  assert.deepEqual(verdict.lines, { start: 389, end: 397 });
});

test("admitFact rejects a fact whose claim addresses code through a path-less ref", () => {
  const rejected = admitFact({
    subject: "notification admin gate",
    claim: "the admin gate lives at notifications.ex:389-397",
    rerun: "grep -n 'def platform_admin_emails' cloud/lib/barkpark_cloud/notifications.ex",
  });
  assert.equal(rejected.ok, false);
  assert.equal(rejected.rejections[0].reason, "PATHLESS-REF");
});

test("findRefs never reads the evidence field through admitFact", () => {
  // The same path-less ref in EVIDENCE prose is inert — evidence is not parsed.
  const admitted = admitFact({
    subject: "notification admin gate",
    claim: "the admin gate checks PLATFORM_ADMIN_EMAILS",
    evidence: "saw it around notifications.ex:389-397 somewhere",
    rerun: "grep -n 'def platform_admin_emails' cloud/lib/barkpark_cloud/notifications.ex",
  });
  assert.equal(admitted.ok, true);
});

// --- INADMISSIBLE-CONTINUOUS (D7) --------------------------------------------

test("a discrete observable is admissible", () => {
  assert.equal(isDiscretePredicate("http_code=200"), true);
  assert.equal(isDiscretePredicate("count=42 documents"), true);
});

test("a continuous measurement without a predicate is not discrete", () => {
  assert.equal(isDiscretePredicate("t_total 0.116"), false);
  assert.equal(isDiscretePredicate("latency was 0.135 seconds"), false);
});

test("a declared threshold collapses a continuous measurement to a discrete predicate", () => {
  assert.equal(isDiscretePredicate("t_total 0.116, admissible as t_total < 0.5"), true);
  assert.equal(isDiscretePredicate("response under 2.0 seconds"), true);
});

test("admitFact flags a predicate-less continuous quantity INADMISSIBLE-CONTINUOUS", () => {
  const rejected = admitFact({
    subject: "prod schemas endpoint latency",
    quantity: "t_total 0.116",
    claim: "the endpoint is fast",
    rerun: "curl -s -o /dev/null -w '%{time_total}' -m 10 http://89.167.28.206/api/schemas",
  });
  assert.equal(rejected.ok, false);
  assert.equal(rejected.rejections[0].reason, "INADMISSIBLE-CONTINUOUS");

  const admitted = admitFact({
    subject: "prod schemas endpoint latency",
    quantity: "t_total 0.116, predicate: t_total < 2.0",
    claim: "the endpoint answers within the budget",
    rerun: "curl -s -o /dev/null -w '%{time_total}' -m 10 http://89.167.28.206/api/schemas",
  });
  assert.equal(admitted.ok, true);
});

// --- the record itself -------------------------------------------------------

test("admitFact returns the full fact record with defaults applied", () => {
  const admitted = admitFact({
    subject: "doc-gates workflow on origin/main",
    claim: "doc-gates triggers on .ex/.go/.exs/.ts",
    rerun: "git show origin/main:.github/workflows/doc-gates.yml",
  });
  assert.equal(admitted.ok, true);
  const { fact } = admitted;
  assert.equal(fact.level, "L2");
  assert.deepEqual(fact.deps, []);
  assert.equal(typeof fact.observed_at, "string");
  assert.ok(!Number.isNaN(Date.parse(fact.observed_at)));
  for (const field of FACT_FIELDS) assert.ok(field in fact, `fact carries ${field}`);
});

test("admitFact rejects a subject-less or claim-less record with named reasons", () => {
  const rejected = admitFact({ rerun: "cat Makefile" });
  assert.equal(rejected.ok, false);
  const reasons = rejected.rejections.map((r) => r.reason).sort();
  assert.deepEqual(reasons, ["MISSING-CLAIM", "MISSING-SUBJECT"]);
});

// =============================================================================
// COMPOUND COMMANDS — the blind spot (charter D30)
// =============================================================================
//
// Everything above this line tests a SINGLE command. The suite had ZERO `&&`
// tests, so a green run proved nothing about the shape that dominates real
// evidence: `cd <path> && <command>`. That gap is why the Digest's three-word
// recommendation — add `bp`, `gh`, `cd` to L3_HEADS — read as safe.
//
// It was not. `deriveLevel` short-circuited on the FIRST head token, so
// blessing `cd` would have made `cd /opt/barkpark && curl https://prod/health`
// derive L3 — LOCAL-CHECKOUT authority for a command that reaches production,
// a two-level skip with no test able to see it. The fix walks every segment of
// the compound instead, and no wrapper is ever blessed with a level.

test("L3_HEADS blesses no wrapper — cd, for and env are NOT local-read heads", () => {
  // The naive fix, pinned as absent. If a future edit adds `cd` here, the
  // compound tests below are what will catch what it costs.
  assert.equal(L3_HEADS.has("cd"), false, "cd is navigation, not a read");
  assert.equal(L3_HEADS.has("for"), false, "for is a loop, not a read");
  assert.equal(L3_HEADS.has("env"), false, "env is a prefix wrapper, not a read");
  assert.equal(L3_HEADS.has("bp"), false, "bp is a remote-API client — L2, not L3");
  assert.equal(L3_HEADS.has("gh"), false, "gh is a remote-API client — L2, not L3");
});

test("cd + curl to a non-loopback host derives L1, not L3 and not L6", () => {
  // Pre-fix this was L6 (safe by accident: the head was `cd`). The naive
  // L3_HEADS fix would have made it L3 — authority INFLATION on a command that
  // provably reaches production. Neither is right: the compound touches a
  // running system, so its ceiling is L1.
  const level = deriveLevel("cd /opt/barkpark && curl https://guerrilla.barkpark.cloud/health");
  assert.equal(level, "L1");
  assert.equal(deriveLevel("cd api && curl -s -o /dev/null -w '%{http_code}' http://89.167.28.206/api/schemas"), "L1");
});

test("cd + wget to a non-loopback host derives L1", () => {
  assert.equal(deriveLevel("cd /opt/barkpark && wget -qO- https://guerrilla.barkpark.cloud/health"), "L1");
});

test("cd + LOOPBACK curl stays L3 — the local dev server is a checkout property", () => {
  assert.equal(deriveLevel("cd /opt/barkpark && curl -s http://localhost:4000/v1/capabilities"), "L3");
  assert.equal(deriveLevel("cd api && curl -s http://[::1]:4000/api/schemas"), "L3");
});

test("cd + ssh derives L1", () => {
  assert.equal(
    deriveLevel("cd /opt/barkpark && ssh -o BatchMode=yes root@157.180.90.121 'systemctl is-active barkpark'"),
    "L1",
  );
});

test("cd + gh api derives L2", () => {
  assert.equal(
    deriveLevel("cd /Volumes/SATECHI/github/barkpark && gh api repos/FRIKKern/barkpark/pulls/4294 --jq .state"),
    "L2",
  );
});

test("cd + bp derives L2", () => {
  assert.equal(
    deriveLevel('cd /Volumes/SATECHI/github/barkpark && bp search query "research coverage ledger"'),
    "L2",
  );
});

test("cd + a local test run derives L3 — the head is found PAST the wrapper", () => {
  assert.equal(
    deriveLevel("cd /Volumes/SATECHI/github/barkpark/api && CC=clang mix test test/barkpark_web/live/studio/connectors_live_test.exs 2>&1 | tail -20"),
    "L3",
  );
  assert.equal(deriveLevel("cd js && pnpm --filter @barkpark/react test"), "L3");
});

test("an env-assignment prefix does not hide the head", () => {
  assert.equal(deriveLevel("CC=clang MIX_ENV=test mix test test/barkpark/content/validation_test.exs"), "L3");
  assert.equal(deriveLevel("HCLOUD_TOKEN=fake curl -s https://api.hetzner.cloud/v1/servers"), "L1");
  assert.equal(deriveLevel("BARKPARK_TOKEN=bogus bp task get foo -o json"), "L2");
});

test("a for-loop wrapper does not hide the head — the `do` segment is levelled", () => {
  assert.equal(
    deriveLevel("for pr in 4566 4567; do gh pr view $pr --json number,state,mergedAt; done"),
    "L2",
  );
  assert.equal(
    deriveLevel('for f in internal/chat/testdata/*.json; do grep -c workflow_agent "$f"; done'),
    "L3",
  );
  assert.equal(
    deriveLevel("for host in a b; do curl -s https://guerrilla.barkpark.cloud/health; done"),
    "L1",
  );
});

test("the STRONGEST segment sets the ceiling — a pipe consumer never demotes a remote read", () => {
  // The standing bar is ZERO false demotions of honest L1/L2 commands. If the
  // weakest segment won, `curl <prod> | jq .` would derive L3 off `jq` and the
  // gate would start rejecting honest L1 claims — the fastest way to get a
  // gate routed around.
  assert.equal(deriveLevel("curl -s https://guerrilla.barkpark.cloud/v1/capabilities | jq .ok"), "L1");
  assert.equal(deriveLevel("gh pr list --state open --json number | jq length"), "L2");
  assert.equal(deriveLevel("cat Makefile && gh api repos/FRIKKern/barkpark --jq .name"), "L2");
});

test("an artifact read piped into a local consumer stays L4", () => {
  // L4 is a statement about the read's TARGET, not a rung competing with L1-L3.
  assert.equal(deriveLevel("cat docs/openapi.json | jq '.paths | keys'"), "L4");
  assert.equal(deriveLevel("cd /opt && cat docs/openapi.json | wc -l"), "L4");
  // ...but it never caps a remote read standing beside it.
  assert.equal(deriveLevel("cat docs/openapi.json && curl -s https://guerrilla.barkpark.cloud/health"), "L1");
});

test("a quoted operator does not split a segment, and a quoted URL is not a curl target", () => {
  // Quote-masking is what keeps the refuted prose scanner's failure mode dead:
  // a MENTIONED url can never reach the curl branch.
  assert.equal(deriveLevel("grep -n 'a && b' src/main.ts"), "L3");
  assert.equal(deriveLevel("grep -rn 'https://guerrilla.barkpark.cloud' api/lib/"), "L3");
  // A genuinely QUOTED curl target still counts — quotes on a real target are
  // ordinary shell hygiene, not a mention.
  assert.equal(deriveLevel("curl -s 'https://guerrilla.barkpark.cloud/v1/capabilities'"), "L1");
});

// =============================================================================
// bp and gh are REMOTE-API READS — L2 (charter D30 (c))
// =============================================================================

test("bp derives L2 — it reads the configured remote content server", () => {
  assert.equal(deriveLevel("bp task get foo -o json"), "L2");
  assert.equal(deriveLevel("bp doc ls tag -o json"), "L2");
  assert.equal(deriveLevel("bp search query 'scaffy engine reanchor' -o json"), "L2");
});

test("non-api gh derives L2, the level gh api already held", () => {
  assert.equal(deriveLevel("gh pr view 4159 --json state,mergeCommit,mergedAt"), "L2");
  assert.equal(deriveLevel("gh pr list --state open"), "L2");
  assert.equal(deriveLevel("gh run list --workflow elixir.yml --branch main --limit 5"), "L2");
  assert.equal(deriveLevel("gh issue view 1598 --json title,body"), "L2");
});

test("bp and gh are NOT L1 — they are not ssh and not a read of served bytes", () => {
  assert.notEqual(deriveLevel("bp task get foo -o json"), "L1");
  assert.notEqual(deriveLevel("gh pr view 4159 --json state"), "L1");
});

test("bp pointed at a LOOPBACK server is a local read: L3, mirroring loopback curl", () => {
  assert.equal(deriveLevel("bp -s http://localhost:4001 --token bp_admin_x cloud workspace export default"), "L3");
  assert.equal(deriveLevel("bp -s http://127.0.0.1:4077 task ready -o json"), "L3");
  // An EXPLICIT remote server is still L2, not a promotion.
  assert.equal(deriveLevel("bp -s https://guerrilla.barkpark.cloud task ready -o json"), "L2");
});

// =============================================================================
// THE PARSEABILITY FLOOR — prose can never be graded as evidence (D30 (d))
// =============================================================================
//
// 13.3% of the frozen corpus's rerun strings are prose, not commands. The
// grammar reads a head token and never asked whether the string PARSES, so any
// prose carrying a blessed token inherited that token's authority. Each
// specimen below is REAL — lifted from tooling/grip/fixtures/evidence-corpus.json
// — and each would have derived L2 or L3 through the segment walk above.

test("real prose specimens from the frozen corpus are floored at L6", () => {
  const specimens = [
    // would derive L3 off `python3`
    "python3 confusion matrix (15 per PREDICTED class, so per-class precision is unbiased)",
    // would derive L2 off `bp`
    "bp sites -o json | python3 (count)",
    // would derive L3 off a `grep`-shaped head
    "grep/read api/lib/barkpark/content/papers/template.ex around lines 200-219",
    // would derive L2 off `bp`
    "bp doc patch … --dry-run",
    // would derive L2 off `bp` — an unfilled optional-flag slot
    "bp onramp gemini-cli/zed --write [--force] --server https://guerrilla.barkpark.cloud",
    // would derive L3 off `mix` — a HUMAN EDIT stands between the reader and the run
    "probe: add migration_lock: false to Ecto.Migrator.up/down; mix test codelist_issue_version_test.exs --include flaky",
    // would derive L2 off `gh` — shorthand for four commands, not one
    "gh pr view 4631/4632/4633 --json state,mergedAt,mergeCommit",
    // would derive L3 off `git checkout` — an unfilled template slot
    "git checkout origin/main -- <55 files>; mix compile; CC=/usr/bin/clang MIX_ENV=test mix test --seed 111",
  ];
  for (const specimen of specimens) {
    assert.equal(deriveLevel(specimen), "L6", `prose must floor at L6: ${specimen}`);
  }
});

test("the floor demotes a REAL command carrying an unrunnable prose annotation", () => {
  // Both are real corpus rows. As literal strings neither runs: the
  // parenthetical would be executed as a subshell. What the grammar certifies
  // is re-derivability of THIS string (D4), so L6 is the honest answer — and
  // the ten-second fix is to delete the aside.
  assert.equal(deriveLevel("curl -s https://guerrilla.barkpark.cloud/papers/x (no auth header) | grep vs-003"), "L6");
  assert.equal(deriveLevel("node grip-mutation.mjs (section F)"), "L6");
});

test("the floor NEVER fires on an honest command — the cry-wolf controls", () => {
  // Every shape the floor could plausibly mistake for prose, pinned. A floor
  // that cries wolf gets routed around within a wave.
  const honest = [
    ["curl -s http://[::1]:4000/api/schemas", "L3"],                    // [ is not [--
    ["grep -n '[0-9]\\{3\\}' api/lib/foo.ex", "L3"],                    // a glob class
    ["go test ./internal/cli/...", "L3"],                               // trailing ... is a Go wildcard
    ["cat Makefile 2>&1 | tail -20", "L3"],                             // > without a closing >
    ["bp task --help < /dev/null", "L2"],                               // < without a closing >
    ["sort < in.txt > out.txt", "L3"],                                  // BOTH redirects in one segment
    ["diff -rq <(cat a) <(cat b) > /tmp/d.txt", "L3"],                  // process substitution + redirect
    ["node -e \"console.log(1 < 2 && 3 > 2)\"", "L3"],                  // quoted angles
    ["(cd __preview__ && node smoke.mjs | tail -1)", "L3"],             // a real subshell
    ["diff <(cat a.txt) <(cat b.txt)", "L3"],                           // process substitution
    ["jq '.paths | keys' docs/openapi.json", "L4"],                     // a quoted pipe
    ["ps aux | grep 'bp login' | grep -v grep", "L3"],                  // a 3-token unknown-head segment WITH flags
    ["frobnicate --all --please", "L6"],                                // unknown head, but flags: not prose
    ["S=$(head -1 run.log|cut -d' ' -f1); echo $S", "L3"],              // command substitution
  ];
  for (const [command, expected] of honest) {
    assert.equal(deriveLevel(command), expected, `must NOT be floored: ${command}`);
  }
});

test("looksLikeProse is exported and explains a demotion rather than only applying it", () => {
  assert.equal(typeof looksLikeProse, "function");
  assert.equal(looksLikeProse("bp sites -o json | python3 (count)"), true);
  assert.equal(looksLikeProse("bp sites -o json | jq length"), false);
});

// =============================================================================
// PURITY — deriveLevel stays pure, synchronous and clock-free
// =============================================================================

test("level.mjs imports nothing, shells out to nothing and reads no clock", () => {
  // A grammar that shells out could not run inside the in-loop gate, and one
  // that reads a clock is non-deterministic — the same command would level
  // differently on two runs, which is the drift this epic exists to abolish.
  const source = readFileSync(new URL("../level.mjs", import.meta.url), "utf8");
  const code = source
    .split("\n")
    .filter((line) => !line.trimStart().startsWith("//"))
    .join("\n");
  for (const forbidden of ["child_process", "execSync", "spawnSync", "Date.now", "new Date", "require(", "readFileSync", "await ", "async "]) {
    assert.equal(code.includes(forbidden), false, `level.mjs must not contain ${forbidden}`);
  }
  assert.equal(/^\s*import\s/m.test(code), false, "level.mjs must import nothing");
  // And it is deterministic: the same input levels the same twice.
  const command = "cd /opt/barkpark && curl https://guerrilla.barkpark.cloud/health";
  assert.equal(deriveLevel(command), deriveLevel(command));
});

test("deriveLevel never throws on hostile input", () => {
  for (const hostile of [null, undefined, 42, {}, [], "", "   ", "((((", "'unterminated", "&&&&", "|||", ";;;;", "<<<>>>", "\n\n\n"]) {
    const level = deriveLevel(hostile);
    assert.ok(Object.keys(LEVELS).includes(level), `${JSON.stringify(hostile)} → ${level}`);
  }
});

// ── THE PROSE FLOOR'S CRY-WOLF EDGE (added in review) ────────────────────────

test("a BACKSLASH-ESCAPED paren is a literal argument, not a prose aside", () => {
  // `find . \( -name a -o -name b \)` is an ordinary local read. The escaped
  // group read as a parenthetical whose first word (`-name`) is not a plausible
  // command head, so the floor demoted a good command L3 → L6.
  //
  // WHY THE MEASUREMENT COULD NOT SEE IT: zero occurrences in the 651-command
  // corpus, so the before/after distribution was bit-identical with the bug
  // present and with it fixed. That is the same blindness that hid the
  // `sort < in.txt > out.txt` cry-wolf. A corpus distribution is a LOWER BOUND
  // on cry-wolf; only probing the class by hand finds the rest.
  assert.equal(deriveLevel("find . \\( -name a -o -name b \\)"), "L3");
  assert.equal(deriveLevel("find api -type f \\( -name '*.ex' -o -name '*.exs' \\) -newer mix.exs"), "L3");

  // The floor must still fire on the shapes it exists for — the fix widens
  // nothing else. An UNESCAPED aside is still prose.
  assert.equal(deriveLevel("cd api && (Edit: add agent_state to the base map) && mix test"), "L6");
  assert.equal(deriveLevel("bp sites -o json | python3 (count)"), "L6");
  // …and a REAL subshell, opening on a known head, is still walked normally.
  assert.equal(deriveLevel("(cd __preview__ && node smoke.mjs)"), "L3");
});

test("the review's floor fix costs the corpus distribution nothing", () => {
  // The standing bar for any floor edit: it may not move a single one of the
  // 651 frozen commands. If a cry-wolf fix changes the distribution, it widened
  // the floor rather than narrowing it.
  const corpus = JSON.parse(readFileSync(new URL("../fixtures/evidence-corpus.json", import.meta.url), "utf8"));
  const commands = [...new Set(corpus.proofs.map((p) => p?.command).filter((c) => typeof c === "string" && c.trim()))];
  const dist = {};
  for (const c of commands) dist[deriveLevel(c)] = (dist[deriveLevel(c)] || 0) + 1;
  assert.equal(commands.length, 651);
  assert.deepEqual(dist, { L1: 32, L2: 93, L3: 380, L6: 146 });
});

test("KNOWN L1 SHAPES: the ssh forms the corpus actually uses are never demoted", () => {
  // The standing bar is ZERO false demotions of honest L1/L2 commands, and the
  // floor is the thing most able to break it. Every ssh row in the frozen
  // corpus uses `root@<host>`, and all of them must survive the walk.
  for (const cmd of [
    "ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'journalctl -u barkpark.service -n 15'",
    "ssh -o ConnectTimeout=15 root@178.105.92.191 'docker ps'",
    "ssh root@157.180.90.121 \"cd /opt/barkpark && git log -1 --format='%H'\"",
  ]) {
    assert.equal(deriveLevel(cmd), "L1", cmd);
  }
  // KNOWN GAP, pre-existing and unchanged by this wave: a BARE host alias with
  // no `user@` does not match SSH_READ and derives L6. D2 ratifies the level as
  // `ssh <user>@<host>`, so widening it is a PROMOTION rule change — the unsafe
  // direction — and belongs in a ruling, not in a review. Filed as
  // tgw3-bl-ssh-bare-host-alias. Pinned here so the gap is visible, not silent.
  assert.equal(deriveLevel("ssh guerrilla systemctl status barkpark"), "L6");
});

// --- mention-immunity for the OTHER blessed remote tokens --------------------
// The curl/wget branch was deliberately head-gated (see the https:// mention
// test above). SSH_READ / GIT_SHOW_REMOTE / GH_API were not: they were tested
// against the RAW segment, so a local grep that merely QUOTES a production
// command was promoted to L1/L2 — and record.mjs's admitFact then ACCEPTED an
// author's false L1 claim, defeating the ceiling. These pin the symmetry.

test("MENTION-IMMUNITY: a grep quoting an ssh command is L3, not L1", () => {
  assert.equal(deriveLevel(`grep -rn "ssh root@89.167.28.206" docs/ops/PROD_OPS.md`), "L3");
  assert.equal(deriveLevel(`rg -n 'ssh root@prod' docs/`), "L3");
  // unquoted, too — quote-masking alone cannot see this one
  assert.equal(deriveLevel(`grep -rn ssh root@host docs/`), "L3");
});

test("MENTION-IMMUNITY: a grep quoting `gh api` or `git show origin/…` is L3, not L2", () => {
  assert.equal(deriveLevel(`grep -n "gh api repos/x/y/pulls" docs/ops/merge-gates.md`), "L3");
  assert.equal(deriveLevel(`grep -n "git show origin/main:api/lib/foo.ex" docs/cards/js-sdk.md`), "L3");
  assert.equal(deriveLevel(`rg -n "git show origin/main:" docs/`), "L3");
});

test("MENTION-IMMUNITY does not demote a real invocation", () => {
  // the standing zero-false-demotion bar, for exactly the shapes now gated
  assert.equal(deriveLevel(`ssh root@89.167.28.206 "cd /opt/barkpark && git pull"`), "L1");
  assert.equal(deriveLevel(`cd /opt && ssh root@h uptime`), "L1");
  assert.equal(deriveLevel(`timeout 30 ssh root@h uptime`), "L1");
  assert.equal(deriveLevel(`gh api repos/o/r/pulls --jq .`), "L2");
  assert.equal(deriveLevel(`git show origin/main:api/mix.exs | head -20`), "L2");
  // a reader head with a PROCESS SUBSTITUTION really does read origin — the
  // corpus contains this shape and it must keep its L2.
  assert.equal(deriveLevel(`diff <(git show origin/main:a.md) a.md`), "L2");
});

test("MENTION-IMMUNITY: the ceiling holds — admitFact rejects a false L1 on a quoting grep", () => {
  const admitted = admitFact({
    subject: "docs/ops/PROD_OPS.md",
    claim: "the documented prod deploy host appears at docs/ops/PROD_OPS.md:17",
    evidence: "read the doc",
    rerun: `grep -rn "ssh root@89.167.28.206" docs/ops/PROD_OPS.md`,
    level: "L1",
  });
  assert.equal(admitted.ok, false);
  assert.equal(admitted.rejections[0].reason, "LEVEL-SKIP");
});
