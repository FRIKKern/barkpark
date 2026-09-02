#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Barkpark contributors
#
# site-spawner-accented-fixture.sh — GENERATE the accented prebuilt dist that the
# spawner's Unicode tail is proven against, from NUMERIC CODEPOINT ESCAPES, and
# ASSERT the normal form of every name it wrote by reading it BACK OFF THE DISK.
#
#   bash deploy/site-spawner-accented-fixture.sh --out <dir> --slug <site>
#                                     [--manifest <file>]   # the ASCII probe paths
#   bash deploy/site-spawner-accented-fixture.sh --self-check   # offline, no network
#
# WHY THE NAMES ARE NEVER TYPED
#   An accented literal in a source file is not a fixed input. This repo sets
#   `core.precomposeunicode=true`, so `git add` of an NFD path RECORDS it as NFC,
#   and an NFD tree entry checked out on macOS leaves a permanently dirty
#   worktree (untracked-as-NFC while tracked-as-NFD). Editors and terminals
#   renormalise too — a prior verifier's own accented literals changed form
#   NONDETERMINISTICALLY between two invocations in one session. So every
#   accented byte here comes from a `$'\xNN'` escape naming the exact UTF-8
#   encoding of a numbered codepoint, and NOTHING accented is ever committed.
#
# WHY IT WRITES ONE NFC NAME *AND* ONE NFD NAME, ON DIFFERENT BASE LETTERS
#   The interesting question is whether the two forms are DISTINCT paths on the
#   serving box, and one directory cannot answer it: on APFS (this laptop) the
#   two forms COLLIDE — normalization-insensitive lookup means `mkdir` of the
#   second form lands on the first — so a single accented name can only ever be
#   probed in the form it was written. Two names on different base letters dodge
#   the collision and let the box be asked both ways round:
#
#     café/   written NFC  (U+00E9)                 → probe NFC, then NFD
#     naïve/  written NFD  (i + U+0308)             → probe NFD, then NFC
#
#   A box that answers only the written form is normalization-SENSITIVE; one that
#   answers both is INSENSITIVE. Either verdict is a result. Note that APFS is
#   normalization-PRESERVING, so the bytes this script writes are the bytes the
#   packer reads — verified below by `od`, not assumed.
#
# WHAT THE DIST CONTAINS
#   index.html plus one page under each accented directory. Every page carries
#   the five deploy markers the box's HEALTH gate reads by value (bp-build-id,
#   bp-content-rev, bp-doc-id, bp-doc-title, bp-site-base). bp-build-id and
#   bp-content-rev are placeholders — the caller restamps them with the nonced
#   values the mint hands out — but bp-doc-id must be NON-EMPTY here (site-deploy
#   HEALTH refuses an empty one and blames the build) and bp-site-base must be
#   the real `/sites/<slug>/` PATH (nothing in the system checks it: a wrong slug
#   ships a cheerful 200 whose every asset href is dead).
#
#   index.html links to both accented directories with PERCENT-ENCODED hrefs.
#   That is deliberate: site-deploy.sh's HEALTH deep-path probe takes its target
#   from the served html's own links and sorts NON-ASCII first, so the box itself
#   fetches an accented path before it will switch. The fixture makes that gate
#   fire rather than hoping it does.
#
# EXITS
#   0  the dist was written and every name read back in the asserted normal form
#   2  bad usage
#   3  a name did not read back in the form it was written (APFS renormalised, or
#      the escape is wrong) — the fixture is NOT usable and says so
#   4  python3 is missing (the normal-form assert cannot be made, so nothing is
#      claimed)

set -uo pipefail

OUT=""
MANIFEST=""
SLUG="perfect-proof"
BUILD_ID="fixture-unstamped"
CONTENT_REV="fixture-unstamped"
DOC_ID="ssw10-accented-fixture"
DOC_TITLE="the accented walk"
MODE="generate"

E_USAGE=2
E_FORM=3
E_NO_PYTHON=4

say() { printf '%s\n' "$*" >&2; }

# ---- the accented bytes, by codepoint ---------------------------------------
# Each escape names the UTF-8 encoding of ONE numbered codepoint. `$'\xNN'` is
# used rather than `$'\uXXXX'` because bash 3.2 (the macOS system bash, which
# this repo still runs on) has no \u.
#
#   U+00E9  LATIN SMALL LETTER E WITH ACUTE      → C3 A9
#   U+0301  COMBINING ACUTE ACCENT               → CC 81
#   U+00EF  LATIN SMALL LETTER I WITH DIAERESIS  → C3 AF
#   U+0308  COMBINING DIAERESIS                  → CC 88
CP_00E9=$'\xc3\xa9'
CP_0301=$'\xcc\x81'
CP_0308=$'\xcc\x88'

# The two directory names. NFC_DIR is precomposed; NFD_DIR is decomposed.
NFC_DIR="caf${CP_00E9}"            # café — NFC, 5 codepoints, 5 bytes
NFD_DIR="nai${CP_0308}ve"          # naïve — NFD, 6 codepoints, 7 bytes

