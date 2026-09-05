#!/usr/bin/env node
//
// gate-map.mjs — "which committed instruments READ this path?", answered by the
// tooling instead of by the brief author's memory.
//
// THE RED THIS EXISTS FOR
// -----------------------
// cch-w16-s2 edited cloud/priv/static/__preview__/breakpoint-sweep.mjs. Its
// DECIDE-authored gate ran the sweep and the sweep's own unit suite. It did NOT
// run cloud/priv/static/__css_check.mjs — which scans EVERY .js/.mjs/.css file
// directly inside cloud/priv/static/ and cloud/priv/static/__preview__/ for E11
// (banned `app.js:<line>` source-line citations). The slice shipped three. The
// slice's own gate was green; the wired node-20 console-unit job would have
// reded on a rule this epic itself wrote. Nobody's gate asked about it, because
// "who reads breakpoint-sweep.mjs?" was answered from memory.
//
// __css_check does not import breakpoint-sweep.mjs. It does not name it. It
// READS THE DIRECTORY (__css_check.mjs:1068-1070):
//
//     for (const f of fs.readdirSync(root)) if (scanned(f)) out.push(f);
//     const pv = path.join(root, "__preview__");
//     if (fs.existsSync(pv)) for (const f of fs.readdirSync(pv)) ...
//
// So an import graph cannot find this edge. A DIRECTORY SCAN is the edge, and
// only a reader that models scan sites — readdir, glob, find, git ls-files,
// literal path — can see it.
//
// WHAT THIS IS AND IS NOT
// -----------------------
//   · It DERIVES the map by reading each instrument's scan sites, then checks
//     the committed snapshot against a fresh derivation on every run. A drifted
//     snapshot is a REFUSAL (exit 3), never a quietly different answer.
//   · An instrument it cannot classify is listed as UNMAPPED and COUNTED. It is
//     never dropped. An unmapped instrument is an admission, not a pass.
//   · The extraction is deliberately CONSERVATIVE: a directory scan maps to
//     every file directly in that directory, with no extension filter, even
//     when the instrument filters. Over-inclusion costs runtime; under-inclusion
//     is the wave-16 red.
//   · It is a COMPOSER, not a replacement for the wired jobs. It answers "what
//     must this slice's gate run", before the merge PR, not from it.
//
// SIBLING: scripts/preview-census-gate-check.mjs answers a DIFFERENT question —
// "did the scenarios.mjs census move, and which census owners must therefore
// run". That tool is corpus-delta keyed and emits four owners; __css_check is
// not among them (it appears there only as a replayed wave-21 gate FIXTURE at
// preview-census-gate-check.mjs:440). The two compose; neither subsumes.
//
// USAGE
//   node tooling/gate-map/gate-map.mjs --population
//   node tooling/gate-map/gate-map.mjs --verify
//   node tooling/gate-map/gate-map.mjs --derive > tooling/gate-map/gate-map.json
//   node tooling/gate-map/gate-map.mjs --for a/b.mjs c/d.sh
//   node tooling/gate-map/gate-map.mjs --for-file <list.txt>
//   node tooling/gate-map/gate-map.mjs --for <files…> --run

