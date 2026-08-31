#!/usr/bin/env node
// boundary.mjs — cqv8 Phase 5: the boundary gate + gated recolocation.
//
// P1 detected the concepts and banded them on the dependency-stability gradient.
// P3 graded every concept against five gaps. P4 scaffolds NEW concepts into the
// right shape. P5 is ENFORCEMENT: it stops a feature boundary from being violated
// at the point a change introduces the violation, and it proposes recolocating
// EXISTING scatter behind a never-worse gate — propose-only, nothing ever moves.
//
//   node tooling/concept-map/boundary.mjs [--json]
//
// ── THE GATE — gateBoundary(proposed) (spec §5/§8, Figure 7) ──────────────────
// A proposed change is a set of NEW edges plus (optionally) NEW files. The gate
// runs the SAME band/concept vocabulary P1/P3 speak and flags three violation
// classes — the three the spec names:
//
//   1. SIDEWAYS        a NEW feature→feature edge: a non-kernel concept depending
//                      on a DIFFERENT non-kernel concept. Features depend only
//                      inward on the kernel; a sideways edge is the canonical
//                      boundary break P3 already counts on the existing graph.
//   2. WRONG-DIRECTION a NEW kernel→feature edge: a KERNEL concept depending on a
//                      FEATURE. The dependency gradient runs feature→kernel; the
//                      reverse makes the substrate depend on a leaf — the worst
//                      direction, because it drags the feature into the kernel's
//                      reach. (content → sheets is the live example.)
//   3. SCATTER-INCREASE a NEW file that lands a concept in a top-dir tree it does
//                      not already occupy — raising its scatter number. P3's gap 5
//                      measures scatter; P5 prevents it from getting worse.
//
// gateBoundary returns { verdict: 'ok' | 'violation', violations: [...] }. Each
// violation is named, typed, and carries the offending edge/file so a caller (a
// pre-commit lint, a CI gate) can print it verbatim. The gate is COMPUTED against
// the live banded graph — it never hardcodes which concepts are kernel/feature.
//
// ── THE RECOLOCATION — proposeRecolocation(concept) (spec §5 check 1, §8) ─────
// For a SCATTERED concept (sheets: graph cohesion 0.87, physically across many
// trees) P5 proposes pulling its GRATUITOUS-CORE half plus its scattered member
// files into ONE feature home directory. The proposal is gated by a NEVER-WORSE
// check borrowed from cqv7: every member file the concept owns today must be
// ACCOUNTED FOR in the plan — 0 lost. The count of files before the move must
// equal the count after; each input file maps to exactly one output path. If a
// single file would be dropped, the proposal is marked `neverWorse:false` and is
// not offered. It is ALWAYS propose-only — proposeRecolocation moves nothing,
// touches no real file, returns a plan + a diff-style preview only.
//
// Dependency-free. ESM, node: builtins only. Reuses P1 (runConcepts) for bands +
// per-concept coupling and the real symbol graph for the concept assignment and
// the edge/file arithmetic. Computes everything live — never hardcodes an
// expected edge, file, count, or verdict.

