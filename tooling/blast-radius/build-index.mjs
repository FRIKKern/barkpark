#!/usr/bin/env node
// Blast-radius index builder — the SLOW, out-of-band half.
// Runs occasionally (CI, or `node build-index.mjs` by hand). It invokes the
// language toolchains (go list, mix xref) ONCE and writes a cached reverse-
// dependency graph to index.json. The pre-push hook (check.mjs) only READS
// this file — it never shells out to a compiler, so it stays millisecond-fast.
//
// Usage: node tooling/blast-radius/build-index.mjs
//        node tooling/blast-radius/build-index.mjs --skip-elixir

import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, readdirSync, existsSync, statSync } from "node:fs";
import { join, relative, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { createHash } from "node:crypto";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: HERE }).toString().trim();
const args = new Set(process.argv.slice(2));

const sh = (cmd, a, opts = {}) =>
  execFileSync(cmd, a, { cwd: ROOT, encoding: "utf8", maxBuffer: 256 * 1024 * 1024, ...opts });

function reverseOf(forward) {
  // forward: { node: [deps...] }  →  reverse: { dep: [nodes-that-depend-on-it] }
  const rev = {};
  for (const [node, deps] of Object.entries(forward)) {
    for (const d of deps) (rev[d] ||= []).push(node);
  }
  for (const k of Object.keys(rev)) rev[k] = [...new Set(rev[k])].sort();
  return rev;
}

// ---------------------------------------------------------------- JS / TS ---
// Workspace dep graph from package.json files alone — no tsc, no install.
function buildJs() {
  const pkgFiles = [];
  const scanRoots = ["js/packages", "web", "sdk", "packages"];
  const walk = (dir, depth = 0) => {
    if (depth > 4) return;
    let entries;
    try { entries = readdirSync(join(ROOT, dir), { withFileTypes: true }); } catch { return; }
    for (const e of entries) {
      if (e.name === "node_modules" || e.name === "dist" || e.name === "_attic" || e.name.startsWith(".")) continue;
      const rel = join(dir, e.name);
      if (e.isDirectory()) walk(rel, depth + 1);
      else if (e.name === "package.json") pkgFiles.push(rel);
    }
  };
  for (const r of scanRoots) walk(r);

  const nameToInfo = {};   // pkgName -> { dir, deps: [internal names] }
  const dirToName = {};    // relDir  -> pkgName
  const internalNames = new Set();

  const parsed = [];
  for (const f of pkgFiles) {
    try {
      const j = JSON.parse(readFileSync(join(ROOT, f), "utf8"));
      if (!j.name) continue;
      parsed.push({ file: f, j });
      internalNames.add(j.name);
    } catch { /* skip unparseable */ }
  }
  for (const { file, j } of parsed) {
    const dir = dirname(file);
    const allDeps = { ...j.dependencies, ...j.devDependencies, ...j.peerDependencies };
    const internal = Object.keys(allDeps).filter((k) => internalNames.has(k));
    nameToInfo[j.name] = { dir, deps: internal };
    dirToName[dir] = j.name;
  }
  const forward = Object.fromEntries(Object.entries(nameToInfo).map(([n, i]) => [n, i.deps]));
  return { dirToName, forward, reverse: reverseOf(forward) };
}

// -------------------------------------------------------------------- Go ---
function buildGo() {
  let raw;
  try { raw = sh("go", ["list", "-deps", "-json", "./..."]); }
  catch (e) { console.error("[go] skipped:", e.message.split("\n")[0]); return null; }

  // `go list -json` emits concatenated JSON objects; split on `}\n{`.
  const objs = [];
  let depth = 0, start = 0;
  for (let i = 0; i < raw.length; i++) {
    const c = raw[i];
    if (c === "{") { if (depth === 0) start = i; depth++; }
    else if (c === "}") { depth--; if (depth === 0) { try { objs.push(JSON.parse(raw.slice(start, i + 1))); } catch {} } }
  }
  const MOD = "github.com/FRIKKern/barkpark";
  const forward = {};   // importPath -> [internal imports]
  const dirToPkg = {};  // relDir -> importPath
  for (const o of objs) {
    if (!o.ImportPath || !o.ImportPath.startsWith(MOD)) continue;
    if (o.Dir) dirToPkg[relative(ROOT, o.Dir) || "."] = o.ImportPath;
    forward[o.ImportPath] = (o.Imports || []).filter((p) => p.startsWith(MOD));
  }
  return { dirToPkg, forward, reverse: reverseOf(forward) };
}

