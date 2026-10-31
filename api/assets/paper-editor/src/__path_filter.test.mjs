// __path_filter.test.mjs — the paper-editor workflow's path filter covers every
// file its own steps read from outside api/assets/paper-editor.
//
// The filter was hand-kept, and it went blind more than once: a suite added a
// read of bp-modal-focus.js, bp-tab-keys.js, nav.ex or the pd-parity corpus, and
// a change to that file alone never ran the suite that pins it. This derives
// the reads instead of trusting a list:
//   1. entry points: every `node <file>`, `npm test` and `npm run <script>` in
//      the workflow, expanded through package.json (pre/post hooks, nested
//      `npm run`, `esbuild <entry>`);
//   2. from each reachable file, every string literal that resolves to an
//      existing path (against the file's folder, the package root, and the
//      repo root for `join(X, "a/b")`): inside the package it is followed,
//      outside it is a sink. A literal folder, or the fixed prefix of a
//      template literal, is a folder sink: a new file in it must trigger too.
// Every sink must match a pattern in BOTH arms, and both arms must be equal.
//
// Run: node src/__path_filter.test.mjs   (or: npm test)

import assert from "node:assert/strict";
import { existsSync, readFileSync, statSync } from "node:fs";
import { dirname, extname, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const SELF = fileURLToPath(import.meta.url);
const PKG = resolve(dirname(SELF), "..");
const REPO = resolve(PKG, "../../..");
const WORKFLOW = new URL("../../../../.github/workflows/paper-editor.yml", import.meta.url);
const SCANNED = new Set([".js", ".mjs", ".cjs", ".css", ".html", ".json"]);
// Literals that name a repo path as DATA (a hostile wrap token, a file-tree
// fixture), not a file the step reads. Each entry names the one file it is in
// (and this file, which names them here).
const NOT_READ = new Map([
  ["api/lib/barkpark/portable_doc/bpml/parser.ex", "src/__narrow_render.mjs"],
  ["internal/", "src/canvas/__filetree_inline_mounted.test.mjs"],
]);

export function filterArms(yml) {
  const arms = {};
  let arm = null;
  let inPaths = false;
  for (const line of yml.split("\n")) {
    const key = line.match(/^  ([a-z_]+):\s*$/);
    if (key) { arm = key[1]; inPaths = false; continue; }
    if (/^\S/.test(line)) { arm = null; inPaths = false; continue; }
    if (arm && /^    paths:\s*$/.test(line)) { inPaths = true; arms[arm] = []; continue; }
    if (!inPaths) continue;
    const entry = line.match(/^      - ["']?([^"'#]+?)["']?\s*$/);
    if (entry) arms[arm].push(entry[1]);
    else if (/^    \S/.test(line)) inPaths = false;
  }
  return arms;
}

export function globToRegExp(pattern) {
  let re = "";
  for (let i = 0; i < pattern.length; i++) {
    const c = pattern[i];
    if (c === "*" && pattern[i + 1] === "*") { re += ".*"; i++; }
    else if (c === "*") re += "[^/]*";
    else re += c.replace(/[.+?^${}()|[\]\\]/g, "\\$&");
  }
  return new RegExp(`^${re}$`);
}

const inside = (p) => p === PKG || p.startsWith(PKG + sep);
const inRepo = (p) => p.startsWith(REPO + sep);
const ancestorOfPkg = (p) => PKG.startsWith(p + sep);
const repoPath = (p) => relative(REPO, p).split(sep).join("/");

function kind(p) {
  if (!existsSync(p)) return null;
  return statSync(p).isDirectory() ? "dir" : "file";
}

function firstExisting(bases, lit) {
  return bases.map((base) => resolve(base, lit)).find((p) => existsSync(p));
}

function candidates(file, text) {
  const out = [];
  for (const m of text.matchAll(/(["'`])((?:\.\.?\/)[^"'`\n]*?)\1/g)) {
    let lit = m[2];
    const hole = lit.indexOf("${");
    if (hole >= 0) lit = lit.slice(0, lit.lastIndexOf("/", hole) + 1);
    const path = firstExisting([dirname(file), PKG], lit.replace(/[?#].*$/, ""));
    if (path) out.push({ path, templated: hole >= 0 });
  }
  for (const m of text.matchAll(/\b(?:join|resolve)\(\s*[A-Za-z_$][\w$.]*\s*,\s*(["'`])([A-Za-z_.][^"'`$\n]*)\1/g)) {
    const path = firstExisting([dirname(file), PKG, REPO], m[2]);
    if (path) out.push({ path, templated: false });
  }
  for (const m of text.matchAll(/(["'`])([A-Za-z_][\w.@-]*\/[^"'`$\s]*)\1/g)) {
    const path = firstExisting([REPO], m[2]);
    if (path) out.push({ path, templated: false });
  }
  return out;
}

export function reads(yml, scripts) {
  const sinks = new Map();
  const queue = [];
  const visited = new Set();
  const expanded = new Set();
  const expand = (name) => {
    for (const hook of [`pre${name}`, name, `post${name}`]) {
      if (expanded.has(hook) || typeof scripts[hook] !== "string") continue;
      expanded.add(hook);
      commands(scripts[hook]);
    }
  };
  const commands = (text) => {
    for (const m of text.matchAll(/\bnode\s+([^\s&|;"'>]+\.(?:mjs|cjs|js))/g)) queue.push(resolve(PKG, m[1]));
    for (const m of text.matchAll(/\besbuild\s+([^\s&|;"'>-][^\s&|;"'>]*)/g)) queue.push(resolve(PKG, m[1]));
    for (const m of text.matchAll(/\bnpm\s+run\s+([\w:-]+)/g)) expand(m[1]);
    for (const m of text.matchAll(/["']npm["'],\s*\[\s*["']run["'],\s*["']([\w:-]+)["']/g)) expand(m[1]);
    if (/\bnpm\s+test\b/.test(text)) expand("test");
  };
  commands(yml);
  const entries = queue.length;
  while (queue.length) {
    const file = queue.shift();
    if (visited.has(file) || kind(file) !== "file") continue;
    visited.add(file);
    if (!SCANNED.has(extname(file))) continue;
    const text = readFileSync(file, "utf8");
    commands(text);
    for (const { path, templated } of candidates(file, text)) {
      if (!inRepo(path) || ancestorOfPkg(path) || path.includes(`${sep}node_modules${sep}`)) continue;
      const k = kind(path);
      if (templated && k !== "dir") continue;
      if (inside(path)) { if (k === "file") queue.push(path); continue; }
      const sink = k === "dir" ? `${repoPath(path)}/` : repoPath(path);
      if (NOT_READ.has(sink) && (file === SELF || NOT_READ.get(sink) === relative(PKG, file).split(sep).join("/"))) continue;
      if (!sinks.has(sink)) sinks.set(sink, repoPath(file));
    }
  }
  return { entries, sinks, visited };
}

export const covers = (patterns, sink) => {
  const probe = sink.endsWith("/") ? `${sink}a-new-file` : sink;
  return patterns.some((p) => globToRegExp(p).test(probe));
};

if (import.meta.url === `file://${process.argv[1]}`) {
  const yml = readFileSync(WORKFLOW, "utf8");
  const scripts = JSON.parse(readFileSync(join(PKG, "package.json"), "utf8")).scripts;
  const arms = filterArms(yml);

  assert.deepEqual(Object.keys(arms).sort(), ["pull_request", "push"], "the workflow has a push and a pull_request path filter");
  assert.deepEqual(arms.pull_request, arms.push, "push and pull_request list the same paths");

  const { entries, sinks, visited } = reads(yml, scripts);
  assert.ok(entries >= 200, `found ${entries} entry points; the workflow parse is broken`);
  assert.ok(sinks.size >= 20, `found ${sinks.size} outside reads; the scan is broken`);

  const missing = [...sinks].filter(([sink]) => !covers(arms.push, sink));
  assert.deepEqual(
    missing.map(([sink, by]) => `${sink}  (read by ${by})`),
    [],
    "files a paper-editor step reads that its path filter does not list: add each to BOTH arms of .github/workflows/paper-editor.yml",
  );

  const unused = arms.push.filter((p) => !p.startsWith("api/assets/paper-editor/") && ![...sinks.keys()].some((s) => covers([p], s)));
  assert.deepEqual(unused, [], "path filter entries no paper-editor step reads: remove them, or the derivation missed a read");

  assert.equal(covers(["api/priv/static/assets/*"], "api/priv/static/assets/"), true);
  assert.equal(covers(["api/priv/static/assets/*.css"], "api/priv/static/assets/"), false);
  assert.equal(covers(["api/lib/a.ex"], "api/lib/b.ex"), false);

  console.log(`ok path filter: ${sinks.size} outside reads from ${visited.size} files, all in both arms`);
}
