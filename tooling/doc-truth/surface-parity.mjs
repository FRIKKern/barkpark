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
// GROUND-TRUTH SOURCES MUST BE READABLE, OR THE VERDICT IS A LIE. `read()`
// returns "" for a file it cannot open, and every parser below returns []
// for empty input — so a RENAMED or MOVED ground-truth source used to parse
// to nothing and print `PARITY ✓`, the strongest possible reassurance,
// precisely when it had read nothing at all. REQUIRED_SOURCES below (the
// capabilities manifest, the SDK client interface, the filter builder) is
// existsSync-asserted before any comparison runs; a miss prints
// `SOURCE MISSING: <path>` and the headline reads DRIFT / SOURCES MISSING —
// never PARITY ✓ — while the process still exits 0 (the advisory contract).
//
//   node tooling/doc-truth/surface-parity.mjs [--json]
//   node tooling/doc-truth/surface-parity.mjs --selftest
//
// Dependency-free. ESM, node: builtins only.

import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, existsSync, mkdtempSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { tmpdir } from "node:os";
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

// The ground-truth sources every comparison is computed FROM. (HANDBOOK,
// CHEATSHEET and CORE_README are doc TARGETS being checked against these —
// not required sources themselves; CLIENT_TS is declared above but unused,
// see clientMethods() below.) A missing entry here means the comparison has
// nothing to read, so its verdict would be a lie — see the header note.
const REQUIRED_SOURCES = [
  { name: "CAPABILITIES", path: CAPABILITIES },
  { name: "CORE_TYPES", path: CORE_TYPES },
  { name: "FILTER_BUILDER", path: FILTER_BUILDER },
];

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
function manifestVerbs(path = CAPABILITIES) {
  const text = read(path);
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
function clientMethods(path = CORE_TYPES) {
  const lines = read(path).split("\n");
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

function checkCli(capabilitiesPath = CAPABILITIES) {
  const docs = read(HANDBOOK) + "\n" + read(CHEATSHEET);
  const verbs = manifestVerbs(capabilitiesPath).filter((v) => !CLI_IGNORE.has(v.id));
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

function checkSdk(coreTypesPath = CORE_TYPES) {
  const readme = read(CORE_README);
  const missing = [];
  for (const name of clientMethods(coreTypesPath)) {
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
function filterOps(path = FILTER_BUILDER) {
  const m = read(path).match(/const VALID_OPS\b[^=]*=\s*\[([^\]]*)\]/);
  if (!m) return [];
  return [...m[1].matchAll(/['"]([a-zA-Z]+)['"]/g)].map((x) => x[1]);
}

function checkOps(filterBuilderPath = FILTER_BUILDER) {
  const readme = read(CORE_README);
  return filterOps(filterBuilderPath).filter((op) => !word(readme, op));
}

// ── required-source guard ───────────────────────────────────────────────────
//
// A missing required source makes every comparison above vacuously empty, so
// it must be caught BEFORE any comparison runs — never inferred after the fact
// from an empty difference list, which is exactly the bug this guards against.

function missingSources(sources = REQUIRED_SOURCES) {
  return sources.filter((s) => !existsSync(s.path));
}

// Computes the full report, short-circuiting to a SOURCE-MISSING report (no
// comparisons attempted) when any required source cannot be read. `sources`
// is injectable so the selftest can point it at a fixture without touching
// the real repo files.
function buildReport(sources = REQUIRED_SOURCES) {
  const missing = missingSources(sources);
  if (missing.length) {
    return { sourcesMissing: true, missing, ok: false, namespaces: [], partials: [], sdk: [], ops: [] };
  }
  const byName = Object.fromEntries(sources.map((s) => [s.name, s.path]));
  const { namespaces, partials } = checkCli(byName.CAPABILITIES);
  const sdk = checkSdk(byName.CORE_TYPES);
  const ops = checkOps(byName.FILTER_BUILDER);
  const ok = namespaces.length === 0 && partials.length === 0 && sdk.length === 0 && ops.length === 0;
  return { sourcesMissing: false, missing: [], ok, namespaces, partials, sdk, ops };
}

function formatReport(report, { json = false } = {}) {
  const { sourcesMissing, missing, ok, namespaces, partials, sdk, ops } = report;
  if (json) {
    return JSON.stringify(
      { namespaces, partials, sdk, ops, sourcesMissing: missing.map((m) => m.path), parity: sourcesMissing ? false : ok },
      null,
      2,
    );
  }
  const lines = [];
  if (sourcesMissing) {
    lines.push("DRIFT / SOURCES MISSING");
    for (const m of missing) lines.push(`SOURCE MISSING: ${m.path}`);
    lines.push("\nCannot compute parity: the ground-truth source(s) above could not be read (renamed or moved?).");
    return lines.join("\n");
  }
  lines.push(ok ? "PARITY ✓" : "DRIFT");
  if (namespaces.length) {
    lines.push(`\nCLI command families with NO mention in HANDBOOK or cheatsheet:`);
    for (const n of namespaces) lines.push(`  - bp ${n.noun}  (${n.count} verb${n.count > 1 ? "s" : ""})`);
  }
  if (partials.length) {
    lines.push(`\nCLI verbs whose family is documented but the verb is not:`);
    for (const id of partials) lines.push(`  - ${id}  (bp ${id.replace(".", " ")})`);
  }
  if (sdk.length) {
    lines.push(`\n@barkpark/core client methods absent from the package README:`);
    for (const m of sdk) lines.push(`  - ${m}()`);
  }
  if (ops.length) {
    lines.push(`\nFilter operators (VALID_OPS) absent from the package README:`);
    for (const op of ops) lines.push(`  - .${op}()`);
  }
  if (ok) lines.push("Every manifest verb, client method, and filter operator is enumerated in its doc surface.");
  return lines.join("\n");
}

// ── selftest ────────────────────────────────────────────────────────────────
//
// Two arms, following the shape of verify-bp-commands.mjs / acceptance.mjs:
//   (1) a required source absent → SOURCE MISSING, never PARITY ✓.
//   (2) all required sources present → the normal report (unchanged shape).
// Both run against temp fixtures this selftest owns — never the real
// CAPABILITIES/CORE_TYPES/FILTER_BUILDER files, so a rename of any of them
// can't make arm (1) vacuous the way the original bug made the whole tool
// vacuous.

function selftest() {
  const results = [];
  const check = (name, fn) => {
    try {
      const r = fn();
      results.push({ name, ok: r === true, detail: r === true ? "" : String(r) });
    } catch (e) {
      results.push({ name, ok: false, detail: e.stack ? e.stack.split("\n")[0] : String(e) });
    }
  };

  const dir = mkdtempSync(join(tmpdir(), "surface-parity-selftest-"));
  try {
    // Arm 1 — one required source absent (FILTER_BUILDER is never written).
    const capPath = join(dir, "capabilities.ex");
    const typesPath = join(dir, "types.ts");
    const missingPath = join(dir, "filter-builder.ts");
    writeFileSync(capPath, '  "doc.ls",\n');
    writeFileSync(typesPath, "export interface BarkparkClient {\n  ls(): void;\n}\n");
    const missingSourceSet = [
      { name: "CAPABILITIES", path: capPath },
      { name: "CORE_TYPES", path: typesPath },
      { name: "FILTER_BUILDER", path: missingPath },
    ];

    check("SOURCE MISSING is detected for the one absent fixture source", () => {
      const gaps = missingSources(missingSourceSet);
      return (gaps.length === 1 && gaps[0].path === missingPath) ||
        `expected exactly [${missingPath}], got ${JSON.stringify(gaps)}`;
    });
    check("a missing required source short-circuits to sourcesMissing, no comparisons attempted", () => {
      const r = buildReport(missingSourceSet);
      return (r.sourcesMissing === true && r.ok === false &&
        r.namespaces.length === 0 && r.partials.length === 0 && r.sdk.length === 0 && r.ops.length === 0) ||
        `got ${JSON.stringify(r)}`;
    });
    check("text report: names the missing path and headlines DRIFT / SOURCES MISSING", () => {
      const out = formatReport(buildReport(missingSourceSet));
      return (out.includes(`SOURCE MISSING: ${missingPath}`) && out.startsWith("DRIFT / SOURCES MISSING")) ||
        `report did not name the gap:\n${out}`;
    });
    check("MUTATION: a missing required source NEVER prints PARITY ✓", () => {
      const out = formatReport(buildReport(missingSourceSet));
      return !out.includes("PARITY ✓") || `false PARITY ✓ printed:\n${out}`;
    });
    check("json report: parity is false and sourcesMissing names the gap", () => {
      const j = JSON.parse(formatReport(buildReport(missingSourceSet), { json: true }));
      return (j.parity === false && j.sourcesMissing.includes(missingPath)) || `got ${JSON.stringify(j)}`;
    });

    // Arm 2 — every required source present (all three fixture files exist,
    // including a filter builder this time): the normal report runs, not the
    // SOURCE MISSING short-circuit.
    const filterPath = join(dir, "filter-builder-present.ts");
    writeFileSync(filterPath, 'const VALID_OPS = ["eq", "hasStrong"];\n');
    const completeSourceSet = [
      { name: "CAPABILITIES", path: capPath },
      { name: "CORE_TYPES", path: typesPath },
      { name: "FILTER_BUILDER", path: filterPath },
    ];
    check("all sources present: missingSources() reports none", () =>
      missingSources(completeSourceSet).length === 0 || "expected zero gaps with every fixture source present");
    check("all sources present: the normal (non-missing) report runs", () => {
      const r = buildReport(completeSourceSet);
      return r.sourcesMissing === false || `expected sourcesMissing:false, got ${JSON.stringify(r)}`;
    });
    check("all sources present: text report never says SOURCE MISSING", () => {
      const out = formatReport(buildReport(completeSourceSet));
      return !out.includes("SOURCE MISSING") || `unexpected SOURCE MISSING:\n${out}`;
    });

    // Wiring half — the real repo files exist today (MEASURED ON MAIN), so the
    // default call must take the normal path too, proving the guard doesn't
    // fire on the live tree.
    check("LIVE TREE: the default REQUIRED_SOURCES are all present today", () =>
      missingSources().length === 0 || `unexpected gap(s) on the live tree: ${JSON.stringify(missingSources())}`);
    check("LIVE TREE: the default run is the normal report, never SOURCE MISSING", () => {
      const out = formatReport(buildReport());
      return (!out.includes("SOURCE MISSING") && (out.startsWith("PARITY ✓") || out.startsWith("DRIFT"))) ||
        `unexpected header on the live tree:\n${out.split("\n")[0]}`;
    });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }

  const w = (s) => process.stdout.write(s + "\n");
  const bar = "─".repeat(78);
  w("");
  w("surface-parity --selftest");
  w(bar);
  let bad = 0;
  for (const r of results) {
    if (!r.ok) bad++;
    w(`  ${r.ok ? "✓" : "✗"} ${r.name}${r.ok ? "" : `\n      ${r.detail}`}`);
  }
  w(bar);
  w(`selftest: ${results.length - bad}/${results.length} passed`);
  w(bar);
  return bad === 0 ? 0 : 1;
}

// ── main ────────────────────────────────────────────────────────────────────

function main() {
  if (process.argv.includes("--selftest")) {
    process.exit(selftest());
  }
  const json = process.argv.includes("--json");
  console.log(formatReport(buildReport(), { json }));
  // Advisory: always exit 0.
  process.exit(0);
}

main();
