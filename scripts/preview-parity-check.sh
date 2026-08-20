#!/usr/bin/env bash
# preview-parity-check.sh — the STRUCTURAL tripwire for the preview contract
# (preview-contract W4, charter D20 Layer 2). The cross-surface FIELD parity is
# proven by the golden-fixture tests (api preview_parity_fixture_test.exs, web
# preview-parity.test.ts, Go preview_parity_test.go — all reading the SAME
# mirror). This script guards the invariants a fixture test cannot see: that no
# surface RESURRECTS a hand-rolled preview, and that D10 stays executable law.
#
#   Part 1 — the web finder detail page consumes the ONE manifest. The per-type
#     `docDescription` / `paperExcerpt` switch (a paper/post-only excerpt fork,
#     the exact drift W3 killed) must stay DEAD; `metadataFromPreview` must be
#     the metadata source.
#   Part 2 — D22: the web detail fetch must carry NO `?fields=` projection.
#     query_controller's project_fields STRIPS any content key a fields list
#     omits — a `fields=` on the detail query would silently drop `preview` off
#     the wire and every card would degrade to the branded default. The by-id
#     doc endpoint (no projection) is the only correct fetch here.
#   Part 3 — D10, recorded as executable law: NO oEmbed. Anywhere. Ever. Slack
#     prefers oEmbed over og and a careless endpoint downgrades every card to a
#     tiny thumbnail. `grep -ri oembed` over the source tree must be ZERO. The
#     decision is CLOSED — this gate exists so it can never be silently reopened.
#     Because ZERO is also what a BROKEN scan returns, part 3 runs a planted
#     positive control first (3a) and censuses the corpus (3b) before it will
#     report a clean tree (3c). See the block above part 3 for why.
#
# Usage: scripts/preview-parity-check.sh
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "preview-parity-check: FAILED — $1" >&2; exit 1; }

DETAIL_PAGE="web/app/(finder)/d/[type]/[slug]/page.tsx"
GET_DOC="web/lib/get-document.ts"

# ── Part 1: the per-type preview switch stays dead ──────────────────────────
[ -f "$DETAIL_PAGE" ] || fail "web finder detail page not found at $DETAIL_PAGE"

if grep -Eq '\b(docDescription|paperExcerpt)\b' "$DETAIL_PAGE"; then
  fail "part 1 — the per-type preview switch (docDescription/paperExcerpt) is BACK in
  $DETAIL_PAGE. The finder must derive every meta tag from the ONE write-time
  preview manifest via metadataFromPreview — not a paper/post excerpt fork (D17/W3)."
fi

if ! grep -q 'metadataFromPreview' "$DETAIL_PAGE"; then
  fail "part 1 — $DETAIL_PAGE no longer calls metadataFromPreview; the finder must
  render its metadata from the shared preview manifest."
fi
echo "preview-parity-check part 1: PASS — the finder consumes the ONE manifest (no per-type switch)."

