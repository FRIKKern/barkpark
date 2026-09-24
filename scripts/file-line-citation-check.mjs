#!/usr/bin/env node
//
// FILE:LINE CITATION CHECK — a `<file>:<N>` citation must still point AT the
// thing it names.
//
// SIBLING, NOT DUPLICATE. `scripts/charter-citation-check.sh` already guards a
// different citation class: `charter D<n>` -> a decision heading in the charter
// FILE. It has no notion of a source line. This script guards the OTHER class a
// charter writes: `app.js:3969`-shaped pointers into a real source file. The two
// share a word and nothing else; neither subsumes the other.
//
// ── THE DEFECT ────────────────────────────────────────────────────────────────
//
// A charter is prose; the file it cites is edited by every merge. Nothing binds
// them, so every insertion above line N silently walks N off its subject. The
// charter keeps the old number and keeps being read. Measured on origin/main at
// this branch point (see --report): a clear majority of the console charter's
// machine-decidable `app.js:N` citations no longer land near any identifier the
// citing line names. The worst measured case drifts by more than two thousand
// lines, pointing a builder at an unrelated handler.
//
// ── THE TEST, AND IT IS DELIBERATELY GENEROUS ─────────────────────────────────
//
// For each citation `F:N` on a charter line L:
//   IDENTIFIERS  every backticked span on L is split into identifier tokens.
//                Tokens shorter than MIN_TOKEN, pure JS keywords, and the
//                cited basename's own words are dropped. What survives is the
//                citation's ANCHOR SET.
//   DECIDABLE    a citation with a non-empty anchor set. A citation whose line
//                names its subject only in prose has nothing to match and is
//                counted separately, never as a miss.
//   RESOLVES     any anchor token appears as a whole word within +/-SLACK lines
//                of N in F.
//
// TWO BIASES, BOTH REAL, BOTH IN THE SAME REPORT:
//   OVER-CREDIT  the anchor set is scraped from the WHOLE citing line, not from
//                the citation's own subject. A line naming ~30 tokens resolves
//                if ANY ONE of them lands in the window. So RESOLVED is an
//                upper bound on correctness, and UNRESOLVED a lower bound on
//                drift.
//   OVER-FLAG    a token can be absent from the window and the citation still
//                be morally right — the line may cite a BLOCK whose name sits
//                outside +/-SLACK, or name the subject in prose while the
//                backticks hold something else.
// Neither bias is removable without a human reading every line. The number is a
// directional floor on drift, not a census of wrongness, and `--report` prints
// it with its denominator so nobody quotes it as the latter.
//
// ── WHY IT FAILS IN BOTH DIRECTIONS ───────────────────────────────────────────
//
//   FIX direction     the charter is stale: N moved, the symbol did not. The
//                     window no longer holds the anchor -> RED.
//   DELETE direction  the symbol is gone from the file entirely. No window can
//                     hold it -> RED.
// A guard proven in one direction is half a guard, so --selftest proves both,
// plus a green on a hand-repaired specimen, plus the empty-read refusal.
//
// ── PINNED AND RANGE CITATIONS ────────────────────────────────────────────────
//
// Every citation in a charter sits in a DATED record, so the honest repair for
// one that has drifted is PROVENANCE, not a new number: pin it to the commit it
// was true at. The pin form NAMES the thing it cites and the commit:
//
//     app.js (renderBadge @ 0db9b0f4a1, L675)        single line
//     app.js (renderBadge @ 0db9b0f4a1, L675-702)    range
//     app.css ("Only the team owner" @ 0db9b0f4a1, L12)   a quoted literal
//
// It is verified against `git show <sha>:<path>` — THAT commit's copy, never
// HEAD — so it cannot drift, and it still reds if the named thing is not where
// it says at that sha (or the sha's copy cannot be read: exit 2, see below).
// The thing is matched as a whole word (hyphen counts as a word character, so
// `.detail-grid` does not credit `.detail-grid--instance`); a "quoted" thing is
// matched as a literal substring. Only the NAMED thing credits a pin — never the
// rest of the citing line, so a pin carries none of the whole-line over-credit.
//
// WHY THIS SHAPE, AND NOT `app.js:675 (at <sha>)`: E11 in
// cloud/priv/static/__css_check.mjs bans `app.js` + `[:~ ]+~?` + two or more
// digits (and `<name>.{js,mjs,sh,css}` + `:` or ` ~` + digits). A form that
// keeps `app.js:675` still carries the banned shape. Here the filename is
// followed by ` (`, which neither branch of E11's alternation accepts, and the
// line number sits behind `L` with no filename before it. So the pin can be
// quoted into any file E11 scans without redding it; --selftest proves that
// against E11's own exported function, not against a copy of its regex.
//
// RANGES. `F:N-M` (hyphen or en dash) is a range: it credits only if an anchor
// lies INSIDE [N, M] — no slack, the range is the tolerance. It is never read
// as `F:N` (the old parser stopped at the dash and gave N +/-slack). A single
// line keeps +/-slack. The same holds for a pinned range.
//
// Pins are stripped from a line before its anchor set is scraped, so the sha,
// the `L<n>` and the pinned thing never become anchors for a sibling citation.
//
// ── VACUITY REFUSAL ───────────────────────────────────────────────────────────
//
// A run whose parser matches NOTHING exits 2 (UNCHECKED), never 0. Same for a
// corpus whose citations are all undecidable, and for a cited file that does not
// exist. A verdict over a corpus that was never read is not a pass. A PIN whose
// sha's copy of the file cannot be read (unknown sha, or a shallow clone — CI
// needs `fetch-depth: 0`) is UNVERIFIABLE and also exits 2: an unread pin is not
// a pass, and it is not a drift either.
//
// ── EXIT CODES ────────────────────────────────────────────────────────────────
//   0  unresolved count <= --max-unresolved (default 0)
//   1  unresolved count above the budget; every miss named with file:line
//   2  UNCHECKED — zero citations parsed, zero decidable, charter missing,
//      cited file missing, a pin whose sha copy is unreadable, or a bad argument
//
// ── USAGE ─────────────────────────────────────────────────────────────────────
//   node scripts/file-line-citation-check.mjs --report
//   node scripts/file-line-citation-check.mjs --list      # resolved + crediting token
//   node scripts/file-line-citation-check.mjs --charter P --map app.js=path/to/app.js
//   node scripts/file-line-citation-check.mjs --max-unresolved 120
//   node scripts/file-line-citation-check.mjs --selftest
//
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const SLACK_DEFAULT = 3;
const MIN_TOKEN = 4;

