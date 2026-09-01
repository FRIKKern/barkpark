// cssom-parity.mjs — does EVERY authored rule on the ROSTER reach the browser?
//
// ─────────────────────────────────────────────────────────────────────────────
//  WHY THIS EXISTS (charter GR73 / GR93 / GR100)
// ─────────────────────────────────────────────────────────────────────────────
//  Of the nine mechanisms that certify this console's CSS, eight ask a question
//  about the FILE — they regex-extract app.css, or scan its comment nesting, or
//  read `--x:` declarations out of three token blocks. ZERO of them build a
//  CSSOM. That is exactly how bug #4592 stayed green for five waves: a lost
//  `/*` opener turned a REVIEW ADDENDUM paragraph into raw CSS, CSS error
//  recovery discarded tokens until the next `{…}` block — and the block it
//  recovered on was `.modal-root`'s own — so the base rule of a shared modal
//  primitive with 15+ call sites never reached the browser. Every modal in the
//  console rendered unpositioned beneath a fixed scrim, in production. Three
//  green gates certified the dead CSS the whole time.
//
//  A gate that cannot parse the artifact it certifies is not a gate.
//
//  This is the first check in the surface that parses the artifact rather than
//  a text projection of it. It loads each ROSTERED sheet in headless Chrome,
//  enumerates `document.styleSheets` recursively, and diffs the result against
//  the selectors the source file actually authors. Any authored selector with no
//  CSSOM counterpart is a MISS.
//
// ────────────────────────────────────────────────────────────────────────────────────
//  THE ROSTER — WHY IT IS A LIST AND NOT A CONSTANT
// ────────────────────────────────────────────────────────────────────────────────────
//  Through wave 7 this file certified `app.css` and NOTHING ELSE — `DEFAULT_CSS`
//  was a single path and the word "roster" appears nowhere. That was not a
//  declared scope, it was an unexamined one, and it left a SERVED surface with
//  no CSSOM check at all:
//
//    `cloud/priv/static/styleguide.html` carries 193 lines of CSS in an inline
//    `<style>` block (lines 10-202 of 841), and it sits in the `Plug.Static`
//    `only:` allowlist in `BarkparkCloud.Web.Router` — it is genuinely served to
//    browsers. Bug #4592 could happen there in exactly the same way, and NOTHING
//    would have seen it.
//
//  The one instrument that does open that block is pointed the other way.
//  `__css_check.mjs` harvests the styleguide's `class="…"` attributes and asks
//  whether **app.css** defines them — with the inline sheet's OWN selectors
//  explicitly EXEMPTED (`sgLocalClasses`, the analog of the `--sg-*` token
//  carve-out), because those classes are page-local by design. E12 opens the
//  block too, for `:focus` rules only, and honestly prints that the population is
//  empty. So every existing read of that sheet either exempts it or asks a
//  narrow question about a different file. The sheet itself was never parsed.
//
//  A LIST, THEN, RATHER THAN A SECOND CONSTANT. Two hard-coded paths would be a
//  bigger version of the same bug: the scope stays implicit and the next served
//  sheet is uncovered again in silence. `ROSTER` below is the gate's scope,
//  written down, and it is REFUSED (exit 2) rather than skipped when an entry
//  cannot be measured — see the roster preflight in main().
//
//  RELATIONSHIP TO ITS NEIGHBOURS — three tools, three scopes, no overlap:
//    · __css_check.mjs E10  — catches the SPECIFIC mechanism (an orphan `*/`
//      terminator) by walking the source text. Narrow, fast, in CI.
//    · modal-oracle.mjs     — catches the SPECIFIC victim (.modal-root) and its
//      rendered consequences. Narrow, browser-backed, unwired.
//    · this file            — catches the general CLASS: any authored top-level
//      selector the browser discards, for any reason, anywhere in the file.
//      Whole-stylesheet, browser-backed, unwired.
//
// ─────────────────────────────────────────────────────────────────────────────
//  TWO BINDING DESIGN RULINGS (GR100) — both are load-bearing, neither is style
// ─────────────────────────────────────────────────────────────────────────────
//  1. SYMMETRIC NORMALISATION, never an enumerated rewrite list.
//     Chrome re-serialises selectors, so a byte compare is useless. The obvious
//     fix — enumerate the known rewrites — is provably incomplete. GR73 recorded
//     TWO classes (comma-group flattening, `> *:pseudo` → `> :pseudo`) and a
//     THIRD was then found in a file containing exactly ONE affected selector:
//     Chrome strips whitespace inside the An+B microsyntax, serialising
//     `> *:nth-last-child(-n + 2)` as `> :nth-last-child(-n+2)`. A fourth class
//     is a coin-flip away. So BOTH sides go through ONE `normalise()` below.
//     Under symmetric normalisation an unknown serialisation class can only
//     cost sensitivity, never manufacture a false miss — which is the trade a
//     gate must make, because a gate that cries wolf is disabled within a wave.
//
//  2. BRACE-TRACKING PARSER, never a grep.
//     `app.css` holds 16 opaque at-rule blocks (@keyframes/@font-face/@property)
//     whose 21 percent-stop heads have NO `selectorText` and can never appear in
//     the CSSOM side, plus 40 multi-line comma continuations a line-oriented
//     grep splits into fragments. A grep manufactures ~37 spurious misses on a
//     perfectly clean file. The parser below skips opaque at-rules wholesale and
//     descends into grouping at-rules (@media/@supports/@container/@layer), so
//     both sides describe the same population by construction.
//
//  CALIBRATION. GR100 measured 1189 heads == 1189 CSSOM rules, 1158 flattened,
//  0 misses. This file measures 1200 == 1200, 1169 flattened, 0 misses — the
//  stylesheet grew 11 rules when #4733 gave six shipped class families their
//  CSS. Do NOT treat either absolute as the invariant; it goes stale every
//  wave. The invariant is `heads == CSSOM rules` and `MISSES == 0`, and both
//  censuses independently carry the same 31-rule head-to-flattened gap.
//
// ─────────────────────────────────────────────────────────────────────────────
//  MUTATION-PROVEN AT TWO LOCATIONS ~2000 LINES APART
// ─────────────────────────────────────────────────────────────────────────────
//  A green run means nothing unless the red is demonstrated.
//
//    cp cloud/priv/static/app.css /tmp/app.css.bak
//    perl -i -pe 's{/\\* REVIEW ADDENDUM}{REVIEW ADDENDUM} if $. == 1029' \
//      cloud/priv/static/app.css        # the #4592 defect, byte-for-byte
//    node cloud/priv/static/__preview__/cssom-parity.mjs   # exit 1, names .modal-root
//    cp /tmp/app.css.bak cloud/priv/static/app.css         # exit 0 again
//
//  Measured: MISSES 0 → 2 (one rule head, two comma fragments of one garbage
//  run) reporting `app.css:1034  .modal-root   ← SWALLOWED`, then 0 restored.
//  The same edit at `app.css:3076` (`/* Shown-once`) names `.wh-secret` at
//  `app.css:3077` — 2047 lines away, and THAT is the whole argument for this
//  instrument over more photographs: the check is FILE-WIDE, not modal-local.
//  (GR100 cites 986/3005; #4733's relocation shifted the file. The openers are
//  unchanged, and GR95 already records this one at :1029. Re-grep before
//  trusting any line number here — `grep -n 'REVIEW ADDENDUM' app.css`.)
//
//  A miss whose text contains `*/` is reported as an ORPHAN-COMMENT SWALLOW
//  cross-referencing E10 — without that, the miss reads as a nonsense selector
//  string and a cold reader files a bug against this gate instead of the CSS.
//
// ─────────────────────────────────────────────────────────────────────────────
//  RUN
// ─────────────────────────────────────────────────────────────────────────────
//    node cloud/priv/static/__preview__/cssom-parity.mjs   # the whole ROSTER
//    CSS=/path/to/other.css node cssom-parity.mjs      # certify ONE ad-hoc file
//                                                      # (.html → its inline <style>)
//    HEADS_BASELINE=/path    node cssom-parity.mjs     # override app.css's sidecar
//    CHROME=/path/to/chrome  node cssom-parity.mjs
//
//  Exit codes: 0 = every authored selector reached the CSSOM · 1 = at least one
//  MISS or a baseline-count mismatch — a fact about the CSS · 2 = GUARD (no Chrome,
//  no stylesheet, no baseline sidecar, wrong Node) — a fact about the ENVIRONMENT,
//  refused before anything is spawned, PLUS (D101) a Chrome that was spawned and
//  never came up, refused at the bring-up boundary. The 1/2 split is load-bearing,
//  see D19 and D101 below.
//
//  WIRED INTO CI (cch-w1-cssom-ci-wiring, epic decisions D17-D20). It runs as its
//  OWN job in .github/workflows/console-harness.yml — deliberately not a fourth
//  step of `console-unit`, which pins node-version: 20 and would fail here (D17).
//  It had been unwired on purpose (GR93(b)): a gate promoted before it is trusted
//  is a gate that gets disabled. It has now survived a wave of real use.
//
//  NOTE THE LIMIT, HONESTLY — AND NOTE THAT THE PREMISE FLIPPED. Through wave 8
//  this paragraph read "main is NOT branch-protected". That is FALSE as of
//  2026-07-28: `main` carries branch protection with `enforce_admins: true`, and
//  the required contexts are recorded in .github/required-checks.json. The limit
//  that survives is narrower and still real: THIS job is not one of them, so a red
//  here reds the PR page and does not yet block the merge. Registration is also NOT
//  "a human clicking in settings" — the roster is committed in
//  .github/required-checks.json and applied by scripts/required-checks-apply.sh, and
//  the name to register is the aggregator `Console gate`, never this leaf (a leaf can
//  be legitimately `skipped`). That registration is `cch-w9-register-console-and-cloud-gates`.
//
//  D19 — AN ENVIRONMENT FAILURE MUST EXIT 2, NOT 1. This instrument speaks CDP over
//  a bare global `WebSocket`, stable-by-default only from Node 22. Under Node 20 it
//  used to reach `Cdp.connect` — AFTER Chrome had already launched and answered
//  /json/version — throw `WebSocket is not defined`, and exit **1**: the code this
//  file reserves for "the CSS is broken". A misconfigured runner therefore reds a PR
//  with a message that reads like a stylesheet defect, and leaks the launched Chrome
//  through the error path. The preflight below refuses on the GUARD path instead,
//  before anything is spawned. For an epic whose frame is "the console stops lying",
//  a gate that misreports its own environment failure as a content failure is
//  self-defeating.
//
//  D20/D65 — THE EXACT-MATCH SIDECAR RATCHET closes a measured blind spot in the
//  mutation proof below. The proof only ever exercised the DE-OPENED direction (a
//  `/*` removed). Going the other way — INSERTING a stray `/*` before `.modal-root`
//  — passed with MISSES 0: the brace-tracking parser and Chrome both swallow the
//  commented-out region symmetrically (measured 1201 heads → 1188 on BOTH sides),
//  so the diff stays empty while 13 rules silently leave the stylesheet. Equality
//  between the two SIDES cannot see a symmetric loss; only a count assertion can.
//
//  D20 first shipped that as a STATIC absolute (`MIN_AUTHORED_HEADS = 1201`). That
//  floor DECAYS: it only ever catches a swallow that drops the count below the
//  baked-in number, and app.css legitimately grows. By the time this file read 1203
//  the 1201 floor could no longer see a two-rule swallow — the D20 hole silently
//  re-opening itself while the gate still reported green. D65 replaces the static
//  floor with a committed sidecar (`cssom-heads.baseline`) and asserts authored
//  heads EQUAL it (not `>=`), so a swallow AND unrecorded growth both red, and every
//  legitimate CSS change must bump the sidecar in the same commit. See readBaseline().
//
//  ZERO DEPENDENCIES — Node 22 native fetch + native WebSocket speak CDP
//  directly, matching __preview__'s doctrine. It reads each file from disk rather
//  than through serve.mjs: serve.mjs serves cloud/priv/static VERBATIM, so these
//  are the served bytes, and ONE FRESH PAGE PER ROSTER ENTRY, each with a single
//  injected <style>, keeps the CSSOM isolated to exactly one stylesheet at a time
//  — which is what makes the head == CSSOM calibration mean anything. Sharing a
//  page across the roster would sum both sheets into one `document.styleSheets`
//  and turn every per-sheet count into a number about neither file.
//
//  TEARDOWN — hand-bounded, and it does NOT inherit shoot.sh's blocking `wait`.
//  That `wait` on a Chrome which ignores SIGTERM is a measured multi-hour stall
//  (7h18m, then 10h30m+, on this host). Nothing here ever blocks on a child:
//  CDP Browser.close raced against a cap, then `kill -0` polling with a cap,
//  then SIGKILL with a further cap, then a SHOUT on stderr naming the pid.
//  Chrome takes --remote-debugging-port=0 and reports its own port through the
//  profile dir, so a concurrent shoot.sh can never collide with it.
// ─────────────────────────────────────────────────────────────────────────────

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import crypto from "node:crypto";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { BRINGUP_ATTEMPTS, bringUpChrome, captureStderr } from "./bringup-retry.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const DEFAULT_CSS = path.resolve(HERE, "..", "app.css");

