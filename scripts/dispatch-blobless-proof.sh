#!/usr/bin/env bash
# dispatch-blobless-proof.sh [--selftest] [PR ...] — the re-runnable proof behind
# `filter: blob:none` on the four `changes:` dispatcher jobs (task-4a969b6e57d82390).
#
# THE CLAIM. Replacing `fetch-depth: 0` with `filter: blob:none` on the dispatcher
# checkout in .github/workflows/{cloud,compose-smoke,console-harness,required-checks-drift}.yml
# leaves every computed changed-path set IDENTICAL while cutting the checkout cost.
#
# WHY NOT SHALLOW — this is the correctness argument, and it is why the row that
# asked for `fetch-depth: 2` was rewritten rather than built as written. Those
# jobs do NOT use the merge ref. Each deliberately checks out the PR HEAD
# (`ref: github.event.pull_request.head.sha`) and runs a THREE-DOT diff against
# `github.event.pull_request.base.sha`. A three-dot diff resolves the MERGE BASE,
# and a shallow history cannot compute one; the jobs already treat an unresolvable
# base as a hard failure and refuse to emit a verdict. `fetch-depth: 2` works on
# jobs sitting on `refs/pull/N/merge`, where HEAD^1 IS the base — not these jobs.
#
# `filter: blob:none` is NOT shallow. It fetches every commit and every tree and
# omits only blob CONTENTS. `git diff --name-only` reads trees, not blobs, so the
# commit graph, the merge base and the path set are unchanged BY CONSTRUCTION
# rather than by benchmark. This script is the benchmark anyway, because a
# construction argument nobody can re-run is an anecdote.
#
# THE TRAP, PAID FOR ONCE (run 33691239048, three of four dispatchers red on
# `PR base <sha> and HEAD share NO common ancestor`). DEPTH and FILTER are
# ORTHOGONAL axes on actions/checkout. `filter: blob:none` does NOT "govern"
# depth, and dropping `fetch-depth: 0` next to it does not leave a full-depth
# blobless clone — it leaves actions/checkout's DEFAULT depth of 1, and a
# depth-1 clone has no merge base whether or not it is blobless. The dispatcher
# checkouts must carry BOTH lines. Selftest case 4 below is that lesson, frozen.
#
# WHAT IT REFUSES TO CALL A PASS:
#   * any sampled PR whose changed-path set is EMPTY on both sides — two empty
#     sets match, and a comparison of nothing against nothing is vacuous (exit 3);
#   * a "blobless" clone that is not actually a partial clone, e.g. a git old
#     enough or a server unwilling to filter (exit 4) — otherwise the proof
#     compares a full clone against a full clone and passes for the wrong reason;
#   * any checksum mismatch (exit 1).
#
# USAGE
#   bash scripts/dispatch-blobless-proof.sh                 # default 5-PR sample, needs gh + network
#   bash scripts/dispatch-blobless-proof.sh 14874 15372     # explicit PRs
#   bash scripts/dispatch-blobless-proof.sh --selftest      # hermetic: no gh, no network
#
# NOT WIRED INTO CI (yet), and deliberately so: the live mode needs `gh` and a
# network, and wiring only `--selftest` into shell-harnesses.yml is a five-place
# change (paths entry, dispatcher output, roster row, job, and the subset/union
# invariant in shell-harnesses-dispatch.test.sh) against a contended file. It is
# a follow-up. Run it by hand whenever a dispatcher's checkout options change.
#
# MEASURED 2026-09-02, alternating clones of this repo from GitHub:
#   full clone (what fetch-depth: 0 does)   97.0 s   .git 791 MB
#   blob:none partial clone                 26.9 s   .git 188 MB
#   5 PRs (#14874 #15372 #15453 #15234 #15572) — path sets IDENTICAL both sides.
# Re-run this script rather than quoting those figures: the repo grows, and a
# committed number with no command attached is exactly what this change is fixing.

set -uo pipefail