// Words that carry no location information: JS/DOM vocabulary common enough to
// land inside ANY +/-3 window, which would manufacture false resolutions.
const STOP = new Set([
  "const", "function", "return", "async", "await", "class", "this", "null",
  "true", "false", "undefined", "typeof", "instanceof", "import", "export",
  "default", "break", "continue", "throw", "catch", "finally", "else",
  "case", "switch", "while", "document", "window", "console", "value",
  "length", "push", "then", "true", "data", "text", "json", "html", "http",
  "https", "type", "name", "node", "item", "list", "true", "void",
]);

function usage(msg) {
  process.stderr.write(`UNCHECKED: ${msg}\n`);
  process.stderr.write(
    "usage: node scripts/file-line-citation-check.mjs [--charter P] [--map base=path]...\n" +
    "       [--slack K] [--max-unresolved N] [--report] [--list] [--json] [--root D] [--selftest]\n");
  process.exit(2);
}

function parseArgs(argv) {
  const o = {
    charter: null, maps: [], slack: SLACK_DEFAULT, maxUnresolved: 0,
    report: false, json: false, root: null, selftest: false, list: false,
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const need = () => { if (i + 1 >= argv.length) usage(`${a} needs a value`); return argv[++i]; };
    switch (a) {
      case "--charter": o.charter = need(); break;
      case "--map": o.maps.push(need()); break;
      case "--slack": o.slack = Number(need()); break;
      case "--max-unresolved": o.maxUnresolved = Number(need()); break;
      case "--root": o.root = need(); break;
      case "--report": o.report = true; break;
      case "--list": o.list = true; break;
      case "--json": o.json = true; break;
      case "--selftest": o.selftest = true; break;
      case "-h": case "--help": process.stdout.write(helpText()); process.exit(0); break;
      default: usage(`unknown argument: ${a}`);
    }
  }
  if (!Number.isInteger(o.slack) || o.slack < 0) usage("--slack must be a non-negative integer");
  if (!Number.isInteger(o.maxUnresolved) || o.maxUnresolved < 0) usage("--max-unresolved must be a non-negative integer");
  return o;
}

function helpText() {
  const self = fileURLToPath(import.meta.url);
  return fs.readFileSync(self, "utf8").split("\n")
    .filter((l) => l.startsWith("//")).map((l) => l.replace(/^\/\/ ?/, "")).join("\n") + "\n";
}

function repoRoot(explicit) {
  if (explicit) return path.resolve(explicit);
  try {
    return execFileSync("git", ["rev-parse", "--show-toplevel"], { encoding: "utf8" }).trim();
  } catch {
    return path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
  }
}

