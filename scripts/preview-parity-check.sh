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
#     Part 2's corpus is TWO NAMED FILES and it now REFUSES (exit 2) when either
#     is absent — see the block above part 2 for the planted runs that forced it.
#   Part 3 — D10, recorded as executable law: NO oEmbed. Anywhere. Ever. Slack
#     prefers oEmbed over og and a careless endpoint downgrades every card to a
#     tiny thumbnail. `grep -ri oembed` over the PRODUCT source tree must be
#     ZERO. The decision is CLOSED — this gate exists so it can never be
#     silently reopened. Because ZERO is also what a BROKEN scan returns, part 3
#     censuses its corpus before reporting clean, and `--selftest` plants an
#     oEmbed reference in a throwaway tree and requires the real gate to catch
#     it. See the block above part 3 for why a non-empty assertion would be the
#     wrong control.
#
# Usage: scripts/preview-parity-check.sh            # the gate
#        scripts/preview-parity-check.sh --selftest # prove parts 2+3 can still lose
set -euo pipefail

# Absolute, captured BEFORE the cd, because --selftest re-invokes this very file.
SELF="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/$(basename -- "$0")"
cd "$(dirname "$0")/.."

fail() { echo "preview-parity-check: FAILED — $1" >&2; exit 1; }
refuse() { echo "preview-parity-check: REFUSED TO MEASURE — $1" >&2; exit 2; }

# Part 3's corpus root, and (separately) parts 1+2's fetch-corpus root.
# `--selftest` points BOTH at a throwaway tree so its assertions run the REAL
# gate rather than a second copy of it; nothing else ever sets either.
SCAN_ROOT="${PREVIEW_PARITY_SCAN_ROOT:-.}"
FETCH_ROOT="${PREVIEW_PARITY_FETCH_ROOT:-.}"

# ── Part 3's corpus definition ────────────────────────────────────────────────
#
# WHY THE EXTENSION LIST IS WIDER THAN THE ELIXIR/TS SOURCE SET
# -------------------------------------------------------------
# D10 says "anywhere, ever", and the implementation used to grep SIX extensions
# (.ex .exs .go .ts .tsx .heex). Planted one-liners measured 2026-09-05 on
# 9fdca8cb8: web/lib/a.js, a.mjs, a.css and a.json each sailed through at exit
# 0 while a .heex plant correctly red. An oEmbed route or provider manifest in
# a Next.js app is a .js/.mjs/.json file — precisely the shape the gate missed.
#
# WHY THE WALK IS SCOPED TO PRODUCT DIRECTORIES
# ---------------------------------------------
# The literal fix — drop the include filters — is unshippable: it reds main on
# pre-existing hits, three of which are THE BAN DOCUMENTING ITSELF
# (docs/ops/merge-gates.md, .github/workflows/doc-gates.yml, and this script's
# own prose). A ban that cannot be written down is not enforceable. So the
# corpus is the PRODUCT source dirs — the places an oEmbed endpoint could
# actually ship from — and docs/, .github/ and scripts/ stay out by
# construction. Any future "anywhere, ever" guard in this repo needs the same
# self-exclusion designed in from the start.
#
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
SCANNED_EXTS="ex exs go ts tsx heex js mjs cjs jsx css py rb json yml yaml"
SCANNED_DIRS="api web js internal cloud apps cmd connectors design"

# The ONE scan expression part 3 owns. $1 = regexp, $2 = root.
# Prints nothing (exit 0) when the root holds none of $SCANNED_DIRS — the
# census in 3a turns that into a REFUSAL, never into a clean reading.
scan_sources() {
  local re="$1" root="$2" d
  local roots=()
  for d in $SCANNED_DIRS; do [ -d "$root/$d" ] && roots+=("$root/$d"); done
  [ "${#roots[@]}" -gt 0 ] || return 0
  local includes=() e
  for e in $SCANNED_EXTS; do includes+=("--include=*.$e"); done
  grep -roil "$re" \
    "${includes[@]}" \
    --exclude-dir=node_modules --exclude-dir=deps --exclude-dir=_build \
    --exclude-dir=.git --exclude-dir=.omx --exclude-dir=.tmp-bp89 \
    --exclude-dir=.claude --exclude-dir=.artifacts \
    --exclude-dir=.next --exclude-dir=.turbo --exclude-dir=cover \
    "${roots[@]}" 2>/dev/null || true
}

