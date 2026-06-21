#!/usr/bin/env node
// scaffold.mjs — cqv8 Phase 4: generative-first scaffolding (PROPOSE-ONLY).
//
// "Cody will usually try to structure feature-first because that materializes
// concepts more clearly" is a design principle. scaffold.mjs is the capability
// that makes it a MEASURED, generative discipline. Given a NOT-YET-EXISTING
// concept, it PROJECTS the concept's coupling position — the same extractability
// math P1/P3 run on existing concepts, applied FORWARD — and picks the right
// anatomical template:
//
//   FEATURE-FOLDER — low projected afferent coupling, depends only inward on the
//                    kernel. Isolated, colocated. The default, because most new
//                    concepts ARE features (pricing · notifications).
//   CROSS-FOLDER   — kernel-ish: the new concept touches deep kernel concepts
//                    (content / tenancy) such that everyone will depend on it.
//                    The layered spread the kernel was historically added with
//                    (tenancy Ca 201 would correctly scaffold cross-folder).
//
// The decision is the SAME arithmetic for both — cross-folder is not an edge-case
// branch, it is the OTHER learned template, selected by projected coupling.
//
//   node tooling/concept-map/scaffold.mjs new <name> [--touches a,b]
//
// ── PROPOSE-ONLY (spec §6, "Substrate reuse") ────────────────────────────────
// cqv8 NEVER moves or writes real repo files behind your back. scaffold emits a
// DRY-RUN file plan — the learned anatomy (P2's role-set) instantiated as the
// files a new feature WOULD get — written ONLY under
//   tooling/concept-map/.scaffold-staging/<name>/
// Nothing outside that staging tree is ever touched. The output is a proposal:
// the file plan + the feature-folder-vs-cross-folder decision + the rationale.
//
// ── THE PROJECTION (P1 math, applied forward) ────────────────────────────────
// A new concept's afferent coupling cannot be measured (it has no callers yet),
// so it is PROJECTED from its declared --touches:
//   • touching a KERNEL concept (content / tenancy) means the new concept hooks
//     into the substrate — it will sit deep, depended-upon, HIGH afferent. That
//     is the cross-folder signature (tenancy itself, Ca 201).
//   • touching only non-kernel concepts (or nothing) projects LOW afferent
//     coupling: a leaf feature that depends inward and is depended on by nothing.
//     That is the feature-folder signature.
// The kernel band is read LIVE from P1 — never hardcoded.
//
// Dependency-free. ESM, node: builtins only. Reuses P1 (bands), P2 (learned
// skeleton), and P4's manifest synthesis. Computes everything from the live
// graph — never hardcodes a band, role, or expected decision.