REPO="${REPO:-FRIKKern/barkpark}"
DEFAULT_PRS="14874 15372 15453 15234 15572"

TMPD=""
cleanup() { [ -n "$TMPD" ] && rm -rf "$TMPD"; }
trap cleanup EXIT

die() { printf '%s\n' "$*" >&2; exit "${2:-2}"; }

# sha of the SORTED path set, so the comparison is by checksum and not by eye.
sum() {
  if command -v shasum >/dev/null 2>&1; then shasum | cut -d' ' -f1
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
  else cksum | tr -d ' '; fi
}

# The three-dot changed-path set exactly as the dispatchers compute it:
# core.quotepath=false + -z + --no-renames, NUL-split, sorted.
path_set() {
  local repo="$1" base="$2" head="$3"
  git -C "$repo" -c core.quotepath=false diff -z --name-only --no-renames "${base}...${head}" 2>/dev/null \
    | tr '\0' '\n' | sed '/^$/d' | LC_ALL=C sort
}

# A clone that says "blobless" but is not one makes the whole comparison vacuous.
assert_partial() {
  local repo="$1"
  [ "$(git -C "$repo" config --get remote.origin.promisor 2>/dev/null)" = "true" ] \
    || die "REFUSING: $repo is not a promisor (partial) clone — the comparison would be full-vs-full and pass for the wrong reason. Needs git >= 2.19 and a server that allows filtering." 4
}

# ── the core: compare N (label, base, head) triples across two clones ─────────
# Reads triples on stdin, one per line, TAB-separated. Prints one verdict line
# per triple. Returns 0 pass / 1 mismatch / 3 vacuous.
compare_triples() {
  local full="$1" bn="$2"
  local fail=0 vacuous=0 total=0
  local label base head sf sb n cf cb
  while IFS=$'\t' read -r label base head; do
    [ -n "${label:-}" ] || continue
    total=$((total + 1))
    sf="$(path_set "$full" "$base" "$head")"
    sb="$(path_set "$bn"   "$base" "$head")"
    # Fault injection, selftest only: proves the detector is not blind. A
    # comparator that never reds is indistinguishable from one that always passes.
    if [ "${PROOF_INJECT_MISMATCH:-}" = "1" ]; then sb="${sb}
zz/injected-divergence"; fi
    n=$(printf '%s' "$sf" | grep -c . || true); n=${n:-0}
    if [ "$n" -eq 0 ]; then
      printf '%-10s VACUOUS — empty set on both sides, proves nothing\n' "$label"
      vacuous=$((vacuous + 1)); continue
    fi
    cf="$(printf '%s\n' "$sf" | sum)"
    cb="$(printf '%s\n' "$sb" | sum)"
    if [ "$cf" = "$cb" ]; then
      printf '%-10s files=%-3s IDENTICAL  %s\n' "$label" "$n" "${cf:0:12}"
    else
      printf '%-10s files=%-3s DIFFERS    full=%s blobless=%s\n' "$label" "$n" "${cf:0:12}" "${cb:0:12}"
      fail=$((fail + 1))
    fi
  done
  echo "----"
  if [ "$vacuous" -gt 0 ]; then
    echo "REFUSING: $vacuous of $total samples produced an EMPTY set on both sides. Two empty sets match, so this run proves nothing. Sample PRs that change files."
    return 3
  fi
  if [ "$fail" -gt 0 ]; then echo "FAIL: $fail mismatch(es) of $total."; return 1; fi
  [ "$total" -gt 0 ] || { echo "REFUSING: zero samples compared."; return 3; }
  echo "PASS: $total samples, changed-path sets identical in both clone shapes."
  return 0
}

