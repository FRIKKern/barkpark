#!/usr/bin/env bash
#
# workflow-portability-check.sh — the tripwire that keeps every
# .claude/workflows/*.workflow.js engine LOADABLE and PORTABLE on a machine that
# is not this one.
#
# WHY THIS EXISTS
# ---------------
# The engines are distributed with the repo: a fresh clone on someone else's
# laptop, or a cloud runner, must be able to discover, list and launch every one
# of them. Nothing checked that. The failure modes are all silent — the engine
# still parses, still lists, and then dies (or, worse, does the wrong thing) the
# first time a stranger runs it:
#
#   * a hardcoded /Volumes/… or /Users/… path that exists on exactly one Mac;
#   * a $HOME-relative path that resolves somewhere else per user;
#   * a reference to a charter file that lives on the author's disk UNTRACKED,
#     so it is simply absent from every clone;
#   * a meta literal the harness's own validator rejects, which drops the engine
#     out of the listing entirely — with no error anywhere;
#   * declared phases that the body never announces, which leaves a phantom
#     progress group open for a whole run.
#
# ────────────────────────────────────────────────────────────────────────────
# READ THIS BEFORE "SIMPLIFYING" CLAUSE P TO `node --check`
# ────────────────────────────────────────────────────────────────────────────
# `node --check` is VACUOUS on every file in this corpus. It bails out GREEN as
# soon as it detects module syntax, and every engine's first statement is
# `export const meta = …`. Two lines, node v22.22.0:
#
#     printf 'const broken = ;\n' > /tmp/a.js && node --check /tmp/a.js; echo $?
#     # -> 1   a real parse error
#     printf 'export const x = 1;\nconst broken = ;\n' > /tmp/b.js && node --check /tmp/b.js; echo $?
#     # -> 0   VACUOUS: the same syntax error, reported green
#
# A chartered `node --check` clause could therefore never fail on any engine —
# a check that cannot lose. `--input-type=module --check` is no escape either:
# the engines use top-level `return`, and node's module check rejects it
# ("SyntaxError: Illegal return statement") on all four, so that direction reds
# on every file forever.
#
# The engine dialect (`export const meta` + top-level `await` + top-level
# `return`) is valid in NO stock node mode. The harness parses it with acorn
# `{sourceType:"module", allowAwaitOutsideFunction:true,
# allowReturnOutsideFunction:true}`. The dependency-free mirror of exactly that
# is: strip the ONE leading `export `, then COMPILE the remainder as an async
# function body — a function body permits both top-level `return` and `await`.
# The compiled function is NEVER invoked; this is a syntax check, not a run.
# scripts/workflow-portability-check.test.sh case 2 mutates a real engine to
# prove this clause can fail, and case 12 re-derives the `node --check` vacuity
# above from scratch so nobody has to take this comment on faith.
#
# ────────────────────────────────────────────────────────────────────────────
# CLAUSE G IS THE DELIBERATE INVERSE OF cloud-path-escape-check.sh's D31 RULE
# ────────────────────────────────────────────────────────────────────────────
# References are asserted against GIT (`git cat-file -e HEAD:<path>`), never
# against the working tree. That is the opposite of honest-gates D31, where
# scripts/cloud-path-escape-check.sh deliberately enumerates the WORKING TREE
# because an untracked .exs on disk is code the suite will really run.
#
# Both rules follow from the same question — "what will actually be there when
# this code runs?" — and the answers differ because the venue differs:
#
#   D31 (cloud ratchet)   the suite runs HERE, on this checkout. An untracked
#                         file on disk is a real input. git would miss it.
#   G   (this tripwire)   the engine runs THERE, on a fresh clone. An untracked
#                         charter on disk passes every `test -e` on this Mac and
#                         404s for everyone else. DISTRIBUTION IS GIT, so HEAD is
#                         the only honest oracle.
#
# Corpus ENUMERATION here still walks the working tree (the harness readdirs
# disk, so an untracked engine is one a local session can launch). Only
# REFERENCES are asserted against HEAD. The harness carries both polarities:
# case 5 (dangling ref) and case 6 (present on disk, untracked — the case a
# working-tree oracle would pass).
#
# CLAUSES
#   P   parses, via the harness's acorn-equivalent async-body compile
#   M1  `export const meta = {` is the FIRST STATEMENT (the harness inspects
#       body[0], not byte 0 — leading comments and blank lines are fine)
#   M2  meta is a PURE literal (no calls, no spread, no template interpolation,
#       no free identifiers) carrying a non-empty string name AND description
#   S   file is at most 524288 bytes (the harness's own cap)
#   A   no /Volumes/ or /Users/ literal — EVERY offending line is reported
#   H   no $HOME, os.homedir(), process.env.HOME, or quoted ~/ path
#   G   every .claude/workflows/<name> reference is tracked in HEAD
#   C   meta.phases titles === the phase('…') titles the body announces
#   W   WARN (never red) when description + " - " + whenToUse exceeds the
#       harness's 1536-char skill-listing cap, naming the cut point
#   N   an empty corpus, or a missing node, is RED — never a skip
#
# USAGE
#   workflow-portability-check.sh [DIR]     # DIR defaults to .claude/workflows
#   workflow-portability-check.sh --selftest
#
# EXIT  0 = clean (warnings allowed) · 1 = a clause failed · 2 = usage/config

