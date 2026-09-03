#!/usr/bin/env bash
# check-web-fork-drift.sh — NAMED-INVARIANT drift guard for the
# web/lib <-> templates/search-starter/lib fork pair (search-template epic).
#
# WHY NOT BYTE-IDENTITY, EXPLICITLY. scripts/check-astro-finder-drift.sh can
# demand byte-identity because templates/astro-search-starter/src/finder is a
# VERBATIM copy by decree (D44). This pair is NOT: templates/search-starter was
# extracted from web/lib, but web/ is a fixed site and the template is a
# configurable scaffold, so several divergences are CORRECT and permanent
# (branding env vars, demo data, first-run UX, fork-only feature modules, a
# gate-enforced `fields=` ABSENCE on the web side). A byte-identity gate over
# this pair would red on its first run, red forever, and be waived inside a
# week. A waived guard is worse than none.
#
# So this gate asserts NAMED PROPERTIES that must hold in BOTH trees regardless
# of how else they differ, plus an EXEMPTION list of the divergences that are
# deliberate. The classification — which divergence is an unpaid fix and which
# is a decision — is the expensive part and is what this file encodes.
#
# The astro gate's own header records this edge as out of scope:
#   "The web/lib -> search-starter drift is a SEPARATE pre-existing backlog and
#    is explicitly out of scope here."
# That scope note became a permanent exemption: #3779/#3780/#3842 were still
# unpropagated five weeks later. This file is the thing that watches it.
#
# STATUS MODEL — three verdicts, and only one of them is red:
#   enforced + holds     -> OK
#   enforced + violated  -> FAIL   (a regression: the property held, now does not)
#   debt     + violated  -> DEBT   (known-unpaid, owned by the named task row)
#   debt     + holds     -> PROMOTABLE (a sibling row paid it; flip `debt` to
#                                      `enforced` on that invariant's STATUS line)
# A debt entry that gets paid must NEVER red the paying PR — an invariant that
# reds a fix that is correct by this file's own list is a bug in the invariant.
# So PROMOTABLE is loud and exit 0.
#
# bash 3.2 compatible (stock macOS): no associative arrays, no mapfile.
# `--selftest` COPIES both real trees into a temp dir, plants violations there,
# proves the guard reds and NAMES the file and the invariant, restores, proves
# green. It plants nothing in the working tree.
#
# Usage:  bash scripts/check-web-fork-drift.sh [--selftest]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

WEB_LIB="web/lib"
TPL_LIB="templates/search-starter/lib"
# The Retry-After ceiling test lives in a different place in each tree.
WEB_RETRY_TEST="web/__tests__/retry-after.test.ts"
TPL_RETRY_TEST="templates/search-starter/lib/retry-after.test.ts"

# ── Floors ────────────────────────────────────────────────────────────────────
# A gate that passes on an empty tree proves nothing (the node-test-floor.mjs
# lesson: a zero-match glob is a PASS). These are deliberately BELOW today's
# counts so ordinary churn does not trip them, and far above zero.
MIN_WEB_LIB_FILES=30
MIN_TPL_LIB_FILES=20
MIN_INVARIANT_PROBES=14

# ── THE INVARIANT LIST ───────────────────────────────────────────────────────
# ID|TREE|STATUS|OWNER|TITLE
# TREE   is `web` or `template`; every invariant is probed in BOTH.
# STATUS is `enforced` (must hold) or `debt` (known-violated on main today).
# OWNER  names the sibling row or PR the property came from.
INVARIANTS="
INV-1|web|enforced|task-8bc560183cd37bf7|every /d/<type>/<slug> builder percent-encodes both segments (ratcheted: known sites are recorded below, a NEW one reds)
INV-1|template|enforced|task-8bc560183cd37bf7|every /d/<type>/<slug> builder percent-encodes both segments (ratcheted: known sites are recorded below, a NEW one reds)
INV-2|web|enforced|#3780|BpUpstreamError carries a machine-readable 'code' FIELD, not only a message fallback
INV-2|template|debt|task-164cedc3299c5fcd|BpUpstreamError carries a machine-readable 'code' FIELD, not only a message fallback
INV-3|web|enforced|task-3771c96a4b554eeb|the absent-vs-unavailable ruling keeps TWO distinct DocResult buckets and classifies by error CODE, never by instanceof
INV-3|template|enforced|task-3771c96a4b554eeb|the absent-vs-unavailable ruling keeps TWO distinct DocResult buckets and classifies by error CODE, never by instanceof
INV-4|web|debt|task-96fc3fb4fb41d242|the one FLAT /v1/graph call derives the bare origin from the configured API URL
INV-4|template|enforced|#3842|the one FLAT /v1/graph call derives the bare origin from the configured API URL
INV-5|web|debt|task-b84842fb6982e799|popular-query chips are CURATED (a filter over the pool), not merely capped
INV-5|template|enforced|task-b84842fb6982e799|popular-query chips are CURATED (a filter over the pool), not merely capped
INV-6|web|enforced|PR #14006|the Retry-After ceiling is pinned by VALUE — its test bounds the constant against a numeric LITERAL, never only against itself
INV-6|template|enforced|PR #14006|the Retry-After ceiling is pinned by VALUE — its test bounds the constant against a numeric LITERAL, never only against itself
INV-7|web|enforced|task-2811a42a66c7b649|a TYPE 404 (BarkparkNotFoundError, which only the slug-query leg can raise) lands in the ERROR bucket with a message NAMING the type — never in the absent bucket
INV-7|template|enforced|task-3771c96a4b554eeb|a TYPE 404 (BarkparkNotFoundError, which only the slug-query leg can raise) lands in the ERROR bucket with a message NAMING the type — never in the absent bucket
"

