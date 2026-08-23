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
#     Because ZERO is also what a BROKEN scan returns, part 3 censuses its
#     corpus before reporting clean, and `--selftest` plants an oEmbed reference
#     in a throwaway tree and requires the real gate to catch it. See the block
#     above part 3 for why a non-empty assertion would be the wrong control.
#
# Usage: scripts/preview-parity-check.sh            # the gate
#        scripts/preview-parity-check.sh --selftest # prove part 3 can still lose
set -euo pipefail

# Absolute, captured BEFORE the cd, because --selftest re-invokes this very file.
SELF="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/$(basename -- "$0")"
cd "$(dirname "$0")/.."

fail() { echo "preview-parity-check: FAILED — $1" >&2; exit 1; }
refuse() { echo "preview-parity-check: REFUSED TO MEASURE — $1" >&2; exit 2; }

# Part 3's corpus root. --selftest points this at a throwaway tree so its
# assertions run the REAL gate; nothing else ever sets it. Parts 1 and 2 are
# unaffected — they assert about two named files in THIS repo.
SCAN_ROOT="${PREVIEW_PARITY_SCAN_ROOT:-.}"

# The ONE scan expression part 3 owns. $1 = regexp, $2 = root.
# PRUNE THE SCRATCH TREES AT THE WALK (D18, applied here).
#
# The three original exclusions are not enough in a working checkout. Measured
# 2026-08-23 at /Volumes/SATECHI/github/barkpark: 10,024 tracked files, and
# 3,190,563 files ON DISK — a 318x amplification from nested worktrees and agent
# scratch trees (.omx alone carries 45,310). This scan took over 90 SECONDS
# there and had to be killed, against 1.5s in a clean worktree. That is the
# definition of a gate that is not runnable LOCALLY, which is exactly where the
# edits it guards are made.
#
# scripts/docs-anchors-check.sh already hit this and solved it the same way,
# and its reasoning transfers exactly: these directories are COPIES of the repo,
# so their contents are duplicates by construction — an oEmbed reference inside
# one is also in the original, which is still scanned. Pruning them cannot hide
# a violation; it only stops the walk reading the same file twenty times.
#
# At the walk, not after it: an exclusion applied to the RESULTS still pays the
# I/O. Same result set, one order of magnitude less work.
scan_sources() {
  grep -roil "$1" \
    --include='*.ex' --include='*.exs' --include='*.go' \
    --include='*.ts' --include='*.tsx' --include='*.heex' \
    --exclude-dir=node_modules --exclude-dir=deps --exclude-dir=_build \
    --exclude-dir=.git --exclude-dir=.omx --exclude-dir=.tmp-bp89 \
    --exclude-dir=.claude --exclude-dir=.artifacts \
    "$2" 2>/dev/null || true
}
SCANNED_EXTS="ex exs go ts tsx heex"

DETAIL_PAGE="web/app/(finder)/d/[type]/[slug]/page.tsx"
GET_DOC="web/lib/get-document.ts"