import { execFileSync } from "node:child_process";
import { readFileSync, existsSync, mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { runConcepts } from "./concepts.mjs";
import { isEntryPoint, isMixTaskFile } from "./entrypoints.mjs";
import { conceptTokenMatchers } from "./concept-tokens.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: HERE })
  .toString()
  .trim();

const SYMBOLS_PATH = join(ROOT, "tooling/symbol-graph/symbols.json");

// Propose-only staging tree (gitignored) — decycle may stage a human-readable
// plan here, mirroring scaffold.mjs. NOTHING tracked is ever written.
const STAGING_ROOT = join(HERE, ".scaffold-staging");

// ── load + concept assignment (mirrors concepts.mjs structural detection) ────
// P5 must speak the EXACT same concept vocabulary P1 banded against, so the
// two-pass assignment is reproduced verbatim — primary domain/plugin names off
// the tree, then cross-tree members folded into the longest matching token.
function loadGraph() {
  if (!existsSync(SYMBOLS_PATH)) {
    throw new Error(
      `symbol graph not found at ${SYMBOLS_PATH} — run tooling/symbol-graph/build-symbols.mjs first`
    );
  }
  return JSON.parse(readFileSync(SYMBOLS_PATH, "utf8"));
}

function primaryConcept(file) {
  let m;
  if ((m = file.match(/^api\/lib\/barkpark\/plugins\/([a-z0-9_]+)(?:[/.]|$)/))) return m[1];
  if ((m = file.match(/^api\/lib\/barkpark\/([a-z0-9_]+)(?:[/.]|$)/))) return m[1];
  return null;
}

function assignConcepts(graph) {
  const conceptOf = new Map();
  const concepts = new Set();
  const filesOf = new Map(); // concept → Set<file>
  for (const n of graph.nodes) {
    const c = primaryConcept(n.file);
    if (c) {
      conceptOf.set(n.id, c);
      concepts.add(c);
    }
  }
  const tokens = [...concepts].sort((a, b) => b.length - a.length);
  const tokenRe = conceptTokenMatchers(tokens);
  for (const n of graph.nodes) {
    if (conceptOf.has(n.id)) continue;
    // Mix CLI tasks are entry-points, never feature members — mirror P1's fold
    // exclusion so all three passes share ONE concept vocabulary (concepts.mjs).
    if (isMixTaskFile(n.file)) continue;
    const low = n.file.toLowerCase();
    for (const t of tokens) {
      if (tokenRe.get(t).test(low)) {
        conceptOf.set(n.id, t);
        break;
      }
    }
  }
  for (const n of graph.nodes) {
    const c = conceptOf.get(n.id);
    if (!c) continue;
    if (!filesOf.has(c)) filesOf.set(c, new Set());
    filesOf.get(c).add(n.file);
  }
  return { conceptOf, concepts, filesOf };
}

// Top-dir tree of a file — the first two path segments. The scatter number P3
// reports counts DISTINCT such trees per concept; P5's scatter-increase check
// keys off the same granularity so the two tools agree.
function topDir(file) {
  return file.split("/").slice(0, 2).join("/");
}

// The feature-meaningful home root for a concept's file: deeper than topDir so
// proposals read as real feature folders (api/lib/barkpark, api/lib/barkpark_web,
// web/lib …) rather than the coarse api/lib bucket every Elixir file shares. Used
// only to PICK the densest home; the scatter math itself stays on topDir.
function homeRoot(file) {
  const parts = file.split("/");
  if (parts[0] === "api" && parts[1] === "lib" && parts[2]) {
    return parts.slice(0, 3).join("/"); // api/lib/barkpark, api/lib/barkpark_web
  }
  return parts.slice(0, 2).join("/"); // web/lib, web/app, …
}

// ── the gate ─────────────────────────────────────────────────────────────────
// gateBoundary(proposed, opts) — judge a proposed change against feature
// boundaries. `proposed` is:
//   {
//     edges: [{ from, to }]   // NEW edges, by symbol id OR by concept token.
//                             // (we resolve a symbol id to its concept; a bare
//                             // token is taken as the concept directly.)
//     files: [{ path, concept? }]  // NEW files; concept inferred from the path
//                             // if not given. Used for the scatter-increase check.
//   }
// Returns { verdict:'ok'|'violation', violations:[{ type, ... }], context:{…} }.
export function gateBoundary(proposed = {}, opts = {}) {
  const graph = opts.graph || loadGraph();
  const p1 = opts.p1 || runConcepts();
  const { conceptOf, concepts, filesOf } = opts.assigned || assignConcepts(graph);
  const kernelSet = new Set(p1.bands.kernel);
  const knownConcepts = new Set(concepts);

  // resolve an edge endpoint (symbol id OR concept token) to its concept token.
  const resolve = (endpoint) => {
    if (endpoint == null) return null;
    if (conceptOf.has(endpoint)) return conceptOf.get(endpoint); // a symbol id
    if (knownConcepts.has(endpoint)) return endpoint; // already a concept token
    // fall back to the structural namer (lets callers pass a bare file path too)
    const c = primaryConcept(String(endpoint));
    return c && knownConcepts.has(c) ? c : null;
  };

  const violations = [];
  const edges = Array.isArray(proposed.edges) ? proposed.edges : [];
  const files = Array.isArray(proposed.files) ? proposed.files : [];

  for (const e of edges) {
    const from = resolve(e.from);
    const to = resolve(e.to);
    if (!from || !to || from === to) continue; // intra / unresolved → not a boundary edge

    const fromKernel = kernelSet.has(from);
    const toKernel = kernelSet.has(to);

    // 2. WRONG-DIRECTION — a kernel concept depending on a feature. Checked first:
    // it is the most severe (the substrate must never depend on a leaf), and it
    // takes priority over the sideways framing when the source is the kernel.
    if (fromKernel && !toKernel) {
      violations.push({
        type: "wrong-direction",
        edge: `${from} → ${to}`,
        from,
        to,
        reason:
          `KERNEL concept "${from}" would depend on FEATURE "${to}" — the dependency ` +
          `gradient runs feature→kernel; this reverse drags the feature into the substrate.`,
        rawEdge: { from: e.from, to: e.to },
      });
      continue;
    }

    // 1. SIDEWAYS — a non-kernel feature depending on a DIFFERENT non-kernel
    // feature. Features may only depend inward on the kernel.
    if (!fromKernel && !toKernel) {
      violations.push({
        type: "sideways",
        edge: `${from} → ${to}`,
        from,
        to,
        reason:
          `FEATURE "${from}" would depend sideways on FEATURE "${to}" — features may ` +
          `depend only inward on the kernel, never on a sibling feature.`,
        rawEdge: { from: e.from, to: e.to },
      });
      continue;
    }
    // feature→kernel (allowed inward) and kernel→kernel (substrate-internal) pass.
  }

  // 3. SCATTER-INCREASE — a new file landing a concept in a top-dir tree it does
  // not already occupy. The concept's CURRENT trees come from its member files.
  for (const f of files) {
    const path = typeof f === "string" ? f : f.path;
    if (!path) continue;
    const c = (typeof f === "object" && f.concept) || resolve(path) || primaryConcept(path);
    if (!c || !knownConcepts.has(c)) continue; // a brand-new concept can't scatter
    const existingTrees = new Set([...(filesOf.get(c) || [])].map(topDir));
    const tree = topDir(path);
    if (!existingTrees.has(tree)) {
      violations.push({
        type: "scatter-increase",
        concept: c,
        file: path,
        newTree: tree,
        existingTrees: [...existingTrees].sort(),
        reason:
          `new file "${path}" lands concept "${c}" in a NEW tree "${tree}" — raising ` +
          `its scatter from ${existingTrees.size} to ${existingTrees.size + 1} top-dir trees.`,
      });
    }
  }

  return {
    verdict: violations.length > 0 ? "violation" : "ok",
    violations,
    context: {
      kernel: [...kernelSet].sort(),
      edgesChecked: edges.length,
      filesChecked: files.length,
    },
  };
}

// ── the recolocation ─────────────────────────────────────────────────────────
// proposeRecolocation(concept, opts) — for a SCATTERED concept, propose pulling
// every member file it owns into one feature home directory. The plan is gated by
// the NEVER-WORSE invariant: every input file maps to exactly one output path,
// count before === count after, 0 files lost. ALWAYS propose-only.
//
// The home directory is derived, not hardcoded: the densest existing tree the
// concept already occupies (most member files) becomes the feature home, so the
// proposal pulls the OTHER trees into the place the bulk of the concept already
// lives. Each input file's new path preserves its basename under the home.
export function proposeRecolocation(concept, opts = {}) {
  const graph = opts.graph || loadGraph();
  const p1 = opts.p1 || runConcepts();
  const { conceptOf, concepts, filesOf } = opts.assigned || assignConcepts(graph);

  if (!concepts.has(concept)) {
    return {
      concept,
      proposeOnly: true,
      neverWorse: false,
      error: `unknown concept "${concept}" — not present in the symbol graph`,
      plan: [],
    };
  }

  const row = p1.concepts.find((c) => c.concept === concept) || null;
  const band = row ? row.band : null;

  // every member file the concept owns today — the COMPLETE input set the
  // never-worse check must account for.
  const memberFiles = [...(filesOf.get(concept) || [])].sort();
  const beforeCount = memberFiles.length;

  // the trees the concept currently scatters across, with file counts. Scatter
  // is measured on topDir (so it agrees with P3); the home is PICKED on the
  // finer homeRoot so the proposal names a real feature folder.
  const treeCounts = new Map();
  const homeCounts = new Map();
  for (const f of memberFiles) {
    const t = topDir(f);
    treeCounts.set(t, (treeCounts.get(t) || 0) + 1);
    const h = homeRoot(f);
    homeCounts.set(h, (homeCounts.get(h) || 0) + 1);
  }
  const trees = [...treeCounts.entries()]
    .map(([tree, count]) => ({ tree, count }))
    .sort((a, b) => b.count - a.count || a.tree.localeCompare(b.tree));

  // the feature home = the densest feature-meaningful root the concept already
  // occupies, scoped to a per-concept folder under it. Pulling the rest INTO
  // where the bulk lives is the minimal-churn move and keeps the framework-
  // forced trees honest.
  const homeRanked = [...homeCounts.entries()].sort(
    (a, b) => b[1] - a[1] || a[0].localeCompare(b[0])
  );
  const homeTreeRoot = homeRanked.length ? homeRanked[0][0] : `api/lib/barkpark`;
  const homeDir = `${homeTreeRoot}/${concept}`;

  // ── gratuitous-core slice ──────────────────────────────────────────────────
  // P3's gap 1: the concept's core half (api/lib/barkpark/<concept>*, excluding
  // any plugins/ tree) is gratuitously in the kernel when its inbound reuse is
  // overwhelmingly internal. We surface that slice here so the proposal NAMES
  // which files are the gratuitous core being colocated.
  const coreRe = new RegExp("^api/lib/barkpark/" + concept + "(?:[/.]|$)");
  const coreFiles = memberFiles.filter((f) => coreRe.test(f) && !/\/plugins\//.test(f));

  // ── the plan: every member file → exactly one home path ────────────────────
  // The new path preserves the file's basename-relative tail under the home dir,
  // de-duplicated so two files never collide on one target. This is the NEVER-
  // WORSE construction: a total function over the input set, injective on output.
  const plan = [];
  const usedTargets = new Set();
  for (const file of memberFiles) {
    const tail = relTail(file, concept, homeTreeRoot);
    let to = `${homeDir}/${tail}`;
    // collision guard — keep targets unique so no two inputs map to one output
    // (which would silently lose a file). Disambiguate with a numeric suffix.
    if (usedTargets.has(to)) {
      const ext = to.includes(".") ? to.slice(to.lastIndexOf(".")) : "";
      const stem = ext ? to.slice(0, -ext.length) : to;
      let i = 2;
      while (usedTargets.has(`${stem}__${i}${ext}`)) i++;
      to = `${stem}__${i}${ext}`;
    }
    usedTargets.add(to);
    plan.push({
      from: file,
      to,
      isGratuitousCore: coreFiles.includes(file),
      movesTree: homeRoot(file) !== homeTreeRoot,
    });
  }

  // ── never-worse gate ───────────────────────────────────────────────────────
  // EVERY input file must appear exactly once as a plan `from`; the output set
  // must be unique (no two inputs collapse onto one path); count before must
  // equal count after. Any failure → neverWorse:false and the plan is not safe
  // to offer. (Nothing is moved regardless — this only flips the safety flag.)
  const fromSet = new Set(plan.map((p) => p.from));
  const toSet = new Set(plan.map((p) => p.to));
  const afterCount = plan.length;
  const everyFileAccountedFor = fromSet.size === beforeCount;
  const noOutputCollision = toSet.size === plan.length;
  const countPreserved = beforeCount === afterCount;
  const lost = memberFiles.filter((f) => !fromSet.has(f));
  const neverWorse =
    everyFileAccountedFor && noOutputCollision && countPreserved && lost.length === 0;

  // scatter: distinct trees before → 1 tree after (everything under one home).
  const scatterBefore = trees.length;
  const scatterAfter = plan.length ? 1 : 0;

  return {
    concept,
    band,
    proposeOnly: true,
    neverWorse,
    homeDir,
    counts: {
      filesBefore: beforeCount,
      filesAfter: afterCount,
      accountedFor: fromSet.size,
      lost: lost.length,
    },
    lostFiles: lost,
    scatter: { before: scatterBefore, after: scatterAfter, trees },
    gratuitousCore: {
      files: coreFiles,
      externalPct: row ? null : null, // surfaced by P3; named here for traceability
    },
    plan,
  };
}

// The home-relative tail for a member file: strip the home root prefix (or the
// coarse top-2) and any redundant per-concept segment so the file keeps its
// meaningful suffix under the home, while staying distinct across source trees.
// e.g. api/lib/barkpark/plugins/sheets/web/export_controller.ex (home api/lib/barkpark)
//        → plugins/web/export_controller.ex
//      web/lib/sheets.ts (home api/lib/barkpark) → web/sheets.ts
function relTail(file, concept, homeRootDir) {
  const parts = file.split("/");
  let rest;
  if (homeRootDir && file.startsWith(homeRootDir + "/")) {
    // file already under the home root — strip exactly that prefix.
    rest = file.slice(homeRootDir.length + 1).split("/");
  } else {
    // file in another tree — keep its tree label (its first segment) so two
    // files with the same basename in different trees never collide.
    rest = [parts[0], ...parts.slice(2)];
  }
  // drop a redundant leading concept-named segment (it becomes the home folder).
  if (rest[0] === concept) rest = rest.slice(1);
  // collapse a leading "plugins/<concept>" pair down to "plugins/…".
  if (rest[0] === "plugins" && rest[1] === concept) {
    rest = ["plugins", ...rest.slice(2)];
  }
  const tail = rest.join("/");
  return tail || parts[parts.length - 1];
}

// ── the decycle proposer ───────────────────────────────────────────────────────
// proposeDecycle(conceptA, conceptB, opts) — break a MUTUAL feature→feature cycle
// (domain edges in BOTH directions A→B and B→A) by directionally relocating one
// side's BRIDGE modules into the other concept. Propose-only, residual-aware,
// never-worse. NOTHING moves.
//
// THE METHOD vs. THE TRAP. A cycle inflates BOTH concepts' instability/Ca — the
// metric is distorted, so picking the cut direction by current instability/Ca is
// wrong. Instead we COMPUTE both candidate cuts and pick by MEASURED residual:
//
//   For a candidate "relocate ORIGIN's bridge → TARGET":
//     bridge      = ORIGIN's NON-web files with ≥1 domain edge to TARGET. Moving
//                   them into TARGET turns those edges into intra-TARGET edges.
//     eliminated  = the bridge's domain edges to TARGET (vanish from the cross-cut).
//     residual    = domain edges from ORIGIN's REMAINING (non-bridge, non-web)
//                   files INTO the relocated bridge — after the move these become
//                   NEW origin→target edges (the bridge is still called from home).
//                   The residual caller files are listed explicitly. The cut is
//                   honest: it is rarely clean.
//     reverseBecomesCorrect = the bridge's edges back to ORIGIN — after the move
//                   these flip to TARGET→ORIGIN, the OTHER (intended) direction.
//                   Reported as a count; this is the cycle straightening, not debt.
//     netReduction = eliminated − residual.
//     remainingCycleEdges = the cross edges still standing after the move:
//                   residual (new origin→target) + the OTHER direction's full
//                   domain weight (target→origin), which this cut does not touch.
//
// We compute BOTH directions (A's bridge→B, B's bridge→A) and RECOMMEND the one
// with the higher netReduction; the other rides along as `alternative`. Tie →
// alphabetical origin so the pick is deterministic. loseNoFile: it is a MOVE, so
// filesBefore === filesAfter and lost === 0 (mirrors proposeRecolocation).
//
// Computed live off the symbol graph — no hardcoded concept names or counts.
export function proposeDecycle(conceptA, conceptB, opts = {}) {
  const graph = opts.graph || loadGraph();
  const p1 = opts.p1 || runConcepts();
  const assigned = opts.assigned || assignConcepts(graph);
  const { conceptOf, concepts, filesOf } = assigned;
  const fileOf = new Map(graph.nodes.map((n) => [n.id, n.file]));

  if (!concepts.has(conceptA) || !concepts.has(conceptB) || conceptA === conceptB) {
    return {
      a: conceptA,
      b: conceptB,
      proposeOnly: true,
      error:
        conceptA === conceptB
          ? `conceptA and conceptB must differ (both "${conceptA}")`
          : `unknown concept(s): ${[conceptA, conceptB].filter((c) => !concepts.has(c)).join(", ")}`,
      cycle: { a2b: 0, b2a: 0 },
    };
  }

  // ── domain (entry-point-excluded) cross edges between the two concepts ───────
  // An edge counts toward the cycle only when its SOURCE file is NOT an
  // entry-point — a web-layer OR Mix-task origin edge is orchestration (same
  // exclusion the grade pass applies), so it is kept out of the cycle counts
  // entirely. This is what kills the false tasks→onixedit cycle: all 13 of those
  // edges originate in api/lib/mix/tasks/onix.*.ex. Each direction is tallied with
  // the per-source-file weights we need for the bridge/residual arithmetic.
  //
  // domainEdge(origin, target):
  //   perSource : origin-file → count of its NON-web domain edges to target
  //   total     : sum of those weights (the domain edge count origin→target)
  function domainEdges(origin, target) {
    const perSource = new Map(); // origin file → edge count to target
    let total = 0;
    for (const e of graph.edges) {
      if (conceptOf.get(e.from) !== origin) continue;
      if (conceptOf.get(e.to) !== target) continue;
      const srcFile = fileOf.get(e.from);
      if (isEntryPoint(srcFile)) continue; // entry-point edge = orchestration (web OR mix-task), excluded
      perSource.set(srcFile, (perSource.get(srcFile) || 0) + 1);
      total++;
    }
    return { perSource, total };
  }

  const a2bEdges = domainEdges(conceptA, conceptB);
  const b2aEdges = domainEdges(conceptB, conceptA);
  const a2b = a2bEdges.total;
  const b2a = b2aEdges.total;

  // ── evaluate ONE candidate cut: relocate origin's bridge → target ───────────
  function candidate(origin, target, originEdges) {
    const targetDir = `api/lib/barkpark/${target}/from_${origin}`;

    // BRIDGE = origin's NON-web files with ≥1 domain edge to target.
    const bridgeSet = new Set([...originEdges.perSource.keys()]);
    const moveFiles = [...bridgeSet].sort();

    // eliminated = the bridge's domain edges to target (these become intra-target).
    let eliminated = 0;
    for (const f of moveFiles) eliminated += originEdges.perSource.get(f) || 0;

    // bridge node ids — needed for residual (origin→bridge) and reverse
    // (bridge→origin) tallies. Restricted to NON-web origin nodes in the bridge.
    const bridgeIds = new Set();
    for (const n of graph.nodes) {
      if (conceptOf.get(n.id) !== origin) continue;
      if (bridgeSet.has(n.file)) bridgeIds.add(n.id);
    }

    // RESIDUAL = domain edges from origin's REMAINING (non-bridge, non-web) files
    // INTO the relocated bridge. After the move the bridge lives in target, so
    // these home calls become NEW origin→target edges. Tally per remaining caller.
    const residualPerCaller = new Map(); // caller file → count into bridge
    // REVERSE = bridge → origin edges (any origin target). After the move these
    // flip to target→origin — the OTHER (intended) cycle direction.
    let reverseBecomesCorrect = 0;
    for (const e of graph.edges) {
      // residual: remaining-origin → bridge
      if (
        bridgeIds.has(e.to) &&
        conceptOf.get(e.from) === origin &&
        !bridgeIds.has(e.from)
      ) {
        const callerFile = fileOf.get(e.from);
        if (!isEntryPoint(callerFile)) {
          residualPerCaller.set(callerFile, (residualPerCaller.get(callerFile) || 0) + 1);
        }
      }
      // reverse: bridge → (other origin file)
      if (
        bridgeIds.has(e.from) &&
        conceptOf.get(e.to) === origin &&
        !bridgeIds.has(e.to)
      ) {
        const srcFile = fileOf.get(e.from);
        if (!isEntryPoint(srcFile)) reverseBecomesCorrect++;
      }
    }
    const residualCallers = [...residualPerCaller.keys()].sort();
    const residual = [...residualPerCaller.values()].reduce((s, n) => s + n, 0);

    const netReduction = eliminated - residual;

    // remaining cycle edges after this cut: the new origin→target residual edges
    // plus the UNTOUCHED reverse-direction domain weight (target→origin), which
    // this cut does not address.
    const otherDirTotal = origin === conceptA ? b2a : a2b;
    const remainingCycleEdges = residual + otherDirTotal;

    const filesBefore = (filesOf.get(origin) || new Set()).size;

    return {
      direction: `${origin}→${target}`,
      origin,
      target,
      targetDir,
      moveFiles,
      eliminated,
      residual,
      residualCallers,
      reverseBecomesCorrect,
      netReduction,
      remainingCycleEdges,
      neverWorse: { filesBefore, filesAfter: filesBefore, lost: 0 },
    };
  }

  const candA = candidate(conceptA, conceptB, a2bEdges); // relocate A's bridge → B
  const candB = candidate(conceptB, conceptA, b2aEdges); // relocate B's bridge → A

  // RECOMMEND by measured residual, NOT by current instability/Ca. Higher
  // netReduction wins; tie broken on lower residual, then alphabetical origin.
  const [recommendation, alternative] =
    candB.netReduction > candA.netReduction ||
    (candB.netReduction === candA.netReduction &&
      (candB.residual < candA.residual ||
        (candB.residual === candA.residual && candB.origin < candA.origin)))
      ? [candB, candA]
      : [candA, candB];

  const result = {
    a: conceptA,
    b: conceptB,
    cycle: { a2b, b2a },
    recommendation,
    alternative,
    proposeOnly: true,
    neverWorse: recommendation.neverWorse,
  };

  // optionally stage a human-readable plan into the gitignored staging tree —
  // never into a tracked path (mirrors scaffold.mjs's assertUnderStaging guard).
  if (opts.stage) {
    const dir = join(STAGING_ROOT, `decycle-${conceptA}-${conceptB}`);
    assertUnderStaging(dir);
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "plan.json"), JSON.stringify(result, null, 2) + "\n");
    writeFileSync(join(dir, "PLAN.md"), decyclePlanText(result));
    result.stagingDir = join(
      "tooling/concept-map/.scaffold-staging",
      `decycle-${conceptA}-${conceptB}`
    );
  }

  return result;
}

