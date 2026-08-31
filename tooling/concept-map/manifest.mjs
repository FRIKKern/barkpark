#!/usr/bin/env node
// manifest.mjs — cqv8 Phase 4: the per-feature manifest.
//
// P1 detected the concepts, P2 learned the feature skeleton, P3 graded every
// concept against five gaps. One of those gaps — MANIFEST-ABSENCE — is the
// recursion the spec calls out: cqv8's own concept-detection has to GUESS a
// feature's boundary by filename regex, so the sideways/scatter analysis carries
// noise. A per-feature MANIFEST fixes that: it declares a feature's identity,
// surface, owned tables, and roles in one place, so the boundary becomes EXACT.
//
//   import { defineManifest, validateManifest, synthesizeManifest } from "./manifest.mjs"
//   node tooling/concept-map/manifest.mjs <concept> [--json]   # synthesize + print
//
// ── THE SCHEMA (spec §6, Figure 5 check 4) ───────────────────────────────────
// A manifest is a plain object:
//
//   {
//     name        : string            // the concept token (its identity)
//     surface     : string[]          // the declared PUBLIC API — exported
//                                     // symbol ids that other concepts may use.
//     deps        : string[]          // allowed inward deps — kernel concepts
//                                     // this feature may depend on. Anything not
//                                     // listed here is a sideways edge P3/P5 cut.
//     ownedTables : string[]          // schema/table names this feature owns.
//     roles       : string[]          // the anatomy roles present (the learned
//                                     // role-set: core · registration · test …).
//   }
//
// validateManifest returns { ok, errors[] }. The schema is intentionally tiny —
// five fields, all required, name a non-empty string, the other four arrays of
// strings. That minimalism is the point: a manifest is a boundary DECLARATION,
// not a build descriptor.
//
// ── SYNTHESIS (build one from the graph for an EXISTING concept) ──────────────
// synthesizeManifest(concept) reads P1 (bands + coupling) and P2 (learned
// skeleton) and the real symbol graph, then derives every field from evidence:
//   name        ← the concept token
//   surface     ← the concept's EXPORTED symbols (node.exported) — the real
//                 public API the graph already records.
//   deps        ← the concept's efferent targets that land in P1's KERNEL band —
//                 the inward deps it actually has (intersected with the kernel).
//   ownedTables ← schema/table names declared in the concept's own source
//                 (Ecto `schema "x"` / `table: "x"`), read off disk.
//   roles       ← the roles this concept exhibits from P2's role vocabulary.
//
// Nothing is hardcoded — every field is computed from the live graph + disk.
//
// Dependency-free. ESM, node: builtins only. Reuses P1 (runConcepts) and P2
// (runAnatomy) so the manifest speaks the same concept + role vocabulary.

