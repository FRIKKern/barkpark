#!/usr/bin/env node
// acceptance-p3.mjs — cqv8 Phase 3 acceptance gate. MUST PASS.
//
// Asserts the grade pass reproduces the spec's known findings — computed LIVE off
// the real symbol graph + on-disk test tree every run, never against frozen
// literals. Exits non-zero on any failed assertion so it can gate CI / the build.
//
//   node tooling/concept-map/acceptance-p3.mjs
//
// ── WHAT IT GUARANTEES (spec §5) ─────────────────────────────────────────────
//   1. GRATUITOUS-CORE — sheets' barkpark/sheets* core half is overwhelmingly
//      sheets-internal (the spec's ~233 internal vs ~7 external; we land ≈226 /
//      ≈14). External share is well under the 20% colocate threshold, so the gap
//      is FLAGGED gratuitous and sheets earns a named colocate edge.
//   2. SIDEWAYS — at least one real feature→feature cluster carries ≥ 10 edges
//      (the spec's thick boundary violations, e.g. media→search). That cluster
//      surfaces as a named cut edge on its concept's remediation list.
//   3. TEST-SCATTER — every real feature (sheets · onixedit · tasks · media ·
//      bulldocs) splits its tests across ≥ 2 distinct directories — the universal
//      flaw the grade measures, not a framework requirement.
//   4. VERDICTS — the kernel concepts (content, tenancy) grade `kernel` (not
//      feature-graded); sheets and onixedit — the CLEAN-FEATURE exemplars, clean
//      by coupling with only a minor note (sheets: gratuitous-core + scatter;
//      onixedit: its small →settings domain edge) — grade the new `improvable`
//      (NOT tangled, NOT clean); release and portable_doc — clean by the coupling
//      math but lacking the plugin registration surface, with NO sideways and NO
//      test-scatter — grade `clean-lib`. media / search / tasks keep `tangled`
//      (real cycles / sprawl). Verdict vocabulary is exactly
//      {kernel, clean, clean-lib, improvable, tangled}.
//   5. FIX-1 (web exclusion) — a feature→feature edge whose SOURCE file is a
//      web-layer file is orchestration, not a boundary violation, and is NOT
//      counted in the sideways tally. Asserted via media: its raw cross-concept
//      tally materially exceeds its domain-only tally (the ~22 controller-origin
//      media→search edges are dropped), and the media→search domain cluster is
//      strictly below the raw media→search cluster.
//   6. MANIFEST-ABSENCE — no per-feature manifest exists yet, so every concept is
//      flagged manifest-absent (P4 introduces the schema).
//
// Every expected value is a RANGE / structural assertion against a freshly
// computed result — no expected number is read from a fixture or hardcoded.

import { fileURLToPath } from "node:url";
import { runGrade, GRATUITOUS_EXTERNAL_PCT, REAL_SIDEWAYS_CLUSTER } from "./grade.mjs";

const res = runGrade();
const byName = new Map(res.concepts.map((c) => [c.concept, c]));

const failures = [];
const checks = [];

function get(name) {
  const c = byName.get(name);
  if (!c) failures.push(`concept "${name}" was not graded at all`);
  return c;
}

function ok(label, cond, detail) {
  checks.push({ label, ok: !!cond, detail });
  if (!cond) failures.push(`${label}: ${detail}`);
  return !!cond;
}

function inRange(label, value, lo, hi) {
  const good = value != null && value >= lo && value <= hi;
  checks.push({ label, ok: good, detail: `${fmt(value)} ∈ [${lo}, ${hi}]` });
  if (!good) failures.push(`${label}: ${fmt(value)} not in [${lo}, ${hi}]`);
  return good;
}

function fmt(v) {
  if (v == null) return "n/a";
  return Number.isInteger(v) ? String(v) : v.toFixed(2);
}

// ── 1. GRATUITOUS-CORE — sheets core half ~97% internal, flagged ─────────────
const sheets = get("sheets");
if (sheets) {
  const gc = sheets.gaps.gratuitousCore;
  // ground truth: ~233 internal vs ~7 external. Live computation lands ≈226/14;
  // assert generous ranges around that, never the exact number.
  inRange("sheets core-half internal inbound ~233", gc.internalInbound, 180, 280);
  inRange("sheets core-half external inbound ~7", gc.externalInbound, 0, 30);
  // the load-bearing claim: external share is far below the colocate threshold.
  ok(
    "sheets core-half external% < colocate threshold",
    gc.externalPct != null && gc.externalPct < GRATUITOUS_EXTERNAL_PCT,
    `external% = ${gc.externalPct == null ? "n/a" : gc.externalPct.toFixed(1)} (threshold ${GRATUITOUS_EXTERNAL_PCT})`
  );
  ok("sheets gratuitous-core FLAGGED", gc.gratuitous === true, `gratuitous = ${gc.gratuitous}`);
  // …and the flag produces a named colocate edge in the remediation.
  ok(
    "sheets carries a named colocate edge",
    sheets.remediation.colocate.length > 0,
    `colocate = ${JSON.stringify(sheets.remediation.colocate)}`
  );
}