// HARD GUARD — refuse to write anywhere but the gitignored staging tree.
function assertUnderStaging(abs) {
  const prefix = STAGING_ROOT.endsWith("/") ? STAGING_ROOT : STAGING_ROOT + "/";
  if (abs !== STAGING_ROOT && !abs.startsWith(prefix)) {
    throw new Error(
      `propose-only violation: refused to write outside staging\n  target: ${abs}\n  staging: ${STAGING_ROOT}`
    );
  }
}

// Human-readable decycle plan body for the staging sidecar.
function decyclePlanText(res) {
  const r = res.recommendation;
  const a = res.alternative;
  const lines = [];
  lines.push(`# Decycle plan — ${res.a} ⇄ ${res.b}  (PROPOSE-ONLY · nothing moves)`);
  lines.push("");
  lines.push(`Cycle (domain, web-excluded): ${res.a}→${res.b} = ${res.cycle.a2b}, ${res.b}→${res.a} = ${res.cycle.b2a}`);
  lines.push("");
  lines.push(`## Recommended: ${r.direction}  (netReduction ${r.netReduction})`);
  lines.push(`Relocate ${r.moveFiles.length} bridge file(s) → ${r.targetDir}`);
  lines.push(`  eliminated ${r.eliminated} · residual ${r.residual} · reverse-now-correct ${r.reverseBecomesCorrect} · remaining-cycle ${r.remainingCycleEdges}`);
  for (const f of r.moveFiles) lines.push(`    move  ${f}`);
  if (r.residualCallers.length) {
    lines.push(`  residual callers (remain in ${r.origin}, still reach the bridge):`);
    for (const f of r.residualCallers) lines.push(`    ·  ${f}`);
  }
  lines.push("");
  lines.push(`## Alternative: ${a.direction}  (netReduction ${a.netReduction})`);
  lines.push(`Relocate ${a.moveFiles.length} bridge file(s) → ${a.targetDir}`);
  lines.push(`  eliminated ${a.eliminated} · residual ${a.residual} · reverse-now-correct ${a.reverseBecomesCorrect} · remaining-cycle ${a.remainingCycleEdges}`);
  lines.push("");
  return lines.join("\n") + "\n";
}

