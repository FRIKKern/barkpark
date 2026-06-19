#!/usr/bin/env node
// Blast-radius dossier builder + verdict cache — the bridge to the agent layer.
// Fully PROGRAMMATIC (zero tokens). For each seam / dynamic edge flagged in
// last-impact.json it assembles a SELF-CONTAINED payload: the symbol delta
// (diff hunks of the changed side), the consumer code slice on the far side of
// the seam, and the current guard contents. An agent can then judge the edge
// with NO exploration tool calls.
//
// A content-hash cache means an unchanged edge is never re-judged: if a verdict
// already exists for (edgeId, contentHash), the dossier is marked `skip`.
//
// Usage:
//   node dossier.mjs                      # build dossiers for all flagged edges
//   node dossier.mjs --edge seam:http-api-v1
//   node dossier.mjs --json               # print manifest to stdout
//   node dossier.mjs record <edgeId> <contentHash> '<verdict-json>'   # cache a verdict
//   node dossier.mjs cache                # show cache stats

import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, existsSync, mkdirSync, rmSync, readdirSync } from "node:fs";
import { createHash } from "node:crypto";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: HERE }).toString().trim();
const argv = process.argv.slice(2);
const has = (f) => argv.includes(f);
const valOf = (f) => { const i = argv.indexOf(f); return i >= 0 ? argv[i + 1] : null; };
const git = (a) => { try { return execFileSync("git", a, { cwd: ROOT, encoding: "utf8", maxBuffer: 64 * 1024 * 1024 }).trim(); } catch { return ""; } };

const DOSSIER_DIR = join(HERE, "dossiers");
const CACHE_PATH = join(HERE, "verdict-cache.json");

// ---------------------------------------------------------- glob matcher ---
function expand(glob) {
  const m = glob.match(/\{([^{}]+)\}/);
  if (!m) return [glob];
  return m[1].split(",").flatMap((o) => expand(glob.slice(0, m.index) + o + glob.slice(m.index + m[0].length)));
}
function globToRe(glob) {
  let re = "";
  for (let i = 0; i < glob.length; i++) {
    const c = glob[i];
    if (c === "*") { if (glob[i + 1] === "*") { if (glob[i + 2] === "/") { re += "(?:.*/)?"; i += 2; } else { re += ".*"; i += 1; } } else re += "[^/]*"; }
    else if (c === "/") re += "/";
    else if ("+?^${}()|[].\\".includes(c)) re += "\\" + c;
    else re += c;
  }
  return new RegExp("^" + re + "$");
}
const reCache = new Map();
const matchesAny = (path, globs) => globs.some((g) => expand(g).some((e) => {
  if (!reCache.has(e)) reCache.set(e, globToRe(e));
  return reCache.get(e).test(path);
}));

// --------------------------------------------------------------- cache -----
const loadCache = () => (existsSync(CACHE_PATH) ? JSON.parse(readFileSync(CACHE_PATH, "utf8")) : {});
const saveCache = (c) => writeFileSync(CACHE_PATH, JSON.stringify(c, null, 2));

// --------------------------------------------------------- record / cache ---
if (argv[0] === "record") {
  const [, edgeId, contentHash, verdictJson] = argv;
  if (!edgeId || !contentHash || !verdictJson) { console.error("usage: dossier.mjs record <edgeId> <contentHash> '<verdict-json>'"); process.exit(1); }
  const cache = loadCache();
  cache[`${edgeId}@${contentHash}`] = { recordedNote: "verdict from agent layer", verdict: JSON.parse(verdictJson) };
  saveCache(cache);
  console.error(`cached verdict for ${edgeId}@${contentHash}`);
  process.exit(0);
}
if (argv[0] === "cache") {
  const cache = loadCache();
  console.error(`verdict cache: ${Object.keys(cache).length} entr(ies) — ${CACHE_PATH}`);
  for (const k of Object.keys(cache)) console.error(`  ${k} → breaking=${cache[k].verdict?.breaking}`);
  process.exit(0);
}

