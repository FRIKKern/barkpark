#!/usr/bin/env node
// lineref-sweep.mjs — the standing REPO-WIDE gate on drifted code-comment
// linerefs. Sibling of retired-terms.mjs, and deliberately built to the same
// shape: git ls-files corpus → scan → diff against a frozen baseline → exit 1
// on any NOVEL finding.
//
// WHY THIS EXISTS. The verifier and the corpus were already here:
// `verify-docs.mjs --code` sweeps every tracked .ex/.exs/.go/.ts and writes
// citation-truth-report.json. But it ends `process.exit(0)` — "exit 0 always
// for the report verb — callers branch on the JSON, not status" — and NOTHING
// in CI called it. The only lineref checking that ran was inside
// acceptance-code-comments.mjs, which points runVerify at the frozen 29-defect
// corpus, one control file and one planted temp file. That proves the CHECKER
// still works; it never asks whether the TREE has new drift. On the tree this
// gate was written against, the answer was 547 high-confidence stale linerefs,
// every one of them green.
//
// NEVER-WORSE, NOT CLEAN-TREE. With 547 outstanding, a zero-findings gate reds
// main on day one and gets disabled — which is worse than no gate, because a
// disabled gate still looks like coverage. So the baseline freezes today's set
// and only a NOVEL citation fails.
//
// THE BASELINE KEY DELIBERATELY OMITS THE CITING LINE NUMBER. Key is
// `<file>|<raw citation text>`, not `<file>|<line>|<raw>`. A line-keyed
// baseline re-keys every entry whenever anything is inserted above a comment,
// so an unrelated edit floods the gate with phantom "novel" findings and the
// gate gets disabled — the precise failure this whole lane documented. Keying
// on WHAT is cited rather than WHERE the citation sits means the entry moves
// with the comment and changes only when the citation itself changes, which is
// exactly when a human should look again.
//
// Dependency-free. ESM, node: builtins only.

import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync, mkdtempSync, rmSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { runVerify, codeCommentCorpus } from "./verify-docs.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: HERE })
  .toString()
  .trim();
const BASELINE = join(HERE, "fixtures/lineref-baseline.json");

// A finding's identity for baseline purposes. See the header: no line number.
export function linerefKey(f) {
  return `${f.doc}|${f.raw}`;
}

// Every high-confidence lineref finding over an explicit doc list.
export function linerefFindings(docs) {
  const rep = runVerify(docs);
  const out = [];
  for (const d of rep.docs) {
    for (const f of d.findings) if (f.type === "lineref") out.push(f);
  }
  return out;
}

// The standing sweep: the whole tracked code corpus.
export function sweep() {
  const { present } = codeCommentCorpus();
  return { scanned: present.length, findings: linerefFindings(present) };
}

function baselineKeys() {
  if (!existsSync(BASELINE)) return { keys: new Set(), generatedAt: null };
  try {
    const b = JSON.parse(readFileSync(BASELINE, "utf8"));
    return { keys: new Set(b.entries.map((e) => `${e.doc}|${e.raw}`)), generatedAt: b.generatedAt };
  } catch {
    return { keys: new Set(), generatedAt: null };
  }
}

function partition(findings) {
  const { keys, generatedAt } = baselineKeys();
  const known = [], novel = [];
  for (const f of findings) (keys.has(linerefKey(f)) ? known : novel).push(f);
  return { known, novel, baselineSize: keys.size, generatedAt };
}

function writeBaseline(findings) {
  // Deduped by key, sorted, so the file is stable across runs and reviewable.
  const seen = new Map();
  for (const f of findings) if (!seen.has(linerefKey(f))) seen.set(linerefKey(f), { doc: f.doc, raw: f.raw });
  const entries = [...seen.values()].sort((a, b) => (a.doc + a.raw).localeCompare(b.doc + b.raw));
  const body = {
    generatedAt: new Date().toISOString(),
    note:
      "Frozen pre-existing stale linerefs. Keyed <doc>|<raw> — NO line number, so an " +
      "insertion above a comment does not re-key its entry. Shrinking this file is always " +
      "welcome; growing it requires a human deciding the new citation is acceptable.",
    entries,
  };
  writeFileSync(BASELINE, JSON.stringify(body, null, 2) + "\n");
  return entries.length;
}

