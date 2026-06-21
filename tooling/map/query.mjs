#!/usr/bin/env node
// query.mjs — the QUERY LAYER. One agent-facing CLI over the understanding
// substrate, so an agent has a single place to consult BEFORE acting and can
// never trust a stale map.
//
//   query verify            → is the map current? (the freshness GATE)
//   query verify --docs [g] → are the DOCS truthful? (the doc-truth verifier)
//   query waterfall         → is any fact RESTATED across docs? (collapse leads)
//   query highways          → does the routing table still resolve? (topic→owner)
//   query priority          → which code is UNDER-documented by reach? (work queue)
//   query remake            → gate a doc restructure: lose no fact/link → human/reject
//   query impact <file|sym> → what breaks if I change X? (blast radius + risk)
//   query scope <feature>   → what files do I touch for feature Y? (context pack)
//   query                   → usage that frames the three
//
// This is a THIN FACADE. It owns no graph logic of its own — it composes three
// existing tools via child_process and brackets two of them with a currency
// gate:
//
//   verify  →  manifest.mjs verify   (the gate itself)
//   impact  →  what-breaks.mjs       (gated: stale-map ⚠ banner first)
//   scope   →  scope.mjs             (gated: stale-map ⚠ banner first)
//
// CONFIDENCE TAGS — every answer mixes two kinds of fact:
//   • PARSED  (high confidence) — deps, closure, symbols, reach, coverage. A
//     parser computed these from the tree; they are ground truth for that tree.
//   • JUDGED  (graded)          — a file's role / description / intention. An
//     agent inferred these; they are opinion, not measurement.
// We print a one-line legend on every gated answer, and pull each file's
// agent-JUDGED role/description from nodes.json so the agent sees provenance.
//
// Dependency-free. No reimplementation of the underlying tools.

import { execFileSync, spawnSync } from "node:child_process";
import { readFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: HERE })
  .toString()
  .trim();

const MANIFEST_MJS = join(HERE, "manifest.mjs");
const WHAT_BREAKS_MJS = join(HERE, "what-breaks.mjs");
const VERIFY_DOCS_MJS = join(ROOT, "tooling/doc-truth/verify-docs.mjs");
const WATERFALL_MJS = join(ROOT, "tooling/doc-truth/waterfall.mjs");
const HIGHWAYS_MJS = join(ROOT, "tooling/doc-truth/highways.mjs");
const PRIORITY_MJS = join(ROOT, "tooling/doc-truth/priority.mjs");
const REMAKE_MJS = join(ROOT, "tooling/doc-truth/remake.mjs");
const SCOPE_MJS = join(ROOT, "tooling/scope/scope.mjs");
const NODES = join(ROOT, "tooling/barkpark-sync/nodes.json");

// ── currency gate ──────────────────────────────────────────────────────────
// Import the manifest verifier in-process (no spawn) so the gate is cheap and
// its structured verdict is available before we even decide to delegate.
import { verifyManifest } from "./manifest.mjs";

function currency() {
  try {
    return verifyManifest();
  } catch (e) {
    return { ok: false, reason: "verify-failed", message: String(e && e.message || e) };
  }
}

// The ⚠ banner an agent sees before any impact/scope answer when the map drifted.
function staleBanner(v) {
  const lines = [];
  if (v.reason === "no-manifest") {
    lines.push("⚠  MAP CURRENCY UNKNOWN — no manifest pinned.");
    lines.push("   The answer below may not reflect the live tree.");
    lines.push("   Run:  node tooling/map/manifest.mjs build   (then re-index the map)");
  } else {
    const c = v.counts || {};
    lines.push(`⚠  MAP IS STALE — ${c.stale || 0} changed · ${c.added || 0} added · ${c.deleted || 0} deleted · ${c.dirty || 0} dirty.`);
    lines.push("   The answer below may NOT reflect the live tree — it was computed against an");
    lines.push("   older snapshot. Rebuild before you trust it:");
    lines.push("   Run:  node tooling/map/manifest.mjs build && re-index");
    const drift = [
      ...(v.dirty || []).map((p) => `${p}  (dirty)`),
      ...(v.stale || []).map((p) => `${p}  (changed)`),
      ...(v.added || []).map((p) => `${p}  (added)`),
      ...(v.deleted || []).map((p) => `${p}  (deleted)`),
    ];
    if (drift.length) {
      lines.push("   drifted slices/files:");
      for (const d of drift.slice(0, 12)) lines.push(`     • ${d}`);
      if (drift.length > 12) lines.push(`     … and ${drift.length - 12} more`);
    }
  }
  const bar = "═".repeat(74);
  return ["", bar, ...lines, bar, ""].join("\n");
}