import { execFileSync } from "node:child_process";
import { readFileSync, existsSync, readdirSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { runConcepts } from "./concepts.mjs";
import { runAnatomy } from "./anatomy.mjs";
import { conceptTokenMatchers } from "./concept-tokens.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: HERE })
  .toString()
  .trim();

const SYMBOLS_PATH = join(ROOT, "tooling/symbol-graph/symbols.json");

// ── the schema ───────────────────────────────────────────────────────────────
// The five required fields, each with a kind. ARRAY fields must be arrays of
// strings; NAME must be a non-empty string. validateManifest checks exactly this.
export const MANIFEST_FIELDS = [
  { field: "name", kind: "string" },
  { field: "surface", kind: "string[]" },
  { field: "deps", kind: "string[]" },
  { field: "ownedTables", kind: "string[]" },
  { field: "roles", kind: "string[]" },
];

// defineManifest — construct a well-formed manifest object, coercing missing
// fields to their empty defaults. This is the canonical shape; callers that build
// a manifest by hand should route through here so the field-set stays exact.
export function defineManifest({ name, surface, deps, ownedTables, roles } = {}) {
  return {
    name: name == null ? "" : String(name),
    surface: Array.isArray(surface) ? surface.slice() : [],
    deps: Array.isArray(deps) ? deps.slice() : [],
    ownedTables: Array.isArray(ownedTables) ? ownedTables.slice() : [],
    roles: Array.isArray(roles) ? roles.slice() : [],
  };
}

// validateManifest — structural validation against the schema. Returns
// { ok:boolean, errors:string[] }. No throwing — callers decide how to surface.
export function validateManifest(m) {
  const errors = [];
  if (m == null || typeof m !== "object" || Array.isArray(m)) {
    return { ok: false, errors: ["manifest must be a non-null object"] };
  }
  const known = new Set(MANIFEST_FIELDS.map((f) => f.field));
  for (const k of Object.keys(m)) {
    if (!known.has(k)) errors.push(`unknown field "${k}"`);
  }
  for (const { field, kind } of MANIFEST_FIELDS) {
    const v = m[field];
    if (v === undefined) {
      errors.push(`missing required field "${field}"`);
      continue;
    }
    if (kind === "string") {
      if (typeof v !== "string") errors.push(`"${field}" must be a string`);
      else if (field === "name" && v.trim() === "") errors.push(`"name" must be non-empty`);
    } else if (kind === "string[]") {
      if (!Array.isArray(v)) errors.push(`"${field}" must be an array`);
      else if (!v.every((x) => typeof x === "string")) errors.push(`"${field}" must be an array of strings`);
    }
  }
  return { ok: errors.length === 0, errors };
}

// ── load + concept assignment (mirrors concepts.mjs structural detection) ────
function loadGraph() {
  if (!existsSync(SYMBOLS_PATH)) {
    throw new Error(
      `symbol graph not found at ${SYMBOLS_PATH} — run tooling/symbol-graph/build-symbols.mjs first`
    );
  }
  return JSON.parse(readFileSync(SYMBOLS_PATH, "utf8"));
}

function primaryConcept(file) {
  let m;
  if ((m = file.match(/^api\/lib\/barkpark\/plugins\/([a-z0-9_]+)(?:[/.]|$)/))) return m[1];
  if ((m = file.match(/^api\/lib\/barkpark\/([a-z0-9_]+)(?:[/.]|$)/))) return m[1];
  return null;
}

function assignConcepts(graph) {
  const conceptOf = new Map();
  const concepts = new Set();
  for (const n of graph.nodes) {
    const c = primaryConcept(n.file);
    if (c) {
      conceptOf.set(n.id, c);
      concepts.add(c);
    }
  }
  const tokens = [...concepts].sort((a, b) => b.length - a.length);
  const tokenRe = conceptTokenMatchers(tokens);
  for (const n of graph.nodes) {
    if (conceptOf.has(n.id)) continue;
    const low = n.file.toLowerCase();
    for (const t of tokens) {
      if (tokenRe.get(t).test(low)) {
        conceptOf.set(n.id, t);
        break;
      }
    }
  }
  return conceptOf;
}

// ── owned-table extraction ───────────────────────────────────────────────────
// Ecto declares a table with `schema "name" do` (or `table: "name"`). Read the
// concept's own source files off disk and pull those names. Files are discovered
// from the graph's node set (the concept's member files), so this stays in sync
// with concept assignment.
const SCHEMA_RE = /schema\s+"([a-z0-9_]+)"/g;
const TABLE_RE = /table:\s*"([a-z0-9_]+)"/g;

function ownedTablesFor(files) {
  const tables = new Set();
  for (const rel of files) {
    const full = join(ROOT, rel);
    if (!existsSync(full)) continue;
    let src;
    try {
      src = readFileSync(full, "utf8");
    } catch {
      continue;
    }
    let m;
    SCHEMA_RE.lastIndex = 0;
    while ((m = SCHEMA_RE.exec(src))) tables.add(m[1]);
    TABLE_RE.lastIndex = 0;
    while ((m = TABLE_RE.exec(src))) tables.add(m[1]);
  }
  return [...tables].sort();
}

// ── synthesize a manifest for an EXISTING concept ────────────────────────────
export function synthesizeManifest(concept, opts = {}) {
  const graph = opts.graph || loadGraph();
  const p1 = opts.p1 || runConcepts();
  const p2 = opts.p2 || runAnatomy();
  const conceptOf = opts.conceptOf || assignConcepts(graph);
  const kernelSet = new Set(p1.bands.kernel);

  // member nodes + files of the concept
  const memberFiles = new Set();
  const surface = new Set();
  for (const n of graph.nodes) {
    if (conceptOf.get(n.id) !== concept) continue;
    memberFiles.add(n.file);
    if (n.exported) surface.add(n.id);
  }

  // deps — efferent targets landing in the kernel band (the real inward deps).
  const deps = new Set();
  for (const e of graph.edges) {
    if (conceptOf.get(e.from) !== concept) continue;
    const ct = conceptOf.get(e.to);
    if (ct && ct !== concept && kernelSet.has(ct)) deps.add(ct);
  }

  // roles — this concept's roles from P2's learned vocabulary. P2 exposes the
  // role-set per exemplar; for non-exemplars we still derive roles from the path
  // markers P2 published in the skeleton (the recurring role names).
  const skeletonRoles = new Set(p2.roles.map((r) => r.role));
  const roles = rolesForConcept(concept, memberFiles, skeletonRoles, kernelSet, graph, conceptOf);

  const m = defineManifest({
    name: concept,
    surface: [...surface].sort(),
    deps: [...deps].sort(),
    ownedTables: ownedTablesFor(memberFiles),
    roles,
  });
  return m;
}

// Derive the roles a concept exhibits, restricted to the learned skeleton's role
// vocabulary so the manifest's roles[] is anchored to P2's anatomy, not invented.
const ROLE_PATH_MARKERS = [
  { role: "engine", re: /(^|[/_])engine([/_.]|$)/ },
  { role: "session", re: /(^|[/_])session([/_.]|$)/ },
  { role: "structure", re: /(^|[/_])structure([/_.]|$)/ },
  { role: "live", re: /_live([/_.]|$)|(^|\/)live\// },
  { role: "controller", re: /(^|[/_])controller([/_.]|$)|_controller\b/ },
  { role: "registry", re: /(^|[/_])regist(ry|er)([/_.]|$)/ },
  { role: "reader", re: /(^|[/_])reader([/_.]|$)/ },
  { role: "grid", re: /(^|[/_])grid([/_.]|$)/ },
  { role: "worker", re: /(^|[/_])worker([/_.]|$)/ },
  { role: "schema", re: /(^|[/_])schemas?([/_.]|$)/ },
];

function rolesForConcept(concept, files, skeletonRoles, kernelSet, graph, conceptOf) {
  const roles = new Set();
  if (skeletonRoles.has("core")) roles.add("core"); // every concept has a core
  // registration — the concept's plugin entry file defines a register_* call.
  const pf = join(ROOT, "api/lib/barkpark/plugins/" + concept + ".ex");
  if (existsSync(pf)) {
    const src = readFileSync(pf, "utf8");
    if (/def\s+register_(schemas|routes)\b/.test(src) && skeletonRoles.has("registration")) {
      roles.add("registration");
    }
  }
  for (const f of files) {
    const low = f.toLowerCase();
    for (const m of ROLE_PATH_MARKERS) {
      if (skeletonRoles.has(m.role) && m.re.test(low)) roles.add(m.role);
    }
  }
  return [...roles].sort();
}

// ── human output ─────────────────────────────────────────────────────────────
function printHuman(concept, m, validation) {
  const out = (s) => process.stdout.write(s);
  const bar = "─".repeat(72);
  out(`\n${bar}\ncqv8 P4 — synthesized manifest for "${concept}"\n${bar}\n\n`);
  out(`  name        ${m.name}\n`);
  out(`  surface     ${m.surface.length} exported symbol(s)\n`);
  for (const s of m.surface.slice(0, 8)) out(`                · ${s}\n`);
  if (m.surface.length > 8) out(`                … +${m.surface.length - 8} more\n`);
  out(`  deps        ${m.deps.join(", ") || "(none)"}\n`);
  out(`  ownedTables ${m.ownedTables.join(", ") || "(none)"}\n`);
  out(`  roles       ${m.roles.join(" · ") || "(none)"}\n`);
  out(`\n  validates:  ${validation.ok ? "✓ ok" : "✗ " + validation.errors.join("; ")}\n`);
  out(`\n${bar}\n`);
}

// ── CLI ──────────────────────────────────────────────────────────────────────
function main() {
  const argv = process.argv.slice(2);
  const concept = argv.find((a) => !a.startsWith("--"));
  if (!concept) {
    process.stderr.write("usage: node manifest.mjs <concept> [--json]\n");
    process.exit(2);
  }
  const m = synthesizeManifest(concept);
  const validation = validateManifest(m);
  if (argv.includes("--json")) {
    process.stdout.write(JSON.stringify({ manifest: m, validation }, null, 2) + "\n");
  } else {
    printHuman(concept, m, validation);
  }
  process.exit(validation.ok ? 0 : 1);
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  main();
}
