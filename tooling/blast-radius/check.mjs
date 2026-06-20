#!/usr/bin/env node
// Blast-radius checker — the FAST half. This is what the pre-push hook runs.
// It NEVER invokes a compiler. It only: (1) reads the git diff, (2) looks each
// changed file up in the cached index.json reverse-dependency graph, (3) matches
// the seam registry. Pure JSON traversal → milliseconds.
//
// Output: a human summary (stderr) + a structured impact-set (last-impact.json)
// that later seeds the agentic layer. Warn-only by default; --strict exits 1
// when the cross-language seam is touched.
//
// Usage:
//   node tooling/blast-radius/check.mjs            # diff @{u}..HEAD (pre-push default)
//   node tooling/blast-radius/check.mjs --staged   # staged files (pre-commit)
//   node tooling/blast-radius/check.mjs --range A..B
//   node tooling/blast-radius/check.mjs --json      # print impact-set JSON to stdout

import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: HERE }).toString().trim();
const argv = process.argv.slice(2);
const has = (f) => argv.includes(f);
const valOf = (f) => { const i = argv.indexOf(f); return i >= 0 ? argv[i + 1] : null; };

const git = (a) => { try { return execFileSync("git", a, { cwd: ROOT, encoding: "utf8" }).trim(); } catch { return ""; } };

// --------------------------------------------------------- changed files ---
// Resolve the diff window ONCE and record the raw `git diff` args, so the
// dossier builder can reproduce the exact hunks without re-guessing the range.
function resolveRange() {
  if (valOf("--range")) return { diffArgs: [valOf("--range")], label: valOf("--range") };
  if (has("--staged")) return { diffArgs: ["--cached"], label: "staged" };
  const base = git(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"]) || "origin/main";
  const mb = git(["merge-base", base, "HEAD"]) || "HEAD~1";
  return { diffArgs: [mb, "HEAD"], label: `${base}..HEAD` };
}
const RANGE = resolveRange();
function changedFiles() {
  return git(["diff", "--name-only", ...RANGE.diffArgs]).split("\n").filter(Boolean);
}

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
    if (c === "*") {
      if (glob[i + 1] === "*") {
        if (glob[i + 2] === "/") { re += "(?:.*/)?"; i += 2; } else { re += ".*"; i += 1; }
      } else re += "[^/]*";
    } else if (c === "/") re += "/";
    else if ("+?^${}()|[].\\".includes(c)) re += "\\" + c;
    else re += c;
  }
  return new RegExp("^" + re + "$");
}
const reCache = new Map();
function matchesAny(path, globs) {
  for (const g of globs) {
    for (const e of expand(g)) {
      if (!reCache.has(e)) reCache.set(e, globToRe(e));
      if (reCache.get(e).test(path)) return true;
    }
  }
  return false;
}

// ------------------------------------------------------ reverse closure ----
function closure(seeds, reverse) {
  const seen = new Set(), out = new Set(), q = [...seeds];
  while (q.length) {
    const n = q.shift();
    if (seen.has(n)) continue;
    seen.add(n);
    for (const dep of reverse[n] || []) { if (!out.has(dep)) { out.add(dep); q.push(dep); } }
  }
  return [...out];
}
function longestPrefixKey(path, map) {
  let best = null;
  for (const dir of Object.keys(map)) {
    if (dir === "." ? true : path === dir || path.startsWith(dir + "/")) {
      if (!best || dir.length > best.length) best = dir;
    }
  }
  return best;
}

// ------------------------------------------------------------------ main ---
const cfg = JSON.parse(readFileSync(join(HERE, "config.json"), "utf8"));
const idxPath = join(HERE, "index.json");
const idx = existsSync(idxPath) ? JSON.parse(readFileSync(idxPath, "utf8")) : null;

const files = changedFiles();
const inStack = (f, s) => matchesAny(f, cfg.stacks[s].match) && !matchesAny(f, cfg.stacks[s].exclude || []);

const impact = {
  range: RANGE,
  changed: files,
  reachable: { js: [], go: [], elixir: [] },
  seamTouched: [],
  dynamicEdges: [],
  indexPresent: !!idx,
  notes: [],
};

