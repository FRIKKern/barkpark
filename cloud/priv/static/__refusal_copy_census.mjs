// __refusal_copy_census.mjs — THE REFUSAL-COPY CENSUS over the Cloud console SPA.
//
// Charter D383/D441 (wave 40). The law this instrument enforces:
//
//     A CAUSE THE CONSOLE NAMES IS A CAUSE THE SERVER SENT — or it is a
//     sentence somebody invented, and nobody judged.
//
// The console renders refusals. Every refusal it draws either RELAYS a cause the
// server actually named (`data.error`, a `reason` slug, a status), or AUTHORS a
// sentence of its own. Authoring is not automatically wrong — a curated sentence
// beats a raw slug — but an AUTHORED cause that no server emitter can produce is
// the console telling the user why something failed when it does not know why.
// This census exists so that class cannot arrive unread.
//
// ── WHAT THIS CENSUS IS AND IS NOT ──────────────────────────────────────────
//
// It is an ADD/REMOVE SET DIFF over a pinned population, in __binding_census.mjs's
// shape: DERIVE the population mechanically, PIN the verdict as a human judgment,
// and gate ONLY on the set diff. It is NOT __unknown_census.mjs's shape, and the
// difference is not taste.
//
// A FULLY-DERIVED AUTHORED-vs-CONSULTED SELECTOR WAS PROTOTYPED AND MEASURED
// UNSOUND ON REAL MAIN, IN FOUR INDEPENDENT WAYS. Do not attempt it here:
//
//   1. FUNCTION-GRANULAR clearing FALSE-CLEARS `envVarWriteFailureCopy`: the
//      function consults `data.error` on two of its arms while its 403 arm
//      authors. "This function consults" is true and useless.
//   2. BRANCH-GRANULAR clearing FALSE-POSITIVES on `siteRollbackFailure`, whose
//      guard reaches `data.error` through a TWO-HOP alias no single-branch
//      dataflow sees.
//   3. 55 CALL SITES delegate the literal to a consulting callee — they hand a
//      fallback to `friendly()`, which provably consults. A selector that cannot
//      see through the delegation scores all 55 as authored.
//   4. `ERRORS.forbidden` — the crown target of cch-w40-s1 — HAS NO ENCLOSING
//      FUNCTION AT ALL, so function granularity is simply UNDEFINED on the one
//      row this wave most needs a key for.
//
// So the VERDICT is pinned by a human, and this file gates the POPULATION.
//
// PINNED VERDICTS ARE INFORMATIONAL THIS WAVE. Every row prints
// AUTHORED / CONSULTED / DELEGATED, and NO arm reads that field. Whether a pinned
// verdict is still TRUE is the DRIFT arm, and it is DEFERRED for exactly the
// reason __binding_census.mjs defers its own: a commit that keeps a literal
// byte-identical and deletes the `data.error` guard in front of it flips the row
// from CONSULTED to AUTHORED while leaving the KEY unchanged. A set diff cannot
// see that, and a drift arm that pretended to would be asserting a dataflow claim
// the four measurements above already refuted. Printing the verdict without
// gating on it is the honest half: a reviewer reading this census's output sees
// the judgment, and the judgment is a comment, not a check.
//
// ── THREE SITE KINDS, EACH KEYED STABLY — NEVER BY LINE NUMBER ──────────────
//
//   MAP|<MAPNAME>.<key>
//       A string value in a refusal copy map. A map QUALIFIES only if its
//       identifier is referenced inside a FENCE BODY (friendly /
//       forbiddenEvidenceCopy / readFailureCopy / faultCopy). That rule is what
//       admits ERRORS, FORBIDDEN_ROLE_COPY and FORBIDDEN_REASON_COPY while
//       rejecting LIVE_CHIP_COPY, NOTIF_TRANSPORTS, LIFECYCLE_PILL_LABEL and the
//       other ~30 all-caps label maps that have nothing to do with refusals.
//       This kind is the ONLY one that can give `ERRORS.forbidden` a key, since
//       it has no enclosing function (see (4) above).
//
//   FN|<enclosing fn>|<sha1(normalized literal)[0:8]>
//       A cause-vocabulary literal in COPY POSITION inside a refusal renderer —
//       inside a `return`, or an argument to a fence call — COMMENTS STRIPPED.
//       POSITION-SCOPING IS LOAD-BEARING, and it is measured: a BODY-scoped scan
//       over the same renderers yields hundreds of rows dominated by modal markup
//       and even pins fragments of friendly()'s OWN DOC COMMENT as refusal copy.
//       This file prints both numbers on every live run so the claim stays a
//       measurement rather than a memory (see the `population` block).
//
//   ARG|<enclosing fn>|<renderer>
//       A literal passed as the FALLBACK argument to friendly / faultCopy /
//       ctl.fail. Scored DELEGATED BY CONSTRUCTION, never AUTHORED. That is the
//       principled answer to the 55-site class in (3), and it is honest rather
//       than convenient: friendly() PROVABLY consults — it keys `data.error` into
//       ERRORS and only reaches its second argument when the server named no
//       cause it recognises. A literal in that slot is what the console says when
//       the server said nothing, which is the definition of a fallback and not
//       the definition of an invented cause.
//
//       THIS KEY IS DELIBERATELY COARSE. Two `friendly(data, "…")` calls in one
//       function collapse to ONE key, and that is intended: the verdict is fixed
//       by construction for every member of the class, so per-literal keys would
//       buy nothing but churn on every copy edit in a fallback slot. What the key
//       still buys is arrival and departure: a function that grows its FIRST
//       delegated fallback reds ADD, and one that loses its last reds REMOVE.
//
// ── A REFUSAL RENDERER IS ANCHORED TWO WAYS, AND THE SECOND IS NOT OPTIONAL ──
//
// A function is a refusal renderer if EITHER holds:
//
//   (a) A REFUSAL PREDICATE in its body — `status === 4xx`, `.error ===`, or a
//       call to one of the four fences.
//   (b) THE NAMING CONVENTION — /(ErrorHtml|FailureCopy|ErrorCopy|RefusalToast|
//       RefusalCopy|FailureHtml)$/.
//
// (b) is here because (a) ALONE PRODUCES ZERO ROWS FOR `notifDeliveriesErrorHtml`
// — one of the two live liars cch-w40-s1 is fixing — since it is a pure HTML
// literal sitting one hop from its error branch, with no predicate of its own
// anywhere in the function. Anchoring on predicates alone would have made the
// crown's own subject invisible to the gate meant to hold the crown's ground.
//
// THE NAMING ANCHOR HAS ITS OWN HAZARD, AND IT IS A REAL HOLE, NOT A ROUNDING
// ERROR. A refusal renderer that carries NO predicate AND is named outside the
// convention — `whyItFailed`, `explain`, `deniedBlurb` — is INVISIBLE to this
// census in BOTH directions. It produces no ADD when it arrives, so an invented
// cause can ship through this gate untouched, and it produces no REMOVE when it
// leaves, so nothing here will ever tell you it existed. This file names that
// hole rather than papering over it: the census's claim is bounded to
// "predicated renderers, plus renderers that follow the convention", and it is
// NOT a completeness claim over the console's refusal copy. Widening (b) is the
// obvious next move and it is NOT free — every name added to that alternation
// enlarges the pin, and an over-wide convention drags ordinary copy into a gate
// people will then want deleted.
//
// ── FOUR ARMS ───────────────────────────────────────────────────────────────
//
//   ADD    — a live site with no pinned key. EXIT 1. This is THE DISEASE: a new
//            invented cause that nobody judged.
//   REMOVE — a pinned key with no live site. EXIT 1. This is THE DECAY: a pin
//            that has quietly become fiction while still looking authoritative.
//   FENCE  — any of friendly / forbiddenEvidenceCopy / readFailureCopy /
//            faultCopy missing from the subject. EXIT 2, BEFORE the set diff,
//            because if a fence is gone then EVERY ARG verdict in the pin is
//            fiction — the whole "delegated by construction" argument rests on
//            those four functions existing and consulting.
//
//            MEASURED, on this tree, with this extractor: renaming `friendly` to
//            `humanize` throughout app.js leaves the SITE COUNT almost unmoved
//            (344 -> 341) while REDISTRIBUTING the kinds — ARG collapses 73 -> 20
//            and FN swells 227 -> 277, because the literals that were delegated
//            fallbacks stop being recognised as delegated and fall through to the
//            FN kind. Run past the fence check, the set diff reports 51 ADD and
//            54 REMOVE: a hundred-row scream about a pure rename, in which the
//            one thing that actually broke — every ARG verdict in the pin is now
//            fiction — is the one thing it does not say.
//
//            NOTE THE CORRECTION to this arm's own filing, which predicted the
//            population would "drop 224 -> 134 and otherwise pass a diff
//            silently". It does not pass silently here; it fails LOUDLY and for
//            the WRONG REASON. That is a worse failure than silence, not a
//            better one — a red that names 105 innocent rows invites re-cutting
//            the pin, which would bake the broken verdicts in. Exit 2 is a
//            REFUSAL TO MEASURE, it is not a pass, and it is what keeps the
//            remedy pointed at the rename.
//   DUPLICATE-KEY — two DISTINCT function bodies sharing one derived key. EXIT 2.
//            app.js carries four duplicated function names (`run` x3, `paint` x3,
//            `card` x2, `showErr` x2). None of them collides TODAY, which is
//            precisely why this arm exists: the collision class is LATENT, and
//            the day a second `showErr` grows the same sentence, one site starts
//            hiding behind the other and the ADD arm goes quietly blind. Adopted
//            from __binding_census.mjs's (2c).
//
// ── THE SIZE OF THIS PIN, AND WHAT IT COSTS YOU ─────────────────────────────
//
// The live run prints the exact split (MAP / FN / ARG) every time; the numbers
// below are this file's reading at the commit that introduced it, kept here so a
// reader knows the ORDER OF MAGNITUDE before running anything. See the
// `pin size` line of any live run for the current truth.
//
//     339 keys — 44 MAP, 222 FN, 73 ARG. Zero collisions after the ARG key was
//     given a literal hash (see (2)). That is roughly FOUR TIMES the population of
//     __binding_census.mjs, and the FN kind is 65% of it.
//
//     222 of those 339 rows carry the verdict UNREVIEWED, and that number is
//     printed on every live run rather than buried here. It is the honest state of
//     a pin cut in one slice: MAP and ARG verdicts are sound BY CONSTRUCTION (a
//     qualified map is keyed on a value the server sent; an ARG row is a fallback
//     handed to a fence that provably consults), but an FN verdict is a per-branch
//     dataflow judgment, and the four measurements above are precisely the record
//     of a machine getting that judgment WRONG. Manufacturing 222 verdicts nobody
//     read would have made this pin a confident liar in the one column where it
//     has no evidence. Retiring UNREVIEWED rows is ordinary follow-up work and it
//     does not block the gate: NO ARM READS THE VERDICT.
//
// EVERY LEGITIMATE COPY EDIT INSIDE A REFUSAL RENDERER'S `return` REDS THIS GATE.
// That is CORRECT behaviour — the whole point is that a changed cause sentence is
// a judgment somebody should make on purpose — and it is also a REAL, ONGOING,
// RECURRING COST paid by whoever next improves a refusal message. It is several
// times the maintenance surface of __binding_census.mjs, whose population only
// moves when a write call site is added or removed.
//
// THIS IS WRITTEN DOWN HERE ON PURPOSE. A gate people RESENT is a gate that gets
// DELETED, or — worse and more common — quietly weakened until it cannot lose.
// If the cost above is not worth paying, the honest move is to argue for
// narrowing the population (drop the FN kind, keep MAP and ARG) or to retire this
// file outright. The dishonest move is to keep the file and stop letting it red.
//
// ── RUN IT ──────────────────────────────────────────────────────────────────
//
//   node cloud/priv/static/__refusal_copy_census.mjs
//   node cloud/priv/static/__refusal_copy_census.mjs --add-check    <fixture.js>
//   node cloud/priv/static/__refusal_copy_census.mjs --remove-check <fixture.js>
//
// Node builtins only. It reads bytes; it never imports the subject.

import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";

const here = path.dirname(new URL(import.meta.url).pathname);