const DEVTOOLS_CAP = 15000;
const PARSE_CAP = 20000;
const BROWSER_CLOSE_CAP = 2000;
const TERM_POLL_CAP = 3000;
const KILL_POLL_CAP = 2000;

// ── D65: the exact-match sidecar ratchet — replaces D20's static floor ────────
// `heads == CSSOM rules` is a SYMMETRIC assertion between the two SIDES, so it
// cannot see a loss that hits both equally — which is exactly what commenting out a
// region does. A count assertion is the only thing that can. D20 shipped that as a
// static absolute; a static absolute DECAYS (see the header). D65 pins the count to
// a committed sidecar and asserts EQUALITY.
//
// WHY EXACT (`==`), NOT A FLOOR (`>=`). A floor only catches a drop BELOW its
// baked-in number, and any margin re-opens the identical hole for every swallow of
// that size or smaller — the same defect, merely quieter. Worse, a `>=` floor lets
// the baseline go stale silently as CSS grows, so the very growth that is normal is
// what erodes the protection (this file read 1203 while the floor still said 1201 —
// a two-rule swallow already sailed over it). Under `==`, a swallow reds (count
// fell) AND unrecorded growth reds (count rose), which forces the sidecar to be
// bumped in the SAME commit as any legitimate CSS change. That co-commit IS the
// ratchet: the count can only move through a reviewed diff, never drift.
//
// WHY A COMMITTED SIDECAR, NOT `git show origin/main:…app.css` (candidate a). A
// git-derived baseline is self-maintaining but adds a git dependency to an
// instrument whose header law is ZERO DEPENDENCIES / runnable-in-a-worktree: it
// would break in a bare archive, a detached checkout, a shallow CI clone with no
// `origin/main` ref, or the fixture proof below — the exact contexts this gate must
// run in. A file on disk needs nothing but `fs`.
//
// WHY NOT A RELATIVE DROP TOLERANCE vs the previous run (candidate c). CI keeps no
// cross-run state — every run is a fresh checkout with no memory of the last run's
// count — so "a drop of >N since last time" has no "last time" to compare against.
// The committed count IS the persistent state, versioned with the code it guards.
//
// THIS MEANS EVERY CSS CHANGE REDS UNTIL THE SIDECAR IS BUMPED, AND THAT IS THE
// INTENDED COST. A red here is never "the gate is broken" — it is "the authored-
// head count moved; say whether you meant it and record the new count."
//
// Measured 2026-07-21 on app.css @ sha256 176f441387bc…: 1203 authored heads,
// 1203 CSSOM rules, 1172/1172 flattened, MISSES 0 (Chrome 150.0.7871.129,
// node v22.22.0). That number lives in cssom-heads.baseline, NOT here — a constant
// in this file would decay exactly as MIN_AUTHORED_HEADS did.
const DEFAULT_BASELINE = path.resolve(HERE, "cssom-heads.baseline");

