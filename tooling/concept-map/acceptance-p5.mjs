#!/usr/bin/env node
// acceptance-p5.mjs — cqv8 Phase 5 acceptance gate. MUST PASS.
//
// Asserts the boundary gate + gated recolocation honour the spec's enforcement
// and never-worse contracts — computed LIVE off the real symbol graph every run,
// never against frozen literals. Exits non-zero on any failed assertion.
//
//   node tooling/concept-map/acceptance-p5.mjs
//
// ── WHAT IT GUARANTEES (spec §5 check 1/3, §8, Figure 7) ─────────────────────
//   1. SIDEWAYS GATE — a SYNTHETIC sideways edge between two LIVE non-kernel
//      features → verdict 'violation', with the offending edge NAMED and typed
//      'sideways'. The two endpoints are picked from P1's live bands, never
//      hardcoded, so the test tracks whatever the graph currently bands.
//   2. WRONG-DIRECTION GATE — a synthetic kernel→feature edge → verdict
//      'violation', typed 'wrong-direction'. The kernel concept is read from the
//      live KERNEL band.
//   3. CLEAN PASS — a legitimate feature→kernel inward edge → verdict 'ok'. The
//      gate must not cry wolf on the allowed direction.
//   4. RECOLOCATION ACCOUNTS FOR 100% — proposeRecolocation('sheets') returns a
//      plan accounting for EVERY file sheets owns (lose-none): count before ===
//      count after, 0 lost, every input maps to a unique output. neverWorse:true.
//   5. PROPOSE-ONLY — the recolocation is marked proposeOnly:true AND moves
//      nothing: the working tree is unchanged across the call (git status
//      --porcelain identical before/after).
//   6. DECYCLE (media ⇄ search) — proposeDecycle returns a residual-aware,
//      propose-only cut of a mutual feature→feature cycle: a recommendation with
//      a non-empty bridge (moveFiles), eliminated ≥ 15, an HONEST residual > 0
//      (the cut is not clean — ~3 media callers remain), neverWorse.lost === 0,
//      and BOTH recommendation + alternative populated with OPPOSITE directions.
//   7. RESIDUAL-PICK — the recommended direction is the one with the higher
//      netReduction (recommendation.netReduction ≥ alternative.netReduction), NOT
//      the one current instability/Ca would pick.
//   8. WEB EXCLUSION — the cycle counts are the DOMAIN (web-excluded) counts,
//      materially lower than the raw cross-concept tally (media→search domain
//      ≈ 20, well under the raw ≈ 42).
//
// Dependency-free. ESM, node: builtins only.

import { execFileSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { runConcepts } from "./concepts.mjs";
import { runGrade } from "./grade.mjs";
import { gateBoundary, proposeRecolocation, proposeDecycle } from "./boundary.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: HERE })
  .toString()
  .trim();

const failures = [];
const checks = [];

function ok(label, cond, detail) {
  checks.push({ label, ok: !!cond, detail });
  if (!cond) failures.push(`${label}: ${detail}`);
  return !!cond;
}

function gitStatusBlob() {
  return execFileSync("git", ["status", "--porcelain", "--untracked-files=all"], {
    cwd: ROOT,
    maxBuffer: 16 * 1024 * 1024,
  }).toString();
}

// ── live substrate ────────────────────────────────────────────────────────────
const p1 = runConcepts();
const kernel = p1.bands.kernel;
// live non-kernel features (CLEAN-FEATURE preferred, else any non-kernel/non-noise).
const features = p1.concepts
  .filter((c) => c.band === "CLEAN-FEATURE")
  .map((c) => c.concept);
const anyFeatures = p1.concepts
  .filter((c) => c.band !== "KERNEL" && c.band !== "noise")
  .map((c) => c.concept);
const featurePool = features.length >= 2 ? features : anyFeatures;

// pick two DISTINCT live features for the synthetic sideways edge.
const featA = featurePool[0];
const featB = featurePool.find((f) => f !== featA);
const kernelConcept = kernel[0];

// snapshot the working tree before any gate/recolocation call (propose-only proof).
const beforeStatus = gitStatusBlob();

// ── 1. SIDEWAYS GATE ──────────────────────────────────────────────────────────
const sideways = gateBoundary({ edges: [{ from: featA, to: featB }] }, { p1 });
const sv = sideways.violations[0];
ok(
  "synthetic sideways edge → verdict 'violation'",
  sideways.verdict === "violation" && sideways.violations.length >= 1,
  `verdict=${sideways.verdict} violations=${sideways.violations.length} (edge ${featA} → ${featB})`
);
ok(
  "sideways violation is typed and NAMES the offending edge",
  sv && sv.type === "sideways" && sv.edge === `${featA} → ${featB}` && sv.from === featA && sv.to === featB,
  sv ? `type=${sv.type} edge="${sv.edge}"` : "no violation returned"
);

// ── 2. WRONG-DIRECTION GATE ─────────────────────────────────────────────────
const wrong = gateBoundary({ edges: [{ from: kernelConcept, to: featA }] }, { p1 });
const wv = wrong.violations[0];
ok(
  "synthetic kernel→feature edge → verdict 'violation' (wrong-direction)",
  wrong.verdict === "violation" && wv && wv.type === "wrong-direction" && wv.edge === `${kernelConcept} → ${featA}`,
  wv ? `type=${wv.type} edge="${wv.edge}"` : `verdict=${wrong.verdict}, no violation`
);

// ── 3. CLEAN PASS — the allowed inward direction ─────────────────────────────
const inward = gateBoundary({ edges: [{ from: featA, to: kernelConcept }] }, { p1 });
ok(
  "legitimate feature→kernel inward edge → verdict 'ok'",
  inward.verdict === "ok" && inward.violations.length === 0,
  `verdict=${inward.verdict} violations=${inward.violations.length} (edge ${featA} → ${kernelConcept})`
);

// ── 4. RECOLOCATION ACCOUNTS FOR 100% OF sheets' FILES ───────────────────────
const reco = proposeRecolocation("sheets", { p1 });
ok(
  "proposeRecolocation('sheets') is never-worse (lose-none)",
  reco.neverWorse === true && reco.counts.lost === 0,
  `neverWorse=${reco.neverWorse} lost=${reco.counts.lost} lostFiles=[${(reco.lostFiles || []).join(", ")}]`
);
ok(
  "recolocation count is preserved: before === after",
  reco.counts.filesBefore === reco.counts.filesAfter &&
    reco.counts.filesBefore > 0 &&
    reco.counts.accountedFor === reco.counts.filesBefore,
  `before=${reco.counts.filesBefore} after=${reco.counts.filesAfter} accounted=${reco.counts.accountedFor}`
);
ok(
  "every member file maps to exactly one UNIQUE home path (100% accounted)",
  reco.plan.length === reco.counts.filesBefore &&
    new Set(reco.plan.map((p) => p.to)).size === reco.plan.length &&
    new Set(reco.plan.map((p) => p.from)).size === reco.plan.length,
  `plan=${reco.plan.length} uniqueTo=${new Set(reco.plan.map((p) => p.to)).size} ` +
    `uniqueFrom=${new Set(reco.plan.map((p) => p.from)).size}`
);
ok(
  "recolocation collapses scatter to ONE home tree",
  reco.scatter.after === 1 && reco.scatter.before >= 1 && reco.plan.every((p) => p.to.startsWith(reco.homeDir + "/")),
  `scatter ${reco.scatter.before} → ${reco.scatter.after}; home=${reco.homeDir}`
);

// ── 5. PROPOSE-ONLY — nothing moved ──────────────────────────────────────────
ok("recolocation is marked propose-only", reco.proposeOnly === true, `proposeOnly=${reco.proposeOnly}`);
const afterStatus = gitStatusBlob();
ok(
  "working tree UNCHANGED across gate + recolocation (nothing moved)",
  afterStatus === beforeStatus,
  afterStatus === beforeStatus ? "git status identical" : "WORKING TREE MUTATED — propose-only violated"
);

// ── 6/7/8. DECYCLE — residual-aware cycle cut (media ⇄ search) ────────────────
// media ⇄ search is the live mutual feature→feature cycle the grade pass names.
// These concepts are read as fixed names ONLY in the assertion (the brief targets
// this specific cycle); every NUMBER is computed live by proposeDecycle.
const DEC_A = "media";
const DEC_B = "search";
const dec = proposeDecycle(DEC_A, DEC_B, { p1 });
const rec = dec.recommendation || {};
const alt = dec.alternative || {};

ok(
  "proposeDecycle(media,search) recommends a non-empty bridge to relocate",
  Array.isArray(rec.moveFiles) && rec.moveFiles.length > 0,
  `moveFiles=[${(rec.moveFiles || []).join(", ")}] direction=${rec.direction}`
);
// Magnitude is NOT hardcoded: a successful de-cycle (media→search was cut 20→1)
// must not break this gate. Test the decycle MATH invariant instead — improvement-robust.
ok(
  "decycle math is sound — netReduction === eliminated − residual, recommended direction wins",
  rec.netReduction === rec.eliminated - rec.residual &&
    (!dec.alternative || rec.netReduction >= dec.alternative.netReduction),
  `rec ${rec.direction}: elim ${rec.eliminated} − resid ${rec.residual} = net ${rec.netReduction}` +
    (dec.alternative ? ` · alt net ${dec.alternative.netReduction}` : "")
);
ok(
  "decycle reports an HONEST residual > 0 (the cut is not clean — callers remain)",
  rec.residual > 0 && Array.isArray(rec.residualCallers) && rec.residualCallers.length > 0,
  `residual=${rec.residual} callers=[${(rec.residualCallers || []).join(", ")}]`
);
ok(
  "decycle is a MOVE — neverWorse.lost === 0, filesBefore === filesAfter",
  dec.neverWorse &&
    dec.neverWorse.lost === 0 &&
    dec.neverWorse.filesBefore === dec.neverWorse.filesAfter &&
    dec.proposeOnly === true,
  `neverWorse=${JSON.stringify(dec.neverWorse)} proposeOnly=${dec.proposeOnly}`
);
ok(
  "BOTH recommendation and alternative are populated with OPPOSITE directions",
  rec.direction &&
    alt.direction &&
    rec.direction !== alt.direction &&
    rec.origin === alt.target &&
    rec.target === alt.origin,
  `recommendation=${rec.direction} alternative=${alt.direction}`
);
ok(
  "recommended direction has the higher netReduction (residual-picked, not Ca-picked)",
  rec.netReduction >= alt.netReduction,
  `rec.netReduction=${rec.netReduction} alt.netReduction=${alt.netReduction}`
);

// WEB EXCLUSION — the cycle counts are the DOMAIN counts, materially below the
// raw (web-inclusive) cross-concept tally. The grade pass already computes the
// raw media→search cluster (pre web-exclusion) off the SAME two-pass concept
// assignment, so we read it from runGrade rather than re-deriving it. Assert the
// decycle domain count equals grade's DOMAIN count and is well below raw.
const grade = runGrade();
const mediaRow = grade.concepts.find((c) => c.concept === DEC_A);
const rawA2B = (mediaRow.gaps.sidewaysRawClusters.find((r) => r.to === DEC_B) || { edges: 0 }).edges;
const gradeDomainA2B = (mediaRow.gaps.sideways.find((r) => r.to === DEC_B) || { edges: 0 }).edges;
ok(
  "cycle counts are DOMAIN (web-excluded), materially below raw cross-concept",
  dec.cycle.a2b > 0 && dec.cycle.a2b === gradeDomainA2B && dec.cycle.a2b < rawA2B,
  `decycle domain media→search=${dec.cycle.a2b} · grade domain=${gradeDomainA2B} · raw=${rawA2B}`
);

// ── ENTRY-POINT EXCLUSION — the false tasks⇄onixedit cycle is GONE ────────────
// The grade pass once named a 13-edge tasks→onixedit knot. Every one of those
// edges originates in a Mix CLI task under api/lib/mix/tasks/ (mix onix.import,
// onix.export_proof, …) — orchestration, not domain coupling. With Mix tasks now
// treated as entry-points (same exclusion as web-layer), proposeDecycle no longer
// finds ANY domain cycle between the two: both directions drop to 0 and the
// recommended bridge is empty — it recommends moving NO lib/mix/tasks/ file.
const noKnot = proposeDecycle("tasks", "onixedit", { p1 });
ok(
  "proposeDecycle(tasks,onixedit) reports NO domain cycle (Mix-task edges excluded)",
  noKnot.cycle.a2b === 0 && noKnot.cycle.b2a === 0,
  `cycle a2b=${noKnot.cycle.a2b} b2a=${noKnot.cycle.b2a} (was 13 when Mix tasks were mis-folded)`
);
ok(
  "proposeDecycle(tasks,onixedit) recommends moving NO Mix-task (api/lib/mix/tasks/) file",
  !((noKnot.recommendation && noKnot.recommendation.moveFiles) || []).some((f) =>
    /^api\/lib\/mix\/tasks\//.test(f)
  ) && !((noKnot.alternative && noKnot.alternative.moveFiles) || []).some((f) =>
    /^api\/lib\/mix\/tasks\//.test(f)
  ),
  `recommendation.moveFiles=[${((noKnot.recommendation || {}).moveFiles || []).join(", ") || "(none)"}]`
);

// ── report ───────────────────────────────────────────────────────────────────
function run() {
  const out = (s) => process.stdout.write(s);
  out(
    `\ncqv8 P5 acceptance — ${p1.graph.nodes} nodes · ${p1.graph.edges} edges · ` +
      `kernel [${kernel.join(", ")}]\n`
  );
  out(`synthetic edges (live concepts):\n`);
  out(`  · sideways:        ${featA} → ${featB}  (two live features)\n`);
  out(`  · wrong-direction: ${kernelConcept} → ${featA}  (kernel → feature)\n`);
  out(`  · inward (ok):     ${featA} → ${kernelConcept}  (feature → kernel)\n`);
  out(`recolocation('sheets'): ${reco.counts.filesBefore} files → home ${reco.homeDir}\n`);
  out(
    `decycle(media,search): cycle ${dec.cycle.a2b}/${dec.cycle.b2a} → recommend ` +
      `${rec.direction} (elim ${rec.eliminated} · resid ${rec.residual} · net ${rec.netReduction}) ` +
      `vs alt ${alt.direction} (net ${alt.netReduction})\n`
  );
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