main() {
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
  # The control is NOT "assert the hit count is non-empty" — a non-empty assertion
  # would red on a correct tree, since zero oEmbed references IS the goal. It is
  # `--selftest`: plant a known oEmbed reference in a throwaway tree, re-invoke
  # THIS script against it through PREVIEW_PARITY_SCAN_ROOT, and require the real
  # gate to FAIL and name the plant; then remove the plant and require it to PASS.
  # The assertions drive the shipping code path rather than a second copy of it
  # that could agree while both are wrong. Exemplars: console-runtime-pin-check.sh
  # and committed-symlink-check.sh (#12742), which is also where the third exit
  # code comes from — "could not read the corpus" is not "read it, found nothing".
  #
  # THE OVERRIDE IS SCOPED TO PART 3'S CORPUS, NOT THE WHOLE SCRIPT. Parts 1 and 2
  # assert about two named files in THIS repo; there is nothing to plant for them
  # and no throwaway tree that would make them meaningful. So a --selftest probe
  # still runs the real parts 1 and 2 (they pass) and only part 3 reads the plant.
  #
  # EXIT CODES
  #   0  clean       1  violation
  #   2  REFUSED TO MEASURE — the scan root carries no scannable source at all

  # --- 3a. census: refuse to certify a tree that holds nothing to scan ---------
  CORPUS_N="$(scan_sources '.' "$SCAN_ROOT" | grep -c . || true)"
  if [ "$CORPUS_N" -eq 0 ]; then
    refuse "zero .ex/.exs/.go/.ts/.tsx/.heex files under $SCAN_ROOT.
    An empty reading is not a clean reading — 'no oEmbed found' would be true of an empty
    directory too. Run this from a real checkout."
  fi

  # --- 3b. the check ----------------------------------------------------------
  OEMBED_HITS="$(scan_sources oembed "$SCAN_ROOT")"

  if [ -n "$OEMBED_HITS" ]; then
    fail "part 3 (D10) — oEmbed appeared in the source tree:
  $OEMBED_HITS
    D10 is CLOSED: NO oEmbed, anywhere, ever. Slack prefers oEmbed over og and a
    careless endpoint downgrades every card. Remove it."
  fi
  echo "preview-parity-check part 3: PASS — D10 upheld: zero oEmbed references across $CORPUS_N scanned source files."

  echo "preview-parity-check: PASS — cross-surface preview contract structurally sound."
}