// ---------------------------------------------------------------- Elixir ---
// Best-effort. `mix xref graph` needs compiled artifacts and the right Elixir;
// failure is non-fatal — check.mjs falls back to file-level + seam for Elixir.
function buildElixir() {
  if (args.has("--skip-elixir")) { console.error("[elixir] skipped (--skip-elixir)"); return null; }
  // Warm the symbol graph. `mix xref` needs compiled artifacts; without `_build`
  // the old code SILENTLY skipped → the densest dependency layer (286 files)
  // vanished on every fresh clone and in CI. Compile once so the dense graph is
  // RELIABLE, not contingent on someone having run `mix compile` first.
  // Opt out with --no-elixir-compile for offline / no-toolchain contexts.
  if (!existsSync(join(ROOT, "api/_build"))) {
    if (args.has("--no-elixir-compile")) { console.error("[elixir] skipped (api/_build absent, --no-elixir-compile)"); return null; }
    console.error("[elixir] api/_build absent — warming via `mix compile` (one-time, ~min)…");
    try { sh("mix", ["compile"], { cwd: join(ROOT, "api"), env: { ...process.env, MIX_ENV: "dev" }, stdio: ["ignore", "ignore", "inherit"] }); }
    catch (e) { console.error("[elixir] compile failed — falling back to regex scan:", e.message.split("\n")[0]); return null; }
  }
  // `mix xref graph --format dot` writes to api/xref_graph.dot by default; `--output -`
  // streams the FULL module→module graph (compile + export + runtime edges) to stdout.
  // The full graph is the real, dense dependency truth — far denser than the regex
  // alias/import scan generate.mjs falls back to. This compiles (a few min); failure is
  // non-fatal — generate.mjs then resolves Elixir edges itself.
  let dot;
  try { dot = sh("mix", ["xref", "graph", "--format", "dot", "--output", "-"], { cwd: join(ROOT, "api"), env: { ...process.env, MIX_ENV: "dev" } }); }
  catch (e) { console.error("[elixir] skipped:", e.message.split("\n")[0]); return null; }

  // dot edges: "lib/a.ex" -> "lib/b.ex" [label="(compile)"]   (a references b).
  // Paths are relative to api/, so prefix. Keep ALL edge types (compile/export/runtime).
  const forward = {};
  for (const m of dot.matchAll(/"([^"]+)"\s*->\s*"([^"]+)"/g)) {
    const a = "api/" + m[1], b = "api/" + m[2];
    if (a === b) continue;
    (forward[a] ||= []).push(b);
  }
  for (const k of Object.keys(forward)) forward[k] = [...new Set(forward[k])];
  return { forward, reverse: reverseOf(forward) };
}

// ---- Elixir cache: a content signature over api/ .ex/.exs (committed blobs +
// uncommitted edits). mix xref compiles (~min), so we only re-run it when the
// signature changes — restoring status.mjs's fast path when Elixir is unchanged.
function elixirSig() {
  try {
    const lines = sh("git", ["ls-files", "-s", "api"]).split("\n").filter((l) => /\.exs?$/.test(l)).sort();
    const dirty = sh("git", ["status", "--porcelain", "api"]).split("\n").filter((l) => /\.exs?$/.test(l)).sort().join("|");
    return createHash("sha256").update(lines.join("\n") + "##" + dirty).digest("hex").slice(0, 16);
  } catch { return ""; }
}

// ------------------------------------------------------------------- main ---
const out = join(HERE, "index.json");
const prior = existsSync(out) ? JSON.parse(readFileSync(out, "utf8")) : {};
const esig = elixirSig();
let elixir, savedSig;
if (!args.has("--skip-elixir") && esig && prior.elixirSig === esig && prior.elixir) {
  elixir = prior.elixir; savedSig = esig;
  console.error("[elixir] reused cache — no .ex changes (skipped mix xref)");
} else {
  elixir = buildElixir();
  savedSig = args.has("--skip-elixir") ? prior.elixirSig : esig;  // keep prior sig when skipping
}

const index = {
  builtAtNote: "regenerate with: node tooling/blast-radius/build-index.mjs",
  head: sh("git", ["rev-parse", "HEAD"]).trim(),
  js: buildJs(),
  go: buildGo(),
  elixir,
  elixirSig: savedSig,
};
writeFileSync(out, JSON.stringify(index, null, 2));

const n = (x) => (x ? Object.keys(x.reverse).length : 0);
console.error(`[blast-radius] index written: ${relative(ROOT, out)}`);
console.error(`  js:     ${n(index.js)} nodes with dependents`);
console.error(`  go:     ${n(index.go)} packages with importers`);
console.error(`  elixir: ${index.elixir ? n(index.elixir) + " files with dependents" : "(none — best-effort skipped)"}`);
