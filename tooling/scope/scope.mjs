#!/usr/bin/env node
// scope — the DELIVERY capability (v2 Phase 5).
//
// Turn a task ("add a CLI verb", "harden auth scoping") or an intention id into a
// SCOPED CONTEXT PACK: the metadata-first file set advancing the matched
// intention(s), each with its one-line role/why + reach + deps BOTH directions +
// blast-radius. An agent reads the pack instead of exploring the tree — lookup,
// not crawl.
//
//   node tooling/scope/scope.mjs <intention-id>          # e.g. layered-auth  (or intent-layered-auth)
//   node tooling/scope/scope.mjs "harden auth scoping"   # free-text task → best-matching intention(s)
//   node tooling/scope/scope.mjs --list                  # every intention id + member count
//   node tooling/scope/scope.mjs <task> --json           # machine-readable pack
//   node tooling/scope/scope.mjs <task> --top 25         # cap the file list (default 30)
//
// Reads tooling/barkpark-sync/nodes.json (the generated graph). Pure, dependency-free,
// derived-only — never mutates source.

import { execFileSync } from "node:child_process";
import { readFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: HERE }).toString().trim();
const NODES = join(ROOT, "tooling/barkpark-sync/nodes.json");

const argv = process.argv.slice(2);
const JSON_OUT = argv.includes("--json");
const LIST = argv.includes("--list");
const topIx = argv.indexOf("--top");
const TOP = topIx >= 0 ? Math.max(1, +argv[topIx + 1] || 30) : 30;
const query = argv.filter((a, i) => !a.startsWith("--") && !(topIx >= 0 && i === topIx + 1)).join(" ").trim();

function die(msg, code = 1) { process.stderr.write(msg + "\n"); process.exit(code); }
if (!existsSync(NODES)) die(`scope: ${NODES} not found — run \`node tooling/status/status.mjs\` first to generate the graph.`, 2);

const graph = JSON.parse(readFileSync(NODES, "utf8"));
const all = graph.nodes || [];
const fileNodes = all.filter((n) => n.kind !== "intention");
const intentNodes = all.filter((n) => n.kind === "intention");
const byPath = new Map(fileNodes.map((n) => [n.path, n]));

// intention id is `intent-<slug>`; the human-facing form is the bare slug.
const slugOf = (id) => id.replace(/^intent-/, "");
const intents = intentNodes.map((n) => ({
  id: n.id,
  slug: slugOf(n.id),
  title: n.fields?.title || n.title || slugOf(n.id),
  scale: n.fields?.scale || "",
  description: n.fields?.description || "",
}));

if (LIST) {
  if (JSON_OUT) { process.stdout.write(JSON.stringify(intents.map((i) => ({ id: i.slug, title: i.title, scale: i.scale, members: filesFor(i.id).length })), null, 2) + "\n"); process.exit(0); }
  process.stderr.write(`scope — ${intents.length} intentions (use the slug or the full intent-<slug> id):\n\n`);
  for (const i of intents.sort((a, b) => filesFor(b.id).length - filesFor(a.id).length)) {
    process.stderr.write(`  ${i.slug.padEnd(34)} ${String(filesFor(i.id).length).padStart(3)} files  ${i.scale ? `[${i.scale}] ` : ""}${i.title}\n`);
  }
  process.exit(0);
}

if (!query) die(`scope: give an intention id or a task description.\n\n  node tooling/scope/scope.mjs <intention-id>\n  node tooling/scope/scope.mjs "free-text task"\n  node tooling/scope/scope.mjs --list\n`, 1);

// ---- files advancing an intention (file node carries intentRefs: [intent-<slug>]) ----
function filesFor(intentId) {
  return fileNodes.filter((n) => (n.intentRefs || []).includes(intentId)).map((n) => n.path);
}