// ── public entrypoint ────────────────────────────────────────────────────────
// The CLI surfaces (a) the CURRENT boundary violations already on the graph —
// every existing sideways/wrong-direction edge framed as if it were proposed —
// and (b) a sample recolocation for the most-scattered tangled feature.
export function runBoundary(opts = {}) {
  const graph = opts.graph || loadGraph();
  const p1 = opts.p1 || runConcepts();
  const assigned = assignConcepts(graph);
  const { conceptOf, filesOf } = assigned;
  const kernelSet = new Set(p1.bands.kernel);

  // synthesize the "proposed" edge set from the EXISTING cross-concept edges, so
  // the gate reports the live boundary state (sideways + wrong-direction counts).
  //
  // ENTRY-POINT EDGES ARE EXCLUDED, exactly as the other two passes exclude them.
  // entrypoints.mjs states the rule for the whole of cqv8: "A feature→feature
  // edge whose SOURCE file is an entry-point is ORCHESTRATION, not a
  // domain-coupling boundary violation", and requires that the passes "agree on
  // EXACTLY what entry-point means". The grade pass drops them from its sideways
  // counter and proposeDecycle's domainEdges() drops them from the cycle
  // analysis — but this live-state path, the one feeding the CI gate, counted
  // them. So a Phoenix controller calling a context (settings_live.ex →
  // Auth.has_permission?) was reported as an architectural violation. That is
  // the intended direction in a Phoenix app, and it is why the third pass
  // disagreed with the other two.
  const fileOf = new Map(graph.nodes.map((n) => [n.id, n.file]));
  const edgeKey = new Map(); // "from→to" concept edge → count
  const edgeRaw = new Map(); // key → a representative raw {from,to}
  for (const e of graph.edges) {
    const cf = conceptOf.get(e.from);
    const ct = conceptOf.get(e.to);
    if (!cf || !ct || cf === ct) continue;
    if (isEntryPoint(fileOf.get(e.from) || "")) continue; // orchestration, not coupling
    const k = cf + "→" + ct;
    edgeKey.set(k, (edgeKey.get(k) || 0) + 1);
    if (!edgeRaw.has(k)) edgeRaw.set(k, { from: cf, to: ct });
  }
  const proposedEdges = [...edgeRaw.values()];
  const gate = gateBoundary({ edges: proposedEdges }, { graph, p1, assigned });
  // attach the live edge weight to each violation
  for (const v of gate.violations) {
    if (v.edge) v.weight = edgeKey.get(v.from + "→" + v.to) || 1;
  }
  gate.violations.sort(
    (a, b) =>
      (b.weight || 0) - (a.weight || 0) || String(a.edge).localeCompare(String(b.edge))
  );

  // pick a sample concept to recolocate: the most-scattered non-kernel feature
  // (most distinct trees), tie-broken by file count. Falls back to "sheets".
  const featureRows = p1.concepts.filter(
    (c) => c.band !== "KERNEL" && c.band !== "noise" && (filesOf.get(c.concept) || new Set()).size > 0
  );
  const scatterOf = (c) =>
    new Set([...(filesOf.get(c.concept) || [])].map(topDir)).size;
  featureRows.sort(
    (a, b) => scatterOf(b) - scatterOf(a) || (filesOf.get(b.concept)?.size || 0) - (filesOf.get(a.concept)?.size || 0)
  );
  const sampleConcept = (featureRows[0] && featureRows[0].concept) || "sheets";
  const recolocation = proposeRecolocation(sampleConcept, { graph, p1, assigned });

  return {
    builtAt: new Date().toISOString(),
    graph: { nodes: graph.nodes.length, edges: graph.edges.length },
    kernel: [...kernelSet].sort(),
    gate,
    counts: {
      sideways: gate.violations.filter((v) => v.type === "sideways").length,
      wrongDirection: gate.violations.filter((v) => v.type === "wrong-direction").length,
    },
    sampleRecolocation: recolocation,
  };
}