// ── 2. SIDEWAYS — at least one real cluster with ≥ 10 edges ───────────────────
let maxCluster = { edges: 0, edge: "(none)" };
for (const c of res.concepts) {
  for (const s of c.gaps.sideways) {
    if (s.edges > maxCluster.edges) maxCluster = { edges: s.edges, edge: `${c.concept} → ${s.to}` };
  }
}
ok(
  "≥ 1 sideways cluster with ≥ 10 edges",
  maxCluster.edges >= 10,
  `largest = ${maxCluster.edge} (${maxCluster.edges} edges)`
);
// that thick cluster must also appear as a named cut edge on its concept.
ok(
  "largest sideways cluster surfaces as a named cut edge",
  res.concepts.some((c) => c.remediation.cut.some((x) => x.edges >= 10)),
  `cut edges with ≥10: ${res.concepts.flatMap((c) => c.remediation.cut.filter((x) => x.edges >= 10).map((x) => x.edge)).join(", ") || "(none)"}`
);

// ── 3. TEST-SCATTER — every real feature ≥ 2 test dirs ────────────────────────
const REAL_FEATURES = ["sheets", "onixedit", "tasks", "media", "bulldocs"];
for (const f of REAL_FEATURES) {
  const c = get(f);
  if (c) {
    ok(
      `test-scatter ≥ 2 for ${f}`,
      c.gaps.testScatter.testDirs.length >= 2,
      `${f} test dirs = ${c.gaps.testScatter.testDirs.length} [${c.gaps.testScatter.testDirs.join(", ")}]`
    );
  }
}

// ── 4. VERDICTS — kernel kernel; exemplars improvable; debt tangled ───────────
const content = get("content");
const tenancy = get("tenancy");
if (content) ok("content grades kernel", content.verdict === "kernel", `verdict = ${content.verdict}`);
if (tenancy) ok("tenancy grades kernel", tenancy.verdict === "kernel", `verdict = ${tenancy.verdict}`);

// the CLEAN exemplars: clean by coupling, only a minor fixable note → improvable.
// sheets keeps its gratuitous-core colocate edge; onixedit carries its small
// →settings domain cut edge. Neither is tangled debt; neither is pristine-clean.
const onixedit = get("onixedit");
if (sheets) {
  ok("sheets grades improvable (not tangled, not clean)", sheets.verdict === "improvable", `verdict = ${sheets.verdict}`);
  ok(
    "sheets keeps its named colocate edge",
    sheets.remediation.colocate.length > 0,
    `colocate = ${JSON.stringify(sheets.remediation.colocate)}`
  );
  ok(
    "sheets has no thick (≥ threshold) domain sideways cluster",
    sheets.gaps.sideways.every((s) => s.edges < REAL_SIDEWAYS_CLUSTER),
    `sideways = ${sheets.gaps.sideways.map((s) => `${s.to}:${s.edges}`).join(", ") || "(none)"} (threshold ${REAL_SIDEWAYS_CLUSTER})`
  );
}
if (onixedit) {
  ok("onixedit grades improvable (not tangled, not clean)", onixedit.verdict === "improvable", `verdict = ${onixedit.verdict}`);
  ok(
    "onixedit carries a small domain sideways cut edge below the knot threshold",
    onixedit.remediation.cut.length > 0 && onixedit.remediation.cut.every((x) => x.edges < REAL_SIDEWAYS_CLUSTER),
    `cut = ${onixedit.remediation.cut.map((x) => `${x.edge}:${x.edges}`).join(", ") || "(none)"} (threshold ${REAL_SIDEWAYS_CLUSTER})`
  );
}

// the clean-nonplugin pristine pair: release + portable_doc are clean by the
// coupling math, lack the plugin registration surface, and trip NO sideways and
// NO test-scatter — only (optionally) the excused gratuitous-core. They grade
// `clean-lib` (NOT improvable, NOT tangled) and carry no remediation.
const release = get("release");
const portableDoc = get("portable_doc");
if (release) {
  ok("release grades clean-lib", release.verdict === "clean-lib", `verdict = ${release.verdict}`);
  ok(
    "release has no real coupling problem (no sideways, single test home)",
    release.gaps.sideways.length === 0 && release.gaps.testScatter.testDirs.length <= 1,
    `sideways = ${release.gaps.sideways.length}, testDirs = ${release.gaps.testScatter.testDirs.length}`
  );
  ok(
    "release carries no remediation edges",
    release.remediation.colocate.length === 0 && release.remediation.cut.length === 0,
    `colocate=${release.remediation.colocate.length} cut=${release.remediation.cut.length}`
  );
}
if (portableDoc) {
  ok("portable_doc grades clean-lib", portableDoc.verdict === "clean-lib", `verdict = ${portableDoc.verdict}`);
  ok(
    "portable_doc has no real coupling problem (no sideways, single test home)",
    portableDoc.gaps.sideways.length === 0 && portableDoc.gaps.testScatter.testDirs.length <= 1,
    `sideways = ${portableDoc.gaps.sideways.length}, testDirs = ${portableDoc.gaps.testScatter.testDirs.length}`
  );
}

