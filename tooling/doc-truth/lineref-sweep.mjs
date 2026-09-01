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
// Seven arms. The gate must be provably able to RED, provably able to stay
// SILENT, provably able to tell known from novel, provably still reading files
// that plain `grep` goes blind on, and provably able to see a cited window that
// is one line TOO NARROW — plus the control proving that last arm reds on
// narrowness rather than on the mere presence of a range. An arm that cannot
// fire is the same defect this gate was built to catch.

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
    // A public def whose name CONTAINS AN UNDERSCORE, because that is what the
    // needle harvester actually picks up: a bare `build` matches no rule (not
    // snake_case, not CamelCase, not SCREAMING), so a probe anchored on it has
    // NO anchor and passes only if the filename stem leaks in as one. These arms
    // used to rest on exactly the leak this change removes.
    const m = text.match(/^\s{2}def ([a-z_][a-z0-9_]*_[a-z0-9_]+)\(/m);
    if (!m) continue;
    return { base: rel.split("/").pop(), symbol: m[1], beyond: lines.length + 10000 };
  }
  return null;
}

// Derive a CLIPPABLE RUN for arms (e)/(f): a maximal block of >= 3 consecutive
// lines sharing a substantial common prefix, bounded on BOTH sides by a
// non-sibling. Maximality is load-bearing — arm (f) cites the run whole and must
// come back silent, which is only true if nothing adjacent shares the prefix.
// Derived from the live corpus for the same reason as derivePlantTarget: a
// hardcoded run rots on the first reflow of the file that holds it.
// Returns {base, lo, hi} or null.
function deriveClipTarget() {
  const { present } = codeCommentCorpus();
  const pfx = (a, b) => { let i = 0; while (i < a.length && i < b.length && a[i] === b[i]) i++; return a.slice(0, i); };
  for (const rel of present) {
    if (rel.includes("/test/") || rel.includes("_test.")) continue;
    const base = rel.split("/").pop();
    let text;
    try { text = readFileSync(join(ROOT, rel), "utf8"); } catch { continue; }
    const lines = text.split("\n").map((l) => l.replace(/\s+$/, ""));
    let i = 0;
    while (i < lines.length) {
      if (lines[i].trim() === "") { i++; continue; }
      let j = i + 1, p = lines[i];
      while (j < lines.length && lines[j].trim() !== "" && pfx(p, lines[j]).trim().length >= 8) {
        p = pfx(p, lines[j]);
        j++;
      }
      const runLen = j - i;
      // `lo >= 11` is not cosmetic: the citation grammar only recognises line
      // numbers of 2-5 digits, so a run at lines 4-6 yields `foo.exs:5-6`, which
      // never classifies as a lineref at all and would fail arm (e) for a reason
      // that has nothing to do with narrowness.
      if (runLen >= 3 && p.trim().length >= 8 && i + 1 >= 11) {
        // Bounded above/below by a non-sibling? (j is already the first non-sibling.)
        const above = i > 0 ? lines[i - 1] : "";
        if (!above.startsWith(p)) return { base, lo: i + 1, hi: j };
      }
      i = Math.max(j, i + 1);
    }
  }
  return null;
}