import { execFileSync } from "node:child_process";
import { mkdirSync, writeFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { runConcepts } from "./concepts.mjs";
import { runAnatomy } from "./anatomy.mjs";
import { defineManifest, validateManifest } from "./manifest.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: HERE })
  .toString()
  .trim();

// The ONE directory scaffold is ever allowed to write into. Every emitted file
// path is asserted to live under here before a single byte is written.
export const STAGING_ROOT = join(HERE, ".scaffold-staging");

// ── the projection ───────────────────────────────────────────────────────────
// Project a new concept's coupling band from its declared --touches against the
// LIVE kernel band. Touching the kernel → high projected afferent → cross-folder.
export function projectTemplate(name, touches, opts = {}) {
  const p1 = opts.p1 || runConcepts();
  const kernelSet = new Set(p1.bands.kernel);
  const knownConcepts = new Set(p1.concepts.map((c) => c.concept));

  const touched = (touches || []).map((t) => t.trim()).filter(Boolean);
  const touchedKernel = touched.filter((t) => kernelSet.has(t));
  const touchedUnknown = touched.filter((t) => !knownConcepts.has(t));

  // PROJECTION: hooking into a kernel concept means the new concept sits deep in
  // the substrate — high projected afferent coupling. That is the cross-folder
  // signature. Otherwise it projects as a low-Ca leaf → feature-folder.
  const template = touchedKernel.length > 0 ? "cross-folder" : "feature-folder";

  const rationale =
    template === "cross-folder"
      ? `--touches names kernel concept(s) [${touchedKernel.join(", ")}] — projected HIGH afferent ` +
        `coupling (the new concept hooks into the substrate everyone depends on). ` +
        `Same signature as ${[...kernelSet].join("/")} (Ca-heavy kernel). Cross-folder layered spread.`
      : touched.length
      ? `--touches names only non-kernel concept(s) [${touched.join(", ")}] — projected LOW afferent ` +
        `coupling. A leaf feature that depends inward and is depended on by nothing. Feature-folder.`
      : `no --touches declared — projected LOW afferent coupling by default. ` +
        `Isolated, colocated leaf feature. Feature-folder.`;

  return {
    name,
    touched,
    touchedKernel,
    touchedUnknown,
    kernelBand: [...kernelSet].sort(),
    template,
    rationale,
  };
}

// ── the file plan (learned anatomy → files) ──────────────────────────────────
// Instantiate P2's learned role-set as the files a new feature WOULD get. The
// FEATURE-FOLDER template colocates everything under one feature tree; the
// CROSS-FOLDER template spreads the same roles across the layered locations the
// kernel was historically added with (domain core + web + tests in separate
// trees). Both draw their role-set from the SAME learned skeleton — the spread
// is the only difference, exactly as the spec frames it.
const ROLE_FILE = {
  core: (name) => `${name}.ex`,
  registration: (name) => `${name}.ex`, // registration lives in the plugin entry
  test: (name) => `${name}_test.exs`,
  controller: (name) => `${name}_controller.ex`,
  live: (name) => `${name}_live.ex`,
  engine: (name) => `${name}_engine.ex`,
  session: (name) => `${name}_session.ex`,
  structure: (name) => `${name}_structure.ex`,
  reader: (name) => `${name}_reader.ex`,
  grid: (name) => `${name}_grid.ex`,
  worker: (name) => `${name}_worker.ex`,
  registry: (name) => `${name}_registry.ex`,
  schema: (name) => `${name}_schema.ex`,
};

function recurringRoles(anatomy) {
  // The learned role-set: roles ≥2 exemplars exhibit (the recurring skeleton),
  // plus the always-present structural roles. Falls back to whatever P2 gives.
  const recurring = anatomy.roles.filter((r) => r.recurring).map((r) => r.role);
  const set = new Set(recurring);
  set.add("core");
  set.add("registration");
  set.add("test");
  return [...set];
}

// Map a role to its file path within the chosen template. relative to staging.
function planFiles(name, template, roles, allowedKernelDeps) {
  const files = [];
  const seen = new Set();
  for (const role of roles) {
    const fn = ROLE_FILE[role];
    if (!fn) continue;
    const base = fn(name);
    let rel;
    if (template === "feature-folder") {
      // everything colocated under one feature folder.
      rel = role === "test" ? `feature/${name}/${base}` : `feature/${name}/${base}`;
    } else {
      // cross-folder layered spread: web roles to a web tree, tests to a test
      // tree, the rest to a domain-core tree — the historical kernel layout.
      if (role === "live" || role === "controller") rel = `web/${name}/${base}`;
      else if (role === "test") rel = `test/${name}/${base}`;
      else rel = `domain/${name}/${base}`;
    }
    if (seen.has(rel)) continue;
    seen.add(rel);
    files.push({ role, path: rel });
  }
  // the manifest is part of every scaffold — the declared boundary.
  files.push({ role: "manifest", path: `feature/${name}/manifest.json` });
  return files;
}

// ── manifest stub for the new concept ────────────────────────────────────────
// A new concept has no graph yet, so its manifest is the DECLARED intent: name,
// the learned roles, deps = the touched concepts that are real kernel deps,
// surface/ownedTables empty until code exists. Validates against P4's schema.
function stubManifest(projection, roles, anatomy) {
  // deps = touched kernel concepts (the allowed inward deps) ∪ the skeleton's
  // learned allowedKernelDeps — both are kernel, both are legitimate inward.
  const deps = new Set(projection.touchedKernel);
  for (const d of anatomy.allowedKernelDeps || []) deps.add(d);
  return defineManifest({
    name: projection.name,
    surface: [], // no code yet
    deps: [...deps].sort(),
    ownedTables: [], // declared once schemas are written
    roles: roles.slice().sort(),
  });
}

// ── file contents (skeleton stubs) ───────────────────────────────────────────
function fileBody(role, name, registration) {
  if (role === "manifest") return null; // written as JSON separately
  const mod = name
    .split(/[_-]/)
    .map((p) => p.charAt(0).toUpperCase() + p.slice(1))
    .join("");
  const header = `# SCAFFOLD STUB (cqv8 P4, propose-only) — role: ${role}\n` +
    `# This is a DRY-RUN proposal. Nothing here was written into the real repo.\n\n`;
  if (role === "registration") {
    const calls = (registration.calls || []).map((c) => `  def ${c}, do: []\n`).join("");
    const beh = registration.behaviour ? `  @behaviour ${registration.behaviour}\n\n` : "";
    return `${header}defmodule Barkpark.Plugins.${mod} do\n${beh}${calls}end\n`;
  }
  return `${header}defmodule Barkpark.${mod}.${roleToMod(role)} do\nend\n`;
}

function roleToMod(role) {
  return role.charAt(0).toUpperCase() + role.slice(1);
}

// ── the scaffold run (PROPOSE-ONLY) ──────────────────────────────────────────
export function runScaffold(name, touches, opts = {}) {
  if (!name || !/^[a-z][a-z0-9_-]*$/.test(name)) {
    throw new Error(`invalid concept name "${name}" — use lower-case [a-z0-9_-], leading letter`);
  }
  const p1 = opts.p1 || runConcepts();
  const anatomy = opts.anatomy || runAnatomy();
  const projection = projectTemplate(name, touches, { p1 });
  const roles = recurringRoles(anatomy);
  const files = planFiles(name, projection.template, roles, anatomy.allowedKernelDeps);
  const manifest = stubManifest(projection, roles, anatomy);
  const validation = validateManifest(manifest);

  const stageDir = join(STAGING_ROOT, name);
  const written = [];
  if (!opts.dryRunNoWrite) {
    for (const f of files) {
      const abs = join(stageDir, f.path);
      // HARD GUARD: refuse to write anything outside the staging tree.
      assertUnderStaging(abs);
      mkdirSync(dirname(abs), { recursive: true });
      if (f.role === "manifest") {
        writeFileSync(abs, JSON.stringify(manifest, null, 2) + "\n");
      } else {
        writeFileSync(abs, fileBody(f.role, name, anatomy.registration));
      }
      written.push(join("tooling/concept-map/.scaffold-staging", name, f.path));
    }
  }

  return {
    name,
    template: projection.template,
    rationale: projection.rationale,
    projection,
    roles,
    learnedFrom: {
      exemplars: anatomy.exemplars.map((e) => e.concept),
      usedCuratedFallback: anatomy.usedCuratedFallback,
      registration: anatomy.registration,
    },
    manifest,
    manifestValid: validation.ok,
    plannedFiles: files.map((f) => ({
      role: f.role,
      path: join("tooling/concept-map/.scaffold-staging", name, f.path),
    })),
    writtenFiles: written,
    stagingDir: join("tooling/concept-map/.scaffold-staging", name),
  };
}

// HARD GUARD — the propose-only invariant in code. Any absolute path that does
// not live under STAGING_ROOT is rejected before a byte is written.
function assertUnderStaging(abs) {
  const stagingPrefix = STAGING_ROOT.endsWith("/") ? STAGING_ROOT : STAGING_ROOT + "/";
  if (abs !== STAGING_ROOT && !abs.startsWith(stagingPrefix)) {
    throw new Error(
      `propose-only violation: refused to write outside staging\n  target: ${abs}\n  staging: ${STAGING_ROOT}`
    );
  }
}

// ── human output ─────────────────────────────────────────────────────────────
function printHuman(res) {
  const out = (s) => process.stdout.write(s);
  const bar = "─".repeat(76);
  out(`\n${bar}\ncqv8 P4 — scaffold "${res.name}"  (PROPOSE-ONLY · dry-run)\n${bar}\n\n`);
  out(`  DECISION:  ${res.template.toUpperCase()}\n`);
  out(`  rationale: ${res.rationale}\n\n`);
  out(`  learned from exemplars: ${res.learnedFrom.exemplars.join(", ") || "(curated fallback)"}\n`);
  if (res.learnedFrom.usedCuratedFallback) out(`             ⚠ curated fallback skeleton\n`);
  out(`  registration: ${(res.learnedFrom.registration.calls || []).join(" + ") || "(none)"}\n`);
  out(`  manifest valid: ${res.manifestValid ? "✓" : "✗"}  (deps: ${res.manifest.deps.join(", ") || "none"})\n`);
  out(`\n  FILE PLAN (${res.plannedFiles.length} files → ${res.stagingDir}):\n`);
  for (const f of res.plannedFiles) {
    out(`    + ${f.path}   [${f.role}]\n`);
  }
  out(`\n  ${res.writtenFiles.length} file(s) staged — nothing written outside the staging tree.\n`);
  out(`\n${bar}\n`);
}

// ── CLI ──────────────────────────────────────────────────────────────────────
function parseArgs(argv) {
  // expected: new <name> [--touches a,b]
  let name = null;
  let touches = [];
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "new") continue;
    if (a === "--touches") {
      touches = (argv[++i] || "").split(",").map((s) => s.trim()).filter(Boolean);
    } else if (a.startsWith("--touches=")) {
      touches = a.slice("--touches=".length).split(",").map((s) => s.trim()).filter(Boolean);
    } else if (!a.startsWith("--") && name === null) {
      name = a;
    }
  }
  return { name, touches };
}

function main() {
  const argv = process.argv.slice(2);
  if (argv[0] !== "new") {
    process.stderr.write("usage: node scaffold.mjs new <name> [--touches a,b]\n");
    process.exit(2);
  }
  const { name, touches } = parseArgs(argv);
  if (!name) {
    process.stderr.write("usage: node scaffold.mjs new <name> [--touches a,b]\n");
    process.exit(2);
  }
  let res;
  try {
    res = runScaffold(name, touches);
  } catch (e) {
    process.stderr.write(`scaffold failed: ${e.message}\n`);
    process.exit(1);
  }
  if (argv.includes("--json")) {
    process.stdout.write(JSON.stringify(res, null, 2) + "\n");
  } else {
    printHuman(res);
  }
  process.exit(0);
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  main();
}
