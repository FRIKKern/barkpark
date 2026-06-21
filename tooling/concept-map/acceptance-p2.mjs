#!/usr/bin/env node
// acceptance-p2.mjs — cqv8 Phase 2 acceptance gate. MUST PASS.
//
// Asserts the anatomy-learner picks the spec's ground-truth exemplars and learns
// a usable skeleton — computed LIVE off the real symbol graph + registration
// convention every run, never against frozen literals. Exits non-zero on any
// failed assertion so it can gate CI / the build pass.
//
//   node tooling/concept-map/acceptance-p2.mjs
//
// ── WHAT IT GUARANTEES (spec §4) ─────────────────────────────────────────────
//   1. EXEMPLARS include sheets AND onixedit (the flagship + tight-packaging
//      exemplars) — proving the coupling+registration math surfaces them.
//   2. EXEMPLARS exclude media AND frt — proving the math EXCLUDES the right
//      features (media = half-infrastructure Ca; frt = too trivial). Knowing
//      which to exclude IS the coupling math.
//   3. roles[] contains the structural triad core + registration + test PLUS the
//      recurring anatomy markers engine · session · live the exemplars teach.
//   4. allowedKernelDeps is non-empty and every entry is a real KERNEL-band
//      concept (content / tenancy) — a feature may depend inward only on these.
//   5. The skeleton is repo-grounded, not the curated fallback.
//
// Nothing here reads an expected number from a fixture. Exemplar identity and
// role presence are derived freshly from the live graph.

import { fileURLToPath } from "node:url";
import { runAnatomy } from "./anatomy.mjs";
import { runConcepts } from "./concepts.mjs";

const res = runAnatomy();
const exemplarNames = new Set(res.exemplars.map((e) => e.concept));
const roleNames = new Set(res.roles.map((r) => r.role));
const recurringRoles = new Set(res.roles.filter((r) => r.recurring).map((r) => r.role));

// the actual KERNEL band from P1 — allowedKernelDeps must be a subset of it.
const kernelBand = new Set(runConcepts().bands.kernel);

const failures = [];
const checks = [];

function ok(label, cond, detail) {
  checks.push({ label, ok: !!cond, detail });
  if (!cond) failures.push(`${label}: ${detail}`);
  return !!cond;
}

// ── 1. exemplars INCLUDE sheets + onixedit ───────────────────────────────────
ok("exemplars include sheets", exemplarNames.has("sheets"), `exemplars = [${[...exemplarNames].join(", ")}]`);
ok("exemplars include onixedit", exemplarNames.has("onixedit"), `exemplars = [${[...exemplarNames].join(", ")}]`);

// ── 2. exemplars EXCLUDE media + frt ─────────────────────────────────────────
ok("exemplars exclude media", !exemplarNames.has("media"), `media ${exemplarNames.has("media") ? "WAS" : "was not"} selected`);
ok("exemplars exclude frt", !exemplarNames.has("frt"), `frt ${exemplarNames.has("frt") ? "WAS" : "was not"} selected`);

// ── 3. roles — structural triad + recurring anatomy markers ──────────────────
ok("roles contain core", roleNames.has("core"), `roles = [${[...roleNames].join(", ")}]`);
ok("roles contain registration", roleNames.has("registration"), `roles = [${[...roleNames].join(", ")}]`);
ok("roles contain test", roleNames.has("test"), `roles = [${[...roleNames].join(", ")}]`);
ok("roles contain engine", roleNames.has("engine"), `roles = [${[...roleNames].join(", ")}]`);
ok("roles contain session", roleNames.has("session"), `roles = [${[...roleNames].join(", ")}]`);
ok("roles contain live", roleNames.has("live"), `roles = [${[...roleNames].join(", ")}]`);

// the structural triad must be RECURRING (every exemplar has it).
ok("core is recurring", recurringRoles.has("core"), `recurring = [${[...recurringRoles].join(", ")}]`);
ok("registration is recurring", recurringRoles.has("registration"), `recurring = [${[...recurringRoles].join(", ")}]`);
ok("test is recurring", recurringRoles.has("test"), `recurring = [${[...recurringRoles].join(", ")}]`);

// ── 4. allowedKernelDeps non-empty and kernel-valid ──────────────────────────
ok("allowedKernelDeps non-empty", res.allowedKernelDeps.length > 0, `allowedKernelDeps = [${res.allowedKernelDeps.join(", ")}]`);
ok(
  "allowedKernelDeps all in KERNEL band",
  res.allowedKernelDeps.length > 0 && res.allowedKernelDeps.every((d) => kernelBand.has(d)),
  `kernel band = [${[...kernelBand].join(", ")}], deps = [${res.allowedKernelDeps.join(", ")}]`
);

// ── 5. skeleton is repo-grounded, not the curated fallback ───────────────────
ok("repo-grounded (not curated fallback)", res.usedCuratedFallback === false, `usedCuratedFallback = ${res.usedCuratedFallback}`);

// ── 6. registration call shape learned (the recurring wiring call) ───────────
ok(
  "registration call shape learned",
  res.registration.calls.includes("register_schemas") && res.registration.calls.includes("register_routes"),
  `registration.calls = [${res.registration.calls.join(", ")}]`
);

// ── report ───────────────────────────────────────────────────────────────────
function run() {
  const out = (s) => process.stdout.write(s);
  out(`\ncqv8 P2 acceptance — ${res.graph.nodes} nodes · ${res.graph.edges} edges · ${res.candidateCount} candidate exemplars\n`);
  out(`exemplars: ${[...exemplarNames].join(", ") || "(none)"}\n`);
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