// ── THE ROSTER — the gate's scope, written down ─────────────────────────
// Every served stylesheet in cloud/priv/static that a browser parses as CSS. See
// the header for why this is a LIST and not a second constant. Each entry gets its
// OWN sidecar: the counts are facts about different files and a shared number could
// only ever be a sum, which no reviewer can bump honestly.
//
// `extract: "html-inline-style"` means the served artifact is an HTML document and
// the CSS is the concatenation of its `<style>` blocks — see inlineStyleSheet().
//
// ADDING A SHEET IS A THREE-PART CHANGE: an entry here, a committed sidecar next to
// this file, and the measured count in it. There is deliberately no glob: a glob
// would silently widen the gate's claim every time someone dropped a file in the
// directory, and a gate whose scope you cannot read is the thing this row was
// filed about.
const ROSTER = [
  {
    id: "app.css",
    file: DEFAULT_CSS,
    baseline: DEFAULT_BASELINE,
    extract: null,
  },
  {
    id: "styleguide.html",
    file: path.resolve(HERE, "..", "styleguide.html"),
    baseline: path.resolve(HERE, "cssom-heads-styleguide.baseline"),
    extract: "html-inline-style",
  },
];

// ── HTML → the sheet the browser actually parses ─────────────────────────
// BLANK, NEVER SLICE. Everything outside a `<style>` block is replaced by
// whitespace of the SAME SHAPE — newlines kept, every other byte spaced — so the
// extracted sheet has the host document's exact line numbering, byte for byte.
// That is the whole reason this is not a two-line `match()[1]`: a sliced sheet
// reports offsets into a string that exists on no disk, so `styleguide.html:47`
// would name line 47 OF THE SLICE and send a reader to the wrong place. Under
// blanking, every line this gate prints is a line a human can open.
//
// It also keeps the parser honest about the boundary. The `<style>` tags themselves
// are blanked, so the brace-tracking parser can never absorb `</style>` or the
// surrounding markup into a prelude; and prose between two blocks cannot join them.
const STYLE_BLOCK = /<style\b[^>]*>([\s\S]*?)<\/style\s*>/gi;
const HTML_COMMENT = /<!--[\s\S]*?-->/g;

// HTML COMMENTS ARE BLANKED FIRST, AND THAT IS NOT TIDINESS. A `<style>` written
// inside an `<!-- … -->` comment is not a stylesheet; a scan that does not know
// that starts its match THERE and swallows every byte from the comment to the real
// `</style>` into the first prelude. Measured on this file's own committed fixture
// (fixtures/styleguide-roster/clean.html, whose comment mentions `<style>` in
// prose): before this pass the CLEAN fixture reported 3 MISSES and a COUNT SKEW —
// a gate accusing a stylesheet that had nothing wrong with it. A gate that cries
// wolf is disabled within a wave, so this is load-bearing, not cosmetic.
//
// Blanking rather than stripping, here too: the comment's bytes become spaces of
// the same shape, so every offset after it is still the offset in the real file.
const blankRun = (s) => s.replace(/[^\n]/g, " ");

function inlineStyleSheet(rawHtml) {
  const html = rawHtml.replace(HTML_COMMENT, blankRun);
  let out = "";
  let last = 0;
  let blocks = 0;
  STYLE_BLOCK.lastIndex = 0;
  for (let m; (m = STYLE_BLOCK.exec(html)); ) {
    const openEnd = m.index + m[0].indexOf(">") + 1;
    out += blankRun(html.slice(last, openEnd)) + m[1];
    last = openEnd + m[1].length;
    blocks++;
  }
  out += blankRun(html.slice(last));
  return { css: out, blocks };
}

// A roster entry whose file no longer carries the thing the entry CLAIMS it carries
// is an environment fault, not a clean sheet. If styleguide.html's inline CSS is one
// day folded into app.css, this refuses (exit 2) and names the entry, so the roster
// gets edited — rather than reporting `0 heads · MISSES 0 · PARITY PASS` over a
// sheet that does not exist. A gate that greens an empty population it was told to
// find is the same failure as the blindness this roster was added to close.
function extractSheet(entry, raw) {
  if (entry.extract !== "html-inline-style") return { css: raw, blocks: null };
  const { css, blocks } = inlineStyleSheet(raw);
  if (blocks === 0) return { css: null, blocks: 0, why: "no <style> block" };
  if (!/\S/.test(css)) return { css: null, blocks, why: `${blocks} <style> block(s), all empty` };
  return { css, blocks };
}

// The CSS= escape hatch still certifies ONE ad-hoc sheet (the committed fixture
// proofs in fixtures/cssom-floor/ and fixtures/styleguide-roster/ depend on it,
// paired with HEADS_BASELINE). Its extractor is chosen by extension so
// `CSS=…/styleguide.html` behaves like the roster entry rather than feeding a whole
// HTML document to a CSS parser.
function adHocEntry(cssPath) {
  return {
    id: path.basename(cssPath),
    file: cssPath,
    baseline: path.resolve(process.env.HEADS_BASELINE || DEFAULT_BASELINE),
    extract: /\.x?html?$/i.test(cssPath) ? "html-inline-style" : null,
  };
}

// HEADS_BASELINE WITHOUT CSS STILL OVERRIDES app.css's SIDECAR, AND THAT IS A
// CONTRACT, NOT A CONVENIENCE. Before the roster, a bare run certified app.css and
// HEADS_BASELINE named its sidecar; scripts/console-path-escape-check.test.sh case 11
// drives the REAL instrument with `HEADS_BASELINE=/nonexistent/…` and no CSS= to
// prove the CI wrapper turns the exit-2 refusal into a red job with a REFUSED
// annotation. Ignoring the variable once the roster arrived did not red that test's
// subject — it made the run PASS, so the wrapper had nothing to classify and the
// selftest went from 278/0 to 276/2. A multi-sheet gate cannot take one baseline for
// every sheet, so the override binds to the sheet it always bound to: the default
// one. Every other entry keeps its committed sidecar.
function applyBaselineOverride(entries) {
  const override = process.env.HEADS_BASELINE;
  if (!override) return entries;
  const resolved = path.resolve(override);
  return entries.map((e) => (e.file === DEFAULT_CSS ? { ...e, baseline: resolved } : e));
}

