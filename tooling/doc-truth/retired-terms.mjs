#!/usr/bin/env node
// retired-terms.mjs — a CONTEXT-AWARE denylist for terms that name a dead
// dependency as if it were live tech.
//
// This is the semantic complement of verify-docs.mjs. verify-docs catches
// drifted CITATIONS (such as a lineref whose line number moved).
// retired-terms catches drifted CLAIMS — prose that
// still asserts a gutted technology is current:
//
//   • `cytoscape` — the graph pane is a self-contained Canvas2D renderer now;
//     Cytoscape was fully gutted. A comment that says the renderer USES it is
//     wrong.
// It is emphatically NOT a blind grep. A retired term is ALLOWED when it sits:
//   1. within NEG_WINDOW chars of a negation / historical framing word
//      (gutted, removed, retired, legacy, NOT, historically, no longer …),
//   2. on a line carrying an inline `doc-truth-allow` pragma, or
//   3. under an allowlisted path (test/, CHANGELOG, git-history docs, the
//      charter, this tool's own source + fixtures).
// So `Canvas2D, NOT Cytoscape`, `Cytoscape is fully gutted`, and `Historically
// Cytoscape owned layout` all PASS, while a planted live-use claim FLAGS.
//
//   node tooling/doc-truth/retired-terms.mjs [--json]
//
// Exit status is NEVER-WORSE against fixtures/citation-corpus-2026-07.json: the
// frozen pre-fix defects are the known backlog (exit 0), but any NOVEL live /
// dead-tech assertion fails the gate (exit 1). Dependency-free; node: builtins.

import { execFileSync } from "node:child_process";
import { readFileSync, existsSync } from "node:fs";
import { dirname, join, extname } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: HERE })
  .toString()
  .trim();
const CORPUS_FIXTURE = join(HERE, "fixtures/citation-corpus-2026-07.json");

// Windows (chars) around an occurrence.
const NEG_WINDOW = 170; // how far a negation/historical word may sit and still excuse
const BIND = 24; // adjacency window for a live-use verb binding to the term

// Broad historical / negation / contract framing — excuses a cytoscape mention.
const NEG_BROAD =
  /\b(gutt\w*|remov\w*|retir\w*|deprecat\w*|legacy|historical\w*|formerly|former|obsolet\w*|no longer|never|without|zero|dead|sunset|stub|not\b|no\b|used to|was\b|were\b|mirror\w*|byte-identical|compatible|backs?\b|back(s|ed|ing)?\s+the|replac\w*|translat\w*|cannot|superseded)\b/i;

// A live-use verb binding DIRECTLY to the term (adjacent), either side.
const LIVE_BEFORE =
  /\b(uses?|using|loads?|loading|imports?|importing|requires?|render(?:s|ed|ing)?\s+(?:with|via|using|by)|powered\s+by|depends?\s+on|built\s+on|runs?\s+on|driven\s+by|calls?\s+into)\s+(?:the\s+|our\s+|a\s+)?$/i;
const LIVE_AFTER =
  /^[\s,()'"`.:-]*(renders?|rendering|is\s+used|is\s+loaded|is\s+the\s+renderer|is\s+our\s+renderer|powers?|drives?|handles?\s+(?:the\s+)?render|lays?\s+out)\b/i;

// ── denylisted terms ─────────────────────────────────────────────────────────
const TERMS = [
  {
    id: "cytoscape",
    re: /cytoscape/gi,
    // a bare `cytoscape.min.js` filename token is fine to name when negated; the
    // denylist targets the CLAIM, not the string.
    excuse: NEG_BROAD,
    classify(before, after) {
      if (LIVE_BEFORE.test(before) || LIVE_AFTER.test(after)) {
        return { kind: "live-tech", confidence: "high" };
      }
      return { kind: "stale-tech-ref", confidence: "medium" };
    },
  },
];

// Paths where a retired term is documentary by nature and must never flag.
function pathAllowed(rel) {
  return (
    /(^|\/)test(s)?\//.test(rel) ||
    /_test\.(exs?|go)$|\.test\.[jt]sx?$/.test(rel) ||
    /(^|\/)CHANGELOG/i.test(rel) ||
    rel.startsWith(".claude/") ||
    rel.includes("tooling/doc-truth/") || // the guard's own source + fixtures
    /(^|\/)(history|retired|cold|archive)/i.test(rel) ||
    rel.startsWith("docs/decisions/")
  );
}

// Line number (1-based) for a char offset.
function lineOf(offsets, idx) {
  // offsets[i] = char offset of line i (0-based line). binary search.
  let lo = 0, hi = offsets.length - 1, ans = 0;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    if (offsets[mid] <= idx) { ans = mid; lo = mid + 1; }
    else hi = mid - 1;
  }
  return ans + 1;
}

