#!/usr/bin/env node
// verify-docs.mjs — the standing doc-truth verifier.
//
// Turns the one-time 22-agent doc audit into a repeatable tool. It parses a
// markdown doc into TYPED CLAIMS, verifies each against ground truth (the
// on-disk tree, the symbol graph, the router), and emits findings — but only
// AFTER a RE-VERIFY GATE re-runs each candidate false/stale check
// independently. The gate is the whole point: the one-time audit was ~84%
// accurate and false-flagged `.github/workflows/js-tests.yml` (a path that
// actually exists). A finding that survives re-verify is emitted; one that
// doesn't is suppressed. Low-confidence leads never auto-apply — they go to a
// human-review queue.
//
// The verifier is a LEAD GENERATOR, not an authority. Every finding carries a
// confidence tag (high|low) and the evidence that produced it.
//
//   node tooling/doc-truth/verify-docs.mjs [--json] [<doc-glob>...]
//
// Dependency-free. ESM, node: builtins only.

import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, existsSync, readdirSync, statSync } from "node:fs";
import { dirname, join, basename, extname } from "node:path";
import { fileURLToPath } from "node:url";
import { loadBpSources as loadBpSourcesRaw, resolveBpCommand } from "./bp-cli-sources.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));

// One scan of the CLI tree per process — the Go walk is ~200 files.
let _bpSources = null;
function loadBpSources(opts) {
  if (!_bpSources) _bpSources = loadBpSourcesRaw(opts);
  return _bpSources;
}
const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: HERE })
  .toString()
  .trim();

const SYMBOLS_JSON = join(ROOT, "tooling/symbol-graph/symbols.json");
const MANIFEST_JSON = join(ROOT, "tooling/map/manifest.json");
const CORPUS_FIXTURE = join(HERE, "fixtures/audit-2026-06-21-corpus.json");
const ROUTER = join(ROOT, "api/lib/barkpark_web/router.ex");

// Known repo top-level dirs that anchor a path claim even without an extension.
// NB `bin/` is intentionally NOT here: `bin/<x>` overwhelmingly denotes a RELEASE
// binary invocation (`bin/barkpark_cloud eval …`) or a code token (`bin/1`), not a
// repo file — anchoring it drowns the HIGH lane in noise.
const TOP_DIRS = [
  "api/", "tooling/", "docs/", "js/", "web/", "lib/", "priv/",
  "deploy/", ".github/", "scripts/", "internal/", "docs-site/",
];
// Known file extensions a path token may end in.
const KNOWN_EXT = new Set([
  ".ex", ".exs", ".heex", ".eex", ".mjs", ".js", ".ts", ".tsx", ".jsx",
  ".json", ".md", ".mdx", ".yml", ".yaml", ".sh", ".go", ".toml", ".css",
  ".html", ".txt", ".xml", ".d.ts", ".sql", ".env", ".xsd",
]);
// Tools we can resolve a command against.
const KNOWN_CMD_HEADS = new Set([
  "mix", "bp", "bd", "make", "npm", "pnpm", "curl", "node", "go", "git",
  "systemctl", "psql", "iex", "yarn", "npx",
]);

// ── ground-truth loaders (lazy, cached) ─────────────────────────────────────

let _manifestFiles = null;
function manifestFiles() {
  if (_manifestFiles) return _manifestFiles;
  _manifestFiles = new Set();
  if (existsSync(MANIFEST_JSON)) {
    try {
      const m = JSON.parse(readFileSync(MANIFEST_JSON, "utf8"));
      for (const k of Object.keys(m.files || {})) _manifestFiles.add(k);
    } catch { /* fall through to fs-only */ }
  }
  return _manifestFiles;
}

let _symIndex = null;
// Index symbols by bare symbol name and by file, for fuzzy prose lookup.
function symbolIndex() {
  if (_symIndex) return _symIndex;
  _symIndex = { bySymbol: new Map(), byFileBase: new Map(), nodes: [] };
  if (existsSync(SYMBOLS_JSON)) {
    try {
      const s = JSON.parse(readFileSync(SYMBOLS_JSON, "utf8"));
      _symIndex.nodes = s.nodes || [];
      for (const n of _symIndex.nodes) {
        if (!n || !n.symbol) continue;
        // index the last dotted segment too (function/module leaf)
        const leaf = n.symbol.split(".").pop();
        push(_symIndex.bySymbol, n.symbol, n);
        if (leaf !== n.symbol) push(_symIndex.bySymbol, leaf, n);
        const fb = basename(n.file || "");
        if (fb) push(_symIndex.byFileBase, fb, n);
      }
    } catch { /* leave empty */ }
  }
  return _symIndex;
}
function push(map, key, val) {
  let arr = map.get(key);
  if (!arr) map.set(key, (arr = []));
  arr.push(val);
}

let _routerText = null;
function routerText() {
  if (_routerText !== null) return _routerText;
  _routerText = "";
  // Core router plus any plugin register_routes sources.
  const candidates = [ROUTER];
  try {
    const pluginDir = join(ROOT, "api/lib/barkpark/plugins");
    if (existsSync(pluginDir)) {
      for (const f of readdirSync(pluginDir)) {
        if (f.endsWith(".ex")) candidates.push(join(pluginDir, f));
      }
    }
  } catch { /* ignore */ }
  for (const c of candidates) {
    if (existsSync(c)) {
      try { _routerText += "\n" + readFileSync(c, "utf8"); } catch { /* skip */ }
    }
  }
  return _routerText;
}

// Frozen-target overrides (doc-gate-frozen-specimen-brittleness): the
// acceptance harness pins a cited TARGET file (e.g. router.ex) to a frozen
// snapshot while verifying a frozen fail-before specimen, so the specimen's
// verdict never depends on the LIVE file's absolute line layout. Without
// this, any net line-add above the cited window slid unrelated prose into
// the ±5 needle scan and false-confirmed the frozen stale citation — a
// blocking doc-gates red for innocent router edits (bit PR #1163 and again
// on studio-user-login). Keyed by repo-relative path; empty in normal runs.
const _targetOverrides = new Map();

export function setLinerefTargetOverride(rel, absSnapshotPath) {
  _targetOverrides.set(rel, absSnapshotPath);
}

export function clearLinerefTargetOverrides() {
  _targetOverrides.clear();
}

function linerefTargetPath(rel) {
  return _targetOverrides.get(rel) || join(ROOT, rel);
}

// Cache file reads for lineref verification.
const _fileLineCache = new Map();
function fileLines(absPath) {
  if (_fileLineCache.has(absPath)) return _fileLineCache.get(absPath);
  let lines = null;
  try {
    if (existsSync(absPath) && statSync(absPath).isFile()) {
      lines = readFileSync(absPath, "utf8").split("\n");
    }
  } catch { /* leave null */ }
  _fileLineCache.set(absPath, lines);
  return lines;
}

// Find a real file in the tree whose basename matches `base`. Prefer manifest
// entries (authoritative set), then a bounded fs walk fallback. Returns the
// repo-relative path or null. Cached.
const _baseResolveCache = new Map();
function resolveBasename(base) {
  if (_baseResolveCache.has(base)) return _baseResolveCache.get(base);
  let hit = null;
  for (const p of manifestFiles()) {
    if (basename(p) === base) { hit = p; break; }
  }
  // Manifest is optional (absent in fresh checkouts / CI shallow trees). Fall
  // back to the full git-tracked set so lineref resolution — and the bare-range
  // cue that gates on resolvability — still works with no manifest present.
  if (!hit) {
    for (const p of trackedFiles()) {
      if (basename(p) === base) { hit = p; break; }
    }
  }
  _baseResolveCache.set(base, hit);
  return hit;
}

// ── (a) claim extraction ────────────────────────────────────────────────────