// ── THE FIXTURE MODE FLAG IS RESOLVED HERE, AT THE `APP` BINDING ────────────
//
// NOT downstream, and this is a MEASURED trap rather than a stylistic
// preference. __binding_census.mjs reads its subject at module scope, so a mode
// block placed after that read never runs at all: `--add-check` IS `argv[2]`, so
// `node census.mjs --add-check fixture.js` dies
// `ENOENT: no such file or directory, open '--add-check'` before one line of
// census logic executes. The flag has to be consumed WHERE THE SUBJECT PATH IS
// CHOSEN, which is this block and the `const APP =` line below it.
const FIXTURE_FLAGS = ["--add-check", "--remove-check"];
const fixtureFlagAt = process.argv.findIndex((a) => FIXTURE_FLAGS.includes(a));
const FIXTURE_MODE = fixtureFlagAt === -1 ? null : process.argv[fixtureFlagAt];
const FIXTURE_FILE = FIXTURE_MODE ? process.argv[fixtureFlagAt + 1] : null;
if (FIXTURE_MODE && !FIXTURE_FILE) {
  console.error(`FAIL(2): ${FIXTURE_MODE} needs a fixture file argument.`);
  console.error("  e.g. node cloud/priv/static/__refusal_copy_census.mjs --add-check \\");
  console.error("         cloud/priv/static/__refusal_copy.add.fixture.js");
  process.exit(2);
}

// AN UNRECOGNISED FLAG IS A REFUSAL, NOT A DEFAULT — and this is here because it
// caught something during this file's own bring-up. `node census.mjs "--add-check
// fixture.js"` (one fused argv element, which is what zsh hands you when an
// unquoted variable does NOT word-split) matched no flag, failed the
// `startsWith("--")` subject test, and fell through to app.js. The run printed a
// confident GREEN — a full live census, correct in every line — as the answer to
// a fixture question that was never asked. A silent fallback to the default
// subject is how a control cell reports success without ever running.
for (const a of process.argv.slice(2)) {
  if (!a.startsWith("--")) continue;
  if (FIXTURE_FLAGS.includes(a)) continue;
  console.error(`FAIL(2): unrecognised argument ${JSON.stringify(a)}.`);
  console.error("  Known flags: " + FIXTURE_FLAGS.join(", ") + ". A run this census does not");
  console.error("  understand is a run it must not answer: falling back to app.js here would print a");
  console.error("  green live census as the answer to a fixture question nobody asked.");
  process.exit(2);
}

const DEFAULT_APP = path.join(here, "app.js");
const APP = FIXTURE_FILE || (process.argv[2] && !process.argv[2].startsWith("--") ? process.argv[2] : DEFAULT_APP);
const LABEL = APP === DEFAULT_APP ? "cloud/priv/static/app.js" : APP;

let src;
try {
  src = fs.readFileSync(APP, "utf8");
} catch (e) {
  console.error(`FAIL(2): cannot read the subject — ${APP}`);
  console.error("  " + e.message);
  process.exit(2);
}

// ═══════════════════════════════════════════════════════════════════════════
// THE SCANNER — one pass, comment/string/regex aware.
// ═══════════════════════════════════════════════════════════════════════════
//
// It produces two views of the same bytes, both the SAME LENGTH as the source so
// every offset is interchangeable:
//
//   code — comments blanked to spaces. "COMMENTS STRIPPED" is this, and it is
//          why friendly()'s own doc comment cannot be pinned as refusal copy.
//   mask — `code` with every string's CONTENTS blanked too (quotes kept). All
//          structural scanning below runs over `mask`, so a comma, paren or
//          semicolon inside a sentence can never be mistaken for syntax.
//
// and one index: every string literal's offsets and raw text.
function scan(s) {
  const code = s.split("");
  const mask = s.split("");
  const strings = [];
  const blank = (from, to, arr) => {
    for (let k = from; k < to && k < s.length; k++) if (arr[k] !== "\n") arr[k] = " ";
  };
  // `prev` is the last significant character, used to tell a regex literal from
  // a division. Getting this wrong turns `/` into a runaway string.
  let prev = "";
  let prevWordEnd = -1;
  let i = 0;
  const REGEX_AFTER_CHAR = "(,=:[!&|?{};+-*%~^<>\n";
  const REGEX_AFTER_WORD = new Set(["return", "typeof", "case", "void", "delete", "in", "instanceof", "new", "do", "else", "yield", "await"]);
  const wordBefore = (at) => {
    let j = at - 1;
    while (j >= 0 && /\s/.test(s[j])) j--;
    let e = j + 1;
    while (j >= 0 && /[A-Za-z0-9_$]/.test(s[j])) j--;
    return s.slice(j + 1, e);
  };
  while (i < s.length) {
    const c = s[i];
    if (c === "/" && s[i + 1] === "/") {
      let j = s.indexOf("\n", i);
      if (j < 0) j = s.length;
      blank(i, j, code); blank(i, j, mask);
      i = j;
      continue;
    }
    if (c === "/" && s[i + 1] === "*") {
      let j = s.indexOf("*/", i);
      j = j < 0 ? s.length : j + 2;
      blank(i, j, code); blank(i, j, mask);
      i = j;
      continue;
    }
    if (c === '"' || c === "'" || c === "`") {
      const start = i;
      const q = c;
      i++;
      let esc = false;
      let text = "";
      for (; i < s.length; i++) {
        const d = s[i];
        if (esc) { text += d; esc = false; continue; }
        if (d === "\\") { text += d; esc = true; continue; }
        if (d === q) break;
        if (d === "\n" && q !== "`") break;   // unterminated; bail at the newline
        text += d;
      }
      const end = Math.min(i + 1, s.length);
      blank(start + 1, end - 1, mask);
      strings.push({ start, end, quote: q, text });
      i = end;
      prev = q;
      prevWordEnd = -1;
      continue;
    }
    if (c === "/") {
      const w = wordBefore(i);
      const isRegex = prev === "" || REGEX_AFTER_CHAR.includes(prev) || REGEX_AFTER_WORD.has(w);
      if (isRegex) {
        let j = i + 1, esc = false, cls = false, ok = false;
        for (; j < s.length; j++) {
          const d = s[j];
          if (esc) { esc = false; continue; }
          if (d === "\\") { esc = true; continue; }
          if (d === "\n") break;
          if (cls) { if (d === "]") cls = false; continue; }
          if (d === "[") { cls = true; continue; }
          if (d === "/") { ok = true; break; }
        }
        if (ok) {
          blank(i + 1, j, mask);
          i = j + 1;
          prev = "/";
          continue;
        }
      }
    }
    if (!/\s/.test(c)) prev = c;
    i++;
  }
  void prevWordEnd;
  return { code: code.join(""), mask: mask.join(""), strings };
}

const { code, mask, strings } = scan(src);
const lineOf = (i) => src.slice(0, i).split("\n").length;