set -euo pipefail

# The harness's own limits, re-derived from the installed binary
# (~/.local/share/claude/versions/2.1.228) rather than guessed:
#   pM  = 524288  the source-size cap
#   JEb = 1536    skillListingMaxDescChars, applied to `${description} - ${whenToUse}`
MAX_BYTES=524288
LISTING_MAX=1536

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  echo "usage: $0 [DIR|--selftest]" >&2
  echo "  DIR defaults to .claude/workflows (relative to the repo root)" >&2
}

case "${1:-}" in
  --selftest)
    exec bash "$HERE/workflow-portability-check.test.sh"
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  -*)
    echo "workflow-portability-check: unknown argument '$1'" >&2
    usage
    exit 2
    ;;
esac

CORPUS_DIR="${1:-.claude/workflows}"

if [ ! -d "$CORPUS_DIR" ]; then
  echo "::error::workflow-portability-check: no such directory: $CORPUS_DIR" >&2
  exit 2
fi
CORPUS_DIR="$(cd -- "$CORPUS_DIR" && pwd)"

# The git repo that owns the corpus — NOT this script's own repo. The harness
# points this at hermetic fixture repos, and clause G must resolve references
# against the fixture's HEAD, not against Barkpark's.
if ! REPO_ROOT="$(git -C "$CORPUS_DIR" rev-parse --show-toplevel 2>/dev/null)"; then
  echo "::error::workflow-portability-check: $CORPUS_DIR is not inside a git repository." >&2
  echo "  Clause G asserts references against HEAD; without git there is no oracle," >&2
  echo "  and a check with no oracle is a skip wearing a green tick." >&2
  exit 2
fi

# ── clause N, first half: no node, no verdict ──────────────────────────────
# NEVER `|| exit 0`, never a skip. A runner image that loses node must red by
# NAME here, not quietly stop checking the engines.
if ! command -v node >/dev/null 2>&1; then
  echo "::error::workflow-portability-check: node is not on PATH." >&2
  echo "  Clauses P/M1/M2/C/W are node-parsed; without node this check is blind." >&2
  echo "  A blind check must RED, never skip (clause N)." >&2
  exit 1
fi

# ── the analyzer (clauses P, M1, M2, C, W) ─────────────────────────────────
# Written to a temp file rather than passed via `node -e`: the program carries
# regex literals and both quote styles, and shell-quoting it is how it would
# rot. It prints one finding per line: `RED|WARN <TAB> clause <TAB> line <TAB> message`.
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/workflow-portability.XXXXXX")"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

cat >"$WORKDIR/analyze.js" <<'ANALYZER'
'use strict';
// Analyzer for clauses P, M1, M2, C and W. One file per invocation; findings on
// stdout as `RED|WARN \t clause \t line \t message`. Exit 0 unless the analyzer
// itself broke (exit 3), which the caller treats as RED — a crashed instrument
// is not a pass.
const fs = require('fs');

const LISTING_MAX = Number(process.argv[3] || 1536);
const file = process.argv[2];
const src = fs.readFileSync(file, 'utf8');
const findings = [];
const lineOf = (i) => src.slice(0, Math.max(0, i)).split('\n').length;
const emit = (kind, clause, line, msg) =>
  findings.push([kind, clause, String(line), String(msg).replace(/[\t\n]+/g, ' ')].join('\t'));
const red = (clause, line, msg) => emit('RED', clause, line, msg);
const warn = (clause, line, msg) => emit('WARN', clause, line, msg);