// The sidecar is a committed text file: `#` lines are human context, the first
// bare-integer line is the count. Override with HEADS_BASELINE=/path (pair it with
// CSS= when certifying a non-default stylesheet — the fixture proof does exactly
// that). A missing or unparseable sidecar is an ENVIRONMENT fact — the gate cannot
// know what to assert — so it GUARDS on exit 2 in the preflight below, never reds as
// though the CSS were broken.
function parseBaseline(text) {
  for (const raw of text.split("\n")) {
    const line = raw.trim();
    if (line === "" || line.startsWith("#")) continue;
    return /^\d+$/.test(line) ? Number(line) : null; // first non-comment line decides
  }
  return null; // no count line at all
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// At-rules that CONTAIN style rules — descend into them; their inner rules are
// real CSSOM style rules and must appear on the authored side too.
const GROUPING_AT = new Set(["media", "supports", "container", "layer", "scope", "document"]);
// At-rules that contain something OTHER than style rules — @keyframes' percent
// stops are CSSKeyframeRule (no selectorText), @font-face/@property have no
// selector at all. Skipped wholesale, symmetric with the CSSOM walk below.

// ── 1. the authored side — a brace-tracking parser, not a grep ────────────────

function skipComment(css, i) {
  const end = css.indexOf("*/", i + 2);
  return end === -1 ? css.length : end + 2;
}

function skipString(css, i) {
  const quote = css[i];
  let j = i + 1;
  while (j < css.length) {
    if (css[j] === "\\") { j += 2; continue; }
    if (css[j] === quote) return j + 1;
    j++;
  }
  return css.length;
}

// Consume from the `{` at `i` through its matching `}`, respecting nesting,
// comments and strings. Used for both style-rule bodies and opaque at-rules.
function skipBlock(css, i) {
  let depth = 0;
  let j = i;
  while (j < css.length) {
    const c = css[j];
    if (c === "/" && css[j + 1] === "*") { j = skipComment(css, j); continue; }
    if (c === '"' || c === "'") { j = skipString(css, j); continue; }
    if (c === "{") depth++;
    else if (c === "}") { depth--; if (depth === 0) return j + 1; }
    j++;
  }
  return css.length;
}

const atName = (head) => (head.match(/^@([a-zA-Z-]+)/) || [, ""])[1].toLowerCase();

// Every style-rule head the source authors, in file order, with its line number.
// A "head" is the raw prelude text before a `{` — it may be a comma group, and
// it may span many lines (40 of them do).
function authoredHeads(css) {
  const heads = [];
  let i = 0;
  let buf = "";
  let bufStart = 0;
  // Leading whitespace is never part of a head, and swallowing it here is what
  // makes the reported line the line the DEFECT is on rather than the line the
  // previous rule closed on.
  const push = (ch, at) => {
    if (buf === "" && /^\s*$/.test(ch)) return;
    if (buf === "") bufStart = at;
    buf += ch;
  };

  while (i < css.length) {
    const c = css[i];
    if (c === "/" && css[i + 1] === "*") { i = skipComment(css, i); continue; }
    if (c === '"' || c === "'") {
      const j = skipString(css, i);
      push(css.slice(i, j), i);
      i = j;
      continue;
    }
    if (c === "{") {
      const head = buf.trim();
      const start = bufStart;
      buf = "";
      if (head.startsWith("@")) {
        if (GROUPING_AT.has(atName(head))) { i++; continue; } // descend
        i = skipBlock(css, i);                                 // opaque — skip
        continue;
      }
      if (head !== "") heads.push({ head, index: start, braceIndex: i });
      i = skipBlock(css, i);
      continue;
    }
    if (c === "}") { buf = ""; i++; continue; }        // leaving a grouping block
    // A `;` ends a STATEMENT at-rule (@import, @charset, @layer a, b;). It does
    // NOT end a qualified rule's prelude — CSS error recovery runs to the next
    // `{`, which is precisely how #4592 swallowed the rule that followed it, and
    // reproducing that faithfully is what makes the mutation proof honest.
    if (c === ";" && buf.trim().startsWith("@")) { buf = ""; i++; continue; }
    push(c, i);
    i++;
  }
  return heads;
}

// ── 2. ONE normaliser, applied to BOTH sides (GR100 ruling 1) ────────────────
// Every transform here is deliberately blind to which side it is looking at.
// It is NOT a list of Chrome's known rewrites — it is a canonical form both a
// hand-written selector and a Chrome-serialised one collapse into. An unknown
// fourth serialisation class costs sensitivity here, never correctness.
function normalise(sel) {
  return sel
    .replace(/\s+/g, " ")               // multi-line comma continuations
    .replace(/\s*([>+~])\s*/g, "$1")    // combinators — AND the An+B `-n + 2`
    .replace(/\(\s+/g, "(")             // `:is( a )`
    .replace(/\s+\)/g, ")")
    .replace(/\s*,\s*/g, ",")
    .replace(/\*(?=[:.#[])/g, "")       // `> *:pseudo` serialises as `> :pseudo`
    .trim();
}

// Split a comma group at TOP level only — `:is(a, b)` and `[x=","]` stay whole.
function splitGroup(head) {
  const out = [];
  let depth = 0;
  let cur = "";
  for (let i = 0; i < head.length; i++) {
    const c = head[i];
    if (c === '"' || c === "'") { const j = skipString(head, i); cur += head.slice(i, j); i = j - 1; continue; }
    if (c === "(" || c === "[") depth++;
    else if (c === ")" || c === "]") depth--;
    if (c === "," && depth === 0) { out.push(cur); cur = ""; continue; }
    cur += c;
  }
  out.push(cur);
  return out.map((s) => s.trim()).filter(Boolean);
}

const lineOf = (css, index) => css.slice(0, index).split("\n").length;

// Middle-ellipsis, never a tail chop: under an orphan-comment swallow the thing
// a reader needs is at the END of a 400-character garbage run, and a tail chop
// hides exactly the selector the gate exists to name.
const ellipsis = (s, max = 150) =>
  s.length <= max ? s : s.slice(0, max - 60) + " … " + s.slice(-57);

// ── 3. the CSSOM side, as it runs inside the page ─────────────────────────────
// Recurse into grouping rules so a rule is never "missing" merely because it is
// nested, and key on `selectorText` being a string — that is exactly what
// excludes @keyframes percent stops, @font-face and @property, symmetric with
// the parser's opaque-at-rule skip.
const COLLECT_JS = `(function () {
  var out = { rules: [], unreadable: 0, sheetCount: document.styleSheets.length };
  function walk(rules) {
    for (var i = 0; i < rules.length; i++) {
      var r = rules[i];
      if (typeof r.selectorText === "string") out.rules.push(r.selectorText);
      if (r.cssRules && r.cssRules.length) walk(r.cssRules);
    }
  }
  for (var s = 0; s < document.styleSheets.length; s++) {
    try { walk(document.styleSheets[s].cssRules || []); } catch (e) { out.unreadable++; }
  }
  return out;
})()`;

// ── 4. plumbing (the CDP client and reap are modal-oracle.mjs's, unchanged) ───

// The accessSync check MUST cover the CHROME env branch, not only the candidate
// sweep. .github/workflows/console-harness.yml pins CHROME=/usr/bin/google-chrome
// for every console run, so on CI the env branch is the ONLY branch taken — an
// unchecked `return process.env.CHROME` makes the exit-2 "no Chrome" GUARD below
// dead code, and a runner image that drops the binary dies instead with a raw
// `spawn … ENOENT` node stack at exit 1. Exit 1 means "a measured CSS defect";
// a missing browser is an ENVIRONMENTAL REFUSAL and must speak as exit 2.
function findChrome() {
  if (process.env.CHROME) {
    try {
      fs.accessSync(process.env.CHROME, fs.constants.X_OK);
      return process.env.CHROME;
    } catch {
      return null; // fall through to the exit-2 GUARD naming the missing path
    }
  }
  const candidates = [
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    "/usr/bin/google-chrome",
    "/usr/bin/google-chrome-stable",
    "/usr/bin/chromium",
    "/usr/bin/chromium-browser",
  ];
  for (const c of candidates) {
    try { fs.accessSync(c, fs.constants.X_OK); return c; } catch { /* next */ }
  }
  return null;
}

// The refusal line for a findChrome() miss — names the path that was pinned and
// not found, so a runner-image regression reads as "this binary is gone", never
// as an anonymous red.
function chromeGuardLine() {
  return process.env.CHROME
    ? `!! GUARD (exit 2): CHROME=${process.env.CHROME} is not an executable file. Environment refusal, not a CSS defect.\n`
    : "!! GUARD (exit 2): no Chrome/Chromium found. Set CHROME=/path/to/chrome.\n";
}

class Cdp {
  constructor(ws) {
    this.ws = ws;
    this.seq = 0;
    this.pending = new Map();
    ws.addEventListener("message", (ev) => {
      let msg;
      try { msg = JSON.parse(ev.data); } catch { return; }
      if (msg.id == null) return;
      const p = this.pending.get(msg.id);
      if (!p) return;
      this.pending.delete(msg.id);
      if (msg.error) p.reject(new Error(msg.method + ": " + JSON.stringify(msg.error)));
      else p.resolve(msg.result);
    });
    ws.addEventListener("close", () => {
      for (const [, p] of this.pending) p.reject(new Error("CDP socket closed"));
      this.pending.clear();
    });
  }

  static async connect(wsUrl) {
    const ws = new WebSocket(wsUrl);
    await new Promise((resolve, reject) => {
      ws.addEventListener("open", resolve, { once: true });
      ws.addEventListener("error", () => reject(new Error("CDP connect failed: " + wsUrl)), { once: true });
    });
    return new Cdp(ws);
  }

  send(method, params = {}, sessionId) {
    const id = ++this.seq;
    const frame = { id, method, params };
    if (sessionId) frame.sessionId = sessionId;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject: (e) => reject(Object.assign(e, { method })) });
      try { this.ws.send(JSON.stringify(frame)); }
      catch (e) { this.pending.delete(id); reject(e); }
    });
  }

  close() { try { this.ws.close(); } catch { /* already gone */ } }
}