# ── selftest: prove part 3 BITES, and prove it stays SILENT when it should ────
#
# Every arm builds a throwaway tree and re-invokes THIS script against it via
# PREVIEW_PARITY_SCAN_ROOT, so the assertions drive the shipping code path — not
# a second implementation of the scan that could agree while both are wrong.
# Parts 1 and 2 run for real inside each probe (they read this repo and pass);
# only part 3's corpus is the plant.
selftest() {
  local tmp bad=0 rc
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  say() { if [ "$2" -eq 0 ]; then echo "  ok    $1"; else echo "  FAIL  $1"; bad=$((bad + 1)); fi; }

  fresh() { # a scannable tree with one file per scanned extension, no oEmbed
    # `local x`, NOT `e`: this runs INSIDE the per-extension loop below, and a
    # bare `for e` here would clobber that loop's variable — every plant would
    # land in the last extension and six arms would silently test one.
    local x
    rm -rf "$tmp/t"; mkdir -p "$tmp/t/src"
    for x in $SCANNED_EXTS; do printf 'const endpoint = "/og"\n' > "$tmp/t/src/probe.$x"; done
  }
  probe() { PREVIEW_PARITY_SCAN_ROOT="$tmp/t" bash "$SELF" > "$tmp/out" 2>&1; echo $?; }

  echo "preview-parity-check --selftest (throwaway trees)"

  # 1. SILENT ARM — a clean corpus must not fire.
  fresh; rc="$(probe)"
  { [ "$rc" -eq 0 ] && grep -q "zero oEmbed references across 6 scanned source files" "$tmp/out"; } \
    && say "clean corpus -> PASS (part 3 stays silent with no oEmbed)" 0 \
    || { say "clean corpus -> PASS (got $rc)" 1; sed 's/^/        /' "$tmp/out"; }

  # 2. BITE ARM, once PER SCANNED EXTENSION — this is the arm that catches a
  #    dropped or renamed --include, which is otherwise indistinguishable from
  #    a clean tree. Six separate plants, because one plant only proves one.
  for e in $SCANNED_EXTS; do
    fresh; printf 'fetch("/oembed?url=" + u)\n' > "$tmp/t/src/leak.$e"
    rc="$(probe)"
    { [ "$rc" -eq 1 ] && grep -q "leak\.$e" "$tmp/out"; } \
      && say "oEmbed planted in a .$e file -> FAIL, path named" 0 \
      || { say "oEmbed planted in a .$e file -> FAIL, path named (got $rc)" 1; sed 's/^/        /' "$tmp/out"; }
  done

  # 3. BITE ARM — the scan is case-insensitive by design (`oEmbed`, `OEmbed`).
  fresh; printf 'const OEmbedProvider = 1\n' > "$tmp/t/src/leak.ts"
  rc="$(probe)"
  { [ "$rc" -eq 1 ] && grep -q "leak\.ts" "$tmp/out"; } \
    && say "OEmbed in mixed case -> FAIL (the scan is -i)" 0 \
    || { say "OEmbed in mixed case -> FAIL (got $rc)" 1; sed 's/^/        /' "$tmp/out"; }

  # 4. SILENT ARM — vendored code is not ours to police; --exclude-dir must hold.
  fresh; mkdir -p "$tmp/t/node_modules/vendor"; printf 'oEmbed\n' > "$tmp/t/node_modules/vendor/dep.ts"
  rc="$(probe)"
  { [ "$rc" -eq 0 ]; } \
    && say "oEmbed under node_modules/ -> PASS (excluded, not our code)" 0 \
    || { say "oEmbed under node_modules/ -> PASS (got $rc)" 1; sed 's/^/        /' "$tmp/out"; }

  # 5. SILENT ARM — the --include list is a real boundary, not decoration.
  fresh; printf 'oEmbed\n' > "$tmp/t/src/notes.md"
  rc="$(probe)"
  { [ "$rc" -eq 0 ]; } \
    && say "oEmbed in an unscanned extension (.md) -> PASS" 0 \
    || { say "oEmbed in an unscanned extension (.md) -> PASS (got $rc)" 1; sed 's/^/        /' "$tmp/out"; }

  # 5b. SILENT ARM — the scratch-tree prunes (D18) actually apply. Without this,
  #     the ONLY evidence they work is that the gate got faster, which is not
  #     evidence that it still scans the right set. One arm per pruned directory:
  #     a prune that silently stops applying takes the gate back to 90+ seconds
  #     in a working checkout, and nothing else here would notice.
  for d in .omx .tmp-bp89 .claude .artifacts; do
    fresh; mkdir -p "$tmp/t/$d/copy"; printf 'oEmbed\n' > "$tmp/t/$d/copy/dup.ts"
    [ -f "$tmp/t/$d/copy/dup.ts" ] \
      || { say "PLANT CHECK: the $d plant did not land" 1; continue; }
    rc="$(probe)"
    { [ "$rc" -eq 0 ]; } \
      && say "oEmbed under $d/ -> PASS (scratch copies are pruned, D18)" 0 \
      || { say "oEmbed under $d/ -> PASS (got $rc)" 1; sed 's/^/        /' "$tmp/out"; }
  done

  # 6. REFUSED TO MEASURE — nothing to scan. Silence here would be the defect:
  #    "no oEmbed found" is true of an empty directory, and that is the failure
  #    mode this whole selftest exists to make impossible.
  rm -rf "$tmp/t"; mkdir -p "$tmp/t"; printf 'oEmbed\n' > "$tmp/t/readme.md"
  rc="$(probe)"
  { [ "$rc" -eq 2 ] && grep -q "REFUSED TO MEASURE" "$tmp/out"; } \
    && say "no scannable source at all -> REFUSED TO MEASURE (2), never a silent PASS" 0 \
    || { say "no scannable source at all -> REFUSED TO MEASURE (2) (got $rc)" 1; sed 's/^/        /' "$tmp/out"; }

  echo ""
  if [ "$bad" -eq 0 ]; then echo "preview-parity-check --selftest: PASS (15/15)"; return 0; fi
  echo "preview-parity-check --selftest: FAILED ($bad case(s))"; return 1
}

case "${1:-}" in
  --selftest) selftest ;;
  "")         main ;;
  *)          echo "usage: bash scripts/preview-parity-check.sh [--selftest]" >&2; exit 64 ;;
esac