// Scan one file's text. Returns [{file?, line, term, kind, confidence, evidence}].
// `file` is stamped by the caller.
export function scanText(text, rel) {
  const out = [];
  if (rel && pathAllowed(rel)) return out;
  // line-start offsets for lineOf + pragma lookup
  const offsets = [0];
  for (let i = 0; i < text.length; i++) if (text[i] === "\n") offsets.push(i + 1);
  const lineText = (ln) => {
    const s = offsets[ln - 1] ?? 0;
    const e = offsets[ln] ?? text.length;
    return text.slice(s, e);
  };
  for (const term of TERMS) {
    term.re.lastIndex = 0;
    let m;
    while ((m = term.re.exec(text))) {
      const idx = m.index;
      const len = m[0].length;
      const ln = lineOf(offsets, idx);
      if (/doc-truth-allow/.test(lineText(ln))) continue;
      const win = text.slice(Math.max(0, idx - NEG_WINDOW), idx + len + NEG_WINDOW);
      if (term.excuse.test(win)) continue;
      const before = text.slice(Math.max(0, idx - BIND), idx);
      const after = text.slice(idx + len, idx + len + BIND);
      const c = term.classify(before, after);
      const snippet = lineText(ln).trim().slice(0, 90);
      out.push({
        line: ln,
        term: term.id,
        kind: c.kind,
        confidence: c.confidence,
        evidence: snippet,
      });
    }
  }
  return out;
}

// ── corpus ───────────────────────────────────────────────────────────────────
const TERM_EXTS = new Set([".ex", ".exs", ".go", ".ts", ".tsx", ".heex", ".eex"]);
const TERM_EXCLUDE = ["node_modules/", "_build/", "deps/", "vendor/", "priv/static/", ".git/"];
export function termCorpus() {
  let lines;
  try {
    lines = execFileSync("git", ["ls-files"], { cwd: ROOT, maxBuffer: 1 << 27 })
      .toString()
      .split("\n");
  } catch {
    return [];
  }
  const present = [];
  for (const raw of lines) {
    const d = raw.trim();
    if (!d) continue;
    if (!TERM_EXTS.has(extname(d))) continue;
    if (TERM_EXCLUDE.some((p) => d.startsWith(p) || d.includes("/" + p))) continue;
    if (existsSync(join(ROOT, d))) present.push(d);
  }
  return present;
}

export function scanCorpus() {
  const out = [];
  for (const rel of termCorpus()) {
    let text;
    try { text = readFileSync(join(ROOT, rel), "utf8"); } catch { continue; }
    for (const f of scanText(text, rel)) out.push({ file: rel, ...f });
  }
  return out;
}

// Known pre-fix defects — the frozen backlog. A finding matching one of these is
// EXPECTED (exit 0); anything else is a regression (exit 1).
function baselineKeys() {
  const set = new Set();
  if (!existsSync(CORPUS_FIXTURE)) return set;
  try {
    const c = JSON.parse(readFileSync(CORPUS_FIXTURE, "utf8"));
    for (const e of c.deadTerms || []) set.add(`${e.file}|${e.line}|${e.term}`);
  } catch { /* empty baseline */ }
  return set;
}

function main() {
  const argv = process.argv.slice(2);
  const wantJson = argv.includes("--json");
  const findings = scanCorpus();
  const baseline = baselineKeys();
  const known = [], novel = [];
  for (const f of findings) {
    (baseline.has(`${f.file}|${f.line}|${f.term}`) ? known : novel).push(f);
  }

  if (wantJson) {
    process.stdout.write(JSON.stringify({ findings, known, novel }, null, 2) + "\n");
  } else {
    const bar = "─".repeat(74);
    process.stdout.write(`\nretired-terms — context-aware dead-tech denylist\n${bar}\n`);
    process.stdout.write(
      `scanned ${termCorpus().length} code/heex files · ${findings.length} finding(s)` +
      ` (${known.length} known/baseline · ${novel.length} novel)\n`);
    for (const f of novel) {
      process.stdout.write(`  ✗ NOVEL ${f.file}:${f.line} [${f.kind}/${f.confidence}] ${f.term}\n      ${f.evidence}\n`);
    }
    if (known.length) {
      process.stdout.write(`\n  known pre-fix backlog (frozen in citation-corpus-2026-07.json):\n`);
      for (const f of known.slice(0, 40)) {
        process.stdout.write(`    · ${f.file}:${f.line} [${f.kind}] ${f.term}\n`);
      }
    }
    process.stdout.write(`${bar}\n`);
    process.stdout.write(
      novel.length
        ? `GATE: FAIL ✗ — ${novel.length} novel dead-tech assertion(s); fix or add a doc-truth-allow pragma\n`
        : `GATE: PASS ✓ — no novel dead-tech assertions\n`);
    process.stdout.write(`${bar}\n`);
  }
  process.exit(novel.length ? 1 : 0);
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  main();
}