# Their percent-encodings, in BOTH forms, so a caller can probe the match and the
# mismatch without ever re-deriving them. These are pure ASCII on purpose: they
# are the only shape of these names that a shell, a URL and a log all agree on.
PCT_NFC_MATCH="caf%C3%A9"          # café written NFC, requested NFC  → must hit
PCT_NFC_OTHER="cafe%CC%81"         # café written NFC, requested NFD  → the probe
PCT_NFD_MATCH="nai%CC%88ve"        # naïve written NFD, requested NFD → must hit
PCT_NFD_OTHER="na%C3%AFve"         # naïve written NFD, requested NFC → the probe
PCT_CONTROL="__no_such_path_control__"

# A string that appears ONLY inside the accented pages, so a caller can tell a
# real hit from a server fallback that answers 200 with the ROOT index.
FIXTURE_MARKER="accented-walk"

usage() {
  sed -n '5,10p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit "${1:-$E_USAGE}"
}

# page <path> <title> — one marker-bearing html page.
page() {
  local path="$1" title="$2" links="${3:-}"
  cat >"$path" <<HTML
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="bp-build-id" content="$BUILD_ID">
<meta name="bp-content-rev" content="$CONTENT_REV">
<meta name="bp-doc-id" content="$DOC_ID">
<meta name="bp-doc-title" content="$DOC_TITLE">
<meta name="bp-site-base" content="/sites/$SLUG/">
<title>$title</title>
</head>
<body>
<h1>$title</h1>
<p data-bp-fixture="accented-walk">$title</p>
$links
</body>
</html>
HTML
}

generate() {
  [ -n "$OUT" ] || usage "$E_USAGE"
  command -v python3 >/dev/null 2>&1 || {
    say "python3 is required: this script REFUSES to write a fixture whose normal form it cannot assert."
    exit "$E_NO_PYTHON"
  }

  rm -rf "$OUT"
  mkdir -p "$OUT/$NFC_DIR" "$OUT/$NFD_DIR" || {
    say "could not create the accented directories under $OUT"
    exit "$E_FORM"
  }

  page "$OUT/index.html" "accented walk — index" \
"<ul>
<li><a href=\"/sites/$SLUG/$PCT_NFC_MATCH/\">the NFC-named page</a></li>
<li><a href=\"/sites/$SLUG/$PCT_NFD_MATCH/\">the NFD-named page</a></li>
</ul>"
  page "$OUT/$NFC_DIR/index.html" "accented walk — NFC directory"
  page "$OUT/$NFD_DIR/index.html" "accented walk — NFD directory"

  # ---- THE ASSERT ----------------------------------------------------------
  # Read the names BACK OFF THE DISK and check the form. Nothing here compares
  # against a typed literal: the expected names are rebuilt from chr(<codepoint>)
  # inside python, and the expected bytes are spelled in hex.
  python3 - "$OUT" <<'PY' || exit "$E_FORM"
import os, sys, unicodedata

root = sys.argv[1]

want_nfc = "caf" + chr(0x00E9)                 # café, precomposed
want_nfd = "nai" + chr(0x0308) + "ve"          # naïve, decomposed
want_nfc_bytes = b"caf\xc3\xa9"
want_nfd_bytes = b"nai\xcc\x88ve"

names = sorted(n for n in os.listdir(root) if os.path.isdir(os.path.join(root, n)))
raw = sorted(n for n in os.listdir(os.fsencode(root))
             if os.path.isdir(os.path.join(os.fsencode(root), n)))

bad = []
if want_nfc not in names:
    bad.append("the NFC directory did not read back as caf+U+00E9; got %r" % (names,))
if want_nfd not in names:
    bad.append("the NFD directory did not read back as nai+U+0308+ve; got %r" % (names,))
if want_nfc_bytes not in raw:
    bad.append("the NFC directory's ON-DISK BYTES are not %r; got %r" % (want_nfc_bytes, raw))
if want_nfd_bytes not in raw:
    bad.append("the NFD directory's ON-DISK BYTES are not %r; got %r" % (want_nfd_bytes, raw))

for n, form in ((want_nfc, "NFC"), (want_nfd, "NFD")):
    if n in names:
        other = "NFD" if form == "NFC" else "NFC"
        if not unicodedata.is_normalized(form, n):
            bad.append("%r is not in %s" % (n, form))
        if unicodedata.is_normalized(other, n):
            bad.append("%r is ALSO in %s — the two forms are not distinct, so this "
                       "fixture cannot tell a normalization-sensitive box from an "
                       "insensitive one" % (n, other))

if bad:
    for b in bad:
        sys.stderr.write("  ✗ %s\n" % b)
    sys.stderr.write("  the filesystem under %s did not preserve the form that was "
                     "written (APFS is normalization-PRESERVING; HFS+ was not) — "
                     "this fixture is NOT usable.\n" % root)
    raise SystemExit(1)

for n, form, b in ((want_nfc, "NFC", want_nfc_bytes), (want_nfd, "NFD", want_nfd_bytes)):
    sys.stderr.write("  ✓ %-8s %-4s  codepoints %-28s bytes %s\n" % (
        n, form,
        " ".join("U+%04X" % ord(c) for c in n),
        " ".join("%02x" % x for x in b)))
PY

  # The raw bytes again, through a DIFFERENT instrument (od, not python), because
  # a single reader that lies about encoding would agree with itself.
  say "  ── ls | od -c over the generated tree (a second, independent reader) ──"
  ( cd "$OUT" && ls ) | od -c | sed 's/^/    /' >&2

  say "  ✓ dist written to $OUT (slug '$SLUG', bp-site-base /sites/$SLUG/)"
  say "  ✓ probe paths — hit: $PCT_NFC_MATCH/ $PCT_NFD_MATCH/"
  say "  ✓ probe paths — wrong form: $PCT_NFC_OTHER/ $PCT_NFD_OTHER/   control: $PCT_CONTROL/"

  # THE MANIFEST IS WRITTEN OUTSIDE THE DIST, DELIBERATELY. Anything inside $OUT
  # is packed and staged; a caller-only handoff file has no business being served
  # (and a dotfile at the artifact root is exactly the kind of entry an extractor
  # is entitled to refuse). It is pure ASCII so that sourcing it is safe.
  if [ -n "$MANIFEST" ]; then
    cat >"$MANIFEST" <<MAN
ACC_NFC_MATCH=$PCT_NFC_MATCH
ACC_NFC_OTHER=$PCT_NFC_OTHER
ACC_NFD_MATCH=$PCT_NFD_MATCH
ACC_NFD_OTHER=$PCT_NFD_OTHER
ACC_CONTROL=$PCT_CONTROL
ACC_MARKER=$FIXTURE_MARKER
MAN
    say "  ✓ probe manifest → $MANIFEST"
  fi
}

