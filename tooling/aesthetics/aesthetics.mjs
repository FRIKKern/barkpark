#!/usr/bin/env node
// aesthetics — the FILEBASE critic. Cody grades CODE (Tested/Hotspots/Modularity/
// …) but is blind to filebase MESS: source dumped in the repo root, build artifacts
// committed into git, a cold-doc graveyard, dead/junk tasks. This analyzer SEES,
// SCORES, and EXPLAINS that mess so the tree can be driven toward peak aesthetics.
//
//   node tooling/aesthetics/aesthetics.mjs  → aesthetics-report.json + console summary
//
// ETHOS — YAGNI (You Aren't Gonna Need It). Less is better. A clean, navigable tree
// scores high. The analyzer rewards ABSENCE: every flagged file is one that earns
// its place poorly. It NEVER deletes or moves anything — it only analyzes + reports;
// the cleanup (with judgment) is the orchestrator's job.
//
// EXPLAINABLE — every finding traces to a real path + a concrete reason + a fix.
// CONSERVATIVE — high-confidence only. main.go/go.mod/Makefile/README are NEVER
// called "dead". A contract/runbook is not dead just because it isn't a routing card.
//
// ── SCORING (0–100, higher = cleaner; formulas are deterministic + documented) ──
//
// BLOAT (structural) = clamp(100 − rootClutterPenalty − artifactPenalty − fanoutPenalty)
//   rootClutterPenalty = min(38, 1.3 × max(0, S − 3))
//       S = count of SOURCE files (by extension) sitting in the REPO ROOT. A handful
//       (baseline 3) is fine for a single-binary module; a whole package dumped in
//       root is the mess. The 33 root .go TUI files are the headline. Capped at 38.
//   artifactPenalty   = min(22, 2.0 × buildOutput + 0.3 × deliberate + 0.8 × typedefs)
//       buildOutput   = generated dist/ + *.bundle.js/*.map that is NEITHER served NOR
//                       published — pure regenerable mess (git history is the home → gitignore).
//       deliberate    = served (a *.bundle.js referenced by a real .heex/.ex/.html/.tsx
//                       source) OR published (under a dir a package.json main/module/types/
//                       exports/files[] resolves to). DELIBERATELY committed → near-zero penalty
//                       (0.3), "verify, likely keep" — a served asset must be in the repo to be
//                       served; a published package commits its dist for installs + workspaces.
//       typedefs      = a standalone *.d.ts not under a published dir (may be hand-maintained).
//   fanoutPenalty     = min(12, 3 × F)
//       F = source directories with > 30 direct children (a too-flat dump), EXCLUDING
//       legitimately-flat dirs (migrations, tests, fixtures, demo data, generated batches).
//
// AESTHETICS (qualitative mess + YAGNI) = clamp(100 − deadDocPenalty − deadTaskPenalty − orphanPenalty)
//   deadDocPenalty  = min(14, 0.25 × atticDocs) + min(18, 4 × orphanDocs)
//       atticDocs  = markdown in the designated cold-doc grave (_attic/ — doc-tier:cold,
//                    "never load"). Capped hard: 53 graved docs are ONE archive, not 53
//                    independent problems. orphanDocs = live-tree .md that is NOT a routing
//                    card, NOT doc-tier-tagged, NOT a standard file, NOT under a role-bearing
//                    dir (.changeset/.github), NOT a per-project doc (README/BRIEF inside an
//                    app/package dir), and referenced by NOTHING. (Conservative → ~0.)
//   deadTaskPenalty = min(16, 2.2 × junkTasks + 0.25 × unscopedOpen)  [over LIVE bp data,
//                     else the snapshot — see LIMITATION]
//       junkTasks    = open tasks whose TITLE is obvious debris (delete-me / write-probe /
//                      r1test / test-scaffold / scratch / "R1 task A/B …") — high confidence.
//       unscopedOpen = open work-tasks that are UNPLACEABLE — live: no parent phase/goal +
//                      no kind/umbrella/intention label; snapshot: 0 commits + 0 files + no
//                      intention match — candidates only (see LIMITATION below).
//   orphanPenalty   = min(8, 4 × yagniOrphans)
//       yagniOrphans = NON-source, non-standard tracked files with zero inbound references
//                      AND no runtime/build role. (Conservative — see LIMITATION.)
//
// LIMITATIONS (stated honestly, not hidden):
//   • Task data comes LIVE from `bp task ls --json` when bp is on PATH, else falls back
//     to the tooling/tasks/tasks-report.json snapshot (a captured moment). Neither gives
//     a reliable AGE signal here → "dead task" = title-debris (high conf) + unscoped-open
//     (candidate), not age. The report states which source was used.
//   • Compiled-source orphans (an unused .go/.ex/.ts module) are INVISIBLE to a grep-only
//     scan — symbol/package references aren't path references. yagniOrphans is therefore
//     scoped to non-source files only, to stay false-positive-free.
//
// Pure Node, dependency-free, NO network. Reads `git ls-files` + fs + `bp task ls`
// (graceful fallback to the tasks-report snapshot when bp is unavailable, e.g. in CI).