// ── the function index — brace matched over `mask`, so nothing inside a string
//    or a comment can open or close a body.
function indexFunctions(m) {
  const out = [];
  const re = /\bfunction\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*\(/g;
  let match;
  while ((match = re.exec(m))) {
    const open = m.indexOf("{", re.lastIndex);
    if (open < 0) continue;
    let depth = 0, i = open;
    for (; i < m.length; i++) {
      if (m[i] === "{") depth++;
      else if (m[i] === "}") { depth--; if (depth === 0) { i++; break; } }
    }
    out.push({ name: match[1], start: match.index, end: i });
  }
  return out;
}
const fns = indexFunctions(mask);
const innermost = (pos) => {
  let best = null;
  for (const f of fns) if (f.start <= pos && pos < f.end) if (!best || f.start > best.start) best = f;
  return best;
};

// ═══════════════════════════════════════════════════════════════════════════
// (1) THE FENCE ARM — RUNS FIRST, BEFORE ANY POPULATION IS DERIVED
// ═══════════════════════════════════════════════════════════════════════════
const FENCES = ["friendly", "forbiddenEvidenceCopy", "readFailureCopy", "faultCopy"];
const fenceFns = new Map();
for (const f of fns) if (FENCES.includes(f.name) && !fenceFns.has(f.name)) fenceFns.set(f.name, f);
const missingFences = FENCES.filter((n) => !fenceFns.has(n));
if (missingFences.length) {
  console.error("");
  console.error("FAIL(2): A FENCE IS MISSING — this census REFUSES TO MEASURE " + LABEL);
  console.error("");
  for (const n of missingFences) console.error("  absent: function " + n + "(...)");
  console.error("");
  console.error("  This is exit 2 and NOT exit 1, and it fires BEFORE the ADD/REMOVE set diff on");
  console.error("  purpose. The ARG kind scores every one of its rows DELEGATED BY CONSTRUCTION,");
  console.error("  and that verdict is only true because these four functions exist and consult the");
  console.error("  server's own cause before reaching their fallback. With one of them gone, every");
  console.error("  ARG verdict in the pin is FICTION and the derived population silently collapses");
  console.error("  — a set diff run over that collapse would report a pile of REMOVEs, or, on a");
  console.error("  tree pinned afterwards, nothing at all.");
  console.error("");
  console.error("  If a fence was RENAMED, rename it in FENCES above in the same commit and re-cut");
  console.error("  the pin. If a fence was DELETED, this census's central argument no longer holds");
  console.error("  and the file needs re-reasoning, not re-pinning.");
  console.error("");
  process.exit(2);
}

// ═══════════════════════════════════════════════════════════════════════════
// THE EXTRACTOR
// ═══════════════════════════════════════════════════════════════════════════

const sha8 = (s) => crypto.createHash("sha1").update(s).digest("hex").slice(0, 8);
const normalize = (t) => t.replace(/\s+/g, " ").trim();

// A CAUSE-VOCABULARY LITERAL: a sentence a user reads, not a class name, a slug,
// a selector, an attribute soup or a two-word column label.
//
// The test runs on the TAG-STRIPPED residue, and that is load-bearing in BOTH
// directions. Markup must not be excluded wholesale — `notifDeliveriesErrorHtml`
// is a PURE HTML literal and it is one of the two live liars cch-w40-s1 exists to
// fix — but a markup literal carrying NO SENTENCE is scaffolding, not copy.
// MEASURED on main: without the strip, `siteDetailHtml`'s
// `"<a class=\"btn btn-ghost btn-sm site-open\" href=\""` and its `"Content type"`
// column label both entered the pin as refusal copy, because that function is
// predicate-anchored (it calls a fence deep inside) while most of its returns are
// page chrome. Stripping tags leaves those two with 0 and 2 prose words and drops
// both, while `"<a href=\"#sites\">Back to sites</a></p></div>"` — a real refusal's
// recovery link — keeps 3 and stays.
const stripTags = (n) => n.replace(/<[^>]*>/g, " ").replace(/&[a-z]+;/g, " ").replace(/\s+/g, " ").trim();
const isCopy = (n) => {
  const prose = stripTags(n);
  return prose.length >= 10 && /[A-Za-z]{3}/.test(prose) && prose.split(/\s+/).length >= 3;
};

// ── MAP: qualified by reference from inside a fence body ────────────────────
const fenceBodies = FENCES.map((n) => {
  const f = fenceFns.get(n);
  return mask.slice(f.start, f.end);
}).join("\n");

const mapRanges = [];
const mapRows = [];
{
  const re = /\bvar\s+([A-Z][A-Z0-9_]*)\s*=\s*\{/g;
  let m;
  while ((m = re.exec(mask))) {
    const open = mask.indexOf("{", m.index);
    let depth = 0, i = open;
    for (; i < mask.length; i++) {
      if (mask[i] === "{") depth++;
      else if (mask[i] === "}") { depth--; if (depth === 0) { i++; break; } }
    }
    const name = m[1];
    mapRanges.push({ name, start: m.index, end: i, open, close: i - 1 });
  }
}
const referencedInFence = (name) =>
  new RegExp("\\b" + name + "\\b").test(fenceBodies);
const qualifiedMaps = mapRanges.filter((r) => referencedInFence(r.name));
for (const r of qualifiedMaps) {
  // members at depth 1 only: `key: "literal"` / `"key": "literal"`
  const body = mask.slice(r.open, r.close + 1);
  const re = /(?:^|[{,])\s*(?:([A-Za-z_$][A-Za-z0-9_$]*)|"([^"]+)"|'([^']+)')\s*:\s*(["'])/g;
  let m;
  while ((m = re.exec(body))) {
    const at = r.open + m.index + m[0].length - 1;   // offset of the opening quote
    // depth check: the member must sit at depth 1 inside this map
    let depth = 0;
    for (let k = r.open; k < at; k++) {
      if (mask[k] === "{") depth++;
      else if (mask[k] === "}") depth--;
    }
    if (depth !== 1) continue;
    const lit = strings.find((s) => s.start === at);
    if (!lit) continue;
    const key = m[1] || m[2] || m[3];
    mapRows.push({
      kind: "MAP",
      key: `MAP|${r.name}.${key}`,
      fn: r.name,
      literal: normalize(lit.text),
      line: lineOf(at),
      start: at,
    });
  }
}
const inQualifiedMap = (pos) => qualifiedMaps.some((r) => r.start <= pos && pos < r.end);

// ── refusal predicates + the naming convention ──────────────────────────────
const NAMING_CONVENTION = /(ErrorHtml|FailureCopy|ErrorCopy|RefusalToast|RefusalCopy|FailureHtml)$/;
const PREDICATES = [
  /\bstatus\s*===?\s*4\d\d\b/,
  /\.status\s*===?\s*4\d\d\b/,
  /\.error\s*===/,
  new RegExp("\\b(" + FENCES.join("|") + ")\\s*\\("),
];
const isRefusalRenderer = (f) => {
  if (NAMING_CONVENTION.test(f.name)) return { by: "name" };
  const body = mask.slice(f.start, f.end);
  for (const p of PREDICATES) if (p.test(body)) return { by: "predicate" };
  return null;
};
const renderers = new Map();   // start -> {fn, anchor}
for (const f of fns) {
  const a = isRefusalRenderer(f);
  if (a) renderers.set(f.start, { fn: f, anchor: a.by });
}

// ── COPY POSITION (1): return-statement ranges ──────────────────────────────
const returnRanges = [];
{
  const re = /\breturn\b/g;
  let m;
  while ((m = re.exec(mask))) {
    let depth = 0, i = m.index + 6;
    for (; i < mask.length; i++) {
      const c = mask[i];
      if (c === "(" || c === "[" || c === "{") depth++;
      else if (c === ")" || c === "]" || c === "}") { if (depth === 0) break; depth--; }
      else if (c === ";" && depth === 0) break;
    }
    returnRanges.push([m.index, i]);
  }
}
const inReturn = (pos) => returnRanges.some(([a, b]) => a <= pos && pos < b);

// ── COPY POSITION (2): fence-call argument ranges ───────────────────────────
// Split a call's argument list at TOP-LEVEL commas over `mask`, returning one
// [start,end) per argument. Nesting and (masked) string contents cannot end an
// argument.
function argRanges(m, openParen) {
  const out = [];
  let depth = 0, argStart = openParen + 1, i = openParen;
  for (; i < m.length; i++) {
    const c = m[i];
    if (c === "(" || c === "[" || c === "{") depth++;
    else if (c === ")" || c === "]" || c === "}") {
      depth--;
      if (depth === 0) { out.push([argStart, i]); break; }
    } else if (c === "," && depth === 1) {
      out.push([argStart, i]);
      argStart = i + 1;
    }
  }
  return out;
}

// The three DELEGATING renderers and the 0-based index of their FALLBACK slot.
//   friendly(data, fallback)                         -> 1
//   faultCopy(status, data, fallback, transport)     -> 2
//   ctl.fail(message, recoveryLabel, fn)             -> 0
const DELEGATORS = [
  { call: "friendly", re: /\bfriendly\s*\(/g, slot: 1 },
  { call: "faultCopy", re: /\bfaultCopy\s*\(/g, slot: 2 },
  { call: "ctl.fail", re: /\bctl\.fail\s*\(/g, slot: 0 },
];

const argRows = [];
const delegatedLiteralStarts = new Set();
for (const d of DELEGATORS) {
  const re = new RegExp(d.re.source, "g");
  let m;
  while ((m = re.exec(mask))) {
    const open = mask.indexOf("(", m.index + m[0].length - 1);
    if (open < 0) continue;
    const args = argRanges(mask, open);
    const slot = args[d.slot];
    if (!slot) continue;
    // The fallback slot must BE a literal (possibly parenthesised), not merely
    // contain one: `friendly(data, x || "…")` still delegates, and the literal
    // there is the callee's fallback all the same, so a containment test is the
    // right one — but the literal must be the slot's own, not a nested call's.
    const lit = strings.find((s) => s.start >= slot[0] && s.end <= slot[1]);
    if (!lit) continue;
    const n = normalize(lit.text);
    if (!isCopy(n)) continue;
    if (inQualifiedMap(lit.start)) continue;
    const f = innermost(lit.start);
    if (!f) continue;
    delegatedLiteralStarts.add(lit.start);
    argRows.push({
      kind: "ARG",
      key: `ARG|${f.name}|${d.call}|${sha8(n)}`,
      fn: f.name,
      fnStart: f.start,
      literal: n,
      line: lineOf(lit.start),
      start: lit.start,
    });
  }
}

// ── FN: copy-position literals inside a refusal renderer ────────────────────
// A literal already claimed by the ARG kind is NOT re-counted here. The two
// kinds PARTITION copy position: a fallback slot is ARG, everything else in a
// return or in a fence call's other arguments is FN.
const fenceCallArgRanges = [];
{
  for (const name of FENCES) {
    const re = new RegExp("\\b" + name + "\\s*\\(", "g");
    let m;
    while ((m = re.exec(mask))) {
      const open = mask.indexOf("(", m.index + m[0].length - 1);
      if (open < 0) continue;
      for (const r of argRanges(mask, open)) fenceCallArgRanges.push(r);
    }
  }
}
const inFenceArg = (pos) => fenceCallArgRanges.some(([a, b]) => a <= pos && pos < b);

const fnRows = [];
let bodyScopedCount = 0;   // the measured contrast the header claims
for (const lit of strings) {
  const f = innermost(lit.start);
  if (!f || !renderers.has(f.start)) continue;
  if (inQualifiedMap(lit.start)) continue;
  const n = normalize(lit.text);
  if (!isCopy(n)) continue;
  bodyScopedCount++;
  if (delegatedLiteralStarts.has(lit.start)) continue;
  if (!inReturn(lit.start) && !inFenceArg(lit.start)) continue;
  fnRows.push({
    kind: "FN",
    key: `FN|${f.name}|${sha8(n)}`,
    fn: f.name,
    fnStart: f.start,
    literal: n,
    line: lineOf(lit.start),
    start: lit.start,
  });
}

const allRows = [...mapRows, ...fnRows, ...argRows].sort((a, b) => a.line - b.line);

// ═══════════════════════════════════════════════════════════════════════════
// (2) THE DUPLICATE-KEY ARM — two DISTINCT function bodies, one derived key
// ═══════════════════════════════════════════════════════════════════════════
//
// Adopted from __binding_census.mjs's (2c). A key that two separate functions
// can both produce lets one site hide behind the other: the ADD arm sees the key
// already pinned and stays silent about a genuinely new sentence. app.js carries
// four duplicated function names (`run` x3, `paint` x3, `card` x2, `showErr` x2)
// and none of them collides today — the class is LATENT, which is why the arm has
// to be a check rather than a note. MAP rows are exempt by construction: a map
// name plus a member key is unique or the object literal itself is malformed.
{
  const byKey = new Map();
  for (const r of allRows) {
    if (r.kind === "MAP") continue;
    if (!byKey.has(r.key)) byKey.set(r.key, new Set());
    byKey.get(r.key).add(r.fnStart);
  }
  const collided = [...byKey.entries()].filter(([, starts]) => starts.size > 1);
  if (collided.length) {
    console.error("");
    console.error("FAIL(2): DERIVED KEY COLLISION — this census REFUSES TO MEASURE " + LABEL);
    console.error("");
    for (const [k, starts] of collided) {
      console.error("  " + k);
      for (const s of [...starts].sort((a, b) => a - b)) {
        console.error("      also declared at line " + lineOf(s));
      }
    }
    console.error("");
    console.error("  Two DISTINCT function bodies with the SAME NAME produced the SAME key. The whole");
    console.error("  instrument rests on a key naming one site: with a collision live, one of those");
    console.error("  sites is pinned and the other one is INVISIBLE — a new invented cause arrives,");
    console.error("  the ADD arm finds its key already in the pin, and the gate stays green over the");
    console.error("  exact class it exists to catch.");
    console.error("");
    console.error("  Rename one of the functions, or give the key a discriminator. Do NOT pin around");
    console.error("  it: a pin over an ambiguous key certifies nothing.");
    console.error("");
    process.exit(2);
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// THE PIN — a human judgment per key. NO ARM READS `verdict`.
// ═══════════════════════════════════════════════════════════════════════════
//
// AUTHORED  — the console invents this cause. It is what the census is FOR.
// CONSULTED — the sentence is reached only after the server's own cause was
//             read and found wanting (or found, and curated).
// DELEGATED — a fallback handed to a fence that provably consults. Every ARG
//             row is DELEGATED BY CONSTRUCTION and no other row may be.
//
// Whether these verdicts are STILL TRUE is the deferred drift arm; see the
// header. What this pin gates is the KEY SET, nothing else.
const PIN = [
  { key: "MAP|TRANSPORT_COPY.aborted", verdict: "AUTHORED", copy: "That request was cancelled before it finished — try it again." },
  { key: "MAP|TRANSPORT_COPY.offline", verdict: "AUTHORED", copy: "You're offline — reconnect, then retry." },
  { key: "MAP|ERRORS.invalid_credentials", verdict: "CONSULTED", copy: "Wrong email or password." },
  { key: "MAP|ERRORS.email_taken", verdict: "CONSULTED", copy: "That email is already registered." },
  { key: "MAP|ERRORS.email_invalid", verdict: "CONSULTED", copy: "Enter a valid email address." },
  { key: "MAP|ERRORS.password_invalid", verdict: "CONSULTED", copy: "Password is too short (12+ characters)." },
  { key: "MAP|ERRORS.validation_failed", verdict: "CONSULTED", copy: "Please check the form and try again." },
  { key: "MAP|ERRORS.name_required", verdict: "CONSULTED", copy: "A name is required." },
  { key: "MAP|ERRORS.no_active_subscription", verdict: "CONSULTED", copy: "You need an active subscription to launch." },
  { key: "MAP|ERRORS.plan_invalid", verdict: "CONSULTED", copy: "That plan can't be checked out." },
  { key: "MAP|ERRORS.invalid_code", verdict: "CONSULTED", copy: "That code didn't match. Authenticator codes rotate every 30..." },
  { key: "MAP|ERRORS.rate_limited", verdict: "CONSULTED", copy: "Too many attempts. Wait a moment, then try the code again." },
  { key: "MAP|ERRORS.no_team", verdict: "CONSULTED", copy: "Your account has no team yet." },
  { key: "MAP|ERRORS.invalid", verdict: "CONSULTED", copy: "That didn't work — check your input." },
  { key: "MAP|ERRORS.not_live", verdict: "CONSULTED", copy: "The instance isn't live yet — wait for provisioning to finish." },
  { key: "MAP|ERRORS.no_admin_token", verdict: "CONSULTED", copy: "No stored credentials for this instance — it may need a re-..." },
  { key: "MAP|ERRORS.instance_unreachable", verdict: "CONSULTED", copy: "Couldn't reach the instance — try again in a moment." },
  { key: "MAP|ERRORS.instance_not_armed", verdict: "CONSULTED", copy: "This instance hasn't armed one-click apply, so resuming aut..." },
  { key: "MAP|ERRORS.network_error", verdict: "CONSULTED", copy: "Network error — is the control plane running?" },
  { key: "MAP|ERRORS.limit_reached", verdict: "CONSULTED", copy: "You're at your plan's instance limit." },
  { key: "MAP|ERRORS.billing_not_configured", verdict: "CONSULTED", copy: "Billing isn't set up on this deployment yet." },
  { key: "MAP|ERRORS.suspended", verdict: "CONSULTED", copy: "This instance is suspended — Barkpark Cloud won't act on it..." },
  { key: "MAP|ERRORS.forbidden", verdict: "CONSULTED", copy: "You don't have permission to do that, and the refusal didn'..." },
  { key: "MAP|ERRORS.server_error", verdict: "CONSULTED", copy: "Something broke on our side — not your input. Try again in ..." },
  { key: "MAP|ERRORS.malformed_body", verdict: "CONSULTED", copy: "We couldn't read that request — reload the page and try again." },
  { key: "MAP|ERRORS.malformed_request", verdict: "CONSULTED", copy: "We couldn't read that request — reload the page and try again." },
  { key: "MAP|ERRORS.unsupported_media_type", verdict: "CONSULTED", copy: "We couldn't read that request — reload the page and try again." },
  { key: "MAP|ERRORS.request_too_large", verdict: "CONSULTED", copy: "That's too large for us to accept. Try a smaller value or f..." },
  { key: "MAP|ERRORS.checkout_failed", verdict: "CONSULTED", copy: "Couldn't start checkout — the payment provider didn't accep..." },
  { key: "MAP|ERRORS.portal_failed", verdict: "CONSULTED", copy: "Couldn't open the billing portal — the payment provider did..." },
  { key: "MAP|ERRORS.no_subscription", verdict: "CONSULTED", copy: "This team doesn't have a subscription yet — start one from ..." },
  { key: "MAP|ERRORS.live_twin", verdict: "CONSULTED", copy: "A live instance with that name already exists — decommissio..." },
  { key: "MAP|ERRORS.role_too_high", verdict: "CONSULTED", copy: "You can't grant a role higher than your own." },
  { key: "MAP|ERRORS.deploy_not_started", verdict: "CONSULTED", copy: "The deployment was recorded, but the build engine couldn't ..." },
  { key: "MAP|ERRORS.no_content_binding", verdict: "CONSULTED", copy: "This site has no content bound yet, so there is nothing to ..." },
  { key: "MAP|ERRORS.repo_not_in_installation", verdict: "CONSULTED", copy: "GitHub's app can no longer see that repository — grant it a..." },
  { key: "MAP|ERRORS.github_error", verdict: "CONSULTED", copy: "GitHub did not respond as expected — the problem is on GitH..." },
  { key: "MAP|ERRORS.invalid_name", verdict: "CONSULTED", copy: "That repository name isn't allowed — use only letters, numb..." },
  { key: "MAP|FORBIDDEN_ROLE_COPY.admin", verdict: "CONSULTED", copy: "You need the admin role on this team — an admin on this tea..." },
  { key: "MAP|FORBIDDEN_ROLE_COPY.owner", verdict: "CONSULTED", copy: "You need the owner role on this team — only the team owner ..." },
  { key: "MAP|FORBIDDEN_ROLE_COPY.platform_operator", verdict: "CONSULTED", copy: "That's limited to platform operators — no team role grants it." },
  { key: "MAP|FORBIDDEN_REASON_COPY.no_team", verdict: "CONSULTED", copy: "Your account isn't on a team yet, so no role can allow this..." },
  { key: "MAP|FORBIDDEN_REASON_COPY.outranked", verdict: "CONSULTED", copy: "You can only act on members whose role is below your own, a..." },
  { key: "MAP|FORBIDDEN_REASON_COPY.cannot_grant_higher_role", verdict: "CONSULTED", copy: "You can't grant a role above your own — that has to come fr..." },
  { key: "FN|forbiddenEvidenceCopy|3fb8e7ae", verdict: "UNREVIEWED", copy: "You need the \"" },
  { key: "FN|forbiddenEvidenceCopy|36412f8e", verdict: "UNREVIEWED", copy: "\" permission on this team — an admin on this team can grant..." },
  { key: "FN|friendly|bee54c9c", verdict: "UNREVIEWED", copy: "Something went wrong." },
  { key: "FN|fleetLoadErrorHtml|47aa7e66", verdict: "UNREVIEWED", copy: "<div class=\"empty-state\"><h2>Couldn\\'t load this instance</h2>" },
  { key: "ARG|fleetLoadErrorHtml|faultCopy|a8e3bd83", verdict: "DELEGATED", copy: "Check your connection and retry." },
  { key: "FN|fleetLoadErrorHtml|08e51fd2", verdict: "UNREVIEWED", copy: "<p class=\"muted\">The server replied:" },
  { key: "FN|siteLoadFailureHtml|586ec29e", verdict: "UNREVIEWED", copy: "<div class=\"empty-state\"><h2>Site not found</h2>" },
  { key: "FN|siteLoadFailureHtml|b7da7f2f", verdict: "UNREVIEWED", copy: "<p>It may have been removed. <a href=\"#sites\">Back to sites..." },
  { key: "FN|siteLoadFailureHtml|7fd8ac18", verdict: "UNREVIEWED", copy: "<div class=\"empty-state\"><h2>Couldn\\'t load this site</h2>" },
  { key: "FN|siteLoadFailureHtml|ab64f116", verdict: "UNREVIEWED", copy: "You don't have access to this site." },
  { key: "FN|siteLoadFailureHtml|b8e3b584", verdict: "UNREVIEWED", copy: "That site couldn't be loaded, and the answer didn't say why." },
  { key: "FN|siteLoadFailureHtml|08e51fd2", verdict: "UNREVIEWED", copy: "<p class=\"muted\">The server replied:" },
  { key: "FN|siteLoadFailureHtml|e8d0440b", verdict: "UNREVIEWED", copy: "<a href=\"#sites\">Back to sites</a></p></div>" },
  { key: "FN|deployLoadFailureHtml|6db31a34", verdict: "UNREVIEWED", copy: "<div class=\"empty-state\"><h2>Couldn\\'t load deployments</h2>" },
  { key: "FN|deployLoadFailureHtml|60241ead", verdict: "UNREVIEWED", copy: "You don't have access to this site's deployments." },
  { key: "FN|deployLoadFailureHtml|083a626e", verdict: "UNREVIEWED", copy: "The deployment history couldn't be loaded, and the answer d..." },
  { key: "FN|deployLoadFailureHtml|08e51fd2", verdict: "UNREVIEWED", copy: "<p class=\"muted\">The server replied:" },
  { key: "FN|accountTwoFactorErrorCopy|2cc1513b", verdict: "UNREVIEWED", copy: "That code didn't match. Check your authenticator app and en..." },
  { key: "FN|accountTwoFactorErrorCopy|7b0c80b9", verdict: "UNREVIEWED", copy: "That setup is no longer pending. Start again to get a fresh..." },
  { key: "ARG|run|ctl.fail|acff7839", verdict: "DELEGATED", copy: "Couldn't turn two-factor off." },
  { key: "ARG|run|friendly|2b55dad9", verdict: "DELEGATED", copy: "Couldn't sign out the other devices." },
  { key: "ARG|run|ctl.fail|2b55dad9", verdict: "DELEGATED", copy: "Couldn't sign out the other devices." },
  { key: "ARG|paint|friendly|ef103d43", verdict: "DELEGATED", copy: "That device is still signed in — please try again." },
  { key: "FN|archivesModel|235d365a", verdict: "UNREVIEWED", copy: "Couldn't load your archives — try again shortly." },
  { key: "FN|archivesModel|53d04325", verdict: "UNREVIEWED", copy: "bp cloud instance resurrect" },
  { key: "ARG|resurrectOutcome|friendly|b51728f6", verdict: "DELEGATED", copy: "Connect that provider first." },
  { key: "ARG|resurrectOutcome|friendly|ac0c96d4", verdict: "DELEGATED", copy: "Couldn't resurrect — please try again." },
  { key: "ARG|submitProviderCred|faultCopy|7f48376a", verdict: "DELEGATED", copy: "Check the details and try again." },
  { key: "FN|loadProviders|e28d68a0", verdict: "UNREVIEWED", copy: "You don't have access to this team's providers." },
  { key: "FN|loadProviders|dfafb552", verdict: "UNREVIEWED", copy: "We couldn't read this team's providers just now — try again..." },
  { key: "ARG|submitInlineProviderCred|faultCopy|7f48376a", verdict: "DELEGATED", copy: "Check the details and try again." },
  { key: "ARG|run|friendly|46436b0f", verdict: "DELEGATED", copy: "Couldn't disconnect. Try again." },
  { key: "ARG|run|ctl.fail|46436b0f", verdict: "DELEGATED", copy: "Couldn't disconnect. Try again." },
  { key: "ARG|githubDisconnectErrorToast|friendly|a51ebf0a", verdict: "DELEGATED", copy: "GitHub is still connected — try again in a moment." },
  { key: "FN|loadGithub|1ac72428", verdict: "UNREVIEWED", copy: "You don't have access to this team's GitHub connection." },
  { key: "FN|loadGithub|661d51ac", verdict: "UNREVIEWED", copy: "We couldn't read the GitHub connection just now — try again..." },
  { key: "FN|notifDeliveriesErrorHtml|44d4ebd1", verdict: "UNREVIEWED", copy: "You don't have access to this team's delivery log." },
  { key: "FN|notifDeliveriesErrorHtml|267cc933", verdict: "UNREVIEWED", copy: "<div class=\"wh-del-empty dim\">Couldn\\'t load the delivery l..." },
  { key: "ARG|loadMoreNotifDeliveries|friendly|83a6fd7b", verdict: "DELEGATED", copy: "Please try again." },
  { key: "FN|notifChatTestToast|70c92cd1", verdict: "UNREVIEWED", copy: "Couldn't send test" },
  { key: "FN|notifChatTestToast|5d7d9d3a", verdict: "UNREVIEWED", copy: "s before another test." },
  { key: "FN|notifChatTestToast|4a4e8864", verdict: "UNREVIEWED", copy: "The email and chat tests share one per-team limit." },
  { key: "ARG|notifChatTestToast|friendly|50a97fba", verdict: "DELEGATED", copy: "Try again shortly." },
  { key: "FN|notifChatTestToast|d2a41d46", verdict: "UNREVIEWED", copy: "Nothing to send to" },
  { key: "FN|notifChatTestToast|a721fcb7", verdict: "UNREVIEWED", copy: "No enabled, configured channel matched this test — nothing ..." },
  { key: "ARG|notifEmailTestToast|friendly|95eb3754", verdict: "DELEGATED", copy: "Couldn't send a test." },
  { key: "FN|notifEmailTestToast|cce88a1d", verdict: "UNREVIEWED", copy: "Test not sent" },
  { key: "FN|notifEmailTestToast|6cfc27fb", verdict: "UNREVIEWED", copy: "Test email sent" },
  { key: "FN|notifEmailTestToast|dbd657a2", verdict: "UNREVIEWED", copy: "Sent over the Barkpark platform transport." },
  { key: "FN|loadTokens|93fb01af", verdict: "UNREVIEWED", copy: "You don't have access to this team's API tokens." },
  { key: "FN|loadTokens|d87a7a14", verdict: "UNREVIEWED", copy: "We couldn't read your tokens just now — try again in a moment." },
  { key: "ARG|submitToken|faultCopy|42f3f653", verdict: "DELEGATED", copy: "Check the form and try again." },
  { key: "ARG|confirmRevokeToken|friendly|d9de0826", verdict: "DELEGATED", copy: "That token is still active — please try again." },
  { key: "FN|twoFactorErrorCopy|69797caf", verdict: "UNREVIEWED", copy: "Enter a recovery code." },
  { key: "FN|twoFactorErrorCopy|8c881549", verdict: "UNREVIEWED", copy: "Enter your 6-digit code." },
  { key: "FN|twoFactorErrorCopy|c26baa68", verdict: "UNREVIEWED", copy: "Couldn't verify that code just now — nothing changed. Pleas..." },
  { key: "ARG|submitReset|friendly|b08ce1a3", verdict: "DELEGATED", copy: "Couldn't reset your password." },
  { key: "ARG|submitAuth|friendly|3fd14b21", verdict: "DELEGATED", copy: "Couldn't sign you in." },
  { key: "ARG|openStudio|friendly|83a6fd7b", verdict: "DELEGATED", copy: "Please try again." },
  { key: "ARG|connectAgent|faultCopy|83a6fd7b", verdict: "DELEGATED", copy: "Please try again." },
  { key: "FN|loadFleet|d1b27ebe", verdict: "UNREVIEWED", copy: "You don't have access to this fleet." },
  { key: "FN|loadFleet|6ad5126d", verdict: "UNREVIEWED", copy: "Your fleet couldn't be loaded, and the answer didn't say why." },
  { key: "FN|loadOverview|d1b27ebe", verdict: "UNREVIEWED", copy: "You don't have access to this fleet." },
  { key: "FN|loadOverview|6ad5126d", verdict: "UNREVIEWED", copy: "Your fleet couldn't be loaded, and the answer didn't say why." },
  { key: "ARG|dismissRunway|friendly|83a6fd7b", verdict: "DELEGATED", copy: "Please try again." },
  { key: "ARG|runDecommission|friendly|83a6fd7b", verdict: "DELEGATED", copy: "Please try again." },
  { key: "ARG|retryInstance|friendly|83a6fd7b", verdict: "DELEGATED", copy: "Please try again." },
  { key: "ARG|removeInstance|friendly|83a6fd7b", verdict: "DELEGATED", copy: "Please try again." },
  { key: "FN|attachDomainFailureCopy|d5279146", verdict: "UNREVIEWED", copy: "That domain is already in use." },
  { key: "FN|attachDomainFailureCopy|a6b42b60", verdict: "UNREVIEWED", copy: "An attach is already running." },
  { key: "FN|attachDomainFailureCopy|6380565a", verdict: "UNREVIEWED", copy: "This instance already answers on" },
  { key: "FN|attachDomainFailureCopy|db8873f5", verdict: "UNREVIEWED", copy: "This instance already has a domain attached." },
  { key: "FN|attachDomainFailureCopy|ab0e8f9a", verdict: "UNREVIEWED", copy: "That doesn't look like a valid domain name." },
  { key: "ARG|attachDomainFailureCopy|friendly|6f7b7820", verdict: "DELEGATED", copy: "Something went wrong — please try again." },
  { key: "FN|addSupportErrorCopy|45d1a36b", verdict: "UNREVIEWED", copy: "This server has no stored admin credentials, so a support c..." },
  { key: "FN|addSupportErrorCopy|ca370b1b", verdict: "UNREVIEWED", copy: "You're at your plan's support-server limit." },
  { key: "ARG|addSupportErrorCopy|friendly|b230fdae", verdict: "DELEGATED", copy: "Couldn't add the support server — please try again." },
  { key: "FN|updateConflictCopy|fbbaa42b", verdict: "UNREVIEWED", copy: "You can't update this instance" },
  { key: "FN|updateConflictCopy|0deec518", verdict: "UNREVIEWED", copy: "This instance is pinned" },
  { key: "FN|updateConflictCopy|b4c2aa5e", verdict: "UNREVIEWED", copy: "Autoupdate is frozen" },
  { key: "FN|updateConflictCopy|6fc4cebc", verdict: "UNREVIEWED", copy: ". Pinning holds an instance at or above its" },
  { key: "FN|updateConflictCopy|49c1af1a", verdict: "UNREVIEWED", copy: "current version; it does not roll back. Update anyway to ov..." },
  { key: "FN|updateConflictCopy|0064f9e5", verdict: "UNREVIEWED", copy: "An update is already running" },
  { key: "FN|updateConflictCopy|7f909935", verdict: "UNREVIEWED", copy: "Give it a moment to finish." },
  { key: "FN|updateConflictCopy|a91cd5d2", verdict: "UNREVIEWED", copy: "Self-update is not enabled on this instance" },
  { key: "FN|updateConflictCopy|3559c106", verdict: "UNREVIEWED", copy: "Set BARKPARK_SELF_UPDATE_APPLY=1 on the box to allow one-cl..." },
  { key: "FN|updateConflictCopy|c2ebc510", verdict: "UNREVIEWED", copy: "This instance isn't live yet" },
  { key: "FN|updateConflictCopy|edb0377c", verdict: "UNREVIEWED", copy: "Wait until it finishes provisioning." },
  { key: "FN|updateConflictCopy|bf378f12", verdict: "UNREVIEWED", copy: "The instance refused our credential" },
  { key: "FN|updateConflictCopy|cf1e433e", verdict: "UNREVIEWED", copy: "The update was never sent —" },
  { key: "FN|updateConflictCopy|be21a51e", verdict: "UNREVIEWED", copy: ". Barkpark Cloud stops asking a box that refused it; the ho..." },
  { key: "FN|updateConflictCopy|2dd34ae3", verdict: "UNREVIEWED", copy: "check is what notices the credential working again." },
  { key: "FN|updateConflictCopy|2ffd9b48", verdict: "UNREVIEWED", copy: "The update wasn't sent" },
  { key: "FN|updateConflictCopy|e4e8990a", verdict: "UNREVIEWED", copy: "We can't read this instance's stored credential" },
  { key: "FN|updateConflictCopy|c219d5e5", verdict: "UNREVIEWED", copy: "The stored admin credential didn't decrypt on our side, so ..." },
  { key: "FN|updateConflictCopy|6e8d9054", verdict: "UNREVIEWED", copy: "The update needs a stored credential" },
  { key: "FN|updateConflictCopy|810311c9", verdict: "UNREVIEWED", copy: "This instance no longer exists" },
  { key: "FN|updateConflictCopy|210457b7", verdict: "UNREVIEWED", copy: "The control plane has no record of it — it may already have..." },
  { key: "FN|updateConflictCopy|774df0b7", verdict: "UNREVIEWED", copy: "Self-update isn't available here" },
  { key: "FN|updateConflictCopy|10151abf", verdict: "UNREVIEWED", copy: "This box doesn't carry the self-update route, so there's no..." },
  { key: "FN|updateConflictCopy|e3ade81a", verdict: "UNREVIEWED", copy: "The update didn't start" },
  { key: "FN|updateConflictCopy|80b9d696", verdict: "UNREVIEWED", copy: "The instance accepted the request but its update runner fai..." },
  { key: "FN|updateConflictCopy|602f39cd", verdict: "UNREVIEWED", copy: "Couldn't start the update" },
  { key: "FN|updateConflictCopy|a917db7a", verdict: "UNREVIEWED", copy: "Please try again in a moment." },
  { key: "FN|rollbackConflictCopy|f414aad1", verdict: "UNREVIEWED", copy: "You can't roll back this instance" },
  { key: "FN|rollbackConflictCopy|cca8eb0b", verdict: "UNREVIEWED", copy: "Nothing to roll back to" },
  { key: "FN|rollbackConflictCopy|5e8ee88c", verdict: "UNREVIEWED", copy: "No previous slot build to roll back to — nothing was record..." },
  { key: "FN|rollbackConflictCopy|38b79751", verdict: "UNREVIEWED", copy: "already recycled by a newer deploy." },
  { key: "FN|rollbackConflictCopy|e927ec79", verdict: "UNREVIEWED", copy: "An update or rollback is already running" },
  { key: "FN|rollbackConflictCopy|de7f34bf", verdict: "UNREVIEWED", copy: "Give it a moment to finish, then try again." },
  { key: "FN|rollbackConflictCopy|2256a299", verdict: "UNREVIEWED", copy: "Rollback isn't available here" },
  { key: "FN|rollbackConflictCopy|144b2eee", verdict: "UNREVIEWED", copy: "This isn't a blue/green slot box — there's no previous slot..." },
  { key: "FN|rollbackConflictCopy|58b7b0ca", verdict: "UNREVIEWED", copy: "Rollback is not enabled on this instance" },
  { key: "FN|rollbackConflictCopy|b0ceb287", verdict: "UNREVIEWED", copy: "Set BARKPARK_SELF_UPDATE_APPLY=1 on the box to allow one-cl..." },
  { key: "FN|rollbackConflictCopy|c2ebc510", verdict: "UNREVIEWED", copy: "This instance isn't live yet" },
  { key: "FN|rollbackConflictCopy|edb0377c", verdict: "UNREVIEWED", copy: "Wait until it finishes provisioning." },
  { key: "FN|rollbackConflictCopy|aad0405d", verdict: "UNREVIEWED", copy: "Couldn't reach the instance" },
  { key: "FN|rollbackConflictCopy|3ad7438e", verdict: "UNREVIEWED", copy: "The box didn't answer. Give it a moment and try again." },
  { key: "FN|rollbackConflictCopy|7c403499", verdict: "UNREVIEWED", copy: "The instance rejected the rollback" },
  { key: "FN|rollbackConflictCopy|90299e38", verdict: "UNREVIEWED", copy: "The box couldn't complete the rollback — check its logs, th..." },
  { key: "FN|rollbackConflictCopy|bf378f12", verdict: "UNREVIEWED", copy: "The instance refused our credential" },
  { key: "FN|rollbackConflictCopy|451c7a9c", verdict: "UNREVIEWED", copy: "The rollback was never sent —" },
  { key: "FN|rollbackConflictCopy|be21a51e", verdict: "UNREVIEWED", copy: ". Barkpark Cloud stops asking a box that refused it; the ho..." },
  { key: "FN|rollbackConflictCopy|2dd34ae3", verdict: "UNREVIEWED", copy: "check is what notices the credential working again." },
  { key: "FN|rollbackConflictCopy|c86b7c47", verdict: "UNREVIEWED", copy: "The rollback wasn't sent" },
  { key: "FN|rollbackConflictCopy|e4e8990a", verdict: "UNREVIEWED", copy: "We can't read this instance's stored credential" },
  { key: "FN|rollbackConflictCopy|79b0db43", verdict: "UNREVIEWED", copy: "The stored admin credential didn't decrypt on our side, so ..." },
  { key: "FN|rollbackConflictCopy|809b13b3", verdict: "UNREVIEWED", copy: "The rollback needs a stored credential" },
  { key: "FN|rollbackConflictCopy|810311c9", verdict: "UNREVIEWED", copy: "This instance no longer exists" },
  { key: "FN|rollbackConflictCopy|210457b7", verdict: "UNREVIEWED", copy: "The control plane has no record of it — it may already have..." },
  { key: "FN|rollbackConflictCopy|c43bb25d", verdict: "UNREVIEWED", copy: "The instance isn't answering right now" },
  { key: "FN|rollbackConflictCopy|2ef71136", verdict: "UNREVIEWED", copy: "Its front proxy is restarting, so the rollback wasn't accep..." },
  { key: "FN|rollbackConflictCopy|98aa4e19", verdict: "UNREVIEWED", copy: "Couldn't start the rollback" },
  { key: "FN|rollbackConflictCopy|a917db7a", verdict: "UNREVIEWED", copy: "Please try again in a moment." },
  { key: "ARG|patchAutoupdate|friendly|83a6fd7b", verdict: "DELEGATED", copy: "Please try again." },
  { key: "ARG|fleetRolloutAction|friendly|83a6fd7b", verdict: "DELEGATED", copy: "Please try again." },
  { key: "FN|operatorReadFault|c3b2e2d6", verdict: "UNREVIEWED", copy: "The control plane refused this read (403)." },
  { key: "FN|operatorReadFault|2cf419c7", verdict: "UNREVIEWED", copy: "That says nothing about the fleet itself." },
  { key: "FN|operatorReadFault|dad627be", verdict: "UNREVIEWED", copy: "Your session is no longer accepted here (401). Sign in agai..." },
  { key: "FN|operatorReadFault|a5b0ceb4", verdict: "UNREVIEWED", copy: "The request never reached the control plane, so there is no..." },
  { key: "ARG|operatorConfirmBrake|friendly|83a6fd7b", verdict: "DELEGATED", copy: "Please try again." },
  { key: "ARG|operatorConfirmBrake|ctl.fail|83a6fd7b", verdict: "DELEGATED", copy: "Please try again." },
  { key: "FN|loadInstanceSites|00ee8a15", verdict: "UNREVIEWED", copy: "You don't have access to the sites on this instance." },
  { key: "FN|loadInstanceSites|1cf6149e", verdict: "UNREVIEWED", copy: "We couldn't read this instance's sites — try again in a mom..." },
  { key: "FN|siteCreateFailureCopy|3b49b7b9", verdict: "UNREVIEWED", copy: "It can read:" },
  { key: "FN|siteCreateFailureCopy|50ccce12", verdict: "UNREVIEWED", copy: "\\u2014 pick one of those as the content type above." },
  { key: "FN|siteCreateFailureCopy|b15db55d", verdict: "UNREVIEWED", copy: "this site would build from nothing \\u2014 the content you b..." },
  { key: "FN|siteCreateFailureCopy|69b3ccfa", verdict: "UNREVIEWED", copy: "Check the workspace/project/dataset and content type above." },
  { key: "FN|siteCreateFailureCopy|65392db8", verdict: "UNREVIEWED", copy: "This site needs content to build from \\u2014 fill in the wo..." },
  { key: "FN|siteCreateFailureCopy|749e943d", verdict: "UNREVIEWED", copy: "This instance is gone \\u2014 refresh and pick another." },
  { key: "FN|siteCreateFailureCopy|29a7801c", verdict: "UNREVIEWED", copy: "This instance has no free port left for another node site \\..." },
  { key: "FN|siteCreateFailureCopy|10463e93", verdict: "UNREVIEWED", copy: "Something broke on our side minting this site's read token ..." },
  { key: "FN|siteCreateFailureCopy|288edef3", verdict: "UNREVIEWED", copy: "Try again in a moment." },
  { key: "FN|webhookErrorHtml|a7adcc68", verdict: "UNREVIEWED", copy: "bp cloud update" },
  { key: "FN|webhookMutationError|7f668201", verdict: "UNREVIEWED", copy: "Couldn't reach the instance — the change is unconfirmed." },
  { key: "FN|webhookMutationError|a052e1db", verdict: "UNREVIEWED", copy: "This instance needs an update to manage webhooks." },
  { key: "ARG|webhookMutationError|faultCopy|d0fc6b0a", verdict: "DELEGATED", copy: "Please check the details and try again." },
  // cch-w31-bl — the sibling of the row above, and pinned the same way for the
  // same reason. This sentence used to be webhookErrorHtml's BARE terminal
  // fall-through; it is now the 4xx-only fallback ARGUMENT to faultCopy, so a
  // 5xx and a status-0 never reach it and the site is DELEGATED, not AUTHORED.
  { key: "ARG|webhookErrorHtml|faultCopy|ff43a844", verdict: "DELEGATED", copy: "Something went wrong reaching this instance." },
  { key: "ARG|loadTimeline|faultCopy|a8e3bd83", verdict: "DELEGATED", copy: "Check your connection and retry." },
  { key: "FN|loadInstanceVerify|b0f904bc", verdict: "UNREVIEWED", copy: "You don't have access to this instance's events." },
  { key: "FN|loadInstanceVerify|4ae00515", verdict: "UNREVIEWED", copy: "The verification history couldn't be loaded, and the answer..." },
  { key: "ARG|runVerifyNow|friendly|a917db7a", verdict: "DELEGATED", copy: "Please try again in a moment." },
  { key: "FN|loadSites|614c12ac", verdict: "UNREVIEWED", copy: "You don't have access to these sites." },
  { key: "FN|loadSites|b0f4e267", verdict: "UNREVIEWED", copy: "Your sites couldn't be loaded, and the answer didn't say why." },
  { key: "ARG|loadSites|faultCopy|7d61278b", verdict: "DELEGATED", copy: "The instance list couldn't be loaded, and the answer didn't..." },
  { key: "ARG|siteThemeFailureCopy|faultCopy|565479bc", verdict: "DELEGATED", copy: "We couldn't set the theme. Try again in a moment." },
  { key: "FN|sitePreviewsSectionHtml|eacf1ac8", verdict: "UNREVIEWED", copy: "<div class=\"empty-state\"><h2>Couldn\\'t load branch previews..." },
  { key: "FN|sitePreviewsSectionHtml|5e55ce3f", verdict: "UNREVIEWED", copy: "You don't have access to this site's branch previews." },
  { key: "FN|sitePreviewsSectionHtml|fc7aea97", verdict: "UNREVIEWED", copy: "The branch previews couldn't be loaded, and the answer didn..." },
  { key: "FN|sitePreviewsSectionHtml|1bd0253b", verdict: "UNREVIEWED", copy: "This says nothing about which branches are being served — r..." },
  { key: "FN|sitePreviewsSectionHtml|08e51fd2", verdict: "UNREVIEWED", copy: "<p class=\"muted\">The server replied:" },
  { key: "FN|sitePreviewsSectionHtml|e89dc6b5", verdict: "UNREVIEWED", copy: "<div class=\"empty-state\"><h2>Branch previews are off</h2>" },
  { key: "FN|sitePreviewsSectionHtml|8f1be5d5", verdict: "UNREVIEWED", copy: "<p>This site has branch previews turned off, so pushing a b..." },
  { key: "FN|sitePreviewsSectionHtml|0518bdaf", verdict: "UNREVIEWED", copy: "Turn them on with <span class=\\\"mono\\\">bp cloud site settin..." },
  { key: "FN|sitePreviewsSectionHtml|e7ec0c7a", verdict: "UNREVIEWED", copy: "<div class=\"empty-state\"><h2>No branch previews are being s..." },
  { key: "FN|sitePreviewsSectionHtml|527cc320", verdict: "UNREVIEWED", copy: "<p>This lists the previews the instance is serving right no..." },
  { key: "FN|sitePreviewsSectionHtml|821a1ecc", verdict: "UNREVIEWED", copy: "or was torn down when the branch was deleted, is not listed..." },
  { key: "FN|sitePreviewsSectionHtml|107dba76", verdict: "UNREVIEWED", copy: "what has been pushed.</p></div>" },
  { key: "ARG|siteDetailHtml|faultCopy|43d5ca9a", verdict: "DELEGATED", copy: "the read failed without saying why." },
  { key: "FN|siteDetailHtml|de26153d", verdict: "UNREVIEWED", copy: "<a class=\"btn btn-ghost btn-sm site-open\" href=\"" },
  { key: "FN|siteDetailHtml|603d2106", verdict: "UNREVIEWED", copy: "\" target=\"_blank\" rel=\"noopener\">Visit&nbsp;&#8599;</a>" },
  { key: "ARG|openSiteEnvModal|friendly|b73c595e", verdict: "DELEGATED", copy: "Couldn’t replace the environment. Please try again." },
  { key: "FN|promoteFailure|ea518d79", verdict: "UNREVIEWED", copy: "A build for this git ref is already in progress — it has to..." },
  { key: "FN|promoteFailure|abbac6d5", verdict: "UNREVIEWED", copy: "That deployment isn't on this site any more — this list may..." },
  { key: "FN|promoteFailure|03de19dd", verdict: "UNREVIEWED", copy: "Branch previews can't be promoted to production." },
  { key: "FN|promoteFailure|2daa1357", verdict: "UNREVIEWED", copy: "This deployment has no stored artifact and the site has no ..." },
  { key: "FN|promoteFailure|2374866a", verdict: "UNREVIEWED", copy: "Couldn't reach the control plane — check your connection." },
  { key: "ARG|promoteFailure|friendly|30d6c7d4", verdict: "DELEGATED", copy: "The new deployment couldn't be created." },
  { key: "FN|siteRollbackFailure|7f75b122", verdict: "UNREVIEWED", copy: "This site can't be rolled back in place" },
  { key: "FN|siteRollbackFailure|dc702835", verdict: "UNREVIEWED", copy: "It rebuilds a fresh image on every deploy, so there's no pr..." },
  { key: "FN|siteRollbackFailure|51b52b96", verdict: "UNREVIEWED", copy: "back to. Use “Roll back to this” on an earlier deployment t..." },
  { key: "FN|siteRollbackFailure|cca8eb0b", verdict: "UNREVIEWED", copy: "Nothing to roll back to" },
  { key: "FN|siteRollbackFailure|177bd590", verdict: "UNREVIEWED", copy: "This site has only ever had one release — there's no previo..." },
  { key: "FN|siteRollbackFailure|51bcb54b", verdict: "UNREVIEWED", copy: "Nothing to roll back" },
  { key: "FN|siteRollbackFailure|e9c49fe6", verdict: "UNREVIEWED", copy: "This site has no live release yet — there is nothing to rol..." },
  { key: "FN|siteRollbackFailure|26944210", verdict: "UNREVIEWED", copy: "A deploy is already running" },
  { key: "FN|siteRollbackFailure|cb704eac", verdict: "UNREVIEWED", copy: "Let the in-flight deploy finish, then roll back." },
  { key: "FN|siteRollbackFailure|907c3c0f", verdict: "UNREVIEWED", copy: "Couldn't roll back" },
  { key: "FN|siteRollbackFailure|8468bb50", verdict: "UNREVIEWED", copy: "The deploy plane refused the rollback and didn't say why." },
  { key: "ARG|siteRollbackFailure|friendly|a917db7a", verdict: "DELEGATED", copy: "Please try again in a moment." },
  { key: "FN|siteDeleteFailureCopy|bf378f12", verdict: "UNREVIEWED", copy: "The instance refused our credential" },
  { key: "FN|siteDeleteFailureCopy|22f19c40", verdict: "UNREVIEWED", copy: "The teardown was never sent —" },
  { key: "FN|siteDeleteFailureCopy|00469fd9", verdict: "UNREVIEWED", copy: ". Barkpark Cloud stops asking a box that refused it; the ho..." },
  { key: "FN|siteDeleteFailureCopy|83fec6e9", verdict: "UNREVIEWED", copy: "notices the credential working again. The site is still reg..." },
  { key: "FN|siteDeleteFailureCopy|0c5375ad", verdict: "UNREVIEWED", copy: "You're signed out" },
  { key: "FN|siteDeleteFailureCopy|933aef20", verdict: "UNREVIEWED", copy: "This session is no longer valid, so nothing was sent and no..." },
  { key: "FN|siteDeleteFailureCopy|1bb4149f", verdict: "UNREVIEWED", copy: "Sign in again, then re-open this site." },
  { key: "FN|siteDeleteFailureCopy|48398c91", verdict: "UNREVIEWED", copy: "This site isn't there to delete" },
  { key: "FN|siteDeleteFailureCopy|b9b56779", verdict: "UNREVIEWED", copy: "The control plane has no site with this id for your team. T..." },
  { key: "FN|siteDeleteFailureCopy|2a4c0b35", verdict: "UNREVIEWED", copy: "once a site is already deleted — the outcome you asked for ..." },
  { key: "FN|siteDeleteFailureCopy|cc50ded6", verdict: "UNREVIEWED", copy: "in another team, an id that never existed, and a session wi..." },
  { key: "FN|siteDeleteFailureCopy|9585a1f5", verdict: "UNREVIEWED", copy: "which one it is." },
  { key: "FN|siteDeleteFailureCopy|74455c7d", verdict: "UNREVIEWED", copy: "The site is torn down but still registered" },
  { key: "FN|siteDeleteFailureCopy|9dbc6497", verdict: "UNREVIEWED", copy: "The instance was torn down, but the control plane could not..." },
  { key: "FN|siteDeleteFailureCopy|854628d5", verdict: "UNREVIEWED", copy: "Contact support to have the leftover registration removed." },
  { key: "FN|siteDeleteFailureCopy|09875bf3", verdict: "UNREVIEWED", copy: "This delete failed partway through" },
  { key: "FN|siteDeleteFailureCopy|ef8aca99", verdict: "UNREVIEWED", copy: "The control plane crashed while deleting this site. The tea..." },
  { key: "FN|siteDeleteFailureCopy|7e784af3", verdict: "UNREVIEWED", copy: "may already have happened while the deregistration did not ..." },
  { key: "FN|siteDeleteFailureCopy|5c711e26", verdict: "UNREVIEWED", copy: "and the site can be left listed here with nothing serving b..." },
  { key: "FN|siteDeleteFailureCopy|5f61d0d0", verdict: "UNREVIEWED", copy: "when you report it." },
  { key: "FN|siteDeleteFailureCopy|c8520b2d", verdict: "UNREVIEWED", copy: "The instance didn't confirm the teardown" },
  { key: "FN|siteDeleteFailureCopy|bf25fa99", verdict: "UNREVIEWED", copy: "The instance never reported the teardown finished, so the c..." },
  { key: "FN|siteDeleteFailureCopy|3171cab0", verdict: "UNREVIEWED", copy: "either way — it may still be tearing down. The site is STIL..." },
  { key: "FN|siteDeleteFailureCopy|f45642c4", verdict: "UNREVIEWED", copy: "registered until a teardown is confirmed. Re-check to read ..." },
  { key: "FN|siteDeleteFailureCopy|ba611c6a", verdict: "UNREVIEWED", copy: "The instance couldn't tear this site down" },
  { key: "FN|siteDeleteFailureCopy|589bd06e", verdict: "UNREVIEWED", copy: "The instance refused the teardown and didn't say why." },
  { key: "FN|siteDeleteFailureCopy|83823d42", verdict: "UNREVIEWED", copy: "Nothing was deleted — the site is still registered." },
  { key: "FN|siteDeleteFailureCopy|aad0405d", verdict: "UNREVIEWED", copy: "Couldn't reach the instance" },
  { key: "FN|siteDeleteFailureCopy|99cea249", verdict: "UNREVIEWED", copy: "The teardown was never delivered — the instance didn't answ..." },
  { key: "FN|siteDeleteFailureCopy|ba689b1d", verdict: "UNREVIEWED", copy: "site is still registered. Check the instance's health, then..." },
  { key: "FN|siteDeleteFailureCopy|5024a11b", verdict: "UNREVIEWED", copy: "You're not allowed to delete this site" },
  { key: "FN|siteDeleteFailureCopy|de434939", verdict: "UNREVIEWED", copy: "Couldn't delete this site" },
  { key: "FN|siteDeleteFailureCopy|086291c0", verdict: "UNREVIEWED", copy: "The control plane refused and didn't say why." },
  { key: "FN|siteDeleteFailureCopy|a402baa1", verdict: "UNREVIEWED", copy: "The site is still registered." },
  { key: "ARG|createAndDeploy|friendly|79e253ee", verdict: "DELEGATED", copy: "The site was created — open it and press Deploy to try again." },
  { key: "ARG|runDeploy|friendly|83a6fd7b", verdict: "DELEGATED", copy: "Please try again." },
  { key: "ARG|openSiteGithub|friendly|f69d8f71", verdict: "DELEGATED", copy: "Couldn't load your repositories." },
  { key: "ARG|submitSiteGithub|friendly|83a6fd7b", verdict: "DELEGATED", copy: "Please try again." },
  { key: "ARG|disconnectSiteGithub|friendly|83a6fd7b", verdict: "DELEGATED", copy: "Please try again." },
  { key: "ARG|resumeStudioLogin|friendly|ca861173", verdict: "DELEGATED", copy: "Try again from the instance page." },
  { key: "ARG|submitLaunchFlow|friendly|83a6fd7b", verdict: "DELEGATED", copy: "Please try again." },
  { key: "ARG|renderLaunchPlan|friendly|83a6fd7b", verdict: "DELEGATED", copy: "Please try again." },
  { key: "ARG|renderBilling|faultCopy|a8e3bd83", verdict: "DELEGATED", copy: "Check your connection and retry." },
  { key: "ARG|openCancelPlanModal|friendly|25193b6e", verdict: "DELEGATED", copy: "Couldn't cancel your plan. Please try again." },
  { key: "ARG|openBillingPortal|friendly|a917db7a", verdict: "DELEGATED", copy: "Please try again in a moment." },
  { key: "ARG|subscribe|friendly|83a6fd7b", verdict: "DELEGATED", copy: "Please try again." },
  { key: "ARG|meFailureCopy|faultCopy|9cf070b7", verdict: "DELEGATED", copy: "We couldn't check your account. Retry in a moment." },
  { key: "FN|loadActivity|10aa429b", verdict: "UNREVIEWED", copy: "You don't have access to this activity." },
  { key: "FN|loadActivity|587c0f15", verdict: "UNREVIEWED", copy: "The activity feed couldn't be loaded, and the answer didn't..." },
  { key: "ARG|loadMoreActivity|friendly|83a6fd7b", verdict: "DELEGATED", copy: "Please try again." },
  { key: "FN|emailConfirmOutcome|a469e9da", verdict: "UNREVIEWED", copy: "Thanks — this address is verified." },
  { key: "FN|emailConfirmOutcome|f10f6898", verdict: "UNREVIEWED", copy: "That confirmation link is spent" },
  { key: "FN|emailConfirmOutcome|5ed668c6", verdict: "UNREVIEWED", copy: "It was already used, or it expired. Send yourself a fresh o..." },
  { key: "FN|emailConfirmOutcome|fee0e4ae", verdict: "UNREVIEWED", copy: "We couldn't confirm this address just now" },
  { key: "FN|emailConfirmOutcome|9e799c56", verdict: "UNREVIEWED", copy: "Nothing else changed. Open the link again in a moment." },
  { key: "ARG|renderNewTemplatesFailed|faultCopy|b31f9491", verdict: "DELEGATED", copy: "The template list couldn't be loaded, and the answer didn't..." },
  { key: "ARG|newSubmitAuth|friendly|3fd14b21", verdict: "DELEGATED", copy: "Couldn't sign you in." },
  { key: "FN|newLaunchRefusalToast|07bccf3b", verdict: "UNREVIEWED", copy: "Plan limit reached" },
  { key: "ARG|newLaunchRefusalToast|friendly|07d22ac2", verdict: "DELEGATED", copy: "You're at your plan's instance limit." },
  { key: "ARG|newLaunchRefusalToast|friendly|615f7d3f", verdict: "DELEGATED", copy: "We couldn't launch for this team." },
  { key: "ARG|newLaunchRefusalToast|friendly|83a6fd7b", verdict: "DELEGATED", copy: "Please try again." },
  { key: "ARG|newLaunch|friendly|83a6fd7b", verdict: "DELEGATED", copy: "Please try again." },
  { key: "ARG|renderNewPricing|friendly|83a6fd7b", verdict: "DELEGATED", copy: "Please try again." },
  { key: "ARG|newReadyHtml|faultCopy|132fed5c", verdict: "DELEGATED", copy: "the answer didn't say why." },
  { key: "ARG|newVercelDeploy|friendly|83a6fd7b", verdict: "DELEGATED", copy: "Please try again." },
  { key: "ARG|newCreateRepo|friendly|83a6fd7b", verdict: "DELEGATED", copy: "Please try again." },
  // siteUrlFailureCopy — extracted from newSubmitSiteUrl, which answered EVERY 422
  // on POST /v1/barkparks/:id/site-url with "check the URL". Each arm below was
  // judged against the route's own emitters in web/router.ex: url_required (:3776),
  // invalid_url (:3810), and the changeset `invalid` + details arm (:3838-3842).
  // All three codes are REAL and arrive at the status the arm reads, so every
  // sentence is reached only after the server's cause was read — CONSULTED, not
  // AUTHORED. The trailing pair is the unseen-slug fall-through: it names the
  // operation and asserts no cause, and its body delegates to friendly().
  { key: "FN|siteUrlFailureCopy|c3fca978", verdict: "CONSULTED", copy: "Enter your site URL" },
  { key: "FN|siteUrlFailureCopy|d5038f99", verdict: "CONSULTED", copy: "The request didn't carry a URL. Enter your site's full http..." },
  { key: "FN|siteUrlFailureCopy|63aad4db", verdict: "CONSULTED", copy: "That doesn't look like a URL" },
  { key: "FN|siteUrlFailureCopy|bb6291b0", verdict: "CONSULTED", copy: "Enter your site's full https:// address." },
  { key: "FN|siteUrlFailureCopy|3a047715", verdict: "CONSULTED", copy: "Revalidation is wired \u2014 we couldn't record it" },
  { key: "FN|siteUrlFailureCopy|aa2ff59b", verdict: "CONSULTED", copy: "Your site URL is fine and the webhook is live. We couldn't ..." },
  { key: "FN|siteUrlFailureCopy|20c67d97", verdict: "CONSULTED", copy: "Couldn't wire revalidation" },
  { key: "ARG|siteUrlFailureCopy|friendly|83a6fd7b", verdict: "DELEGATED", copy: "Please try again." },
  { key: "ARG|newRenderFailed|friendly|83a6fd7b", verdict: "DELEGATED", copy: "Please try again." },
  { key: "FN|usageFailureCopy|8a810bac", verdict: "UNREVIEWED", copy: "Retry in a moment." },
  { key: "FN|usageFailureCopy|a9f20770", verdict: "UNREVIEWED", copy: "This instance isn't in your team, or has been removed." },
  { key: "FN|usageFailureCopy|b311e66a", verdict: "UNREVIEWED", copy: "Something broke on our side loading usage — not this instan..." },
  { key: "FN|usageFailureCopy|0d0033a4", verdict: "UNREVIEWED", copy: "We couldn't load usage for this instance. Retry in a moment." },
  { key: "FN|usageErrorHtml|9778186a", verdict: "UNREVIEWED", copy: "<div class=\"empty-state\"><h2>Couldn\\'t load usage</h2><p>" },
  { key: "FN|metricsFailureCopy|8a810bac", verdict: "UNREVIEWED", copy: "Retry in a moment." },
  { key: "FN|metricsFailureCopy|a9f20770", verdict: "UNREVIEWED", copy: "This instance isn't in your team, or has been removed." },
  { key: "FN|metricsFailureCopy|e8a9169f", verdict: "UNREVIEWED", copy: "Something broke on our side loading metrics — not this inst..." },
  { key: "FN|metricsFailureCopy|4eaa53ce", verdict: "UNREVIEWED", copy: "We couldn't load metrics for this instance. Retry in a moment." },
  { key: "FN|metricsErrorHtml|d87c50c8", verdict: "UNREVIEWED", copy: "<div class=\"empty-state\"><h2>Couldn\\'t load metrics</h2><p>" },
  { key: "FN|membersFailureCopy|68a8481c", verdict: "UNREVIEWED", copy: "Network error — is the control plane reachable? Retry in a ..." },
  { key: "FN|membersFailureCopy|204911ab", verdict: "UNREVIEWED", copy: "You don't have permission to view this team's members." },
  { key: "FN|membersFailureCopy|e118540e", verdict: "UNREVIEWED", copy: "We couldn't load your team's members. Retry in a moment." },
  { key: "FN|membersErrorHtml|e38e7cca", verdict: "UNREVIEWED", copy: "<div class=\"empty-state\"><h2>Couldn\\'t load members</h2><p>" },
  { key: "ARG|membersPanelHtml|faultCopy|6b6674a1", verdict: "DELEGATED", copy: "the list couldn't be loaded, and the answer didn't say why." },
  { key: "FN|inviteFailureCopy|3800b21a", verdict: "UNREVIEWED", copy: "That person is already on your team." },
  { key: "FN|inviteFailureCopy|8872b5f1", verdict: "UNREVIEWED", copy: "There's already a pending invitation for that address — rev..." },
  { key: "ARG|inviteFailureCopy|faultCopy|a448c5d3", verdict: "DELEGATED", copy: "Check the address and try again." },
  { key: "FN|roleChangeFailureCopy|3871abbb", verdict: "UNREVIEWED", copy: "You're the last owner — promote another member to owner first." },
  { key: "ARG|roleChangeFailureCopy|friendly|37eaf9f4", verdict: "DELEGATED", copy: "That role change didn't go through — please try again." },
  { key: "FN|removeMemberFailureCopy|cdc21050", verdict: "UNREVIEWED", copy: "You're the last owner — promote another member to owner bef..." },
  { key: "FN|removeMemberFailureCopy|c860f807", verdict: "UNREVIEWED", copy: "That member is no longer on the team." },
  { key: "ARG|removeMemberFailureCopy|friendly|83a6fd7b", verdict: "DELEGATED", copy: "Please try again." },
  { key: "ARG|confirmRevokeInvite|friendly|338c9e16", verdict: "DELEGATED", copy: "That invitation is still active — please try again." },
  { key: "ARG|submitActivateDecision|friendly|22201e0d", verdict: "DELEGATED", copy: "Nothing changed — please try again." },
  { key: "FN|offloadFileErrorCopy|009882c1", verdict: "UNREVIEWED", copy: "Couldn't reach the Barkpark — it may be offline, or its add..." },
  { key: "FN|offloadFileErrorCopy|f712989d", verdict: "UNREVIEWED", copy: "The app token was rejected — reload and try again." },
  { key: "ARG|offloadFileErrorCopy|friendly|3fddca35", verdict: "DELEGATED", copy: "Couldn't file the order — please try again." },
];

// ═══════════════════════════════════════════════════════════════════════════
// FIXTURE MODE — the committed positive/negative controls (charter D442)
// ═══════════════════════════════════════════════════════════════════════════
//
// A SMALL PIN, DELIBERATELY NOT THE LIVE ONE. A control keyed to the live
// population goes stale on every honest console change, and a control anchored to
// a real defect quietly acquires an interest in that defect surviving. These
// sites are INVENTED, so nothing anyone does to the console can make this proof
// stale and nothing anyone does to this proof can hold the console still.
//
// ONE MODE RUNS ONE ARM, so the two fixtures CROSS-CHECK: the add fixture under
// `--remove-check` and the remove fixture under `--add-check` must BOTH exit 0.
// That silence is the discrimination proof — without it, exit 1 on the matching
// cell would only show the control shouting, never that it can tell the arms
// apart.
//
// THE FIXTURES ARE PLAIN CODE, AND THAT IS A DELIBERATE SIMPLIFICATION OF THE
// PROTOTYPE. The prototype mutated app.js and therefore needed a `@census-sub`
// text-substitution directive to reach inside an existing object literal and
// append a MAP member — and that directive had a REAL BUG: a literal `\n` in the
// replacement text was inserted as two characters, which broke the member it was
// writing and produced a FALSE REMOVE (exit 1 where the cross cell required 0).
// This file needs no such directive: because FIXTURE_PIN is its OWN small pin,
// the fixtures can simply DECLARE their own maps and omit a member outright. The
// escape-interpretation bug is not fixed here, it is designed out.
//
// THE FIXTURE MECHANISM STILL GETS ITS OWN SELF-CHECK, because "a fixture is code
// and will lie if you let it" is true whatever the mechanism:
//   · the 2-and-2 FLOOR — one @must-flag row proves the mode is wired and nothing
//     about discrimination;
//   · REALITY of every @must-clear key — a negative control over an absent
//     subject is green by construction;
//   · DECLARED BUT SILENT / FIRED BUT MUST CLEAR / FIRED UNDECLARED — firing for
//     a reason the fixture does not claim exits 2 exactly like not firing at all.
if (FIXTURE_MODE) {
  const FIXTURE_PIN = [
    { key: "MAP|FIXTURE_ERRORS.forbidden", verdict: "AUTHORED" },
    { key: "MAP|FIXTURE_ERRORS.departed", verdict: "AUTHORED" },
    { key: "FN|fixturePinnedFailureCopy|" + sha8("The instance refused the check."), verdict: "AUTHORED" },
    { key: "ARG|fixtureDelegatingHandler|friendly|" + sha8("Couldn't apply that change. Try again."), verdict: "DELEGATED" },
  ];
  const ARMS = ["ADD", "REMOVE"];
  const IN_SCOPE = FIXTURE_MODE === "--add-check" ? ["ADD"] : ["REMOVE"];
  const inScope = (row) => IN_SCOPE.includes(row.split(" ")[0]);

  const dieFixture = (lines) => {
    console.error("");
    console.error("FAIL(2): the fixture control lost its footing — " + LABEL);
    for (const l of lines) console.error(l);
    console.error("");
    console.error("  This is NOT the census failing on the console. It is the control that proves the");
    console.error("  census CAN fail failing to behave as its own fixture declares. Fix the fixture or");
    console.error("  the arm — never the declaration alone.");
    process.exit(2);
  };

  // ── the declarations, read from the fixture's OWN bytes ───────────────────
  const flags = [];
  const clears = [];
  for (const m of src.matchAll(/^[ \t]*\/\/[ \t]*@(must-flag|must-clear)[ \t]+(.+?)[ \t]*$/gm)) {
    const [, kind, rest] = m;
    const am = rest.match(/^([A-Z-]+)[ \t]+(.+)$/);
    if (!am || !ARMS.includes(am[1])) {
      dieFixture(["  unparseable @" + kind + ": " + JSON.stringify(rest),
        "  shape: @" + kind + " <" + ARMS.join("|") + "> <key>"]);
    }
    (kind === "must-flag" ? flags : clears).push(am[1] + " " + am[2].trim());
  }
  if (flags.length < 2 || clears.length < 2) {
    dieFixture([`  declares ${flags.length} @must-flag and ${clears.length} @must-clear row(s); the floor is 2 and 2.`,
      "  One must-flag row proves the mode is wired. It does not prove the arm DISCRIMINATES —",
      "  for that the same run has to leave known-good rows alone (charter D442)."]);
  }

  // ── the observations, computed from the fixture, never from the declarations ─
  const fixturePinByKey = new Map(FIXTURE_PIN.map((r) => [r.key, r]));
  const liveKeys = new Set(allRows.map((r) => r.key));
  const observed = new Set();
  if (IN_SCOPE.includes("ADD")) {
    for (const k of liveKeys) if (!fixturePinByKey.has(k)) observed.add("ADD " + k);
  }
  if (IN_SCOPE.includes("REMOVE")) {
    for (const k of fixturePinByKey.keys()) if (!liveKeys.has(k)) observed.add("REMOVE " + k);
  }

  // ── every must-clear key must be REAL, or the negative control is theatre ──
  const unreal = [];
  for (const c of clears.filter(inScope)) {
    const key = c.split(" ").slice(1).join(" ");
    if (!fixturePinByKey.has(key)) {
      unreal.push(`  ${c} — FIXTURE_PIN carries no such row, so nothing could have cleared`);
    } else if (!liveKeys.has(key)) {
      unreal.push(`  ${c} — the fixture has no such live site, so nothing was exercised`);
    }
  }
  if (unreal.length) {
    dieFixture(["  a @must-clear row names something that does not exist:", ...unreal,
      "  A negative control over an absent subject is green by construction."]);
  }

  const scopedFlags = flags.filter(inScope);
  const scopedClears = clears.filter(inScope);
  const flagSet = new Set(scopedFlags);
  const missing = scopedFlags.filter((f) => !observed.has(f));
  const unexpected = [...observed].filter((o) => !flagSet.has(o));
  const firedClear = scopedClears.filter((c) => observed.has(c));

  console.log("fixture          :", LABEL);
  console.log("mode             :", FIXTURE_MODE, "· arms in scope:", IN_SCOPE.join(", "),
    "(fixture pin: " + FIXTURE_PIN.length + " rows · derived sites: " + allRows.length + ")");
  console.log("");
  console.log("  declared must-flag :" + (scopedFlags.length ? "" : " (none in scope — this is a CROSS cell)"));
  for (const f of scopedFlags) console.log("    " + (observed.has(f) ? "FIRED   " : "SILENT  ") + f);
  console.log("  declared must-clear:" + (scopedClears.length ? "" : " (none in scope)"));
  for (const c of scopedClears) console.log("    " + (observed.has(c) ? "FIRED   " : "clear   ") + c);
  const outOfScope = [...flags, ...clears].filter((r) => !inScope(r));
  if (outOfScope.length) console.log("  out of scope here  : " + outOfScope.length + " row(s) — " + IN_SCOPE.join("/") + " only");

  if (missing.length || unexpected.length || firedClear.length) {
    dieFixture([
      ...missing.map((f) => "  DECLARED BUT SILENT   " + f + "  — the arm did not fire on a case built to make it fire"),
      ...firedClear.map((c) => "  FIRED BUT MUST CLEAR  " + c + "  — the arm fires on a known-good row; it does not discriminate"),
      ...unexpected.map((o) => "  FIRED UNDECLARED      " + o + "  — the control fired for a reason it does not claim"),
    ]);
  }

  console.log("");
  if (observed.size) {
    console.log(`OK(1): all ${scopedFlags.length} declared arm(s) fired and all ${scopedClears.length} known-good row(s) stayed clear.`);
    console.log("       Exiting 1 — the same code the live ADD/REMOVE arm uses when it loses. 2 is");
    console.log("       reserved for an instrument that lost its footing, and a control that borrowed");
    console.log("       it would be indistinguishable from a broken one.");
    process.exit(1);
  }
  console.log(`OK(0): no ${IN_SCOPE.join("/")} observation on this fixture, and none was declared.`);
  console.log("       This is a CROSS cell of the 2x2: the fixture built to fire the OTHER arm leaves");
  console.log("       this one silent. Without that silence, exit 1 on the matching cell would only");
  console.log("       show the control shouting, never that it can tell the two arms apart.");
  process.exit(0);
}

// ═══════════════════════════════════════════════════════════════════════════
// (3) THE LIVE SET DIFF — ADD and REMOVE
// ═══════════════════════════════════════════════════════════════════════════
const pinByKey = new Map(PIN.map((r) => [r.key, r]));
if (pinByKey.size !== PIN.length) {
  const dupes = PIN.map((r) => r.key).filter((k, i, a) => a.indexOf(k) !== i);
  console.error("FAIL(2): duplicate PIN keys — a site is hiding behind another:");
  for (const d of new Set(dupes)) console.error("  " + d);
  process.exit(2);
}

const liveByKey = new Map();
for (const r of allRows) if (!liveByKey.has(r.key)) liveByKey.set(r.key, r);

const added = [...liveByKey.values()].filter((r) => !pinByKey.has(r.key));
const removed = PIN.filter((r) => !liveByKey.has(r.key));

// ── the report ──────────────────────────────────────────────────────────────
const count = (k) => allRows.filter((r) => r.kind === k).length;
const pinCount = (k) => PIN.filter((r) => r.key.startsWith(k + "|")).length;
const pad = (s, n) => (s.length >= n ? s : s + " ".repeat(n - s.length));

console.log("subject          :", LABEL);
console.log("fences           :", FENCES.map((n) => n + " ✓").join(" · "));
console.log("qualified maps   :", qualifiedMaps.map((m) => m.name).join(", ") || "(none)",
  "— of " + mapRanges.length + " all-caps object literals in the file");
console.log("renderers        :", renderers.size + " refusal renderers (" +
  [...renderers.values()].filter((r) => r.anchor === "predicate").length + " by predicate, " +
  [...renderers.values()].filter((r) => r.anchor === "name").length + " by naming convention)");
console.log("population       :", allRows.length + " sites · " +
  count("MAP") + " MAP, " + count("FN") + " FN, " + count("ARG") + " ARG · " +
  liveByKey.size + " distinct keys");
console.log("position scoping :", "FN is " + count("FN") + " position-scoped vs " + bodyScopedCount +
  " body-scoped — the difference is modal markup and doc-comment prose that a");
console.log("                   body-scoped scan would pin as refusal copy.");
console.log("pin size         :", PIN.length + " rows · " +
  pinCount("MAP") + " MAP, " + pinCount("FN") + " FN, " + pinCount("ARG") + " ARG");
const unreviewed = PIN.filter((r) => r.verdict === "UNREVIEWED").length;
console.log("verdicts         :", PIN.filter((r) => r.verdict === "AUTHORED").length + " AUTHORED, " +
  PIN.filter((r) => r.verdict === "CONSULTED").length + " CONSULTED, " +
  PIN.filter((r) => r.verdict === "DELEGATED").length + " DELEGATED, " + unreviewed + " UNREVIEWED");
console.log("                  ", "MAP and ARG verdicts are sound by construction; " + unreviewed + " FN rows carry no");
console.log("                  ", "judgment yet, and inventing one is how a pin starts lying. NO ARM READS THIS.");
console.log("");
console.log("maintenance cost : every copy edit inside a refusal renderer's return REDS THIS GATE —");
console.log("                   the FN and ARG keys hash the sentence, so changing the sentence is");
console.log("                   changing the site. That is correct and it is not free.");
console.log("");

// ── the crown-target report block (cch-w40-s1) ──────────────────────────────
// The one row this wave most needs to be able to name. It is printed BY KEY,
// unconditionally, so a reader can see with their own eyes that the census gives
// `ERRORS.forbidden` a key — the site that has NO enclosing function and would be
// invisible to any function-granular instrument.
console.log("crown target (cch-w40-s1) — the keys the crown moves:");
const CROWN = [/^MAP\|ERRORS\.forbidden$/, /^MAP\|FORBIDDEN_REASON_COPY\./, /^MAP\|FORBIDDEN_ROLE_COPY\./];
const crownRows = [...liveByKey.values()].filter((r) => CROWN.some((c) => c.test(r.key)));
for (const r of crownRows) {
  const p = pinByKey.get(r.key);
  console.log("    " + pad(r.key, 46) + " " + pad(p ? p.verdict : "UNPINNED", 10) +
    " " + LABEL + ":" + r.line + "  " + JSON.stringify(r.literal.slice(0, 58)));
}
if (!crownRows.some((r) => r.key === "MAP|ERRORS.forbidden")) {
  console.error("");
  console.error("FAIL(2): MAP|ERRORS.forbidden is NOT in the derived population.");
  console.error("  That key is the whole reason the MAP kind exists — the site has no enclosing");
  console.error("  function, so no function-granular selector can reach it. Its absence means the");
  console.error("  map-qualification rule stopped admitting ERRORS, not that the console improved.");
  process.exit(2);
}
console.log("");

if (added.length) {
  console.log("ADD — live sites with NO pinned key (" + added.length + "):");
  for (const r of added) {
    console.log("    " + pad(r.key, 60) + " " + LABEL + ":" + r.line + "  " + JSON.stringify(r.literal.slice(0, 70)));
  }
  console.log("");
}
if (removed.length) {
  console.log("REMOVE — pinned keys with NO live site (" + removed.length + "):");
  for (const r of removed) console.log("    " + pad(r.key, 60) + " " + r.verdict);
  console.log("");
}

if (added.length || removed.length) {
  console.error("FAIL(1): the refusal-copy population moved and the pin did not.");
  console.error("");
  if (added.length) {
    console.error("  " + added.length + " ADD — a refusal site the pin does not predict. THIS IS THE DISEASE the");
    console.error("  census exists for: a cause sentence arrived and no human judged whether the server");
    console.error("  can actually produce it. Read each one, decide AUTHORED / CONSULTED / DELEGATED,");
    console.error("  and add the row to PIN with that verdict. If the verdict is AUTHORED and the server");
    console.error("  has no emitter for it, the fix is the CONSOLE, not the pin.");
    console.error("");
  }
  if (removed.length) {
    console.error("  " + removed.length + " REMOVE — a pinned key with nothing behind it. THIS IS THE DECAY: the pin");
    console.error("  is still asserting a judgment about a site that is gone. Delete the row. A pin that");
    console.error("  describes a tree that no longer exists reads exactly like one that does.");
    console.error("");
  }
  console.error("  A COPY EDIT REDS THIS GATE, and that is correct — the FN key hashes the sentence,");
  console.error("  so changing the sentence is changing the site. Re-pin it deliberately.");
  process.exit(1);
}

console.log("OK: the refusal-copy population is exactly the pinned set — " + PIN.length + " keys, no ADD, no REMOVE.");
console.log("    Verdicts above are INFORMATIONAL: no arm reads them, and whether each is still true");
console.log("    is the deferred drift arm (see this file's header).");
process.exit(0);