// Pull every backtick span and fenced code block from a markdown doc, tagged
// with the line they start on.
function extractSpans(text) {
  const lines = text.split("\n");
  const spans = []; // {raw, line, fenced, srcLine}
  let inFence = false;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const ln = i + 1;
    if (/^\s*```/.test(line)) {
      inFence = !inFence;
      continue;
    }
    if (inFence) {
      // A trailing `\` is a SHELL LINE CONTINUATION, not the end of a command.
      // Emitting the physical lines separately splits one invocation into two
      // fragments, and every checker downstream then judges half a command —
      // which reds the one correctly-written multi-line command in the tree
      // (templates/astro-search-starter/README.md:28-29) for missing the flags
      // that live on its second line. Join them, and stamp the span with the
      // line the command STARTS on.
      if (/\\\s*$/.test(line)) {
        let joined = line.replace(/\\\s*$/, "");
        let j = i + 1;
        while (j < lines.length && !/^\s*```/.test(lines[j])) {
          const next = lines[j];
          joined += " " + next.trim().replace(/\\\s*$/, "");
          j++;
          if (!/\\\s*$/.test(next)) break;
        }
        spans.push({ raw: joined.replace(/\s+/g, " ").trim(), line: ln, fenced: true, srcLine: joined });
        i = j - 1;
        continue;
      }
      spans.push({ raw: line, line: ln, fenced: true, srcLine: line });
      continue;
    }
    // inline backtick spans — carry the full markdown source line so a lineref
    // claim can find anchors that live in a sibling backtick span on the same
    // line (e.g. `runtime.exs:56` — `host = System.get_env("PHX_HOST")…`).
    const re = /`([^`]+)`/g;
    let m;
    while ((m = re.exec(line))) {
      spans.push({ raw: m[1], line: ln, fenced: false, srcLine: line });
    }
  }
  return spans;
}

// Split a markdown doc into sections on `##`/`###` (and `#`) headings. Returns
// [{ heading, level, startLine, endLine, slug }] in document order. The slice
// before the first heading is emitted as a synthetic "(preamble)" section so no
// content is dropped. Exported for the P2 waterfall detector.
export function sectionsOf(text) {
  const lines = text.split("\n");
  const heads = [];
  let inFence = false;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (/^\s*```/.test(line)) { inFence = !inFence; continue; }
    if (inFence) continue;
    const m = line.match(/^(#{1,6})\s+(.*\S)\s*$/);
    if (m) heads.push({ idx: i, level: m[1].length, heading: m[2].trim() });
  }
  const out = [];
  // preamble before the first heading
  const firstIdx = heads.length ? heads[0].idx : lines.length;
  if (firstIdx > 0) {
    out.push({ heading: "(preamble)", level: 0, startLine: 1, endLine: firstIdx, slug: "" });
  }
  for (let h = 0; h < heads.length; h++) {
    const start = heads[h].idx;
    const end = h + 1 < heads.length ? heads[h + 1].idx : lines.length;
    out.push({
      heading: heads[h].heading,
      level: heads[h].level,
      startLine: start + 1, // 1-based, the heading line
      endLine: end, // exclusive of next heading (1-based count of lines)
      slug: slugify(heads[h].heading),
    });
  }
  return out;
}

// GitHub-style heading slug: lowercase, strip non-word (keep spaces/hyphens),
// collapse whitespace to single hyphens. Matches the `#section-anchor` form.
export function slugify(heading) {
  return heading
    .toLowerCase()
    .replace(/[`*_~]/g, "")
    .replace(/[^a-z0-9 \-]/g, "")
    .trim()
    .replace(/\s+/g, "-");
}

// Extract every typed claim from a doc's text, tagged with the line it appears
// on. This is the P1 extractor, lifted to a clean export so the P2 waterfall
// detector reuses the exact same span-parsing + classification regexes instead
// of duplicating them. `doc` is the repo-relative path used to stamp claims.
export function extractClaims(doc, text) {
  const out = [];
  for (const span of extractSpans(text)) {
    for (const claim of claimsFromSpan(doc, span)) out.push(claim);
  }
  return out;
}

// ── (a′) code-comment claim extraction ───────────────────────────────────────
//
// 27 of the 29 citation-truth defects live in @moduledoc / /// / // doc-comment
// PROSE that the markdown-only extractor never reads. We pull that prose into
// synthetic spans of the SAME shape `extractSpans` yields — `{raw, line, fenced,
// srcLine}` — so `claimsFromSpan` / `verifyClaim` / `reverify` run UNCHANGED.
// The corpus walk dispatches on extension: markdown → extractSpans, code →
// extractCommentSpans.

export function langFor(ext) {
  const e = (ext || "").toLowerCase();
  if (e === ".ex" || e === ".exs") return "elixir";
  if (e === ".go") return "go";
  if (e === ".ts" || e === ".tsx") return "ts";
  return null;
}

// A `#` line/trailing comment (Elixir), excluding `#{…}` interpolation and the
// `?#` char literal. Returns the comment text or null.
function matchElixirComment(line) {
  const m = line.match(/(?:^|[^?])#(?!\{)(.*)$/);
  return m ? m[1] : null;
}

// A `//` or `///` comment (Go / TS), excluding `://` inside URLs. Returns text.
function matchSlashComment(line) {
  const m = line.match(/(?:^|[^:/])\/\/+\s?(.*)$/);
  return m ? m[1] : null;
}

// Reduce a source file to its comment/doc PROSE fragments, each stamped with its
// 1-based source line. Handles Elixir `@moduledoc/@doc/@typedoc` heredocs plus
// `#` comments; Go/TS `/** */` blocks plus `//` lines.
function commentFragments(text, lang) {
  const lines = text.split("\n");
  const frags = [];
  if (lang === "elixir") {
    let inHeredoc = false;
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i], ln = i + 1;
      if (inHeredoc) {
        if (/^\s*"""/.test(line)) { inHeredoc = false; continue; }
        frags.push({ text: line, line: ln });
        continue;
      }
      const hd = line.match(/@(?:moduledoc|doc|typedoc|shortdoc)\s+~?[Ss]?"""/);
      if (hd) {
        const after = line.slice(line.indexOf('"""') + 3);
        const close = after.indexOf('"""');
        if (close >= 0) frags.push({ text: after.slice(0, close), line: ln });
        else inHeredoc = true;
        continue;
      }
      const cm = matchElixirComment(line);
      if (cm) frags.push({ text: cm, line: ln });
    }
  } else {
    // go / ts
    let inBlock = false;
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i], ln = i + 1;
      if (inBlock) {
        const end = line.indexOf("*/");
        const body = (end >= 0 ? line.slice(0, end) : line).replace(/^\s*\*+/, "");
        frags.push({ text: body, line: ln });
        if (end >= 0) inBlock = false;
        continue;
      }
      const bs = line.indexOf("/*");
      const ss = line.indexOf("//");
      if (bs >= 0 && (ss < 0 || bs < ss)) {
        const end = line.indexOf("*/", bs + 2);
        if (end >= 0) frags.push({ text: line.slice(bs + 2, end), line: ln });
        else { frags.push({ text: line.slice(bs + 2), line: ln }); inBlock = true; }
        continue;
      }
      const cm = matchSlashComment(line);
      if (cm) frags.push({ text: cm, line: ln });
    }
  }
  return frags;
}

// Turn one prose fragment into synthetic spans. Mirrors how `extractSpans` emits
// a span per backtick token: here we emit (1) the WHOLE fragment so a bare
// `router.ex … 716-724` phrase classifies as a lineref, and (2) one span per
// whitespace/punctuation-delimited token so a mid-sentence path or `Module.func`
// symbol is seen. Comment spans are `fenced:true` to bypass the
// inline prose-guard (comment prose legitimately carries `…` and aligned spaces).
function emitProseSpans(fragText, line) {
  const spans = [];
  const trimmed = (fragText || "").trim();
  if (!trimmed) return spans;
  // (1) LINEREF PHRASES. For each `basename.ext` occurrence, slice from it to the
  // next filename (so two citations in one comment can't cross-contaminate) and
  // emit the slice ONLY when it genuinely classifies as a lineref. Pre-checking
  // with matchLineref is what stops a non-lineref phrase from falling through to
  // a spurious path/symbol claim (comment prose that merely mentions a file name
  // is not a citation). Bare `router.ex … 716-724` phrases pass; prose does not.
  const fileRe = /[A-Za-z0-9_./-]*[A-Za-z0-9_-]\.[A-Za-z0-9]{1,6}\b/g;
  const fileHits = [];
  let fm;
  while ((fm = fileRe.exec(fragText))) fileHits.push(fm.index);
  for (let k = 0; k < fileHits.length; k++) {
    const start = fileHits[k];
    const end = k + 1 < fileHits.length ? fileHits[k + 1] : fragText.length;
    const phrase = fragText.slice(start, end).trim();
    if (phrase && matchLineref(phrase)) {
      spans.push({ raw: phrase, line, fenced: true, srcLine: fragText, comment: true });
    }
  }
  // (2) BACKTICKED tokens → path / symbol / route candidates. A genuine code or
  // path citation in doc-comment prose is almost always inside `backticks`; bare
  // prose that merely READS like a path (an `internal/system` tier, a
  // `deploy/restart` cycle) is NOT a citation and must never flag. Gating
  // per-token claims on backticks is what keeps the HIGH lane precise.
  for (const m of fragText.matchAll(/`([^`]+)`/g)) {
    const tok = m[1].trim();
    if (tok && tok !== trimmed) {
      spans.push({ raw: tok, line, fenced: true, srcLine: fragText, comment: true });
    }
  }
  return spans;
}

// Synthetic spans over a whole source file's comment prose.
export function extractCommentSpans(text, lang) {
  const spans = [];
  for (const frag of commentFragments(text, lang)) {
    for (const span of emitProseSpans(frag.text, frag.line)) spans.push(span);
  }
  return spans;
}

// Code-comment claims, deduped (the whole-fragment span and a per-token span can
// both yield the same lineref). `comment:true` rides on every claim so the
// confidence discount (symbol/route → low) can be applied downstream.
export function extractCommentClaims(doc, text, lang) {
  const out = [];
  const seen = new Set();
  for (const span of extractCommentSpans(text, lang)) {
    for (const claim of claimsFromSpan(doc, span)) {
      const key = `${claim.type}|${claim.line}|${JSON.stringify(claim.target)}`;
      if (seen.has(key)) continue;
      seen.add(key);
      out.push({ ...claim, comment: true });
    }
  }
  return out;
}

// Dispatch: markdown docs → prose backtick spans; code files → comment prose.
function claimsForDoc(relDoc, text) {
  const lang = langFor(extname(relDoc));
  if (lang) return extractCommentClaims(relDoc, text, lang);
  return extractClaims(relDoc, text);
}

// Comment prose is noisier than a curated markdown backtick span. Keep lineref +
// path (dead-path) findings at HIGH confidence; push symbol/route leads to the
// low-confidence human queue (verifyRoute never emits false anyway; verifySymbol
// is already low, but a discount makes the intent explicit and future-proof).
function commentDiscount(v) {
  if (!v || !v.comment) return v;
  if ((v.status === "false" || v.status === "stale") &&
      (v.type === "symbol" || v.type === "route")) {
    return { ...v, confidence: "low" };
  }
  return v;
}

// Classify a span's text into zero or more typed claims. A span can yield more
// than one claim (e.g. a lineref also looks like a path).
function claimsFromSpan(doc, span) {
  const out = [];
  const raw = span.raw.trim();
  if (!raw) return out;
  // Prose / table-cell text captured in an INLINE backtick span is never a code
  // reference. The tells: an ellipsis (truncated prose) or a run of 2+ spaces
  // (markdown table-column alignment). Scoped to inline spans only — fenced
  // code-block lines legitimately carry indentation. NB middot `·` is a valid
  // separator between sibling linerefs, so it must NOT trigger this skip.
  if (!span.fenced && /…|\s{2,}/.test(raw)) return out;

  // ── lineref (the drift-prone kind) — check FIRST so a `foo.ex:55` span is
  // classified as a lineref, not merely a path.
  //   mix.exs:55 · content.ex ~:2153/:2172 · router.ex line ~672 · ~:1431/:1552
  const lineref = matchLineref(raw);
  if (lineref) {
    out.push({ doc, line: span.line, type: "lineref", raw, target: lineref, srcLine: span.srcLine });
    return out; // a lineref is its own thing; don't double-classify
  }

  // ── command (shell)
  // A FENCED line may carry a shell prompt (`$ ` / `# `). Strip it before
  // deriving the head, or every prompted command is silently DROPPED: the head
  // reads as "$", which is in no KNOWN_CMD_HEADS, so the claim is never emitted
  // and the doc looks clean because nothing was examined. splitCommandLine()
  // already strips the same prompt downstream — that strip was unreachable
  // until now, because extraction never handed it a prompted line.
  // Inline spans are NOT prompt-stripped: a bare `$` in prose is not a prompt.
  const cmdText = span.fenced ? raw.replace(/^[$#]\s+/, "") : raw;
  const cmdHead = cmdText.split(/\s+/)[0];
  if (KNOWN_CMD_HEADS.has(cmdHead) && /\s/.test(cmdText)) {
    out.push({
      doc, line: span.line, type: "command", raw: cmdText, fenced: !!span.fenced,
      target: { head: cmdHead, sub: cmdText.split(/\s+/)[1] || null, full: cmdText },
    });
    return out;
  }

  // ── route
  const route = matchRoute(raw);
  if (route) {
    out.push({ doc, line: span.line, type: "route", raw, target: route });
    return out;
  }

  // ── path
  const path = matchPath(raw);
  if (path) {
    out.push({ doc, line: span.line, type: "path", raw, target: path });
    return out;
  }

  // ── symbol (Elixir module / function ref)
  const sym = matchSymbol(raw);
  if (sym) {
    out.push({ doc, line: span.line, type: "symbol", raw, target: sym });
    return out;
  }

  return out;
}

// Is the number ending at `idx` glued to a WORD rather than standing alone? A
// line number is followed by whitespace or punctuation; a measurement carries a
// unit or a noun — `~23-tool`, `12px`, `~180-400s`. The optional `-NNN` step
// looks PAST a range's second endpoint, because that is where the unit sits.
//   "-tool"  -> reject   "-400s" -> reject   "s before" -> reject   "/page" -> reject
//   "-724,"  -> keep     "\u2013509" -> keep    ")."       -> keep     "/:2172" -> keep
// The slash arm is what separates a RATE from a multi-line citation: `1000/page`
// is a clamp, while `content.ex ~:2153/:2172` puts a `:` or a digit after the
// slash, never a letter.
function unitSuffixed(scan, idx) {
  return /^(?:\s*[-\u2013]\s*\d{1,5})?(?:-|\/)?[A-Za-z]/.test(scan.slice(idx));
}

function matchLineref(raw) {
  // basename.ext with an explicit line number nearby. Tolerate ~ and ranges.
  // Examples: mix.exs:55 · content.ex ~:2153/:2172 · router.ex line ~672 ·
  //           studio_live.ex:189–509 · runtime.exs:61
  const fileM = raw.match(/([A-Za-z0-9_./-]+\.[A-Za-z0-9]+)/);
  if (!fileM) return null;
  const fileTok = fileM[1];
  const base = basename(fileTok);
  if (!/\.[A-Za-z0-9]+$/.test(base)) return null;

  // PROSE IS NOT A CITATION, and the grammar below used to accept it. Two
  // measured instances, both of which reached a verdict about a file nobody
  // cited:
  //
  //   "the ONE canonical consumer AGENTS.md teach block (the ~23-tool
  //    convergence standard)"        → read as AGENTS.md, line 23
  //   "`…-guerrilla-live-writes-2026-08-17.md`): 119"
  //                                  → read as lines 2026, 8, 17 and 119
  //
  // Nothing about either sentence is a lineref. The first glues a number to a
  // WORD; the second harvests the DATE out of the target's own filename. Both
  // are silent today only because an empty anchor set exits `unverifiable`
  // before anything compares the number to the file — so the moment the range
  // check is hoisted (as it is, below) they become loud false reds. Closing the
  // grammar first is what keeps the hoist honest; hoisting first is how a
  // never-worse baseline gets switched off.
  //
  // (1) THE DIGITS INSIDE A FILENAME ARE NOT LINE NUMBERS. Blank the file token
  //     out before harvesting — length-preserving, so a real citation's own
  //     `:<N>` cue is still sitting at exactly the offset it was written at.
  const tokStart = fileM.index;
  const tokEnd = tokStart + fileTok.length;
  const scan = raw.slice(0, tokStart) + " ".repeat(fileTok.length) + raw.slice(tokEnd);

  // collect line numbers expressed as :N, ~:N, "line N", "line ~N", –N ranges
  const nums = [];
  const numRe = /(?:[:~]\s*|line\s*~?\s*|[–-])(\d{2,5})/g;
  let nm;
  while ((nm = numRe.exec(scan))) {
    // (2) A NUMBER GLUED TO A WORD IS A MEASUREMENT, NOT A LINE. `~23-tool`,
    //     `12px`, `~5-minute` — a real line number is followed by whitespace or
    //     punctuation, never by letters. The optional `-NNN` step ahead is what
    //     catches a UNIT hanging off the far end of a RANGE: in `~180-400s
    //     before exit`, the `s` that makes it seconds sits past the second
    //     number, so reading only the character after `180` sees a digit and
    //     lets a duration through as a pair of line numbers. Measured: that is
    //     how `cp-deploy.sh` was reported as citing lines 180 and 400.
    if (unitSuffixed(scan, numRe.lastIndex)) continue;
    nums.push(parseInt(nm[1], 10));
  }
  // BARE-RANGE cue (code-comment prose): a `NNN-NNN` line span written WITHOUT a
  // `:` or backtick — the flagship code-comment defect is
  //   `# Paths mirror router.ex /v1/auth/* (public 716-724, gated 727-734).`
  // Capture BOTH endpoints of every range and treat the range itself as the cue,
  // but only when the cited basename actually resolves to a real file (so random
  // prose like `foo.bar 12-34` never classifies) and the token pair is not a
  // date (`2026-06-21`), which would otherwise read as lines 2026/06.
  const isDate = /\b\d{4}-\d{2}-\d{2}\b/.test(scan);
  let rangeCue = false;
  if (!isDate) {
    const rangeRe = /(\d{2,5})\s*[-–]\s*(\d{2,5})/g;
    let rm;
    while ((rm = rangeRe.exec(scan))) {
      // A unit hanging off the range — `~180-400s`, `50-100ms` — makes it a
      // duration or a size, never a pair of line numbers.
      if (unitSuffixed(scan, rangeRe.lastIndex)) continue;
      nums.push(parseInt(rm[1], 10), parseInt(rm[2], 10));
      rangeCue = true;
    }
  }
  // (3) THE CUE MUST TOUCH THE FILE TOKEN. Every real citation shape — a bare
  //     colon-and-number, a backticked name followed by `line ~N`, a slash-joined
  //     pair of `:N` cues — puts the cue immediately after the
  //     name, separated by nothing but whitespace, backticks or an opening
  //     bracket. A number that turns up LATER in the sentence, past a closing
  //     paren or a run of words, belongs to the prose — that is exactly how
  //     "AGENTS.md teach block (the ~23-tool …)" and "`….md`): 119" were read as
  //     citations. Once adjacency establishes the citation, every number in the
  //     phrase is still harvested, so `content.ex ~:2153/:2172` keeps both.
  //
  //     THE BARE-RANGE CUE IS DELIBERATELY EXEMPT. Its flagship case —
  //     `router.ex /v1/auth/* (public 716-724, gated 727-734)` — puts the range
  //     a whole route away from the name, so requiring adjacency there would
  //     re-open the over-ACCEPT hole that cue was added to close. It carries its
  //     own guard instead: a real range AND a basename that resolves.
  const after = raw.slice(tokEnd);
  const adjacentCue = /^[\s`([]*(?::\s*~?\s*\d|~\s*:?\s*\d|line\s*~?\s*\d)/.test(after);
  const explicitCue = adjacentCue && /[:~]\s*\d|line\s*~?\s*\d/.test(scan);
  const bareCue = rangeCue && resolveBasename(base) !== null;
  if ((!explicitCue && !bareCue) || nums.length === 0) return null;
  return { file: fileTok, base, lines: [...new Set(nums)] };
}

function matchRoute(raw) {
  const verbM = raw.match(/^(GET|POST|PUT|DELETE|PATCH)\s+(\/\S+)/);
  if (verbM) return { method: verbM[1], path: verbM[2] };
  // bare path beginning with /v1 /papers /studio /api /w/ etc.
  if (/^\/(v1|papers|studio|api|w|live|plugins)\b/.test(raw) && raw.includes("/")) {
    // exclude things that are clearly file paths with an extension
    if (KNOWN_EXT.has(extname(raw))) return null;
    return { method: null, path: raw.split(/\s+/)[0] };
  }
  return null;
}

function matchPath(raw) {
  // a single token (no spaces) that contains a slash and either ends in a
  // known extension OR starts with a known top dir.
  let tok = raw.split(/\s+/)[0].replace(/[`,;]+$/, "");
  // Interpolated / templated tokens are dynamic, not literal files:
  // `priv/codelists/onix-issue-#{@issue}.xsd`, `deploy/${SLOT}/env`. Never resolve.
  if (/#\{|\$\{|<%/.test(tok)) return null;
  // Strip a trailing URL / JSON-pointer fragment — `foo.json#/$defs/x` and
  // `guide.md#section` cite a REAL file plus an in-document anchor; the `#…`
  // is never part of the path and would otherwise read as a phantom missing file.
  const hashIdx = tok.indexOf("#");
  if (hashIdx > 0) tok = tok.slice(0, hashIdx);
  if (!tok.includes("/")) return null;
  // must not be a URL or a route
  if (/^https?:\/\//.test(tok) || tok.startsWith("/")) return null;
  // home (`~/.config/…`) and env-var (`$XDG_CONFIG_HOME/…`) paths are user paths,
  // not repo files — never resolvable in the tree, so don't classify them.
  if (/^[~$]/.test(tok)) return null;
  // glob / brace / wildcard patterns and `<placeholder>` templates are not
  // literal paths — skip (e.g. `js/**`, `priv/plugins/*/plugin.json`,
  // `bp:ds:{_all|...}`, `api/lib/barkpark/plugins/<name>.ex`). A real path never
  // contains these characters.
  if (/[*?{}|<>]/.test(tok)) return null;
  // A Go qualified symbol (`internal/bootstrap.WebhookName`,
  // `internal/template.TestRealManifests`) is `pkg/sub.ExportedName` — its final
  // segment's ".Name" is an exported identifier, NOT a file extension. Elixir
  // module refs contain no slash, so a slashed `lowercasePkg.CapitalizedName`
  // token is a Go pkg.Symbol reference, never a repo file path.
  const lastSeg = tok.slice(tok.lastIndexOf("/") + 1);
  if (/^[a-z][A-Za-z0-9_]*\.[A-Z][A-Za-z0-9_]*$/.test(lastSeg)) return null;
  const ext = extname(tok);
  const endsKnown = KNOWN_EXT.has(ext);
  const startsTop = TOP_DIRS.some((d) => tok.startsWith(d));
  // A path that starts with a top dir is anchored to repo root and checkable.
  // A bare relative token (src/index.ts, lib/foo.ts, components/x.tsx) is
  // RELATIVE to some package the doc lives in — not resolvable from repo root
  // without guessing. Treat those as low-confidence: still classify, but the
  // verifier resolves them by basename search before flagging.
  if (!endsKnown && !startsTop) return null;
  // a trailing-slash dir (e.g. "node_modules/next/docs/") is still a path claim
  return { literal: tok, anchored: startsTop };
}

function matchSymbol(raw) {
  // defmodule X · Module.func/arity · Barkpark.Foo.bar · name/2
  const defmod = raw.match(/^defmodule\s+([A-Z][A-Za-z0-9_.]+)/);
  if (defmod) return { module: defmod[1], func: null, arity: null };
  // Module.func/arity  or  Module.Sub  or  func/2
  const mfa = raw.match(/^([A-Z][A-Za-z0-9_.]*?)?\.?([a-z_][A-Za-z0-9_?!]*)?\/(\d+)$/);
  if (mfa && (mfa[1] || mfa[2])) {
    return { module: mfa[1] || null, func: mfa[2] || null, arity: parseInt(mfa[3], 10) };
  }
  // dotted Module path with at least two segments, capitalised head
  if (/^[A-Z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$/.test(raw)) {
    // last segment lowercase ⇒ function ref; else module ref
    const segs = raw.split(".");
    const last = segs[segs.length - 1];
    // A token whose final segment is a file extension is a FILENAME, not an
    // Elixir symbol — e.g. `QUICKSTART.md`, `ONIX_Subset.xsd` match the dotted
    // pattern but are docs, not module refs. Don't flag them as missing symbols.
    if (KNOWN_EXT.has("." + last.toLowerCase())) return null;
    if (/^[a-z_]/.test(last)) {
      return { module: segs.slice(0, -1).join("."), func: last, arity: null };
    }
    return { module: raw, func: null, arity: null };
  }
  return null;
}

// ── (b) verification ────────────────────────────────────────────────────────

function verifyClaim(claim) {
  switch (claim.type) {
    case "path": return verifyPath(claim);
    case "symbol": return verifySymbol(claim);
    case "route": return verifyRoute(claim);
    case "lineref": return verifyLineref(claim);
    case "command": return verifyCommand(claim);
    default:
      return tag(claim, "unverifiable", "low", "unknown claim type");
  }
}

function tag(claim, status, confidence, evidence) {
  return { ...claim, status, confidence, evidence };
}

// Package roots a doc may write paths relative to. Docs in/about a package
// routinely use package-relative paths — `priv/repo/seeds.exs` is run "in api/",
// `lib/barkpark_web/…` lives under api/, `lib/barkpark-client.ts` under web/.
// Resolving against these before declaring a path absent kills a whole class of
// false positives (the verifier is a lead generator — never cry wolf on a real file).
const PACKAGE_ROOTS = ["api", "cloud", "js", "web", "sdk"];

function pathExists(literal) {
  // strip a trailing slash for the fs check; a dir is still "exists"
  const clean = literal.replace(/\/+$/, "");
  if (manifestFiles().has(clean)) return true;
  if (existsSync(join(ROOT, clean))) return true;
  // package-root-relative resolution
  for (const pkg of PACKAGE_ROOTS) {
    if (existsSync(join(ROOT, pkg, clean))) return true;
  }
  return false;
}

function verifyPath(claim) {
  const lit = claim.target.literal;
  // `./x` and `../x` are markdown links RELATIVE TO THE DOC's own directory,
  // not the repo root — resolve them there (e.g. `../cli/HANDBOOK.md` from
  // docs/setup/ → docs/cli/HANDBOOK.md).
  if (/^\.\.?\//.test(lit) && claim.doc) {
    const abs = join(dirname(join(ROOT, claim.doc)), lit.replace(/\/+$/, ""));
    if (existsSync(abs)) return tag(claim, "confirmed", "high", `relative link resolves from ${dirname(claim.doc)}/: ${lit}`);
    return tag(claim, "false", "low", `relative link not found from doc dir: ${lit}`);
  }
  if (pathExists(lit)) {
    return tag(claim, "confirmed", "high", `path resolves: ${lit}`);
  }
  // Unanchored relative paths (e.g. `src/revalidate/index.ts`) are relative to
  // whatever package the doc lives in. We can't resolve the prefix from repo
  // root, but if the trailing path segments appear as a real file SOMEWHERE in
  // the tree, the claim is almost certainly fine — confirm at low confidence
  // rather than emit a false.
  if (!claim.target.anchored) {
    if (suffixResolves(lit)) {
      return tag(claim, "confirmed", "low",
        `unanchored path matches a real file by suffix: ${lit}`);
    }
    return tag(claim, "false", "low",
      `unanchored path; no file matches suffix in tree: ${lit}`);
  }
  // Anchored at a top-level dir but absent there. If the multi-segment path still
  // matches a real file elsewhere by suffix — e.g. `web/router.ex` resolving to
  // cloud/lib/barkpark_cloud/web/router.ex, where `web/` is ALSO a repo top-dir —
  // the reference is ambiguous, not a confident error. Drop to the low-confidence
  // human queue instead of crying wolf at high confidence.
  if (lit.includes("/") && suffixResolves(lit)) {
    return tag(claim, "false", "low",
      `anchored path absent at the top-level anchor but matches a real file by suffix (ambiguous): ${lit}`);
  }
  // anchored candidate false — the RE-VERIFY GATE in verifyDoc decides
  return tag(claim, "false", "high", `path not found at repo root or in manifest: ${lit}`);
}

// All git-tracked files (cached). The manifest only covers indexed roots, so it
// misses e.g. cloud/ — but a doc may reference a real cloud/ file by suffix.
let _trackedFiles = null;
function trackedFiles() {
  if (_trackedFiles) return _trackedFiles;
  _trackedFiles = new Set();
  try {
    const out = execFileSync("git", ["ls-files"], { cwd: ROOT, maxBuffer: 1 << 27 }).toString();
    for (const line of out.split("\n")) if (line) _trackedFiles.add(line);
  } catch { /* leave empty — fall back to manifest only */ }
  return _trackedFiles;
}

// Does some real file end with this (multi-segment) relative path? e.g.
// `src/revalidate/index.ts` matches js/packages/nextjs/src/revalidate/index.ts.
// Checks the manifest AND the full git-tracked set (the latter covers cloud/ etc.).
function suffixResolves(rel) {
  const clean = rel.replace(/\/+$/, "");
  for (const set of [manifestFiles(), trackedFiles()]) {
    for (const p of set) {
      if (p === clean || p.endsWith("/" + clean)) return true;
    }
  }
  return false;
}

function verifySymbol(claim) {
  const idx = symbolIndex();
  const t = claim.target;
  let hits = [];
  if (t.module) hits = hits.concat(idx.bySymbol.get(t.module) || []);
  if (t.func) hits = hits.concat(idx.bySymbol.get(t.func) || []);
  // also try the full dotted leaf
  if (t.module && t.func) {
    const full = `${t.module}.${t.func}`;
    hits = hits.concat(idx.bySymbol.get(full) || []);
  }
  if (hits.length) {
    return tag(claim, "confirmed", "low", `symbol found in graph (${hits.length} node(s))`);
  }
  // Short-name module refs ("Tenancy.Auth" for "Barkpark.Tenancy.Auth") — confirm
  // when a real qualified symbol ENDS WITH this exact dotted suffix. Requires a
  // multi-segment ref anchored at a `.` boundary, so it never confirms a
  // coincidental single word, and external libs (Plug.Test) stay flagged because
  // no Barkpark symbol ends with `.Plug.Test`. Direction is CONFIRM-only.
  if (t.module && t.module.includes(".")) {
    const suf = "." + t.module;
    if (idx.nodes.some((n) => n.symbol === t.module || n.symbol.endsWith(suf))) {
      return tag(claim, "confirmed", "low", `qualified symbol ends with .${t.module}`);
    }
  }
  // Extraction is fuzzy on prose symbols ⇒ low confidence false (human queue).
  return tag(claim, "false", "low", `symbol not in graph: ${claim.raw}`);
}

function verifyRoute(claim) {
  const path = claim.target.path;
  // Build a loose pattern: replace :params and * with a wildcard, escape rest.
  const segs = path.split("/").filter(Boolean);
  // Match by the literal static prefix segments — routes are dynamic so we
  // only ever CONFIRM, never emit false.
  const statics = segs.filter((s) => !s.startsWith(":") && s !== "*");
  const rt = routerText();
  const found = statics.length > 0 && statics.every((s) => rt.includes(s));
  if (found) {
    return tag(claim, "confirmed", "low", `route prefix segments present in router`);
  }
  return tag(claim, "unverifiable", "low", `route not matched in router (dynamic; not flagged false)`);
}

// EVERY tracked file a citation could mean, and whether the citation itself
// narrowed the choice. Returns {candidates, explicit}.
//
// THE DEFECT THIS REPLACES. The old path was `resolveBasenameNear(t.base, …)` —
// t.BASE, never t.FILE — so a citation that supplied a directory had it thrown
// away at the door and was then matched against whatever file happened to share
// the basename. `cloud/lib/barkpark_cloud/accounts.ex:2186` was checked against
// api/lib/barkpark/accounts.ex (943 lines) and reported as exceeding the file
// length. The comment was right; the resolver was wrong, and the verdict read
// as rot. Measured 2026-08-24: 33 of 36 out-of-range findings were false
// positives this way, and 10 of those 33 had supplied an explicit path.
//
// EXPLICIT BEATS BASENAME, ALWAYS. When the citation carries a `/`, the path
// (or path SUFFIX — `lib/barkpark_cloud/web/router.ex` names one file
// unambiguously) is the answer, and there is NO basename fallback: falling back
// is what produced the false positives, and a cited path that does not exist is
// its own honest verdict rather than an excuse to go looking elsewhere.
function linerefCandidates(t, docPath) {
  const tok = (t.file || "").replace(/^\.\//, "");
  if (tok.includes("/")) {
    const hits = [];
    for (const p of trackedFiles()) if (p === tok || p.endsWith("/" + tok)) hits.push(p);
    return { candidates: hits, explicit: true };
  }
  const hits = [];
  for (const p of trackedFiles()) if (basename(p) === t.base) hits.push(p);
  if (hits.length > 1) {
    // Keep the sibling-preferring answer FIRST so a single-verdict read is
    // unchanged for the common case, but carry every candidate so the caller
    // can refuse to guess.
    const near = resolveBasenameNear(t.base, docPath);
    if (near && hits.includes(near)) return { candidates: [near, ...hits.filter((h) => h !== near)], explicit: false };
  }
  return { candidates: hits, explicit: false };
}

// A one-line description of each candidate for an ambiguity verdict: the path
// and its length, which is what a reader needs to see which one was meant.
function candidateSummary(cands) {
  return cands
    .map((p) => {
      const l = fileLines(linerefTargetPath(p));
      return `${p} (${l ? l.length : "unreadable"} lines)`;
    })
    .join(" · ");
}

// AMBIGUITY IS NOT A DEFECT; AN UNRESOLVABLE CITATION IS. When a bare stem
// names several files, this verifies against EVERY one and keeps the first
// non-stale answer — so a citation that is correct about SOME candidate is
// never reported as rot. Only when it is stale against all of them is the
// ambiguity itself reported, naming each candidate and its line count.
//
// DELIBERATE DEVIATION FROM criterion 1 AS WRITTEN, stated rather than hidden.
// Criterion 1 asks that any bare stem with 2+ matches red. Measured on this
// tree: 189 of 618 bare-stem citations are ambiguous. Red-ing all of them adds
// ~189 novel findings against a 519-entry baseline — which criterion 2 forbids
// ("a fix that reshuffles the baseline is a different change"). The two cannot
// both hold. This implements the half that removes false verdicts without
// manufacturing new ones, and reports ambiguity in the evidence of the verdicts
// that DO fire.
//
// ── THE RULING ON BASENAME AMBIGUITY: **KEEP**, decided in PR #13988 ──────────
// The question put was whether basename-only resolution should REFUSE when the
// stem names more than one tracked file, rather than silently taking the first.
// The ruling is KEEP — verify against EVERY candidate and red only when the
// citation is stale in ALL of them — and it lives here, in the code it governs,
// because a ruling recorded only in a task row is a ruling the next reader of
// this function will never see.
//
// THE REASON. Refusing is not a neutral "be stricter" knob: it converts a
// citation that is CORRECT about one of its candidates into a finding, which is
// the over-REJECT failure this checker has now been fixed for three separate
// times (a file required to name itself, directory segments demanded as
// anchors, a definition's name demanded inside its own body). Ambiguity is a
// property of the REPO's naming, not evidence that a comment drifted, and a
// gate that reds on correct citations is the fastest way to get the whole
// never-worse baseline switched off. What refusal would buy — catching a
// citation that is stale about the file it MEANT while passing against a
// namesake — is bought instead by the candidate walk below, which only accepts a
// non-stale answer and reports the whole candidate set when every one is stale.
//
// THE COUNT, re-measured on this tree rather than inherited: 173 of 581
// bare-stem lineref citations in the code corpus resolve to more than one
// tracked file, and a further 36 resolve to none. The most-forked stems people
// actually cite are auth.ex (6 tracked files), lifecycle.ex (5), client.go (5)
// and errors.ex (4). Refusing on ambiguity would therefore red 173 citations,
// against a 385-entry baseline, and essentially none of them for having drifted.
//
// WHERE THE RULING IS NOT YET HONOURED, and it is a live defect rather than a
// deviation: `reverify` re-resolves through `resolveBasenameNear(t.base, …)`,
// reading t.BASE and discarding an explicit path the citation supplied. So a
// stale verdict about a path-qualified citation can be suppressed by a namesake
// the citation never named — the same first-match hazard `linerefCandidates`
// was written to remove from the first pass. Measured while building the
// enclosing-definition selftest arm, which passed vacuously because of it.
function verifyLineref(claim) {
  const t = claim.target;
  const { candidates, explicit } = linerefCandidates(t, claim.doc);

  if (candidates.length === 0) {
    return explicit
      ? tag(claim, "unverifiable", "low", `lineref path does not resolve to a tracked file: ${t.file}`)
      : tag(claim, "unverifiable", "low", `lineref basename does not resolve to a file: ${t.base}`);
  }

  if (candidates.length > 1) {
    // THE PRIMARY'S VERDICT STANDS UNLESS THE LINE IS OUT OF RANGE.
    //
    // The first draft of this took the first NON-stale answer from any
    // candidate — and that suppressed a real, frozen defect
    // (`api/lib/barkpark/plugins/capabilities.ex:1527`, the flagship bare-range
    // case: "router.ex /v1/auth/* (public 716-724, gated 727-734)"). Lines
    // 716-734 exist in BOTH routers, so a citation genuinely stale about the
    // api router passed against the cloud router by coincidence and the
    // acceptance harness reported a MISS. Shopping for a file where a claim
    // happens to pass is the over-ACCEPT failure this checker already has an
    // open row for; making it worse while fixing over-REJECT is not a trade.
    //
    // So the fallback is scoped to the ONE symptom this change exists to fix:
    // an OUT-OF-RANGE verdict, which is the signature of binding to the wrong
    // file (a short twin cannot hold a line the real target has). If the cited
    // line EXISTS in the primary, that file is a plausible referent and its
    // verdict — confirmed, unverifiable or stale-on-anchors — is the answer.
    const primary = verifyLinerefAgainst(claim, candidates[0]);
    if (!(primary.status === "stale" && /exceed file length/.test(primary.evidence || ""))) {
      return primary;
    }
    for (const cand of candidates.slice(1)) {
      const v = verifyLinerefAgainst(claim, cand);
      if (v.status !== "stale") return v;
      if (!/exceed file length/.test(v.evidence || "")) return v;
    }
    // Out of range in every candidate: the citation is wrong wherever it
    // points, and the reader is owed the whole candidate set.
    return tag(claim, "stale", "high",
      `${primary.evidence} — AMBIGUOUS stem \`${t.base}\` matches ${candidates.length} tracked files, ` +
      `and the cited line is out of range in every one: ${candidateSummary(candidates)}`);
  }

  return verifyLinerefAgainst(claim, candidates[0]);
}

function verifyLinerefAgainst(claim, rel) {
  const t = claim.target;
  const abs = linerefTargetPath(rel);
  const lines = fileLines(abs);
  if (!lines) {
    return tag(claim, "unverifiable", "low", `lineref file unreadable: ${rel}`);
  }
  // A CITED WINDOW THAT CLIPS ITS OWN EVIDENCE. Checked FIRST — before the
  // needle harvest and before the ±3 scan — because BOTH of the outcomes below
  // hide this class: an empty needle set exits "unverifiable" without ever
  // looking at the window, and the ±3 slack reaches OUTSIDE the cited range and
  // confirms on the very line the citation excluded.
  const clipped = clippedEnumeration(claim, lines, rel);
  if (clipped) return tag(claim, "stale", "high", clipped);

  // A CITATION PAST THE END OF THE FILE IS STALE ON ITS OWN EVIDENCE, and needs
  // no anchor to say so. This check used to sit at the BOTTOM, behind the needle
  // requirement — so a citation whose anchor set came back empty exited
  // `unverifiable` ("no checkable anchor") before anyone compared the number
  // against the file. The most mechanically checkable property a lineref has —
  // is the line even IN the file — was the one property the guard skipped, and
  // an empty anchor set is the COMMON case for a bare `dir/file.ex:N` citation
  // now that path segments no longer count as anchors.
  //
  // HOISTED SECOND, NOT FIRST. Ordering against `clippedEnumeration` is
  // deliberate: a clipped enumeration cites lines that are all IN range, so it
  // can never be reached by this check, and leaving it above keeps its sharper
  // verdict. Ordering against the GRAMMAR is the load-bearing part, and it is a
  // different file's worth of work: hoisted while `matchLineref` still read
  // "~23-tool" and a date in a filename as line numbers, this check turns every
  // one of those into a loud false red, which is how a never-worse baseline gets
  // switched off. The grammar was closed first, in this same change.
  const beyondCited = t.lines.filter((n) => n > lines.length);
  if (beyondCited.length) {
    return tag(claim, "stale", "high",
      `cited line(s) ${t.lines.join("/")} exceed file length (${lines.length}) in ${rel}`);
  }

  // Extract salient tokens from the claim's surrounding markdown line that
  // should sit near the referenced code line: quoted strings, dotted symbols,
  // snake_case idents, env-var names. Use the full source line so anchors in a
  // sibling backtick span are seen.
  const needles = linerefNeedles(claim.srcLine || claim.raw, t);

  // THE STEM IS NOT EVIDENCE. `dedup_wall.ex` does not say `dedup_wall` in its
  // own body — almost no file names itself — so demanding that token near the
  // cited line is a test the truth cannot pass. When the stem is the ONLY thing
  // harvested there is no anchor at all, and the honest verdict is "cannot
  // check", never "stale". Deliberately scoped to the SOLE-needle case: where a
  // real anchor exists too, the stem rides along exactly as before, which is
  // what keeps this from re-scoring 14 confirmed citations into novel findings.
  const stem = basenameStem(t);
  const anchors = needles.filter((n) => n !== stem);
  if (needles.length === 0 || anchors.length === 0) {
    // nothing concrete to check against — leave as low-conf unverifiable
    return tag(claim, "unverifiable", "low", `lineref has no checkable anchor near :${t.lines.join("/")}`);
  }
  // For each referenced line number, scan ±3 for any needle.
  const WINDOW = 3;
  const independent = needles.filter((nd) => !selfDerived(nd, t));
  let anyHit = false;
  let indHit = false;
  const checked = [];
  for (const n of t.lines) {
    const lo = Math.max(1, n - WINDOW);
    const hi = Math.min(lines.length, n + WINDOW);
    let hit = false;
    for (let i = lo; i <= hi; i++) {
      const text = lines[i - 1] || "";
      if (!hit && needles.some((nd) => text.includes(nd))) hit = true;
      if (independent.some((nd) => text.includes(nd))) { indHit = true; break; }
    }
    checked.push({ n, hit });
    if (hit) anyHit = true;
  }
  if (indHit) {
    return tag(claim, "confirmed", "high",
      `referenced content found within ±${WINDOW} of cited line(s)`);
  }
  // THE ANCHOR IS THE ENCLOSING DEFINITION, AND ±3 CANNOT SEE IT. A definition
  // writes its name ONCE, at its head; every line of its body is, by
  // construction, a line that does not repeat the name. So a citation pointing
  // into a body and anchoring on the function it is inside asks the reader to
  // look at exactly the region where the anchor cannot appear, and the ±3 scan
  // above returns "none of the referenced anchors sit within ±3" on a citation
  // that is CORRECT. Measured on main: the quiz-bridge sandbox cascade
  // regression cites the bridge at a line inside `handle_info/2` whose clause
  // head sits SIX lines above, and the sweep reported it NOVEL.
  //
  // ±3 IS NOT WIDENED TO FIX THIS, and must not be. The window is the precision
  // knob: widen it and every citation confirms against a neighbour, which is how
  // a guard stops finding drift while still looking busy — and `clippedEnumeration`
  // above exists precisely because window slack already reached OUTSIDE a cited
  // range once and confirmed on the very line the citation excluded. Widening
  // trades one false direction for the other. This is instead a SEPARATE confirm
  // path asking a DIFFERENT question: not "is the word near the line" but "is the
  // line inside the thing the word names". WINDOW stays 3 and remains the
  // fallback for every citation with no enclosing definition to appeal to.
  //
  // CONFIRM-ONLY, INDEPENDENT-ANCHORS-ONLY. It can turn a would-be stale into a
  // confirmation; it can never manufacture a stale. And it reads only needles
  // that survived `selfDerived`, so a name the citation's own path supplied
  // cannot certify the citation — the leak `basenameStem` closed stays closed.
  const enclosing = enclosingDefHit(lines, t.lines, independent);
  if (enclosing) {
    return tag(claim, "confirmed", "high",
      `cited line ${enclosing.cited} sits INSIDE \`${enclosing.name}\`, whose definition head is at` +
      ` line ${enclosing.line} of ${rel} — the name is written once, at the head, which is outside` +
      ` ±${WINDOW} of the cited line`);
  }
  if (anyHit) {
    // Every hit came from a needle the CITATION ITSELF supplied. That is not a
    // confirmation, and it is not evidence of drift either — say so, rather
    // than stamping the claim verified at high confidence.
    return tag(claim, "unverifiable", "low",
      `only self-derived anchors [${needles.filter((nd) => selfDerived(nd, t)).slice(0, 3).join(", ")}]` +
      ` sit near cited line(s) ${t.lines.join("/")} in ${rel} — a needle taken from the cited path` +
      ` confirms nothing about the claim`);
  }
  // No needle near any cited line ⇒ the line number drifted. Dominant stale.
  // Every cited line is IN RANGE here: the beyond-EOF case returned above, which
  // is why this arm no longer branches on it.
  return tag(claim, "stale", "high",
    `none of the referenced anchors [${needles.slice(0, 3).join(", ")}] sit within ±${WINDOW} of cited line(s) ${t.lines.join("/")} in ${rel}`);
}

// ── the ENCLOSING DEFINITION ─────────────────────────────────────────────────
// Definition heads this checker understands, one pattern per host language, the
// capture group always the NAME. Kept deliberately narrow: a line that is not
// unmistakably a function definition is better left to the ±3 fallback than
// guessed at, because every shape added here is a shape that can CONFIRM.
const DEF_HEAD_PATTERNS = [
  /^\s*def(?:p|macro|macrop)?\s+([a-z_][A-Za-z0-9_]*[?!]?)/,                                   // Elixir
  /^\s*func\s+(?:\([^)]*\)\s*)?([A-Za-z_][A-Za-z0-9_]*)\s*[([]/,                               // Go, incl. methods
  /^\s*(?:export\s+(?:default\s+)?)?(?:async\s+)?function\s*\*?\s*([A-Za-z_$][A-Za-z0-9_$]*)/, // JS/TS
  // An exported arrow / function expression. Restricted to a right-hand side
  // that is actually a function, so `export const CONFIG = {…}` — an object, not
  // a definition with a body a line can be "inside" — is not treated as one.
  /^\s*export\s+(?:const|let|var)\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*(?::[^=]*)?=\s*(?:async\s+)?(?:\(|function\b|[A-Za-z_$][A-Za-z0-9_$]*\s*=>)/,
];

function defHeadName(text) {
  for (const re of DEF_HEAD_PATTERNS) {
    const m = text.match(re);
    if (m) return m[1];
  }
  return null;
}

// Every definition whose BODY contains line `n`, innermost first.
//
// INDENTATION IS THE WHOLE MECHANISM, which is why this needs no parser and no
// per-language brace counting. Walk BACKWARDS from the cited line carrying the
// smallest indent seen so far: a definition head encloses the line exactly when
// its own indent is STRICTLY smaller than every non-blank line between it and
// the citation. A closing `end` / `}` sits at its head's own indent, so the
// first one met on the way up pins the running minimum there and every
// definition at that level or deeper is correctly ruled out as already closed.
//
// IT FAILS CLOSED, ON PURPOSE. A body line at column 0 — a heredoc, a wrapped
// string, a language this list does not cover — drives the running minimum to 0
// and no enclosing definition is found; the ±3 scan then answers exactly as it
// does today. The cost of that is a confirmation not granted, i.e. at worst the
// false-stale this file already errs toward. The alternative — guessing past a
// construct we cannot read — manufactures CONFIRMATIONS, and a checker that
// certifies what it could not read is the failure the whole baseline exists to
// measure.
function enclosingDefNames(lines, n) {
  const out = [];
  let minIndent = Infinity;
  for (let i = Math.min(n, lines.length); i >= 1; i--) {
    const text = lines[i - 1] || "";
    if (text.trim() === "") continue;
    const indent = text.length - text.trimStart().length;
    if (indent < minIndent) {
      const name = defHeadName(text);
      if (name) out.push({ name, line: i });
      minIndent = indent;
    }
    if (indent === 0) break;
  }
  return out;
}

// Does any cited line sit inside a definition an independent anchor NAMES?
// A dotted needle counts when its last segment is the name, so a comment citing
// `Quiz.Content.load_question/2` anchors on the `load_question` it means.
function enclosingDefHit(lines, citedLines, anchorNeedles) {
  for (const n of citedLines) {
    if (!(n >= 1 && n <= lines.length)) continue;
    for (const d of enclosingDefNames(lines, n)) {
      if (anchorNeedles.some((nd) => nd === d.name || nd.endsWith("." + d.name))) {
        return { name: d.name, line: d.line, cited: n };
      }
    }
  }
  return null;
}

// ── the TOO-NARROW WINDOW ────────────────────────────────────────────────────
// THE DEFECT THIS CATCHES, from the tree it was written against. A census row
// read:
//
//   source declares only `watch` and `preflight` verbs
//   (scripts/pds-window-sentinel.sh:48-49)
//
// The sentinel declares THREE verbs and the third is the DEFAULT
// (`local cmd="${1:-sample}"`). The USAGE block is a homogeneous run —
//
//   #   scripts/pds-window-sentinel.sh sample      <- clipped
//   #   scripts/pds-window-sentinel.sh watch
//   #   scripts/pds-window-sentinel.sh preflight
//
// — and the citation took the last two lines of it. Every other member of this
// bug family announces itself: a stale pin points at a line that moved, a
// hardcoded count stops matching, a line-anchored waiver rehashes. This one
// never reds, because the cited lines are IN RANGE and NON-BLANK and say exactly
// what the claim says they say. "In range and non-blank" is not "correct": the
// window's job was to be evidence, and it excluded the one line that refutes it.
// A citation is normally what makes a claim checkable; here it is what made the
// claim wrong, and made it look well-evidenced while wrong.
//
// THE SIGNAL, and why it does not need to read English. Two independent
// conditions must BOTH hold:
//
//   (1) STRUCTURAL — the cited lines form a contiguous run of >= 2 that shares a
//       substantial common prefix, and the line immediately before or after the
//       run shares that same prefix. A shared prefix is what makes lines
//       SIBLINGS: entries of one list, arms of one case, rows of one table. The
//       citation cut a list in the middle of itself.
//   (2) EXHAUSTIVE — the citing prose claims the cited window is the WHOLE set
//       (`only`, `solely`, `exclusively`, `both`, `no other`, `nothing but`).
//
// (1) alone is ordinary and common: citing two lines of a longer list is fine
// when the claim is about those two lines. (2) alone is fine too. It is the
// CONJUNCTION that is a false claim about a set — the claim asserts totality
// over a window that provably is not total. Requiring both is what keeps this
// off the 547-entry baseline instead of flooding it.
const EXHAUSTIVE_CUE =
  /\b(only|solely|exclusively|both|nothing but|no other|and no more|the (?:sole|lone))\b/i;

function commonPrefix(a, b) {
  const n = Math.min(a.length, b.length);
  let i = 0;
  while (i < n && a[i] === b[i]) i++;
  return a.slice(0, i);
}

// Returns evidence text when the citation is an exhaustive claim over a clipped
// homogeneous run, else null.
function clippedEnumeration(claim, lines, rel) {
  const t = claim.target;
  const prose = claim.srcLine || claim.raw;
  if (!EXHAUSTIVE_CUE.test(prose)) return null;

  // THE SPAN, NOT THE ENDPOINTS. `t.lines` is a deduped SET of every number the
  // citation mentions, so `types.ts:117-126` arrives as [117, 126] — two points
  // ten lines apart, indistinguishable there from the two separate points in
  // `content.ex ~:2153/:2172`. Only the raw text says which is which: a dash
  // between two numbers is a RANGE and means every line between them. Reading the
  // span off `t.lines` instead would restrict this check to citations of exactly
  // two ADJACENT lines and silently skip every wider window — 8 candidates on the
  // tree this was written against, of which only the adjacent ones would qualify.
  const spans = [];
  for (const m of (claim.raw || "").matchAll(/(\d{2,5})\s*[-–]\s*(\d{2,5})/g)) {
    const a = parseInt(m[1], 10), b = parseInt(m[2], 10);
    if (b > a && b - a < 400) spans.push([a, b]);
  }
  if (spans.length === 0) return null;

  for (const [lo, hi] of spans) {
    if (lo < 1 || hi > lines.length) continue;
    const cited = [];
    for (let n = lo; n <= hi; n++) cited.push((lines[n - 1] || "").replace(/\s+$/, ""));
    if (cited.some((l) => l.trim() === "")) continue; // a blank line is not a list entry

    // The shared shape of the cited lines. Require it to carry real content —
    // 8+ non-space characters — so a run of `#` or `  ` never counts as a prefix.
    let prefix = cited[0];
    for (const l of cited.slice(1)) prefix = commonPrefix(prefix, l);
    if (prefix.trim().length < 8) continue;

    // A sibling immediately outside the run, sharing that same prefix.
    for (const [n, side] of [[lo - 1, "before"], [hi + 1, "after"]]) {
      if (n < 1 || n > lines.length) continue;
      const text = (lines[n - 1] || "").replace(/\s+$/, "");
      if (!text.startsWith(prefix)) continue;
      const widened = side === "before" ? `${n}-${hi}` : `${lo}-${n}`;
      return (
        `cited range ${lo}-${hi} in ${rel} is an EXHAUSTIVE claim over a CLIPPED run:` +
        ` line ${n} (immediately ${side}) shares the cited lines' prefix ${JSON.stringify(prefix.trim())}` +
        ` and is excluded from the window. The claim asserts totality over a window that is not total` +
        ` — widen the citation to ${widened} or drop the exhaustiveness wording.`
      );
    }
  }
  return null;
}

// SELF-DERIVED ANCHORS CANNOT VERIFY THE CITATION THEY CAME FROM. `linerefNeedles`
// drops the whole `t.file` / `t.base` token but leaves its PIECES in: the
// route-segment harvester turns `scripts/pds-window-sentinel.sh:64-65` into the
// needle `pds`, a substring of the citation's own path. A file whose header
// repeats its own path on every USAGE line then "confirms" the citation against
// its own name. Measured on 7df142e0a7: that single needle carried the false
// claim `source declares only watch and preflight verbs
// (scripts/pds-window-sentinel.sh:64-65)` all the way to confirmed/HIGH.
//
// Scoped DELIBERATELY to the CONFIRM decision only. Removing these needles from
// the STALE decision as well re-scores 350 baseline entries out of existence and
// promotes 13 fresh ones — a churn this row did not ask for. A self-derived
// needle stays able to say "the file is still shaped roughly like this"; it is
// only barred from certifying the claim.
function selfDerived(s, t) {
  return t.file.includes(s) || t.base.includes(s);
}

// A FILE DOES NOT NAME ITSELF IN ITS OWN BODY, so its own name is never an
// anchor for a citation OF it. The guard for this already existed and never
// fired: it compared the harvested token against `t.base.replace(/\W/g, "_")`,
// which turns `dedup_wall.ex` into `dedup_wall_ex` — a string no prose ever
// contains. So the snake_case harvester kept `dedup_wall`, the sweep demanded
// that token within ±3 of the cited line, `dedup_wall.ex` naturally never says
// its own name, and a CORRECT citation was reported as stale.
//
// MEASURED on main at 3dd205eeb4: `mutate-warnings.test.ts:26` cites
// `dedup_wall.ex:524` for "the SHARPER band". Line 524 is `severity: "warning"`
// inside `defp warning/1` at :519 — exactly what the comment says. The gate
// reported it NOVEL and reddened main.
//
// The class is every citation of the form `<snake_case_file>.ex:<line>` carrying
// no second symbol: the stem is then the ONLY needle, so the finding is
// guaranteed. This is the mirror of the too-narrow-window defect — there a wrong
// citation was accepted, here a right one is rejected — and a gate that reds on
// correct citations is the fastest way to get the whole never-worse baseline
// switched off.
//
// Stripping the EXTENSION is the whole fix; the stem is dropped however it was
// harvested (the route-segment rule reaches it too, via `content/dedup_wall.ex`).
function basenameStem(t) {
  return String(t.base || "").replace(/\.[A-Za-z0-9]+$/, "");
}

// Pull checkable anchors out of a lineref claim's raw text.
function linerefNeedles(raw, t) {
  const needles = new Set();
  // quoted string literals
  for (const m of raw.matchAll(/"([^"]{2,})"/g)) needles.add(m[1]);
  // dotted symbol refs like System.get_env, Module.func
  for (const m of raw.matchAll(/\b([A-Z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)+)\b/g)) needles.add(m[1]);
  // snake_case / handle_event-style identifiers (>=4 chars, has _ )
  for (const m of raw.matchAll(/\b([a-z][a-z0-9_]*_[a-z0-9_]+)\b/g)) {
    if (m[1].length >= 4) needles.add(m[1]);
  }
  // env-var / SCREAMING_CASE constant names (PHX_HOST, LAST_EVENT_ID). Require an
  // underscore or digit so English words written in caps for EMPHASIS (NOT, INTO,
  // MIRRORS, BEAM) are not mistaken for code anchors — otherwise a prose-only
  // "anchor" drives a bogus stale lineref.
  for (const m of raw.matchAll(/\b([A-Z][A-Z0-9]*_[A-Z0-9_]+|[A-Z]{2,}[0-9][A-Z0-9]*)\b/g)) needles.add(m[1]);
  // CamelCase type/identifier refs — code-comment prose cites these bare (no
  // dot), e.g. `types.ts:117-126` → the anchor is `ListenEvent`, not a dotted
  // symbol. Adding needles only ever makes a lineref MORE likely to confirm, so
  // this cannot manufacture a false stale — it only sharpens a genuine drift.
  for (const m of raw.matchAll(/\b([A-Z][a-z0-9]+[A-Z][A-Za-z0-9]*)\b/g)) needles.add(m[1]);
  // route-path segments — a comment that cites `/v1/auth/*` anchors on `auth`;
  // keep segments of length >= 3 so noise like `v1` / `id` does not leak in.
  //
  // A FILE PATH IS NOT A ROUTE, AND ITS SEGMENTS ARE NOT ANCHORS. This harvester
  // was written for URL paths, where a segment really is content the cited code
  // contains. Run over a citation it also chews the CITATION'S OWN PATH into
  // needles: `plugins/indx/errors.ex` yields `indx` and `errors`, and the sweep
  // then demands those words within ±3 of the cited line. Nothing about an
  // Elixir module obliges it to spell its own directory in its own body, so the
  // test is one the truth cannot pass and the verdict is stale-on-correct.
  //
  // THE PARTIAL PATH IS WHY THE EXISTING GUARDS MISS IT. `basenameStem` drops
  // the bare-basename shape (`errors.ex` → `errors`) and `selfDerived` knows a
  // substring of the target path is not evidence — but a citation written as
  // `plugins/indx/errors.ex` is NEITHER an explicit repo-relative path NOR a
  // bare basename. It falls between the two arms: the stem filter removes only
  // `errors`, leaving the directory segments standing as though someone had
  // written them as anchors.
  //
  // WORSE, THE SEGMENTS TRAVEL. Needles are harvested from `claim.srcLine` — the
  // whole comment line — while `emitProseSpans` deliberately slices `raw` at each
  // filename so two citations in one comment cannot cross-contaminate. Reading
  // the full line for needles walks straight around that slicing: a line naming
  // both `plugins/github/errors.ex` and `plugins/indx/errors.ex` hands `github`
  // to the indx claim as an "independent" anchor — independent of the indx path,
  // certainly, and evidence of nothing.
  //
  // MEASURED on main: six of the eight novel findings that reddened doc-gates had
  // an anchor set consisting ENTIRELY of path segments — [github, errors, indx]
  // and [provisioner, support] — i.e. the sweep reported drift while holding
  // nothing it could have checked. The emptiness guard in `verifyLinerefAgainst`
  // exists for exactly that case and never reached it, because path segments
  // were counted as anchors. Excluding them lets the honest verdict
  // (`unverifiable`, "no checkable anchor") fire where it was always meant to.
  //
  // FILTERED AFTER THE HARVEST, NOT INSIDE ONE HARVESTER, because the segments
  // arrive by more than one route. The obvious producer is the rule directly
  // below — but `lib/barkpark_cloud/verify.ex` and
  // `components/studio_components/editor.ex` reach the same place through the
  // SNAKE_CASE rule above, since a directory named `barkpark_cloud` is a
  // perfectly good snake_case identifier. Fixing only the route-segment rule
  // cleared six findings and left four of the same class standing, each of them
  // an anchor set of exactly one directory name. One post-filter covers every
  // producer, including any added later.
  //
  // A token is a FILE PATH, not a route, when it carries an extension:
  // `/v1/auth/*` has none, so `auth` still survives as a route anchor.
  const pathSegments = new Set();
  for (const m of raw.matchAll(/[A-Za-z0-9_./-]*\.[A-Za-z0-9]{1,6}\b/g)) {
    for (const seg of m[0].split("/")) {
      const bare = seg.replace(/\.[A-Za-z0-9]+$/, "");
      if (bare) pathSegments.add(bare);
    }
  }
  for (const m of raw.matchAll(/\/([a-z][a-z0-9_]{2,})/g)) needles.add(m[1]);
  // drop the bare filename token itself, and every segment of any path cited on
  // this line — its own and its neighbours'
  const out = [...needles].filter(
    (s) => s !== t.file && s !== t.base && !pathSegments.has(s),
  );
  return out;
}

// Resolve a bare basename PREFERRING the citing file's own directory / package
// before the first global manifest hit. A code file that writes `types.ts` means
// the `types.ts` sitting NEXT TO IT — and several `types.ts` exist across the js/
// packages, so a blind manifest lookup would resolve to the wrong one. Falls back
// to the global (manifest-first) resolver for markdown docs, whose citations are
// repo-relative rather than package-relative.
function resolveBasenameNear(base, docPath) {
  if (docPath) {
    let dir = dirname(docPath);
    // walk up from the citing file's dir toward repo root, first same-dir hit wins
    while (dir && dir !== "." && dir !== "/") {
      const cand = join(dir, base);
      if (trackedFiles().has(cand) || existsSync(join(ROOT, cand))) return cand;
      const up = dirname(dir);
      if (up === dir) break;
      dir = up;
    }
  }
  return resolveBasename(base);
}

let _makeTargets = null;
function makeTargets() {
  if (_makeTargets) return _makeTargets;
  _makeTargets = new Set();
  const mk = join(ROOT, "Makefile");
  if (existsSync(mk)) {
    try {
      for (const line of readFileSync(mk, "utf8").split("\n")) {
        const m = line.match(/^([a-zA-Z0-9_-]+):/);
        if (m) _makeTargets.add(m[1]);
      }
    } catch { /* ignore */ }
  }
  return _makeTargets;
}

function onPath(bin) {
  try {
    execFileSync("which", [bin], { stdio: ["ignore", "ignore", "ignore"] });
    return true;
  } catch { return false; }
}

function verifyCommand(claim) {
  const { head, sub } = claim.target;
  if (head === "make") {
    if (sub && makeTargets().has(sub)) {
      return tag(claim, "confirmed", "high", `make target exists: ${sub}`);
    }
    return tag(claim, "unverifiable", "low", `make target not found in Makefile: ${sub || "(none)"}`);
  }
  // `bp` used to be confirmed on `which bp` ALONE — a vacuous green: the binary
  // existing says nothing about whether the printed command parses, so every
  // wrong `bp …` in the tree read as verified. Resolve it against the CLI's own
  // four sources instead (bp-cli-sources.mjs). The dedicated gate
  // (verify-bp-commands.mjs) is the enforcing surface; here the verdict stays
  // LOW confidence by construction so this lead-generator's repo-wide report
  // routes bp findings to the human queue rather than auto-emitting them.
  if (head === "bp" || head === "barkpark") {
    let sources;
    try {
      sources = loadBpSources({ root: ROOT });
    } catch (e) {
      return tag(claim, "unverifiable", "low", `bp sources unavailable: ${e.message}`);
    }
    if (!sources.ok) {
      return tag(claim, "unverifiable", "low", `bp sources unavailable: ${sources.errors.join("; ")}`);
    }
    const r = resolveBpCommand(sources, claim.target.full, { fenced: !!claim.fenced });
    if (r.verdict === "proven") {
      return tag(claim, "confirmed", "low",
        `bp command parses: \`bp ${r.path.join(" ")}\` via source(s) ${[...new Set(r.via)].join("+")} ` +
        `(parses — not proof it succeeds)`);
    }
    if (r.verdict === "unproven") {
      return tag(claim, "unverifiable", "low", `bp command UNPROVEN: ${r.unproven.join("; ")}`);
    }
    return tag(claim, "false", "low", `bp command does not parse: ${r.reasons.join("; ")}`);
  }
  // bd / mix / npm / pnpm etc. — only check the tool resolves; subcommand
  // surfaces are dynamic, so don't over-claim.
  if (onPath(head)) {
    return tag(claim, "confirmed", "low", `tool resolves on PATH: ${head}`);
  }
  return tag(claim, "unverifiable", "low", `tool not on PATH: ${head}`);
}

// ── (c) THE RE-VERIFY GATE ───────────────────────────────────────────────────
// Before any candidate false/stale is emitted as a finding, re-run its check
// INDEPENDENTLY. If the re-check passes, suppress the finding and mark it
// confirmed. High-confidence survivors become findings; low-confidence leads
// go to the human queue.

function reverify(claim) {
  // returns a (possibly rewritten) verified claim
  if (claim.status !== "false" && claim.status !== "stale") return claim;

  if (claim.type === "path") {
    // The js-tests.yml case: re-check the literal path, both at repo root and
    // as-written against the manifest, INDEPENDENTLY of the first pass.
    const lit = claim.target.literal;
    const cleanAbs = join(ROOT, lit.replace(/\/+$/, ""));
    const survives = !(pathExists(lit) || existsSync(cleanAbs));
    if (!survives) {
      return tag(claim, "confirmed", "high",
        `RE-VERIFY GATE: path actually exists on re-check (${lit}) — finding suppressed`);
    }
    return { ...claim, reverified: true };
  }

  if (claim.type === "lineref") {
    // Re-resolve the file and re-scan a slightly wider window. If the anchor
    // now lands, the first pass was a near-miss — suppress.
    const t = claim.target;
    // RE-RESOLVE THE WAY THE FIRST PASS DID. This used to call
    // `resolveBasenameNear(t.base, …)` — t.BASE, so a citation that supplied an
    // explicit path had it thrown away at the door and was re-checked against
    // whatever file happened to share the basename. That is the exact defect
    // `linerefCandidates` was written to remove from the first pass, still live
    // in the gate that overrules it: a stale verdict about a path-qualified
    // citation could be suppressed by a namesake the citation never named.
    // Measured while building the enclosing-definition and filename-date
    // selftest arms — both passed VACUOUSLY because the gate scored a twin.
    const { candidates } = linerefCandidates(t, claim.doc);
    const rel = candidates[0] || resolveBasenameNear(t.base, claim.doc);
    if (rel) {
      const lines = fileLines(linerefTargetPath(rel));
      if (lines) {
        // A CLIPPED-ENUMERATION finding must not be re-checked by the needle
        // scan below. The scan's whole job is to forgive a citation that is off
        // by a few lines — which is exactly the defect here, so running it would
        // suppress every finding of this class the moment it was raised. Re-derive
        // the clip INDEPENDENTLY instead: if the neighbouring sibling is still
        // there, the finding survives; if the file changed underneath, it goes.
        const stillClipped = clippedEnumeration(claim, lines, rel);
        if (stillClipped) return { ...claim, reverified: true, evidence: stillClipped };
        if (/EXHAUSTIVE claim over a CLIPPED run/.test(claim.evidence || "")) {
          return tag(claim, "confirmed", "high",
            `RE-VERIFY GATE: the clipped sibling is no longer adjacent on re-check — finding suppressed`);
        }
        // AN OUT-OF-RANGE VERDICT IS NOT AN OFF-BY-A-FEW, and the needle scan
        // below must not be given the chance to forgive one. That scan exists to
        // rescue a citation that missed by a line or two — but no width of
        // window makes a line the file does not have exist, and a citation
        // carrying SEVERAL numbers lands a needle on whichever one IS in range,
        // taking the out-of-range verdict down with it. Measured: a citation
        // naming a year past the end of a 132-line file was suppressed because
        // the same comment also named a line near real content.
        //
        // Re-derived INDEPENDENTLY against the file this pass resolved, exactly
        // as the clipped check above is: if the line is still out of range the
        // finding stands; if the file grew underneath it, the finding goes.
        if (/exceed file length/.test(claim.evidence || "")) {
          if (t.lines.some((n) => n > lines.length)) {
            return { ...claim, reverified: true };
          }
          return tag(claim, "confirmed", "high",
            `RE-VERIFY GATE: every cited line is inside ${rel} (${lines.length} lines) on re-check — finding suppressed`);
        }
        const needles = linerefNeedles(claim.srcLine || claim.raw, t);
        const WINDOW = 5; // wider on re-check to avoid off-by-a-few false stale
        let hit = false;
        for (const n of t.lines) {
          const lo = Math.max(1, n - WINDOW), hi = Math.min(lines.length, n + WINDOW);
          for (let i = lo; i <= hi; i++) {
            if (needles.some((nd) => (lines[i - 1] || "").includes(nd))) { hit = true; break; }
          }
          if (hit) break;
        }
        if (hit) {
          return tag(claim, "confirmed", "high",
            `RE-VERIFY GATE: referenced content found within ±${WINDOW} on re-check — finding suppressed`);
        }
      }
    }
    return { ...claim, reverified: true };
  }

  // symbol false is low-confidence by construction — it never becomes a hard
  // finding; the human queue handles it. Mark reverified so the router routes
  // it to the queue rather than the findings list.
  return { ...claim, reverified: true };
}

// ── per-doc verification ─────────────────────────────────────────────────────

function verifyDoc(relDoc) {
  return verifyDocText(relDoc, readFileSync(join(ROOT, relDoc), "utf8"));
}

// Same pipeline as verifyDoc, but on SUPPLIED text rather than the file on disk.
// The doc path is used only as resolution context (basename/sibling lookup and
// relative-link anchoring); the citations verified come from `text`. This lets
// the acceptance gate prove FAIL-BEFORE against a FROZEN buggy specimen — the
// detection stays provable even after the live tree has been corrected, which
// is exactly the coupling that would otherwise turn every fix into a red gate.
export function verifyDocText(relDoc, text) {
  const verified = [];
  for (const claim of claimsForDoc(relDoc, text)) {
    let v = verifyClaim(claim);
    if (v.status === "false" || v.status === "stale") v = reverify(v);
    v = commentDiscount(v);
    verified.push(v);
  }

  const statuses = { confirmed: 0, false: 0, stale: 0, unverifiable: 0 };
  const findings = []; // high-confidence false/stale that survived the gate
  const humanQueue = []; // low-confidence leads
  for (const v of verified) {
    statuses[v.status] = (statuses[v.status] || 0) + 1;
    if (v.status === "false" || v.status === "stale") {
      if (v.confidence === "high") findings.push(slim(v));
      else humanQueue.push(slim(v));
    }
  }
  return { doc: relDoc, statuses, findings, humanQueue, total: verified.length };
}

function slim(v) {
  return {
    doc: v.doc, line: v.line, type: v.type, status: v.status,
    confidence: v.confidence, raw: v.raw, evidence: v.evidence,
  };
}

// ── corpus resolution ────────────────────────────────────────────────────────

export function defaultCorpus() {
  const c = JSON.parse(readFileSync(CORPUS_FIXTURE, "utf8"));
  const all = [...(c.ctx || []), ...(c.batches || []).flat()];
  const present = [], skipped = [];
  for (const d of all) {
    if (existsSync(join(ROOT, d))) present.push(d);
    else skipped.push(d);
  }
  return { present, skipped };
}

// The LIVE corpus: every tracked .md in the repo, minus vendored/cold/WIP trees.
// This is what the standing tools (highways, waterfall, verify CLI, --emit-refs)
// index by default, so a newly-added doc is visible the moment it's tracked —
// no fixture round-trip. The frozen 92-doc fixture (defaultCorpus) stays ONLY
// for P1's recall acceptance, which is scored against the audited set.
// Graceful fallback to defaultCorpus() when git is absent / not a checkout.
const LIVE_EXCLUDE = ["node_modules/", "obsidian_example/"];
export function liveCorpus() {
  let lines;
  try {
    lines = execFileSync("git", ["ls-files", "*.md"], { cwd: ROOT })
      .toString()
      .split("\n");
  } catch {
    return defaultCorpus();
  }
  const present = [], skipped = [];
  for (const raw of lines) {
    const d = raw.trim();
    if (!d) continue;
    if (LIVE_EXCLUDE.some((p) => d.startsWith(p) || d.includes("/" + p))) continue;
    if (existsSync(join(ROOT, d))) present.push(d);
    else skipped.push(d);
  }
  return { present, skipped };
}

// The CODE-COMMENT corpus: every tracked .ex/.exs/.go/.ts, minus vendored /
// generated trees. This is what the standing code-comment verifier indexes so a
// drifted @moduledoc lineref is caught the moment it lands. Graceful empty
// fallback when git is absent.
const CODE_EXTS = new Set([".ex", ".exs", ".go", ".ts"]);
const CODE_EXCLUDE = ["node_modules/", "_build/", "deps/", "vendor/", "priv/static/", ".git/"];
export function codeCommentCorpus() {
  let lines;
  try {
    lines = execFileSync("git", ["ls-files"], { cwd: ROOT, maxBuffer: 1 << 27 })
      .toString()
      .split("\n");
  } catch {
    return { present: [], skipped: [] };
  }
  const present = [], skipped = [];
  for (const raw of lines) {
    const d = raw.trim();
    if (!d) continue;
    if (!CODE_EXTS.has(extname(d))) continue;
    if (CODE_EXCLUDE.some((p) => d.startsWith(p) || d.includes("/" + p))) continue;
    if (existsSync(join(ROOT, d))) present.push(d);
    else skipped.push(d);
  }
  return { present, skipped };
}

// Resolve user-supplied globs/paths (relative to repo root). Supports a simple
// trailing /** or * — no external glob dep.
function resolveArgs(args) {
  const present = [], skipped = [];
  for (const a of args) {
    const rel = a.replace(/^\.?\//, "");
    if (existsSync(join(ROOT, rel))) {
      if (statSync(join(ROOT, rel)).isFile()) present.push(rel);
      else walkMd(join(ROOT, rel), rel, present);
    } else {
      skipped.push(rel);
    }
  }
  return { present, skipped };
}
function walkMd(absDir, relDir, out) {
  for (const e of readdirSync(absDir)) {
    if (e.startsWith(".")) continue;
    const abs = join(absDir, e), rel = join(relDir, e);
    const st = statSync(abs);
    if (st.isDirectory()) walkMd(abs, rel, out);
    else if (e.endsWith(".md")) out.push(rel);
  }
}

// ── reporting ────────────────────────────────────────────────────────────────

export function runVerify(docs) {
  const results = docs.map(verifyDoc);
  const confidenceDist = { high: 0, low: 0 };
  for (const r of results) {
    for (const f of r.findings) confidenceDist[f.confidence]++;
    for (const h of r.humanQueue) confidenceDist[h.confidence]++;
  }
  const humanQueue = results.flatMap((r) => r.humanQueue);
  return { docs: results, confidenceDist, humanQueue };
}

// Optional byproduct: doc → [referenced repo files] map, for drift-gating from
// the manifest WITHOUT mutating manifest.json's schema. Written only on
// --emit-refs. Lets CI re-verify just the docs whose referenced files changed.
function buildDocRefs(docs) {
  const refs = {};
  for (const relDoc of docs) {
    const text = readFileSync(join(ROOT, relDoc), "utf8");
    const set = new Set();
    for (const span of extractSpans(text)) {
      for (const claim of claimsFromSpan(relDoc, span)) {
        if (claim.type === "path" && claim.target.anchored && pathExists(claim.target.literal)) {
          set.add(claim.target.literal.replace(/\/+$/, ""));
        }
        if (claim.type === "lineref") {
          const rel = resolveBasename(claim.target.base);
          if (rel) set.add(rel);
        }
      }
    }
    if (set.size) refs[relDoc] = [...set].sort();
  }
  return { generatedAt: new Date().toISOString(), refs };
}

function printHuman(report, skipped) {
  const { docs, confidenceDist, humanQueue } = report;
  let totFindings = 0;
  const agg = { confirmed: 0, false: 0, stale: 0, unverifiable: 0 };
  for (const d of docs) {
    for (const k of Object.keys(agg)) agg[k] += d.statuses[k] || 0;
    totFindings += d.findings.length;
  }
  const bar = "─".repeat(74);
  process.stdout.write(`\ndoc-truth verifier — ${docs.length} doc(s)\n${bar}\n`);
  if (skipped && skipped.length) {
    process.stdout.write(`skipped (no longer on disk): ${skipped.length}\n`);
    for (const s of skipped.slice(0, 10)) process.stdout.write(`  · ${s}\n`);
  }
  // per-doc lines, only those with findings or non-trivial counts
  for (const d of docs) {
    if (d.findings.length === 0 && d.humanQueue.length === 0) continue;
    const s = d.statuses;
    process.stdout.write(
      `\n${d.doc}\n  confirmed ${s.confirmed} · false ${s.false} · stale ${s.stale} · unverifiable ${s.unverifiable}` +
      `  (${d.findings.length} finding(s), ${d.humanQueue.length} queued)\n`);
    for (const f of d.findings) {
      process.stdout.write(`    ✗ [${f.status.toUpperCase()} ${f.type}] L${f.line} \`${trunc(f.raw, 50)}\`\n`);
      process.stdout.write(`        ${f.evidence}\n`);
    }
  }
  process.stdout.write(`\n${bar}\n`);
  process.stdout.write(
    `TOTALS  confirmed ${agg.confirmed} · false ${agg.false} · stale ${agg.stale} · unverifiable ${agg.unverifiable}\n`);
  process.stdout.write(`high-confidence findings (emitted): ${totFindings}\n`);
  process.stdout.write(`confidence dist of leads: high ${confidenceDist.high} · low ${confidenceDist.low}\n`);
  process.stdout.write(`human-review queue (low-confidence, never auto-applied): ${humanQueue.length}\n`);
  process.stdout.write(`${bar}\n`);
}

function trunc(s, n) { return s.length > n ? s.slice(0, n - 1) + "…" : s; }

// ── CLI ──────────────────────────────────────────────────────────────────────

function main() {
  const argv = process.argv.slice(2);
  const wantJson = argv.includes("--json");
  const emitRefs = argv.includes("--emit-refs");
  const wantCode = argv.includes("--code");
  const globs = argv.filter((a) => !a.startsWith("--"));

  let docs, skipped;
  if (globs.length) {
    ({ present: docs, skipped } = resolveArgs(globs));
  } else if (wantCode) {
    // The standing CODE-COMMENT corpus: every tracked .ex/.exs/.go/.ts.
    ({ present: docs, skipped } = codeCommentCorpus());
  } else {
    // Standing default is the LIVE tracked tree (verify + --emit-refs).
    // Explicit globs still override. The frozen fixture stays for P1 recall only.
    ({ present: docs, skipped } = liveCorpus());
  }

  if (emitRefs) {
    const sidecar = buildDocRefs(docs);
    const out = join(HERE, "doc-refs.json");
    writeFileSync(out, JSON.stringify(sidecar, null, 2) + "\n");
    process.stdout.write(`doc-refs.json written: ${Object.keys(sidecar.refs).length} docs with refs\n`);
    process.exit(0);
  }

  const report = runVerify(docs);

  if (wantCode) {
    // ONE findings artifact — the sole producer for the Cody Citation-truth GRADE
    // dimension, CI drill-down, and this report (charter Decision 10). Only the
    // high-confidence, re-verified findings feed the grade (Decision 11); the
    // low-confidence leads stay in the human queue and are counted, not graded.
    const byType = {};
    let high = 0;
    for (const d of report.docs) for (const f of d.findings) { high++; byType[f.type] = (byType[f.type] || 0) + 1; }
    const artifact = { generatedAt: new Date().toISOString(), high, low: report.humanQueue.length, byType, findings: report.docs.flatMap((d) => d.findings) };
    writeFileSync(join(HERE, "citation-truth-report.json"), JSON.stringify(artifact, null, 2) + "\n");
  }

  if (wantJson) {
    process.stdout.write(JSON.stringify({ ...report, skipped }, null, 2) + "\n");
  } else {
    printHuman(report, skipped);
  }
  // exit 0 always for the report verb — callers branch on the JSON, not status
  process.exit(0);
}

// run only when invoked directly (so acceptance.mjs can import runVerify)
if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  main();
}