# ── INV-1 RATCHET LEDGER ─────────────────────────────────────────────────────
# PATH|COUNT — unencoded `/d/${…}/${…}` builders known on main 2026-09-02,
# owned by task-8bc560183cd37bf7 (which pays BOTH trees). MORE than the recorded
# count, or ANY unencoded builder in a file absent from this ledger, is a RED.
# FEWER is the fix landing: the guard says PROMOTABLE and passes.
INV1_LEDGER="
web/lib/find.ts|2
templates/search-starter/lib/find.ts|2
templates/search-starter/lib/prefix-seed.ts|1
"

# ── THE EXEMPTION LIST ───────────────────────────────────────────────────────
# As important as the invariant list. These divergences are CORRECT: a guard
# that demands six wrong fixes on its first run gets waived. This is a LIVE
# FILTER, not a comment — every finding is passed through it, and the selftest
# plants a violation inside an exempt file to prove the filter bites.
#
# KIND|SUBJECT|REASON     (KIND is `file` or `symbol`)
EXEMPTIONS="
file|web/lib/config.ts|template branding/scope env vars vs a fixed site
file|templates/search-starter/lib/config.ts|template branding/scope env vars vs a fixed site
file|web/lib/tokens.gen.ts|generated design tokens, per-tree brand
file|templates/search-starter/lib/tokens.gen.ts|generated design tokens, per-tree brand
file|web/lib/find-search.ts|the fields= projection divergence: web's ABSENCE is gate-enforced by scripts/preview-parity-check.sh part 2 (D22)
file|templates/search-starter/lib/find-search.ts|the fields= projection divergence: web's ABSENCE is gate-enforced by scripts/preview-parity-check.sh part 2 (D22)
file|web/lib/use-live-search.ts|the fields= projection divergence (D22), same ground as find-search.ts
file|templates/search-starter/lib/use-live-search.ts|the fields= projection divergence (D22), same ground as find-search.ts
file|web/lib/listings.ts|SAMPLE_LISTINGS demo-data fallback is a template affordance
file|templates/search-starter/lib/listings.ts|SAMPLE_LISTINGS demo-data fallback is a template affordance
file|web/lib/bp-env.ts|isApiUrlConfigured / API_URL_CONFIGURED is template first-run UX
file|templates/search-starter/lib/bp-env.ts|isApiUrlConfigured / API_URL_CONFIGURED is template first-run UX
file|templates/search-starter/lib/base-path.ts|fork-only template feature, no web counterpart is owed
file|templates/search-starter/lib/markers.ts|fork-only template feature, no web counterpart is owed
file|templates/search-starter/lib/provenance.ts|fork-only template feature, no web counterpart is owed
file|web/lib/graph-truncation.ts|contract parity already holds (both trees declare truncated + truncationReason); web merely EXTRACTED the reading for testability
symbol|CorpusUnavailableError|web NAMES the fork's class in a comment at web/lib/graph.ts and records that this module still degrades silently BY DESIGN — a documented choice, not drift
symbol|SAMPLE_LISTINGS|template demo data, see listings.ts above
symbol|isApiUrlConfigured|template first-run UX, see bp-env.ts above
"

# ── plumbing ─────────────────────────────────────────────────────────────────