// ── human output ─────────────────────────────────────────────────────────────
function pad(s, n) {
  s = String(s);
  return s.length >= n ? s : s + " ".repeat(n - s.length);
}
function padL(s, n) {
  s = String(s);
  return s.length >= n ? s : " ".repeat(n - s.length) + s;
}

function printHuman(res) {
  const out = (s) => process.stdout.write(s);
  const bar = "─".repeat(82);
  out(`\n${bar}\n`);
  out(`cqv8 P5 — boundary gate + gated recolocation\n`);
  out(
    `${res.graph.nodes} nodes · ${res.graph.edges} edges · ` +
      `${res.counts.sideways} sideways · ${res.counts.wrongDirection} wrong-direction (live)\n`
  );
  out(`  kernel: ${res.kernel.join(", ")}\n`);
  out(`${bar}\n\n`);

  out(`BOUNDARY VIOLATIONS ON THE CURRENT GRAPH (top 20)\n`);
  out(`  ${pad("type", 16)}${pad("edge", 38)}${padL("edges", 7)}\n`);
  out(`  ${"-".repeat(78)}\n`);
  const shown = res.gate.violations.slice(0, 20);
  if (shown.length === 0) out(`  (none — clean)\n`);
  for (const v of shown) {
    if (v.type === "scatter-increase") continue;
    out(`  ${pad(v.type, 16)}${pad(v.edge, 38)}${padL(v.weight || "", 7)}\n`);
  }
  if (res.gate.violations.length > 20) {
    out(`  … +${res.gate.violations.length - 20} more\n`);
  }

  const r = res.sampleRecolocation;
  out(`\nSAMPLE RECOLOCATION — "${r.concept}"  (PROPOSE-ONLY · nothing moves)\n`);
  out(`  ${"-".repeat(78)}\n`);
  if (r.error) {
    out(`  error: ${r.error}\n`);
  } else {
    out(`  home dir:     ${r.homeDir}\n`);
    out(
      `  never-worse:  ${r.neverWorse ? "✓ PASS" : "✗ FAIL"}  ` +
        `(${r.counts.filesBefore} before → ${r.counts.filesAfter} after · ` +
        `${r.counts.accountedFor} accounted · ${r.counts.lost} lost)\n`
    );
    out(`  scatter:      ${r.scatter.before} trees → ${r.scatter.after} tree\n`);
    out(`  gratuitous core (${r.gratuitousCore.files.length} file(s)):\n`);
    for (const f of r.gratuitousCore.files) out(`      · ${f}\n`);
    out(`\n  PLAN (${r.plan.length} files, every member accounted for):\n`);
    for (const p of r.plan) {
      const mark = p.movesTree ? "→" : "·";
      out(`    ${mark} ${pad(p.from, 52)} ⇒ ${p.to}\n`);
    }
  }
  out(`\n${bar}\n`);
}