// ── confidence legend + JUDGED provenance from nodes.json ───────────────────
const LEGEND =
  "confidence:  [PARSED] deps · closure · symbols · reach · coverage  (ground truth) " +
  "·  [JUDGED] role · description · intention  (agent-inferred)";

let _nodesByPath = null;
function nodesByPath() {
  if (_nodesByPath) return _nodesByPath;
  _nodesByPath = new Map();
  if (existsSync(NODES)) {
    try {
      const doc = JSON.parse(readFileSync(NODES, "utf8"));
      const nodes = doc.nodes || doc.files || doc;
      for (const n of nodes) if (n && n.path) _nodesByPath.set(n.path, n);
    } catch { /* leave map empty — the legend still prints */ }
  }
  return _nodesByPath;
}

// The agent-JUDGED facts for one file, labelled so provenance is explicit.
function judgedFor(path) {
  const n = nodesByPath().get(path);
  const f = (n && n.fields) || {};
  return { role: f.role || null, description: f.description || null };
}

// ── delegation ──────────────────────────────────────────────────────────────
// Run an existing tool, streaming its stdout/stderr straight through so its
// own (already-tested) formatting reaches the user verbatim. We never parse or
// rewrite the delegate's body — facade, not reimplementation.
function delegate(script, argv) {
  const r = spawnSync(process.execPath, [script, ...argv], {
    cwd: ROOT,
    stdio: "inherit",
  });
  if (r.error) {
    process.stderr.write(`query: failed to run ${script}: ${r.error.message}\n`);
    return 2;
  }
  return r.status === null ? 1 : r.status;
}

// ── verb: verify ─────────────────────────────────────────────────────────────
// Two gates under one verb:
//   query verify            → MAP currency gate (manifest.mjs). Exit 0 current /
//                             non-zero stale — this IS the gate CI branches on.
//   query verify --docs [g] → DOC-TRUTH verifier (doc-truth/verify-docs.mjs).
//                             Parses docs into typed claims, checks them against
//                             ground truth behind a re-verify gate. Pass-through.
function cmdVerify(rest) {
  if (rest.includes("--docs")) {
    const passthrough = rest.filter((a) => a !== "--docs");
    return delegate(VERIFY_DOCS_MJS, passthrough);
  }
  return delegate(MANIFEST_MJS, ["verify", ...rest]);
}

// ── verb: waterfall ──────────────────────────────────────────────────────────
// "Each fact once." The P2 restatement detector: finds sections that restate the
// same VERIFIABLE-CLAIM anchors (not prose) and proposes — never applies —
// collapsing the duplicates to one canonical home plus typed pointers. Pure
// pass-through to the doc-truth waterfall tool (facade, not reimplementation).
//   query waterfall                       → clusters + collapse proposals
//   query waterfall --topic <fk-substr>   → a fact's canonical doc+section + all
//                                           docs carrying pointers (the DAG query)
function cmdWaterfall(rest) {
  return delegate(WATERFALL_MJS, rest);
}

// ── verb: highways ─────────────────────────────────────────────────────────────
// "Does the map still work?" The P3 routing check: every entry in the root
// CLAUDE.md routing table must reach exactly one canonical owner doc in ≤2 hops,
// each canonical-for topic must have one owner, and byte budgets / 7-card cap
// must hold. Pure pass-through to the doc-truth highways tool (facade).
//   query highways            → routing resolution + orphans + dup owners + budget
//   query highways --json     → { routes, orphans, duplicateOwners, budget }
function cmdHighways(rest) {
  return delegate(HIGHWAYS_MJS, rest);
}