# lib_dir <tree> — the tree's lib root, relative to the repo root.
lib_dir() { if [ "$1" = "web" ]; then echo "$WEB_LIB"; else echo "$TPL_LIB"; fi; }
# retry_test <tree>
retry_test() { if [ "$1" = "web" ]; then echo "$WEB_RETRY_TEST"; else echo "$TPL_RETRY_TEST"; fi; }

# is_exempt <path> — 0 when the path carries a `file` exemption.
is_exempt() {
  _p="$1"
  while IFS='|' read -r kind subject _reason; do
    [ -z "${kind:-}" ] && continue
    [ "$kind" != "file" ] && continue
    [ "$subject" = "$_p" ] && return 0
  done <<< "$EXEMPTIONS"
  return 1
}

# has <root> <relpath> <extended-regex> — 0 when the file exists and matches.
# Never pipes into grep -q: under `set -o pipefail` a SIGPIPE from a short-
# circuiting grep surfaces as exit 141 and reads as a false red.
has() {
  [ -f "$1/$2" ] || return 1
  grep -Eq -- "$3" "$1/$2"
}

# has_in_tree <root> <libdir> <extended-regex> — 0 when ANY file under libdir matches.
has_in_tree() {
  [ -d "$1/$2" ] || return 1
  grep -REq -- "$3" "$1/$2"
}

# strip_comments <file> — the file with // and /* */ comments removed.
# A COMMENT THAT QUOTES THE ASSERTION IS NOT THE ASSERTION. Measured: INV-6's
# first probe passed on a mutated web/__tests__/retry-after.test.ts because that
# file's prose quotes `assert.ok(MAX_RETRY_AFTER_MS < 90_000)` verbatim while
# describing the fork. Every probe that asserts CODE reads through this.
strip_comments() {
  awk '
    BEGIN { inblk = 0 }
    {
      line = $0; out = ""; i = 1
      while (i <= length(line)) {
        c2 = substr(line, i, 2)
        if (inblk) {
          if (c2 == "*/") { inblk = 0; i += 2 } else { i++ }
        } else if (c2 == "/*") { inblk = 1; i += 2 }
        else if (c2 == "//") { break }
        else { out = out substr(line, i, 1); i++ }
      }
      print out
    }' "$1"
}