// ── decycle human output ─────────────────────────────────────────────────────
function printDecycle(res) {
  const out = (s) => process.stdout.write(s);
  const bar = "─".repeat(82);
  out(`\n${bar}\n`);
  out(`cqv8 P5 — decycle proposer  (PROPOSE-ONLY · nothing moves)\n`);
  if (res.error) {
    out(`  error: ${res.error}\n${bar}\n`);
    return;
  }
  out(
    `  cycle (domain, web-excluded):  ${res.a}→${res.b} = ${res.cycle.a2b}` +
      `   ·   ${res.b}→${res.a} = ${res.cycle.b2a}\n`
  );
  out(`${bar}\n\n`);

  const block = (label, c) => {
    out(`${label}: ${c.direction}   netReduction ${c.netReduction}\n`);
    out(`  ${"-".repeat(78)}\n`);
    out(`  target dir:   ${c.targetDir}\n`);
    out(
      `  eliminated ${c.eliminated} · residual ${c.residual} · ` +
        `reverse-now-correct ${c.reverseBecomesCorrect} · remaining-cycle ${c.remainingCycleEdges}\n`
    );
    out(
      `  never-worse:  ${c.neverWorse.filesBefore} files before → ` +
        `${c.neverWorse.filesAfter} after · ${c.neverWorse.lost} lost\n`
    );
    out(`  bridge (${c.moveFiles.length} file(s) to relocate):\n`);
    for (const f of c.moveFiles) out(`      → ${f}\n`);
    if (c.residualCallers.length) {
      out(`  residual callers (${c.residualCallers.length} — stay in ${c.origin}, still reach the bridge):\n`);
      for (const f of c.residualCallers) out(`      · ${f}\n`);
    }
    out(`\n`);
  };

  block("RECOMMENDATION", res.recommendation);
  block("ALTERNATIVE", res.alternative);
  if (res.stagingDir) out(`  staged plan: ${res.stagingDir}\n\n`);
  out(`${bar}\n`);
}

// ── CLI ──────────────────────────────────────────────────────────────────────
function main() {
  const argv = process.argv.slice(2);
  const json = argv.includes("--json");

  if (argv[0] === "decycle") {
    const rest = argv.slice(1).filter((a) => !a.startsWith("--"));
    const [a, b] = rest;
    if (!a || !b) {
      process.stderr.write(
        "usage: node tooling/concept-map/boundary.mjs decycle <A> <B> [--stage] [--json]\n"
      );
      process.exit(2);
    }
    const res = proposeDecycle(a, b, { stage: argv.includes("--stage") });
    if (json) process.stdout.write(JSON.stringify(res, null, 2) + "\n");
    else printDecycle(res);
    process.exit(0);
  }

  const res = runBoundary();
  if (json) {
    process.stdout.write(JSON.stringify(res, null, 2) + "\n");
  } else {
    printHuman(res);
  }
  // NO process.exit() here — see grade.mjs: exit() truncates a piped stdout at
  // one 64KiB pipe buffer, and ci-boundary.mjs parses this --json payload.
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  main();
}
