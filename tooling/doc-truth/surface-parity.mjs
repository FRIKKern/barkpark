#!/usr/bin/env node
// surface-parity.mjs — does the hand-maintained doc surface still match ground truth?
//
// A recurring doc-drift class: a feature adds a public CLI verb (in the bp
// capabilities manifest) or a public SDK client method (in @barkpark/core), but
// the hand-maintained ENUMERATION that lists it — the CLI HANDBOOK / cheatsheet,
// or the core README — isn't updated. The verb/method still works (it's
// manifest- or code-driven), but a reader scanning the docs never learns it
// exists. PRs #363/#364 (README method lists) and #367 (CLI verb tables) were
// all this class, each caught by a manual cross-check. This guard automates it.
//
// Two checks:
//   cli      — every `"<noun>.<verb>"` op in capabilities.ex appears (as a word)
//              in the CLI HANDBOOK or the bp cheatsheet.
//   sdk      — every public method on the @barkpark/core `client` object appears
//              in the package README.
//
// ADVISORY, like metric-currency: it prints PARITY / DRIFT and a list, exit 0
// always (the drift-guard job surfaces it; it never blocks a merge). Intentional
// omissions go in the IGNORE sets below with a one-line reason.
//
//   node tooling/doc-truth/surface-parity.mjs [--json]
//
// Dependency-free. ESM, node: builtins only.

import { execFileSync } from "node:child_process";
import { readFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: HERE })
  .toString()
  .trim();

const CAPABILITIES = join(ROOT, "api/lib/barkpark/plugins/capabilities.ex");
const CLIENT_TS = join(ROOT, "js/packages/core/src/client.ts");
const CORE_TYPES = join(ROOT, "js/packages/core/src/types.ts");
const FILTER_BUILDER = join(ROOT, "js/packages/core/src/filter-builder.ts");
const HANDBOOK = join(ROOT, "docs/cli/HANDBOOK.md");
const CHEATSHEET = join(ROOT, "docs/cheatsheets/bp.md");
const CORE_README = join(ROOT, "js/packages/core/README.md");

// Manifest ops intentionally NOT enumerated in the CLI quick-refs (with reason).
const CLI_IGNORE = new Map([
  // e.g. ["plugin.internalThing", "internal op, not a user-facing bp command"],
]);
// Client object keys that are not user-facing methods to document.
const SDK_IGNORE = new Map([
  ["handshake", "internal capability handshake, not a documented method"],
  ["config", "config accessor, not a method"],
]);

function read(p) {
  return existsSync(p) ? readFileSync(p, "utf8") : "";
}

// ── ground truth ────────────────────────────────────────────────────────────

// Every `"<noun>.<verb>"` operation id that sits on its own line — the manifest's
// command surface. Restricted to standalone id lines so dotted strings inside
// prose/summaries aren't mistaken for ops.
function manifestVerbs() {
  const text = read(CAPABILITIES);
  const ids = new Map(); // id -> {noun, verb}
  // verb segment allows hyphens (e.g. `doc.create-or-replace`), not just [a-z_].
  for (const m of text.matchAll(/^\s*"([a-z_]+)\.([a-z_-]+)",\s*$/gm)) {
    const id = `${m[1]}.${m[2]}`;
    if (!ids.has(id)) ids.set(id, { noun: m[1], verb: m[2], id });
  }
  return [...ids.values()];
}

