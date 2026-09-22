// bp-graph-mirror-census.test.mjs — reconciles the bp-graph.js mirror set that
// EXISTS against the mirror set scripts/check-bp-graph-drift.sh KNOWS ABOUT,
// and enforces byte identity by PREDICATE rather than by list.
//
// THE DEFECT THIS CLOSES. That shell gate declares its subjects as two literals:
//
//     CANONICAL="api/priv/static/assets/bp-graph.js"
//     MIRRORS="web/public/bp-graph.js
//              templates/search-starter/public/bp-graph.js
//              templates/astro-search-starter/public/bp-graph.js"
//
// Nothing anywhere reconciles that list against the tree. Proved on a clean
// checkout: plant a deliberately-wrong FIFTH copy at
// templates/next-starter/public/bp-graph.js and the gate still exits 0 with
// "OK - all 3 mirrors are byte-identical to ...". A wrong copy nobody added to
// the list is invisible, forever. Its own --selftest covers mutated mirror,
// deleted mirror, mutation+deletion, missing canonical and fix-command text —
// but has no arm for an UNLISTED copy, so the gate can only ever be as complete
// as a list somebody remembered to edit.
//
// The studio lane ships starter templates, and a search-shaped template that
// renders a graph ships public/bp-graph.js by construction. templates/
// next-starter/ already exists and simply does not ship the file yet.
//
// THE SHAPE OF THE FIX: enrol by predicate, exactly as
// design/graph-palette-authority.test.mjs does — and share the SAME predicate
// (design/bp-graph-copies.mjs) rather than growing a second, divergent walk.
// Two enumerations that disagree are worse than one. This file then does two
// things the shell gate cannot:
//
//   1. IDENTITY BY PREDICATE — every bp-graph.js the walk finds must be
//      byte-identical to the canonical. An unlisted fifth copy is checked the
//      day it lands, with no list to edit.
//   2. CENSUS — the shell gate's own MIRRORS literal is read as DATA and
//      reconciled against the walk, both directions: a tracked copy absent from
//      MIRRORS reds (UNLISTED), and a MIRRORS entry with no file behind it reds
//      (PHANTOM). The list may stay explicit for ordering and fix-command text;
//      it may not stay unreconciled.
//
// EVERY ARM IS PAIRED. The reconciliation is a pure function over
// (walked, listed), so the RED arms plant a fifth copy and a phantom entry in
// argument values and assert the verdict flips, while the QUIET arm runs the
// same function over the REAL tree and the REAL script and asserts silence. A
// gate that reds on every tree is no improvement over one that passes on every
// tree.

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { copyRelPaths, CANONICAL_REL } from "./bp-graph-copies.mjs";

const REPO = join(dirname(fileURLToPath(import.meta.url)), "..");
const GATE_REL = "scripts/check-bp-graph-drift.sh";
const gateSrc = readFileSync(join(REPO, GATE_REL), "utf8");

// ── parsing the shell gate's declared subjects ───────────────────────────────

// parseGateSubjects(src) -> { canonical, mirrors }
//
// REFUSES rather than returns empty. A renamed variable, a reflowed assignment,
// or a rewritten gate must make this THROW: an empty list would reconcile
// vacuously against nothing and paint a perfect green over a gate this file no
// longer understands. Absence is never caught by inspection — so it is caught
// here, loudly.
export function parseGateSubjects(src) {
  const canonical = /^CANONICAL="([^"]+)"/m.exec(src);
  if (!canonical) {
    throw new Error(
      `${GATE_REL}: no CANONICAL="..." assignment found. If the gate was ` +
      `rewritten, re-point this census at its new subject declaration.`);
  }
  const mirrors = /^MIRRORS="([^"]*)"/m.exec(src);
  if (!mirrors) {
    throw new Error(
      `${GATE_REL}: no MIRRORS="..." assignment found. If the gate was ` +
      `rewritten, re-point this census at its new subject declaration.`);
  }
  const listed = mirrors[1]
    .split("\n")
    .map((l) => l.trim())
    .filter((l) => l.length > 0);
  if (listed.length === 0) {
    throw new Error(`${GATE_REL}: MIRRORS parsed to an EMPTY list — refusing a vacuous census.`);
  }
  return { canonical: canonical[1].trim(), mirrors: listed };
}

// reconcile(walked, listed, canonical) -> reason lines, empty when in agreement.
// Pure, so both directions can be driven from planted arguments.
export function reconcile(walked, listed, canonical) {
  const problems = [];
  const mirrorsOnDisk = walked.filter((p) => p !== canonical);
  const listedSet = new Set(listed);
  const diskSet = new Set(mirrorsOnDisk);

  if (!walked.includes(canonical)) {
    problems.push(`MISSING CANONICAL  ${canonical} — the gate compares every mirror against a file that is not there`);
  }
  for (const p of mirrorsOnDisk) {
    if (!listedSet.has(p)) {
      problems.push(`UNLISTED           ${p} — a bp-graph.js copy the tree carries and ${GATE_REL} MIRRORS does not name; it drifts unwatched`);
    }
  }
  for (const p of listed) {
    if (!diskSet.has(p)) {
      problems.push(`PHANTOM            ${p} — named in ${GATE_REL} MIRRORS with no such file in the tree`);
    }
  }
  return problems;
}

// ── controls on the instrument itself ────────────────────────────────────────

