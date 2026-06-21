#!/usr/bin/env node
// acceptance-p4.mjs — cqv8 Phase 4 acceptance gate. MUST PASS.
//
// Asserts the manifest + scaffold reproduce the spec's generative-first,
// propose-only contract — computed LIVE off the real symbol graph every run,
// never against frozen literals. Exits non-zero on any failed assertion.
//
//   node tooling/concept-map/acceptance-p4.mjs
//
// ── WHAT IT GUARANTEES (spec §6, Figure 6) ───────────────────────────────────
//   1. FEATURE-FOLDER — `new pricing` (no kernel touches) projects LOW afferent
//      coupling → FEATURE-FOLDER, carrying the learned role-set (the recurring
//      skeleton P2 derived: core · registration · test · controller · live …).
//      The roles are NOT invented here — they are read back from runAnatomy().
//   2. CROSS-FOLDER — `new billing-core --touches content,tenancy` touches the
//      LIVE kernel band → projects HIGH afferent coupling → CROSS-FOLDER. The
//      kernel concepts are read from P1, never hardcoded.
//   3. PROPOSE-ONLY — after both scaffolds, NOTHING was written outside
//      tooling/concept-map/.scaffold-staging/. Verified via `git status
//      --porcelain` over the whole repo: every changed/untracked path must sit
//      under the staging tree.
//   4. MANIFEST VALIDATES — a manifest synthesized for a real existing concept
//      (an exemplar) validates against P4's schema, and the scaffold stub
//      manifests for both new concepts validate too.
//
// Dependency-free. ESM, node: builtins only.