// ------------------------------------------------------------ slicing -------
const tracked = git(["ls-files"]).split("\n").filter(Boolean);
const isTest = (f) => /(_test\.go|\.test\.[tj]sx?|\.spec\.[tj]sx?|_test\.exs)$/.test(f);
const resolveFiles = (globs) => tracked.filter((f) => matchesAny(f, globs) && !isTest(f));

function fileSlice(relPath, anchorSrc, { win = 10, maxWindows = 4, headLines = 50, capLines = 160 } = {}) {
  let text;
  try { text = readFileSync(join(ROOT, relPath), "utf8"); } catch { return null; }
  const lines = text.split("\n");
  let picked = [];
  if (anchorSrc) {
    const re = new RegExp(anchorSrc);
    const hits = lines.map((l, i) => (re.test(l) ? i : -1)).filter((i) => i >= 0);
    const ranges = [];
    for (const i of hits.slice(0, maxWindows)) ranges.push([Math.max(0, i - win), Math.min(lines.length - 1, i + win)]);
    // merge overlaps
    ranges.sort((a, b) => a[0] - b[0]);
    const merged = [];
    for (const r of ranges) { const last = merged[merged.length - 1]; if (last && r[0] <= last[1] + 1) last[1] = Math.max(last[1], r[1]); else merged.push(r); }
    for (const [a, b] of merged) { for (let i = a; i <= b; i++) picked.push(`${i + 1}: ${lines[i]}`); picked.push("  …"); }
  }
  if (!picked.length) picked = lines.slice(0, headLines).map((l, i) => `${i + 1}: ${l}`);
  if (picked.length > capLines) picked = [...picked.slice(0, capLines), `  … (${picked.length - capLines} more lines elided)`];
  return picked.join("\n");
}

// --------------------------------------------------------- build dossiers --
const cfg = JSON.parse(readFileSync(join(HERE, "config.json"), "utf8"));
const impactPath = join(HERE, "last-impact.json");
if (!existsSync(impactPath)) { console.error("no last-impact.json — run check.mjs first"); process.exit(1); }
const impact = JSON.parse(readFileSync(impactPath, "utf8"));
const diffArgs = impact.range?.diffArgs || ["HEAD~1", "HEAD"];

const slug = (s) => s.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 48);

function changedSlices(changedFiles) {
  return changedFiles.map((f) => {
    const hunk = git(["diff", ...diffArgs, "--", f]);
    const trimmed = hunk.split("\n").slice(0, 220).join("\n");
    return { file: f, diff: trimmed || "(no textual diff in range)" };
  });
}

const MAX_FILES_PER_CONSUMER = 6; // safety net: a loose glob must never explode a dossier
function buildSeamDossier(entry) {
  const surface = cfg.seam.surfaces.find((s) => s.id === entry.id) || {};
  const overmatched = [];
  const consumerSlices = (surface.consumers || []).flatMap((c) => {
    const all = resolveFiles(c.files || []);
    if (all.length > MAX_FILES_PER_CONSUMER) overmatched.push({ consumer: c.label, matched: all.length, kept: MAX_FILES_PER_CONSUMER });
    return all.slice(0, MAX_FILES_PER_CONSUMER)
      .map((f) => ({ consumer: c.label, file: f, code: fileSlice(f, c.anchor) }))
      .filter((x) => x.code); // drop unreadable
  });
  if (overmatched.length) overmatchNotes.push(...overmatched.map((o) => `${entry.id}: consumer "${o.consumer}" matched ${o.matched} files, kept ${o.kept} — tighten its glob`));
  const guardSlices = (surface.guards || []).map((g) => {
    const path = g.split(" (")[0];
    return { guard: g, file: path, code: existsSync(join(ROOT, path)) ? fileSlice(path, null, { headLines: 60 }) : "(guard file not found on disk)" };
  });
  return {
    kind: "seam", edgeId: `seam:${entry.id}`, surface: entry.id,
    changedSlices: changedSlices(entry.changed),
    consumerSlices,
    guardSlices,
    consumersWithoutSlice: (surface.consumers || []).filter((c) => !resolveFiles(c.files || []).length).map((c) => c.label),
  };
}