// media / search / tasks stay tangled — real domain cycles / sprawl, not rescued
// by Fix 1's web exclusion or the new improvable band.
const media = get("media");
const search = get("search");
const tasks = get("tasks");
if (media) {
  ok("media stays tangled (real sideways cluster)", media.verdict === "tangled", `verdict = ${media.verdict}`);
  ok(
    "media keeps a thick sideways cut edge (≥ knot threshold)",
    media.remediation.cut.some((x) => x.edges >= REAL_SIDEWAYS_CLUSTER),
    `cut = ${media.remediation.cut.map((x) => `${x.edge}:${x.edges}`).join(", ") || "(none)"}`
  );
}
if (search) ok("search stays tangled", search.verdict === "tangled", `verdict = ${search.verdict}`);
if (tasks) ok("tasks stays tangled", tasks.verdict === "tangled", `verdict = ${tasks.verdict}`);

const VOCAB = new Set(["kernel", "clean", "clean-lib", "improvable", "tangled"]);
ok(
  "verdict vocabulary is exactly {kernel, clean, clean-lib, improvable, tangled}",
  res.concepts.every((c) => VOCAB.has(c.verdict)),
  `verdicts = [${[...new Set(res.concepts.map((c) => c.verdict))].join(", ")}]`
);
// the verdict counts sum to total across the full five-word vocabulary.
ok(
  "verdict counts sum to total",
  res.counts.kernel + res.counts.clean + res.counts.cleanLib + res.counts.improvable + res.counts.tangled === res.counts.total,
  `${res.counts.kernel}+${res.counts.clean}+${res.counts.cleanLib}+${res.counts.improvable}+${res.counts.tangled} vs total ${res.counts.total}`
);

// ── 5. FIX-1 — web-layer source edges are NOT counted as sideways ─────────────
// media is the canonical web-inflated concept: ~22 of its 42 raw media→search
// edges originate in media_controller.ex / web params (orchestration). After the
// exclusion the domain tally is materially lower, and the media→search domain
// cluster is strictly below the raw media→search cluster.
if (media) {
  ok(
    "media domain cross-concept tally is materially below its raw tally",
    media.gaps.sidewaysDomainCrossConcept < media.gaps.sidewaysRawCrossConcept,
    `domain = ${media.gaps.sidewaysDomainCrossConcept}, raw = ${media.gaps.sidewaysRawCrossConcept}`
  );
  const rawSearch = (media.gaps.sidewaysRawClusters.find((c) => c.to === "search") || {}).edges || 0;
  const domSearch = (media.gaps.sideways.find((s) => s.to === "search") || {}).edges || 0;
  ok(
    "media→search domain cluster is strictly below the raw media→search cluster",
    domSearch > 0 && rawSearch > 0 && domSearch < rawSearch,
    `media→search domain = ${domSearch}, raw = ${rawSearch} (≈ ${rawSearch - domSearch} web-origin edges dropped)`
  );
}
// the kernel band is never feature-graded (no colocate/cut on a kernel concept).
ok(
  "kernel concepts carry no colocate/cut remediation",
  [content, tenancy].every((c) => !c || (c.remediation.colocate.length === 0 && c.remediation.cut.length === 0)),
  `content cut=${content ? content.remediation.cut.length : "-"}, tenancy cut=${tenancy ? tenancy.remediation.cut.length : "-"}`
);

// ── 6. MANIFEST-ABSENCE — no per-feature manifest exists yet ──────────────────
ok(
  "every concept flagged manifest-absent (none exist yet)",
  res.concepts.every((c) => c.gaps.manifestAbsent === true),
  `present manifests: [${res.concepts.filter((c) => !c.gaps.manifestAbsent).map((c) => c.concept).join(", ") || "none"}]`
);

// ── report ───────────────────────────────────────────────────────────────────
function run() {
  const out = (s) => process.stdout.write(s);
  out(
    `\ncqv8 P3 acceptance — ${res.graph.nodes} nodes · ${res.graph.edges} edges · ` +
      `${res.counts.tangled} tangled · ${res.counts.improvable} improvable · ` +
      `${res.counts.cleanLib} clean-lib · ${res.counts.clean} clean · ${res.counts.kernel} kernel\n`
  );
  out(`largest sideways cluster: ${maxCluster.edge} (${maxCluster.edges} edges)\n`);
  out(`${"─".repeat(64)}\n`);
  for (const c of checks) {
    out(`  ${c.ok ? "✓" : "✗"} ${c.label}\n      ${c.detail}\n`);
  }
  out(`${"─".repeat(64)}\n`);
  if (failures.length === 0) {
    out(`PASS — ${checks.length}/${checks.length} checks green\n\n`);
    process.exit(0);
  } else {
    out(`FAIL — ${failures.length} of ${checks.length} checks failed:\n`);
    for (const f of failures) out(`  ✗ ${f}\n`);
    out(`\n`);
    process.exit(1);
  }
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  run();
}
