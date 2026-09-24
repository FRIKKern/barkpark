#!/usr/bin/env node
//
// FILE:LINE CITATION CLASSIFIER — bucket every `<file>:<N>` citation in a
// charter by SHAPE, settle the buckets a rule can settle, and print the residue
// a human must read. Companion to scripts/file-line-citation-check.mjs, which
// answers "does this citation still land?"; this answers "WHY not, and which
// rule repairs it?".
//
// ── WHY PINNING, NOT REWRITING ────────────────────────────────────────────────
//
// Every citation in the console charter sits inside a DATED record — a D-row,
// a wave plan, a wave-log entry. `app.js:675` in D292 is a measurement taken on
// the day D292 was written. Rewriting 675 to today's line would make D292 claim
// it measured something it never measured. So the repair for a drifted citation
// in a dated record is PROVENANCE, not a new number: append the main commit the
// number was true at, NAMING the thing it cites — `app.js (renderFoo @ <sha10>,
// L675)` — and the checker then verifies that thing against `git show
// <sha>:<path>`, which never drifts. An unpinned citation keeps being checked
// against HEAD, so a NEW citation that rots still reds.
//
// THE PIN FORM IS E11-CLEAN BY CONSTRUCTION. An earlier draft of this header
// proposed appending `(at <sha>)` after the old `app.js:675`; that keeps the
// exact shape E11 (cloud/priv/static/__css_check.mjs) bans. The written form
// drops the `:` — filename, space, `(` — so neither branch of E11's alternation
// can bind, and the line number rides behind `L`. The grammar, the verification
// and the E11 proof live in scripts/file-line-citation-check.mjs (--selftest
// arm 18 runs E11's own exported function over it). The thing written is the
// LOCAL token that landed at the pinned version — the same token the checker
// will then look for, and nothing else on the line.
//
// ── THE LOCAL ANCHOR — the classifier's stricter test ─────────────────────────
//
// The checker scrapes anchors from the WHOLE charter line, so a 60-token row
// resolves if any one word lands in a +/-3 window (over-credit). The classifier
// uses a LOCAL anchor set instead — subjectOf() below: tokens from the backtick
// span that CONTAINS the citation, else the spans and quotes beside it (nearest
// span ending within 80 chars before, nearest starting within 40 after, quotes
// in the same window), ranked by distance; a directory prefix is never one.
// The pin names the nearest candidate that lands. A pin is proposed when a local
// token lands at the pinned version under the checker's OWN pin test — thingRe()
// of the exact thing the pin will name, in windowOf() — and nothing else. The
// checker verifies a pin by its named thing alone and strips pins before it
// builds whole-line anchors, so requiring the whole-line anchors to land too
// (the rule until task-d4448021560b99c5) tested something the checker never
// asks, and sent quote-subject citations sitting EXACTLY on their line to
// BLOCK-NEAR (#20145's L447: `"seven fleet ticks after one boot"` at d=0).
//
// ── DATING — which version a citation is checked against ─────────────────────
//
// Each citation is dated by the charter commit that INTRODUCED ITS OWN TEXT,
// never by the last edit to the line it sits on. A pin rewrites a line, so
// dating by `git blame` of the line (the rule until task-d4448021560b99c5)
// moved every UNPINNED sibling on it to the pin commit and re-bucketed it:
// #20145 measured three moves from pinning alone. The dating now replays the
// charter's first-parent history (`git log -p -U0`) and carries each
// `<file>:<N>` occurrence through every commit that rewrites its line: an
// occurrence on an added line INHERITS the date of an unconsumed removed
// occurrence of the same token in the same commit (same hunk first, then by
// surrounding text), and is NEW — dated to that commit — only when none
// exists. A pin removes exactly its own token, so it cannot move a sibling's
// date. Uncommitted edits are replayed last and dated "now". The replay must
// reproduce the working charter byte-for-byte or the run exits 2 (UNCHECKED).
//
// ── BUCKETS ───────────────────────────────────────────────────────────────────
//   R-LOCAL      checker resolves at HEAD and a LOCAL token lands too
//   R-FOREIGN    checker resolves at HEAD only via a token NOT in the local set
//                (over-credit suspects — the resolved-side audit samples these)
//   R-NO-LOCAL   checker resolves at HEAD; no local subject to test it by
//   PIN-EXACT    local set lands at the version current when the citation's
//                own text was written (see DATING) -> pin there
//   PIN-OLDER    lands only at an OLDER version, within --depth versions
//                (cited from a stale base)
//   PIN-NEWER    lands only at a NEWER version, within --ahead versions (cited
//                from a base carrying siblings that merged after the charter)
//   PIN-WEAK     would pin, but the crediting token occurs >= --weak times in the
//                pinned file: a generic word, so the pin is not evidence -> hand
//                (default 10; was > 25 until the lead's ruling on #20128: a pin
//                records "verified at sha", so pinning a word common enough to
//                land by chance — `index` landing on `o.index` — makes a false
//                citation look confirmed)
//   NO-LOCAL     no backticked subject and no quoted sentence near the citation
//                -> hand (no rule can pick the subject out of prose)
//   BLOCK-NEAR   the local subject sits <= 40 lines off at the dated version
//                (cites a block body, or an off-main base) -> hand
//   FAR          the local subject sits > 40 lines off -> hand
//   ABSENT-THEN  no local token exists anywhere in the dated file -> hand
//   UNDECIDABLE  no backticked anchor on the line (the checker skips it too)
// RESIDUE = PIN-WEAK + NO-LOCAL + BLOCK-NEAR + FAR + ABSENT-THEN. Per the lead's
// ruling the hand pass is capped (--cap, default 30): over the cap this exits 1
// with a STOP verdict and --apply refuses to touch the charter, so the residue is
// split into rows instead of being waved through by a tired reader.
// Pins are proposed for resolved citations too: a resolved citation in a dated
// record rots on the next insertion above it.
//
// ── USAGE ─────────────────────────────────────────────────────────────────────
//   node scripts/file-line-citation-classify.mjs                # buckets + samples
//   node scripts/file-line-citation-classify.mjs --residue      # every residue row
//   node scripts/file-line-citation-classify.mjs --apply        # write the pins
//   node scripts/file-line-citation-classify.mjs --apply --only PIN-EXACT,PIN-OLDER,PIN-NEWER
//        write ONLY the named buckets. When every named bucket is rule-pinnable
//        (PIN-EXACT / PIN-OLDER / PIN-NEWER) the residue cap does not gate the
//        write: the cap bounds HAND work, and these buckets are settled by rule.
//        The residue is left untouched either way.
//   node scripts/file-line-citation-classify.mjs --json
//   node scripts/file-line-citation-classify.mjs --subject '447:__app.test.mjs:328="seven fleet ticks"'
//        a hand-named subject for ONE citation (<charter line>:<file>:<N>=<thing>,
//        repeatable; "quoted" = literal substring) — replaces its local set, so
//        the classifier dates and verifies what a reader chose. A --subject that
//        matches no citation exits 2.
//   node scripts/file-line-citation-classify.mjs --selftest
//   [--root D] [--charter P] [--map base=path]... [--depth K] [--ahead K] [--weak K] [--cap N] [--slack K]
//   exit 0 residue <= cap · 1 residue > cap (STOP) · 2 bad argument / UNCHECKED
//
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";