test("control: the parser reads a planted subject declaration", () => {
  const planted = [
    '#!/usr/bin/env bash',
    'CANONICAL="a/canon/bp-graph.js"',
    'MIRRORS="',
    'b/bp-graph.js',
    '',
    'c/bp-graph.js',
    '"',
  ].join("\n");
  assert.deepEqual(parseGateSubjects(planted), {
    canonical: "a/canon/bp-graph.js",
    mirrors: ["b/bp-graph.js", "c/bp-graph.js"],
  });
});

test("control: a renamed, missing or empty declaration THROWS, never reads as an empty list", () => {
  assert.throws(() => parseGateSubjects('MIRRORS="\nb/bp-graph.js\n"'), /no CANONICAL/);
  assert.throws(() => parseGateSubjects('CANONICAL="a/bp-graph.js"'), /no MIRRORS/);
  assert.throws(() => parseGateSubjects('CANONICAL="a/bp-graph.js"\nMIRRORS="\n \n"'), /EMPTY list/);
});

test("RED arm: an UNLISTED fifth copy reds the census", () => {
  const canonical = "api/priv/static/assets/bp-graph.js";
  const listed = ["web/public/bp-graph.js"];
  const walked = [canonical, "web/public/bp-graph.js", "templates/next-starter/public/bp-graph.js"];
  const problems = reconcile(walked, listed, canonical);
  assert.equal(problems.length, 1, `expected exactly one reason, got: ${problems.join(" | ")}`);
  assert.match(problems[0], /^UNLISTED\s+templates\/next-starter\/public\/bp-graph\.js/);
});

test("RED arm: a PHANTOM MIRRORS entry with no file behind it reds the census", () => {
  const canonical = "api/priv/static/assets/bp-graph.js";
  const listed = ["web/public/bp-graph.js", "templates/gone/public/bp-graph.js"];
  const walked = [canonical, "web/public/bp-graph.js"];
  const problems = reconcile(walked, listed, canonical);
  assert.equal(problems.length, 1, `expected exactly one reason, got: ${problems.join(" | ")}`);
  assert.match(problems[0], /^PHANTOM\s+templates\/gone\/public\/bp-graph\.js/);
});

test("RED arm: a canonical the walk cannot find reds the census", () => {
  const problems = reconcile(["web/public/bp-graph.js"], ["web/public/bp-graph.js"], "api/priv/static/assets/bp-graph.js");
  assert.equal(problems.length, 1);
  assert.match(problems[0], /^MISSING CANONICAL/);
});

test("QUIET arm: an agreeing list and tree produce NO reasons", () => {
  const canonical = "api/priv/static/assets/bp-graph.js";
  const listed = ["web/public/bp-graph.js", "templates/search-starter/public/bp-graph.js"];
  assert.deepEqual(reconcile([canonical, ...listed], listed, canonical), []);
});

// ── the real tree ────────────────────────────────────────────────────────────

const subjects = parseGateSubjects(gateSrc);
const walked = copyRelPaths(REPO);

test("the shell gate's CANONICAL is the canonical this predicate module declares", () => {
  assert.equal(subjects.canonical, CANONICAL_REL,
    `${GATE_REL} and design/bp-graph-copies.mjs disagree about which copy is canonical`);
});

test("control: the predicate walk enrols the four known copies", () => {
  // Without this, an empty walk would make the census below vacuously green.
  assert.ok(walked.length >= 4, `expected >= 4 bp-graph.js copies, the walk found ${walked.length}: ${walked.join(", ")}`);
  for (const want of [
    "api/priv/static/assets/bp-graph.js",
    "web/public/bp-graph.js",
    "templates/search-starter/public/bp-graph.js",
    "templates/astro-search-starter/public/bp-graph.js",
  ]) {
    assert.ok(walked.includes(want), `${want} did not enrol — the walk missed it`);
  }
});

test("QUIET arm on the REAL tree: every bp-graph.js copy is named by the shell gate", () => {
  const problems = reconcile(walked, subjects.mirrors, subjects.canonical);
  assert.deepEqual(problems, [],
    `the bp-graph.js census and ${GATE_REL} disagree:\n${problems.join("\n")}\n\n` +
    `Fix: add each UNLISTED path to the MIRRORS block in ${GATE_REL} (and copy ` +
    `${subjects.canonical} over it verbatim), or delete each PHANTOM entry.`);
});

// ── identity by predicate, which the list-driven gate cannot give ────────────

test("control: the byte comparator distinguishes different bytes", () => {
  assert.equal(Buffer.from("a").equals(Buffer.from("a")), true);
  assert.equal(Buffer.from("a").equals(Buffer.from("b")), false);
});

test("every bp-graph.js the walk finds is byte-identical to the canonical", () => {
  const canonicalBytes = readFileSync(join(REPO, CANONICAL_REL));
  assert.ok(canonicalBytes.length > 0, "control: the canonical must not be empty");
  const drifted = walked
    .filter((p) => p !== CANONICAL_REL)
    .filter((p) => !readFileSync(join(REPO, p)).equals(canonicalBytes));
  assert.deepEqual(drifted, [],
    `these bp-graph.js copies are not byte-identical to ${CANONICAL_REL}: ${drifted.join(", ")}. ` +
    `Edit ONLY the canonical, then copy it verbatim to every mirror.`);
});
