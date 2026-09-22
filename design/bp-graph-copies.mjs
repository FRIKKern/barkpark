// bp-graph-copies.mjs — THE predicate that says which files are bp-graph.js
// copies. One rule, one implementation, imported by every gate that needs it.
//
// WHY A SHARED MODULE: two enumerations that disagree are worse than one.
// design/graph-palette-authority.test.mjs already enrolled its subjects by
// walking the tree ("every bp-graph.js the walk finds") precisely so a fifth
// copy could not hide from it. design/bp-graph-mirror-census.test.mjs needs the
// SAME subject set to reconcile scripts/check-bp-graph-drift.sh's hardcoded
// MIRRORS list against reality. If each grew its own walk they would drift, and
// a copy could fall between them. So the walk lives here, once.
//
// AN ENUMERATION IS A SNAPSHOT; A PREDICATE IS A RULE. The rule is: any file
// named bp-graph.js anywhere under the repo, minus the directories below, which
// hold vendored, generated, or throwaway trees rather than authored sources.

import { readdirSync, statSync } from "node:fs";
import { join, relative, sep } from "node:path";

// The declared canonical, repo-relative. Every other copy is a mirror of it.
// scripts/check-bp-graph-drift.sh names the same path as CANONICAL, and
// design/bp-graph-mirror-census.test.mjs asserts the two agree.
export const CANONICAL_REL = "api/priv/static/assets/bp-graph.js";

export const SKIP_DIRS = new Set([
  "node_modules", ".git", ".claude", "_build", "deps", "dist", ".next",
  ".turbo", "priv/static/cache_manifest", "coverage",
]);

// findCopies(dir) — absolute paths of every bp-graph.js under dir.
export function findCopies(dir, out = []) {
  for (const name of readdirSync(dir)) {
    if (SKIP_DIRS.has(name)) continue;
    const p = join(dir, name);
    let st;
    try { st = statSync(p); } catch { continue; }
    if (st.isDirectory()) findCopies(p, out);
    else if (name === "bp-graph.js") out.push(p);
  }
  return out;
}

// copyRelPaths(repoRoot) — repo-relative, POSIX-separated, sorted. This is the
// form both the census and the shell gate's MIRRORS list speak.
export function copyRelPaths(repoRoot) {
  return findCopies(repoRoot)
    .map((p) => relative(repoRoot, p).split(sep).join("/"))
    .sort();
}