import fs from "node:fs";
import path from "node:path";
import { execFileSync, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

export const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
export const MAP_PATH = path.join(REPO, "tooling", "gate-map", "gate-map.json");

// ── THE POPULATION ───────────────────────────────────────────────────────────
// Committed checks only — `git ls-files`, never a working-tree walk, so an
// uncommitted scratch file can never enter or leave the population silently.
export const POPULATION_GLOBS = [
  "scripts/*.sh",
  "scripts/*.mjs",
  "cloud/priv/static/*.mjs",
  "cloud/priv/static/__preview__/*.mjs",
  "tooling/**/check*.mjs",
  "*.test.sh",
  "*.test.mjs",
];

export function population(root = REPO) {
  const out = new Set();
  for (const g of POPULATION_GLOBS) {
    let listed = "";
    try {
      listed = execFileSync("git", ["-C", root, "ls-files", "--", g], { encoding: "utf8" });
    } catch {
      continue;
    }
    for (const l of listed.split("\n")) if (l.trim()) out.add(l.trim());
  }
  // Fixture corpora are inputs, not instruments.
  return [...out].filter((f) => !/\/fixtures?\//.test(f)).sort();
}

// ── SCAN-SITE EXTRACTION ─────────────────────────────────────────────────────
// Each rule below turns one source construct into a scan prefix. `dirOf` is the
// instrument's own directory, which is how `readdirSync(dir)` in a file that
// lives at cloud/priv/static/ resolves to cloud/priv/static/.
//
// A prefix is one of:
//   {kind:"dir",  p:"cloud/priv/static"}            direct children only
//   {kind:"tree", p:"api/lib"}                      the whole subtree
//   {kind:"file", p:"cloud/priv/static/app.js"}     that exact file
const REPO_TOP = "(?:api|cloud|js|web|scripts|tooling|internal|docs|deploy|bin|test|priv|lib|assets|config|\\.github)";

export function scanSites(rel, src) {
  const dirOf = path.posix.dirname(rel);
  const sites = [];
  const add = (kind, p, evidence) => {
    p = p.replace(/^\.\//, "").replace(/\/+$/, "");
    if (!p || p === "." || p.startsWith("..")) return;
    if (!sites.some((s) => s.kind === kind && s.p === p)) sites.push({ kind, p, evidence });
  };
  const lines = src.split("\n");
  const at = (i) => `${rel}:${i + 1}`;

  for (let i = 0; i < lines.length; i++) {
    const L = lines[i];

    // 1. readdirSync(<expr>) — the construct that hides the wave-16 edge.
    for (const m of L.matchAll(/readdirSync\(\s*([^),]+)/g)) {
      const e = m[1].trim();
      if (/^(dir|root|HERE|__dirname|BASE|DIR)$/.test(e)) add("dir", dirOf, at(i));
      else if (/^["'`]/.test(e)) {
        const lit = e.slice(1, -1);
        add("dir", lit.startsWith("/") ? lit : path.posix.join(dirOf, lit), at(i));
      } else {
        // path.join(dir, "sub") / join(root, "sub")
        const j = e.match(/join\(\s*(?:dir|root|HERE|__dirname|BASE|DIR)\s*,\s*["'`]([^"'`]+)/);
        if (j) add("dir", path.posix.join(dirOf, j[1]), at(i));
        else add("dir", dirOf, at(i)); // conservative: an unresolved readdir over its own tree
      }
    }
    // 1b. `const pv = path.join(dir, "sub")` feeding a readdir two lines down.
    for (const m of L.matchAll(/path\.join\(\s*(?:dir|root|HERE|__dirname)\s*,\s*["'`]([^"'`]+)["'`]\s*\)/g)) {
      const near = lines.slice(i, i + 4).join("\n");
      if (/readdirSync|readdir\(/.test(near)) add("dir", path.posix.join(dirOf, m[1]), at(i));
    }

    // 2. git ls-files / git grep patterns.
    for (const m of L.matchAll(/ls-files[^\n]*?["']((?:\*\*\/)?[\w./*@-]+)["']/g)) {
      const p = m[1];
      const base = p.replace(/\/?\*+.*$/, "");
      if (base) add(p.includes("**") || !p.includes("*") ? "tree" : "dir", base, at(i));
    }

    // 3. shell `find <dir>` and glob loops.
    for (const m of L.matchAll(new RegExp(`\\bfind\\s+["']?(${REPO_TOP}[\\w./-]*)`, "g"))) add("tree", m[1], at(i));
    for (const m of L.matchAll(new RegExp(`(${REPO_TOP}[\\w./-]*)/\\*`, "g"))) add("dir", m[1], at(i));

    // 4. literal repo-relative paths — a file the instrument opens by name.
    for (const m of L.matchAll(new RegExp(`(${REPO_TOP}/[\\w./-]+\\.[A-Za-z]{1,6})\\b`, "g"))) {
      add("file", m[1], at(i));
    }

    // 5. a .test.* harness reads the module it drives.
    for (const m of L.matchAll(/from\s+["'](\.\.?\/[\w./-]+)["']/g)) {
      add("file", path.posix.normalize(path.posix.join(dirOf, m[1])), at(i));
    }
    for (const m of L.matchAll(/(?:bash|sh|source|\.)\s+(\.\/[\w./-]+\.sh)/g)) {
      add("file", path.posix.normalize(path.posix.join(dirOf, m[1])), at(i));
    }
  }
  return sites;
}

export function runCommandFor(rel) {
  if (rel.endsWith(".test.mjs")) return `node --test ${rel}`;
  if (rel.endsWith(".mjs")) return `node ${rel}`;
  return `bash ${rel}`;
}

export function derive(root = REPO) {
  const pop = population(root);
  const instruments = [];
  const unmapped = [];
  for (const rel of pop) {
    let src;
    try {
      src = fs.readFileSync(path.join(root, rel), "utf8");
    } catch {
      unmapped.push({ path: rel, why: "unreadable" });
      continue;
    }
    const scans = scanSites(rel, src);
    if (scans.length === 0) {
      unmapped.push({ path: rel, why: "no scan site found (no readdir, glob, find, ls-files or repo-relative literal)" });
      continue;
    }
    instruments.push({ path: rel, run: runCommandFor(rel), scans });
  }
  return { population: pop.length, mapped: instruments.length, unmapped, instruments };
}

// ── MATCHING ─────────────────────────────────────────────────────────────────
export function matches(site, file) {
  if (site.kind === "file") return site.p === file;
  if (site.kind === "dir") return path.posix.dirname(file) === site.p;
  return file === site.p || file.startsWith(site.p + "/");
}

export function requiredFor(changedFiles, map) {
  const req = [];
  for (const inst of map.instruments) {
    if (changedFiles.includes(inst.path)) continue; // an instrument is not its own scanner-of-record
    const why = [];
    for (const f of changedFiles) {
      const hit = inst.scans.find((s) => matches(s, f));
      if (hit) why.push({ file: f, via: hit });
    }
    if (why.length) req.push({ path: inst.path, run: inst.run, why });
  }
  // A changed instrument still runs — it is the check its own edit can break.
  for (const f of changedFiles) {
    const self = map.instruments.find((i) => i.path === f);
    if (self && !req.some((r) => r.path === self.path)) {
      req.push({ path: self.path, run: self.run, why: [{ file: f, via: { kind: "self", p: f, evidence: "the edited instrument itself" } }] });
    }
  }
  return req.sort((a, b) => a.path.localeCompare(b.path));
}

// ── THE SNAPSHOT IS RE-EARNED, EVERY RUN ─────────────────────────────────────
// A committed map nobody re-derives rots into a list of paths. `verify` diffs
// the snapshot against a fresh derivation: a vanished instrument, a new one, or
// a moved scan set is a REFUSAL. A shorter answer is the wave-16 failure again.
export function verify(map, root = REPO) {
  const fresh = derive(root);
  const problems = [];
  const byPath = (m) => new Map(m.instruments.map((i) => [i.path, i]));
  const A = byPath(map);
  const B = byPath(fresh);
  for (const p of A.keys()) if (!B.has(p)) problems.push(`snapshot names an instrument the tree no longer derives: ${p}`);
  for (const p of B.keys()) if (!A.has(p)) problems.push(`the tree derives an instrument the snapshot omits: ${p}`);
  for (const [p, a] of A) {
    const b = B.get(p);
    if (!b) continue;
    const key = (i) => i.scans.map((s) => `${s.kind}:${s.p}`).sort().join(",");
    if (key(a) !== key(b)) problems.push(`scan set moved for ${p}`);
  }
  const au = new Set(map.unmapped.map((u) => u.path));
  const bu = new Set(fresh.unmapped.map((u) => u.path));
  for (const p of bu) if (!au.has(p)) problems.push(`newly UNMAPPED instrument absent from the snapshot: ${p}`);
  for (const p of au) if (!bu.has(p)) problems.push(`snapshot lists ${p} as UNMAPPED but the tree now maps it`);
  return { ok: problems.length === 0, problems, fresh };
}

// ── THE PREFIX VIEW ──────────────────────────────────────────────────────────
// `--for` answers "this exact slice"; `--prefix` answers the row's question,
// "which instruments READ anything under cloud/priv/static/**". Same scan sites,
// aggregated one level up — this is the prefix -> [instruments] map itself.
export function instrumentsUnderPrefix(prefix, map) {
  const p = prefix.replace(/\/+$/, "");
  const under = (q) => q === p || q.startsWith(p + "/");
  return map.instruments
    .filter((i) => i.scans.some((s) => under(s.p)))
    .map((i) => ({ path: i.path, run: i.run, via: i.scans.filter((s) => under(s.p)).slice(0, 3) }))
    .sort((a, b) => a.path.localeCompare(b.path));
}

export function loadMap(p = MAP_PATH) {
  return JSON.parse(fs.readFileSync(p, "utf8"));
}

// ── CLI ──────────────────────────────────────────────────────────────────────
function main(argv) {
  const has = (f) => argv.includes(f);
  if (has("--derive")) {
    process.stdout.write(JSON.stringify(derive(), null, 2) + "\n");
    return 0;
  }
  if (has("--population")) {
    const d = derive();
    console.log(`POPULATION  ${d.population} committed instrument(s) over ${POPULATION_GLOBS.length} globs`);
    console.log(`MAPPED      ${d.mapped}`);
    console.log(`UNMAPPED    ${d.unmapped.length}  (listed, never dropped)`);
    for (const u of d.unmapped) console.log(`  UNMAPPED  ${u.path}  — ${u.why}`);
    return 0;
  }
  if (has("--verify")) {
    const v = verify(loadMap());
    if (!v.ok) {
      console.error("REFUSED: the committed gate-map no longer describes the tree");
      for (const p of v.problems) console.error(`  ${p}`);
      console.error("Re-derive with --derive > tooling/gate-map/gate-map.json and read the diff.");
      return 3;
    }
    console.log(`gate-map.json still describes the tree (${loadMap().mapped} mapped, ${loadMap().unmapped.length} unmapped)`);
    return 0;
  }

  const pf = argv.indexOf("--prefix");
  if (pf !== -1) {
    const prefix = argv[pf + 1];
    const list = instrumentsUnderPrefix(prefix, loadMap());
    console.log(`PREFIX ${prefix}  ->  ${list.length} instrument(s)`);
    for (const i of list) console.log(`  ${i.path}\n      ${i.via.map((v) => `${v.kind} ${v.p} (${v.evidence})`).join("\n      ")}`);
    return 0;
  }

  let files = [];
  const ff = argv.indexOf("--for-file");
  if (ff !== -1) {
    files = fs.readFileSync(argv[ff + 1], "utf8").split("\n").map((s) => s.trim()).filter(Boolean);
  }
  const fi = argv.indexOf("--for");
  if (fi !== -1) {
    for (let i = fi + 1; i < argv.length; i++) {
      if (argv[i].startsWith("--")) break;
      files.push(argv[i]);
    }
  }
  if (!files.length) {
    console.error("usage: gate-map.mjs --population | --verify | --derive | --prefix <p> | --for <files…> [--run]");
    return 2;
  }

  const map = loadMap();
  const v = verify(map);
  if (!v.ok) {
    console.error("REFUSED: the committed gate-map no longer describes the tree — the composed gate would be a guess.");
    for (const p of v.problems) console.error(`  ${p}`);
    return 3;
  }
  const req = requiredFor(files, map);
  console.log(`SLICE  ${files.length} changed file(s)`);
  for (const f of files) console.log(`  ${f}`);
  console.log(`GATE   ${req.length} instrument(s) READ those paths:`);
  for (const r of req) {
    const w = r.why[0];
    console.log(`  ${r.run}`);
    console.log(`      because ${w.via.kind === "self" ? "it IS the edited file" : `it ${w.via.kind === "dir" ? "reads the directory" : w.via.kind === "tree" ? "walks the subtree" : "opens"} ${w.via.p}`}  (${w.via.evidence})`);
  }
  if (!has("--run")) return 0;

  let bad = 0;
  for (const r of req) {
    const parts = r.run.split(" ");
    console.log(`\n─── ${r.run}`);
    const res = spawnSync(parts[0], parts.slice(1), { cwd: REPO, encoding: "utf8" });
    const out = (res.stdout || "") + (res.stderr || "");
    process.stdout.write(out);
    if (res.status !== 0) {
      bad++;
      console.log(`RED  ${r.run}  exit ${res.status}`);
    }
  }
  if (bad) {
    console.log(`\nCOMPOSED GATE RED — ${bad} of ${req.length} instrument(s) failed`);
    return 1;
  }
  console.log(`\nCOMPOSED GATE GREEN — ${req.length} instrument(s)`);
  return 0;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  process.exit(main(process.argv.slice(2)));
}