DETAIL_PAGE="$FETCH_ROOT/web/app/(finder)/d/[type]/[slug]/page.tsx"
GET_DOC="$FETCH_ROOT/web/lib/get-document.ts"

# Part 2 reads CODE, not prose. Strip block comments and `//` line comments
# (but not the `//` in a URL, which is always preceded by `:`) before matching:
# appending `// no fields: projection here, by design (D22)` to page.tsx used to
# RED this gate, because the pattern is case-insensitive and unanchored. A gate
# that reds on its own rationale being written down teaches people to delete the
# rationale.
strip_comments() {
  perl -0777 -pe 's{/\*.*?\*/}{ }gs; s{(^|[^:])//[^\n]*}{$1}gm;' "$1"
}

main() {
  # ── Part 1: the per-type preview switch stays dead ──────────────────────────
  [ -f "$DETAIL_PAGE" ] || refuse "web finder detail page not found at $DETAIL_PAGE.
    Part 1 has no corpus to read. If the finder detail route MOVED, move this path
    with it in the same PR — a missing subject is not a clean subject."

  if grep -Eq '\b(docDescription|paperExcerpt)\b' "$DETAIL_PAGE"; then
    fail "part 1 — the per-type preview switch (docDescription/paperExcerpt) is BACK in
    $DETAIL_PAGE. The finder must derive every meta tag from the ONE write-time
    preview manifest via metadataFromPreview — not a paper/post excerpt fork (D17/W3)."
  fi

  if ! grep -q 'metadataFromPreview' "$DETAIL_PAGE"; then
    fail "part 1 — $DETAIL_PAGE no longer calls metadataFromPreview; the finder must
    render its metadata from the shared preview manifest."
  fi
  echo "preview-parity-check part 1: PASS — the finder consumes the ONE manifest (no per-type switch), read from $DETAIL_PAGE."

  # ── Part 2: no ?fields= projection on the web detail fetch (D22) ─────────────
  #
  # WHY THIS PART REFUSES INSTEAD OF SKIPPING A MISSING FILE
  # --------------------------------------------------------
  # This loop used to open `[ -f "$f" ] || continue`. Three runs on the same
  # tree, measured 2026-09-05 on 9fdca8cb8:
  #   web/lib/get-document.ts ABSENT                        -> exit 0, "part 2: PASS"
  #   the same file holding `export const q = "?fields=title";` -> exit 1 (correct)
  #   that SAME violating file renamed to getDocument.ts    -> exit 0, "part 2: PASS"
  # A file going missing — the exact way a Next.js refactor moves a lib — turned
  # the check into a no-op that still printed PASS. An absent corpus is a
  # REFUSAL (exit 2), never a clean reading.
  FETCH_CORPUS_N=0
  for f in "$DETAIL_PAGE" "$GET_DOC"; do
    [ -f "$f" ] || refuse "part 2 (D22) — the fetch corpus is INCOMPLETE: $f is absent.
    Part 2 asserts an ABSENCE (no fields= projection) over exactly two named files;
    with one of them gone the absence is trivially true and the PASS means nothing.
    If the file moved or was renamed, update DETAIL_PAGE/GET_DOC in this script in the
    SAME PR as the move."
    FETCH_CORPUS_N=$((FETCH_CORPUS_N + 1))
    # Any `fields=` / `fields:` / `"fields"` projection on the detail read would
    # strip `preview` (query_controller project_fields). The by-id doc endpoint
    # carries no projection — keep it that way. Comments are stripped first.
    code="$(strip_comments "$f")"
    if grep -Eqi 'fields[[:space:]]*[=:]|["'\'']fields["'\'']' <<<"$code"; then
      fail "part 2 (D22) — a fields= projection appeared in $f. The detail read must NOT
    project content fields, or query_controller strips \`preview\` off the wire and
    every card degrades to the branded default. Fetch the whole doc (by-id endpoint)."
    fi
  done
  echo "preview-parity-check part 2: PASS — no fields= projection across $FETCH_CORPUS_N fetch-corpus files (D22): $DETAIL_PAGE, $GET_DOC."

  # ── Part 3: D10 — NO oEmbed, anywhere, ever ─────────────────────────────────
  #
  # WHY THIS PART CARRIES A POSITIVE CONTROL AND PARTS 1-2 DO NOT
  # -------------------------------------------------------------
  # Parts 1 and 2 read NAMED files and now REFUSE when one is missing. Part 3 is
  # an ABSENCE proof over the whole product tree, and its expected result is ZERO
  # — permanently, because D10 is closed. Zero is also exactly what a wrong cwd, a
  # dropped `--include`, or a renamed source extension produce. The clean tree and
  # the broken scanner print the same line, forever, so on its own this part has
  # no signal that it still works.
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
  # EXIT CODES
  #   0  clean       1  violation
  #   2  REFUSED TO MEASURE — a named fetch file is gone, or the scan root
  #      carries no scannable product source at all

  # --- 3a. census: refuse to certify a tree that holds nothing to scan ---------
  CORPUS="$(scan_sources '.' "$SCAN_ROOT")"
  CORPUS_N="$(printf '%s' "$CORPUS" | grep -c . || true)"
  if [ "$CORPUS_N" -eq 0 ]; then
    refuse "zero scannable files under $SCAN_ROOT.
    Looked for *.{$(echo "$SCANNED_EXTS" | tr ' ' ',')} under: $SCANNED_DIRS
    An empty reading is not a clean reading — 'no oEmbed found' would be true of an empty
    directory too. Run this from a real checkout."
  fi
  # Positive control in the OUTPUT, not just in the assertions: a zero must never
  # be indistinguishable from an empty scan when a human reads the log.
  CORPUS_SAMPLE="$(printf '%s\n' "$CORPUS" | head -3 | tr '\n' ' ')"

  # --- 3b. the check ----------------------------------------------------------
  OEMBED_HITS="$(scan_sources oembed "$SCAN_ROOT")"

  if [ -n "$OEMBED_HITS" ]; then
    fail "part 3 (D10) — oEmbed appeared in the source tree:
  $OEMBED_HITS
    D10 is CLOSED: NO oEmbed, anywhere, ever. Slack prefers oEmbed over og and a
    careless endpoint downgrades every card. Remove it."
  fi
  echo "preview-parity-check part 3: PASS — D10 upheld: zero oEmbed references across $CORPUS_N scanned source files (sample: $CORPUS_SAMPLE)."

  echo "preview-parity-check: PASS — cross-surface preview contract structurally sound."
}

# ── selftest: prove parts 2+3 BITE, and prove they stay SILENT when they should ─
#
# Every arm builds a throwaway tree and re-invokes THIS script against it via
# PREVIEW_PARITY_SCAN_ROOT + PREVIEW_PARITY_FETCH_ROOT, so the assertions drive
# the shipping code path — not a second implementation that could agree while
# both are wrong. Nothing is planted in this repo.
selftest() {
  local tmp bad=0 rc
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  say() { if [ "$2" -eq 0 ]; then echo "  ok    $1"; else echo "  FAIL  $1"; bad=$((bad + 1)); fi; }

  fresh() { # a scannable tree with one file per scanned extension, no oEmbed,
            # plus a VALID two-file fetch corpus for parts 1 and 2.
    # `local x`, NOT `e`: this runs INSIDE the per-extension loop below, and a
    # bare `for e` here would clobber that loop's variable — every plant would
    # land in the last extension and the arms would silently test one.
    local x
    rm -rf "$tmp/t"
    mkdir -p "$tmp/t/web/src" "$tmp/t/web/lib" "$tmp/t/web/app/(finder)/d/[type]/[slug]"
    for x in $SCANNED_EXTS; do printf 'const endpoint = "/og"\n' > "$tmp/t/web/src/probe.$x"; done
    printf 'export const metadata = metadataFromPreview(doc)\n' \
      > "$tmp/t/web/app/(finder)/d/[type]/[slug]/page.tsx"
    printf 'export async function getDocument(id) { return fetch("/v1/docs/" + id) }\n' \
      > "$tmp/t/web/lib/get-document.ts"
  }
  probe() {
    PREVIEW_PARITY_SCAN_ROOT="$tmp/t" PREVIEW_PARITY_FETCH_ROOT="$tmp/t" \
      bash "$SELF" > "$tmp/out" 2>&1
    echo $?
  }
  local n_exts; n_exts="$(printf '%s\n' $SCANNED_EXTS | grep -c .)"

  echo "preview-parity-check --selftest (throwaway trees)"

  # 1. SILENT ARM — a clean corpus must not fire.
  fresh; rc="$(probe)"
  { [ "$rc" -eq 0 ] && grep -q "zero oEmbed references across $n_exts scanned source files" "$tmp/out"; } \
    && say "clean corpus -> PASS (parts 1-3 stay silent, $n_exts files scanned)" 0 \
    || { say "clean corpus -> PASS (got $rc)" 1; sed 's/^/        /' "$tmp/out"; }

  # ── part 2's corpus-vanish arms — the defect this rewrite closed ─────────────

  # 2a. REFUSE ARM — the by-id fetch lib is GONE. Used to print "part 2: PASS".
  fresh; rm -f "$tmp/t/web/lib/get-document.ts"
  rc="$(probe)"
  { [ "$rc" -eq 2 ] && grep -q "fetch corpus is INCOMPLETE" "$tmp/out" && grep -q "get-document.ts" "$tmp/out"; } \
    && say "part 2 fetch lib absent -> REFUSED TO MEASURE (2), names the file" 0 \
    || { say "part 2 fetch lib absent -> REFUSED TO MEASURE (2) (got $rc)" 1; sed 's/^/        /' "$tmp/out"; }

  # 2b. REFUSE ARM — the same file RENAMED, still carrying a real violation.
  #     Used to exit 0: the violation was invisible AND the rename was silent.
  fresh
  mv "$tmp/t/web/lib/get-document.ts" "$tmp/t/web/lib/getDocument.ts"
  printf 'export const q = "?fields=title";\n' >> "$tmp/t/web/lib/getDocument.ts"
  rc="$(probe)"
  { [ "$rc" -eq 2 ] && grep -q "fetch corpus is INCOMPLETE" "$tmp/out"; } \
    && say "part 2 fetch lib renamed (violating) -> REFUSED TO MEASURE (2), never a PASS" 0 \
    || { say "part 2 fetch lib renamed (violating) -> REFUSED TO MEASURE (2) (got $rc)" 1; sed 's/^/        /' "$tmp/out"; }

  # 2c. REFUSE ARM — part 1's subject gone is a refusal too, not a FAILED.
  fresh; rm -f "$tmp/t/web/app/(finder)/d/[type]/[slug]/page.tsx"
  rc="$(probe)"
  { [ "$rc" -eq 2 ]; } \
    && say "part 1 detail page absent -> REFUSED TO MEASURE (2)" 0 \
    || { say "part 1 detail page absent -> REFUSED TO MEASURE (2) (got $rc)" 1; sed 's/^/        /' "$tmp/out"; }

  # 2d. BITE ARM — a REAL projection in the fetch lib still reds.
  fresh; printf 'const url = base + "?fields=title,slug";\n' >> "$tmp/t/web/lib/get-document.ts"
  rc="$(probe)"
  { [ "$rc" -eq 1 ] && grep -q "part 2 (D22)" "$tmp/out"; } \
    && say "real ?fields= projection in the fetch lib -> FAIL (D22)" 0 \
    || { say "real ?fields= projection in the fetch lib -> FAIL (got $rc)" 1; sed 's/^/        /' "$tmp/out"; }

  # 2e. BITE ARM — a projection in the detail page reds too (both corpus files).
  fresh; printf 'const q = { fields: "title" };\n' >> "$tmp/t/web/app/(finder)/d/[type]/[slug]/page.tsx"
  rc="$(probe)"
  { [ "$rc" -eq 1 ] && grep -q "part 2 (D22)" "$tmp/out"; } \
    && say "real fields: projection in the detail page -> FAIL (D22)" 0 \
    || { say "real fields: projection in the detail page -> FAIL (got $rc)" 1; sed 's/^/        /' "$tmp/out"; }

  # 2f. SILENT ARM — the gate must not red on its own rationale written down.
  fresh
  printf '// no fields: projection here, by design (D22)\n' \
    >> "$tmp/t/web/app/(finder)/d/[type]/[slug]/page.tsx"
  printf '/* fields= is forbidden on this read (D22) */\n' >> "$tmp/t/web/lib/get-document.ts"
  rc="$(probe)"
  { [ "$rc" -eq 0 ]; } \
    && say "a COMMENT mentioning fields= -> PASS (part 2 reads code, not prose)" 0 \
    || { say "a COMMENT mentioning fields= -> PASS (got $rc)" 1; sed 's/^/        /' "$tmp/out"; }

  # 2g. SILENT ARM — a `//` inside a URL is not a comment opener.
  fresh; printf 'const base = "https://api.example.com/v1/docs";\n' >> "$tmp/t/web/lib/get-document.ts"
  rc="$(probe)"
  { [ "$rc" -eq 0 ]; } \
    && say "a https:// URL in the fetch lib -> PASS (the // strip is :-aware)" 0 \
    || { say "a https:// URL in the fetch lib -> PASS (got $rc)" 1; sed 's/^/        /' "$tmp/out"; }

  # ── part 3's arms ─────────────────────────────────────────────────────────────

  # 3. BITE ARM, once PER SCANNED EXTENSION — this is the arm that catches a
  #    dropped or renamed --include, which is otherwise indistinguishable from
  #    a clean tree. One plant per extension, because one plant only proves one.
  #    .js/.mjs/.css/.json are here because each of them measurably sailed
  #    through the six-extension corpus on 9fdca8cb8.
  for e in $SCANNED_EXTS; do
    fresh; printf 'fetch("/oembed?url=" + u)\n' > "$tmp/t/web/src/leak.$e"
    rc="$(probe)"
    { [ "$rc" -eq 1 ] && grep -q "leak\.$e" "$tmp/out"; } \
      && say "oEmbed planted in a .$e file -> FAIL, path named" 0 \
      || { say "oEmbed planted in a .$e file -> FAIL, path named (got $rc)" 1; sed 's/^/        /' "$tmp/out"; }
  done

  # 4. BITE ARM — the scan is case-insensitive by design (`oEmbed`, `OEmbed`).
  fresh; printf 'const OEmbedProvider = 1\n' > "$tmp/t/web/src/leak.ts"
  rc="$(probe)"
  { [ "$rc" -eq 1 ] && grep -q "leak\.ts" "$tmp/out"; } \
    && say "OEmbed in mixed case -> FAIL (the scan is -i)" 0 \
    || { say "OEmbed in mixed case -> FAIL (got $rc)" 1; sed 's/^/        /' "$tmp/out"; }

  # 5. BITE ARM, once PER SCANNED PRODUCT DIR — the walk is scoped, so a dir
  #    silently dropping out of SCANNED_DIRS is the same failure shape as a
  #    dropped --include: a whole surface stops being policed and the gate still
  #    prints PASS. One plant per directory.
  for d in $SCANNED_DIRS; do
    fresh; mkdir -p "$tmp/t/$d"; printf 'fetch("/oembed")\n' > "$tmp/t/$d/leak-dir.ts"
    rc="$(probe)"
    { [ "$rc" -eq 1 ] && grep -q "$d/leak-dir\.ts" "$tmp/out"; } \
      && say "oEmbed planted under $d/ -> FAIL, path named" 0 \
      || { say "oEmbed planted under $d/ -> FAIL, path named (got $rc)" 1; sed 's/^/        /' "$tmp/out"; }
  done

  # 6. SILENT ARM — vendored code is not ours to police; --exclude-dir must hold.
  fresh; mkdir -p "$tmp/t/web/node_modules/vendor"; printf 'oEmbed\n' > "$tmp/t/web/node_modules/vendor/dep.ts"
  rc="$(probe)"
  { [ "$rc" -eq 0 ]; } \
    && say "oEmbed under node_modules/ -> PASS (excluded, not our code)" 0 \
    || { say "oEmbed under node_modules/ -> PASS (got $rc)" 1; sed 's/^/        /' "$tmp/out"; }

  # 7. SILENT ARM — the --include list is a real boundary, not decoration.
  fresh; printf 'oEmbed\n' > "$tmp/t/web/src/notes.md"
  rc="$(probe)"
  { [ "$rc" -eq 0 ]; } \
    && say "oEmbed in an unscanned extension (.md) -> PASS" 0 \
    || { say "oEmbed in an unscanned extension (.md) -> PASS (got $rc)" 1; sed 's/^/        /' "$tmp/out"; }

  # 7b. SILENT ARM — the SELF-EXCLUSION. docs/, .github/ and scripts/ are OUT of
  #     the walk on purpose: the ban has to be writable down. This is the arm
  #     that stops a well-meant "widen it to everything" from making the gate
  #     unshippable again.
  fresh; mkdir -p "$tmp/t/docs" "$tmp/t/scripts"
  printf 'D10: NO oEmbed. Anywhere. Ever.\n' > "$tmp/t/docs/merge-gates.ts"
  printf '# the oEmbed ban, documented\n' > "$tmp/t/scripts/some-check.py"
  rc="$(probe)"
  { [ "$rc" -eq 0 ]; } \
    && say "oEmbed in docs/ and scripts/ -> PASS (the ban may document itself)" 0 \
    || { say "oEmbed in docs/ and scripts/ -> PASS (got $rc)" 1; sed 's/^/        /' "$tmp/out"; }

  # 7c. SILENT ARM — the scratch-tree prunes (D18) actually apply. Without this,
  #     the ONLY evidence they work is that the gate got faster, which is not
  #     evidence that it still scans the right set. One arm per pruned directory:
  #     a prune that silently stops applying takes the gate back to 90+ seconds
  #     in a working checkout, and nothing else here would notice.
  for d in .omx .tmp-bp89 .claude .artifacts; do
    fresh; mkdir -p "$tmp/t/web/$d/copy"; printf 'oEmbed\n' > "$tmp/t/web/$d/copy/dup.ts"
    [ -f "$tmp/t/web/$d/copy/dup.ts" ] \
      || { say "PLANT CHECK: the $d plant did not land" 1; continue; }
    rc="$(probe)"
    { [ "$rc" -eq 0 ]; } \
      && say "oEmbed under $d/ -> PASS (scratch copies are pruned, D18)" 0 \
      || { say "oEmbed under $d/ -> PASS (got $rc)" 1; sed 's/^/        /' "$tmp/out"; }
  done

  # 8. REFUSED TO MEASURE — nothing to scan. Silence here would be the defect:
  #    "no oEmbed found" is true of an empty directory, and that is the failure
  #    mode this whole selftest exists to make impossible.
  fresh; rm -rf "$tmp/t/web/src"
  for d in $SCANNED_DIRS; do rm -rf "$tmp/t/$d"; done
  mkdir -p "$tmp/t/web/lib" "$tmp/t/web/app/(finder)/d/[type]/[slug]"
  printf 'export const metadata = metadataFromPreview(doc)\n' \
    > "$tmp/t/web/app/(finder)/d/[type]/[slug]/page.tsx"
  printf 'export async function getDocument(id) {}\n' > "$tmp/t/web/lib/get-document.ts"
  rm -f "$tmp/t/web/lib/get-document.ts" "$tmp/t/web/app/(finder)/d/[type]/[slug]/page.tsx"
  rm -rf "$tmp/t"; mkdir -p "$tmp/t"; printf 'oEmbed\n' > "$tmp/t/readme.md"
  rc="$(probe)"
  { [ "$rc" -eq 2 ] && grep -q "REFUSED TO MEASURE" "$tmp/out"; } \
    && say "no scannable source at all -> REFUSED TO MEASURE (2), never a silent PASS" 0 \
    || { say "no scannable source at all -> REFUSED TO MEASURE (2) (got $rc)" 1; sed 's/^/        /' "$tmp/out"; }

  # 9. ARG DISPATCH — an unknown flag is a refusal (2), not a silent gate run.
  rc=0; bash "$SELF" --no-such-flag > "$tmp/out" 2>&1 || rc=$?
  { [ "$rc" -eq 2 ] && grep -q -- "--no-such-flag" "$tmp/out"; } \
    && say "unknown argument -> exit 2, names the argument" 0 \
    || { say "unknown argument -> exit 2, names the argument (got $rc)" 1; sed 's/^/        /' "$tmp/out"; }

  echo ""
  echo "  scanned-extension arms: $n_exts   product-dir arms: $(printf '%s\n' $SCANNED_DIRS | grep -c .)"
  if [ "$bad" -eq 0 ]; then echo "preview-parity-check --selftest: PASS"; return 0; fi
  echo "preview-parity-check --selftest: FAILED ($bad case(s))"; return 1
}

case "${1:-}" in
  --selftest) selftest ;;
  "")         main ;;
  *)          echo "preview-parity-check: REFUSED TO MEASURE — unknown argument '$1'" >&2
              echo "usage: bash scripts/preview-parity-check.sh [--selftest]" >&2
              exit 2 ;;
esac