# ── Part 2: no ?fields= projection on the web detail fetch (D22) ─────────────
for f in "$DETAIL_PAGE" "$GET_DOC"; do
  [ -f "$f" ] || continue
  # Any `fields=` / `fields:` / `"fields"` projection on the detail read would
  # strip `preview` (query_controller project_fields). The by-id doc endpoint
  # carries no projection — keep it that way.
  if grep -Eqi 'fields[[:space:]]*[=:]|["'\'']fields["'\'']' "$f"; then
    fail "part 2 (D22) — a fields= projection appeared in $f. The detail read must NOT
  project content fields, or query_controller strips \`preview\` off the wire and
  every card degrades to the branded default. Fetch the whole doc (by-id endpoint)."
  fi
done
echo "preview-parity-check part 2: PASS — the web detail fetch carries no fields= projection (D22)."

# ── Part 3: D10 — NO oEmbed, anywhere, ever ─────────────────────────────────
#
# WHY THIS PART CARRIES A POSITIVE CONTROL AND PARTS 1-2 DO NOT
# -------------------------------------------------------------
# Parts 1 and 2 read NAMED files: point them at the wrong tree and the `[ -f ]`
# guard fires. Part 3 is an ABSENCE proof over the whole tree, and its expected
# result is ZERO — permanently, because D10 is closed. Zero is also exactly what
# a wrong cwd, a dropped `--include`, or a renamed source extension produce. The
# clean tree and the broken scanner print the same line, forever, so on its own
# this part has no signal that it still works.
#
# The fix is NOT "assert the hit count is non-empty" — a non-empty assertion
# would red on a correct tree, since zero oEmbed references IS the goal. It is a
# PLANTED FIXTURE: build a throwaway tree carrying a known oEmbed reference in
# every extension the scan claims to cover, run the SAME scan expression over
# it, and require it to find each one (and to skip the excluded ones). Then
# census the real corpus with that same expression: if the scan root holds zero
# files of the scanned kinds, this REFUSES TO MEASURE rather than certifying a
# tree it never read. Modelled on scripts/committed-symlink-check.sh --selftest.
#
# EXIT CODES
#   0  clean       1  violation (or a control that did not bite)
#   2  REFUSED TO MEASURE — the scan root carries no scannable source at all

refuse() { echo "preview-parity-check: REFUSED TO MEASURE — $1" >&2; exit 2; }

# The ONE scan expression part 3 owns. $1 = regexp, $2 = root. Every reader —
# the control, the census and the real check — goes through here, so a control
# that passes is a statement about the shipping code path, not about a second
# copy of it that could agree while both are wrong.
scan_sources() {
  grep -roil "$1" \
    --include='*.ex' --include='*.exs' --include='*.go' \
    --include='*.ts' --include='*.tsx' --include='*.heex' \
    --exclude-dir=node_modules --exclude-dir=deps --exclude-dir=_build \
    "$2" 2>/dev/null || true
}
SCANNED_EXTS="ex exs go ts tsx heex"

# --- 3a. positive control: the scan must FIND a planted oEmbed reference -----
CTL="$(mktemp -d)"
trap 'rm -rf "$CTL"' EXIT
mkdir -p "$CTL/src" "$CTL/node_modules/vendor"
for e in $SCANNED_EXTS; do
  printf 'const endpoint = "/oEmbed"\n' > "$CTL/src/probe.$e"
done
printf 'oEmbed\n' > "$CTL/node_modules/vendor/dep.ts"   # excluded tree: must NOT be found
printf 'oEmbed\n' > "$CTL/src/notes.md"                 # unscanned extension: must NOT be found

CTL_HITS="$(scan_sources oembed "$CTL")"
CTL_MISSED=""
for e in $SCANNED_EXTS; do
  if ! printf '%s\n' "$CTL_HITS" | grep -q "probe\.$e\$"; then CTL_MISSED="$CTL_MISSED .$e"; fi
done
if [ -n "$CTL_MISSED" ]; then
  fail "part 3 SELFTEST — the oEmbed scan did NOT find its own planted fixture for:$CTL_MISSED
  The scan is BROKEN, not the tree clean. A dropped --include, a renamed extension or a
  grep that no longer accepts these flags all look like a clean tree from here. Fix the
  scan expression before trusting any 'zero oEmbed references' verdict from this gate."
fi
if printf '%s\n' "$CTL_HITS" | grep -q 'node_modules'; then
  fail "part 3 SELFTEST — the scan reached INTO node_modules; --exclude-dir is not being applied,
  so this gate would red on a vendored dependency nobody here controls."
fi
if printf '%s\n' "$CTL_HITS" | grep -q 'notes\.md'; then
  fail "part 3 SELFTEST — the scan matched an unscanned extension (.md); the --include list is
  not being applied and the scan is reading a wider tree than this gate documents."
fi
echo "preview-parity-check part 3a: PASS — the oEmbed scan finds a planted reference in all 6 scanned extensions and skips node_modules/.md."

# --- 3b. census: refuse to certify a tree that holds nothing to scan ---------
# `.` here is the repo root (this script cd's there at the top, and parts 1-2
# have already proven that by resolving $DETAIL_PAGE). What this catches is the
# other half: a checkout with no scannable source in it at all.
CORPUS_N="$(scan_sources '.' . | grep -c . || true)"
if [ "$CORPUS_N" -eq 0 ]; then
  refuse "zero .ex/.exs/.go/.ts/.tsx/.heex files under $(pwd).
  An empty reading is not a clean reading — 'no oEmbed found' would be true of an empty
  directory too. Run this from a real checkout."
fi

# --- 3c. the real check -----------------------------------------------------
OEMBED_HITS="$(scan_sources oembed .)"

if [ -n "$OEMBED_HITS" ]; then
  fail "part 3 (D10) — oEmbed appeared in the source tree:
$OEMBED_HITS
  D10 is CLOSED: NO oEmbed, anywhere, ever. Slack prefers oEmbed over og and a
  careless endpoint downgrades every card. Remove it."
fi
echo "preview-parity-check part 3: PASS — D10 upheld: zero oEmbed references across $CORPUS_N scanned source files."

echo "preview-parity-check: PASS — cross-surface preview contract structurally sound."
