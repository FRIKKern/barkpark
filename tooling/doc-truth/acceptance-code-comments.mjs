#!/usr/bin/env node
// acceptance-code-comments.mjs — acceptance for the CODE-COMMENT citation guard.
//
// Sibling of acceptance.mjs (which guards the markdown lane). Four checks, all
// hard gates — exit non-zero on any failure:
//
//   (a) FAIL-BEFORE — every one of the 29 frozen citation-truth defects
//       (fixtures/citation-corpus-2026-07.json) surfaces as a high-confidence
//       finding from its named guard on the pre-fix tree, AND retired-terms emits
//       nothing NOVEL beyond that frozen baseline (never-worse).
//   (b) NEVER CRY WOLF — the clean control file (fixtures/control-clean.ex) and
//       the two canonical "historical mention" files (graph_view.ex,
//       root.html.heex) emit ZERO findings.
//   (c) CATCHES A PLANT — a planted live `# uses Cytoscape to render` assertion
//       and a planted stale lineref are both caught.
//   (d) NEVER-WORSE ELSEWHERE — the existing acceptance.mjs (markdown /
//       js-tests.yml gate) still passes.
//
// Dependency-free. ESM, node: builtins only.

import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { runVerify } from "./verify-docs.mjs";
import { scanText, scanCorpus } from "./retired-terms.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: HERE })
  .toString()
  .trim();
const CORPUS = join(HERE, "fixtures/citation-corpus-2026-07.json");
const CONTROL = "tooling/doc-truth/fixtures/control-clean.ex";

const fails = [];
const notes = [];

// high-confidence findings from runVerify, keyed "doc:line:type".
function highKeys(docList) {
  const rep = runVerify(docList);
  const set = new Set();
  for (const d of rep.docs) for (const f of d.findings) set.add(`${f.doc}:${f.line}:${f.type}`);
  return { set, rep };
}