// ── 5. the run ───────────────────────────────────────────────────────────────

async function main() {
  // D19 — ENVIRONMENT PREFLIGHT, on the GUARD path (exit 2), before anything is
  // spawned. Capability-tested rather than version-parsed: what this instrument
  // actually needs is the global, and a `process.version` regex would both lie
  // about a backported build and go stale. Refusing HERE (rather than letting
  // Cdp.connect throw) is also what stops a Node-20 run from leaking the Chrome
  // it had already launched.
  if (typeof WebSocket === "undefined") {
    process.stderr.write(
      `!! GUARD (exit 2): no global WebSocket in this Node build (running ${process.version}).\n` +
        `   This instrument speaks CDP over a native WebSocket, stable-by-default from Node 22.\n` +
        `   THIS IS AN ENVIRONMENT FAILURE, NOT A STYLESHEET DEFECT — app.css was never read,\n` +
        `   no parity claim is being made about it either way. Do not go looking for a CSS bug.\n` +
        `   Fix the runtime: node-version: 22 in the workflow, or nvm use 22 locally.\n`,
    );
    process.exit(2);
  }

  // ── THE ROSTER PREFLIGHT — EVERY entry, before anything is spawned ─────────
  // Each refusal below is an ENVIRONMENT fact (exit 2), never a stylesheet defect
  // (exit 1): a rostered file that is absent, a sidecar that is absent or carries no
  // count, or an entry whose file no longer holds the sheet the roster claims. In all
  // four cases the gate cannot make a parity claim, so it must not make one — and it
  // must not make one about the OTHER entries either, because a partial run reported
  // as a pass is exactly the silent-skip this roster exists to forbid. It names the
  // entry, so a reader knows which line of ROSTER to go fix.
  const roster = process.env.CSS
    ? [adHocEntry(path.resolve(process.env.CSS))]
    : applyBaselineOverride(ROSTER);

  const sheets = [];
  for (const entry of roster) {
    if (!fs.existsSync(entry.file)) {
      process.stderr.write(
        `!! GUARD (exit 2): rostered sheet "${entry.id}" is MISSING at ${entry.file}\n` +
          `   The roster in cssom-parity.mjs claims this file is a served stylesheet. It is not on\n` +
          `   disk, so NO parity claim is being made about it — and none is made about the rest of\n` +
          `   the roster either: a run that quietly measures a subset and prints PASS is the silent\n` +
          `   skip this roster exists to refuse. Restore the file, or remove its ROSTER entry and its\n` +
          `   sidecar in the same commit.\n`,
      );
      process.exit(2);
    }
    if (!fs.existsSync(entry.baseline)) {
      process.stderr.write(
        `!! GUARD (exit 2): no authored-head baseline sidecar for "${entry.id}" at ${entry.baseline}\n` +
          `   This gate asserts each rostered sheet's authored-head count EQUALS its committed\n` +
          `   sidecar. Without it there is nothing to assert against — an environment fault, not a\n` +
          `   CSS defect. Restore the sidecar, or set HEADS_BASELINE=/path with CSS=/path when\n` +
          `   certifying a single ad-hoc stylesheet.\n`,
      );
      process.exit(2);
    }
    const baseline = parseBaseline(fs.readFileSync(entry.baseline, "utf8"));
    if (baseline === null) {
      process.stderr.write(
        `!! GUARD (exit 2): baseline sidecar ${entry.baseline} (for "${entry.id}") carries no parseable count.\n` +
          `   Expected a file whose first non-\`#\` line is a bare integer (the authored-head count).\n`,
      );
      process.exit(2);
    }

    const raw = fs.readFileSync(entry.file, "utf8");
    const got = extractSheet(entry, raw);
    if (got.css === null) {
      process.stderr.write(
        `!! GUARD (exit 2): rostered sheet "${entry.id}" carries NO INLINE CSS (${got.why}).\n` +
          `   The roster says this document embeds a stylesheet; it does not. Refusing rather than\n` +
          `   certifying an empty population — \`0 heads · MISSES 0 · PARITY PASS\` over a sheet that\n` +
          `   is not there reads as coverage and is the absence of it. If the CSS moved into\n` +
          `   app.css, delete the ROSTER entry and its sidecar in the same commit.\n`,
      );
      process.exit(2);
    }

    const css = got.css;
    const heads = authoredHeads(css);
    const authored = new Map(); // normalised selector -> first {head, line, braceLine}
    for (const h of heads) {
      const where = { head: h.head, line: lineOf(css, h.index), braceLine: lineOf(css, h.braceIndex) };
      for (const sel of splitGroup(h.head)) {
        const key = normalise(sel);
        if (key && !authored.has(key)) authored.set(key, where);
      }
    }

    sheets.push({
      id: entry.id,
      file: entry.file,
      rel: path.relative(process.cwd(), entry.file),
      baselinePath: entry.baseline,
      baseline,
      css,
      blocks: got.blocks,
      bytes: Buffer.byteLength(raw),
      sheetBytes: Buffer.byteLength(css.replace(/[ ]+$/gm, "")),
      sha: crypto.createHash("sha256").update(raw).digest("hex"),
      heads,
      authored,
      cssom: null,
    });
  }

  const chromeBin = findChrome();
  if (!chromeBin) {
    process.stderr.write(chromeGuardLine());
    process.exit(2);
  }

  // D101 (deploy-reliability charter, PR #9905) — the BRING-UP class.
  // Chrome failing to come up is an environment fact, never a CSS fact: no
  // stylesheet was ever parsed, so there is nothing to accuse. Until D101 the
  // bring-up throw below was a PLAIN Error, so the classifier at the bottom of
  // this block scored it as a MEASURED defect (exit 1) and console-harness.yml's
  // `1)` arm told the reviewer "This is a REAL CSS defect in app.css" on a run
  // whose own stderr said Chrome never started. The workflow's case block is
  // correct; this instrument was lying to it. Sibling overflow-guard.mjs routes
  // the IDENTICAL fault through die() → exit 2 = REFUSED TO MEASURE; this is the
  // same vocabulary, deliberately not a third one.
  //
  // The class is carried on the error OBJECT, never sniffed out of its message.
  // A message match would widen silently every time someone reworded a throw,
  // and a refusal class that widens until nothing can ever be accused is a gate
  // that can never fail — strictly worse than the bug it replaces. So exactly
  // the three bring-up steps are tagged: the DevToolsActivePort wait, the
  // /json/version handshake, and the CDP socket connect. Everything the browser
  // tells us AFTER it is up — injection threw, ZERO rules parsed, unreadable
  // sheets — is a claim about the stylesheet and stays exit 1.
  const REFUSED = Symbol("cssom-parity refused to measure");
  const bringUpFailure = (message) => Object.assign(new Error(message), { [REFUSED]: true });

  // The profile dir is allocated PER BRING-UP ATTEMPT (bringup-retry.mjs), not
  // once here: a retry into the dead attempt's directory would re-race the same
  // DevToolsActivePort path. This holds whichever attempt's dir is live, so
  // teardown removes the right one.
  let profile = null;
  const t0 = Date.now();
  let chrome = null;
  let cdp = null;
  let teardownMs = 0;

  const teardown = async () => {
    const td0 = Date.now();
    if (cdp) {
      await Promise.race([cdp.send("Browser.close").catch(() => {}), sleep(BROWSER_CLOSE_CAP)]);
      cdp.close();
    }
    const alive = (p) => { if (!p || p.pid == null) return false; try { process.kill(p.pid, 0); return true; } catch { return false; } };
    if (alive(chrome)) {
      try { chrome.kill("SIGTERM"); } catch { /* gone */ }
      let waited = 0;
      while (alive(chrome) && waited < TERM_POLL_CAP) { await sleep(50); waited += 50; }
      if (alive(chrome)) {
        try { chrome.kill("SIGKILL"); } catch { /* gone */ }
        waited = 0;
        while (alive(chrome) && waited < KILL_POLL_CAP) { await sleep(50); waited += 50; }
        if (alive(chrome)) {
          process.stderr.write(
            `!! TEARDOWN SHOUT: chrome pid ${chrome.pid} SURVIVED SIGKILL after ` +
              `${KILL_POLL_CAP}ms. Reap it by hand: kill -9 ${chrome.pid}\n`,
          );
        }
      }
    }
    if (profile) { try { fs.rmSync(profile, { recursive: true, force: true }); } catch { /* best effort */ } }
    teardownMs = Date.now() - td0;
  };

  try {
    // REVIEW ADDITION to D101 — the FOURTH bring-up step, and the one that was
    // still misclassified after the slice landed. An EXEC failure is not the
    // same fault as "Chrome started and never came up": findChrome()'s X_OK
    // preflight proves the file is there and executable, but it cannot see
    // exec-time faults — a wrong-architecture or non-binary file (ENOEXEC, the
    // arm64/amd64 runner-image mismatch class), EACCES from a mount option,
    // ETXTBSY mid-download, or the file being swapped between the check and the
    // spawn. Measured on this host (node v22.22.0, darwin): `spawn` throws
    // ENOEXEC SYNCHRONOUSLY, so it landed in the catch block below UNTAGGED and
    // printed `!! PARITY ERROR: spawn ENOEXEC` at exit 1 —
    // console-harness.yml's `1)` arm, i.e. "This is a REAL CSS defect in
    // app.css", over a message that says the browser could not be executed.
    // Both delivery shapes are covered because node picks between them by
    // platform and errno: the try/catch takes the synchronous throw, and the
    // 'error' listener takes the asynchronous emit (which, with no listener,
    // would be an uncaughtException — also exit 1, also a lie).
    // D101 BRING-UP RETRY (deploy-reliability wave 8). Bounded, fresh profile
    // per attempt, every failed attempt's Chrome stderr printed — see
    // bringup-retry.mjs for the measurement that justified it and for the line
    // this retry must never cross: cch-w19-bl-gr115's "do not paper over the
    // race" governs exit-1 MEASURED intermittency (the stylesheet WAS parsed
    // and the instrument disagreed with itself). This retries only the exit-2
    // case where Chrome never came up, so no parity claim exists to hide.
    // Everything after `devPort` is a claim about app.css and is never retried.
    let attemptSpawnError = null;
    const brought = await bringUpChrome({
      label: "cssom-parity",
      attempts: BRINGUP_ATTEMPTS,
      newProfile: () => fs.mkdtempSync(path.join(os.tmpdir(), "cssom-parity-")),
      launch: (dir) => {
        attemptSpawnError = null;
        let child;
        try {
          child = spawn(
            chromeBin,
            [
              "--headless=new",
              "--disable-gpu",
              "--no-sandbox",
              "--disable-dev-shm-usage",
              "--no-first-run",
              "--no-default-browser-check",
              "--disable-extensions",
              "--disable-background-networking",
              `--user-data-dir=${dir}`,
              "--remote-debugging-port=0",
              "about:blank",
            ],
            // stderr is a PIPE, never "ignore": a refusal whose cause Chrome
            // already explained, thrown away by the instrument, is a refusal
            // nobody can audit.
            { stdio: ["ignore", "ignore", "pipe"] },
          );
        } catch (err) {
          // See the REVIEW ADDITION note above: node delivers exec faults
          // (ENOEXEC, EACCES, ETXTBSY) either synchronously here or
          // asynchronously on 'error'. Both shapes are covered.
          throw new Error(`Chrome could not be executed (${err.code || err.message}): ${chromeBin}`);
        }
        child.on("error", (e) => { attemptSpawnError = e; });
        return { child, readStderr: captureStderr(child) };
      },
      awaitDevToolsPort: async ({ profile: dir }) => {
        const portFile = path.join(dir, "DevToolsActivePort");
        for (let w = 0; w < DEVTOOLS_CAP; w += 100) {
          if (attemptSpawnError) break; // no point waiting DEVTOOLS_CAP on a process that never execed
          try {
            const raw = fs.readFileSync(portFile, "utf8").split("\n");
            if (raw[0] && Number(raw[0])) return Number(raw[0]);
          } catch { /* not written yet */ }
          await sleep(100);
        }
        if (attemptSpawnError) {
          throw new Error(`Chrome could not be executed (${attemptSpawnError.code || attemptSpawnError.message}): ${chromeBin}`);
        }
        return null;
      },
      abandon: async ({ profile: dir, child }) => {
        if (child && child.pid != null) {
          try { child.kill("SIGKILL"); } catch { /* already gone */ }
        }
        try { fs.rmSync(dir, { recursive: true, force: true }); } catch { /* best effort */ }
      },
      log: (s) => process.stderr.write(s),
    }).catch((err) => {
      // Every bounded attempt refused. Re-tag onto THIS file's refusal class so
      // the classifier below still reaches exit 2 — a refusal is not a defect.
      if (err && err.refused) throw bringUpFailure(err.message);
      throw err;
    });
    chrome = brought.child;
    profile = brought.profile;
    const devPort = brought.devPort;

    let version;
    try {
      version = await (await fetch(`http://127.0.0.1:${devPort}/json/version`)).json();
    } catch (err) {
      throw bringUpFailure(`Chrome wrote port ${devPort} but /json/version never answered: ${err.message}`);
    }
    process.stdout.write(
      `>> chrome     ${chromeBin}\n` +
        `>> build      ${version.Browser} · node ${process.version}\n` +
        `>> roster     ${sheets.length} sheet(s)\n`,
    );
    for (const s of sheets) {
      process.stdout.write(
        `>> stylesheet ${s.rel} · ${s.bytes} B · sha256 ${s.sha.slice(0, 12)}…` +
          (s.blocks === null ? "" : ` · ${s.blocks} inline <style> block(s)`) +
          `\n`,
      );
    }
    process.stdout.write("\n");
    try {
      cdp = await Cdp.connect(version.webSocketDebuggerUrl);
    } catch (err) {
      // A ReferenceError here (no global WebSocket) must keep its OWN class —
      // D19's arm names the runtime fix, this one names the browser. Both refuse.
      if (err instanceof ReferenceError) throw err;
      throw bringUpFailure(`CDP bring-up failed: ${err.message}`);
    }

    // ONE FRESH PAGE PER ROSTER ENTRY. `document.styleSheets` is per-document, so
    // reusing one page across the roster would sum every sheet into one census and
    // make `heads == CSSOM rules` a statement about neither file. A new target also
    // means a sheet that fails to parse cannot contaminate the next one's count.
    // Every accusation below is prefixed with the sheet's id: exit 1 is a claim
    // about A stylesheet and the reader has to be told WHICH.
    for (const s of sheets) {
      const { targetId } = await cdp.send("Target.createTarget", { url: "about:blank" });
      const { sessionId } = await cdp.send("Target.attachToTarget", { targetId, flatten: true });
      await cdp.send("Runtime.enable", {}, sessionId);

      // Inject as ONE inline <style> and wait for the sheet to be reachable. An
      // inline sheet is always same-origin, so `cssRules` can never throw the
      // SecurityError that would silently zero this instrument out.
      const inject = await cdp.send("Runtime.evaluate", {
        expression:
          `(function(){var s=document.createElement("style");` +
          `s.textContent=${JSON.stringify(s.css)};document.head.appendChild(s);` +
          `return document.styleSheets.length;})()`,
        returnByValue: true,
      }, sessionId);
      if (inject.exceptionDetails) throw new Error(`${s.id}: injection threw: ` + inject.exceptionDetails.text);

      let collected = null;
      for (let w = 0; w < PARSE_CAP; w += 100) {
        const ev = await cdp.send("Runtime.evaluate", { expression: COLLECT_JS, returnByValue: true }, sessionId);
        if (ev.exceptionDetails) throw new Error(`${s.id}: collection threw: ` + ev.exceptionDetails.text);
        if (ev.result.value && ev.result.value.rules.length) { collected = ev.result.value; break; }
        await sleep(100);
      }
      if (!collected) throw new Error(`${s.id}: Chrome parsed ZERO style rules — the stylesheet never reached the CSSOM`);
      if (collected.unreadable) throw new Error(`${s.id}: ${collected.unreadable} stylesheet(s) were unreadable — the diff would be a false green`);
      s.cssom = collected;
      await cdp.send("Target.closeTarget", { targetId }).catch(() => {});
    }
  } catch (err) {
    await teardown();
    // D19, second line of defence. A ReferenceError escaping this block is a
    // missing global — an environment fact, never a CSS fact — so it exits on the
    // GUARD path like the preflight above. The preflight already catches the one
    // known case (WebSocket); this keeps a FUTURE missing global from being
    // reported to a reviewer as a stylesheet defect.
    //
    // D101, first line of defence. A tagged bring-up failure means the browser
    // never came up, so this run measured NOTHING about app.css. It refuses on
    // the GUARD path too — two distinct environment classes, one exit code (2),
    // each naming the thing a human should actually go fix.
    const missingGlobal = err instanceof ReferenceError;
    const neverStarted = Boolean(err && err[REFUSED]);
    const envFailure = missingGlobal || neverStarted;
    const detail = err && err.message ? err.message : err;
    process.stderr.write(
      missingGlobal
        ? `\n!! GUARD (exit 2): ENVIRONMENT — ${detail}\n` +
            `   A required global is missing from this runtime. No parity claim was made about\n` +
            `   the stylesheet. Fix the environment (Node 22+), not the CSS.\n` +
            `   teardown ${teardownMs}ms\n`
        : neverStarted
          ? `\n!! GUARD (exit 2): REFUSED TO MEASURE — ${detail}\n` +
              `   Headless Chrome never came up, so NOT ONE rule of any rostered sheet was parsed.\n` +
              `   No parity claim was made about ${sheets.map((s) => s.rel).join(", ")} — this is NOT a CSS defect.\n` +
              `   Fix the browser in this environment (CHROME=${chromeBin}), then re-run.\n` +
              `   teardown ${teardownMs}ms\n`
          : `\n!! PARITY ERROR: ${detail}\n   teardown ${teardownMs}ms\n`,
    );
    process.exit(envFailure ? 2 : 1);
  }

  await teardown();

  const wall = Date.now() - t0;
  let failed = 0;

  // ONE REPORT PER ROSTERED SHEET, then ONE verdict. Each block is the report this
  // file has always printed — the only change is that it now says WHICH sheet, and
  // that a red anywhere on the roster reds the run. A per-sheet PASS line is printed
  // even when a sibling fails: "app.css is clean" and "the styleguide is not" are two
  // facts and collapsing them into one exit code without printing both is how a
  // reader ends up hunting the wrong file.
  for (const s of sheets) {
    const cssomSet = new Set();
    for (const sel of s.cssom.rules) for (const one of splitGroup(sel)) cssomSet.add(normalise(one));

    const misses = [];
    for (const [key, where] of s.authored) if (!cssomSet.has(key)) misses.push({ key, ...where });

    const baselineMismatch = s.heads.length !== s.baseline;
    const grew = s.heads.length > s.baseline;

    process.stdout.write(
      `── ${s.id} ───\n` +
        `   authored rule heads   ${s.heads.length} (baseline ${s.baseline}${baselineMismatch ? (grew ? " ← ABOVE" : " ← BELOW") : ""})\n` +
        `   CSSOM style rules     ${s.cssom.rules.length}\n` +
        `   flattened selectors   ${s.authored.size} authored / ${cssomSet.size} CSSOM\n` +
        `   MISSES                ${misses.length}\n`,
    );

    // Count skew means the parser no longer models the file (CSS nesting, a new
    // at-rule) — the miss list may then be INCOMPLETE, which is the failure mode
    // this whole instrument exists to refuse. Advisory, not fatal: it is a fact
    // about the parser, not about the CSS, and a gate that reds on the wrong
    // thing gets disabled. Under a real swallow it moves too, and the MISS below
    // is the signal that decides the exit code.
    if (s.heads.length !== s.cssom.rules.length) {
      process.stdout.write(
        `\n!! COUNT SKEW in ${s.id}: ${s.heads.length} authored heads vs ${s.cssom.rules.length} CSSOM rules. Either a rule\n` +
          `   was discarded by the browser (see MISSES), or this parser no longer models\n` +
          `   ${s.id} (CSS nesting? a new at-rule? add it to GROUPING_AT). If MISSES is 0 while\n` +
          `   this is non-zero, treat the 0 as UNPROVEN and fix the parser first.\n`,
      );
    }

    // D65 — the exact-match baseline. FATAL, and checked independently of `misses`,
    // because the whole point is the case where MISSES is 0 and the stylesheet is
    // still missing rules. Reported BEFORE the miss list: under a stray-`/*` insert
    // this is the ONLY signal, and under a real swallow it is the more legible one.
    if (baselineMismatch) {
      const delta = Math.abs(s.heads.length - s.baseline);
      process.stderr.write(
        `\n!! BASELINE MISMATCH in ${s.id}: ${s.heads.length} authored rule heads, sidecar baseline is ` +
          `${s.baseline} (${grew ? "+" : "−"}${delta}).\n` +
          `   sidecar: ${path.relative(process.cwd(), s.baselinePath)}\n\n`,
      );
      if (grew) {
        process.stderr.write(
          `   The stylesheet GREW without recording it. This is not a defect by itself — it is an\n` +
            `   UNRECORDED change, which the ratchet refuses on purpose so the count can only move\n` +
            `   through a reviewed diff. Bump the sidecar to ${s.heads.length} IN THE SAME COMMIT as the\n` +
            `   CSS change, so the next reader sees the new count was reviewed. (Confirm MISSES is 0\n` +
            `   first — a mismatch with misses is a genuine parity defect, not just an unrecorded add.)\n`,
        );
      } else {
        process.stderr.write(
          `   MISSES above may well be 0 and that 0 IS NOT A PASS. The authored-vs-CSSOM diff is\n` +
            `   symmetric, so a region commented out by a stray \`/*\` opener vanishes from BOTH sides\n` +
            `   at once and the diff stays empty while ${delta} rule(s) leave the stylesheet. This count\n` +
            `   assertion is the only thing in this file that can see that.\n\n` +
            `   TWO CAUSES, AND YOU MUST SAY WHICH:\n` +
            `     1. A stray \`/*\` opener commented out a live region — a real defect, of the same\n` +
            `        family as #4592. Find it: diff the comment openers against\n` +
            `        \`git show origin/main:${s.rel}\`. (For app.css, \`node cloud/priv/static/__css_check.mjs\`\n` +
            `        E10 guards the same mechanism at the source-text level; it does NOT scan the\n` +
            `        styleguide's inline sheet, so on that entry this gate is the only witness.)\n` +
            `     2. You deliberately deleted ${delta} rule head(s). Then lower the sidecar to\n` +
            `        ${s.heads.length}, IN THE SAME COMMIT as the deletion, so the ratchet stays honest\n` +
            `        and the next reader sees the count was reviewed.\n`,
        );
      }
    }

    if (misses.length === 0 && !baselineMismatch) {
      process.stdout.write(`   PASS — every authored selector reached the CSSOM, count matches baseline\n\n`);
      continue;
    }
    failed++;

    if (misses.length === 0) {
      process.stderr.write(`\n   FAIL ${s.id} — baseline mismatch with 0 misses\n\n`);
      continue;
    }

    // Report GROUPED BY AUTHORED HEAD. One orphan-comment swallow fragments into
    // several misses (the prose contains commas), and listing them flat reads as
    // several unrelated defects instead of the single one it is.
    const byHead = new Map();
    for (const m of misses) {
      if (!byHead.has(m.head)) byHead.set(m.head, { where: m, keys: [] });
      byHead.get(m.head).keys.push(m.key);
    }

    process.stderr.write(
      `\n!! ${misses.length} authored selector(s) in ${byHead.size} rule head(s) of ${s.id} NEVER REACHED THE CSSOM:\n\n`,
    );
    for (const [head, g] of byHead) {
      const orphan = head.includes("*/");
      // The swallowed rule is ALWAYS the tail of the garbage run — error recovery
      // stops at the first `{`, and that `{` belongs to the real rule. Naming it
      // is the difference between "some nonsense selector" and ".modal-root is
      // dead in production".
      const swallowed = orphan ? head.slice(head.lastIndexOf("*/") + 2).trim() : null;

      if (orphan) {
        process.stderr.write(
          `   ✗ ${s.id}:${g.where.braceLine}  ${swallowed || "(unnamed)"}   ← SWALLOWED\n` +
            `     ORPHAN-COMMENT SWALLOW — not a malformed selector, and not a bug in this gate.\n` +
            `     The comment beginning at ${s.id}:${g.where.line} is missing its \`/*\` opener, so its\n` +
            `     prose is parsed as CSS. Error recovery then discards tokens until the next\n` +
            `     \`{…}\` block — and that block belongs to \`${swallowed || "the next rule"}\`, which is\n` +
            `     therefore consumed with it and never reaches the browser. This is bug #4592\n` +
            `     exactly: it is how \`.modal-root\` stayed dead in production for five waves.\n` +
            `     __css_check.mjs E10 guards that same mechanism at the source-text level over\n` +
            `     app.css — cross-check it there. It does NOT read this file's inline <style>, so on\n` +
            `     the styleguide entry this gate is the only instrument that can see this.\n` +
            `     Fix: restore the \`/*\` opener at ${s.id}:${g.where.line}.\n` +
            `     Garbage run absorbed into the prelude (${g.keys.length} fragment(s)):\n`,
        );
        for (const k of g.keys) process.stderr.write(`       · ${ellipsis(k)}\n`);
      } else {
        process.stderr.write(`   ✗ ${s.id}:${g.where.braceLine}  ${g.keys.map(ellipsis).join(", ")}\n`);
      }
    }
    process.stderr.write("\n");
  }

  if (failed === 0) {
    process.stdout.write(
      `PARITY PASS — ${sheets.length} rostered sheet(s) certified, every authored selector reached the ` +
        `CSSOM, counts match baselines · ${(wall / 1000).toFixed(1)}s wall · teardown ${teardownMs}ms\n`,
    );
    process.exit(0);
  }

  process.stderr.write(
    `PARITY FAIL — ${failed} of ${sheets.length} rostered sheet(s) failed · ${(wall / 1000).toFixed(1)}s wall · ` +
      `teardown ${teardownMs}ms\n` +
      `Findings are FILED as tasks, never patched by this instrument.\n`,
  );
  process.exit(1);
}

main();