# has_code_in_tree <root> <libdir> <extended-regex> — like has_in_tree, but over
# comment-stripped source only.
has_code_in_tree() {
  [ -d "$1/$2" ] || return 1
  for f in "$1/$2"/*.ts "$1/$2"/*.tsx; do
    [ -f "$f" ] || continue
    _src="$(strip_comments "$f")"
    if grep -Eq -- "$3" <<< "$_src"; then return 0; fi
  done
  return 1
}

# has_code_flat <root> <relpath> <extended-regex> — 0 when the file exists and
# its COMMENT-STRIPPED source, with every whitespace run squashed to one space,
# matches. INV-7's assertion spans four lines (an `if` and its `return`), and
# both trees' prose QUOTES the two bucket shapes verbatim while explaining them,
# so a probe that read raw bytes would match the explanation and pass on a
# reverted implementation. Same lesson as INV-6's strip_comments.
has_code_flat() {
  [ -f "$1/$2" ] || return 1
  _flat="$(strip_comments "$1/$2" | tr '\n' ' ' | tr -s '[:space:]' ' ')"
  grep -Eq -- "$3" <<< "$_flat"
}

# ── the probes ───────────────────────────────────────────────────────────────
# Each prints nothing and returns 0 (property holds) or 1 (violated). A probe
# that cannot even find its subject returns 1: an unmeasurable invariant is a
# violated one, never a vacuous pass.

# INV-1: unencoded detail-href builders, ratcheted against INV1_LEDGER.
# A builder is `/d/${…}/${…}` in a template literal; it holds when the line
# carries two encodeURIComponent( calls. Comment forms (`/d/<type>/<slug>`,
# `/d/[type]/[slug]`) do not match the `${` anchor and are never counted.
inv1_offenders() {   # <root> <libdir> -> "path count" lines, exempt files dropped
  _root="$1"; _lib="$2"
  [ -d "$_root/$_lib" ] || return 0
  for f in "$_root/$_lib"/*.ts "$_root/$_lib"/*.tsx; do
    [ -f "$f" ] || continue
    rel="${f#$_root/}"
    if is_exempt "$rel"; then continue; fi
    lines="$(grep -n '`/d/\${' "$f" || true)"
    [ -z "$lines" ] && continue
    n=0
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      encs="$(grep -o 'encodeURIComponent(' <<< "$line" | wc -l | tr -d ' ')"
      if [ "${encs:-0}" -lt 2 ]; then n=$((n + 1)); fi
    done <<< "$lines"
    [ "$n" -gt 0 ] && echo "$rel $n"
  done
  return 0
}

ledger_count() {  # <path> -> recorded count, 0 when unrecorded
  _p="$1"
  while IFS='|' read -r p c; do
    [ -z "${p:-}" ] && continue
    if [ "$p" = "$_p" ]; then echo "$c"; return 0; fi
  done <<< "$INV1_LEDGER"
  echo 0
}

# Sets INV1_DETAIL to the first offending path so the finding NAMES A FILE,
# not just the directory the invariant ranges over.
INV1_DETAIL=""
probe_inv1() {  # <root> <tree>
  _root="$1"; _lib="$(lib_dir "$2")"
  _bad=0
  INV1_DETAIL=""
  while read -r rel n; do
    [ -z "${rel:-}" ] && continue
    allowed="$(ledger_count "$rel")"
    if [ "$n" -gt "$allowed" ]; then
      [ -z "$INV1_DETAIL" ] && INV1_DETAIL="$rel ($n unencoded builder(s), ledger allows $allowed)"
      _bad=1
    fi
  done <<< "$(inv1_offenders "$_root" "$_lib")"
  [ "$_bad" -eq 0 ]
}

probe_inv2() {  # BpUpstreamError declares a `code` class FIELD
  has "$1" "$(lib_dir "$2")/bp-fetch.ts" '^[[:space:]]*readonly code\?:[[:space:]]*string;'
}

probe_inv3() {  # two distinct buckets, documented; classification keyed on the CODE
  _root="$1"; _lib="$(lib_dir "$2")"
  has "$_root" "$_lib/get-document.ts" 'doc: null, error: null' || return 1
  has "$_root" "$_lib/get-document.ts" 'doc: null, error: "' || return 1
  has_code_in_tree "$_root" "$_lib" 'isBarkparkError\([^)]*"BarkparkNotFoundError"' || return 1
  # `instanceof` is defeated by a second copy of the class in another realm
  # (@barkpark/core is linked by file: in this monorepo), so it is banned.
  if has_code_in_tree "$_root" "$_lib" 'instanceof[[:space:]]+BarkparkNotFoundError'; then return 1; fi
  return 0
}

probe_inv4() {  # the flat /v1/graph URL is built from a derived bare ORIGIN
  _root="$1"; _lib="$(lib_dir "$2")"
  _f="$_lib/graph.ts"
  has "$_root" "$_f" '/v1/graph\?' || return 1
  has "$_root" "$_f" 'new URL\(.*\)\.origin'
}

probe_inv5() {  # a curation FUNCTION over the popular pool, not just a cap
  has_code_in_tree "$1" "$(lib_dir "$2")" 'export function curatePopularQueries\('
}

probe_inv6() {  # the ceiling is bounded against a numeric LITERAL
  _root="$1"; _f="$(retry_test "$2")"
  [ -f "$_root/$_f" ] || return 1
  # Comments first (this file's own prose quotes the fork's assertion), then
  # squash newlines: the web assertion spans three lines.
  _flat="$(strip_comments "$_root/$_f" | tr '\n' ' ')"
  grep -Eq 'MAX_RETRY_AFTER_MS[[:space:]]*[,<][[:space:]]*[0-9][0-9_]*|[0-9][0-9_]+[[:space:]]*,[[:space:]]*MAX_RETRY_AFTER_MS' <<< "$_flat"
}

# INV-7: the TYPE-404 bucket, asserted in BOTH trees so they cannot drift apart
# on the property they were paired for. Three parts, each killing one mutant:
#   a. the named message exists and INTERPOLATES the type   (drop-the-type)
#   b. the NotFound branch returns it, not `error: null`    (collapse-the-buckets)
#   c. no NotFound branch returns the absent shape          (belt and braces)
# Part (b) is the whole invariant: `{ doc: null, error: null }` there is exactly
# the ruling this pair used to disagree on (web said absent, the template said
# misconfigured), and the disagreement was invisible to INV-3, which only asks
# that TWO buckets exist and that classification is code-keyed — never WHICH
# bucket a TYPE 404 lands in.
probe_inv7() {  # <root> <tree>
  _root="$1"; _f="$(lib_dir "$2")/doc-absence.ts"
  has_code_flat "$_root" "$_f" 'export function unknownTypeMessage\(type: string\)' || return 1
  has_code_flat "$_root" "$_f" 'Unknown document type "\$\{type\}"' || return 1
  has_code_flat "$_root" "$_f" \
    'isBarkparkError\([^)]*"BarkparkNotFoundError"\)\) \{ return \{ doc: null, error: unknownTypeMessage\(type\) \};' || return 1
  if has_code_flat "$_root" "$_f" \
    '"BarkparkNotFoundError"\)\) \{ return \{ doc: null, error: null'; then return 1; fi
  return 0
}

# subject <id> <tree> — the file a finding should NAME.
subject() {
  case "$1" in
    INV-1) lib_dir "$2" ;;
    INV-2) echo "$(lib_dir "$2")/bp-fetch.ts" ;;
    INV-3) echo "$(lib_dir "$2")/get-document.ts" ;;
    INV-4) echo "$(lib_dir "$2")/graph.ts" ;;
    INV-5) echo "$(lib_dir "$2")/find.ts" ;;
    INV-6) retry_test "$2" ;;
    INV-7) echo "$(lib_dir "$2")/doc-absence.ts" ;;
  esac
}

run_probe() {  # <root> <id> <tree>
  case "$2" in
    INV-1) probe_inv1 "$1" "$3" ;;
    INV-2) probe_inv2 "$1" "$3" ;;
    INV-3) probe_inv3 "$1" "$3" ;;
    INV-4) probe_inv4 "$1" "$3" ;;
    INV-5) probe_inv5 "$1" "$3" ;;
    INV-6) probe_inv6 "$1" "$3" ;;
    INV-7) probe_inv7 "$1" "$3" ;;
    *) return 1 ;;
  esac
}

# run_checks <root> — one `VERDICT|id|tree|file|owner|title` line per probe.
run_checks() {
  _root="$1"
  while IFS='|' read -r id tree status owner title; do
    [ -z "${id:-}" ] && continue
    file="$(subject "$id" "$tree")"
    if run_probe "$_root" "$id" "$tree"; then held=yes; else held=no; fi
    if [ "$id" = "INV-1" ] && [ -n "$INV1_DETAIL" ]; then file="$INV1_DETAIL"; fi
    if [ "$held" = "yes" ]; then
      if [ "$status" = "debt" ]; then v=PROMOTABLE; else v=OK; fi
    else
      if [ "$status" = "debt" ]; then v=DEBT; else v=FAIL; fi
    fi
    echo "$v|$id|$tree|$file|$owner|$title"
  done <<< "$INVARIANTS"
}

count_verdict() {  # <report> <verdict>
  grep -c "^$2|" <<< "$1" || true
}

# floor_check <root> — prints failures; returns 1 if any floor is unmet.
floor_check() {
  _root="$1"; _bad=0
  for pair in "$WEB_LIB|$MIN_WEB_LIB_FILES" "$TPL_LIB|$MIN_TPL_LIB_FILES"; do
    d="${pair%%|*}"; min="${pair##*|}"
    if [ ! -d "$_root/$d" ]; then
      echo "  FLOOR  $d does not exist — nothing to compare, refusing to pass"
      _bad=1; continue
    fi
    n="$(find "$_root/$d" -maxdepth 1 -type f \( -name '*.ts' -o -name '*.tsx' \) | wc -l | tr -d ' ')"
    if [ "${n:-0}" -lt "$min" ]; then
      echo "  FLOOR  $d holds $n source file(s), floor is $min — refusing to pass"
      _bad=1
    fi
  done
  return $_bad
}

# ── argument dispatch ────────────────────────────────────────────────────────
# Refuse an unknown argument. A swallowed `--selftest` typo would run the
# ordinary check and report green, fabricating the tripwire's own proof.
if [ -n "${1:-}" ] && [ "$1" != "--selftest" ]; then
  echo "check-web-fork-drift: unknown argument '$1' (expected nothing or --selftest)" >&2
  exit 2
fi

# ── selftest ─────────────────────────────────────────────────────────────────
if [ "${1:-}" = "--selftest" ]; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$tmp/$WEB_LIB" "$tmp/$TPL_LIB" "$tmp/$(dirname "$WEB_RETRY_TEST")"
  cp -R "$REPO_ROOT/$WEB_LIB/." "$tmp/$WEB_LIB/"
  cp -R "$REPO_ROOT/$TPL_LIB/." "$tmp/$TPL_LIB/"
  cp "$REPO_ROOT/$WEB_RETRY_TEST" "$tmp/$WEB_RETRY_TEST"

  fails=0
  expect() {  # <label> <expected-FAIL-count> <must-appear-substring>
    _label="$1"; _want="$2"; _needle="$3"
    _rep="$(run_checks "$tmp")"
    _got="$(count_verdict "$_rep" FAIL)"
    if [ "$_got" -ne "$_want" ]; then
      echo "  SELFTEST FAIL  $_label: $_got FAIL verdict(s), expected $_want"
      fails=$((fails + 1)); return
    fi
    if [ -n "$_needle" ]; then
      if ! grep -Fq -- "$_needle" <<< "$_rep"; then
        echo "  SELFTEST FAIL  $_label: report never named '$_needle'"
        fails=$((fails + 1)); return
      fi
      echo "  ok   $_label -> RED, naming $_needle"
    else
      echo "  ok   $_label -> GREEN (0 FAIL)"
    fi
  }

  # A MUTATION THAT DID NOT APPLY IS NOT A CATCH. Every plant is proven to have
  # changed the file before its verdict is read; a silently-failed perl regex
  # would otherwise let a green probe masquerade as a caught violation.
  mutated() {
    if cmp -s "$REPO_ROOT/$1" "$tmp/$1"; then
      echo "  SELFTEST FAIL  the plant left $1 byte-identical — the mutation never applied"
      fails=$((fails + 1))
      return 1
    fi
    return 0
  }

  echo "SELFTEST — planting violations in a temp COPY of both trees ($tmp)"
  echo "           (the working tree is never written to)"
  echo

  echo "[0] baseline: an unmutated copy of both real trees"
  expect "baseline" 0 ""

  echo
  echo "[1] PLANT INV-2: strip the \`code\` field off web's BpUpstreamError"
  perl -0pi -e 's/^\s*readonly code\?: string;\n//m' "$tmp/$WEB_LIB/bp-fetch.ts"
  mutated "$WEB_LIB/bp-fetch.ts" || true
  expect "INV-2 web" 1 "FAIL|INV-2|web|$WEB_LIB/bp-fetch.ts"
  cp "$REPO_ROOT/$WEB_LIB/bp-fetch.ts" "$tmp/$WEB_LIB/bp-fetch.ts"
  expect "INV-2 restored" 0 ""

  echo
  echo "[2] PLANT INV-3: swap the template's code-keyed test for \`instanceof\`"
  echo "     (the classification moved get-document.ts -> doc-absence.ts in #15762;"
  echo "      this plant's anchor moved with it, and \`mutated\` is what caught that)"
  perl -0pi -e 's/isBarkparkError\(err, "BarkparkNotFoundError"\)/err instanceof BarkparkNotFoundError/' \
    "$tmp/$TPL_LIB/doc-absence.ts"
  mutated "$TPL_LIB/doc-absence.ts" || true
  # TWO reds, and that is correct: INV-3 bans `instanceof` anywhere in the lib
  # dir, and INV-7 pins the NotFound branch to the code-keyed predicate that
  # produces the named message. One plant, two invariants — asserting 1 here
  # would be asserting that INV-7 is blind to it.
  # INV-3 ranges over the whole lib dir (has_code_in_tree), so it NAMES its
  # subject file, get-document.ts, even though the violation is one module over.
  expect "INV-3 template" 2 "FAIL|INV-3|template|$TPL_LIB/get-document.ts"
  if ! grep -Fq "FAIL|INV-7|template|$TPL_LIB/doc-absence.ts" <<< "$(run_checks "$tmp")"; then
    echo "  SELFTEST FAIL  the instanceof plant did not also red INV-7"
    fails=$((fails + 1))
  else
    echo "  ok   INV-3 template -> the same plant also reds INV-7, naming doc-absence.ts"
  fi
  cp "$REPO_ROOT/$TPL_LIB/doc-absence.ts" "$tmp/$TPL_LIB/doc-absence.ts"
  expect "INV-3 restored" 0 ""

  echo
  echo "[2b] PLANT INV-7: flip WEB back to the pre-#15762 ruling (TYPE 404 = absent)"
  echo "     — the exact divergence INV-3 could not see: two buckets still exist"
  echo "       and classification is still code-keyed, only the VERDICT moved."
  perl -0pi -e 's/return \{ doc: null, error: unknownTypeMessage\(type\) \};/return { doc: null, error: null };/' \
    "$tmp/$WEB_LIB/doc-absence.ts"
  mutated "$WEB_LIB/doc-absence.ts" || true
  expect "INV-7 web" 1 "FAIL|INV-7|web|$WEB_LIB/doc-absence.ts"
  cp "$REPO_ROOT/$WEB_LIB/doc-absence.ts" "$tmp/$WEB_LIB/doc-absence.ts"
  expect "INV-7 restored" 0 ""

  echo
  echo "[2c] PLANT INV-7 the other way: flip the TEMPLATE, proving the probe is"
  echo "     symmetric and not merely pinned to whichever tree it was written in"
  perl -0pi -e 's/return \{ doc: null, error: unknownTypeMessage\(type\) \};/return { doc: null, error: null };/' \
    "$tmp/$TPL_LIB/doc-absence.ts"
  mutated "$TPL_LIB/doc-absence.ts" || true
  expect "INV-7 template" 1 "FAIL|INV-7|template|$TPL_LIB/doc-absence.ts"
  cp "$REPO_ROOT/$TPL_LIB/doc-absence.ts" "$tmp/$TPL_LIB/doc-absence.ts"
  expect "INV-7 restored" 0 ""

  echo
  echo "[3] PLANT INV-1: a NEW unencoded /d/ builder in an unledgered web file"
  printf '\nexport const planted = (t: string, s: string) => `/d/${t}/${s}`;\n' \
    >> "$tmp/$WEB_LIB/mark-href.ts"
  mutated "$WEB_LIB/mark-href.ts" || true
  expect "INV-1 web" 1 "FAIL|INV-1|web|$WEB_LIB/mark-href.ts ("
  cp "$REPO_ROOT/$WEB_LIB/mark-href.ts" "$tmp/$WEB_LIB/mark-href.ts"
  expect "INV-1 restored" 0 ""

  echo
  echo "[3b] PLANT INV-1 RATCHET: a THIRD unencoded builder in a LEDGERED file"
  echo "     (web/lib/find.ts is recorded at 2 — the ratchet must red on 3, not on 2)"
  printf '\nexport const planted = (t: string, s: string) => `/d/${t}/${s}`;\n' \
    >> "$tmp/$WEB_LIB/find.ts"
  mutated "$WEB_LIB/find.ts" || true
  expect "INV-1 ratchet" 1 "ledger allows 2"
  cp "$REPO_ROOT/$WEB_LIB/find.ts" "$tmp/$WEB_LIB/find.ts"
  expect "INV-1 ratchet restored" 0 ""

  echo
  echo "[4] PLANT INV-6: make web's ceiling test agree with itself only"
  perl -0pi -e 's/assert\.equal\(parseRetryAfterMs\("3600"\), 20_000\);/assert.equal(parseRetryAfterMs("3600"), MAX_RETRY_AFTER_MS);/;
                s/assert\.equal\(parseRetryAfterMs\("999999999"\), 20_000\);/assert.equal(parseRetryAfterMs("999999999"), MAX_RETRY_AFTER_MS);/;
                s/\s*MAX_RETRY_AFTER_MS,\n\s*20_000,\n/\n    MAX_RETRY_AFTER_MS,\n    MAX_RETRY_AFTER_MS,\n/' \
    "$tmp/$WEB_RETRY_TEST"
  mutated "$WEB_RETRY_TEST" || true
  expect "INV-6 web" 1 "FAIL|INV-6|web|$WEB_RETRY_TEST"
  cp "$REPO_ROOT/$WEB_RETRY_TEST" "$tmp/$WEB_RETRY_TEST"
  expect "INV-6 restored" 0 ""

  echo
  echo "[5] EXEMPTION FILTER: the same INV-1 violation inside an EXEMPT file"
  printf '\nexport const planted = (t: string, s: string) => `/d/${t}/${s}`;\n' \
    >> "$tmp/$WEB_LIB/config.ts"
  mutated "$WEB_LIB/config.ts" || true
  expect "exempt web/lib/config.ts stays green" 0 ""
  cp "$REPO_ROOT/$WEB_LIB/config.ts" "$tmp/$WEB_LIB/config.ts"

  echo
  echo "[6] DEBT ledger is live, not decorative: pay INV-2 in the template"
  perl -0pi -e 's/^(\s*)readonly definitive: boolean;\n/$1readonly definitive: boolean;\n$1readonly code\?: string;\n/m' \
    "$tmp/$TPL_LIB/bp-fetch.ts"
  mutated "$TPL_LIB/bp-fetch.ts" || true
  rep="$(run_checks "$tmp")"
  if grep -Fq "PROMOTABLE|INV-2|template" <<< "$rep"; then
    echo "  ok   a paid debt reports PROMOTABLE, never FAIL (a correct sibling fix must not red)"
  else
    echo "  SELFTEST FAIL  paying INV-2 in the template did not report PROMOTABLE"
    fails=$((fails + 1))
  fi
  if [ "$(count_verdict "$rep" FAIL)" -ne 0 ]; then
    echo "  SELFTEST FAIL  paying a debt produced a FAIL verdict"
    fails=$((fails + 1))
  fi
  cp "$REPO_ROOT/$TPL_LIB/bp-fetch.ts" "$tmp/$TPL_LIB/bp-fetch.ts"

  echo
  echo "[7] FLOOR: an empty tree must REFUSE to pass, not report green"
  empty="$(mktemp -d)"
  mkdir -p "$empty/$WEB_LIB" "$empty/$TPL_LIB"
  if floor_check "$empty" > /dev/null 2>&1; then
    echo "  SELFTEST FAIL  the floor passed on two empty lib directories"
    fails=$((fails + 1))
  else
    echo "  ok   empty trees trip the floor ($MIN_WEB_LIB_FILES / $MIN_TPL_LIB_FILES source files)"
  fi
  rm -rf "$empty"

  echo
  probes="$(grep -c '^INV-' <<< "$INVARIANTS" || true)"
  if [ "${probes:-0}" -lt "$MIN_INVARIANT_PROBES" ]; then
    echo "  SELFTEST FAIL  only $probes probe(s) declared, floor is $MIN_INVARIANT_PROBES"
    fails=$((fails + 1))
  fi

  if [ "$fails" -ne 0 ]; then
    echo "SELFTEST FAIL: $fails assertion(s) failed"
    exit 1
  fi
  echo "SELFTEST PASS: $probes probes; 7 planted violations reported RED and NAMED,"
  echo "               an exempt file's identical violation stayed green, a paid debt"
  echo "               reported PROMOTABLE (never red), and an empty tree tripped the floor."
  exit 0
fi

# ── real check ───────────────────────────────────────────────────────────────
echo "web <-> search-starter named-invariant check: $WEB_LIB vs $TPL_LIB"
echo "(NOT byte-identity — these trees legitimately differ; see the header)"
echo

FLOOR_REPORT="$(floor_check "$REPO_ROOT" || true)"
if [ -n "$FLOOR_REPORT" ]; then
  echo "FLOOR UNMET — refusing to report a pass over an empty or shrunken tree:"
  echo "$FLOOR_REPORT"
  exit 1
fi

REPORT="$(run_checks "$REPO_ROOT")"
N_OK="$(count_verdict "$REPORT" OK)"
N_FAIL="$(count_verdict "$REPORT" FAIL)"
N_DEBT="$(count_verdict "$REPORT" DEBT)"
N_PROM="$(count_verdict "$REPORT" PROMOTABLE)"
N_TOT="$(grep -c '^INV-' <<< "$INVARIANTS" || true)"
N_EXEMPT="$(grep -c '^file|\|^symbol|' <<< "$EXEMPTIONS" || true)"

if [ "$N_TOT" -lt "$MIN_INVARIANT_PROBES" ]; then
  echo "FLOOR UNMET — only $N_TOT invariant probe(s) declared, floor is $MIN_INVARIANT_PROBES."
  exit 1
fi

while IFS='|' read -r v id tree file owner title; do
  [ -z "${v:-}" ] && continue
  case "$v" in
    FAIL) echo "  FAIL        $id [$tree] $file — $title  (owner: $owner)" ;;
    DEBT) echo "  DEBT        $id [$tree] $file — known unpaid, owned by $owner" ;;
    PROMOTABLE) echo "  PROMOTABLE  $id [$tree] $file — now holds; flip its STATUS line in $(basename "$0") from debt to enforced (owner: $owner)" ;;
  esac
done <<< "$REPORT"

if [ "$N_FAIL" -ne 0 ]; then
  echo
  echo "DRIFT — an ENFORCED invariant no longer holds in one of the two trees."
  echo "Fix the named file, or — if the divergence is deliberate — add it to the"
  echo "EXEMPTION list in $(basename "$0") with the reason, never by deleting the invariant."
  echo
  echo "PASS/FAIL: $N_OK ok, $N_FAIL failed, $N_DEBT known-debt, $N_PROM promotable"
  echo "  (of $N_TOT invariant probes over 2 trees; $N_EXEMPT exemptions active)"
  exit 1
fi

echo
echo "OK — $N_OK/$N_TOT enforced invariant probes hold across both trees;"
echo "     $N_DEBT known-debt probe(s) still owned by a filed row; $N_PROM promotable;"
echo "     $N_EXEMPT exemption record(s) active; floors met"
echo "     ($WEB_LIB and $TPL_LIB, >= $MIN_WEB_LIB_FILES / $MIN_TPL_LIB_FILES source files)."
exit 0
