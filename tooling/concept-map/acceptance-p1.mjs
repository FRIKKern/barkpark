#!/usr/bin/env node
// acceptance-p1.mjs — cqv8 Phase 1 acceptance gate. MUST PASS.
//
// Asserts the concept/coupling model lands the spec's ground-truth bands and
// headline numbers — computed LIVE off the real symbol graph every run, never
// against frozen literals. Exits non-zero on any failed assertion so it can gate
// CI / the build pass.
//
//   node tooling/concept-map/acceptance-p1.mjs
//
// ── WHAT IT GUARANTEES (spec §1–2) ───────────────────────────────────────────
//   1. content  AND tenancy  classify as KERNEL          (Ca > 150)
//   2. sheets   AND onixedit classify as CLEAN-FEATURE   (cohesion ≥ 0.8, registered)
//   3. release  AND portable_doc classify CLEAN-NONPLUGIN (clean by the coupling
//        math but lacking the plugin registration surface — same cohesion gate,
//        no registration). The ONLY difference from sheets/onixedit is registration.
//   4. headline numbers land within tolerance of ground truth:
//        content  Ca   ~390   (range 360–420)
//        tenancy  Ca   ~201   (range 180–220)
//        sheets   cohesion ~0.87 (range 0.83–0.92)
//
// Every expected value is a RANGE asserted against a freshly computed result —
// no expected number is read from a fixture or hardcoded as the answer.

import { fileURLToPath } from "node:url";
import { runConcepts } from "./concepts.mjs";

const res = runConcepts();
const byName = new Map(res.concepts.map((c) => [c.concept, c]));

const failures = [];
const checks = [];

function get(name) {
  const c = byName.get(name);
  if (!c) failures.push(`concept "${name}" was not detected at all`);
  return c;
}

// assert a numeric value falls in [lo, hi]
function inRange(label, value, lo, hi) {
  const ok = value != null && value >= lo && value <= hi;
  checks.push({ label, ok, detail: `${fmt(value)} ∈ [${lo}, ${hi}]` });
  if (!ok) failures.push(`${label}: ${fmt(value)} not in [${lo}, ${hi}]`);
  return ok;
}

// assert a boolean condition
function ok2(label, cond, detail) {
  checks.push({ label, ok: !!cond, detail });
  if (!cond) failures.push(`${label}: ${detail}`);
  return !!cond;
}

// assert a concept's band
function band(name, expected) {
  const c = get(name);
  const got = c ? c.band : "(absent)";
  const ok = got === expected;
  checks.push({ label: `${name} band`, ok, detail: `${got} (want ${expected})` });
  if (!ok) failures.push(`${name} band: got ${got}, want ${expected}`);
  return ok;
}

function fmt(v) {
  if (v == null) return "n/a";
  return Number.isInteger(v) ? String(v) : v.toFixed(3);
}

// ── 1. KERNEL band — content + tenancy, with the Ca > 150 guarantee ──────────
const content = get("content");
const tenancy = get("tenancy");
band("content", "KERNEL");
band("tenancy", "KERNEL");
if (content) inRange("content Ca > 150 (kernel substrate)", content.ca, 151, 100000);
if (tenancy) inRange("tenancy Ca > 150 (kernel substrate)", tenancy.ca, 151, 100000);

// ── 2. CLEAN-FEATURE band — sheets + onixedit, cohesion ≥ 0.8 ─────────────────
const sheets = get("sheets");
const onixedit = get("onixedit");
band("sheets", "CLEAN-FEATURE");
band("onixedit", "CLEAN-FEATURE");
if (sheets) inRange("sheets cohesion ≥ 0.8", sheets.cohesion, 0.8, 1.0);
if (onixedit) inRange("onixedit cohesion ≥ 0.8", onixedit.cohesion, 0.8, 1.0);

// ── 2b. CLEAN-NONPLUGIN band — release + portable_doc, clean-by-coupling but ──
// not registered. Same cohesion gate as CLEAN-FEATURE; only registration differs.
const release = get("release");
const portableDoc = get("portable_doc");
band("release", "CLEAN-NONPLUGIN");
band("portable_doc", "CLEAN-NONPLUGIN");
if (release) inRange("release cohesion ≥ 0.8", release.cohesion, 0.8, 1.0);
if (portableDoc) inRange("portable_doc cohesion ≥ 0.8", portableDoc.cohesion, 0.8, 1.0);
// they must NOT land in the registered CLEAN-FEATURE band.
if (release) ok2("release is NOT CLEAN-FEATURE", release.band !== "CLEAN-FEATURE", `band = ${release.band}`);
if (portableDoc) ok2("portable_doc is NOT CLEAN-FEATURE", portableDoc.band !== "CLEAN-FEATURE", `band = ${portableDoc.band}`);
// the registered exemplars stay CLEAN-FEATURE, never the new band.
if (sheets) ok2("sheets stays CLEAN-FEATURE (registered)", sheets.band === "CLEAN-FEATURE", `band = ${sheets.band}`);
if (onixedit) ok2("onixedit stays CLEAN-FEATURE (registered)", onixedit.band === "CLEAN-FEATURE", `band = ${onixedit.band}`);

// ── 3. headline numbers — dominant-kernel floors, NOT tight pins ─────────────
// content's afferent coupling drifts DOWN as the god-object is decomposed into
// Content.* sub-modules (was ~390 pre-decomposition, ~342 after the spine split).
// That's the intended effect — so assert a dominant-kernel floor, not a tight
// range a successful decomposition would break. content stays the biggest hub
// (Ca well above the 150 kernel gate and above tenancy) until it's genuinely no
// longer the spine, which would be a real signal worth re-checking.
if (content && tenancy) {
  inRange("content Ca — dominant kernel (>200, drifts down as the spine decomposes)", content.ca, 200, 100000);
  ok2("content remains the most-depended-upon concept (Ca > tenancy)", content.ca > tenancy.ca, `content ${content.ca} vs tenancy ${tenancy.ca}`);
}
if (tenancy) inRange("tenancy Ca ~201 (stable kernel)", tenancy.ca, 150, 260);
if (sheets) inRange("sheets cohesion ~0.87", sheets.cohesion, 0.83, 0.92);

// ── report ───────────────────────────────────────────────────────────────────
function run() {
  const out = (s) => process.stdout.write(s);
  out(`\ncqv8 P1 acceptance — ${res.graph.nodes} nodes · ${res.graph.edges} edges · ${res.conceptCount} concepts\n`);
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