// ── selftest ─────────────────────────────────────────────────────────────────
// Three arms. The gate must be provably able to RED, provably able to stay
// SILENT, and provably able to tell known from novel — an arm that cannot fire
// is the same defect this gate was built to catch.
// Derive the plant's target from the live corpus rather than hardcoding one.
// A hardcoded `media.ex:99999` rots the day that file is renamed, and a
// selftest whose target has vanished goes quietly vacuous — the exact failure
// this gate exists to catch. Returns {base, symbol, beyond} or null.
function derivePlantTarget() {
  const { present } = codeCommentCorpus();
  for (const rel of present) {
    if (!rel.endsWith(".ex") || rel.includes("/test/")) continue;
    let text;
    try { text = readFileSync(join(ROOT, rel), "utf8"); } catch { continue; }
    const lines = text.split("\n");
    // A public 0-arity-ish def gives a token the verifier will treat as an anchor.
    const m = text.match(/^\s{2}def ([a-z_][a-z0-9_]*)\(/m);
    if (!m) continue;
    return { base: rel.split("/").pop(), symbol: m[1], beyond: lines.length + 10000 };
  }
  return null;
}

function selftest() {
  const fails = [];
  const dir = mkdtempSync(join(tmpdir(), "lineref-selftest-"));
  // The verifier resolves docs relative to ROOT, so the probe must live inside
  // the repo. It is removed in the finally block and is never committed.
  const probeAbs = join(ROOT, `__lineref_selftest_probe_${process.pid}.ex`);
  const probeRel = relative(ROOT, probeAbs);
  const plant = derivePlantTarget();
  try {
    if (!plant) {
      // Refuse rather than pass: no target means the arms below prove nothing.
      fails.push("(0) SETUP: could not derive a plant target from the corpus — the selftest would be vacuous");
    } else {
      // (a) BITES: a citation past the end of a real file, carrying a real
      //     symbol as its anchor, is unambiguously stale.
      writeFileSync(
        probeAbs,
        "defmodule LinerefSelftestProbe do\n" +
          `  # \`${plant.symbol}\` is defined at (${plant.base}:${plant.beyond}).\n` +
          "  def noop, do: :ok\n" +
          "end\n",
      );
      const red = linerefFindings([probeRel]);
      if (red.length === 0) {
        fails.push(
          `(a) BITES: planted stale lineref (${plant.base}:${plant.beyond} anchored on \`${plant.symbol}\`)` +
            " produced NO finding — the gate cannot red",
        );
      } else if (!red.some((f) => f.doc === probeRel)) {
        fails.push(`(a) BITES: finding did not name the probe file (${probeRel})`);
      }

      // (b) SILENT: the same comment WITHOUT a line citation must stay quiet.
      writeFileSync(
        probeAbs,
        "defmodule LinerefSelftestProbe do\n" +
          `  # \`${plant.symbol}\` is defined in ${plant.base}, somewhere near the top.\n` +
          "  def noop, do: :ok\n" +
          "end\n",
      );
      const green = linerefFindings([probeRel]);
      if (green.length !== 0) {
        fails.push(`(b) SILENT: clean probe produced ${green.length} finding(s) — the gate cries wolf`);
      }
    }

    // (c) KNOWN vs NOVEL: a finding whose key is in the baseline is not novel,
    //     and the same finding with a changed citation IS.
    const fake = { doc: "fixtures/x.ex", raw: "y.ex:1 something", type: "lineref" };
    const inBaseline = new Set([linerefKey(fake)]);
    if (!inBaseline.has(linerefKey({ ...fake, line: 999 }))) {
      fails.push("(c) KEY: changing only the LINE of a finding changed its baseline key — the key is not drift-stable");
    }
    if (inBaseline.has(linerefKey({ ...fake, raw: "y.ex:2 something" }))) {
      fails.push("(c) KEY: changing the CITATION did not change the key — a re-pointed citation would ride the baseline");
    }
  } finally {
    rmSync(probeAbs, { force: true });
    rmSync(dir, { recursive: true, force: true });
  }

  const bar = "─".repeat(74);
  process.stdout.write(`\nlineref-sweep --selftest\n${bar}\n`);
  if (fails.length) {
    for (const f of fails) process.stdout.write(`  ✗ ${f}\n`);
    process.stdout.write(`${bar}\nSELFTEST FAILED (${fails.length})\n`);
    process.exit(1);
  }
  process.stdout.write("  ok: (a) bites on a planted stale lineref\n");
  process.stdout.write("  ok: (b) silent on a clean probe\n");
  process.stdout.write("  ok: (c) baseline key is line-insensitive and citation-sensitive\n");
  process.stdout.write(`${bar}\nSELFTEST PASSED\n`);
  process.exit(0);
}

function main() {
  const argv = process.argv.slice(2);
  if (argv.includes("--selftest")) return selftest();

  const { scanned, findings } = sweep();

  if (argv.includes("--write-baseline")) {
    const n = writeBaseline(findings);
    process.stdout.write(`lineref baseline written: ${n} entrie(s) from ${scanned} scanned file(s)\n`);
    process.exit(0);
  }

  const { known, novel, baselineSize, generatedAt } = partition(findings);

  if (argv.includes("--json")) {
    process.stdout.write(JSON.stringify({ scanned, known, novel, baselineSize }, null, 2) + "\n");
  } else {
    const bar = "─".repeat(74);
    process.stdout.write(`\nlineref-sweep — repo-wide code-comment lineref drift\n${bar}\n`);
    // The count is stated OUT LOUD so a zero-novel pass is legibly a fact about
    // the repo and not a fact about the scanner finding nothing to scan.
    process.stdout.write(
      `scanned ${scanned} tracked code file(s) · ${findings.length} stale lineref(s)` +
        ` (${known.length} known/baseline · ${novel.length} novel)\n` +
        `baseline: ${baselineSize} frozen entrie(s)${generatedAt ? ` from ${generatedAt}` : " — NONE FOUND"}\n`,
    );
    for (const f of novel) {
      process.stdout.write(`  ✗ NOVEL ${f.doc}:${f.line}\n      cites: ${f.raw}\n      ${f.evidence}\n`);
    }
    if (novel.length) {
      process.stdout.write(
        `\n  A NOVEL stale lineref means a comment cites a file:line that no longer holds\n` +
          `  what the comment says. Re-point it — and prefer a SYMBOL over a line number\n` +
          `  (\`media.ex:MediaFile.changeset/2\`, not \`media.ex:110\`), because line anchors\n` +
          `  are what rot. If the citation is genuinely acceptable, a human adds it via\n` +
          `  --write-baseline in the same PR, on the record.\n`,
      );
    }
    process.stdout.write(`${bar}\n`);
  }
  process.exit(novel.length ? 1 : 0);
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  main();
}