# ── live mode ────────────────────────────────────────────────────────────────
live() {
  local prs="$1"
  command -v gh >/dev/null 2>&1 || die "gh is not on PATH — it is how this script reads each PR's head/base sha."
  local tmp; tmp="$(mktemp -d)"; TMPD="$tmp"

  echo "== cloning $REPO both ways into $tmp"
  local t0 t_full t_bn
  t0=$SECONDS; git clone --quiet "https://github.com/$REPO.git" "$tmp/full" || die "full clone failed"
  t_full=$((SECONDS - t0))
  t0=$SECONDS; git clone --quiet --filter=blob:none "https://github.com/$REPO.git" "$tmp/bn" || die "blobless clone failed"
  t_bn=$((SECONDS - t0))
  assert_partial "$tmp/bn"
  printf 'full clone   %4ds  .git %s\n' "$t_full" "$(du -sh "$tmp/full/.git" | cut -f1)"
  printf 'blob:none    %4ds  .git %s\n' "$t_bn"   "$(du -sh "$tmp/bn/.git"   | cut -f1)"
  echo

  local triples="" p h b
  for p in $prs; do
    h="$(gh api "repos/$REPO/pulls/$p" -q .head.sha 2>/dev/null)"
    b="$(gh api "repos/$REPO/pulls/$p" -q .base.sha 2>/dev/null)"
    if [ -z "$h" ] || [ -z "$b" ]; then echo "#$p  SKIP (could not read head/base)"; continue; fi
    # A PR head can be gone from the default refspec (force-push, deleted fork
    # branch). Fetch both shas explicitly into BOTH clones or the sample is a lie.
    git -C "$tmp/full" fetch --no-tags -q origin "$h" "$b" 2>/dev/null
    git -C "$tmp/bn"   fetch --no-tags -q origin "$h" "$b" 2>/dev/null
    if ! git -C "$tmp/full" cat-file -e "${h}^{commit}" 2>/dev/null \
      || ! git -C "$tmp/full" cat-file -e "${b}^{commit}" 2>/dev/null; then
      echo "#$p  SKIP (head or base sha unreachable — force-pushed or deleted branch)"; continue
    fi
    triples="${triples}#${p}"$'\t'"${b}"$'\t'"${h}"$'\n'
  done
  [ -n "$triples" ] || die "REFUSING: no sampled PR yielded a usable head/base pair." 3
  printf '%s' "$triples" | compare_triples "$tmp/full" "$tmp/bn"
  local rc=$?
  [ $rc -eq 0 ] && printf 'clone cost: blobless %ss vs full %ss (this run, %s).\n' "$t_bn" "$t_full" "$(date +%Y-%m-%d)"
  return $rc
}