// ── verb: priority ─────────────────────────────────────────────────────────────
// "Is documentation proportioned to reach?" The P4 coverage scorer: joins doc
// coverage against blast-radius reach + churn and ranks the gaps — high-reach code
// no doc names (write-new / extend-canonical), and trivia that's over-documented.
// Pure pass-through to the doc-truth priority tool (facade).
//   query priority            → ranked under/over-documented work queue
//   query priority --json     → { queue, overDocumented, buildSpec }
function cmdPriority(rest) {
  return delegate(PRIORITY_MJS, rest);
}

// ── verb: remake ─────────────────────────────────────────────────────────────
// "Can this doc restructure land safely?" The P5 never-worse remake gate: it
// evaluates a proposed merge/split/promote/rewrite and lets it land ONLY if it
// loses no verifiable fact (P1's extractor) and no outbound link, with every
// routing/pointer anchor (P3) surviving. Destructive or canonical-touching
// remakes route to HUMAN review — never silent auto-apply. The gate NEVER writes
// a doc. The CLI shows the human-review queue + recent rejects from the failure
// log. Pure pass-through to the doc-truth remake tool (facade).
//   query remake            → human-review queue + recent rejects
//   query remake --json     → { humanQueue, recentRejects, failureLog }
function cmdRemake(rest) {
  return delegate(REMAKE_MJS, rest);
}

// ── verb: impact ─────────────────────────────────────────────────────────────
// Blast-radius / risk for a file or symbol. GATE FIRST: if the map is stale we
// print the ⚠ banner before the result so the agent is never silently misled.
function cmdImpact(rest) {
  const wantJson = rest.includes("--json");
  const v = currency();

  if (!v.ok && !wantJson) process.stdout.write(staleBanner(v));
  if (!wantJson) process.stdout.write(LEGEND + "\n");

  const code = delegate(WHAT_BREAKS_MJS, rest);

  // After the parsed report, surface the agent-JUDGED role/description for the
  // queried file so its provenance is explicit (what-breaks prints role inline,
  // but unlabelled — we re-state it as JUDGED). Skip in --json (the underlying
  // tool already emits machine-readable structure; we don't wrap it).
  if (!wantJson) {
    const target = rest.find((a) => !a.startsWith("--") && !isSymbolValue(rest, a));
    if (target) {
      const j = judgedFor(target);
      if (j.role || j.description) {
        process.stdout.write("\n[JUDGED] agent-inferred provenance for the queried file:\n");
        if (j.role) process.stdout.write(`  role:        ${j.role}\n`);
        if (j.description) process.stdout.write(`  description: ${j.description}\n`);
      }
    }
  }
  return code;
}

// the value of --symbol is not a positional file arg
function isSymbolValue(argv, a) {
  const i = argv.findIndex((x) => x === "--symbol");
  return i !== -1 && argv[i + 1] === a;
}

// ── verb: scope ──────────────────────────────────────────────────────────────
// Context pack for a feature / intention. GATE FIRST, same contract as impact.
// scope.mjs already labels role/why per file; we add the global legend so the
// agent knows those per-file roles are JUDGED, not parsed.
function cmdScope(rest) {
  const wantJson = rest.includes("--json");
  const listing = rest.includes("--list");
  const v = currency();

  // --list is a pure discovery call (no per-file facts to mistrust) — still
  // banner it when stale, because the intention membership itself can drift.
  if (!v.ok && !wantJson) process.stdout.write(staleBanner(v));
  if (!wantJson && !listing) process.stdout.write(LEGEND + "\n\n");

  return delegate(SCOPE_MJS, rest);
}