import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { dirname, join, basename } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: HERE }).toString().trim();
const rd = (p, d) => existsSync(join(ROOT, p)) ? JSON.parse(readFileSync(join(ROOT, p), "utf8")) : d;
const read = (p) => { try { return readFileSync(join(ROOT, p), "utf8"); } catch { return ""; } };
const git = (a) => execFileSync("git", a, { cwd: ROOT, encoding: "utf8", maxBuffer: 256 * 1024 * 1024 });
const e = (s = "") => process.stderr.write(s + "\n");
const clamp = (n) => Math.max(0, Math.min(100, Math.round(n)));

const files = git(["ls-files"]).split("\n").filter(Boolean);
const fileSet = new Set(files);

// Directory maps — built once, used by published-dir detection, fan-out, project-roots.
const childrenOf = new Map();    // dir → Set of immediate child names (files + subdirs)
const fileChildren = new Map();  // dir → count of DIRECT file children
for (const p of files) {
  const segs = p.split("/");
  for (let i = 0; i < segs.length - 1; i++) {
    const dir = segs.slice(0, i + 1).join("/");
    if (!childrenOf.has(dir)) childrenOf.set(dir, new Set());
    childrenOf.get(dir).add(segs[i + 1]);
  }
  const parent = segs.slice(0, -1).join("/");
  if (parent) fileChildren.set(parent, (fileChildren.get(parent) || 0) + 1);
}

// ════════════════════════════════════════════════════════════════════════════
// BLOAT (structural)
// ════════════════════════════════════════════════════════════════════════════
const bloat = [];

// ── ROOT CLUTTER — source files dumped in the repo root ──────────────────────
// A SOURCE file is one whose extension is a programming language. Config / build /
// doc / script files legitimately live at root and are NOT clutter (go.mod, go.sum,
// package.json, *.json, *.toml, *.yml, Makefile, README.md, CLAUDE.md, AGENTS.md,
// LICENSE, .gitignore, *.sh, …) — none have a SOURCE extension, so the extension
// test excludes them automatically. main.go IS counted (it pollutes the root) but
// the FIX is "move to a subpackage", NEVER "delete".
const SOURCE_EXT = new Set(["go", "ex", "exs", "ts", "tsx", "js", "jsx", "mjs", "cjs",
  "py", "rs", "rb", "java", "kt", "swift", "scala", "clj", "c", "cc", "cpp", "h", "hpp"]);
const ROOT_CLUTTER_BASELINE = 3; // a single-binary module may keep a couple of root files
const extOf = (p) => { const b = basename(p); const i = b.lastIndexOf("."); return i > 0 ? b.slice(i + 1).toLowerCase() : ""; };
const rootFiles = files.filter((p) => !p.includes("/"));
const rootSource = rootFiles.filter((p) => SOURCE_EXT.has(extOf(p)));
const rootByExt = {};
for (const p of rootSource) { const x = extOf(p); (rootByExt[x] ||= []).push(p); }
const dominantExt = Object.entries(rootByExt).sort((a, b) => b[1].length - a[1].length)[0];
const rootClutterPenalty = Math.min(38, 1.3 * Math.max(0, rootSource.length - ROOT_CLUTTER_BASELINE));
if (rootSource.length > ROOT_CLUTTER_BASELINE) {
  // one roll-up finding (keeps the improvement plan readable — not 33 rows)
  const ext = dominantExt ? dominantExt[0] : "src";
  const target = ext === "go" ? "a cmd/<bin>/ or internal/<pkg>/ subpackage" : "a dedicated source subdirectory";
  bloat.push({
    path: "(repo root)",
    kind: "root-clutter",
    severity: +Math.min(0.95, 0.3 + rootSource.length / 50).toFixed(2),
    why: `${rootSource.length} source files (${Object.entries(rootByExt).map(([x, l]) => `${l.length} .${x}`).join(", ")}) sit in the repo ROOT — a whole package dumped at top level clutters the "index" and buries the few files that belong there. Baseline is ${ROOT_CLUTTER_BASELINE}.`,
    fix: `Move the root source package into ${target} (one git mv + a package/import update). Leave go.mod/go.sum/Makefile/README/CLAUDE.md/AGENTS.md/LICENSE/*.sh at root — those belong.`,
    sample: rootSource.slice(0, 8),
  });
}