// ── scanning primitives ───────────────────────────────────────────────────
// Skip a '…' / "…" literal, honouring backslash escapes. Returns the index one
// past the closing quote.
function skipQuoted(s, i) {
  const q = s[i];
  i++;
  while (i < s.length) {
    if (s[i] === '\\') { i += 2; continue; }
    if (s[i] === q) return i + 1;
    i++;
  }
  return s.length;
}

// Skip a `…` template, including nested ${ … } substitutions and any strings or
// templates inside them. Sets seenInterpolation when a ${ is crossed.
let seenInterpolation = false;
function skipTemplate(s, i) {
  i++;
  let depth = 0;
  while (i < s.length) {
    const c = s[i];
    if (c === '\\') { i += 2; continue; }
    if (depth === 0 && c === '`') return i + 1;
    if (c === '$' && s[i + 1] === '{') { seenInterpolation = true; depth++; i += 2; continue; }
    if (depth > 0) {
      if (c === '}') { depth--; i++; continue; }
      if (c === '"' || c === "'") { i = skipQuoted(s, i); continue; }
      if (c === '`') { i = skipTemplate(s, i); continue; }
    }
    i++;
  }
  return s.length;
}

// A '/' opens a regex literal only where a value may start. The heuristic is the
// standard one (previous significant char); it is deliberately conservative —
// misreading a division as a regex would at worst blank out a few characters of
// masked source, and clause M2 rejects a residual '/' inside meta outright.
function regexAllowed(prev) {
  return prev === '' || '(,=:[!&|?{};+-*%~^<>'.indexOf(prev) >= 0;
}
function skipRegex(s, i) {
  let j = i + 1;
  let inClass = false;
  while (j < s.length) {
    const c = s[j];
    if (c === '\\') { j += 2; continue; }
    if (c === '\n') return i; // not a regex after all
    if (inClass) { if (c === ']') inClass = false; }
    else if (c === '[') inClass = true;
    else if (c === '/') { j++; while (j < s.length && /[a-z]/.test(s[j])) j++; return j; }
    j++;
  }
  return i;
}

// Replace every comment (and regex-literal body) with spaces, preserving byte
// offsets and newlines so line numbers stay true. Strings and templates are kept
// verbatim — clause C reads phase('…') titles out of this.
function maskComments(s) {
  const m = s.split('');
  const blank = (a, b) => { for (let k = a; k < b; k++) if (m[k] !== '\n') m[k] = ' '; };
  let i = 0;
  let prev = '';
  while (i < s.length) {
    const c = s[i];
    if (c === '/' && s[i + 1] === '/') {
      let j = s.indexOf('\n', i); if (j < 0) j = s.length;
      blank(i, j); i = j; continue;
    }
    if (c === '/' && s[i + 1] === '*') {
      let j = s.indexOf('*/', i + 2); j = j < 0 ? s.length : j + 2;
      blank(i, j); i = j; continue;
    }
    if (c === '"' || c === "'") { i = skipQuoted(s, i); prev = c; continue; }
    if (c === '`') { i = skipTemplate(s, i); prev = c; continue; }
    if (c === '/' && regexAllowed(prev)) {
      const j = skipRegex(s, i);
      if (j > i) { blank(i, j); i = j; prev = '/'; continue; }
    }
    if (!/\s/.test(c)) prev = c;
    i++;
  }
  return m.join('');
}

// ── clause P — the harness's acorn options, mirrored ──────────────────────
// Strip the ONE leading `export ` (the export of meta itself), then compile the
// whole remaining file as an ASYNC FUNCTION BODY: that is what makes top-level
// `return` and top-level `await` legal, exactly as the harness's acorn options
// do. NEVER invoked. See this script's header for why `node --check` cannot
// stand in here.
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
let parses = true;
try {
  new AsyncFunction(src.replace(/^export\s+/m, ''));
} catch (e) {
  parses = false;
  const m = /(\d+):(\d+)/.exec(String(e.stack || '')) || [];
  red('P', m[1] || 1, `does not compile as an async body (the harness's acorn dialect): ${e.message}`);
}

const masked = maskComments(src);