import { execFileSync } from "node:child_process";
import { rmSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { runConcepts } from "./concepts.mjs";
import { runAnatomy } from "./anatomy.mjs";
import { synthesizeManifest, validateManifest } from "./manifest.mjs";
import { runScaffold } from "./scaffold.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: HERE })
  .toString()
  .trim();

const STAGING_REL = "tooling/concept-map/.scaffold-staging";

const failures = [];
const checks = [];

function ok(label, cond, detail) {
  checks.push({ label, ok: !!cond, detail });
  if (!cond) failures.push(`${label}: ${detail}`);
  return !!cond;
}

// Clean the staging tree first so the run is hermetic and the git-status check
// measures only THIS run's writes. The staging tree is gitignored/disposable.
function cleanStaging() {
  const dir = join(ROOT, STAGING_REL);
  if (existsSync(dir)) rmSync(dir, { recursive: true, force: true });
}

// Every path the repo's working tree changed (tracked or untracked), relative to
// ROOT. Used to prove propose-only: nothing outside staging may appear here as a
// NEW change introduced by the scaffold run.
function gitStatusPaths() {
  const out = execFileSync("git", ["status", "--porcelain", "--untracked-files=all"], {
    cwd: ROOT,
    maxBuffer: 16 * 1024 * 1024,
  }).toString();
  const paths = [];
  for (const line of out.split("\n")) {
    if (!line.trim()) continue;
    // porcelain: XY <path>  (or "XY orig -> new" for renames)
    let p = line.slice(3);
    const arrow = p.indexOf(" -> ");
    if (arrow !== -1) p = p.slice(arrow + 4);
    paths.push(p.replace(/^"|"$/g, ""));
  }
  return paths;
}

// ── run ──────────────────────────────────────────────────────────────────────
cleanStaging();

// snapshot working-tree changes BEFORE the scaffold run, so we only judge the
// NEW paths this run introduces (the repo may have other unrelated edits).
const before = new Set(gitStatusPaths());

const p1 = runConcepts();
const anatomy = runAnatomy();

// learned recurring role-set, straight from P2 — the ground truth for check 1.
const learnedRecurring = anatomy.roles.filter((r) => r.recurring).map((r) => r.role);

// ── 1. FEATURE-FOLDER: `new pricing` ─────────────────────────────────────────
const pricing = runScaffold("pricing", [], { p1, anatomy });
ok(
  "pricing → FEATURE-FOLDER",
  pricing.template === "feature-folder",
  `template = ${pricing.template} (touched kernel: [${pricing.projection.touchedKernel.join(", ")}])`
);
// it carries the LEARNED role-set — every recurring role P2 derived is present.
const pricingRoles = new Set(pricing.roles);
const missingLearned = learnedRecurring.filter((r) => !pricingRoles.has(r));
ok(
  "pricing carries the learned role-set",
  missingLearned.length === 0,
  `learned recurring = [${learnedRecurring.join(", ")}]; scaffold roles = [${pricing.roles.join(", ")}]` +
    (missingLearned.length ? `; MISSING [${missingLearned.join(", ")}]` : "")
);
// and the file plan instantiates those roles colocated under one feature folder.
ok(
  "pricing files colocated under one feature folder",
  pricing.plannedFiles.length > 0 &&
    pricing.plannedFiles.every((f) => f.path.includes(`${STAGING_REL}/pricing/feature/`)),
  `paths = [${pricing.plannedFiles.map((f) => f.path.replace(STAGING_REL + "/pricing/", "")).join(", ")}]`
);
ok("pricing manifest validates", pricing.manifestValid === true, `valid = ${pricing.manifestValid}`);

// ── 2. CROSS-FOLDER: `new billing-core --touches content,tenancy` ────────────
const billing = runScaffold("billing-core", ["content", "tenancy"], { p1, anatomy });
ok(
  "billing-core → CROSS-FOLDER",
  billing.template === "cross-folder",
  `template = ${billing.template} (touched kernel: [${billing.projection.touchedKernel.join(", ")}])`
);
// the touched kernel concepts are the LIVE kernel band, not hardcoded.
const kernelBand = new Set(p1.bands.kernel);
ok(
  "billing-core touched concepts are the live kernel band",
  ["content", "tenancy"].every((c) => kernelBand.has(c)) &&
    billing.projection.touchedKernel.length === 2,
  `live kernel = [${[...kernelBand].join(", ")}]; touchedKernel = [${billing.projection.touchedKernel.join(", ")}]`
);
// cross-folder spreads roles across layered trees (web / domain / test), not one.
const trees = new Set(
  billing.plannedFiles
    .filter((f) => f.role !== "manifest")
    .map((f) => f.path.replace(STAGING_REL + "/billing-core/", "").split("/")[0])
);
ok(
  "billing-core spreads across ≥ 2 layered trees",
  trees.size >= 2,
  `trees = [${[...trees].join(", ")}]`
);
ok("billing-core manifest validates", billing.manifestValid === true, `valid = ${billing.manifestValid}`);
// the projected deps include the touched kernel concepts.
ok(
  "billing-core manifest deps include touched kernel",
  ["content", "tenancy"].every((c) => billing.manifest.deps.includes(c)),
  `deps = [${billing.manifest.deps.join(", ")}]`
);

// ── 3. PROPOSE-ONLY: nothing written outside staging ─────────────────────────
const after = gitStatusPaths();
const newPaths = after.filter((p) => !before.has(p));
const outsideStaging = newPaths.filter((p) => !p.startsWith(STAGING_REL + "/") && p !== STAGING_REL + "/");
ok(
  "NOTHING written outside .scaffold-staging/",
  outsideStaging.length === 0,
  outsideStaging.length
    ? `LEAKED paths: [${outsideStaging.join(", ")}]`
    : `all ${newPaths.length} new path(s) under ${STAGING_REL}/`
);
// and both scaffolds actually staged their files (the proposal is real).
ok(
  "both scaffolds staged their file plans",
  pricing.writtenFiles.length === pricing.plannedFiles.length &&
    billing.writtenFiles.length === billing.plannedFiles.length &&
    pricing.writtenFiles.length > 0,
  `pricing ${pricing.writtenFiles.length}/${pricing.plannedFiles.length}, ` +
    `billing ${billing.writtenFiles.length}/${billing.plannedFiles.length}`
);

// ── 4. A SYNTHESIZED MANIFEST validates against the schema ────────────────────
// pick a real exemplar concept and synthesize its manifest off the live graph.
const exemplarConcept = (anatomy.exemplars[0] && anatomy.exemplars[0].concept) || "sheets";
const synth = synthesizeManifest(exemplarConcept, { p1, p2: anatomy });
const synthValid = validateManifest(synth);
ok(
  `synthesized manifest for "${exemplarConcept}" validates`,
  synthValid.ok === true,
  synthValid.ok ? "ok" : synthValid.errors.join("; ")
);
// the synthesized manifest is grounded: it has a name, a real role-set, and deps.
ok(
  `synthesized "${exemplarConcept}" manifest is grounded`,
  synth.name === exemplarConcept && synth.roles.length > 0,
  `name=${synth.name} roles=[${synth.roles.join(", ")}] deps=[${synth.deps.join(", ")}] ` +
    `surface=${synth.surface.length} tables=[${synth.ownedTables.join(", ")}]`
);

// ── report ───────────────────────────────────────────────────────────────────
function run() {
  const out = (s) => process.stdout.write(s);
  out(
    `\ncqv8 P4 acceptance — ${p1.graph.nodes} nodes · ${p1.graph.edges} edges · ` +
      `kernel [${p1.bands.kernel.join(", ")}]\n`
  );
  out(`learned recurring roles: [${learnedRecurring.join(", ")}]\n`);
  out(`scaffold decisions:\n`);
  out(`  · pricing                          → ${pricing.template.toUpperCase()}\n`);
  out(`  · billing-core --touches content,tenancy → ${billing.template.toUpperCase()}\n`);
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