function buildDynamicDossier(entry) {
  return {
    kind: "dynamic", edgeId: `dyn:${slug(entry.note)}`, note: entry.note, affects: entry.affects,
    changedSlices: changedSlices(entry.changed),
    consumerSlices: [], guardSlices: [],
  };
}

const overmatchNotes = [];
const edges = [
  ...(impact.seamTouched || []).map(buildSeamDossier),
  ...(impact.dynamicEdges || []).map(buildDynamicDossier),
];
const only = valOf("--edge");
const selected = only ? edges.filter((e) => e.edgeId === only) : edges;

if (existsSync(DOSSIER_DIR)) rmSync(DOSSIER_DIR, { recursive: true, force: true });
mkdirSync(DOSSIER_DIR, { recursive: true });

const cache = loadCache();
const manifest = [];
for (const d of selected) {
  // content hash = everything an agent would read. Stable → cache key.
  const payload = { changedSlices: d.changedSlices, consumerSlices: d.consumerSlices, guardSlices: d.guardSlices };
  const contentHash = createHash("sha256").update(JSON.stringify(payload)).digest("hex").slice(0, 16);
  const cacheKey = `${d.edgeId}@${contentHash}`;
  const cached = cache[cacheKey];

  const dossier = {
    edgeId: d.edgeId, kind: d.kind, contentHash, cacheKey,
    skip: !!cached, cachedVerdict: cached?.verdict || null,
    range: impact.range, ...d,
    // the schema the agent layer must emit; promotes blind edges into config.dynamicEdges.
    verdictSchema: { edge_id: "string", breaking: "boolean", confidence: "0..1", evidence: "string", suggested_fix: "string", new_dynamic_edges: "[{from,affects,note}]" },
  };
  const charSize = JSON.stringify(dossier).length;
  const file = join(DOSSIER_DIR, `${slug(d.edgeId)}.json`);
  writeFileSync(file, JSON.stringify(dossier, null, 2));
  manifest.push({ edgeId: d.edgeId, kind: d.kind, contentHash, skip: dossier.skip, file: file.replace(ROOT + "/", ""), estTokens: Math.round(charSize / 4) });
}
writeFileSync(join(DOSSIER_DIR, "manifest.json"), JSON.stringify({ range: impact.range, dossiers: manifest }, null, 2));

if (has("--json")) process.stdout.write(JSON.stringify(manifest, null, 2) + "\n");

// ---------------------------------------------------------------- report ---
const C = process.stderr.isTTY ? { y: "\x1b[33m", g: "\x1b[32m", b: "\x1b[1m", x: "\x1b[0m" } : { y: "", g: "", b: "", x: "" };
const log = (s = "") => process.stderr.write(s + "\n");
const toJudge = manifest.filter((m) => !m.skip);
const skipped = manifest.filter((m) => m.skip);
log(`${C.b}dossiers${C.x}  ${manifest.length} edge(s) → ${DOSSIER_DIR.replace(ROOT + "/", "")}/`);
for (const m of manifest) log(`  ${m.skip ? C.g + "✓ cached " : C.y + "• judge  "}${C.x}${m.edgeId}  (~${m.estTokens} tok, ${m.contentHash})`);
for (const n of overmatchNotes) log(`  ${C.y}⚠ ${n}${C.x}`);
log(`${C.b}→ ${toJudge.length} need judgment, ${skipped.length} cached (skipped), ~${toJudge.reduce((a, m) => a + m.estTokens, 0)} tok to spend${C.x}`);