const escRe = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

// ── the pin form: `<base> (<thing> @ <sha>, L<N>[-<M>])` ─────────────────────
// Exported shape, mirrored by scripts/file-line-citation-classify.mjs (which
// WRITES it). Any base: stripping must not depend on which targets are mapped.
const PIN_ANY = /\b[\w.-]+\.[A-Za-z0-9]+ \(([^@()\n]+?) @ ([0-9a-f]{7,40}), L(\d+)(?:[-\u2013]L?(\d+))?\)/g;
function pinRe(bases) {
  const alt = bases.map(escRe).join("|");
  return new RegExp(`(?<![\\w.-])(${alt}) \\(([^@()\\n]+?) @ ([0-9a-f]{7,40}), L(\\d+)(?:[-\u2013]L?(\\d+))?\\)`, "g");
}
const stripPins = (line) => line.replace(PIN_ANY, " ");

// A pinned thing: "quoted" -> literal substring; otherwise a whole word where
// `-` is a word character (CSS class names), so a prefix never credits.
function thingRe(thing) {
  const q = thing.match(/^["\u201c](.+)["\u201d]$/);
  if (q) return new RegExp(escRe(q[1]));
  return new RegExp(`(^|[^A-Za-z0-9_$-])${escRe(thing)}([^A-Za-z0-9_$-]|$)`);
}