// A basename with TWO tracked paths of clearly different lengths, plus a line
// only the LONGER one has, and a real token near that line to serve as an
// anchor. Derived from the live corpus so arms (h)/(i) test the tree rather
// than a fixture; returns null when no such pair exists, and the arms then
// declare themselves vacuous instead of passing silently.
function deriveAmbiguousTarget() {
  // THE ARM MUST BE ABLE TO BITE, WHICH CONSTRAINS THE PAIR HARD. The reverted
  // resolver takes the FIRST tracked path whose basename matches — so a pair
  // whose first match happens to be the right file proves nothing, and an arm
  // built on one passes under the mutation. (Measured: the first draft picked
  // api/config/dev.exs, which IS the first match, and both arms went green with
  // the fix reverted.) So: require that first-match order lands on a file where
  // the cited line is OUT OF RANGE, and that some OTHER candidate contains it.
  // Then the old resolver must report "exceeds file length" and the new one
  // must not.
  const { present } = codeCommentCorpus();
  const order = [];
  try {
    const out = execFileSync("git", ["ls-files"], { cwd: ROOT, maxBuffer: 64 * 1024 * 1024 }).toString();
    for (const l of out.split("\n")) if (l) order.push(l);
  } catch { return null; }

  const byBase = new Map();
  for (const rel of order) {
    const b = rel.split("/").pop();
    if (!byBase.has(b)) byBase.set(b, []);
    byBase.get(b).push(rel);
  }
  const inCorpus = new Set(present);

  for (const [base, paths] of byBase) {
    if (paths.length < 2) continue;
    const first = paths[0];                       // what the reverted resolver picks
    let firstLen = 0;
    try { firstLen = readFileSync(join(ROOT, first), "utf8").split("\n").length; } catch { continue; }
    for (const other of paths.slice(1)) {
      if (!inCorpus.has(other)) continue;         // arm (i) cites it; keep it a real code file
      let lines;
      try { lines = readFileSync(join(ROOT, other), "utf8").split("\n"); } catch { continue; }
      if (lines.length <= firstLen + 20) continue; // need a line the first match cannot have
      for (let i = firstLen + 10; i < lines.length; i++) {
        // SNAKE_CASE ONLY. linerefNeedles harvests quoted strings, dotted
        // symbols and snake_case idents; a bare lowercase word is not a needle,
        // so a probe anchored on one leaves NO anchor, verifyLineref exits
        // "unverifiable" before the range check, and the arm passes vacuously.
        const m = (lines[i] || "").match(/[a-z][a-z0-9]*_[a-z0-9_]{4,}/);
        if (!m) continue;
        // The needle must be a REAL anchor, not a word the citation itself
        // supplies. A needle that appears in either candidate path is
        // self-derived, verifyLineref discards it, and with no anchor left the
        // verdict is "unverifiable" — which is silence, so the arm passes even
        // with the fix reverted. That is how arm (h) shipped vacuous the first
        // time: its only anchor was the stem.
        const wordsInPaths = (first + " " + other).toLowerCase();
        if (wordsInPaths.includes(m[0].toLowerCase())) continue;
        if (base.toLowerCase().includes(m[0].toLowerCase())) continue;
        return {
          base,
          long: other, short: first,
          longLines: lines.length, shortLines: firstLen,
          line: i + 1, needle: m[0],
        };
      }
    }
  }
  return null;
}

// A file whose BASENAME contains an underscore — its stem is then harvested by
// the snake_case needle rule, which is the whole precondition for the
// false-positive class arm (g) pins. Returns {base, line} or null.
function deriveStemTarget() {
  const { present } = codeCommentCorpus();
  for (const rel of present) {
    if (!rel.endsWith(".ex") || rel.includes("/test/")) continue;
    const base = rel.split("/").pop();
    if (!/^[a-z][a-z0-9]*_[a-z0-9_]+\.ex$/.test(base)) continue;
    let text;
    try { text = readFileSync(join(ROOT, rel), "utf8"); } catch { continue; }
    const lines = text.split("\n");
    if (lines.length < 30) continue;
    // A line comfortably inside the file, and non-blank, so the citation is
    // unambiguously CORRECT in the only sense the sweep can check.
    for (let n = 20; n < Math.min(lines.length, 200); n++) {
      if ((lines[n - 1] || "").trim() !== "") return { base, line: n };
    }
  }
  return null;
}