const MIN_TOKEN = 4;
const STOP = new Set([
  "const", "function", "return", "async", "await", "class", "this", "null",
  "true", "false", "undefined", "typeof", "instanceof", "import", "export",
  "default", "break", "continue", "throw", "catch", "finally", "else",
  "case", "switch", "while", "document", "window", "console", "value",
  "length", "push", "then", "data", "text", "json", "html", "http",
  "https", "type", "name", "node", "item", "list", "void",
]);
// The pin form — must mirror PIN_ANY in scripts/file-line-citation-check.mjs.
const PIN_RE = /\b[\w.-]+\.[A-Za-z0-9]+ \(([^@()\n]+?) @ ([0-9a-f]{7,40}), L(\d+)(?:[-\u2013]L?(\d+))?\)/g;
const RULE_PINNABLE = new Set(["PIN-EXACT", "PIN-OLDER", "PIN-NEWER"]);

// ── THE ADJACENCY RULE, exported ─────────────────────────────────────────────
// tokensOf / spansOf / quotesNear / subjectOf are the ONE definition of "the
// subject adjacent to a citation". scripts/file-line-citation-check.mjs imports
// subjectOf() to credit an unpinned citation only by its adjacent subject, so
// the checker and the classifier cannot drift apart. They read only the
// constants above; everything that parses argv, runs git or exits sits behind
// IS_MAIN.
export const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

// A directory component is where a file LIVES, never what a citation names:
// `cloud/priv/static/__app.test.mjs:1585` cites __app.test.mjs, and `cloud`,
// `priv` and `static` are not its subject. Every `<segment>/` is blanked before
// a span is tokenized, so a path contributes at most its last segment (a file
// name, which the own-name filter then drops for the cited file itself).
// Until task-c99f9579606babbd the prefix was tokenized like any other word, and
// `cloud` became the subject of #20145's L575 (22 lines off). --selftest ARM 7.
// A `/` followed by a bare number is an ARITY (`crash_slug/2`,
// `Sites.Deploy.rollback/2`), not a directory, and is kept.
const PATH_DIRS = /(?:[A-Za-z0-9_.$-]+\/(?!\d+\b))+/g;

export function tokensOf(span, base, keepHyphen) {
  const own = new Set(base.toLowerCase().split(/[^a-z0-9]+/i).filter(Boolean));
  const out = new Set();
  span = span.replace(PATH_DIRS, " ");
  const parts = keepHyphen ? span.split(/[^A-Za-z0-9_$-]+/).flatMap((t) => [t, ...t.split("-")]) : span.split(/[^A-Za-z0-9_$]+/);
  for (let tok of parts) {
    tok = tok.replace(/^-+|-+$/g, "");
    if (tok.length < MIN_TOKEN) continue;
    if (/^[0-9-]+$/.test(tok)) continue;
    if (/^[0-9a-f]{7,40}$/.test(tok)) continue; // a sha is provenance, not a subject
    if (STOP.has(tok.toLowerCase())) continue;
    if (own.has(tok.toLowerCase().replace(/^_+/, ""))) continue;
    out.add(tok);
  }
  return [...out];
}

export function spansOf(text) {
  const spans = [];
  let i = 0;
  while (true) {
    const a = text.indexOf("`", i); if (a < 0) break;
    const b = text.indexOf("`", a + 1); if (b < 0) break;
    spans.push({ s: a, e: b + 1, body: text.slice(a + 1, b) });
    i = b + 1;
  }
  return spans;
}