// ── the anchor set of a charter line ─────────────────────────────────────────
function anchorsOf(line, citedBase) {
  const own = new Set(citedBase.toLowerCase().split(/[^a-z0-9]+/i).filter(Boolean));
  const out = new Set();
  for (const m of stripPins(line).matchAll(/`([^`]+)`/g)) {
    for (const tok of m[1].split(/[^A-Za-z0-9_$]+/)) {
      if (tok.length < MIN_TOKEN) continue;
      if (/^[0-9]+$/.test(tok)) continue;
      if (STOP.has(tok.toLowerCase())) continue;
      if (own.has(tok.toLowerCase())) continue;
      out.add(tok);
    }
  }
  return [...out];
}

// ── parse every `<base>:<N>` citation in a charter ───────────────────────────
function parseCitations(charterText, bases) {
  const alt = bases.map((b) => b.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("|");
  // `F:N-M` is a RANGE and is captured whole: the old `\b(F):(\d+)\b` stopped
  // at the dash and silently read every range as its first line.
  const re = new RegExp(`\\b(${alt}):(\\d+)(?:[-\u2013](\\d+))?\\b`, "g");
  const pre = pinRe(bases);
  const lines = charterText.split("\n");
  const cites = [];
  lines.forEach((text, idx) => {
    for (const m of text.matchAll(re)) {
      const n = Number(m[2]);
      const hi = m[3] && Number(m[3]) >= n ? Number(m[3]) : null;
      cites.push({ base: m[1], line: n, hi, charterLine: idx + 1, text });
    }
    for (const m of text.matchAll(pre)) {
      const n = Number(m[4]);
      const hi = m[5] && Number(m[5]) >= n ? Number(m[5]) : null;
      cites.push({ base: m[1], line: n, hi, charterLine: idx + 1, text,
        pin: { thing: m[2].trim(), sha: m[3] } });
    }
  });
  return cites;
}

const citeLabel = (c) => c.pin
  ? `${c.base} (${c.pin.thing} @ ${c.pin.sha}, L${c.line}${c.hi ? "-" + c.hi : ""})`
  : `${c.base}:${c.line}${c.hi ? "-" + c.hi : ""}`;

// The window a citation credits in: a range is its own tolerance, a single
// line gets +/-slack.
function windowOf(c, nLines, slack) {
  if (c.hi) return [Math.max(1, c.line), Math.min(nLines, c.hi)];
  return [Math.max(1, c.line - slack), Math.min(nLines, c.line + slack)];
}

// THAT commit's copy of the cited file. null = unreadable (unknown sha, or a
// shallow clone): the caller turns it into UNCHECKED, never a pass or a miss.
const pinBlobCache = new Map();
function pinBlob(root, sha, rel) {
  const k = `${sha}:${rel}`;
  if (!pinBlobCache.has(k)) {
    try {
      pinBlobCache.set(k, execFileSync("git", ["-C", root, "show", k],
        { encoding: "utf8", maxBuffer: 1 << 30, stdio: ["ignore", "pipe", "ignore"] }).split("\n"));
    } catch { pinBlobCache.set(k, null); }
  }
  return pinBlobCache.get(k);
}

function evaluatePin(c, tgt, root, slack) {
  c.decidable = true;
  c.anchors = [c.pin.thing];
  const fl = pinBlob(root, c.pin.sha, tgt.rel);
  if (!fl) { c.unreadable = true; c.resolved = null; return; }
  c.beyondEof = c.line > fl.length;
  const re = thingRe(c.pin.thing);
  const [lo, hi] = windowOf(c, fl.length, slack);
  let hit = null;
  for (let n = lo; n <= hi; n++) if (re.test(fl[n - 1])) { hit = { tok: c.pin.thing, at: n }; break; }
  c.resolved = !!hit;
  c.hit = hit;
  if (!hit) {
    let best = null;
    for (let n = 1; n <= fl.length; n++) {
      if (!re.test(fl[n - 1])) continue;
      const d = n < c.line ? c.line - n : (n > (c.hi || c.line) ? n - (c.hi || c.line) : 0);
      if (best === null || d < best.dist) best = { tok: c.pin.thing, at: n, dist: d };
    }
    c.elsewhere = best ? [best] : [];
  }
}

function wordRe(tok) {
  return new RegExp(`(^|[^A-Za-z0-9_$])${tok.replace(/[.*+?^${}()|[\]\\$]/g, "\\$&")}([^A-Za-z0-9_$]|$)`);
}

function evaluate(cites, targets, slack, root) {
  for (const c of cites) {
    const tgt = targets.get(c.base);
    if (c.pin) { evaluatePin(c, tgt, root, slack); continue; }
    c.anchors = anchorsOf(c.text, c.base);
    c.decidable = c.anchors.length > 0;
    c.beyondEof = c.line > tgt.lines.length;
    if (!c.decidable) { c.resolved = null; continue; }
    const [lo, hi] = windowOf(c, tgt.lines.length, slack);
    let hit = null;
    for (const tok of c.anchors) {
      const re = wordRe(tok);
      for (let n = lo; n <= hi; n++) {
        if (re.test(tgt.lines[n - 1])) { hit = { tok, at: n }; break; }
      }
      if (hit) break;
    }
    c.resolved = !!hit;
    c.hit = hit;
    if (!hit) {
      // Where DOES each anchor live? Report the occurrence NEAREST to N, not the
      // first in the file: a first-occurrence scan on a 30k-line file reports a
      // distance to line ~100 for a symbol that also sits 20 lines from the
      // citation, and would overstate every drift it prints.
      c.elsewhere = [];
      for (const tok of c.anchors) {
        const re = wordRe(tok);
        let best = null;
        for (let n = 1; n <= tgt.lines.length; n++) {
          if (!re.test(tgt.lines[n - 1])) continue;
          const d = n < c.line ? c.line - n : (n > (c.hi || c.line) ? n - (c.hi || c.line) : 0);
          if (best === null || d < best.d) best = { at: n, d };
        }
        if (best) c.elsewhere.push({ tok, at: best.at, dist: best.d });
      }
      c.elsewhere.sort((a, b) => a.dist - b.dist);
      c.elsewhere = c.elsewhere.slice(0, 3);
    }
  }
  return cites;
}

function run(o) {
  const root = repoRoot(o.root);
  const charter = path.resolve(root, o.charter);
  if (!fs.existsSync(charter)) {
    process.stderr.write(`UNCHECKED: charter not found at ${charter}\n`);
    return 2;
  }
  const targets = new Map();
  for (const spec of o.maps) {
    const eq = spec.indexOf("=");
    if (eq <= 0) { usage(`--map wants base=path, got ${spec}`); }
    const base = spec.slice(0, eq);
    const p = path.resolve(root, spec.slice(eq + 1));
    if (!fs.existsSync(p)) {
      process.stderr.write(`UNCHECKED: cited file ${base} maps to ${p}, which does not exist. ` +
        "A citation cannot be checked against a file that is not there.\n");
      return 2;
    }
    targets.set(base, { path: p, rel: path.relative(root, p).split(path.sep).join("/"),
      lines: fs.readFileSync(p, "utf8").split("\n") });
  }
  if (targets.size === 0) { usage("no --map given: nothing to check citations against"); }

  const charterText = fs.readFileSync(charter, "utf8");
  const cites = parseCitations(charterText, [...targets.keys()]);

  // ── THE VACUITY REFUSAL ────────────────────────────────────────────────────
  if (cites.length === 0) {
    process.stderr.write(
      `UNCHECKED: the parser matched ZERO ${[...targets.keys()].join("/")}:<N> citations in ` +
      `${path.relative(root, charter)}.\n` +
      "           A run that read nothing has proven nothing. This exits 2, not 0 —\n" +
      "           a silent pass on an empty parse is the exact failure this guard exists to prevent.\n");
    return 2;
  }
  evaluate(cites, targets, o.slack, root);

  const decidable = cites.filter((c) => c.decidable);
  if (decidable.length === 0) {
    process.stderr.write(
      `UNCHECKED: ${cites.length} citation(s) parsed but NONE is machine-decidable — no citing\n` +
      "           line carries a backticked identifier to anchor on. Nothing was measured.\n");
    return 2;
  }
  const unreadable = cites.filter((c) => c.unreadable);
  const resolved = decidable.filter((c) => c.resolved);
  const unresolved = decidable.filter((c) => c.resolved === false);
  const pinned = cites.filter((c) => c.pin);
  const ranges = cites.filter((c) => c.hi);
  const prose = cites.filter((c) => !c.decidable);
  const beyondEof = cites.filter((c) => c.beyondEof);
  const charterLines = new Set(cites.map((c) => c.charterLine));

  if (o.json) {
    process.stdout.write(JSON.stringify({
      charter: path.relative(root, charter),
      targets: [...targets].map(([b, t]) => ({ base: b, path: path.relative(root, t.path), lines: t.lines.length })),
      slack: o.slack,
      citations: cites.length,
      distinctCharterLines: charterLines.size,
      decidable: decidable.length,
      resolved: resolved.length,
      unresolved: unresolved.length,
      proseOnly: prose.length,
      beyondEof: beyondEof.length,
      pinned: pinned.length,
      pinnedVerified: pinned.filter((c) => c.resolved).length,
      pinnedFailed: pinned.filter((c) => c.resolved === false).length,
      pinnedUnreadable: unreadable.length,
      ranges: ranges.length,
      misses: unresolved.map((c) => ({
        cite: citeLabel(c), charterLine: c.charterLine,
        anchors: c.anchors, elsewhere: c.elsewhere,
      })),
    }, null, 2) + "\n");
  } else {
    process.stdout.write("FILE:LINE CITATION CHECK\n");
    process.stdout.write(`  charter        : ${path.relative(root, charter)}\n`);
    for (const [b, t] of targets) {
      process.stdout.write(`  target         : ${b} -> ${path.relative(root, t.path)} (${t.lines.length} lines)\n`);
    }
    process.stdout.write(`  slack          : +/-${o.slack} lines\n`);
    process.stdout.write(`  citations      : ${cites.length} across ${charterLines.size} distinct charter lines\n`);
    process.stdout.write(`  decidable      : ${decidable.length}   (${prose.length} cite by prose only — no backticked anchor — NOT counted as misses)\n`);
    process.stdout.write(`  resolved       : ${resolved.length} / ${decidable.length}\n`);
    process.stdout.write(`  UNRESOLVED     : ${unresolved.length} / ${decidable.length}\n`);
    process.stdout.write(`  beyond EOF     : ${beyondEof.length}   (drift, not truncation, when 0)\n`);
    process.stdout.write(`  pinned         : ${pinned.length}   (verified ${pinned.filter((c) => c.resolved).length}, ` +
      `FAILED ${pinned.filter((c) => c.resolved === false).length}, sha copy unreadable ${unreadable.length}) — checked at THEIR sha, not HEAD\n`);
    process.stdout.write(`  ranges         : ${ranges.length}   (credit only INSIDE [N, M]; never read as N)\n`);
    process.stdout.write(
      "  BIASES         : anchors are scraped from the WHOLE citing line, so a citation\n" +
      "                   RESOLVES if any one of them lands in the window (over-credit),\n" +
      "                   and a line naming its subject in prose has nothing to match\n" +
      "                   (over-flag, mitigated by excluding the prose-only citations above).\n" +
      `                   Read ${unresolved.length}/${decidable.length} as a DIRECTIONAL FLOOR on drift, not a census.\n`);
    if (o.list) {
      process.stdout.write(
        "\n  --- every RESOLVED citation, with the token that credited it ---\n" +
        "  The token is printed because the credit is only as good as the token: a\n" +
        "  generic word landing in the window credits a citation that is wrong by hand.\n" +
        "  Read this list before quoting the resolved count as a correctness rate.\n");
      for (const c of resolved) {
        process.stdout.write(`  ${citeLabel(c)}  charter line ${c.charterLine}  credited by \`${c.hit.tok}\` at ${c.hit.at}\n`);
      }
    }
    if (o.report) {
      process.stdout.write("\n  --- unresolved, worst drift first ---\n");
      const withDrift = unresolved.map((c) => {
        const far = (c.elsewhere || []).map((e) => e.dist);
        return { c, drift: far.length ? Math.min(...far) : -1 };
      }).sort((a, b) => b.drift - a.drift);
      for (const { c, drift } of withDrift.slice(0, 25)) {
        const el = (c.elsewhere || []).map((e) => `${e.tok}@${e.at} (${e.dist} away)`).join(", ") || "(no anchor found anywhere in the file)";
        process.stdout.write(`  ${citeLabel(c)}  (charter line ${c.charterLine}, nearest anchor occurrence ${drift < 0 ? "n/a" : drift + " lines away"})\n`);
        process.stdout.write(`      anchors elsewhere: ${el}\n`);
      }
      if (withDrift.length > 25) process.stdout.write(`  ... and ${withDrift.length - 25} more\n`);
    }
  }

  if (unreadable.length > 0) {
    process.stderr.write(
      `UNCHECKED: ${unreadable.length} pinned citation(s) name a sha whose copy of the cited file cannot be read ` +
      "(unknown sha, or a shallow clone — fetch full history). An unread pin is neither a pass nor a drift:\n");
    for (const c of unreadable.slice(0, 10)) process.stderr.write(`  ${citeLabel(c)}  charter line ${c.charterLine}\n`);
    return 2;
  }
  if (unresolved.length > o.maxUnresolved) {
    if (!o.json) {
      process.stdout.write(`\nFAIL — ${unresolved.length} unresolved citation(s), budget ${o.maxUnresolved}.\n`);
      if (!o.report) {
        for (const c of unresolved.slice(0, 20)) {
          process.stdout.write(`  ${citeLabel(c)}  charter line ${c.charterLine}  anchors: ${c.anchors.slice(0, 8).join(", ")}\n`);
        }
        if (unresolved.length > 20) process.stdout.write(`  ... and ${unresolved.length - 20} more (use --report)\n`);
      }
    }
    return 1;
  }
  if (!o.json) process.stdout.write(`\nPASS — ${resolved.length}/${decidable.length} decidable citations resolve; unresolved ${unresolved.length} <= budget ${o.maxUnresolved}.\n`);
  return 0;
}