// Public method names on the `const client = { … }` object literal returned by
// createClient. Top-level keys only (2- or 4-space indent inside the object),
// matched as `name(`, `name<`, or `name:`.
// Public client methods, read from the AUTHORITATIVE `BarkparkClient` interface
// (types.ts) — the public contract — NOT the client object literal (client.ts).
// The interface is uniform declarations (no `async`, no impl braces, no internal
// `handshake`/`__handshakeCache`), so it's immune to the implementation-parsing
// blind spots that bit the object-literal approach (hyphens, the `async` prefix).
function clientMethods() {
  const lines = read(CORE_TYPES).split("\n");
  const start = lines.findIndex((l) => /export interface BarkparkClient\s*\{/.test(l));
  if (start < 0) return [];
  let depth = 0, started = false, end = lines.length;
  for (let i = start; i < lines.length; i++) {
    for (const ch of lines[i]) {
      if (ch === "{") { depth++; started = true; }
      else if (ch === "}") { depth--; }
    }
    if (started && depth === 0) { end = i; break; }
  }
  const names = new Set();
  for (let i = start + 1; i < end; i++) {
    // a method/property declaration sits at the interface's one indent level,
    // named then `(` (method) or `<` (generic method).
    const m = lines[i].match(/^\s{2}([a-zA-Z_][a-zA-Z0-9_]*)\s*[(<]/);
    if (m) names.add(m[1]);
  }
  return [...names];
}

// ── checks ──────────────────────────────────────────────────────────────────

function word(haystack, w) {
  return new RegExp(`\\b${w.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}\\b`).test(haystack);
}

function checkCli() {
  const docs = read(HANDBOOK) + "\n" + read(CHEATSHEET);
  const verbs = manifestVerbs().filter((v) => !CLI_IGNORE.has(v.id));
  const byNoun = new Map();
  for (const v of verbs) {
    if (!byNoun.has(v.noun)) byNoun.set(v.noun, []);
    byNoun.get(v.noun).push(v);
  }
  const namespaces = []; // fully-undocumented noun families
  const partials = []; // documented noun, but this verb is absent
  const lines = docs.split("\n");
  for (const [noun, vs] of byNoun) {
    // the noun family is documented if any line references it as `bp <noun>`.
    const nounLines = lines.filter((l) => new RegExp(`bp\\s+${noun}\\b`).test(l)).join("  ");
    if (!nounLines) {
      namespaces.push({ noun, count: vs.length });
      continue;
    }
    // a verb counts as documented only if it appears WITHIN the noun's own lines —
    // NOT anywhere (else common verbs like `get`/`delete` pass via a different noun).
    for (const v of vs) if (!word(nounLines, v.verb)) partials.push(v.id);
  }
  return { namespaces, partials };
}

function checkSdk() {
  const readme = read(CORE_README);
  const missing = [];
  for (const name of clientMethods()) {
    if (name.startsWith("__")) continue; // internal convention (e.g. __handshakeCache)
    if (SDK_IGNORE.has(name)) continue;
    if (!word(readme, name)) missing.push(name);
  }
  return missing;
}

// The canonical filter-operator list (`VALID_OPS` in the filter builder). Each
// op should appear in the core README's operator list — the team adds operators
// often (null `is`, `startsWith`/`endsWith`), and each addition has shipped
// without README docs until caught.
function filterOps() {
  const m = read(FILTER_BUILDER).match(/const VALID_OPS\b[^=]*=\s*\[([^\]]*)\]/);
  if (!m) return [];
  return [...m[1].matchAll(/['"]([a-zA-Z]+)['"]/g)].map((x) => x[1]);
}

function checkOps() {
  const readme = read(CORE_README);
  return filterOps().filter((op) => !word(readme, op));
}

// ── main ────────────────────────────────────────────────────────────────────

const { namespaces, partials } = checkCli();
const sdk = checkSdk();
const ops = checkOps();
const json = process.argv.includes("--json");
const ok = namespaces.length === 0 && partials.length === 0 && sdk.length === 0 && ops.length === 0;

if (json) {
  console.log(JSON.stringify({ namespaces, partials, sdk, ops, parity: ok }, null, 2));
} else {
  console.log(ok ? "PARITY ✓" : "DRIFT");
  if (namespaces.length) {
    console.log(`\nCLI command families with NO mention in HANDBOOK or cheatsheet:`);
    for (const n of namespaces) console.log(`  - bp ${n.noun}  (${n.count} verb${n.count > 1 ? "s" : ""})`);
  }
  if (partials.length) {
    console.log(`\nCLI verbs whose family is documented but the verb is not:`);
    for (const id of partials) console.log(`  - ${id}  (bp ${id.replace(".", " ")})`);
  }
  if (sdk.length) {
    console.log(`\n@barkpark/core client methods absent from the package README:`);
    for (const m of sdk) console.log(`  - ${m}()`);
  }
  if (ops.length) {
    console.log(`\nFilter operators (VALID_OPS) absent from the package README:`);
    for (const op of ops) console.log(`  - .${op}()`);
  }
  if (ok) console.log("Every manifest verb, client method, and filter operator is enumerated in its doc surface.");
}

// Advisory: always exit 0.
process.exit(0);