// ── TRACKED BUILD ARTIFACTS — generated files committed into git ─────────────
// Four classes, NOT one — a served bundle and a published dist are DELIBERATELY
// committed (a served asset must be in the repo to be served; a published package
// commits its dist so installs + workspace consumers resolve it), so they earn a
// near-zero penalty + a "verify, likely keep" note — NOT "gitignore it". Only a
// genuinely-regenerable artifact (not served, not published) gets the full penalty.
//   build-output — regenerable, neither served nor published → full penalty, gitignore.
//   published    — under a package whose package.json main/module/types/exports/files
//                  resolves to it → DELIBERATE (npm tarball + workspace consumers).
//   served       — referenced by a non-build SOURCE (.heex/.ex/.html/.tsx/…) outside
//                  its own dir → DELIBERATE (shipped to the browser without a build).
//   typedef      — a standalone .d.ts that is neither published nor served → small.
//
// PUBLISHED-DIR detection: scan every tracked package.json; collect the dirs its
// main/module/types/exports(import|require|types|default)/files[] entries point at.
// A file under any of those dirs (within that package) is published.
const publishedDirs = new Set();   // "pkgDir/subdir" the package ships
for (const p of files) {
  if (basename(p) !== "package.json") continue;
  let pkg; try { pkg = JSON.parse(read(p)); } catch { continue; }
  const pkgDir = dirname(p) === "." ? "" : dirname(p);
  const join2 = (rel) => { const c = (pkgDir ? pkgDir + "/" : "") + String(rel).replace(/^\.\//, "").replace(/^\//, ""); return c; };
  const dirOfEntry = (rel) => { const j = join2(rel); return j.includes("/") ? j.slice(0, j.lastIndexOf("/")) : ""; };
  const exportsLeaves = (node, acc) => {
    if (typeof node === "string") { acc.push(node); return; }
    if (node && typeof node === "object") for (const v of Object.values(node)) exportsLeaves(v, acc);
  };
  for (const key of ["main", "module", "types", "typings"]) if (typeof pkg[key] === "string") publishedDirs.add(dirOfEntry(pkg[key]));
  const expLeaves = []; exportsLeaves(pkg.exports, expLeaves);
  for (const rel of expLeaves) publishedDirs.add(dirOfEntry(rel));
  if (Array.isArray(pkg.files)) for (const f of pkg.files) {     // files[] often names a whole dir ("dist")
    const j = join2(f); if (childrenOf.has(j)) publishedDirs.add(j);  // it's a real dir → its whole subtree ships
    else publishedDirs.add(dirOfEntry(f));
  }
}
publishedDirs.delete("");   // a bare "main":"index.js" at pkg root is not a build-dir signal
const isPublished = (p) => { for (const d of publishedDirs) if (p === d || p.startsWith(d + "/")) return true; return false; };
// SERVED: referenced by a real source file (not a build/config) somewhere else in the tree.
const SERVING_SRC = /\.(heex|eex|ex|exs|html|htm|tsx|jsx|ts|js|mjs|cjs|vue|svelte|erb|php)$/i;
const servedBy = (p) => {
  const b = basename(p);
  try {
    const hits = git(["grep", "-l", "-F", b, "--", ":!" + p]).split("\n").filter(Boolean);
    return hits.some((h) => h !== p && SERVING_SRC.test(h) && !/(^|\/)dist\//.test(h) && !h.endsWith(".map"));
  } catch { return false; }
};
const artifacts = [];
for (const p of files) {
  const underDist = /(^|\/)dist\//.test(p);
  const isMap = /\.map$/.test(p);
  const isBundle = /\.bundle\.js$/.test(p);
  const isDts = /\.d\.[cm]?ts$/.test(p);
  if (!(underDist || isMap || isBundle || isDts)) continue;
  let cls;
  if (isPublished(p)) cls = "published";        // npm tarball / workspace-resolved → deliberate
  else if (isBundle && servedBy(p)) cls = "served";  // shipped to the browser by a real source ref
  else if (isDts) cls = "typedef";              // standalone hand/gen .d.ts, not published
  else cls = "build-output";                    // regenerable, not served, not published → real mess
  artifacts.push({ p, cls });
}
const buildOutput = artifacts.filter((a) => a.cls === "build-output");
const deliberate = artifacts.filter((a) => a.cls === "published" || a.cls === "served");
const typedefs = artifacts.filter((a) => a.cls === "typedef");
// full penalty only for genuinely-removable build-output; deliberate served/published
// is near-zero (0.3 each); a standalone .d.ts stays the old small 0.8.
const artifactPenalty = Math.min(22, 2.0 * buildOutput.length + 0.3 * deliberate.length + 0.8 * typedefs.length);
if (buildOutput.length) {
  bloat.push({
    path: buildOutput[0].p,
    kind: "tracked-artifact",
    severity: +Math.min(0.8, 0.25 + buildOutput.length * 0.07).toFixed(2),
    why: `${buildOutput.length} generated build files are tracked in git (${buildOutput.slice(0, 4).map((a) => a.p).join(", ")}${buildOutput.length > 4 ? ", …" : ""}) and are NEITHER served by a source reference NOR published via a package.json entry — pure regenerable bundler/tsup output. Committing it adds diff noise on every rebuild and bloats the repo.`,
    fix: `gitignore this output and let the build regenerate it — it is not served and not published, so nothing in the tree depends on the committed copy. git history preserves what was there.`,
    sample: buildOutput.map((a) => a.p),
  });
}
for (const a of typedefs) {
  bloat.push({
    path: a.p,
    kind: "tracked-artifact",
    severity: 0.2,
    why: `${a.p} is a standalone .d.ts (not under a published package dir) — it may be generated, or a hand-maintained typecheck stub.`,
    fix: `VERIFY before acting: if the build regenerates it, gitignore it; if it is hand-written, keep it. Do NOT auto-delete.`,
  });
}
for (const a of deliberate) {
  bloat.push({
    path: a.p,
    kind: "tracked-artifact",
    severity: 0.12,
    why: a.cls === "served"
      ? `${a.p} is a built bundle REFERENCED by a non-build source (.heex/.ex/.html/.tsx/…) — it is DELIBERATELY committed so the surface serves it without a build step. A served asset must be in the repo to be served; this is not mess.`
      : `${a.p} is under a package whose package.json points main/module/types/exports/files[] at this dir — it is DELIBERATELY committed (the npm tarball ships it and workspace consumers resolve it without a build). This is not mess.`,
    fix: `Likely KEEP — verify the ${a.cls === "served" ? "source reference still serves it" : "package still publishes this dir"} and that a build hook would regenerate it if you ever chose to untrack. Do NOT gitignore it blindly: ${a.cls === "served" ? "untracking breaks the served surface" : "untracking breaks installs + workspace resolution unless a prepare/build step runs first"}.`,
  });
}

// ── DIRECTORY FAN-OUT — too many direct children (a too-flat dump) ───────────
// Count DIRECT FILE children (not subdirs) — a flat DUMP is many files in one dir;
// a dir of many SUBDIRS is a namespace, not a dump, so it is not flagged. Also
// track all immediate children (files + subdirs) for dated-dump root detection.
// 45, not 30: Phoenix contexts/controllers/channels/live conventionally live flat in one
// dir and legitimately reach ~33 — framework convention, not a "dump". Only a genuinely
// excessive flat directory (45+ direct source files) is worth flagging as too-flat.
const FANOUT_THRESHOLD = 45;
const FANOUT_EXCLUDE = /(^|\/)(migrations|test|tests|__tests__|fixtures|__fixtures__|__snapshots__|testdata|golden|goldens|node_modules|batches|results|review-results|review-batches|samples|papers|repo-papers|concept-map|_attic|captures)(\/|$)/i;
// childrenOf / fileChildren are built once near the top (shared with published-dir detection).
const fanoutDirs = [];
for (const [dir, n] of fileChildren) {
  if (n <= FANOUT_THRESHOLD) continue;
  if (FANOUT_EXCLUDE.test(dir + "/")) continue;
  // require it to be a real SOURCE directory (holds code, not data/fixtures)
  const hasSource = [...(childrenOf.get(dir) || [])].some((k) => SOURCE_EXT.has(extOf(k)));
  if (!hasSource) continue;
  fanoutDirs.push({ dir, n });
}
fanoutDirs.sort((a, b) => b.n - a.n);
const fanoutPenalty = Math.min(12, 3 * fanoutDirs.length);
for (const f of fanoutDirs) {
  bloat.push({
    path: f.dir + "/",
    kind: "dir-fanout",
    severity: +Math.min(0.4, 0.15 + (f.n - FANOUT_THRESHOLD) / 100).toFixed(2),
    why: `${f.n} direct children in one source directory — a flat dump that is hard to scan. Consider sub-grouping by responsibility.`,
    fix: `Group related modules into sub-namespaces (e.g. by feature) so no single directory exceeds ~${FANOUT_THRESHOLD} entries. Low priority — only if the grouping is natural.`,
  });
}

const bloatScore = clamp(100 - rootClutterPenalty - artifactPenalty - fanoutPenalty);

// ════════════════════════════════════════════════════════════════════════════
// AESTHETICS (qualitative mess + YAGNI)
// ════════════════════════════════════════════════════════════════════════════
const aesthetics = [];

// ── DEAD / STALE DOCS ────────────────────────────────────────────────────────
// Ground truth for "alive": the repo enforces a doc-tier header + a routing table
// in the root CLAUDE.md (the 7-card contract). A doc that is in the routing table,
// OR carries a doc-tier header, OR is a standard file, OR lives in a role-bearing
// dir (.changeset/.github), OR is referenced by another file = ALIVE. Everything
// else in the live tree is an orphan candidate (conservative → expect ~0).
const mdFiles = files.filter((p) => p.endsWith(".md"));
const atticDocs = mdFiles.filter((p) => /(^|\/)_attic\//.test(p));
const liveMd = mdFiles.filter((p) => !/(^|\/)_attic\//.test(p));

// routing-table membership: paths written as `path.md` anywhere in the root CLAUDE.md
const routingSet = new Set();
for (const claude of ["CLAUDE.md", "api/CLAUDE.md"]) {
  for (const m of read(claude).matchAll(/`([A-Za-z0-9_./-]+\.md)`/g)) routingSet.add(m[1]);
}
const STANDARD = /^(README|CLAUDE|AGENTS|CHANGELOG|LICENSE|CONTRIBUTING|SECURITY|SKILL|MEMORY|CODEOWNERS|NOTICE)/i;
const ROLE_DIR = /(^|\/)(\.changeset|\.github)\//;
const hasTier = (p) => /doc-tier:/.test(read(p).split("\n", 1)[0] || "");
// inbound reference: the doc's basename appears in some OTHER tracked text file
const referenced = (p) => {
  const b = basename(p);
  try { const hits = git(["grep", "-l", "-F", b, "--", ":!" + p]).split("\n").filter(Boolean); return hits.some((h) => h !== p); }
  catch { return false; } // git grep exits 1 on no match
};
// ── PROJECT/APP/PACKAGE roots — a dir that owns a real codebase ───────────────
// A markdown file is NOT an orphan/dead-doc if it sits inside (or under) a
// recognizable project: a dir that holds a manifest (package.json / mix.exs /
// go.mod / Cargo.toml / pyproject.toml / build.gradle) OR a conventional source
// dir (src/app/components/lib) directly beneath it. apps/hundesteder/BRIEF.md is
// such a doc — apps/hundesteder/ has package.json + app/ + components/ + lib/, so
// BRIEF.md is that app's brief/readme, a legitimate per-project doc, NOT dead.
// We compute the set of project-root directories ONCE, then a doc is project-owned
// if ANY ancestor directory (the doc's own dir or above) is a project root.
const MANIFEST = new Set(["package.json", "mix.exs", "go.mod", "cargo.toml",
  "pyproject.toml", "build.gradle", "build.gradle.kts", "deno.json", "gemfile"]);
const SRC_DIRNAME = new Set(["src", "app", "components", "lib"]);
const projectRoots = new Set();
for (const [dir, kids] of childrenOf) {
  for (const k of kids) {
    if (MANIFEST.has(k.toLowerCase()) && fileSet.has(dir + "/" + k)) { projectRoots.add(dir); break; }
    // a source-named child that is itself a DIRECTORY (i.e. has its own children)
    if (SRC_DIRNAME.has(k.toLowerCase()) && childrenOf.has(dir + "/" + k)) { projectRoots.add(dir); break; }
  }
}
const projectDoc = (p) => {
  const segs = p.split("/");
  for (let i = segs.length - 1; i >= 1; i--) {       // doc's own dir up to the top
    if (projectRoots.has(segs.slice(0, i).join("/"))) return true;
  }
  return false;
};
const orphanDocs = [];
for (const p of liveMd) {
  if (STANDARD.test(basename(p))) continue;
  if (ROLE_DIR.test(p)) continue;
  if (routingSet.has(p)) continue;
  if (hasTier(p)) continue;
  if (projectDoc(p)) continue;     // per-project README/BRIEF in a live app — not an orphan
  if (referenced(p)) continue;
  orphanDocs.push(p);
}
// dated-dump ROOTS: a dir whose own last segment is a date stamp, inside _attic/,
// and whose parent is NOT itself a dated dump (dedupe nested date subtrees).
const isDated = (seg) => /^(docs-)?20\d\d(-\d\d)?$/.test(seg) || /-20\d\d-\d\d$/.test(seg);
const datedDumps = [...childrenOf.keys()].filter((d) => {
  if (!/(^|\/)_attic\//.test(d + "/") && !/^_attic\//.test(d)) return false;
  const segs = d.split("/");
  return isDated(segs[segs.length - 1]) && !isDated(segs[segs.length - 2] || "");
});
const deadDocPenalty = Math.min(14, 0.25 * atticDocs.length) + Math.min(18, 4 * orphanDocs.length);
if (atticDocs.length) {
  aesthetics.push({
    path: "_attic/",
    kind: "dead-doc",
    severity: +Math.min(0.6, 0.2 + atticDocs.length / 150).toFixed(2),
    why: `${atticDocs.length} markdown docs sit in the cold-doc grave _attic/ (doc-tier:cold, "never load"). They are quarantined + unreferenced by the routing table — YAGNI: archived ≠ needed. git history is the real archive.`,
    fix: `Confirm nothing in the live tree links them (the routing table doesn't), then remove the _attic/ grave. Keep nothing "just in case" — git remembers.`,
    sample: atticDocs.slice(0, 8),
  });
}
for (const d of datedDumps.slice(0, 1)) {
  const n = atticDocs.filter((p) => p.startsWith(d + "/")).length;
  aesthetics.push({
    path: d + "/",
    kind: "dead-doc",
    severity: 0.45,
    why: `Dated documentation dump (${n} docs under ${d}/) — a point-in-time snapshot superseded by the live docs tree. Stale-by-construction.`,
    fix: `Delete the dated dump; the live docs/ tree is canonical and git history preserves the snapshot.`,
  });
}
for (const p of orphanDocs) {
  aesthetics.push({
    path: p,
    kind: "dead-doc",
    severity: 0.5,
    why: `Live-tree markdown that is NOT in the routing table, carries NO doc-tier header, and is referenced by no other file — an orphan. Likely stale or never wired in.`,
    fix: `Either give it a doc-tier header + an owner (route it / link it), or remove it. An unowned doc rots.`,
  });
}

// ── DEAD / STALE TASKS ────────────────────────────────────────────────────────
// DATA SOURCE: LIVE `bp task ls --json` when the bp CLI is on PATH and answers;
// otherwise GRACEFUL FALLBACK to the point-in-time tooling/tasks/tasks-report.json
// snapshot — so the grade still computes on a machine without bp (a fresh clone / CI).
// The snapshot is stale-by-construction (it's a captured moment); live data is current.
// LIMITATION: neither source gives reliable AGE here → the heuristic stays
// (a) title-debris (high confidence) + (b) unscoped-open (candidate), not true age.
const JUNK_TITLE = /\bdelete[ -]?me\b|write[ -]?probe|\br1test\b|test[ -]?scaffold|\bscratch\b|^r[0-9]? task [ab] /i;
// Normalize both sources to a single shape: { id, title, open, isWorkTask, scoped }.
// scoped = the task is PLACED — live: nested under a parent (phase/goal) or carries a
// kind/umbrella/intention label; snapshot: has commits OR touched files OR an intention
// match (predictedVia !== "none"). An UNPLACEABLE open work-task is the staleness candidate.
let openTasks = [], taskSource = "snapshot", taskAgeKnown = false;
const fromLive = () => {
  let raw;
  try { raw = execFileSync("bp", ["task", "ls", "--json"], { cwd: ROOT, encoding: "utf8", maxBuffer: 64 * 1024 * 1024, stdio: ["ignore", "pipe", "ignore"] }); }
  catch { return null; }            // bp missing or errored → signal fallback
  let docs; try { docs = (JSON.parse(raw).docs) || []; } catch { return null; }
  const norm = [];
  for (const d of docs) {
    const c = d.content || {};
    const kind = d.kind || c.kind || "task";
    const status = d.lifecycle_status || c.lifecycle_status || d.status;
    const open = status !== "closed" && status !== "cancelled" && status !== "done";
    if (!open) continue;
    const labels = d.labels || c.labels || [];
    const parent = d.parent_id || c.parent_id;
    const scoped = !!parent || labels.some((l) => /^(kind:|umbrella-|intention:|goal-|phase-)/.test(String(l)));
    norm.push({ id: String(d.doc_id || d.id || ""), title: d.title || c.title || "", open: true,
      isWorkTask: kind === "task", scoped });
  }
  return norm;
};
const live = fromLive();
if (live) { openTasks = live; taskSource = "live (bp task ls)"; }
else {
  const tasksRep = rd("tooling/tasks/tasks-report.json", { tasks: [] });
  taskAgeKnown = (tasksRep.tasks || []).some((t) => Object.keys(t).some((k) => /creat|updat|closed_at|age/i.test(k)));
  openTasks = (tasksRep.tasks || []).filter((t) => t.open).map((t) => ({
    id: String(t.id || ""), title: t.title || "", open: true,
    isWorkTask: (t.kind === "task" || t.kind === undefined),
    scoped: (t.commits || 0) > 0 || (t.actualFiles?.length || 0) > 0 || t.predictedVia !== "none",
  }));
}
const junkTasks = openTasks.filter((t) => JUNK_TITLE.test(t.title || ""));
const unscopedOpen = openTasks.filter((t) => t.isWorkTask && !t.scoped && !JUNK_TITLE.test(t.title || ""));
const deadTaskPenalty = Math.min(16, 2.2 * junkTasks.length + 0.25 * unscopedOpen.length);
for (const t of junkTasks) {
  aesthetics.push({
    path: "bp-task:" + String(t.id).replace(/^drafts\./, ""),
    kind: "dead-task",
    severity: 0.5,
    why: `Open task with debris title "${t.title}" (probe / test-scaffold / delete-me) — clutters the work queue with something that doesn't matter. YAGNI.`,
    fix: `Close / cancel the task (bp task close). Test-probe and "delete me" tasks should never linger open.`,
  });
}
if (unscopedOpen.length) {
  aesthetics.push({
    path: "bp-task:(unscoped-open ×" + unscopedOpen.length + ")",
    kind: "dead-task",
    severity: 0.32,
    why: `${unscopedOpen.length} open work-tasks are unplaceable — no parent phase/goal and no kind/umbrella/intention label (snapshot source: 0 commits + 0 files + no intention match). CANDIDATES for staleness (no reliable age signal to confirm). Source: ${taskSource}. e.g. ${unscopedOpen.slice(0, 4).map((t) => String(t.id).replace(/^drafts\./, "")).join(", ")}.`,
    fix: `Triage: place them under a phase/goal (or label them) and schedule, or close the ones that no longer matter.`,
  });
}

// ── YAGNI ORPHANS (non-source files with no inbound reference, no build role) ──
// CONSERVATIVE: source-language orphans are invisible to grep (symbol/package refs
// aren't path refs) → scoped to NON-source, non-standard, non-doc tracked files.
const yagniOrphans = [];
// skip dirs whose files are referenced by directory CONVENTION (grep can't see it):
// golden/testdata fixtures, snapshots, migrations, demo data, and the attic grave.
const ORPHAN_SKIP = /(^|\/)(\.github|\.changeset|\.vscode|node_modules|_attic|migrations|fixtures|__fixtures__|__snapshots__|snapshots|test|tests|testdata|golden|goldens|samples|demo|\.demo-content)(\/|$)/i;
const NONSOURCE_SUSPECT = /\.(md|txt|rst|sample|example|bak|old|orig|tmp)$/i;
for (const p of files) {
  if (p.endsWith(".md")) continue; // docs handled above
  if (ORPHAN_SKIP.test(p)) continue;
  if (STANDARD.test(basename(p))) continue;
  if (!NONSOURCE_SUSPECT.test(p)) continue; // only obviously-scratch non-source files
  if (referenced(p)) continue;
  yagniOrphans.push(p);
}
const orphanPenalty = Math.min(8, 4 * yagniOrphans.length);
for (const p of yagniOrphans) {
  aesthetics.push({
    path: p,
    kind: "yagni-orphan",
    severity: 0.45,
    why: `Non-source file with no inbound reference anywhere in the tree and no build/runtime role — speculative scaffolding. YAGNI.`,
    fix: `Remove it, or wire it in if it has a purpose. (Source-language orphans are not scanned here — grep can't see symbol/package references.)`,
  });
}

const aestheticsScore = clamp(100 - deadDocPenalty - deadTaskPenalty - orphanPenalty);

// ════════════════════════════════════════════════════════════════════════════
// REPORT
// ════════════════════════════════════════════════════════════════════════════
const summary = {
  rootClutter: rootSource.length,
  rootClutterExt: dominantExt ? `.${dominantExt[0]}×${dominantExt[1].length}` : "—",
  trackedArtifacts: artifacts.length,
  buildOutput: buildOutput.length,
  deliberateArtifacts: deliberate.length,      // served + published (near-zero penalty)
  typedefs: typedefs.length,
  servedOrTyped: deliberate.length + typedefs.length,  // back-compat for quality.mjs note
  fanoutDirs: fanoutDirs.length,
  deadDocsAttic: atticDocs.length,
  datedDumps: datedDumps.length,
  orphanDocs: orphanDocs.length,
  junkTasks: junkTasks.length,
  unscopedOpenTasks: unscopedOpen.length,
  yagniOrphans: yagniOrphans.length,
  taskSource,
  taskStaleness: `${taskSource} · ${taskAgeKnown ? "timestamped" : "no reliable age (title-debris + unscoped-open heuristic only)"}`,
  formula: {
    bloat: "100 − min(38, 1.3·max(0,roots−3)) − min(22, 2.0·buildOut + 0.3·deliberate + 0.8·typedef) − min(12, 3·fanoutDirs)",
    aesthetics: "100 − [min(14, .25·attic) + min(18, 4·orphanDocs)] − min(16, 2.2·junk + .25·unscoped) − min(8, 4·yagniOrphans)",
  },
};
const penalties = {
  bloat: { rootClutter: +rootClutterPenalty.toFixed(2), artifacts: +artifactPenalty.toFixed(2), fanout: +fanoutPenalty.toFixed(2) },
  aesthetics: { deadDocs: +deadDocPenalty.toFixed(2), deadTasks: +deadTaskPenalty.toFixed(2), yagniOrphans: +orphanPenalty.toFixed(2) },
};
const out = {
  at: new Date().toISOString(),
  bloat: { score: bloatScore, findings: bloat },
  aesthetics: { score: aestheticsScore, findings: aesthetics },
  penalties,
  summary,
};
writeFileSync(join(HERE, "aesthetics-report.json"), JSON.stringify(out, null, 2));

// ── console summary ──
e(`\n  FILEBASE AESTHETICS — YAGNI critic (higher = cleaner)`);
e(`    Bloat       ${String(bloatScore).padStart(3)}  root-clutter ${summary.rootClutter} src in root (${summary.rootClutterExt}) · ${summary.trackedArtifacts} tracked artifacts (${summary.buildOutput} build-output, ${summary.deliberateArtifacts} served/published, ${summary.typedefs} typedef) · ${summary.fanoutDirs} over-flat dirs`);
e(`                     penalties: root −${penalties.bloat.rootClutter} · artifacts −${penalties.bloat.artifacts} · fanout −${penalties.bloat.fanout}`);
e(`    Aesthetics  ${String(aestheticsScore).padStart(3)}  ${summary.deadDocsAttic} dead docs (_attic grave) · ${summary.orphanDocs} live-tree orphans · ${summary.junkTasks} junk + ${summary.unscopedOpenTasks} unscoped open tasks · ${summary.yagniOrphans} yagni-orphans`);
e(`                     penalties: dead-docs −${penalties.aesthetics.deadDocs} · dead-tasks −${penalties.aesthetics.deadTasks} · orphans −${penalties.aesthetics.yagniOrphans}`);
e(`    task staleness: ${summary.taskStaleness}`);
e(`  → tooling/aesthetics/aesthetics-report.json  (${bloat.length + aesthetics.length} findings)`);