// ── SELFTEST: both failure directions, the green, and the empty read ─────────
async function selftest() {
  const t = fs.mkdtempSync(path.join(os.tmpdir(), "flcc-"));
  const self = fileURLToPath(import.meta.url);
  const wdir = path.join(t, "src");
  fs.mkdirSync(wdir, { recursive: true });
  const widget = path.join(wdir, "widget.js");
  const charter = path.join(t, "fixture-charter.md");

  // 40-line target; makeWidget at 30, renderBadge at 12.
  const body = [];
  for (let i = 1; i <= 40; i++) body.push(`// filler line ${i}`);
  body[11] = "function renderBadge(el) { return el; }";   // line 12
  body[29] = "function makeWidget(opts) { return opts; }"; // line 30
  fs.writeFileSync(widget, body.join("\n"));

  const mapArg = ["--map", `widget.js=${widget}`, "--root", t, "--slack", "3"];
  const nodeBin = process.execPath;
  const call = (args) => {
    try {
      const out = execFileSync(nodeBin, [self, ...args], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
      return { code: 0, out };
    } catch (e) {
      return { code: e.status, out: (e.stdout || "") + (e.stderr || "") };
    }
  };

  let fails = 0;
  const show = (label, r, wantCode, mustMatch) => {
    const okCode = r.code === wantCode;
    const okText = !mustMatch || mustMatch.test(r.out);
    process.stdout.write(`\n=== ${label} ===\n`);
    process.stdout.write(r.out.replace(/^/gm, "    "));
    process.stdout.write(`    -> exit ${r.code} (want ${wantCode})${okText ? "" : " / expected text NOT found"}\n`);
    if (!okCode || !okText) { fails++; process.stdout.write("    ARM FAILED\n"); }
    return okCode && okText;
  };

  // ARM 1 — GREEN on a hand-repaired specimen (NON-VACUITY: it parses, and passes).
  fs.writeFileSync(charter,
    "# fixture\n\n| D1 | `makeWidget` builds the widget | widget.js:30 names it |\n" +
    "| D2 | `renderBadge` paints the badge | widget.js:12 names it |\n");
  show("ARM 1  hand-repaired specimen -> GREEN (exit 0)", call([...mapArg, "--charter", charter]), 0, /PASS — 2\/2/);

  // ARM 2 — FIX direction: the charter is STALE, the symbol did not move.
  fs.writeFileSync(charter,
    "# fixture\n\n| D1 | `makeWidget` builds the widget | widget.js:7 names it |\n" +
    "| D2 | `renderBadge` paints the badge | widget.js:12 names it |\n");
  show("ARM 2  FIX direction: stale citation widget.js:7 (symbol at 30) -> RED (exit 1)",
    call([...mapArg, "--charter", charter, "--report"]), 1, /widget\.js:7/);

  // ARM 3 — DELETE direction: citation correct, symbol REMOVED from the file.
  fs.writeFileSync(charter,
    "# fixture\n\n| D1 | `makeWidget` builds the widget | widget.js:30 names it |\n" +
    "| D2 | `renderBadge` paints the badge | widget.js:12 names it |\n");
  const deleted = body.slice();
  deleted[29] = "// filler line 30";
  fs.writeFileSync(widget, deleted.join("\n"));
  show("ARM 3  DELETE direction: makeWidget removed from widget.js -> RED (exit 1)",
    call([...mapArg, "--charter", charter, "--report"]), 1, /no anchor found anywhere in the file/);
  fs.writeFileSync(widget, body.join("\n"));

  // ARM 4 — VACUITY: a charter the parser matches NOTHING in must RED, not pass.
  fs.writeFileSync(charter, "# fixture\n\nNo citations here at all. `makeWidget` is named but never cited.\n");
  show("ARM 4  empty read: zero citations parsed -> UNCHECKED (exit 2), never 0",
    call([...mapArg, "--charter", charter]), 2, /matched ZERO/);

  // ARM 5 — POSITIVE CONTROL on arm 4: the SAME charter with one citation added
  // parses, proving arm 4's zero was the corpus and not a broken parser.
  fs.writeFileSync(charter, "# fixture\n\n`makeWidget` at widget.js:30 is cited.\n");
  show("ARM 5  positive control for ARM 4: add ONE citation to the same file -> parses, GREEN",
    call([...mapArg, "--charter", charter]), 0, /citations      : 1/);

  // ARM 6 — VACUITY: citations exist but none is decidable -> UNCHECKED.
  fs.writeFileSync(charter, "# fixture\n\nThe widget is built at widget.js:30 with no backticks anywhere.\n");
  show("ARM 6  all citations undecidable (no backticked anchor) -> UNCHECKED (exit 2)",
    call([...mapArg, "--charter", charter]), 2, /NONE is machine-decidable/);

  // ARM 7 — VACUITY: the cited file does not exist -> UNCHECKED, not a pass.
  fs.writeFileSync(charter, "# fixture\n\n`makeWidget` at widget.js:30.\n");
  show("ARM 7  cited file missing -> UNCHECKED (exit 2)",
    call(["--map", `widget.js=${path.join(wdir, "gone.js")}`, "--root", t, "--charter", charter]), 2, /does not exist/);

  // ── PINNED + RANGE ARMS ─────────────────────────────────────────────────────
  // A real git history under the fixture root: commit A has makeWidget at 30;
  // commit B (HEAD, and the working copy) deletes it and adds paintChip at 20.
  // A pin must be judged by ITS sha's copy, so each pin arm is chosen so that
  // reading HEAD instead would give the OPPOSITE verdict.
  const g = (...a) => execFileSync("git", ["-C", t, "-c", "user.email=selftest@example.invalid",
    "-c", "user.name=selftest", "-c", "commit.gpgsign=false", ...a], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
  g("init", "-q");
  fs.writeFileSync(widget, body.join("\n"));
  g("add", "src/widget.js"); g("commit", "-q", "-m", "A");
  const shaA = g("rev-parse", "--short=10", "HEAD");
  const bodyB = body.slice();
  bodyB[29] = "// filler line 30";
  bodyB[19] = "function paintChip(el) { return el; }"; // line 20
  fs.writeFileSync(widget, bodyB.join("\n"));
  g("add", "src/widget.js"); g("commit", "-q", "-m", "B");
  const shaB = g("rev-parse", "--short=10", "HEAD");
  const pinArg = ["--map", "widget.js=src/widget.js", "--root", t, "--slack", "3"];
  const cite = (lineText) => { fs.writeFileSync(charter, `# fixture\n\n${lineText}\n`); return [...pinArg, "--charter", charter, "--report"]; };

  show("ARM 8  PIN present at its sha, ABSENT at HEAD -> GREEN (reads the sha's copy, not HEAD)",
    call(cite(`\`makeWidget\` builds it — widget.js (makeWidget @ ${shaA}, L30)`)), 0, /pinned         : 1   \(verified 1/);
  show("ARM 9  PIN absent at its sha (deleted by B) -> RED (exit 1)",
    call(cite(`\`makeWidget\` builds it — widget.js (makeWidget @ ${shaB}, L30)`)), 1, /no anchor found anywhere/);
  show("ARM 10 PIN absent at its sha but PRESENT at HEAD line 20 -> RED (HEAD cannot rescue a pin)",
    call(cite(`\`paintChip\` paints — widget.js (paintChip @ ${shaA}, L20)`)), 1, /FAIL — 1 unresolved/);
  show("ARM 11 PIN at the right sha, wrong line (thing 10 lines off) -> RED",
    call(cite(`\`makeWidget\` — widget.js (makeWidget @ ${shaA}, L20)`)), 1, /10 lines away/);
  show("ARM 12 PINNED RANGE containing the thing -> GREEN",
    call(cite(`\`makeWidget\` — widget.js (makeWidget @ ${shaA}, L10-31)`)), 0, /PASS — 1\/1/);
  show("ARM 13 PINNED RANGE whose slack-neighbour holds the thing -> RED (no slack on a range)",
    call(cite(`\`makeWidget\` — widget.js (makeWidget @ ${shaA}, L31-40)`)), 1, /FAIL/);
  show("ARM 14 PIN whose sha copy is unreadable -> UNCHECKED (exit 2), never a pass or a miss",
    call(cite(`\`makeWidget\` — widget.js (makeWidget @ 0000000dead, L30)`)), 2, /cannot be read/);

  // Unpinned ranges, against the working copy (B): paintChip at 20.
  show("ARM 15 RANGE F:N-M credits a thing deep inside it (read as N +/-3 it would miss) -> GREEN",
    call(cite("`paintChip` — widget.js:5-24")), 0, /ranges         : 1/);
  show("ARM 16 RANGE F:N-M whose only hit sits in N's slack, outside [N, M] -> RED",
    call(cite("`paintChip` — widget.js:22-30")), 1, /widget\.js:22-30/);
  show("ARM 17 SINGLE F:N keeps +/-slack (control for ARM 16: same file, same thing) -> GREEN",
    call(cite("`paintChip` — widget.js:22")), 0, /PASS/);

  // ARM 18 — E11: the pin form must be clean under E11's OWN function; the old
  // `(at <sha>)` form is the positive control and must red it. The banned
  // string is assembled from parts so this file never types one whole.
  {
    process.stdout.write("\n=== ARM 18  pin form vs E11 (cloud/priv/static/__css_check.mjs bannedSourceCitationErrors) ===\n");
    const e11 = path.resolve(path.dirname(self), "..", "cloud", "priv", "static", "__css_check.mjs");
    let ok = false;
    if (!fs.existsSync(e11)) {
      process.stdout.write(`    E11 source not found at ${e11}\n`);
    } else {
      const { bannedSourceCitationErrors } = await import(e11);
      const forms = ["app.js", "app.css", "__app.test.mjs"].map((b) => `// ${b} (makeWidget @ ${shaA}, L675-702) and ${b} ("Only the owner" @ ${shaA}, L12)`);
      const clean = forms.map((f) => bannedSourceCitationErrors(f, "fixture.mjs").length);
      const oldForm = `// ${"app.js"}${":"}${"675"} (at ${shaA})`;
      const red = bannedSourceCitationErrors(oldForm, "fixture.mjs").length;
      process.stdout.write(`    pin form E11 hits per base [app.js, app.css, __app.test.mjs]: ${clean.join(", ")} (want 0,0,0)\n`);
      process.stdout.write(`    control: the (at <sha>) form reds E11 with ${red} hit(s) (want >= 1)\n`);
      ok = clean.every((n) => n === 0) && red >= 1;
    }
    process.stdout.write(`    -> ${ok ? "ok" : "ARM FAILED"}\n`);
    if (!ok) fails++;
  }

  const ARMS = 18;
  fs.rmSync(t, { recursive: true, force: true });
  process.stdout.write(`\nSELFTEST ${fails === 0 ? "PASS" : "FAIL"} — ${ARMS - fails}/${ARMS} arms\n`);
  return fails === 0 ? 0 : 1;
}

const o = parseArgs(process.argv.slice(2));
if (o.selftest) process.exit(await selftest());
if (!o.charter) o.charter = ".claude/workflows/bp-cloud-console-hardening-charter.md";
if (o.maps.length === 0) o.maps = ["app.js=cloud/priv/static/app.js"];
process.exit(run(o));
