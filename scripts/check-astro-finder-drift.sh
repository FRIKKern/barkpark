#!/usr/bin/env bash
# check-astro-finder-drift.sh — byte-identity tripwire for the Astro finder copy
# (search-template epic D44).
#
# The Astro flagship (templates/astro-search-starter) does NOT share the finder
# code — D44 deliberately pays the copy cost: the finder closure is COPIED
# VERBATIM out of templates/search-starter into
# templates/astro-search-starter/src/finder/ (finder.tsx + its 13-module lib
# closure) plus app/globals.css -> src/styles/globals.css. A copy without a gate
# reproduces the proven drift pattern (#3779/#3780/#3842 were unpropagated
# within 24h of the search-starter vendor): a fix lands in search-starter and
# the Astro copy silently rots.
#
# This gate reds the moment ANY vendored Astro file differs, byte-for-byte, from
# its templates/search-starter source. It names every drifted file. A MISSING
# vendored file counts as drift (until slice stw7-finder-island-mount lands the
# verbatim copy, this gate reds — that is correct; it goes green on main once the
# closure exists).
#
# PARITY TARGET is search-starter and ONLY search-starter: the Astro copy
# inherits whatever state search-starter is in. The web/lib -> search-starter
# drift is a SEPARATE pre-existing backlog and is explicitly out of scope here.
#
# bash 3.2 compatible (stock macOS): no associative arrays, no mapfile.
# `--selftest` proves the tripwire bites in temp files (plants nothing in the
# tree): identical copies stay green; a one-byte mutation reds and is named.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

SRC_BASE="templates/search-starter"
DST_BASE="templates/astro-search-starter/src/finder"

# The vendored closure as SOURCE|DEST pairs, both relative to REPO_ROOT.
# SOURCE = the canonical templates/search-starter path.
# DEST   = the Astro vendored copy.
#   finder.tsx  <- components/finder.tsx           (at src/finder/finder.tsx)
#   lib/*       <- lib/*                            (at src/finder/lib/*)
#   globals.css <- app/globals.css                 (at src/styles/globals.css)
# tokens.gen.ts is one of the 13 lib modules (src/finder/lib/tokens.gen.ts).
MAPPINGS="
$SRC_BASE/components/finder.tsx|$DST_BASE/finder.tsx
$SRC_BASE/lib/find.ts|$DST_BASE/lib/find.ts
$SRC_BASE/lib/find-shape.ts|$DST_BASE/lib/find-shape.ts
$SRC_BASE/lib/config.ts|$DST_BASE/lib/config.ts
$SRC_BASE/lib/hovered-doc-context.tsx|$DST_BASE/lib/hovered-doc-context.tsx
$SRC_BASE/lib/finder-nav-context.tsx|$DST_BASE/lib/finder-nav-context.tsx
$SRC_BASE/lib/use-live-search.ts|$DST_BASE/lib/use-live-search.ts
$SRC_BASE/lib/prefix-seed.ts|$DST_BASE/lib/prefix-seed.ts
$SRC_BASE/lib/did-you-mean.ts|$DST_BASE/lib/did-you-mean.ts
$SRC_BASE/lib/search-session.ts|$DST_BASE/lib/search-session.ts
$SRC_BASE/lib/stem.ts|$DST_BASE/lib/stem.ts
$SRC_BASE/lib/fuzzy.ts|$DST_BASE/lib/fuzzy.ts
$SRC_BASE/lib/tokens.gen.ts|$DST_BASE/lib/tokens.gen.ts
$SRC_BASE/lib/base-path.ts|$DST_BASE/lib/base-path.ts
$SRC_BASE/app/globals.css|templates/astro-search-starter/src/styles/globals.css
"

