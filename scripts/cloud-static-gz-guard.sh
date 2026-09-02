#!/usr/bin/env bash
#
# cloud-static-gz-guard.sh — keeps the cloud console's pre-compressed static
# siblings UNCOMMITTED, and keeps the pair that makes them safe wired together.
#
# WHY THIS EXISTS (Cloud Console Hardening wave 11, cch-w11-s2-cloud-static-gzip)
# -----------------------------------------------------------------------------
# The console's cold boot shipped 1,164,296 uncompressed bytes (app.js 965,342 +
# app.css 198,954) because the edge in front of it compresses nothing — measured
# on the live host, no `content-encoding` and no `vary` on either response. The
# fix is two lines: `gzip: true` on the `at: "/"` Plug.Static, and one
# `RUN gzip -9 -k priv/static/app.js priv/static/app.css` in cloud/Dockerfile.
# 338,917 bytes on the wire, −70.9%.
#
# That fix introduces exactly ONE new failure mode, and it is a silent one: a
# .gz that no longer matches its source. Plug.Static derives the etag from the
# file it SERVES, never from the source (plug 1.20.1 static.ex: `etag_for_path/3`
# at :404-413 hashes the `file_info` that `file_encoding/4` at :416-437 got by
# stat'ing `path <> ext`). So a stale sibling and a fresh source answer the SAME
# url with different bytes and different etags in the same second, and the
# router's `cache-control: no-cache` buys nothing — revalidation is answered 304
# off the stale etag. There is no sound runtime check for this. A hard refresh
# does not save you either; it sends `accept-encoding: gzip` too.
#
# So the design does not DETECT staleness, it makes it unrepresentable: the
# Dockerfile builds the sibling from the bytes `COPY priv priv` just laid down,
# in the same build, and Docker keys that RUN layer on the COPY above it. Source
# and sibling are born together or not at all.
#
# THE ONE HOLE IN THAT ARGUMENT is a .gz that arrives from somewhere other than
# the build — i.e. one that is COMMITTED. A tracked app.js.gz would ship
# whatever bytes it held on the day it was added, in preference to a fresh
# source, forever, with nothing anywhere able to notice. That hole was wide open
# before this slice: `git check-ignore cloud/priv/static/app.css.gz` returned
# rc 1, so a stray local `gzip -k` was one `git add .` from production.
# cloud/.gitignore's `*.gz` closes the accident; this guard closes the
# `git add -f` and the ignore-rule-deleted paths, which .gitignore cannot.
#
# It also asserts the two halves of the fix are still BOTH there, because either
# one alone is a quiet regression rather than a loud one: `gzip: true` with no
# Dockerfile RUN silently serves the uncompressed file (Plug.Static falls back),
# and the RUN with no `gzip: true` silently ships two dead files in the image.
#
# NOTHING HERE PINS A DIGEST, deliberately. cloud/priv/static/app.js is a built
# SPA bundle that other open work rewrites wholesale (PR #6028 carries +96/-1 on
# it today). A pinned content hash would go red the instant such a PR merged —
# a permanently-correct red on protected main, which is exactly the failure this
# epic exists to remove. Every check below RECOMPUTES from the tree.
#
# USAGE
#   cloud-static-gz-guard.sh              # the tripwire (CI + the local gate)
#   cloud-static-gz-guard.sh --selftest   # mutation-prove all four checks red
#
# The selftest is the answer to "a guard that cannot fail proves nothing": it
# builds a throwaway git repo from the REAL files, asserts a clean pass, then
# breaks each invariant in turn and asserts the guard reds on each.

set -euo pipefail

# CLOUD_GZ_GUARD_ROOT retargets every read at another checkout; the selftest is
# its only caller. It cannot weaken a real run — pointing it at this repo gives
# the identical verdict.
REPO_ROOT="${CLOUD_GZ_GUARD_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"

STATIC_DIR='cloud/priv/static'
ROUTER='cloud/lib/barkpark_cloud/web/router.ex'
DOCKERFILE='cloud/Dockerfile'
# The files the Dockerfile must name explicitly. `gzip priv/static/*` would also
# compress __app.test.mjs / __css_check.mjs / __fixtures__, none of which are in
# the Plug.Static `only:` allowlist — pure image weight.
#
# index.html is here because it is the SPA SHELL: it is the FIRST request of
# every cold boot, and compressing the assets it pulls while shipping the shell
# itself uncompressed is the residual half of the same lie (re-measured off the
# tree: 33,912 -> 8,869, -73.8%). styleguide.html joined under
# cch-cloud-static-gzip-html — same allowlist, same `gzip: true`, 52,722 ->
# 12,097 (-77.1%) — on its own row rather than under the shell's cold-boot
# urgency, because only a developer opening the styleguide ever pays it.
# favicon.ico and button.svg are too small for the sibling to pay for itself;
# robots.txt (~100 bytes) likewise.
#
# This list and the Dockerfile RUN are ONE change: check 3 below reds if the
# RUN stops naming any entry here, so growing this list alone is a red, and
# growing the RUN alone leaves the new file unguarded. Move both or neither.
GZ_ASSETS='app.js
app.css
index.html
styleguide.html'

