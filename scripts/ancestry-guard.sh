#!/usr/bin/env bash
# usage: ancestry-guard.sh <ancestor-sha> <descendant-ref> [--repo <dir>]
#        ancestry-guard.sh --selftest
#
# REFUSES to let a local `git merge-base --is-ancestor` decide anything when this
# checkout cannot see far enough back to answer honestly.
#
# WHY. `git merge-base --is-ancestor` folds three different worlds into rc=1:
#   * "the descendant genuinely does not contain the ancestor"  (an honest NO)
#   * "the walk was truncated by a graft before it got there"   (I CANNOT SEE)
# and only a MISSING OBJECT differs (rc=128). Every caller that reads rc=1 as a
# product claim is therefore unsound in a truncated checkout. Measured on this
# repo: three merge commits GitHub reports `ahead` returned rc=1 in a grafted
# clone (charter bp-cloud-console-hardening D724, 2026-08-09).
#
# WHY NOT `--is-shallow-repository` ALONE. It is REPOSITORY-WIDE. One off-HEAD
# `--depth` fetch sets it for a checkout whose HEAD history is complete, and a
# guard keyed on the bare flag stamps HISTORY-UNAVAILABLE on machines that can
# answer perfectly well — charter bp-cloud-console-hardening D328 refused exactly
# that shape, and the same charter's D724 (which asked for the bare-flag guard)
# is the ruling this script declines to implement literally. Measured 2026-09-09
# on /Volumes/SATECHI/github/barkpark: `--is-shallow-repository` = false today
# while D724 recorded true on 2026-08-09 — the flag is not even stable over time
# for one checkout, so it is a trigger, never a verdict.
#
# THE FOUR LEGS, probed SEPARATELY, never folding rcs across probes (D328):
#   1 REF     `rev-parse --verify --quiet <descendant>` rc!=0  => HISTORY-UNAVAILABLE
#   2 OBJECT  `cat-file -e <sha>^{commit}` rc!=0               => HISTORY-UNAVAILABLE
#   3 WALK    store-shallow AND some graft is an ancestor of
#             the descendant's own history                     => HISTORY-UNAVAILABLE
#             (an unreadable graft list / unanswerable git = fail CLOSED)
#   4 ANSWER  only with 1-3 clean may `--is-ancestor` speak.
# Leg 3 is ported from scripts/pds-record-parity.sh walk_truncation() (which asks
# it of HEAD); here it is asked of the descendant ref actually under test.
#
# EXIT CODES
#   0  CONTAINED        the descendant contains the ancestor (rc 0, legs clean)
#   1  NOT-CONTAINED    an HONEST no (rc 1, legs clean)
#   2  HISTORY-UNAVAILABLE   the guard REFUSES; no ancestry claim may be made
#   3  usage error
# A caller must treat 2 as "unknown", never as 1. Refusing is the whole point.
set -u

GUARD_REASON=""
GUARD_GRAFT=""

_ag_git() { git -C "$AG_REPO" "$@"; }

