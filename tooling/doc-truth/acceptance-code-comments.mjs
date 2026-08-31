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
import {
  runVerify,
  verifyDocText,
  setLinerefTargetOverride,
  clearLinerefTargetOverrides,
} from "./verify-docs.mjs";
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

  // ── (a) FAIL-BEFORE: verify-docs lineref/path defects (FROZEN snapshots) ────
  // Verify each FIXED defect against a committed frozen WINDOW of its citing
  // file's pre-fix content (fixtures/frozen/, ±context around the defect), NOT
  // the live file — so the proof holds after the fix slices corrected the source.
  // The original path is passed as resolution context only (basename/sibling
  // lookup); ground-truth targets (router.ex, the sibling types.ts, the absent
  // path) resolve LIVE, which is what makes the frozen citation surface. One
  // defect per frozen window, so type+status identifies it (windows shift lines).
  const frozen = corpus.frozen || {};
  let vdHit = 0;
  for (const e of vd) {
    const type = e.expect === "false" ? "path" : "lineref";
    const wantStatus = e.expect === "false" ? "false" : "stale";
    const snap = frozen[e.file];
    if (!snap) { fails.push(`(a) verify-docs NO SNAPSHOT — ${e.file}`); continue; }
    const content = readFileSync(join(HERE, "fixtures/frozen", snap), "utf8");
    // A specimen may pin its cited TARGET to a frozen snapshot too
    // (`target_snapshot` in the corpus) — the fail-before proof then never
    // depends on the LIVE target's absolute line layout, so innocent edits
    // to that file can't false-confirm the frozen citation. Cleared right
    // after: pass-after and the live legs always run against the real tree.
    if (e.target_snapshot) {
      setLinerefTargetOverride(
        e.target_snapshot.rel,
        join(HERE, "fixtures/frozen", e.target_snapshot.snap),
      );
    }
    const rep = verifyDocText(e.file, content);
    clearLinerefTargetOverrides();
    const caught = rep.findings.some((f) => f.type === type && f.status === wantStatus);
    if (caught) vdHit++;
    else fails.push(`(a) verify-docs MISS (frozen) — ${e.file}:${e.line} (${type}) ${e.cite}`);
  }
  notes.push(`(a) verify-docs fail-before (frozen snapshots): ${vdHit}/${vd.length}`);

  // ── (a″) PASS-AFTER: the fixed defects no longer surface on the LIVE tree ────
  // The other half of the regression proof: the corrected source must be clean.
  // Reads the live citing file (fixed) and requires the defect to be GONE at its
  // original line — closes the loop so neither the fix nor the guard can rot.
  let paHit = 0;
  for (const e of vd) {
    const type = e.expect === "false" ? "path" : "lineref";
    const wantStatus = e.expect === "false" ? "false" : "stale";
    const rep = verifyDocText(e.file, readFileSync(join(ROOT, e.file), "utf8"));
    const gone = !rep.findings.some((f) => f.type === type && f.status === wantStatus && f.line === e.line);
    if (gone) paHit++;
    else fails.push(`(a″) PASS-AFTER regression — ${e.file}:${e.line} still surfaces (${type}) on the live tree`);
  }
  notes.push(`(a″) verify-docs pass-after (fixed defects gone from live): ${paHit}/${vd.length}`);

  // ── (a) FAIL-BEFORE: retired-terms dead-tech defects (FROZEN specimens) ─────
  // Scan each defect's frozen `cite` text directly (scanText is text-in), so
  // the proof holds after the purge slices strip the term from the live tree.
  let dtHit = 0;
  for (const e of corpus.deadTerms) {
    const found = scanText(e.cite, e.file);
    if (found.some((f) => f.term === e.term)) dtHit++;
    else fails.push(`(a) retired-terms MISS (frozen) — ${e.file}:${e.line} ${e.term}`);
  }
  notes.push(`(a) retired-terms fail-before (frozen specimens): ${dtHit}/${corpus.deadTerms.length}`);

  // ── (a') NEVER-WORSE (live tree): the corrected tree introduces no dead-tech ─
  // The complement of fail-before: the standing denylist over the REAL tree must
  // be clean now that the purge slices landed. This is the regression teeth — a
  // future re-introduction of live-Cytoscape prose fails here.
  const liveTerm = scanCorpus();
  if (liveTerm.length !== 0) {
    fails.push(`(a') retired-terms live never-worse breach: ${liveTerm.length} dead-tech occurrence(s) remain on the corrected tree`);
    for (const f of liveTerm.slice(0, 12)) fails.push(`      ↳ ${f.file}:${f.line} ${f.term} [${f.kind}] ${f.evidence}`);
  }
  notes.push(`(a') retired-terms live never-worse: ${liveTerm.length} occurrence(s) on the corrected tree`);

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
  const cc = corpus._meta.counts;
  process.stdout.write(`corpus: ${cc.total_fixed} FIXED defects frozen` +
    ` (${cc.fixed_linerefs} linerefs · ${cc.fixed_paths} paths · ${cc.deadTerms} dead-terms)` +
    ` · ${cc.liveLeads} live leads tracked as follow-up\n\n`);
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