// A quote's matchable text: its first 24 chars, cut at an ellipsis. A quote
// that names a cited file is a citation, not a subject.
function quoteSubject(raw, min) {
  const q = raw.replace(/[\u2026].*$/, "").replace(/\.\.\..*$/, "").slice(0, 24);
  if (q.length < min || /app\.(js|css)|\.mjs|index\.html/.test(q)) return null;
  return { label: `"${q}"`, re: new RegExp(esc(q)) };
}
const QUOTE = /["\u201c]([^"\u201d]{4,})["\u201d]/g;

// FALLBACK only: a quoted sentence (>= 12 chars) anywhere within 140 chars,
// used when no backtick span or quote sits in the adjacency window. The
// charter often cites copy ("Only the team owner can manage billing.") rather
// than a symbol.
export function quotesNear(text, p, e) {
  const win = text.slice(Math.max(0, p - 140), e + 140);
  const out = [];
  for (const m of win.matchAll(QUOTE)) {
    const q = m[1].length >= 12 ? quoteSubject(m[1], 12) : null;
    if (q) out.push(q);
  }
  return out;
}

// THE SUBJECT of the citation at [p, e) on a charter line, NEAREST FIRST.
//   1. The backtick span CONTAINING the citation, if it names anything once its
//      path prefix and the cited file's own words are dropped (`makeWidget
//      widget.js:30`): that span is the subject, alone.
//   2. Else every candidate in the adjacency window — the nearest span ending
//      <= 80 chars before, the nearest span starting <= 40 chars after, and each
//      quote (>= 8 chars) ending <= 80 before or starting <= 40 after — ranked
//      by DISTANCE, a span before a quote on a tie.
//   3. Else quotesNear()'s 140-char fallback.
// Until task-c99f9579606babbd a quote was read only when no span existed, so a
// backticked span beat a quote beside the citation at ANY distance (#20145's
// L4743: `operatorRowState` 23 lines off won over "Autoupdate off" on the cited
// line). The checker credits a citation if ANY candidate lands; the classifier
// pins the nearest candidate that lands. --selftest ARMS 8 and 9.
// Returns tokens as strings and quotes as { label, re }.
export function subjectOf(text, base, p, e) {
  const spans = spansOf(text);
  const keepHyphen = base.endsWith(".css") || base.endsWith(".html");
  const toksOf = (sp) => tokensOf(sp.body.replace(PIN_RE, " "), base, keepHyphen);
  const inside = spans.find((sp) => sp.s < p && sp.e > e);
  if (inside) {
    const own = toksOf(inside);
    if (own.length) return own;
  }
  const cands = [];
  const before = spans.filter((sp) => sp.e <= p && p - sp.e <= 80 && sp !== inside).pop();
  const after = spans.find((sp) => sp.s >= e && sp.s - e <= 40);
  if (before) for (const t of toksOf(before)) cands.push({ d: p - before.e, sub: t });
  if (after) for (const t of toksOf(after)) cands.push({ d: after.s - e, sub: t });
  for (const m of text.matchAll(QUOTE)) {
    const s = m.index, qe = m.index + m[0].length;
    const d = qe <= p ? p - qe : s >= e ? s - e : null;
    if (d === null || (qe <= p && d > 80) || (s >= e && d > 40)) continue;
    // a quote inside a backtick span is code, not copy — the span already
    // speaks; a "quote" holding a backtick paired across a span, not copy
    if (m[1].includes("`") || spans.some((sp) => sp.s < s && sp.e > qe)) continue;
    const q = quoteSubject(m[1], 8);
    if (q) cands.push({ d, sub: q });
  }
  if (cands.length) {
    const seen = new Set();
    return cands.map((c, i) => ({ ...c, i })).sort((a, b) => a.d - b.d || a.i - b.i)
      .map((c) => c.sub).filter((x) => { const k = x.label || x; if (seen.has(k)) return false; seen.add(k); return true; });
  }
  return quotesNear(text, p, e);
}

// ── DEFINITION, NOT USE (task-eb534ada6569c7da) ──────────────────────────────
// A citation of a FUNCTION (or a CSS RULE) cites where it is defined. Matching
// its bare name credited a use: charter L677's pin `app.js (tokenRow @
// 55513d908f, L3462)` verified on the call site `list.map(tokenRow)` at 3464
// while `function tokenRow` sat at 3472. So a thing is matched by its
// DEFINITION when the file version being read defines it, and by its name
// otherwise.
//
// IS IT A FUNCTION? Decided per file version, by the file itself: a thing is a
// function (or a CSS rule) there when at least one line of that version is a
// definition of it —
//   JS (.js, .mjs, .html):  function NAME(   NAME = function   NAME: function
//                           NAME = (...) =>  NAME = arg =>     class NAME
//                           a method head at line start: NAME(...) {
//   CSS (.css):             a selector head holding the thing — the thing sits
//                           before the line's first `{`, and the line opens a
//                           block or ends a selector-list line with `,`; not a
//                           comment line, not a `property: value` line.
// A thing with no definition anywhere in that version — a string literal, a
// variable, an element id, a CSS property or custom property, a "quoted"
// thing — keeps whole-name (or substring) matching. A NAME must look like an
// identifier (JS) or a selector token (CSS) to be tested at all.

// The pin test's name match — must mirror thingRe() in the checker: "quoted"
// -> literal substring, else a whole word where `-` is a word character.
export function nameRe(thing) {
  const q = thing.match(/^["\u201c](.+)["\u201d]$/);
  if (q) return new RegExp(esc(q[1]));
  return new RegExp(`(^|[^A-Za-z0-9_$-])${esc(thing)}([^A-Za-z0-9_$-]|$)`);
}

// A predicate "is this CODE line a definition of thing?", or null when the
// thing cannot have one (quoted, or not identifier/selector shaped). It is
// asked of codeLines() — comments blanked — never of the raw line: a comment
// saying "a class that has no rule" is not `class that`, and a CSS comment
// line ending in `,` is not a selector list.
export function definitionTest(thing, base) {
  if (/^["“]/.test(thing)) return null;
  if (base.endsWith(".css")) {
    if (!/^[.#]?-{0,2}[A-Za-z_][\w-]*$/.test(thing)) return null;
    // A class or id selector: the thing as written when it carries its `.`/`#`,
    // else preceded by one — `topbar` is defined by `.topbar {`, not by
    // `grid-area: topbar` or `@media (width ...)`.
    const at = /^[.#]/.test(thing)
      ? new RegExp(`(^|[^A-Za-z0-9_$-])${esc(thing)}(?![A-Za-z0-9_$-])`)
      : new RegExp(`[.#]${esc(thing)}(?![A-Za-z0-9_$-])`);
    return (code) => {
      const t = code.trim();
      if (t.startsWith("@") || /^[\w-]+\s*:\s/.test(t)) return false;
      const brace = t.indexOf("{");
      if (brace < 0 && !/,$/.test(t)) return false;
      return at.test(brace < 0 ? t : t.slice(0, brace));
    };
  }
  if (!/^[A-Za-z_$][\w$]*$/.test(thing)) return null;
  const n = esc(thing);
  const res = [
    new RegExp(`\\bfunction\\s*\\*?\\s*${n}\\s*\\(`),
    new RegExp(`(^|[^\\w$.])${n}\\s*[:=]\\s*(async\\s+)?function\\b`),
    new RegExp(`(^|[^\\w$.])${n}\\s*[:=]\\s*(async\\s*)?(\\([^()]*\\)|[A-Za-z_$][\\w$]*)\\s*=>`),
    new RegExp(`^\\s*((async|static|get|set)\\s+)*${n}\\s*\\([^()]*\\)\\s*\\{`),
    new RegExp(`\\bclass\\s+${n}\\b`),
  ];
  return (code) => res.some((r) => r.test(code));
}

// The file with comments blanked (same line count, same line numbers): block
// comments across lines, and `//` line comments in JS. Quotes are tracked
// within a line so a `/*` or `//` inside a string is not a comment.
const codeCache = new WeakMap();
function codeLines(fileLines, base) {
  if (codeCache.has(fileLines)) return codeCache.get(fileLines);
  const css = base.endsWith(".css");
  const out = [];
  let inBlock = false;
  for (const line of fileLines) {
    let o = "", q = null;
    for (let i = 0; i < line.length; i++) {
      const ch = line[i], nx = line[i + 1];
      if (inBlock) { if (ch === "*" && nx === "/") { inBlock = false; i++; o += "  "; } else o += " "; continue; }
      if (q) { o += ch; if (ch === "\\" && i + 1 < line.length) { o += nx; i++; } else if (ch === q) q = null; continue; }
      if (ch === "/" && nx === "*") { inBlock = true; i++; o += "  "; continue; }
      if (!css && ch === "/" && nx === "/") break;
      if (ch === '"' || ch === "'" || ch === "`") q = ch;
      o += ch;
    }
    out.push(o);
  }
  codeCache.set(fileLines, out);
  return out;
}

// The ONE line matcher for a named thing in ONE file version (an array of
// lines): { test(line, index), kind() }, index 0-based into that array. When
// the version DEFINES the thing (kind() "definition") only a definition line
// matches; otherwise (kind() "name") any whole-name occurrence does. The
// whole-file "does it define it?" scan runs only when a name hit is not itself
// a definition, and is cached per (file version, thing).
const defCache = new WeakMap();
export function thingMatcher(thing, base, fileLines) {
  const name = nameRe(thing);
  const def = definitionTest(thing, base);
  const isDef = (k) => { const code = codeLines(fileLines, base)[k]; return name.test(code) && def(code); };
  const defines = () => {
    if (!def) return false;
    let m = defCache.get(fileLines);
    if (!m) { m = new Map(); defCache.set(fileLines, m); }
    const key = `${base}\0${thing}`;
    if (!m.has(key)) m.set(key, fileLines.some((l, k) => name.test(l) && isDef(k)));
    return m.get(key);
  };
  return {
    test: (line, k) => {
      if (line === undefined || !name.test(line)) return false;
      if (!def) return true;
      if (k === undefined) throw new Error("thingMatcher.test needs the line index");
      return isDef(k) || !defines();
    },
    kind: () => (defines() ? "definition" : "name"),
  };
}

// Run the CLI only when executed directly (`node file-line-citation-classify.mjs`),
// never on import: the checker imports the four functions above, and an import
// that parsed the checker's argv, ran git blame and called process.exit would
// kill the importing process.
const IS_MAIN = (() => {
  try { return !!process.argv[1] && fs.realpathSync(process.argv[1]) === fs.realpathSync(fileURLToPath(import.meta.url)); }
  catch { return false; }
})();
if (IS_MAIN) {
// (the CLI body below is deliberately NOT re-indented, so the diff stays reviewable)


const o = { charter: ".claude/workflows/bp-cloud-console-hardening-charter.md", maps: [],
  depth: 80, ahead: 20, slack: 3, weak: 10, cap: 30, apply: false, json: false, residue: false, only: null,
  root: null, subjects: [], selftest: false };
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  const need = () => argv[++i];
  if (a === "--charter") o.charter = need();
  else if (a === "--root") o.root = need();
  else if (a === "--selftest") o.selftest = true;
  else if (a === "--subject") {
    const m = String(need() || "").match(/^(\d+):([^=]+)=(.+)$/);
    if (!m) { process.stderr.write("UNCHECKED: --subject wants <charter line>:<file>:<N>=<thing>\n"); process.exit(2); }
    o.subjects.push({ line: Number(m[1]), cite: m[2], thing: m[3], used: false });
  }
  else if (a === "--map") o.maps.push(need());
  else if (a === "--depth") o.depth = Number(need());
  else if (a === "--ahead") o.ahead = Number(need());
  else if (a === "--cap") o.cap = Number(need());
  else if (a === "--weak") o.weak = Number(need());
  else if (a === "--slack") o.slack = Number(need());
  else if (a === "--apply") o.apply = true;
  else if (a === "--json") o.json = true;
  else if (a === "--residue") o.residue = true;
  else if (a === "--only") o.only = new Set(String(need() || "").split(",").map((x) => x.trim()).filter(Boolean));
  else { process.stderr.write(`UNCHECKED: unknown argument ${a}\n`); process.exit(2); }
}
if (o.maps.length === 0) {
  o.maps = ["app.js=cloud/priv/static/app.js", "app.css=cloud/priv/static/app.css",
    "index.html=cloud/priv/static/index.html", "__app.test.mjs=cloud/priv/static/__app.test.mjs"];
}

if (o.selftest) process.exit(selftest());

const git = (args, opts = {}) => execFileSync("git", o.root ? ["-C", o.root, ...args] : args,
  { encoding: "utf8", maxBuffer: 1 << 30, ...opts });
const root = git(["rev-parse", "--show-toplevel"]).trim();
const charterPath = path.resolve(root, o.charter);
const charterRel = path.relative(root, charterPath);
const charterText = fs.readFileSync(charterPath, "utf8");
const lines = charterText.split("\n");

const targets = new Map();
for (const spec of o.maps) {
  const eq = spec.indexOf("=");
  const base = spec.slice(0, eq);
  const rel = spec.slice(eq + 1);
  targets.set(base, { rel, head: fs.readFileSync(path.resolve(root, rel), "utf8").split("\n") });
}

const checkerWordRe = (tok) => new RegExp(`(^|[^A-Za-z0-9_$])${esc(tok)}([^A-Za-z0-9_$]|$)`);


// The checker's own anchor set (whole line, pins stripped) — must mirror
// anchorsOf() in file-line-citation-check.mjs.
function lineAnchors(text, base) {
  const out = new Set();
  // A pin is replaced by a SPACE, never removed: removing it from inside a
  // backtick span leaves an empty `` pair, which `([^`]+)` skips, and every
  // later span on the line then pairs the wrong backticks.
  for (const m of text.replace(PIN_RE, " ").matchAll(/`([^`]+)`/g)) for (const t of tokensOf(m[1], base, false)) out.add(t);
  return [...out];
}



// ── parse ────────────────────────────────────────────────────────────────────
const alt = [...targets.keys()].map(esc).join("|");
const CITE = new RegExp(`\\b(${alt}):(\\d+)(?:[-–](\\d+))?`, "g");
const PINNED = new RegExp(`(?<![\\w.-])(${alt}) \\(([^@()\\n]+?) @ ([0-9a-f]{7,40}), L(\\d+)(?:[-\u2013]L?(\\d+))?\\)`, "g");
const cites = [];
lines.forEach((text, idx) => {
  let k = 0;
  for (const m of text.matchAll(CITE)) {
    const n = Number(m[2]);
    const hi = m[3] ? Number(m[3]) : n;
    const end = m.index + m[0].length;
    cites.push({ base: m[1], n, hi: hi >= n ? hi : n, charterLine: idx + 1, text, p: m.index, e: end, pin: null, k: k++ });
  }
  for (const m of text.matchAll(PINNED)) {
    const n = Number(m[4]);
    const hi = m[5] && Number(m[5]) >= n ? Number(m[5]) : n;
    cites.push({ base: m[1], n, hi, charterLine: idx + 1, text, p: m.index, e: m.index + m[0].length, pin: m[3] });
  }
});

// A range is its own tolerance (no slack), a single line gets +/-slack — the
// checker's windowOf(), so a pin this writes is one the checker accepts.
// `mk(tok, fileLines)` builds the line test for a string token; a quote object
// carries its own `re`. The pin test is thingMatcher() (definition, not use).
const byThing = (base) => (tok, fl) => thingMatcher(tok, base, fl);
function lands(fileLines, c, toks, mk) {
  const lo = c.hi !== c.n ? Math.max(1, c.n) : Math.max(1, c.n - o.slack);
  const hi = c.hi !== c.n ? Math.min(fileLines.length, c.hi) : Math.min(fileLines.length, c.n + o.slack);
  for (const tok of toks) {
    const r = typeof tok === "object" ? tok.re : mk(tok, fileLines);
    const name = typeof tok === "object" ? tok.label : tok;
    for (let k = lo; k <= hi; k++) if (r.test(fileLines[k - 1], k - 1)) return { tok: name, at: k, re: r };
  }
  return null;
}

const countIn = (fl, r) => fl.reduce((n, l, k) => n + (r.test(l, k) ? 1 : 0), 0);

// ── dating: when was each citation's OWN text written? (see DATING above) ────
// Replays the charter's first-parent history as -U0 diffs, carrying each
// `<file>:<N>` occurrence across line rewrites. dateOf(line, k) answers for the
// k-th citation token on a working-charter line.
const occRe = () => new RegExp(CITE.source, "g");
function occurrences(text, date) {
  return [...text.matchAll(occRe())].map((m) => ({ tok: m[0], p: m.index, date }));
}
// Tiebreak between same-token candidates: shared text either side (<= 40 chars).
function contextScore(aText, a, bText, b) {
  let s = 0;
  for (let i = 1; i <= 40 && a.p - i >= 0 && b.p - i >= 0 && aText[a.p - i] === bText[b.p - i]; i++) s++;
  const ae = a.p + a.tok.length, be = b.p + b.tok.length;
  for (let i = 0; i < 40 && ae + i < aText.length && be + i < bText.length && aText[ae + i] === bText[be + i]; i++) s++;
  return s;
}
function applyDiff(cur, diffText, date) {
  const hunks = [];
  let h = null, left = 0, right = 0;
  for (const l of diffText.split("\n")) {
    if (h && (left > 0 || right > 0)) {
      if (l.startsWith("-") && left > 0) { h.removed.push(l.slice(1)); left--; continue; }
      if (l.startsWith("+") && right > 0) { h.added.push(l.slice(1)); right--; continue; }
      if (l.startsWith("\\")) continue;
    }
    const m = l.match(/^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/);
    if (m) {
      h = { a: Number(m[1]), b: m[2] === undefined ? 1 : Number(m[2]), removed: [], added: [] };
      left = h.b; right = m[4] === undefined ? 1 : Number(m[4]);
      hunks.push(h);
    }
  }
  if (hunks.length === 0) return cur;
  // Pool every removed occurrence in the commit, tagged with its hunk.
  const pool = [];
  hunks.forEach((hk, hi) => {
    const start = hk.b === 0 ? hk.a : hk.a - 1;
    for (let j = 0; j < hk.b; j++) {
      const old = cur[start + j];
      for (const oc of old.occ) pool.push({ ...oc, text: old.text, hunk: hi, used: false });
    }
  });
  const out = [];
  let ptr = 0;
  hunks.forEach((hk, hi) => {
    const start = hk.b === 0 ? hk.a : hk.a - 1;
    while (ptr < start) out.push(cur[ptr++]);
    ptr += hk.b;
    for (const text of hk.added) {
      const occ = occurrences(text, date);
      for (const oc of occ) {
        let best = null, bestScore = -1;
        for (const cand of pool) {
          if (cand.used || cand.tok !== oc.tok) continue;
          const sc = (cand.hunk === hi ? 1000 : 0) + contextScore(text, oc, cand.text, cand);
          if (sc > bestScore) { best = cand; bestScore = sc; }
        }
        if (best) { best.used = true; oc.date = best.date; }
      }
      out.push({ text, occ });
    }
  });
  while (ptr < cur.length) out.push(cur[ptr++]);
  return out;
}
const dateOf = (() => {
  let cur = [];
  const log = git(["log", "--first-parent", "--diff-merges=first-parent", "--reverse", "-p", "-U0", "--no-color",
    "--no-ext-diff", "--no-renames", "--format=%x00%H %ct", "HEAD", "--", charterRel]);
  for (const chunk of log.split("\0").slice(1)) {
    const nl = chunk.indexOf("\n");
    const [sha, t] = chunk.slice(0, nl < 0 ? chunk.length : nl).split(" ");
    cur = applyDiff(cur, nl < 0 ? "" : chunk.slice(nl + 1), { sha, time: Number(t) });
  }
  cur = applyDiff(cur, git(["diff", "-U0", "--no-color", "--no-ext-diff", "--no-renames", "HEAD", "--", charterRel]),
    { sha: "WORKTREE", time: Math.floor(Date.now() / 1000) });
  const want = charterText.endsWith("\n") ? lines.slice(0, -1) : lines;
  const bad = want.length !== cur.length ? `line count ${cur.length} vs ${want.length}`
    : (() => { const k = want.findIndex((t, i) => t !== cur[i].text); return k < 0 ? null : `line ${k + 1} differs`; })();
  if (bad) {
    process.stderr.write(`UNCHECKED: the dating replay of ${charterRel} does not reproduce the working charter (${bad}); no date is trustworthy.\n`);
    process.exit(2);
  }
  return (line, k) => cur[line - 1].occ[k].date;
})();

// ── versions of each target on HEAD's first-parent line, newest first ────────
const versionCache = new Map();
function versions(rel) {
  if (!versionCache.has(rel)) {
    const out = git(["log", "--first-parent", "--format=%H %ct", "HEAD", "--", rel]).trim().split("\n");
    versionCache.set(rel, out.map((l) => { const [sha, t] = l.split(" "); return { sha, time: Number(t) }; }));
  }
  return versionCache.get(rel);
}
const blobCache = new Map();
function blob(sha, rel) {
  const k = `${sha}:${rel}`;
  if (!blobCache.has(k)) {
    try { blobCache.set(k, git(["show", k], { stdio: ["ignore", "pipe", "ignore"] }).split("\n")); }
    catch { blobCache.set(k, null); }
  }
  return blobCache.get(k);
}

// ── classify ─────────────────────────────────────────────────────────────────
for (const c of cites) {
  const t = targets.get(c.base);
  c.lineAnchors = lineAnchors(c.text, c.base);
  c.local = subjectOf(c.text, c.base, c.p, c.e);
  if (!c.pin) {
    const label = `${c.base}:${c.n}${c.hi !== c.n ? "-" + c.hi : ""}`;
    for (const s of o.subjects) if (s.line === c.charterLine && s.cite === label) {
      s.used = true;
      const q = s.thing.match(/^["\u201c](.+)["\u201d]$/);
      c.local = [q ? { label: s.thing, re: new RegExp(esc(q[1])) } : s.thing];
    }
  }
  c.decidable = c.lineAnchors.length > 0;
  if (c.pin) { c.bucket = "ALREADY-PINNED"; continue; }
  const headHit = c.decidable ? lands(t.head, c, c.lineAnchors, checkerWordRe) : null;
  c.headResolved = !!headHit;
  c.credit = headHit;
  const localHead = c.local.length ? lands(t.head, c, c.local, byThing(c.base)) : null;
  if (!c.decidable) { c.bucket = "UNDECIDABLE"; continue; }
  if (c.local.length === 0) { c.bucket = c.headResolved ? "R-NO-LOCAL" : "NO-LOCAL"; continue; }

  // pin search: newest version at or before the commit that wrote THIS
  // citation's text (DATING), walking older.
  c.dated = dateOf(c.charterLine, c.k);
  const vs = versions(t.rel);
  let start = vs.findIndex((v) => v.time <= c.dated.time);
  if (start < 0) start = vs.length;
  let pin = null;
  // The checker's pin test for the exact thing the pin will name: a quote as a
  // literal, anything else by thingMatcher() (definition, not use).
  const pinCandidates = c.local.map((tok) => (typeof tok === "object" ? tok.label : tok));
  const order = [];
  for (let d = 0; d < o.depth; d++) {
    if (start + d < vs.length) order.push(start + d);
    if (d > 0 && d <= o.ahead && start - d >= 0) order.push(start - d);
  }
  for (const k of order) {
    const fl = blob(vs[k].sha, t.rel);
    if (!fl) continue;
    // The checker's pin test, and only it (see THE LOCAL ANCHOR).
    const lh = lands(fl, c, pinCandidates, byThing(c.base));
    if (!lh) continue;
    pin = { sha: vs[k].sha, back: k - start, tok: lh.tok, at: lh.at, freq: countIn(fl, lh.re) };
    break;
  }
  c.pinTo = pin;
  if (c.headResolved) {
    c.bucket = localHead ? "R-LOCAL" : "R-FOREIGN";
  } else if (pin && pin.freq >= o.weak) {
    c.bucket = "PIN-WEAK";
  } else if (pin) {
    c.bucket = pin.back === 0 ? "PIN-EXACT" : pin.back > 0 ? "PIN-OLDER" : "PIN-NEWER";
  } else {
    // shape the residue: how close did the local set EVER come, at the dated version?
    const fl = blob(vs[Math.min(start, vs.length - 1)].sha, t.rel) || t.head;
    let best = null;
    for (const tok of c.local) {
      const r = typeof tok === "object" ? tok.re : thingMatcher(tok, c.base, fl);
      for (let k = 1; k <= fl.length; k++) if (r.test(fl[k - 1], k - 1)) {
        const d = k < c.n ? c.n - k : (k > c.hi ? k - c.hi : 0);
        if (!best || d < best.d) best = { tok: typeof tok === "object" ? tok.label : tok, at: k, d };
      }
    }
    c.near = best;
    c.bucket = !best ? "ABSENT-THEN" : best.d <= 40 ? "BLOCK-NEAR" : "FAR";
  }
  c.localHead = localHead;
}
{
  const unused = o.subjects.filter((x) => !x.used);
  if (unused.length) {
    process.stderr.write("UNCHECKED: --subject matched no unpinned citation: " + unused.map((x) => `${x.line}:${x.cite}`).join(", ") + "\n");
    process.exit(2);
  }
}

// ── report ───────────────────────────────────────────────────────────────────
const RULES = {
  "R-LOCAL": "resolves at HEAD by a local token; pinned (at the dated version) so it cannot rot",
  "R-FOREIGN": "checker credits it at HEAD by a NON-local token (over-credit suspect); pinned if the local set lands historically",
  "R-NO-LOCAL": "checker credits it at HEAD; no local anchor, so no rule can pin it -> left unpinned",
  "PIN-EXACT": "local set lands at the version current when the line was written -> rewrite to <file> (<thing> @ <sha>, L<n>)",
  "PIN-OLDER": "local set lands only at an older version (cited on a stale base) -> rewrite to <file> (<thing> @ <sha>, L<n>)",
  "PIN-NEWER": `local set lands only at a NEWER version (<=${o.ahead}; cited from a base carrying unmerged siblings) -> rewrite to <file> (<thing> @ <sha>, L<n>)`,
  "PIN-WEAK": `would pin, but the crediting local token occurs >= ${o.weak} times in the pinned file (generic word) -> RESIDUE (hand)`,
  "NO-LOCAL": "no backticked subject and no quoted sentence near the citation -> RESIDUE (hand)",
  "BLOCK-NEAR": "local set never lands in +/-slack, but sits <=40 lines off at the dated version (cites a block body, or a sibling base) -> RESIDUE (hand)",
  "FAR": "local set sits >40 lines off at the dated version -> RESIDUE (hand)",
  "ABSENT-THEN": "no local token exists anywhere in the dated file (prose word, other file, or later rename) -> RESIDUE (hand)",
  "UNDECIDABLE": "no backticked anchor on the line at all (checker does not count it)",
  "ALREADY-PINNED": "already in the pin form <file> (<thing> @ <sha>, L<n>)",
};
const order = Object.keys(RULES);
const shortSha = (s) => s.slice(0, 10);
const byBucket = new Map(order.map((k) => [k, []]));
for (const c of cites) byBucket.get(c.bucket).push(c);

// The pinned thing is written INTO the citation, so it must survive the pin
// grammar: no `(`, `)`, `@` or newline. A token that cannot is left unpinned
// and counted (THING-UNWRITABLE), never mangled.
const writableThing = (t) => !/[()@\n]/.test(t);
function withPin(c) {
  if (!c.pinTo || c.bucket === "PIN-WEAK" || (c.bucket.startsWith("R-") && c.pinTo.freq >= o.weak)) return null;
  if (!writableThing(c.pinTo.tok)) return null;
  const range = c.hi !== c.n ? `L${c.n}-${c.hi}` : `L${c.n}`;
  return { at: c.p, end: c.e, str: `${c.base} (${c.pinTo.tok} @ ${shortSha(c.pinTo.sha)}, ${range})` };
}
const excerpt = (s, a, b) => s.slice(Math.max(0, a), b).replace(/\s+/g, " ");

if (o.json) {
  process.stdout.write(JSON.stringify(cites.map((c) => ({
    cite: `${c.base}:${c.n}${c.hi !== c.n ? "-" + c.hi : ""}`, charterLine: c.charterLine, bucket: c.bucket,
    local: c.local, credit: c.credit, localHead: c.localHead, pin: c.pinTo,
    dated: c.dated || null, near: c.near || null,
  })), null, 1) + "\n");
} else {
  process.stdout.write(`FILE:LINE CITATION CLASSIFIER — ${charterRel}\n`);
  process.stdout.write(`  citations parsed: ${cites.length}  (targets: ${[...targets.keys()].join(", ")}; depth ${o.depth}; slack +/-${o.slack})\n\n`);
  process.stdout.write("  bucket         " + [...targets.keys()].map((b) => b.padStart(15)).join("") + "     total\n");
  for (const k of order) {
    const row = byBucket.get(k);
    if (!row.length) continue;
    process.stdout.write(`  ${k.padEnd(15)}` + [...targets.keys()].map((b) => String(row.filter((c) => c.base === b).length).padStart(15)).join("") + String(row.length).padStart(10) + "\n");
  }
  const unresolvedHead = cites.filter((c) => c.decidable && !c.pin && !c.headResolved);
  process.stdout.write(`\n  unresolved at HEAD (decidable, unpinned): ${unresolvedHead.length}\n`);
  const residue = cites.filter((c) => ["PIN-WEAK", "NO-LOCAL", "BLOCK-NEAR", "FAR", "ABSENT-THEN"].includes(c.bucket));
  process.stdout.write(`  RESIDUE (hand): ${residue.length}   ` + [...targets.keys()].map((b) => `${b}=${residue.filter((c) => c.base === b).length}`).join(" ") + "\n");
  for (const k of order) {
    const row = byBucket.get(k);
    if (!row.length) continue;
    process.stdout.write(`\n  == ${k} (${row.length}) — ${RULES[k]}\n`);
    for (const c of row.slice(0, 3)) {
      const w = withPin(c);
      process.stdout.write(`    L${c.charterLine} ${c.base}:${c.n}${c.hi !== c.n ? "-" + c.hi : ""} local=[${c.local.slice(0, 5).map((x) => x.label || x).join(",")}]` +
        (c.credit ? ` credit=${c.credit.tok}@${c.credit.at}` : "") + (c.pinTo ? ` pin=${shortSha(c.pinTo.sha)} (${c.pinTo.back} versions from dated, ${c.pinTo.tok}@${c.pinTo.at} x${c.pinTo.freq})` : "") + "\n");
      process.stdout.write(`      before: …${excerpt(c.text, c.p - 60, c.e + 30)}…\n`);
      if (w) {
        const after = c.text.slice(0, w.at) + w.str + c.text.slice(w.end);
        process.stdout.write(`      after : …${excerpt(after, c.p - 60, c.p + w.str.length + 30)}…\n`);
      }
    }
  }
  if (o.residue) {
    process.stdout.write("\n  --- RESIDUE, every row ---\n");
    for (const c of residue) {
      process.stdout.write(`  [${c.bucket}${c.near ? " " + c.near.tok + "@" + c.near.at + " d=" + c.near.d : ""}] L${c.charterLine} ${c.base}:${c.n}${c.hi !== c.n ? "-" + c.hi : ""} local=[${c.local.map((x) => x.label || x).join(",")}]\n      …${excerpt(c.text, c.p - 160, c.e + 80)}…\n`);
    }
  }
}

const residueN = cites.filter((c) => ["PIN-WEAK", "NO-LOCAL", "BLOCK-NEAR", "FAR", "ABSENT-THEN"].includes(c.bucket)).length;
if (o.only) {
  const unknown = [...o.only].filter((b) => !(b in RULES));
  if (unknown.length) { process.stderr.write(`UNCHECKED: --only names unknown bucket(s): ${unknown.join(", ")}\n`); process.exit(2); }
}
const ruleOnly = o.only && [...o.only].every((b) => RULE_PINNABLE.has(b));
if (residueN > o.cap && !(o.apply && ruleOnly)) {
  if (!o.json) process.stdout.write(`\nSTOP — residue ${residueN} exceeds the hand-adjudication cap ${o.cap}. Split it; do not apply.\n`);
  if (o.apply) process.stderr.write("REFUSED: --apply with residue over the cap writes nothing (unless --only names rule-pinnable buckets alone).\n");
  // exitCode, never process.exit(): stdout to a PIPE is asynchronous on macOS,
  // and exiting here cut --json at 64 KiB mid-string (seen building #20146).
  process.exitCode = 1;
} else if (o.apply) {
  const edits = new Map();
  const perBucket = new Map();
  const unwritable = [];
  for (const c of cites) {
    if (o.only && !o.only.has(c.bucket)) continue;
    const w = withPin(c);
    if (!w) { if (c.pinTo && RULE_PINNABLE.has(c.bucket)) unwritable.push(c); continue; }
    perBucket.set(c.bucket, (perBucket.get(c.bucket) || 0) + 1);
    if (!edits.has(c.charterLine)) edits.set(c.charterLine, []);
    edits.get(c.charterLine).push(w);
  }
  let n = 0;
  for (const [ln, ws] of edits) {
    let t = lines[ln - 1];
    for (const w of ws.sort((a, b) => b.at - a.at)) { t = t.slice(0, w.at) + w.str + t.slice(w.end); n++; }
    lines[ln - 1] = t;
  }
  fs.writeFileSync(charterPath, lines.join("\n"));
  process.stdout.write(`\nAPPLIED ${n} pin(s) across ${edits.size} charter line(s) in ${charterRel}` +
    (o.only ? ` (only: ${[...o.only].join(",")})` : "") + "\n");
  for (const [b, k] of perBucket) process.stdout.write(`  ${b.padEnd(15)} ${k}\n`);
  if (unwritable.length) {
    process.stdout.write(`  THING-UNWRITABLE ${unwritable.length} (rule-pinnable, but the thing holds ( ) @ or a newline — left unpinned):\n`);
    for (const c of unwritable) process.stdout.write(`    L${c.charterLine} ${c.base}:${c.n} thing=${c.pinTo.tok}\n`);
  }
}

// ── SELFTEST — a fixture git history per arm; each arm reds on the old rule ──
// DATING: arm 2 reds when a citation is dated by git blame of its LINE (arm 1
// is its positive control; arm 3 guards the working-tree replay, which blame of
// HEAD never saw). PIN SEARCH: arms 4 and 6 red when the pin search demands the
// whole-line anchors; arm 5 is the negative control (a subject off its line is
// still no pin).
function selftest() {
  const self = fileURLToPath(import.meta.url);
  const checker = path.join(path.dirname(self), "file-line-citation-check.mjs");
  let fails = 0, arms = 0;
  const repos = [];
  const repo = () => {
    const t = fs.mkdtempSync(path.join(os.tmpdir(), "flcx-"));
    repos.push(t);
    fs.mkdirSync(path.join(t, "src"));
    let clock = 1000;
    const g = (...a) => execFileSync("git", ["-C", t, "-c", "user.email=selftest@example.invalid", "-c", "user.name=selftest",
      "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", ...a], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"],
      env: { ...process.env, GIT_AUTHOR_DATE: `@${clock} +0000`, GIT_COMMITTER_DATE: `@${clock} +0000` } }).trim();
    g("init", "-q");
    const commit = (file, body) => {
      clock += 1000;
      fs.writeFileSync(path.join(t, file), body);
      g("add", file); g("commit", "-q", "-m", `c${clock}`);
      return g("rev-parse", "HEAD");
    };
    return { t, commit };
  };
  const widget = (at) => {
    const b = [];
    for (let i = 1; i <= 60; i++) b.push(`// filler line ${i}`);
    for (const [n, l] of Object.entries(at)) b[n - 1] = l;
    return b.join("\n") + "\n";
  };
  const run = (t, extra = []) => {
    try {
      return { code: 0, out: execFileSync(process.execPath, [self, "--root", t, "--charter", "charter.md", "--map", "widget.js=src/widget.js", ...extra],
        { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }) };
    } catch (e) { return { code: e.status, out: (e.stdout || "") + (e.stderr || "") }; }
  };
  const buckets = (t) => { const r = run(t, ["--json"]); try { return JSON.parse(r.out); } catch { return null; } };
  const arm = (label, ok, detail) => {
    arms++;
    process.stdout.write(`\n=== ARM ${arms}  ${label} ===\n    ${detail}\n    -> ${ok ? "ok" : "ARM FAILED"}\n`);
    if (!ok) fails++;
  };
  const find = (rows, cite) => (rows || []).find((x) => x.cite === cite) || { bucket: "(missing)" };
  const s10 = (s) => s.slice(0, 10);

  try {
    // ── DATING fixture: two citations on ONE charter line, then a pin of one.
    // A: widget.js has paintChip at 20, makeWidget at 30.
    // B: the charter cites both on one line.
    // C: widget.js drops both (neither resolves at HEAD).
    // D: the charter pins paintChip, rewriting the line.
    // makeWidget's text was written at B, so its dated version is A -> PIN-EXACT.
    // Blame of its LINE says D, whose dated version is C -> walks back to A -> PIN-OLDER.
    const pad = " — a spacer phrase long enough to keep the two backtick spans apart — ";
    const line = "| D1 | `makeWidget widget.js:30` builds it" + pad + "`paintChip widget.js:20` paints it |";
    const both = { 20: "function paintChip(el) { return el; }", 30: "function makeWidget(o) { return o; }" };
    {
      const { t, commit } = repo();
      const shaA = commit("src/widget.js", widget(both));
      commit("charter.md", `# fixture\n\n${line}\n`);
      commit("src/widget.js", widget({}));
      const b0 = find(buckets(t), "widget.js:30");
      arm("DATING positive control: before any pin, makeWidget widget.js:30 is PIN-EXACT at A",
        b0.bucket === "PIN-EXACT" && b0.pin && b0.pin.sha === shaA,
        `bucket ${b0.bucket}${b0.pin ? ` pin ${s10(b0.pin.sha)}` : ""} (want PIN-EXACT at ${s10(shaA)})`);
      commit("charter.md", `# fixture\n\n${line.replace("widget.js:20", `widget.js (paintChip @ ${s10(shaA)}, L20)`)}\n`);
      const after = buckets(t);
      const a0 = find(after, "widget.js:30");
      arm("DATING: a COMMITTED pin of the sibling paintChip on the same line leaves makeWidget PIN-EXACT at A",
        a0.bucket === "PIN-EXACT" && a0.pin && a0.pin.sha === shaA && (after || []).some((x) => x.bucket === "ALREADY-PINNED"),
        `bucket ${a0.bucket}${a0.pin ? ` pin ${s10(a0.pin.sha)} back ${a0.pin.back}` : ""} (want PIN-EXACT at ${s10(shaA)}; blame-of-line dating gives PIN-OLDER)`);
    }
    {
      // The same shape, pinned by --apply and left UNCOMMITTED: the working-tree
      // diff is replayed too, so a partial apply cannot re-date the rest.
      const { t, commit } = repo();
      const shaA = commit("src/widget.js", widget(both));
      commit("charter.md", `# fixture\n\n${line}\n`);
      commit("src/widget.js", widget({}));
      const cp = path.join(t, "charter.md");
      fs.writeFileSync(cp, fs.readFileSync(cp, "utf8").replace("widget.js:20", `widget.js (paintChip @ ${s10(shaA)}, L20)`));
      const a0 = find(buckets(t), "widget.js:30");
      arm("DATING: the same sibling pin UNCOMMITTED leaves makeWidget PIN-EXACT at A",
        a0.bucket === "PIN-EXACT" && a0.pin && a0.pin.sha === shaA,
        `bucket ${a0.bucket}${a0.pin ? ` pin ${s10(a0.pin.sha)}` : ""} (want PIN-EXACT at ${s10(shaA)})`);
    }

    // ── PIN-SEARCH fixture: a quote subject exactly on its cited line, and no
    // whole-line anchor landing there. The checker verifies a pin by the thing
    // alone, so this is PIN-EXACT; the old rule sent it to BLOCK-NEAR at d=0.
    {
      const { t, commit } = repo();
      const shaA = commit("src/widget.js", widget({ 12: "test(\"seven fleet ticks after one boot cost 12 requests\", () => {});",
        50: "test(\"a second titled case well away\", () => {});" }));
      const far = "`farAwayAnchor` is named at the start of this row and then a long stretch of plain prose follows it, well over eighty characters wide, before";
      commit("charter.md", `# fixture\n\n| D1 | ${far} the guard (widget.js:12 counts requests: "seven fleet ticks after one boot cost 12") |\n` +
        `| D2 | ${far} the case (widget.js:42 is "a second titled case well away") |\n`);
      commit("src/widget.js", widget({}));
      const rows = buckets(t);
      const q = find(rows, "widget.js:12");
      arm("PIN SEARCH: quote subject on the cited line, whole-line anchor elsewhere -> PIN-EXACT",
        q.bucket === "PIN-EXACT" && q.pin && q.pin.sha === shaA && q.pin.at === 12,
        `bucket ${q.bucket}${q.pin ? ` pin ${s10(q.pin.sha)} at ${q.pin.at}` : ""}${q.near ? ` near d=${q.near.d}` : ""} (want PIN-EXACT at ${s10(shaA)} L12; the whole-line-anchor rule gives BLOCK-NEAR d=0)`);
      const n = find(rows, "widget.js:42");
      arm("PIN SEARCH negative control: the same shape with the subject 8 lines off -> BLOCK-NEAR d=8, no pin",
        n.bucket === "BLOCK-NEAR" && !n.pin && n.near && n.near.d === 8, `bucket ${n.bucket}${n.near ? ` d=${n.near.d}` : ""}`);
      const r = run(t, ["--apply", "--only", "PIN-EXACT"]);
      let ck;
      try {
        ck = { code: 0, out: execFileSync(process.execPath, [checker, "--root", t, "--charter", "charter.md", "--map", "widget.js=src/widget.js",
          "--max-unresolved", "1", "--report"], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }) };
      } catch (e) { ck = { code: e.status, out: (e.stdout || "") + (e.stderr || "") }; }
      const pinLine = fs.readFileSync(path.join(t, "charter.md"), "utf8").split("\n")[2];
      arm("PIN SEARCH: the checker ACCEPTS the pin the classifier wrote",
        r.code === 0 && /widget\.js \("seven fleet ticks after " @ [0-9a-f]{10}, L12\)/.test(pinLine) && ck.code === 0 && /verified 1/.test(ck.out),
        `apply exit ${r.code}, checker exit ${ck.code}; ${(ck.out.match(/pinned[^\n]*/) || ["(no pinned line in checker output)"])[0].trim()}`);
    }

    // ── SUBJECT fixture (task-c99f9579606babbd): which adjacent thing is the
    // subject. Each widget.js version A holds the named thing on the cited line;
    // C empties the file, so nothing resolves at HEAD and the pin search decides.
    {
      const { t, commit } = repo();
      const shaA = commit("src/widget.js", widget({
        11: "// static fixture",
        12: "// a 230px-wide floor, measured",
        20: "function paintChip() { return \"Only the owner can pay here\"; }",
        30: "    if (st === \"off\") return { label: \"Autoupdate is off here\" };",
        8: "function operatorRow(bp) {",
      }));
      const far = "a long stretch of plain prose that keeps the next span apart";
      commit("charter.md", "# fixture\n\n" +
        `| D1 | \`farAwayAnchor\` keeps the row decidable; ${far}, well over eighty characters — stale copy ("230px-wide"), \`cloud/priv/static/widget.js:12\` |\n` +
        "| D2 | `paintChip` renders the owner copy — see widget.js:20 (\"Only the owner can pay here\") |\n" +
        "| D3 | (\"Autoupdate is off here\" — echoed from `operatorRow` at `widget.js:30`, verified) |\n");
      commit("src/widget.js", widget({}));
      const rows = buckets(t);
      const labelOf = (x) => (x && x.pin ? x.pin.tok : "(no pin)");
      const a = find(rows, "widget.js:12");
      // #20145's L575 shape: the quote is 10 chars, under the 140-char fallback's
      // 12, so this also reds if an ADJACENT quote needs 12 again.
      arm("SUBJECT: a path prefix is never the subject — `cloud/priv/static/widget.js:12` pins the adjacent short quote \"230px-wide\", not `static`",
        a.bucket === "PIN-EXACT" && a.pin && a.pin.sha === shaA && a.pin.tok === '"230px-wide"' &&
          !(a.local || []).some((x) => ["cloud", "priv", "static"].includes(x.label || x)),
        `bucket ${a.bucket} pin ${labelOf(a)} local=[${(a.local || []).map((x) => x.label || x).join(",")}] (want PIN-EXACT on the quote; the prefix rule pins \`static\` at 11)`);
      const b = find(rows, "widget.js:20");
      arm("SUBJECT: a quote beside the citation outranks a span farther away, when both land -> the pin names the quote",
        b.bucket === "PIN-EXACT" && b.pin && /^"Only the owner/.test(b.pin.tok),
        `bucket ${b.bucket} pin ${labelOf(b)} (want the quote; span-beats-quote pins paintChip)`);
      const c = find(rows, "widget.js:30");
      arm("SUBJECT: the nearer span 22 lines off does not hide a quote that lands on the cited line -> PIN-EXACT on the quote",
        c.bucket === "PIN-EXACT" && c.pin && c.pin.sha === shaA && /^"Autoupdate is off/.test(c.pin.tok),
        `bucket ${c.bucket} pin ${labelOf(c)}${c.near ? ` near ${c.near.tok} d=${c.near.d}` : ""} (want PIN-EXACT on the quote; span-only gives BLOCK-NEAR d=22)`);
    }

    // ── DEFINITION, NOT USE (task-eb534ada6569c7da): charter L677's shape. A
    // defines tokenRow AT the cited line 22; B (the version current when the
    // charter row is written) calls it at 22 and defines it at 32. The name
    // alone lands at B via the call -> the old rule proposed PIN-EXACT at B, the
    // call-site pin #20128 wrote. The definition lands only at A -> PIN-OLDER.
    {
      const { t, commit } = repo();
      const shaA = commit("src/widget.js", widget({ 22: "  function tokenRow(t) {" }));
      const shaB = commit("src/widget.js", widget({ 22: "    box.innerHTML = list.map(tokenRow).join(\"\");", 32: "  function tokenRow(t) {" }));
      commit("charter.md", "# fixture\n\n| D1 | `.token-row` is emitted by `tokenRow` at widget.js:22 alone |\n");
      commit("src/widget.js", widget({}));
      const r = find(buckets(t), "widget.js:22");
      arm("DEFINITION: a function whose name lands only as a CALL at the dated version is not pinned there -> PIN-OLDER at its definition",
        r.bucket === "PIN-OLDER" && r.pin && r.pin.sha === shaA && r.pin.at === 22,
        `bucket ${r.bucket}${r.pin ? ` pin ${s10(r.pin.sha)} at ${r.pin.at}` : ""} (want PIN-OLDER at ${s10(shaA)} L22; name matching gives PIN-EXACT at ${s10(shaB)} via the call)`);
    }
  } catch (e) {
    fails++;
    process.stdout.write(`\nSELFTEST CRASHED: ${e.stack || e}\n`);
  } finally {
    for (const t of repos) fs.rmSync(t, { recursive: true, force: true });
  }
  process.stdout.write(`\nSELFTEST ${fails === 0 ? "PASS" : "FAIL"} — ${arms - fails}/${arms} arms\n`);
  return fails === 0 ? 0 : 1;
}
} // IS_MAIN