self_check() {
  local td rc=0
  td="$(mktemp -d "${TMPDIR:-/tmp}/bp-accented-fixture-XXXXXX")" || exit 1
  say "▸ SELF-CHECK — generate into $td and assert every name's form"
  OUT="$td/dist"
  generate || rc=$?
  if [ "$rc" -eq 0 ]; then
    # The four invariants a caller depends on, re-checked from the outside.
    [ -f "$td/dist/index.html" ] || { say "  ✗ no index.html"; rc=1; }
    [ -f "$td/dist/$NFC_DIR/index.html" ] || { say "  ✗ no page under the NFC directory"; rc=1; }
    [ -f "$td/dist/$NFD_DIR/index.html" ] || { say "  ✗ no page under the NFD directory"; rc=1; }
    grep -q "bp-site-base\" content=\"/sites/$SLUG/\"" "$td/dist/index.html" ||
      { say "  ✗ bp-site-base is not /sites/$SLUG/"; rc=1; }
    grep -q "$PCT_NFC_MATCH" "$td/dist/index.html" ||
      { say "  ✗ index.html does not link the NFC page percent-encoded"; rc=1; }
    grep -q "$PCT_NFD_MATCH" "$td/dist/index.html" ||
      { say "  ✗ index.html does not link the NFD page percent-encoded"; rc=1; }
    # APFS collision, asserted rather than believed: the two forms of the SAME
    # base letter must be the same directory on this laptop. If they ever stop
    # colliding, the comment above is wrong and the fixture design changes.
    if [ -d "$td/dist/caf${CP_00E9}" ] && [ -d "$td/dist/cafe${CP_0301}" ]; then
      say "  ✓ this filesystem is normalization-INSENSITIVE (both forms of café resolve) — as documented"
    else
      say "  ✓ this filesystem is normalization-SENSITIVE (only the written form of café resolves)"
    fi
  fi
  rm -rf "$td"
  if [ "$rc" -eq 0 ]; then say "SELF-CHECK PASSED"; else say "SELF-CHECK FAILED (rc=$rc)"; fi
  exit "$rc"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --out) shift; OUT="${1:-}" ;;
    --manifest) shift; MANIFEST="${1:-}" ;;
    --slug) shift; SLUG="${1:-}" ;;
    --build-id) shift; BUILD_ID="${1:-}" ;;
    --content-rev) shift; CONTENT_REV="${1:-}" ;;
    --doc-id) shift; DOC_ID="${1:-}" ;;
    --doc-title) shift; DOC_TITLE="${1:-}" ;;
    --self-check) MODE="self-check" ;;
    -h | --help) usage 0 ;;
    *) say "unknown flag: $1"; usage "$E_USAGE" ;;
  esac
  shift
done

case "$MODE" in
  self-check) self_check ;;
  *) generate ;;
esac