# walk_truncation_of <ref> -> echoes complete|truncated|unknown, sets GUARD_REASON/GUARD_GRAFT
ag_walk_truncation_of() {
  local ref="$1" store common grafts g rc
  GUARD_REASON=""; GUARD_GRAFT=""

  store="$(_ag_git rev-parse --is-shallow-repository 2>/dev/null)" || store=""
  case "$store" in
    false) printf 'complete\n'; return 0 ;;
    true)  : ;;
    *)     GUARD_REASON="\`git rev-parse --is-shallow-repository\` answered '${store:-<nothing>}', which is neither true nor false"
           printf 'unknown\n'; return 0 ;;
  esac

  common="$(_ag_git rev-parse --git-common-dir 2>/dev/null)" || common=""
  if [ -z "$common" ]; then
    GUARD_REASON="the store is shallow but \`git rev-parse --git-common-dir\` answered nothing, so the graft list cannot be located"
    printf 'unknown\n'; return 0
  fi
  case "$common" in /*) : ;; *) common="$AG_REPO/${common#./}" ;; esac

  grafts="${common%/}/shallow"
  if [ ! -r "$grafts" ]; then
    GUARD_REASON="the store is shallow but the graft list ${grafts} is missing or unreadable, so no graft can be tested against ${ref}"
    printf 'unknown\n'; return 0
  fi

  while read -r g || [ -n "$g" ]; do
    case "$g" in ''|\#*) continue ;; esac
    _ag_git merge-base --is-ancestor "$g" "$ref" >/dev/null 2>&1
    rc=$?
    case "$rc" in
      0) GUARD_GRAFT="$g"
         GUARD_REASON="graft ${g} lies on ${ref}'s own history, so the walk stops before it reaches the ancestor under test"
         printf 'truncated\n'; return 0 ;;
      1) : ;;
      *) GUARD_GRAFT="$g"
         GUARD_REASON="graft ${g} could not be tested against ${ref} (git merge-base --is-ancestor exit ${rc})"
         printf 'unknown\n'; return 0 ;;
    esac
  done < "$grafts"

  GUARD_REASON="store-shallow, but no graft in ${grafts} lies on ${ref}'s history"
  printf 'complete\n'; return 0
}

ag_check() { # ag_check <ancestor> <descendant>
  local anc="$1" desc="$2" walk rc

  # LEG 1 — REF. A missing ref makes `rev-parse` rc 1, the same code an honest
  # "no" would carry downstream. Probed on its own so it can never be folded in.
  if ! _ag_git rev-parse --verify --quiet "${desc}^{commit}" >/dev/null 2>&1; then
    printf 'HISTORY-UNAVAILABLE ancestry of %s in %s is UNDECIDABLE: the descendant ref/commit "%s" does not resolve in %s\n' \
      "$anc" "$desc" "$desc" "$AG_REPO"
    return 2
  fi
  # LEG 2 — OBJECT.
  if ! _ag_git cat-file -e "${anc}^{commit}" 2>/dev/null; then
    printf 'HISTORY-UNAVAILABLE ancestry of %s in %s is UNDECIDABLE: the ancestor object %s is not in this object database\n' \
      "$anc" "$desc" "$anc"
    return 2
  fi
  # LEG 3 — WALK TRUNCATION. Fail CLOSED on `unknown`.
  walk="$(ag_walk_truncation_of "$desc")"
  if [ "$walk" != "complete" ]; then
    printf 'HISTORY-UNAVAILABLE ancestry of %s in %s is UNDECIDABLE: walk is %s — %s\n' \
      "$anc" "$desc" "$walk" "$GUARD_REASON"
    return 2
  fi
  # LEG 4 — only now may the ancestry test speak.
  _ag_git merge-base --is-ancestor "$anc" "$desc" >/dev/null 2>&1
  rc=$?
  case "$rc" in
    0) printf 'CONTAINED %s is an ancestor of %s (walk complete: %s)\n' "$anc" "$desc" "${GUARD_REASON:-not shallow}"; return 0 ;;
    1) printf 'NOT-CONTAINED %s is NOT an ancestor of %s, and this checkout CAN see far enough to say so (walk complete: %s)\n' "$anc" "$desc" "${GUARD_REASON:-not shallow}"; return 1 ;;
    *) printf 'HISTORY-UNAVAILABLE ancestry of %s in %s is UNDECIDABLE: git merge-base --is-ancestor exited %s with all three pre-legs clean\n' "$anc" "$desc" "$rc"; return 2 ;;
  esac
}

# ── selftest ──────────────────────────────────────────────────────────────────
# Builds REAL repositories (no stubbing of git) in four shapes and asserts the
# verdict of each. The truncated arms are the fail-before proof: in each of them
# a bare `merge-base --is-ancestor` returns rc=1 — indistinguishable from an
# honest NO — and the guard returns 2 instead.
ag_selftest() {
  local tmp pass=0 fail=0
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/ancestry-guard-selftest.XXXXXX")" || { echo "CANNOT READ: mktemp failed" >&2; return 2; }
  trap 'rm -rf -- "$tmp"' RETURN

  ok() { pass=$((pass+1)); echo "ok    $1"; }
  no() { fail=$((fail+1)); echo "FAIL  $1"; }

  # A source repo with 6 linear commits.
  local src="$tmp/src"
  git init -q "$src" 2>/dev/null
  git -C "$src" config user.email g@example.com; git -C "$src" config user.name g
  git -C "$src" config commit.gpgsign false
  local i
  for i in 1 2 3 4 5 6; do
    echo "$i" > "$src/f$i"; git -C "$src" add "f$i"
    git -C "$src" commit -qm "c$i"
  done
  git -C "$src" branch -M main
  local OLD NEW
  OLD="$(git -C "$src" rev-parse main~5)"   # the FIRST commit — beyond a depth-1 walk
  NEW="$(git -C "$src" rev-parse main)"
  local UNREL
  UNREL="$(git -C "$src" commit-tree "$(git -C "$src" rev-parse main^{tree})" -m unrelated < /dev/null 2>/dev/null || true)"

  # ARM 1 — FULL clone: the guard must ANSWER, both directions.
  local full="$tmp/full"
  git clone -q "file://$src" "$full" 2>/dev/null
  AG_REPO="$full"
  local out rc
  out="$(ag_check "$OLD" "origin/main")"; rc=$?
  [ "$rc" = 0 ] && case "$out" in CONTAINED*) ok "full clone: a real ancestor reads CONTAINED (rc 0)";; *) no "full clone: expected CONTAINED, got: $out";; esac || no "full clone: expected rc 0, got $rc — $out"
  out="$(ag_check "$NEW" "origin/main~2")"; rc=$?
  [ "$rc" = 1 ] && case "$out" in NOT-CONTAINED*) ok "full clone: an honest non-ancestor reads NOT-CONTAINED (rc 1)";; *) no "full clone: expected NOT-CONTAINED, got: $out";; esac || no "full clone: expected rc 1, got $rc — $out"

  # ARM 2 — SHALLOW clone (--depth 1) with the old object grafted IN.
  # This is the fail-before arm: bare is-ancestor says rc=1 (a lie), guard says 2.
  local sh="$tmp/shallow"
  git clone -q --depth 1 "file://$src" "$sh" 2>/dev/null
  git -C "$sh" fetch -q --depth 1 origin "$OLD" 2>/dev/null || true
  if [ "$(git -C "$sh" rev-parse --is-shallow-repository 2>/dev/null)" != true ]; then
    no "shallow clone: --depth 1 did not produce a shallow store; the fail-before arm is VACUOUS"
  else
    if git -C "$sh" cat-file -e "${OLD}^{commit}" 2>/dev/null; then
      # CONTROL: the bare recipe this guard exists to refuse.
      git -C "$sh" merge-base --is-ancestor "$OLD" HEAD >/dev/null 2>&1; local brc=$?
      if [ "$brc" = 1 ]; then
        ok "shallow clone CONTROL: bare \`merge-base --is-ancestor\` returns rc=1 for a commit the full clone proves IS an ancestor — the exact lie"
      else
        no "shallow clone CONTROL: bare recipe returned rc=$brc, not the rc=1 lie — this arm no longer reproduces the defect"
      fi
      AG_REPO="$sh"
      out="$(ag_check "$OLD" "HEAD")"; rc=$?
      [ "$rc" = 2 ] && case "$out" in HISTORY-UNAVAILABLE*truncated*) ok "shallow clone: the guard REFUSES (rc 2, walk truncated) where the bare recipe lied";; *) no "shallow clone: expected HISTORY-UNAVAILABLE/truncated, got: $out";; esac || no "shallow clone: expected rc 2, got $rc — $out"
    else
      no "shallow clone: the old object was not grafted in; cannot pose the ambiguous question (arm VACUOUS)"
    fi
  fi

  # ARM 3 — MISSING OBJECT is its own verdict, not 'truncated'.
  local sh2="$tmp/shallow2"
  git clone -q --depth 1 "file://$src" "$sh2" 2>/dev/null
  AG_REPO="$sh2"
  if git -C "$sh2" cat-file -e "${OLD}^{commit}" 2>/dev/null; then
    no "missing-object arm VACUOUS: the depth-1 clone already has $OLD"
  else
    out="$(ag_check "$OLD" "HEAD")"; rc=$?
    [ "$rc" = 2 ] && case "$out" in *"not in this object database"*) ok "depth-1 clone: an absent ancestor object reads HISTORY-UNAVAILABLE via the OBJECT leg, not the walk leg";; *) no "depth-1 clone: expected the object-leg sentence, got: $out";; esac || no "depth-1 clone: expected rc 2, got $rc — $out"
  fi

  # ARM 4 — MISSING REF leg (the pull_request checkout shape: no origin/main).
  AG_REPO="$full"
  out="$(ag_check "$OLD" "refs/remotes/origin/no-such-branch")"; rc=$?
  [ "$rc" = 2 ] && case "$out" in *"does not resolve"*) ok "full clone: an unresolvable descendant ref reads HISTORY-UNAVAILABLE via the REF leg (rc 2), never rc 1";; *) no "missing-ref: expected the ref-leg sentence, got: $out";; esac || no "missing-ref: expected rc 2, got $rc — $out"

  # ARM 5 — OFF-HEAD graft must NOT refuse: this is the D328 over-report the bare
  # `--is-shallow-repository` guard would have produced on the build machine.
  local off="$tmp/offhead"
  git clone -q "file://$src" "$off" 2>/dev/null
  git -C "$off" checkout -q -b side main~1 2>/dev/null
  echo side > "$off/side"; git -C "$off" -c user.email=g@example.com -c user.name=g -c commit.gpgsign=false add side
  git -C "$off" -c user.email=g@example.com -c user.name=g -c commit.gpgsign=false commit -qm side
  git -C "$off" checkout -q main
  # Make the store shallow via an off-HEAD graft: shallow-fetch the side branch.
  local side2="$tmp/side-src"
  git clone -q "$off" "$side2" 2>/dev/null || true
  git -C "$off" fetch -q --depth 1 "file://$off" side:refs/heads/grafted-side 2>/dev/null || true
  if [ "$(git -C "$off" rev-parse --is-shallow-repository 2>/dev/null)" = true ]; then
    AG_REPO="$off"
    out="$(ag_check "$OLD" "main")"; rc=$?
    [ "$rc" = 0 ] && ok "off-HEAD graft: store IS shallow, yet main's own walk is complete — the guard ANSWERS (rc 0) instead of over-reporting (D328)" \
      || no "off-HEAD graft: the bare-flag over-report the guard must avoid; expected rc 0, got $rc — $out"
  else
    echo "skip  off-HEAD graft arm: could not make the store shallow off HEAD in this git ($(git --version)); the D328 over-report direction is NOT covered by this run"
  fi

  : "${UNREL:-}"
  echo "ancestry-guard selftest: ${pass} passed, ${fail} failed"
  [ "$fail" -eq 0 ]
}

# ── CLI ───────────────────────────────────────────────────────────────────────
AG_REPO="${AG_REPO:-.}"
if [ "${1:-}" = "--selftest" ]; then ag_selftest; exit $?; fi

ANC=""; DESC=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) AG_REPO="${2:-}"; shift 2 ;;
    -h|--help) sed -n '/^# usage:/,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 3 ;;
    -*) echo "ancestry-guard: unknown argument '$1'" >&2; exit 3 ;;
    *) if [ -z "$ANC" ]; then ANC="$1"; elif [ -z "$DESC" ]; then DESC="$1"; else echo "ancestry-guard: too many arguments" >&2; exit 3; fi; shift ;;
  esac
done
[ -n "$ANC" ] && [ -n "$DESC" ] || { echo "ancestry-guard: need <ancestor-sha> <descendant-ref>" >&2; exit 3; }
ag_check "$ANC" "$DESC"
exit $?