fail=0

err() {
  echo "::error::cloud-static-gz-guard: $1" >&2
  fail=$((fail + 1))
}

need_file() {
  if [ ! -f "$REPO_ROOT/$1" ]; then
    err "expected file is missing: $1"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# check 1 — NO .gz IS TRACKED under cloud/priv/static
# ---------------------------------------------------------------------------
# The load-bearing one. `git ls-files` is correct here (unlike the path-escape
# ratchets, which must see untracked files): the thing being forbidden is
# precisely the state of BEING TRACKED. An untracked app.js.gz on a developer's
# disk is fine and expected — that is what the build produces.
check_untracked() {
  local tracked
  tracked="$(git -C "$REPO_ROOT" ls-files "$STATIC_DIR" | grep '\.gz$' || true)"
  if [ -n "$tracked" ]; then
    err "COMMITTED .gz under $STATIC_DIR — these must be built, never tracked:"
    printf '%s\n' "$tracked" | sed 's/^/    /' >&2
    cat >&2 <<'MSG'
    A tracked .gz is served by Plug.Static in preference to the fresh source and
    carries no link back to it, so it ships stale bytes with a matching etag and
    nothing can detect it. Remove it (`git rm --cached <path>`); cloud/Dockerfile
    builds it inside the image from the source it just copied.
MSG
    return
  fi
  echo "OK: no .gz tracked under $STATIC_DIR"
}

# ---------------------------------------------------------------------------
# check 2 — cloud/.gitignore IGNORES the sibling paths
# ---------------------------------------------------------------------------
# Check 1 catches a .gz that already landed. This catches the deletion of the
# rule that stops the next one from landing by accident — a `git add .` in
# cloud/ after a local `mix release` dry-run.
check_ignored() {
  local a
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    # A TRACKED path is never reported as ignored, however good the rule is —
    # so without this, check 1's committed-.gz failure would drag a second,
    # false "restore the *.gz entry" error along with it and send the reader at
    # a .gitignore that is perfectly fine. Check 1 owns that case; skip it here.
    if git -C "$REPO_ROOT" ls-files --error-unmatch "$STATIC_DIR/$a.gz" >/dev/null 2>&1; then
      continue
    fi
    if ! git -C "$REPO_ROOT" check-ignore -q "$STATIC_DIR/$a.gz"; then
      err "nothing ignores $STATIC_DIR/$a.gz — restore the \`*.gz\` entry in cloud/.gitignore"
    fi
  done <<EOF
$GZ_ASSETS
EOF
  [ "$fail" -eq 0 ] && echo "OK: $STATIC_DIR/*.gz is git-ignored"
  return 0
}

# ---------------------------------------------------------------------------
# check 3 — the Dockerfile still BUILDS the siblings, in the right place
# ---------------------------------------------------------------------------
# Position is the whole safety argument, not a style preference: the RUN must
# come AFTER `COPY priv priv` (so it compresses the bytes of this build, which
# is what makes staleness impossible) and BEFORE `RUN mix release` (so the
# siblings are inside the release tree — mix symlinks
# _build/<env>/lib/<app>/priv at the source priv, so files created in priv after
# compile are carried).
check_dockerfile() {
  need_file "$DOCKERFILE" || return 0
  local f="$REPO_ROOT/$DOCKERFILE" gz_line copy_line rel_line a
  gz_line="$(grep -n '^RUN gzip .*priv/static/' "$f" | head -1 | cut -d: -f1 || true)"
  copy_line="$(grep -n '^COPY priv priv' "$f" | head -1 | cut -d: -f1 || true)"
  rel_line="$(grep -n '^RUN mix release' "$f" | head -1 | cut -d: -f1 || true)"

  if [ -z "$gz_line" ]; then
    err "$DOCKERFILE no longer carries a \`RUN gzip … priv/static/…\` step."
    echo "    Without it the router's \`gzip: true\` silently serves the full" >&2
    echo "    1,164,296 uncompressed bytes — Plug.Static just falls back." >&2
    return
  fi
  if [ -z "$copy_line" ] || [ -z "$rel_line" ]; then
    err "$DOCKERFILE is missing \`COPY priv priv\` or \`RUN mix release\` — cannot verify gzip placement"
    return
  fi
  if [ "$gz_line" -lt "$copy_line" ] || [ "$gz_line" -gt "$rel_line" ]; then
    err "the gzip step (line $gz_line) must sit between \`COPY priv priv\` ($copy_line) and \`RUN mix release\` ($rel_line)"
    echo "    Before the COPY it compresses the WRONG bytes; after the release it" >&2
    echo "    never reaches the image at all." >&2
    return
  fi
  # Each asset named explicitly — a bare glob would compress the test harness.
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    # Whole-WORD match via awk, not a regex: `\b` is not portable across BSD
    # and GNU grep, and `.` in "app.js" would otherwise match any character —
    # so `priv/static/appXjs` would sail through a naive grep.
    if ! sed -n "${gz_line}p" "$f" |
      awk -v want="priv/static/$a" '{ for (i = 1; i <= NF; i++) if ($i == want) { found = 1 } } END { exit found ? 0 : 1 }'; then
      err "the gzip step does not name priv/static/$a explicitly"
    fi
  done <<EOF
$GZ_ASSETS
EOF
  echo "OK: $DOCKERFILE builds the siblings at line $gz_line (between $copy_line and $rel_line)"
}

# ---------------------------------------------------------------------------
# check 4 — the router still SERVES them
# ---------------------------------------------------------------------------
# Anchored on the `only:` allowlist rather than a line number: PR #6028 edits
# this file above and below the plug, and a rebase reshuffles every line under
# the diff. Anchoring on content is what keeps this from going red for a reason
# that has nothing to do with gzip.
check_router() {
  need_file "$ROUTER" || return 0
  local f="$REPO_ROOT/$ROUTER" only_line window
  only_line="$(grep -n 'only: ~w(index.html' "$f" | head -1 | cut -d: -f1 || true)"
  if [ -z "$only_line" ]; then
    err "cannot find the \`at: \"/\"\` Plug.Static allowlist in $ROUTER (looked for \`only: ~w(index.html\`)"
    return
  fi
  window="$(sed -n "$((only_line > 6 ? only_line - 6 : 1)),$((only_line + 6))p" "$f")"
  if ! printf '%s\n' "$window" | grep -q 'gzip: true'; then
    err "the \`at: \"/\"\` Plug.Static in $ROUTER lost \`gzip: true\` (allowlist at line $only_line)"
    echo "    The .gz siblings are still built into the image but never served:" >&2
    echo "    every cold boot ships 1,164,296 bytes again, silently." >&2
    return
  fi
  echo "OK: $ROUTER serves the siblings (\`gzip: true\` near line $only_line)"
}

# ---------------------------------------------------------------------------
# --selftest — mutation-prove every check above can actually go red
# ---------------------------------------------------------------------------
# GLOBAL, not `local`: the EXIT trap below fires after the function's frame is
# gone, so a `local tmp` leaves it unbound and `set -u` turns cleanup into a
# spurious rc=1 on an otherwise all-green selftest.
SELFTEST_TMP=''

selftest() {
  local real rc passed=0 failed=0 tmp
  real="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
  SELFTEST_TMP="$(mktemp -d)"
  tmp="$SELFTEST_TMP"
  trap 'rm -rf "$SELFTEST_TMP"' EXIT

  # A throwaway repo built from the REAL files, so the selftest is testing the
  # shipped invariants and not a hand-written stand-in that could drift.
  mkdir -p "$tmp/cloud/lib/barkpark_cloud/web" "$tmp/cloud/priv/static"
  cp "$real/$DOCKERFILE" "$tmp/$DOCKERFILE"
  cp "$real/$ROUTER" "$tmp/$ROUTER"
  cp "$real/cloud/.gitignore" "$tmp/cloud/.gitignore"
  cp "$real/$STATIC_DIR/app.js" "$tmp/$STATIC_DIR/app.js"
  cp "$real/$STATIC_DIR/app.css" "$tmp/$STATIC_DIR/app.css"
  git -C "$tmp" init -q
  git -C "$tmp" add -A
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -qm base

  run_case() {
    local name="$1" want="$2"
    set +e
    CLOUD_GZ_GUARD_ROOT="$tmp" bash "${BASH_SOURCE[0]}" >/dev/null 2>&1
    rc=$?
    set -e
    if [ "$rc" -eq "$want" ]; then
      echo "  PASS  $name (rc=$rc)"
      passed=$((passed + 1))
    else
      echo "  FAIL  $name (rc=$rc, want $want)"
      failed=$((failed + 1))
    fi
  }

  echo "cloud-static-gz-guard --selftest: fixture repo at $tmp"
  run_case "clean tree passes" 0

  # 1. a COMMITTED .gz — the hole .gitignore cannot close, via `git add -f`.
  gzip -9 -kf "$tmp/$STATIC_DIR/app.js"
  git -C "$tmp" add -f "$STATIC_DIR/app.js.gz"
  run_case "committed app.js.gz reds" 1
  git -C "$tmp" rm -q --cached "$STATIC_DIR/app.js.gz"
  rm -f "$tmp/$STATIC_DIR/app.js.gz"
  run_case "…and passes again once untracked" 0

  # 2. the ignore rule deleted.
  cp "$tmp/cloud/.gitignore" "$tmp/.gitignore.bak"
  grep -v '^\*\.gz$' "$tmp/.gitignore.bak" > "$tmp/cloud/.gitignore"
  run_case "deleted \`*.gz\` ignore rule reds" 1
  cp "$tmp/.gitignore.bak" "$tmp/cloud/.gitignore"

  # 3a. the Dockerfile RUN deleted.
  cp "$tmp/$DOCKERFILE" "$tmp/Dockerfile.bak"
  grep -v '^RUN gzip ' "$tmp/Dockerfile.bak" > "$tmp/$DOCKERFILE"
  run_case "deleted Dockerfile gzip step reds" 1
  # 3b/3c specimens are DERIVED from the real RUN line, never re-typed. A typed
  # literal silently stops matching the moment GZ_ASSETS gains a file (wave 11
  # review added index.html), and a sed that matches nothing produces an
  # UNMUTATED copy that the guard then passes — a green that means "the mutation
  # did not apply", which is the exact vacuous shape this guard exists to catch.
  local real_run
  real_run="$(grep -m1 '^RUN gzip .*priv/static/' "$tmp/Dockerfile.bak")"
  [ -n "$real_run" ] || { echo "  FAIL  selftest cannot find the real RUN line to mutate" >&2; failed=$((failed + 1)); }
  # 3b. the RUN moved ABOVE `COPY priv priv` — compresses the wrong bytes.
  {
    printf '%s\n' "$real_run"
    cat "$tmp/Dockerfile.bak"
  } > "$tmp/$DOCKERFILE"
  run_case "gzip step above \`COPY priv priv\` reds" 1
  # 3c. a bare glob instead of the explicitly named files.
  awk -v real="$real_run" '$0 == real { print "RUN gzip -9 -k priv/static/*"; next } { print }' \
    "$tmp/Dockerfile.bak" > "$tmp/$DOCKERFILE"
  if grep -q '^RUN gzip -9 -k priv/static/\*$' "$tmp/$DOCKERFILE"; then
    passed=$((passed + 1)); echo "  PASS  the glob mutation applies (the specimen really is globbed)"
  else
    failed=$((failed + 1)); echo "  FAIL  the glob mutation did not apply — the case below would be vacuous"
  fi
  run_case "\`gzip priv/static/*\` glob reds" 1
  cp "$tmp/Dockerfile.bak" "$tmp/$DOCKERFILE"

  # 4. `gzip: true` removed from the router.
  cp "$tmp/$ROUTER" "$tmp/router.bak"
  grep -v '^    gzip: true,$' "$tmp/router.bak" > "$tmp/$ROUTER"
  run_case "router losing \`gzip: true\` reds" 1
  cp "$tmp/router.bak" "$tmp/$ROUTER"

  run_case "restored tree passes" 0

  echo "cloud-static-gz-guard --selftest: $passed passed, $failed failed"
  [ "$failed" -eq 0 ]
}

case "${1:---check}" in
  --selftest)
    selftest
    exit $?
    ;;
  --check) ;;
  *)
    echo "cloud-static-gz-guard: unknown argument '$1'" >&2
    echo "usage: $0 [--check|--selftest]" >&2
    exit 2
    ;;
esac

echo "cloud-static-gz-guard: scanning \$REPO_ROOT=$REPO_ROOT"
check_untracked
check_ignored
check_dockerfile
check_router

if [ "$fail" -gt 0 ]; then
  echo "cloud-static-gz-guard: $fail problem(s)" >&2
  exit 1
fi

echo "cloud-static-gz-guard: OK — siblings are built, served, and never committed."