// --- per-stack reachability ---
if (files.length) {
  const jsFiles = files.filter((f) => inStack(f, "js"));
  const goFiles = files.filter((f) => inStack(f, "go"));
  const exFiles = files.filter((f) => inStack(f, "elixir"));

  if (jsFiles.length && idx?.js) {
    const seeds = new Set();
    for (const f of jsFiles) { const d = longestPrefixKey(f, idx.js.dirToName); if (d) seeds.add(idx.js.dirToName[d]); }
    impact.reachable.js = closure([...seeds], idx.js.reverse).sort();
    impact._jsSeeds = [...seeds].sort();
  } else if (jsFiles.length) impact.notes.push("js: index missing — file-level only");

  if (goFiles.length && idx?.go) {
    const seeds = new Set();
    for (const f of goFiles) { const d = longestPrefixKey(dirname(f), idx.go.dirToPkg); if (d) seeds.add(idx.go.dirToPkg[d]); }
    impact.reachable.go = closure([...seeds], idx.go.reverse).sort();
    impact._goSeeds = [...seeds].sort();
  } else if (goFiles.length) impact.notes.push("go: index missing — file-level only");

  if (exFiles.length && idx?.elixir) {
    impact.reachable.elixir = closure(exFiles, idx.elixir.reverse).sort();
  } else if (exFiles.length) impact.notes.push("elixir: no index (coarse stack) — seam + file-level only");
}

// --- seam (needs NO index; highest value) ---
for (const s of cfg.seam.surfaces) {
  const hits = files.filter((f) => matchesAny(f, s.globs));
  if (hits.length) impact.seamTouched.push({ id: s.id, changed: hits, consumers: s.consumers, guards: s.guards });
}

// --- dynamic edges (agent-promoted blind spots) ---
for (const e of cfg.dynamicEdges.edges || []) {
  const hits = files.filter((f) => matchesAny(f, e.from));
  if (hits.length) impact.dynamicEdges.push({ note: e.note, changed: hits, affects: e.affects });
}

writeFileSync(join(HERE, "last-impact.json"), JSON.stringify(impact, null, 2));
if (has("--json")) process.stdout.write(JSON.stringify(impact, null, 2) + "\n");

// ---------------------------------------------------------------- report ---
const C = process.stderr.isTTY ? { r: "\x1b[31m", y: "\x1b[33m", g: "\x1b[32m", b: "\x1b[1m", x: "\x1b[0m" } : { r: "", y: "", g: "", b: "", x: "" };
const log = (s = "") => process.stderr.write(s + "\n");

log(`${C.b}blast-radius${C.x}  ${files.length} changed file(s)${idx ? "" : `  ${C.y}[no index — run build-index.mjs for cross-package reach]${C.x}`}`);
if (!files.length) { log("  (nothing to analyze)"); process.exit(0); }

const r = impact.reachable;
if (r.js.length) log(`  js     → affects ${C.b}${r.js.length}${C.x} package(s): ${r.js.join(", ")}`);
if (r.go.length) log(`  go     → affects ${C.b}${r.go.length}${C.x} package(s)`);
if (r.elixir.length) log(`  elixir → recompiles ${C.b}${r.elixir.length}${C.x} file(s)`);
for (const n of impact.notes) log(`  ${C.y}· ${n}${C.x}`);

if (impact.seamTouched.length) {
  log("");
  log(`${C.r}${C.b}⚠ CROSS-LANGUAGE SEAM TOUCHED — no single-language graph sees this${C.x}`);
  for (const s of impact.seamTouched) {
    log(`  ${C.r}▸ ${s.id}${C.x}  (${s.changed.join(", ")})`);
    for (const c of s.consumers) log(`      breaks? → ${c.label}`);
    for (const g of s.guards) log(`      guard   → ${g}`);
  }
  log(`  ${C.y}These are the edges to hand to a blast-radius agent.${C.x}`);
}
for (const d of impact.dynamicEdges) {
  log(`${C.y}⚠ dynamic edge: ${d.note} → ${d.affects.join(", ")}${C.x}`);
}

if (!impact.seamTouched.length && !impact.dynamicEdges.length) log(`  ${C.g}✓ no seam / dynamic edges touched${C.x}`);

process.exit(has("--strict") && impact.seamTouched.length ? 1 : 0);