# check_pair <root> <src-rel> <dst-rel>
# Emits a one-line reason on drift (to stdout) and returns 1; returns 0 if
# byte-identical. Missing source or dest is drift.
check_pair() {
  root="$1"; src="$2"; dst="$3"
  if [ ! -f "$root/$src" ]; then
    echo "  MISSING SOURCE  $src (cannot compare $dst)"
    return 1
  fi
  if [ ! -f "$root/$dst" ]; then
    echo "  MISSING COPY    $dst (expected verbatim copy of $src)"
    return 1
  fi
  if ! cmp -s "$root/$src" "$root/$dst"; then
    echo "  DRIFTED         $dst != $src"
    return 1
  fi
  return 0
}

# run_checks <root>  — iterate MAPPINGS, return count of drifted files.
run_checks() {
  root="$1"
  echo "$MAPPINGS" | while IFS='|' read -r src dst; do
    [ -z "$src" ] && continue
    if ! check_pair "$root" "$src" "$dst"; then
      echo "DRIFT"
    fi
  done | grep -c '^DRIFT$' || true
}

# ---- argument dispatch -------------------------------------------------------
# Refuse an argument this gate does not understand. A swallowed flag — a
# `--selftest` typo, a future rename — would silently run the ordinary check
# and report green, fabricating the tripwire's own proof.
if [ -n "${1:-}" ] && [ "$1" != "--selftest" ]; then
  echo "check-astro-finder-drift: unknown argument '$1' (expected nothing or --selftest)" >&2
  exit 2
fi

# ---- selftest ---------------------------------------------------------------
if [ "${1:-}" = "--selftest" ]; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$tmp/$SRC_BASE/components" "$tmp/$SRC_BASE/lib" "$tmp/$SRC_BASE/app"
  mkdir -p "$tmp/$DST_BASE/lib" "$tmp/templates/astro-search-starter/src/styles"

  # Plant identical copies of every mapped pair.
  echo "$MAPPINGS" | while IFS='|' read -r src dst; do
    [ -z "$src" ] && continue
    mkdir -p "$tmp/$(dirname "$src")" "$tmp/$(dirname "$dst")"
    printf 'content of %s\n' "$src" > "$tmp/$src"
    cp "$tmp/$src" "$tmp/$dst"
  done

  n="$(run_checks "$tmp")"
  if [ "$n" -ne 0 ]; then
    echo "SELFTEST FAIL: identical copies reported $n drift(s), expected 0"
    exit 1
  fi

  # Mutate one vendored byte -> must be caught.
  printf 'x' >> "$tmp/$DST_BASE/lib/find.ts"
  n="$(run_checks "$tmp")"
  if [ "$n" -ne 1 ]; then
    echo "SELFTEST FAIL: one mutation reported $n drift(s), expected 1"
    exit 1
  fi

  # Remove a vendored file -> must be caught as MISSING COPY.
  rm -f "$tmp/$DST_BASE/finder.tsx"
  n="$(run_checks "$tmp")"
  if [ "$n" -ne 2 ]; then
    echo "SELFTEST FAIL: mutation+deletion reported $n drift(s), expected 2"
    exit 1
  fi

  echo "SELFTEST PASS: byte-identity tripwire detects drift, deletion, and green parity"
  exit 0
fi

# ---- real check -------------------------------------------------------------
echo "Astro finder byte-identity check: $DST_BASE vs $SRC_BASE"
DRIFT_REPORT="$(
  echo "$MAPPINGS" | while IFS='|' read -r src dst; do
    [ -z "$src" ] && continue
    check_pair "$REPO_ROOT" "$src" "$dst" || true
  done
)"

if [ -n "$DRIFT_REPORT" ]; then
  echo "DRIFT — the Astro finder copy is out of sync with $SRC_BASE:"
  echo "$DRIFT_REPORT"
  echo
  echo "Fix: re-copy the drifted file(s) VERBATIM from $SRC_BASE. The Astro"
  echo "closure is a byte-for-byte copy (D44); never hand-edit the vendored copy."
  exit 1
fi

echo "OK — all vendored finder files are byte-identical to $SRC_BASE."
exit 0
