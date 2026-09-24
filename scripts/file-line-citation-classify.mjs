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
// uses a LOCAL anchor set instead: tokens from the backtick span that CONTAINS
// the citation, else the nearest span ending within 80 chars before it and the
// nearest starting within 40 chars after it. A pin is only proposed when the
// local set lands at the pinned version AND the checker's own whole-line test
// also passes there (so the checker will accept what the classifier writes).
//
// ── BUCKETS ───────────────────────────────────────────────────────────────────
//   R-LOCAL      checker resolves at HEAD and a LOCAL token lands too
//   R-FOREIGN    checker resolves at HEAD only via a token NOT in the local set
//                (over-credit suspects — the resolved-side audit samples these)
//   R-NO-LOCAL   checker resolves at HEAD; no local subject to test it by
//   PIN-EXACT    local set lands at the version current when the citing line
//                was last written (git blame) -> pin there
//   PIN-OLDER    lands only at an OLDER version, within --depth versions
//                (cited from a stale base)
//   PIN-NEWER    lands only at a NEWER version, within --ahead versions (cited
//                from a base carrying siblings that merged after the charter)
//   PIN-WEAK     would pin, but the crediting token occurs > --weak times in the
//                pinned file: a generic word, so the pin is not evidence -> hand
//   NO-LOCAL     no backticked subject and no quoted sentence near the citation
//                -> hand (no rule can pick the subject out of prose)
//   BLOCK-NEAR   the local subject sits <= 40 lines off at the blame-era version
//                (cites a block body, or an off-main base) -> hand
//   FAR          the local subject sits > 40 lines off -> hand
//   ABSENT-THEN  no local token exists anywhere in the blame-era file -> hand
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
//   [--charter P] [--map base=path]... [--depth K] [--ahead K] [--weak K] [--cap N] [--slack K]
//   exit 0 residue <= cap · 1 residue > cap (STOP) · 2 bad argument
//
import fs from "node:fs";
import path from "node:path";
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

const o = { charter: ".claude/workflows/bp-cloud-console-hardening-charter.md", maps: [],
  depth: 80, ahead: 20, slack: 3, weak: 25, cap: 30, apply: false, json: false, residue: false, only: null };
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  const need = () => argv[++i];
  if (a === "--charter") o.charter = need();
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

const git = (args, opts = {}) => execFileSync("git", args, { encoding: "utf8", maxBuffer: 1 << 30, ...opts });
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

const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
const wordRe = (tok) => new RegExp(`(^|[^A-Za-z0-9_$-])${esc(tok)}([^A-Za-z0-9_$-]|$)`);
const checkerWordRe = (tok) => new RegExp(`(^|[^A-Za-z0-9_$])${esc(tok)}([^A-Za-z0-9_$]|$)`);