// ---- match the query to intention(s) ----
// 1. exact id (slug or intent-<slug>)  2. substring on slug/title  3. word-overlap on title+description.
function matchIntents(q) {
  const norm = (s) => s.toLowerCase();
  const qn = norm(q);
  const qBare = qn.replace(/^intent-/, "");
  // 1. exact id
  const exact = intents.find((i) => i.slug === qBare || i.id === qn);
  if (exact) return { intents: [exact], how: "exact id" };
  // 2. substring on slug or title
  const sub = intents.filter((i) => i.slug.includes(qBare) || norm(i.title).includes(qn));
  if (sub.length) return { intents: sub.slice(0, 3), how: "name match" };
  // 3. word-overlap scoring on title + description
  const stop = new Set(["the", "a", "an", "to", "of", "for", "and", "or", "in", "on", "with", "add", "fix", "make", "this", "that", "is", "are", "via", "from", "into"]);
  const qWords = qn.split(/[^a-z0-9]+/).filter((w) => w.length > 2 && !stop.has(w));
  const scored = intents.map((i) => {
    const hay = norm(i.title + " " + i.description + " " + i.slug.replace(/-/g, " "));
    const hayWords = new Set(hay.split(/[^a-z0-9]+/).filter(Boolean));
    let s = 0;
    for (const w of qWords) if (hayWords.has(w)) s += 2; else if (hay.includes(w)) s += 1;
    return { i, s };
  }).filter((x) => x.s > 0).sort((a, b) => b.s - a.s);
  if (scored.length) return { intents: scored.slice(0, 3).map((x) => x.i), how: "keyword match" };
  return { intents: [], how: "no match" };
}

const { intents: matched, how } = matchIntents(query);
if (!matched.length) {
  die(`scope: no intention matched "${query}".\n  Try \`node tooling/scope/scope.mjs --list\` to see the ${intents.length} intentions.\n`, 1);
}

// ---- assemble the context pack ----
// union the member files across matched intentions, dedup, rank by reach (the value root).
const memberPaths = new Set();
for (const m of matched) for (const p of filesFor(m.id)) memberPaths.add(p);

const packFiles = [...memberPaths]
  .map((p) => byPath.get(p))
  .filter(Boolean)
  .map((n) => {
    const f = n.fields || {};
    const deps = (n.depPaths || []).filter((d) => d);            // this file → depends on
    const dependents = (f.dependents || []).filter((d) => d);    // depends on this file ←
    return {
      path: n.path,
      role: f.role || "",
      why: f.why || "",
      whatBreaks: f.whatBreaks || "",
      reach: f.reach ?? 0,                                        // normalized 0–100 value root
      blastRadius: f.dependentCount ?? dependents.length,        // # files that break if this changes
      importance: f.importance ?? 0,
      stack: f.stack || "",
      hasTest: !!f.hasTest,
      depends_on: deps,
      depended_on_by: dependents,
    };
  })
  .sort((a, b) => (b.reach - a.reach) || (b.blastRadius - a.blastRadius));

const capped = packFiles.slice(0, TOP);

const pack = {
  query,
  matchedBy: how,
  intentions: matched.map((m) => ({ id: m.slug, title: m.title, scale: m.scale, description: m.description })),
  fileCount: packFiles.length,
  shown: capped.length,
  files: capped,
  note: packFiles.length > capped.length
    ? `${packFiles.length - capped.length} lower-reach files omitted — pass --top ${packFiles.length} for the full set.`
    : "complete file set for the matched intention(s).",
};

if (JSON_OUT) { process.stdout.write(JSON.stringify(pack, null, 2) + "\n"); process.exit(0); }

// ---- human-readable pack (stdout — so it pipes cleanly) ----
const o = (s = "") => process.stdout.write(s + "\n");
o(`SCOPED CONTEXT PACK  —  "${query}"  (${how})`);
o(`═`.repeat(72));
for (const m of pack.intentions) {
  o(`  ▸ ${m.id}${m.scale ? `  [${m.scale}]` : ""}  ${m.title}`);
  if (m.description) o(`      ${m.description}`);
}
o("");
o(`  ${pack.fileCount} files advance this scope (showing top ${pack.shown} by reach). Read these — don't crawl the tree.`);
o(`─`.repeat(72));
for (const f of capped) {
  const flags = [`reach ${f.reach}`, `blast ${f.blastRadius}`, f.hasTest ? "tested" : "UNTESTED"].join(" · ");
  o(`  ${f.path}`);
  o(`     ${f.role || "(no role)"}  ·  ${flags}`);
  if (f.whatBreaks) o(`     breaks if changed: ${f.whatBreaks}`);
  if (f.depends_on.length) o(`     → depends on: ${f.depends_on.slice(0, 6).join(", ")}${f.depends_on.length > 6 ? ` (+${f.depends_on.length - 6})` : ""}`);
  if (f.depended_on_by.length) o(`     ← depended on by: ${f.depended_on_by.slice(0, 6).join(", ")}${f.depended_on_by.length > 6 ? ` (+${f.depended_on_by.length - 6})` : ""}`);
  o("");
}
o(`  ${pack.note}`);
o(`  (machine-readable: add --json · narrow: --top N · discover: --list)`);