// ── usage ────────────────────────────────────────────────────────────────────
function usage() {
  const out = `query — one place to consult BEFORE you act. Never trust a stale map.

  ${LEGEND}

  USAGE
    node tooling/map/query.mjs <verb> [args] [--json]

  VERBS
    verify                     Is the map CURRENT?  Runs the freshness gate.
                               Exit 0 = current, non-zero = stale. This is the
                               gate every other answer is checked against.

    verify --docs [glob...]    Are the DOCS truthful?  The doc-truth verifier
                               parses docs into typed claims (path · symbol ·
                               route · lineref · command) and checks each
                               against ground truth behind a RE-VERIFY GATE.
                               Defaults to the 92-doc audit corpus; pass globs
                               to scope. Flags: --json
                               e.g. query verify --docs docs/ops/
                                    query verify --docs js/CLAUDE.md --json

    waterfall                  Is any fact RESTATED across docs?  Finds sections
                               that share a set of verifiable-claim anchors (the
                               same paths/commands/symbols, NOT prose) and
                               PROPOSES — never applies — collapsing them to one
                               canonical home + typed pointers. Conservative:
                               propose-only, lose-no-fact enforced.
                               Flags: --json  --topic <factKey-substr>
                               e.g. query waterfall
                                    query waterfall --topic systemctl --json

    highways                   Does the routing table still resolve?  Every entry
                               in the root CLAUDE.md routing table must reach one
                               canonical owner doc in ≤2 hops; flags orphans,
                               duplicate owners, and budget / 7-card-cap breaches.
                               Flags: --json
                               e.g. query highways --json

    priority                   Which code is UNDER-documented by reach?  Joins doc
                               coverage against blast-radius reach + churn and ranks
                               the gaps (write-new / extend-canonical) plus the
                               over-documented trivia.
                               Flags: --json
                               e.g. query priority --json

    remake                     Can a doc RESTRUCTURE land safely?  The never-worse
                               gate evaluates a proposed merge/split/promote/rewrite
                               and lets it land ONLY if it loses no verifiable fact
                               (P1's extractor) and no outbound link, with every
                               routing/pointer anchor (P3) surviving. Destructive or
                               canonical-touching remakes route to HUMAN review —
                               never silent auto-apply. Propose-only: the gate never
                               writes a doc. The CLI shows the human-review queue +
                               recent rejects.
                               Flags: --json
                               e.g. query remake --json

    impact <file|symbol>       What breaks if I change X?  Blast-radius closure,
                               symbol-precise + cross-language reach, and a
                               LOW/MEDIUM/HIGH/CRITICAL risk verdict.
                               Flags: --symbol <Module|Module.fun>  --json
                               If the map is stale, a ⚠ banner fires FIRST.

    scope <feature|intention>  What files do I touch for feature Y?  A ranked
                               context pack — read these instead of crawling.
                               Flags: --list (all intentions)  --top N  --json
                               If the map is stale, a ⚠ banner fires FIRST.

  EXAMPLES
    node tooling/map/query.mjs verify
    node tooling/map/query.mjs verify --docs
    node tooling/map/query.mjs verify --docs docs/ops/ --json
    node tooling/map/query.mjs impact api/lib/barkpark/content.ex
    node tooling/map/query.mjs impact api/lib/barkpark/content.ex --symbol Content
    node tooling/map/query.mjs scope --list
    node tooling/map/query.mjs scope "harden auth scoping"

  Every impact/scope answer is bracketed by the currency gate: a stale map is
  flagged with a ⚠ banner before the result, so you are never silently misled.
  Structural facts are PARSED (ground truth); roles/descriptions/intentions are
  JUDGED (agent-inferred). Pass --json on any verb for machine-readable output.
`;
  process.stdout.write(out);
}

// ── CLI ──────────────────────────────────────────────────────────────────────
function main() {
  const [verb, ...rest] = process.argv.slice(2);

  switch (verb) {
    case "verify":
      process.exit(cmdVerify(rest));
      break;
    case "waterfall":
      process.exit(cmdWaterfall(rest));
      break;
    case "highways":
      process.exit(cmdHighways(rest));
      break;
    case "priority":
      process.exit(cmdPriority(rest));
      break;
    case "remake":
      process.exit(cmdRemake(rest));
      break;
    case "impact":
      if (!rest.some((a) => !a.startsWith("--") || a === "--symbol")) {
        process.stderr.write("query impact: give a <file> or --symbol <name>.\n");
        process.exit(2);
      }
      process.exit(cmdImpact(rest));
      break;
    case "scope":
      process.exit(cmdScope(rest));
      break;
    case undefined:
    case "help":
    case "-h":
    case "--help":
      usage();
      process.exit(0);
      break;
    default:
      process.stderr.write(`query: unknown verb "${verb}".\n\n`);
      usage();
      process.exit(2);
  }
}

main();