function tokensOf(span, base, keepHyphen) {
  const own = new Set(base.toLowerCase().split(/[^a-z0-9]+/i).filter(Boolean));
  const out = new Set();
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

function spansOf(text) {
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

function localAnchors(text, base, p, e) {
  const spans = spansOf(text);
  const inside = spans.find((sp) => sp.s < p && sp.e > e);
  const keepHyphen = base.endsWith(".css") || base.endsWith(".html");
  let toks = [];
  if (inside) toks = tokensOf(inside.body.replace(PIN_RE, " "), base, keepHyphen);
  if (toks.length === 0) {
    const before = spans.filter((sp) => sp.e <= p && p - sp.e <= 80 && !(inside && sp === inside)).pop();
    const after = spans.find((sp) => sp.s >= e && sp.s - e <= 40);
    for (const sp of [before, after]) if (sp) toks.push(...tokensOf(sp.body.replace(PIN_RE, " "), base, keepHyphen));
  }
  return [...new Set(toks)];
}

// ── parse ────────────────────────────────────────────────────────────────────
const alt = [...targets.keys()].map(esc).join("|");
const CITE = new RegExp(`\\b(${alt}):(\\d+)(?:[-–](\\d+))?`, "g");
const PINNED = new RegExp(`(?<![\\w.-])(${alt}) \\(([^@()\\n]+?) @ ([0-9a-f]{7,40}), L(\\d+)(?:[-\u2013]L?(\\d+))?\\)`, "g");
const cites = [];
lines.forEach((text, idx) => {
  for (const m of text.matchAll(CITE)) {
    const n = Number(m[2]);
    const hi = m[3] ? Number(m[3]) : n;
    const end = m.index + m[0].length;
    cites.push({ base: m[1], n, hi: hi >= n ? hi : n, charterLine: idx + 1, text, p: m.index, e: end, pin: null });
  }
  for (const m of text.matchAll(PINNED)) {
    const n = Number(m[4]);
    const hi = m[5] && Number(m[5]) >= n ? Number(m[5]) : n;
    cites.push({ base: m[1], n, hi, charterLine: idx + 1, text, p: m.index, e: m.index + m[0].length, pin: m[3] });
  }
});

// A range is its own tolerance (no slack), a single line gets +/-slack — the
// checker's windowOf(), so a pin this writes is one the checker accepts.
function lands(fileLines, c, toks, re) {
  const lo = c.hi !== c.n ? Math.max(1, c.n) : Math.max(1, c.n - o.slack);
  const hi = c.hi !== c.n ? Math.min(fileLines.length, c.hi) : Math.min(fileLines.length, c.n + o.slack);
  for (const tok of toks) {
    const r = typeof tok === "object" ? tok.re : re(tok);
    const name = typeof tok === "object" ? tok.label : tok;
    for (let k = lo; k <= hi; k++) if (r.test(fileLines[k - 1])) return { tok: name, at: k, re: r };
  }
  return null;
}

// A quoted sentence next to the citation is a subject too: the charter often
// cites copy ("Only the team owner can manage billing.") rather than a symbol.
// Its first 24 chars (>= 12) are matched as a literal substring.
function quotesNear(text, p, e) {
  const win = text.slice(Math.max(0, p - 140), e + 140);
  const out = [];
  for (const m of win.matchAll(/["\u201c]([^"\u201d]{12,})["\u201d]/g)) {
    const q = m[1].replace(/[\u2026].*$/, "").replace(/\.\.\..*$/, "").slice(0, 24);
    if (q.length < 12 || /app\.(js|css)|\.mjs|index\.html/.test(q)) continue;
    out.push({ label: `"${q}"`, re: new RegExp(esc(q)) });
  }
  return out;
}
const countIn = (fl, r) => fl.reduce((n, l) => n + (r.test(l) ? 1 : 0), 0);

// ── blame: when was each citing line last written? ────────────────────────────
const blame = new Map();
{
  const out = git(["blame", "--line-porcelain", "HEAD", "--", charterRel]);
  let cur = null, ct = null;
  for (const l of out.split("\n")) {
    const h = l.match(/^([0-9a-f]{40}) \d+ (\d+)/);
    if (h) { cur = { sha: h[1], line: Number(h[2]) }; continue; }
    const t = l.match(/^committer-time (\d+)/);
    if (t && cur) { ct = Number(t[1]); blame.set(cur.line, { sha: cur.sha, time: ct }); }
  }
}

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
  c.local = localAnchors(c.text, c.base, c.p, c.e);
  if (c.local.length === 0) c.local = quotesNear(c.text, c.p, c.e);
  c.decidable = c.lineAnchors.length > 0;
  if (c.pin) { c.bucket = "ALREADY-PINNED"; continue; }
  const headHit = c.decidable ? lands(t.head, c, c.lineAnchors, checkerWordRe) : null;
  c.headResolved = !!headHit;
  c.credit = headHit;
  const localHead = c.local.length ? lands(t.head, c, c.local, wordRe) : null;
  if (!c.decidable) { c.bucket = "UNDECIDABLE"; continue; }
  if (c.local.length === 0) { c.bucket = c.headResolved ? "R-NO-LOCAL" : "NO-LOCAL"; continue; }

  // pin search: newest version at or before the blame commit, walking older.
  const b = blame.get(c.charterLine);
  const vs = versions(t.rel);
  let start = vs.findIndex((v) => v.time <= b.time);
  if (start < 0) start = vs.length;
  let pin = null;
  const order = [];
  for (let d = 0; d < o.depth; d++) {
    if (start + d < vs.length) order.push(start + d);
    if (d > 0 && d <= o.ahead && start - d >= 0) order.push(start - d);
  }
  for (const k of order) {
    const fl = blob(vs[k].sha, t.rel);
    if (!fl) continue;
    const lh = lands(fl, c, c.local, wordRe);
    if (!lh) continue;
    const wh = lands(fl, c, c.lineAnchors, checkerWordRe);
    if (!wh) continue;
    pin = { sha: vs[k].sha, back: k - start, tok: lh.tok, at: lh.at, freq: countIn(fl, lh.re) };
    break;
  }
  c.pinTo = pin;
  if (c.headResolved) {
    c.bucket = localHead ? "R-LOCAL" : "R-FOREIGN";
  } else if (pin && pin.freq > o.weak) {
    c.bucket = "PIN-WEAK";
  } else if (pin) {
    c.bucket = pin.back === 0 ? "PIN-EXACT" : pin.back > 0 ? "PIN-OLDER" : "PIN-NEWER";
  } else {
    // shape the residue: how close did the local set EVER come, at the blame-era version?
    const fl = blob(vs[Math.min(start, vs.length - 1)].sha, t.rel) || t.head;
    let best = null;
    for (const tok of c.local) {
      const r = typeof tok === "object" ? tok.re : wordRe(tok);
      for (let k = 1; k <= fl.length; k++) if (r.test(fl[k - 1])) {
        const d = k < c.n ? c.n - k : (k > c.hi ? k - c.hi : 0);
        if (!best || d < best.d) best = { tok: typeof tok === "object" ? tok.label : tok, at: k, d };
      }
    }
    c.near = best;
    c.bucket = !best ? "ABSENT-THEN" : best.d <= 40 ? "BLOCK-NEAR" : "FAR";
  }
  c.localHead = localHead;
}

// ── report ───────────────────────────────────────────────────────────────────
const RULES = {
  "R-LOCAL": "resolves at HEAD by a local token; pinned (at the blame-era version) so it cannot rot",
  "R-FOREIGN": "checker credits it at HEAD by a NON-local token (over-credit suspect); pinned if the local set lands historically",
  "R-NO-LOCAL": "checker credits it at HEAD; no local anchor, so no rule can pin it -> left unpinned",
  "PIN-EXACT": "local set lands at the version current when the line was written -> rewrite to <file> (<thing> @ <sha>, L<n>)",
  "PIN-OLDER": "local set lands only at an older version (cited on a stale base) -> rewrite to <file> (<thing> @ <sha>, L<n>)",
  "PIN-NEWER": `local set lands only at a NEWER version (<=${o.ahead}; cited from a base carrying unmerged siblings) -> rewrite to <file> (<thing> @ <sha>, L<n>)`,
  "PIN-WEAK": `would pin, but the crediting local token occurs > ${o.weak} times in the pinned file (generic word) -> RESIDUE (hand)`,
  "NO-LOCAL": "no backticked subject and no quoted sentence near the citation -> RESIDUE (hand)",
  "BLOCK-NEAR": "local set never lands in +/-slack, but sits <=40 lines off at the blame-era version (cites a block body, or a sibling base) -> RESIDUE (hand)",
  "FAR": "local set sits >40 lines off at the blame-era version -> RESIDUE (hand)",
  "ABSENT-THEN": "no local token exists anywhere in the blame-era file (prose word, other file, or later rename) -> RESIDUE (hand)",
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
  if (!c.pinTo || c.bucket === "PIN-WEAK" || (c.bucket.startsWith("R-") && c.pinTo.freq > o.weak)) return null;
  if (!writableThing(c.pinTo.tok)) return null;
  const range = c.hi !== c.n ? `L${c.n}-${c.hi}` : `L${c.n}`;
  return { at: c.p, end: c.e, str: `${c.base} (${c.pinTo.tok} @ ${shortSha(c.pinTo.sha)}, ${range})` };
}
const excerpt = (s, a, b) => s.slice(Math.max(0, a), b).replace(/\s+/g, " ");

if (o.json) {
  process.stdout.write(JSON.stringify(cites.map((c) => ({
    cite: `${c.base}:${c.n}${c.hi !== c.n ? "-" + c.hi : ""}`, charterLine: c.charterLine, bucket: c.bucket,
    local: c.local, credit: c.credit, localHead: c.localHead, pin: c.pinTo,
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
        (c.credit ? ` credit=${c.credit.tok}@${c.credit.at}` : "") + (c.pinTo ? ` pin=${shortSha(c.pinTo.sha)} (${c.pinTo.back} versions from blame, ${c.pinTo.tok}@${c.pinTo.at} x${c.pinTo.freq})` : "") + "\n");
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
  process.exit(1);
}
if (o.apply) {
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