// A citation written as a PARTIAL path — `plugins/indx/errors.ex:<line>` — names
// some directories but not the repo root. It is the shape arms (g) and (i) both
// miss: not a bare basename, not an explicit repo-relative path, and its
// DIRECTORY names get harvested as anchors that the cited code was never obliged
// to contain. Returns {rel, partial, dirs, stem, line} or null.
//
// THE ARM MUST BE ABLE TO BITE, so the derivation carries three constraints, and
// dropping any one of them makes it pass against the un-fixed verifier:
//   1. the partial suffix must resolve to EXACTLY ONE tracked file, or the
//      finding is about ambiguity (arm h's subject) rather than about anchors;
//   2. every directory segment must actually match the needle rules — a segment
//      too short or capitalised is never harvested, so nothing was ever demanded;
//   3. NO harvested word — directory segment or basename stem — may appear
//      within the ±3 window. If one does, the un-fixed verifier finds it, calls
//      the anchors self-derived and exits `unverifiable`, which is silence, and
//      the arm goes green on the very defect it exists to catch.
function derivePartialPathTarget() {
  const { present } = codeCommentCorpus();
  let tracked = [];
  try {
    const out = execFileSync("git", ["ls-files"], { cwd: ROOT, maxBuffer: 64 * 1024 * 1024 }).toString();
    tracked = out.split("\n").filter(Boolean);
  } catch { return null; }

  for (const rel of present) {
    if (!rel.endsWith(".ex") || rel.includes("/test/")) continue;
    const segs = rel.split("/");
    if (segs.length < 4) continue;
    const partial = segs.slice(-3).join("/");
    const dirs = segs.slice(-3, -1);
    const stem = segs[segs.length - 1].replace(/\.[A-Za-z0-9]+$/, "");
    // (2) both directories must be harvestable words
    if (!dirs.every((d) => /^[a-z][a-z0-9_]{2,}$/.test(d))) continue;
    // (1) the suffix must be unique across the whole tracked corpus
    const suffix = "/" + partial;
    let hits = 0;
    for (const p of tracked) if (p === rel || p.endsWith(suffix)) hits++;
    if (hits !== 1) continue;

    let lines;
    try { lines = readFileSync(join(ROOT, rel), "utf8").split("\n"); } catch { continue; }
    if (lines.length < 60) continue;
    const words = [...dirs, stem];
    for (let n = 20; n < Math.min(lines.length, 400); n++) {
      if ((lines[n - 1] || "").trim() === "") continue;
      // (3) the window must be clean of every harvested word
      const lo = Math.max(1, n - 3), hi = Math.min(lines.length, n + 3);
      let near = false;
      for (let i = lo; i <= hi && !near; i++) {
        if (words.some((w) => (lines[i - 1] || "").includes(w))) near = true;
      }
      if (near) continue;
      return { rel, partial, dirs, stem, line: n };
    }
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

    // (d) NUL-SAFE. A file containing a NUL byte is INVISIBLE to plain `grep`,
    //     which treats it as binary and stays silent — on the tree this was
    //     written against, `grep -c export apps/mobile/src/state/cache.ts`
    //     printed nothing while `git grep -c` found 17. This sweep reads via
    //     git ls-files + readFileSync and is immune, but that immunity is a
    //     property worth pinning: a future refactor to `grep -r` would go
    //     silently blind over exactly the files most likely to hide drift.
    if (plant) {
      writeFileSync(
        probeAbs,
        "defmodule LinerefSelftestProbe do\n" +
          "  @blob \"pre\\u0000post\"\n" +
          `  # \`${plant.symbol}\` is defined at (${plant.base}:${plant.beyond}).\n` +
          "  def noop, do: :ok\n" +
          "end\n",
      );
      const nul = linerefFindings([probeRel]);
      if (nul.length === 0) {
        fails.push(
          "(d) NUL-SAFE: a probe containing a NUL byte produced NO finding — the reader has gone " +
            "binary-blind (did the corpus or the file read switch to grep?)",
        );
      }
    }

    // (e)/(f) TOO-NARROW WINDOW. Arms (a)-(d) all pin citations that are stale in
    //     a way that ANNOUNCES itself — the cited line moved, or the reader went
    //     blind. This pair pins the variant that never announces itself: a cited
    //     window that is IN RANGE, NON-BLANK, and one line too narrow, so the
    //     lines it names say exactly what the claim says while the line it
    //     EXCLUDED refutes the claim. "In range and non-blank" is not "correct".
    //     (f) is the control that gives (e) its meaning: the same run cited WHOLE
    //     must stay silent, or (e) is just a detector that reds on ranges.
    const clip = deriveClipTarget();
    if (!clip) {
      fails.push("(e) SETUP: could not derive a clippable run from the corpus — arms (e)/(f) would be vacuous");
    } else {
      const exhaustive = "the file declares only these entries";
      // (e) BITES: cite the run's TAIL, clipping its first line, and claim totality.
      writeFileSync(
        probeAbs,
        "defmodule LinerefSelftestProbe do\n" +
          `  # ${exhaustive} (${clip.base}:${clip.lo + 1}-${clip.hi}).\n` +
          "  def noop, do: :ok\n" +
          "end\n",
      );
      const clipped = linerefFindings([probeRel]);
      if (!clipped.some((f) => /EXHAUSTIVE claim over a CLIPPED run/.test(f.evidence || ""))) {
        fails.push(
          `(e) TOO-NARROW: an exhaustive claim over ${clip.base}:${clip.lo + 1}-${clip.hi}, which clips the` +
            ` sibling at line ${clip.lo}, produced NO clipped-run finding — the gate cannot see a window` +
            " that is too narrow",
        );
      }
      // (f) CONTROL: the same run cited WHOLE must stay silent.
      writeFileSync(
        probeAbs,
        "defmodule LinerefSelftestProbe do\n" +
          `  # ${exhaustive} (${clip.base}:${clip.lo}-${clip.hi}).\n` +
          "  def noop, do: :ok\n" +
          "end\n",
      );
      const whole = linerefFindings([probeRel]);
      if (whole.some((f) => /EXHAUSTIVE claim over a CLIPPED run/.test(f.evidence || ""))) {
        fails.push(
          `(f) CONTROL: the SAME run cited whole (${clip.base}:${clip.lo}-${clip.hi}) also flagged as clipped` +
            " — the detector reds on ranges, not on narrowness, and arm (e) proves nothing",
        );
      }
    }

    // (g) A FILE DOES NOT NAME ITSELF. A citation of the bare form
    //     `<snake_case_file>.ex:<line>`, carrying no second symbol, leaves the
    //     filename STEM as the only harvestable token — and a file almost never
    //     writes its own name in its own body, so demanding that token near the
    //     cited line is a test the truth cannot pass. On the tree this arm was
    //     written against, that reddened main on a CORRECT citation
    //     (`mutate-warnings.test.ts:26` → `dedup_wall.ex:524`, which really is
    //     `severity: "warning"` inside `defp warning/1`). A gate that reds on
    //     correct citations gets switched off, and takes the never-worse
    //     baseline — the only real drift instrument here — with it.
    const stemT = deriveStemTarget();
    if (!stemT) {
      fails.push("(g) SETUP: no underscore-basenamed .ex in the corpus — the stem arm would be vacuous");
    } else {
      writeFileSync(
        probeAbs,
        "defmodule LinerefSelftestProbe do\n" +
          `  # The behaviour is described at (${stemT.base}:${stemT.line}).\n` +
          "  def noop, do: :ok\n" +
          "end\n",
      );
      const stemFindings = linerefFindings([probeRel]);
      if (stemFindings.length !== 0) {
        fails.push(
          `(g) STEM: a CORRECT citation naming only ${stemT.base}:${stemT.line} produced ` +
            `${stemFindings.length} finding(s) — the filename stem is being demanded as an anchor, ` +
            "so every bare `<file>:<line>` citation in the repo is a false positive: " +
            (stemFindings[0].evidence || ""),
        );
      }
    }

    // (h) AMBIGUOUS STEM — a citation whose basename matches TWO tracked files
    //     and whose line is valid in the SECOND must not be reported stale.
    //     Before path-honoring, resolution was first-match: the sweep validated
    //     the cited line against whichever file it happened to find first and
    //     reported a correct citation as rot. Measured on this tree, 33 of 36
    //     out-of-range findings were false positives of exactly this shape.
    //
    //     Chosen from the LIVE corpus, never planted: a basename with 2+ tracked
    //     paths of clearly different lengths, cited at a line only the longer one
    //     has. The arm is vacuous — and says so — if no such pair exists.
    const amb = deriveAmbiguousTarget();
    if (!amb) {
      fails.push("(h) SETUP: no ambiguous basename with a long/short pair — the arm would be vacuous");
    } else {
      writeFileSync(
        probeAbs,
        "defmodule LinerefSelftestProbe do\n" +
          `  # ${amb.needle} is described at ${amb.base}:${amb.line}.\n` +
          "  def noop, do: :ok\n" +
          "end\n",
      );
      const ambFindings = linerefFindings([probeRel]);
      if (ambFindings.length !== 0) {
        fails.push(
          `(h) AMBIGUOUS: a citation valid in ${amb.long} (${amb.longLines} lines) was reported ` +
            `stale because the resolver bound \`${amb.base}\` to ${amb.short} (${amb.shortLines} lines): ` +
            (ambFindings[0].evidence || ""),
        );
      }
    }

    // (i) EXPLICIT PATH — a citation that supplies a directory-qualified path
    //     whose BASENAME also exists elsewhere must bind to the path it names.
    //     This is the half arm (h) cannot cover: those citations are not
    //     ambiguous at all, so "report ambiguity" is the wrong verdict for them
    //     — the path already disambiguates. 10 of the 33 measured false
    //     positives were this shape, including
    //     `cloud/lib/barkpark_cloud/accounts.ex:2186` checked against
    //     api/lib/barkpark/accounts.ex (943 lines) and reported out of range.
    if (!amb) {
      fails.push("(i) SETUP: shares (h)'s corpus pair and it was unavailable");
    } else {
      writeFileSync(
        probeAbs,
        "defmodule LinerefSelftestProbe do\n" +
          `  # ${amb.needle} is described at ${amb.long}:${amb.line}.\n` +
          "  def noop, do: :ok\n" +
          "end\n",
      );
      const pathFindings = linerefFindings([probeRel]);
      if (pathFindings.length !== 0) {
        fails.push(
          `(i) EXPLICIT PATH: the citation named ${amb.long}:${amb.line} outright and was still ` +
            `resolved by basename to ${amb.short} — an explicit path must never fall back to ` +
            "basename matching: " + (pathFindings[0].evidence || ""),
        );
      }
    }

    // (j) PARTIAL PATH — the shape between (g) and (i). A citation like
    //     `plugins/indx/errors.ex:<line>` supplies directories but not the repo
    //     root, and the needle harvest chews those directories into anchors: the
    //     sweep then demands the words `plugins` / `indx` within ±3 of the cited
    //     line. No module is obliged to name its own directory in its own body,
    //     so the test cannot be passed by a correct citation, and the verdict is
    //     stale-on-correct.
    //
    //     MEASURED on main at 4d223c151a: 6 of the 8 NOVEL findings reddening
    //     doc-gates were this shape, with anchor sets of nothing but path
    //     segments — [github, errors, indx] and [provisioner, support]. Across
    //     the whole corpus 141 findings held no anchor that was not a path
    //     segment of their own citing line.
    const pp = derivePartialPathTarget();
    if (!pp) {
      fails.push("(j) SETUP: no uniquely-resolving partial path with an anchor-free window — the arm would be vacuous");
    } else {
      writeFileSync(
        probeAbs,
        "defmodule LinerefSelftestProbe do\n" +
          `  # The behaviour is described at (${pp.partial}:${pp.line}).\n` +
          "  def noop, do: :ok\n" +
          "end\n",
      );
      const partialFindings = linerefFindings([probeRel]);
      if (partialFindings.length !== 0) {
        fails.push(
          `(j) PARTIAL PATH: a CORRECT citation naming only ${pp.partial}:${pp.line} produced ` +
            `${partialFindings.length} finding(s) — the directory segments ` +
            `[${pp.dirs.join(", ")}] are being demanded as anchors, so every ` +
            "`<dir>/<file>:<line>` citation in the repo is a false positive: " +
            (partialFindings[0].evidence || ""),
        );
      }
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
  process.stdout.write("  ok: (d) still reads a NUL-containing file that plain grep goes blind on\n");
  process.stdout.write("  ok: (e) bites on an exhaustive claim over a window one line too narrow\n");
  process.stdout.write("  ok: (f) silent on the SAME run cited whole — (e) reds on narrowness, not on ranges\n");
  process.stdout.write("  ok: (g) silent on a CORRECT bare `<file>:<line>` — the filename stem is not an anchor\n");
  process.stdout.write("  ok: (h) silent on an AMBIGUOUS stem whose line is valid in another candidate\n");
  process.stdout.write("  ok: (i) an EXPLICIT path binds to the file it names, never to a basename twin\n");
  process.stdout.write("  ok: (j) silent on a CORRECT PARTIAL path — directory segments are not anchors\n");
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