function main() {
  const corpus = JSON.parse(readFileSync(CORPUS, "utf8"));
  const vd = [...corpus.linerefs, ...corpus.paths];

  // ── (a) FAIL-BEFORE: verify-docs lineref/path defects ──────────────────────
  const vdFiles = [...new Set(vd.map((e) => e.file))];
  const { set: high } = highKeys(vdFiles);
  let vdHit = 0;
  for (const e of vd) {
    const type = e.expect === "false" ? "path" : "lineref";
    if (high.has(`${e.file}:${e.line}:${type}`)) vdHit++;
    else fails.push(`(a) verify-docs MISS — ${e.file}:${e.line} (${type}) ${e.cite}`);
  }
  notes.push(`(a) verify-docs fail-before: ${vdHit}/${vd.length}`);

  // ── (a) FAIL-BEFORE: retired-terms dead-tech defects + never-worse ─────────
  const termFindings = scanCorpus();
  const termSet = new Set(termFindings.map((f) => `${f.file}:${f.line}:${f.term}`));
  const baseKeys = new Set(corpus.deadTerms.map((e) => `${e.file}:${e.line}:${e.term}`));
  let dtHit = 0;
  for (const e of corpus.deadTerms) {
    if (termSet.has(`${e.file}:${e.line}:${e.term}`)) dtHit++;
    else fails.push(`(a) retired-terms MISS — ${e.file}:${e.line} ${e.term}`);
  }
  for (const f of termFindings) {
    if (!baseKeys.has(`${f.file}:${f.line}:${f.term}`)) {
      fails.push(`(a) retired-terms NOVEL (never-worse breach) — ${f.file}:${f.line} ${f.term}`);
    }
  }
  notes.push(`(a) retired-terms fail-before: ${dtHit}/${corpus.deadTerms.length}` +
    ` · novel beyond baseline: ${termFindings.length - baseKeys.size >= 0 ? termFindings.length - dtHit : 0}`);

  // ── (b) NEVER CRY WOLF: clean control emits zero ───────────────────────────
  const { rep: crep } = highKeys([CONTROL]);
  const cHigh = crep.docs.reduce((a, d) => a + d.findings.length, 0);
  if (cHigh !== 0) {
    fails.push(`(b) control emitted ${cHigh} verify-docs false-positive(s)`);
    for (const d of crep.docs) for (const f of d.findings) fails.push(`      ↳ ${f.doc}:${f.line} ${f.type} ${f.raw}`);
  }
  // retired-terms on the control — pass a NON-allowlisted rel so the negation
  // logic actually runs (fixtures/ is allowlisted and would trivially pass).
  const controlText = readFileSync(join(ROOT, CONTROL), "utf8");
  const cTerm = scanText(controlText, "acceptance/control-clean.ex");
  if (cTerm.length !== 0) fails.push(`(b) control retired-terms emitted ${cTerm.length} false-positive(s)`);

  // the two canonical "historical mention" files MUST pass retired-terms
  for (const rel of [
    "api/lib/barkpark_web/live/studio/graph_view.ex",
    "api/lib/barkpark_web/layouts/root.html.heex",
  ]) {
    const t = readFileSync(join(ROOT, rel), "utf8");
    const f = scanText(t, rel);
    if (f.length !== 0) {
      fails.push(`(b) ${rel} should PASS (negated/historical) but flagged ${f.length}`);
      for (const x of f) fails.push(`      ↳ L${x.line} [${x.kind}] ${x.evidence}`);
    }
  }
  notes.push(`(b) control zero-FP + graph_view/root.heex historical mentions pass`);

  // ── (c) CATCHES A PLANT ────────────────────────────────────────────────────
  const plantedLive = scanText(
    "# The blast-radius pane uses Cytoscape to render the node graph.",
    "acceptance/planted.ex");
  if (!plantedLive.some((f) => f.kind === "live-tech")) {
    fails.push("(c) planted live-Cytoscape assertion NOT caught by retired-terms");
  }
  const tmpRel = "tooling/doc-truth/fixtures/.planted-tmp.ex";
  const tmpAbs = join(ROOT, tmpRel);
  writeFileSync(tmpAbs, [
    "defmodule DocTruth.Planted do",
    "  @moduledoc \"\"\"",
    "  The verifier entry point sits at `verify-docs.mjs:99999` — see \"runVerify\".",
    "  \"\"\"",
    "  def noop, do: :ok",
    "end",
    "",
  ].join("\n"));
  try {
    const { rep: prep } = highKeys([tmpRel]);
    const caught = prep.docs.some((d) =>
      d.findings.some((f) => f.type === "lineref" && f.status === "stale"));
    if (!caught) fails.push("(c) planted stale lineref NOT caught by verify-docs");
  } finally {
    rmSync(tmpAbs, { force: true });
  }
  notes.push("(c) planted live-tech assertion + planted stale lineref both caught");

  // ── (d) NEVER-WORSE ELSEWHERE: markdown acceptance still green ─────────────
  try {
    execFileSync("node", [join(HERE, "acceptance.mjs")], { stdio: "ignore" });
    notes.push("(d) acceptance.mjs (markdown / js-tests.yml gate) PASS");
  } catch {
    fails.push("(d) acceptance.mjs FAILED — markdown lane regressed");
  }

  // ── report ─────────────────────────────────────────────────────────────────
  const bar = "═".repeat(74);
  process.stdout.write(`\n${bar}\nCODE-COMMENT CITATION GUARD — ACCEPTANCE\n${bar}\n`);
  process.stdout.write(`corpus: ${corpus._meta.counts.total} frozen defects` +
    ` (${corpus._meta.counts.linerefs} linerefs · ${corpus._meta.counts.paths} paths · ${corpus._meta.counts.deadTerms} dead-terms)\n\n`);
  for (const n of notes) process.stdout.write(`  ✓ ${n}\n`);
  if (fails.length) {
    process.stdout.write(`\n  FAILURES (${fails.length}):\n`);
    for (const f of fails) process.stdout.write(`  ✗ ${f}\n`);
  }
  process.stdout.write(`\n${bar}\n`);
  process.stdout.write(fails.length ? `RESULT: FAIL ✗ (${fails.length})\n` : `RESULT: PASS ✓\n`);
  process.stdout.write(`${bar}\n`);
  process.exit(fails.length ? 1 : 0);
}

main();