# ── selftest: hermetic. No gh, no network, no GitHub. ────────────────────────
# Builds a synthetic repo with a real merge-base topology, clones it BOTH ways
# over file:// (partial clone needs uploadpack.allowFilter on the serving side,
# which is why it is set on the source), and asserts three things:
#   1. a real changed-path set is IDENTICAL across both clone shapes  -> exit 0
#   2. an empty-on-both-sides sample is REFUSED as vacuous            -> exit 3
#   3. an injected divergence is CAUGHT                               -> exit 1
#   4. a DEPTH-1 blobless clone still has NO merge base — depth and filter are
#      orthogonal, which is the mistake this change made once and paid for.
# Case 3 is what keeps case 1 honest: a comparator that cannot red is not a proof.
selftest() {
  local tmp; tmp="$(mktemp -d)"; TMPD="$tmp"
  local src="$tmp/src"
  g() { git -C "$src" -c user.email=proof@example.com -c user.name=proof -c commit.gpgsign=false "$@"; }

  git init -q "$src"
  # blobs big enough that a partial clone is a distinguishable shape
  mkdir -p "$src/api/lib" "$src/docs"
  for f in api/lib/a.ex docs/b.md; do head -c 20000 /dev/urandom | base64 > "$src/$f"; done
  g add -A >/dev/null; g commit -qm root
  local base; base="$(g rev-parse HEAD)"
  # main advances after the PR branched — this is the whole point of three-dot
  g checkout -q -b feature
  head -c 20000 /dev/urandom | base64 > "$src/api/lib/c.ex"
  printf 'changed\n' >> "$src/docs/b.md"
  g add -A >/dev/null; g commit -qm "feature: two files"
  local head_sha; head_sha="$(g rev-parse HEAD)"
  g checkout -q master 2>/dev/null || g checkout -q main
  head -c 20000 /dev/urandom | base64 > "$src/unrelated.txt"
  g add -A >/dev/null; g commit -qm "main advances"
  g config uploadpack.allowFilter true
  g config uploadpack.allowAnySHA1InWant true

  git clone -q "file://$src" "$tmp/full"                    || die "selftest: full clone failed"
  git clone -q --filter=blob:none "file://$src" "$tmp/bn"   || die "selftest: blobless clone failed"
  for d in full bn; do git -C "$tmp/$d" fetch --no-tags -q origin "$head_sha" "$base" 2>/dev/null; done
  assert_partial "$tmp/bn"

  local rc pass=0 failn=0
  check() { # name expected_rc
    if [ "$1" -eq "$2" ]; then echo "  ok   $3 (exit $1)"; pass=$((pass+1));
    else echo "  FAIL $3 (exit $1, expected $2)"; failn=$((failn+1)); fi
  }

  echo "selftest 1/4 — identical sets across clone shapes (expect PASS, exit 0)"
  printf 'case1\t%s\t%s\n' "$base" "$head_sha" | compare_triples "$tmp/full" "$tmp/bn" | sed 's/^/    /'
  printf 'case1\t%s\t%s\n' "$base" "$head_sha" | compare_triples "$tmp/full" "$tmp/bn" >/dev/null; rc=$?
  check "$rc" 0 "identical path sets"

  echo "selftest 2/4 — empty-on-both-sides is REFUSED as vacuous (expect exit 3)"
  printf 'case2\t%s\t%s\n' "$head_sha" "$head_sha" | compare_triples "$tmp/full" "$tmp/bn" >/dev/null; rc=$?
  check "$rc" 3 "vacuity guard fires on an empty set"

  echo "selftest 3/4 — an injected divergence is CAUGHT (expect exit 1)"
  printf 'case3\t%s\t%s\n' "$base" "$head_sha" | PROOF_INJECT_MISMATCH=1 compare_triples "$tmp/full" "$tmp/bn" >/dev/null; rc=$?
  check "$rc" 1 "mismatch detector is not blind"

  # CASE 4 — DEPTH AND FILTER ARE ORTHOGONAL, and this is the one that cost a
  # red CI run. A blobless clone at DEPTH 1 is still shallow, and shallow has no
  # merge base. This asserts the failure exists, so nobody "simplifies" the
  # dispatchers by dropping `fetch-depth: 0` on the theory that the filter
  # covers it.
  echo "selftest 4/4 — a DEPTH-1 blobless clone has NO merge base (the trap, frozen)"
  git clone -q --depth 1 --filter=blob:none "file://$src" "$tmp/shallow" 2>/dev/null
  git -C "$tmp/shallow" fetch --no-tags -q --depth 1 origin "$head_sha" "$base" 2>/dev/null
  if git -C "$tmp/shallow" merge-base "$base" "$head_sha" >/dev/null 2>&1; then rc=1; else rc=0; fi
  check "$rc" 0 "depth 1 + blob:none still cannot resolve a merge base"

  echo "----"
  if [ "$failn" -gt 0 ]; then echo "SELFTEST FAILED: $failn of $((pass+failn)) cases."; return 1; fi
  echo "SELFTEST PASSED: $pass/$pass cases (identical / vacuity refusal / mismatch caught / depth-vs-filter)."
  return 0
}

case "${1:-}" in
  --selftest|--self-test) selftest; exit $? ;;
  -h|--help) sed -n '2,45p' "$0"; exit 0 ;;
esac
live "${*:-$DEFAULT_PRS}"
exit $?