// ── clause M1 — meta is the FIRST STATEMENT ───────────────────────────────
// The harness inspects body[0] of the parsed program, so leading comments and
// blank lines are fine and only real statements ahead of it are a violation.
// Walking the MASKED source from 0 gives exactly that reading: comments are
// already spaces, so the first non-space character is the first token.
const firstTok = masked.search(/\S/);
const META_DECL = /^export[\s]+const[\s]+meta[\s]*=[\s]*\{/;
if (firstTok < 0) {
  red('M1', 1, 'file is empty — no `export const meta` at all');
} else if (!META_DECL.test(masked.slice(firstTok))) {
  const preview = masked.slice(firstTok, firstTok + 60).split('\n')[0].trim();
  red('M1', lineOf(firstTok),
    `first statement is not \`export const meta = {\` (found: ${preview}) — the harness reads body[0] and drops the engine from the listing when it is anything else`);
}

// ── clause M2 — meta is a PURE literal with name + description ────────────
const declAt = masked.search(/export[\s]+const[\s]+meta[\s]*=[\s]*\{/);
let meta = null;
if (declAt < 0) {
  red('M2', 1, 'no `export const meta = {` declaration found anywhere in the file');
} else {
  const open = masked.indexOf('{', declAt);
  // Brace-match over the MASKED source so braces inside comments cannot move the
  // end of the literal; strings and templates are skipped as units.
  let i = open;
  let depth = 0;
  let end = -1;
  seenInterpolation = false;
  while (i < masked.length) {
    const c = masked[i];
    if (c === '"' || c === "'") { i = skipQuoted(masked, i); continue; }
    if (c === '`') { i = skipTemplate(masked, i); continue; }
    if (c === '{') depth++;
    else if (c === '}') { depth--; if (depth === 0) { end = i + 1; break; } }
    i++;
  }
  if (end < 0) {
    red('M2', lineOf(open), 'the meta object literal is never closed');
  } else {
    const metaSrc = masked.slice(open, end);
    const metaLine = lineOf(open);
    // De-string: keep the quotes, drop the contents. What survives is the
    // literal's STRUCTURE, and the conservative screens below run on that — a
    // '(' in prose can no longer be mistaken for a call.
    let bare = '';
    let k = 0;
    while (k < metaSrc.length) {
      const c = metaSrc[k];
      if (c === '"' || c === "'") { const j = skipQuoted(metaSrc, k); bare += c + c; k = j; continue; }
      if (c === '`') { const j = skipTemplate(metaSrc, k); bare += '``'; k = j; continue; }
      bare += c;
      k++;
    }
    let pure = true;
    const impure = (why) => { pure = false; red('M2', metaLine, `meta is not a pure literal — ${why}`); };
    if (seenInterpolation) impure('a template substitution (${…}) appears inside it');
    if (bare.indexOf('(') >= 0) impure('it contains a call or a parenthesised expression');
    if (bare.indexOf('...') >= 0) impure('it contains a spread');
    if (bare.indexOf('/') >= 0) impure('it contains a `/` outside any string (division or a regex literal)');
    // Every identifier must be a property key. `true`/`false`/`null` are the only
    // bare words a pure literal may carry; anything else is a free identifier the
    // harness's evaluator cannot resolve, so the engine vanishes from the listing.
    const idRe = /[A-Za-z_$][A-Za-z0-9_$]*/g;
    let mm;
    while ((mm = idRe.exec(bare)) !== null) {
      const word = mm[0];
      if (word === 'true' || word === 'false' || word === 'null') continue;
      const after = bare.slice(mm.index + word.length);
      if (/^\s*:/.test(after)) continue; // a property key
      impure(`it references the free identifier \`${word}\``);
      break;
    }
    if (pure) {
      try {
        // Safe BECAUSE the screens above passed: no calls, no spread, no
        // interpolation, no free identifiers — there is nothing left to execute.
        meta = new Function('return (' + metaSrc + ');')();
      } catch (e) {
        red('M2', metaLine, `meta passed the purity screen but does not evaluate: ${e.message}`);
      }
    }
    if (meta) {
      for (const field of ['name', 'description']) {
        if (typeof meta[field] !== 'string' || meta[field].trim() === '') {
          red('M2', metaLine, `meta.${field} must be a non-empty string (the harness requires both name and description)`);
        }
      }
    }
  }
}

// ── clause C — declared phases === announced phases ───────────────────────
function unescape(s) {
  return s.replace(/\\(u\{[0-9a-fA-F]+\}|u[0-9a-fA-F]{4}|x[0-9a-fA-F]{2}|.)/g, (whole, esc) => {
    switch (esc[0]) {
      case 'n': return '\n';
      case 't': return '\t';
      case 'r': return '\r';
      case 'u': case 'x': try { return JSON.parse('"\\' + esc + '"'); } catch (_) { return whole; }
      default: return esc;
    }
  });
}
if (meta) {
  const declared = [];
  if (Array.isArray(meta.phases)) {
    for (const p of meta.phases) {
      if (typeof p === 'string') declared.push(p);
      else if (p && typeof p.title === 'string') declared.push(p.title);
      else red('C', 1, `meta.phases carries an entry with no string title: ${JSON.stringify(p)}`);
    }
  }
  // Called titles come out of the MASKED source, so a commented-out phase('X')
  // is not counted as announced.
  const called = [];
  const callRe = /\bphase\(\s*(['"`])((?:\\.|[\s\S])*?)\1/g;
  let cm;
  while ((cm = callRe.exec(masked)) !== null) called.push(unescape(cm[2]));
  const uniq = (a) => Array.from(new Set(a));
  const D = uniq(declared);
  const C = uniq(called);
  for (const t of D) {
    if (C.indexOf(t) < 0) {
      red('C', 1, `meta.phases declares "${t}" but the body never announces it — a phantom progress group stays open for the whole run`);
    }
  }
  for (const t of C) {
    if (D.indexOf(t) < 0) {
      red('C', 1, `the body announces phase("${t}") but meta.phases does not declare it`);
    }
  }
}

// ── clause W — the 1536-char skill-listing cut (WARN, never RED) ──────────
// The harness composes `${description} - ${whenToUse}` and, past the cap,
// renders slice(0, cap - 1) + "…". Everything after the cut is invisible to
// every agent reading the listing — worth saying out loud, not worth blocking a
// merge over, so this is the one advisory clause.
if (meta && typeof meta.description === 'string') {
  const listing = typeof meta.whenToUse === 'string'
    ? meta.description + ' - ' + meta.whenToUse
    : meta.description;
  if (listing.length > LISTING_MAX) {
    const cut = LISTING_MAX - 1;
    const lost = listing.slice(cut).replace(/\s+/g, ' ').trim();
    warn('W', 1,
      `skill listing is ${listing.length} chars, over the harness cap of ${LISTING_MAX}: it is cut at char ${cut}, after "…${listing.slice(Math.max(0, cut - 40), cut).replace(/\s+/g, ' ')}" — ${listing.length - cut} chars are dropped, starting "${lost.slice(0, 60)}"`);
  }
}

if (!parses) {
  // Everything after clause P read a file that does not compile; say so rather
  // than let a reader take the other clauses' silence for a pass.
  emit('NOTE', 'P', 1, 'clauses M1/M2/C/W were evaluated on a file that does not compile — fix P first');
}

process.stdout.write(findings.length ? findings.join('\n') + '\n' : '');
ANALYZER

# ── the corpus (clause N, second half) ─────────────────────────────────────
# WORKING-TREE enumeration, deliberately: the harness readdirs disk, so an
# untracked engine is one a local session can really launch. Only REFERENCES are
# asserted against HEAD (clause G). Flat, `*.workflow.js` only — the harness's
# own discovery is a flat readdir.
corpus="$(find "$CORPUS_DIR" -maxdepth 1 -type f -name '*.workflow.js' | LC_ALL=C sort)"
corpus_n="$(printf '%s' "$corpus" | grep -c . || true)"

echo "workflow-portability-check: corpus $CORPUS_DIR ($corpus_n engine(s)), repo $REPO_ROOT"

if [ "$corpus_n" -eq 0 ]; then
  echo "::error::workflow-portability-check: the corpus is EMPTY — 0 *.workflow.js under $CORPUS_DIR." >&2
  echo "  An empty corpus is RED, never a green skip (clause N): a check that reports" >&2
  echo "  'all 0 engines pass' is how a mis-typed path becomes a permanent pass." >&2
  exit 1
fi

reds=0
warns=0

note_red() {
  reds=$((reds + 1))
  echo "::error::$1" >&2
}

while IFS= read -r f; do
  [ -n "$f" ] || continue
  rel="${f#"$REPO_ROOT"/}"

  # ── clause S — the harness's 524288-byte source cap ──────────────────────
  bytes="$(wc -c <"$f" | tr -d ' ')"
  if [ "$bytes" -gt "$MAX_BYTES" ]; then
    note_red "workflow-portability-check[S] $rel: $bytes bytes, over the harness cap of $MAX_BYTES — the engine is not loaded at all"
  fi

  # ── clause A — machine-local absolute paths ──────────────────────────────
  # EVERY offending line, never first-match-only: a first-match report turns a
  # four-hit file into a four-round game of whack-a-mole, and the second hit is
  # usually in a different function than the first.
  hits="$(grep -nE '/Volumes/|/Users/' "$f" || true)"
  if [ -n "$hits" ]; then
    while IFS= read -r h; do
      [ -n "$h" ] || continue
      note_red "workflow-portability-check[A] $rel:${h%%:*}: machine-local absolute path — exists on one Mac, nowhere else: $(printf '%s' "${h#*:}" | sed 's/^[0-9]*://' | cut -c1-120)"
    done <<EOF
$hits
EOF
  fi

  # ── clause H — home-relative paths ───────────────────────────────────────
  # $HOME, os.homedir(), process.env.HOME and a quoted leading ~/ all resolve
  # per-user. An engine that writes to one of them writes somewhere different for
  # every reader, and `~/x` is not even expanded by node's fs — it creates a
  # literal directory named `~`.
  hhits="$(grep -nE '\$HOME|os\.homedir\(|process\.env\.HOME|["'"'"'`]~/' "$f" || true)"
  if [ -n "$hhits" ]; then
    while IFS= read -r h; do
      [ -n "$h" ] || continue
      note_red "workflow-portability-check[H] $rel:${h%%:*}: home-relative path — resolves differently per user: $(printf '%s' "${h#*:}" | sed 's/^[0-9]*://' | cut -c1-120)"
    done <<EOF
$hhits
EOF
  fi

  # ── clause G — references must be TRACKED IN HEAD (the D31 inverse) ──────
  # Flat names only, matching the harness's flat readdir. A placeholder like
  # `.claude/workflows/<epic>-charter.md` carries no character from this class
  # after the slash and so does not match at all — placeholders exclude
  # themselves, which is the intended reading: a template is not a reference.
  refs="$(grep -onE '\.claude/workflows/[A-Za-z0-9._-]+' "$f" || true)"
  if [ -n "$refs" ]; then
    while IFS= read -r r; do
      [ -n "$r" ] || continue
      rline="${r%%:*}"
      rpath="${r#*:}"
      if git -C "$REPO_ROOT" cat-file -e "HEAD:$rpath" 2>/dev/null; then
        continue
      fi
      if [ -e "$REPO_ROOT/$rpath" ]; then
        # The case a working-tree oracle passes and every clone fails. Distinct
        # message on purpose: the fix is `git add`, not "create the file".
        note_red "workflow-portability-check[G] $rel:$rline: references $rpath, which exists on THIS disk but is UNTRACKED in HEAD — it is absent from every clone. Distribution is git: \`git add $rpath\`"
      else
        note_red "workflow-portability-check[G] $rel:$rline: references $rpath, which is not in HEAD and not on disk — a dangling reference"
      fi
    done <<EOF
$refs
EOF
  fi

  # ── clauses P, M1, M2, C, W ──────────────────────────────────────────────
  if ! out="$(node "$WORKDIR/analyze.js" "$f" "$LISTING_MAX" 2>&1)"; then
    note_red "workflow-portability-check[P] $rel: the analyzer itself failed — treated as RED, never as a pass: $(printf '%s' "$out" | head -3 | tr '\n' ' ')"
    continue
  fi
  if [ -n "$out" ]; then
    while IFS="$(printf '\t')" read -r kind clause line msg; do
      [ -n "$kind" ] || continue
      case "$kind" in
        RED) note_red "workflow-portability-check[$clause] $rel:$line: $msg" ;;
        WARN)
          warns=$((warns + 1))
          echo "::warning::workflow-portability-check[$clause] $rel:$line: $msg"
          ;;
        *) echo "  note[$clause] $rel:$line: $msg" ;;
      esac
    done <<EOF
$out
EOF
  fi
done <<EOF
$corpus
EOF

echo "workflow-portability-check: $corpus_n engine(s) checked, $reds failure(s), $warns warning(s)"

if [ "$reds" -gt 0 ]; then
  cat >&2 <<'MSG'

One or more engines will not load, or will not behave, on a machine that is not
this one. Every clause above is a thing a fresh clone actually hits:

  [P]  the engine does not parse in the harness's dialect — it never runs
  [M1] meta is not the first statement — the harness drops it from the listing
  [M2] meta is not a pure literal, or lacks name/description — same, silently
  [S]  over the 524288-byte source cap — not loaded at all
  [A]  a hardcoded /Volumes or /Users path — one machine only
  [H]  a $HOME-relative path — a different directory for every user
  [G]  a reference that is not in HEAD — absent from every clone
  [C]  declared and announced phases disagree — a phantom progress group

The [W] warnings are advisory: the listing is merely truncated, not broken.
MSG
  exit 1
fi

echo "OK: every engine parses, registers, and carries no machine-local path."
