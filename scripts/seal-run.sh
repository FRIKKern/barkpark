#!/usr/bin/env bash
# seal-run.sh — the only sanctioned way to TAKE a seal reading.
#
# It runs `cloud/priv/static/__preview__/seal-predicate.mjs` and then adjudicates
# the predicate's own `VERDICT-TOKEN:` line. It adds NO judgement of its own about
# any epic. What it adds is a REFUSAL: four conditions under which the tree the
# reading was taken over cannot support a quotable answer, and under which this
# wrapper declines to hand one over at all.
#
# WHY THIS EXISTS (deploy-reliability wave 28, charter D488)
#
#   Wave 28's direction quoted the seal predicate as `a=FAIL b=FAIL c=PASS`, with
#   leg (b) denying a `cloud-gate` job that plainly sits at .github/workflows/
#   cloud.yml with `if: always()` and a four-way `needs:`. The predicate was not
#   wrong. The TREE was: the reading had been taken over a sibling worktree at
#   ab396959c — a pre-cch-w9 checkout with no `cloud-gate:` job at all — and over
#   a SHALLOW clone, which is the entire reason `b-unavailable=` was non-zero.
#   The predicate had been printing both facts in its own `head=` and
#   `b-unavailable=` fields the whole time. Nobody read them.
#
#   So the failure was never in the parser. It was that a reading taken over the
#   wrong tree is INDISTINGUISHABLE, once quoted, from a reading taken over the
#   right one. This wrapper makes it distinguishable by refusing to produce the
#   quotable form when the tree cannot support it.
#
# THE FOUR REFUSALS
#
#   8  SHALLOW REPOSITORY        clause (b) verifies ancestry; a shallow clone has
#                                no history to verify it against. `HISTORY-
#                                UNAVAILABLE` is a fact about the CHECKOUT, never
#                                about the product. (This refusal was 3 until the
#                                predicate grew its OWN exit 3 for a `Refusal`;
#                                see the exit-code table below.)
#   4  PREDICATE DRIFT           the file about to be executed differs from
#                                `<origin-ref>:cloud/priv/static/__preview__/seal-
#                                predicate.mjs`. The primary checkout carries the
#                                PRE-WAVE-9 copy — 572 lines against origin/main's
#                                1437 — and it emits a DIFFERENT, WRONG verdict
#                                shape. Two answers out of one command name is not
#                                a gauge.
#   5  HEAD IS NOT origin/main   the reading would describe some other tree. This
#                                is the exact condition that produced wave 28's
#                                false verdict. Checked from git BEFORE the run and
#                                again from the token's own `head=` field after it.
#   6  b-unavailable NON-ZERO    the predicate is telling you it could not read the
#                                history some clause-(b) rows needed. "I could not
#                                look" must never render as a finding.
#
# EXIT CODES — A REFUSAL IS NEVER A NO-SEAL
#
#   0  SEAL          the predicate exited 0 over a tree this wrapper vouches for
#                    — OR, when the token reports a partial reading (LADDER-ONLY,
#                    or any a=/c=NOT-READ), a COMPLETED READING that is not a
#                    verdict. Exit 0 alone does not distinguish the two; the
#                    printed line does, and never says SEAL for the second.
#   1  NO SEAL       the predicate exited 1 over a tree this wrapper vouches for
#   2  INFRA FAULT   the predicate exited 2 (or an exit this wrapper cannot map)
#   3  REFUSED — the PREDICATE refused: it measured nothing (its own exit 3)
#   4  REFUSED — predicate drift
#   5  REFUSED — HEAD is not the origin ref's tip
#   6  REFUSED — the token reports unavailable clause-(b) history
#   7  REFUSED — the inputs are unusable (not a work tree, no predicate, no origin
#                ref, no parseable token). Nothing was read.
#   8  REFUSED — shallow repository
#
#   0-3 are the PREDICATE's own quartet, passed through untouched. 4-8 are this
#   wrapper's, and NONE of them is a statement about the epic. That separation is
#   the whole point: an operator who greps for `NO SEAL` must never find one that
#   actually meant "I was pointed at the wrong checkout".
#
# WHY 3 CHANGED HANDS, AND WHY SHALLOW MOVED TO 8 (task-cfa85992568a4bdc)
#
#   `seal-predicate.mjs` used to exit 1 for BOTH a measured NO-SEAL and a
#   `Refusal` (EMPTY-ROSTER, NO-SUCCESSOR, …) where it scored nothing at all. It
#   now exits 3 for the refusal — and this wrapper, whose switch only knew
#   0/1/2, swept that 3 into its `*)` arm and re-published it as exit 2, INFRA
#   FAULT: "the predicate exited 3, which is outside its documented 0/1/2 triad".
#   The predicate's own honesty was being laundered back into a fault by the only
#   thing that reads it.
#
#   The predicate's 3 is upstream and load-bearing, so it is what passes through;
#   this wrapper's shallow refusal is the one that moved, to 8 — the next free
#   code above the 0-7 block. A refusal MUST NOT share a code with a verdict, and
#   two different refusals MUST NOT share one either, which is exactly what
#   reusing 3 here would have done.
#
# WITHHOLDING. When a post-run refusal fires (5 via the token, or 6), the
# predicate's reading is NOT printed. A verdict that came out of an unquotable
# tree is exactly the artefact that gets pasted into a wave paper; printing it
# with a warning above it has already lost. Pass --show-withheld if you are
# debugging the predicate itself and accept that the letters are void.
#
# THE FENCE. `cloud/priv/static/__preview__/*` is ceded to the Cloud Console
# epic by charter D402. D402 cedes the FILE, not the act of invoking it. This
# wrapper lives in scripts/, adds no logic to the fenced file, executes it
# unmodified, and reads only its documented stdout token. seal-predicate.mjs and
# seal-predicate.test.mjs are byte-identical to origin/main.
#
# READ-ONLY. Every git call here is a read (`rev-parse`, `hash-object`, `show`).
# Nothing is fetched, written, checked out or created.
#
#   bash scripts/seal-run.sh --repo <full-history worktree at origin/main>
#   bash scripts/seal-run.sh --repo . --epic deploy-reliability-epic -- --ladder-only
#
# Mutation proofs: bash scripts/seal-run.test.sh

set -uo pipefail

PRED_REL="cloud/priv/static/__preview__/seal-predicate.mjs"

REPO=""
EPIC=""
ORIGIN_REF="origin/main"
SHOW_WITHHELD=0
PASSTHRU=()

usage() {
  sed -n '/^#   bash scripts\/seal-run.sh/,/^#$/p' "$0" | sed 's/^# \{0,1\}//'
  cat <<'EOF'

  --repo <path>        checkout to read (default: this script's own repo root)
  --epic <id>          forwarded to the predicate
  --origin-ref <ref>   the ref that defines "the tree worth quoting" (default: origin/main)
  --show-withheld      print a withheld reading anyway (the letters are void)
  -- <args…>           forwarded verbatim to the predicate
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)        REPO="${2-}"; shift 2 ;;
    --epic)        EPIC="${2-}"; shift 2 ;;
    --origin-ref)  ORIGIN_REF="${2-}"; shift 2 ;;
    --predicate)
      # REMOVED (dr-w34-bl-seal-run-predicate-flag-is-a-decoy). The flag could
      # never work: refusal 4 compares the executed file against the HARDCODED
      # $ORIGIN_REF:$PRED_REL blob, so any --predicate that was not a
      # byte-identical copy of that file was a guaranteed pre-run exit 4 whose
      # remedy named a file the caller never passed. Dead surface that read as
      # an escape hatch. The runner executes ONLY <repo>/$PRED_REL.
      echo "seal-run: --predicate is no such flag (removed). This runner executes ONLY <repo>/$PRED_REL — point --repo at the checkout you want read." >&2
      exit 7 ;;
    --show-withheld) SHOW_WITHHELD=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    --)            shift; PASSTHRU=("$@"); break ;;
    *) echo "seal-run: unknown argument: $1" >&2; usage >&2; exit 7 ;;
  esac
done

if [ -z "$REPO" ]; then
  REPO="$(cd "$(dirname "$0")/.." && pwd)"
fi

# ---------------------------------------------------------------------------
# Refusals are COLLECTED, not short-circuited: a stale sibling worktree of a
# shallow clone trips three of them at once, and an operator who fixes only the
# one they were told about comes straight back. The exit code is the FIRST
# refusal in evaluation order (the most fundamental), but every one is printed.
REFUSAL_CODE=0
REFUSALS=()

refuse() { # <code> <headline> <remedy>
  REFUSALS+=("$1"$'\x1f'"$2"$'\x1f'"$3")
  [ "$REFUSAL_CODE" -eq 0 ] && REFUSAL_CODE="$1"
  return 0
}

report_refusals() {
  local entry code head remedy
  echo
  echo "=============================================================================="
  echo "seal-run: REFUSED TO READ — no seal verdict was taken."
  echo "=============================================================================="
  for entry in "${REFUSALS[@]}"; do
    IFS=$'\x1f' read -r code head remedy <<<"$entry"
    echo
    echo "  [exit $code] $head"
    echo "    do this: $remedy"
  done
  echo
  echo "  Every line above is a fact about the CHECKOUT at $REPO, not about the epic."
  echo "  Nothing here is a clause (a)/(b)/(c) finding, and none of it is a seal verdict."
  echo "  Take the reading again from a full-history worktree parked at $ORIGIN_REF."
  echo
}

# ---------------------------------------------------------------------------
# UNUSABLE INPUT (exit 7) — short-circuits, because none of the four refusals is
# even askable without a work tree, an origin ref and a predicate on disk.
if [ ! -d "$REPO" ]; then
  refuse 7 "--repo $REPO is not a directory." "point --repo at a checkout of this repository"
  report_refusals; exit 7
fi
REPO="$(cd "$REPO" && pwd)"

if ! git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  refuse 7 "--repo $REPO is not a git work tree." "point --repo at a checkout of this repository"
  report_refusals; exit 7
fi

PREDICATE="$REPO/$PRED_REL"
if [ ! -f "$PREDICATE" ]; then
  refuse 7 "the predicate is not on disk at $PREDICATE." "point --repo at a checkout that carries $PRED_REL"
  report_refusals; exit 7
fi

ORIGIN_SHA="$(git -C "$REPO" rev-parse --verify --quiet "$ORIGIN_REF^{commit}" || true)"
if [ -z "$ORIGIN_SHA" ]; then
  refuse 7 "$ORIGIN_REF does not resolve in $REPO, so there is no tip to compare against." \
           "git -C $REPO fetch origin main   (then re-run)"
  report_refusals; exit 7
fi

# ---------------------------------------------------------------------------
# REFUSAL 8 — SHALLOW REPOSITORY.
# Clause (b) verifies each registered fix by ANCESTRY of origin/main. A shallow
# clone does not carry the commits that ancestry is asked about, so the predicate
# reports HISTORY-UNAVAILABLE — which is true of the checkout and says nothing
# whatsoever about whether the defect was paid.
SHALLOW="$(git -C "$REPO" rev-parse --is-shallow-repository 2>/dev/null || echo unknown)"
if [ "$SHALLOW" = "true" ]; then # MUT:G-SHALLOW
  refuse 8 "$REPO is a SHALLOW repository — clause (b) ancestry cannot be evaluated here." \
           "git -C $REPO fetch --unshallow   (or point --repo at a full-history worktree)"
fi

# ---------------------------------------------------------------------------
# REFUSAL 4 — PREDICATE DRIFT.
# Compared as git blob ids, so this is byte identity and not a line count.
WANT_BLOB="$(git -C "$REPO" rev-parse --verify --quiet "$ORIGIN_REF:$PRED_REL" || true)"
HAVE_BLOB="$(git -C "$REPO" hash-object "$PREDICATE" 2>/dev/null || true)"
if [ -z "$WANT_BLOB" ] || [ -z "$HAVE_BLOB" ]; then
  refuse 7 "the predicate at $ORIGIN_REF could not be resolved, so drift cannot be ruled out." \
           "git -C $REPO fetch origin main   (then re-run)"
  report_refusals; exit 7
fi
if [ "$WANT_BLOB" != "$HAVE_BLOB" ]; then # MUT:G-DRIFT
  refuse 4 "the predicate about to run is NOT $ORIGIN_REF's copy (blob ${HAVE_BLOB:0:9} vs ${WANT_BLOB:0:9}) — a different program under the same name emits a different verdict shape." \
           "git -C $REPO checkout $ORIGIN_REF -- $PRED_REL   (or point --repo at a worktree parked at $ORIGIN_REF)"
fi

# ---------------------------------------------------------------------------
# REFUSAL 5 — HEAD IS NOT THE ORIGIN REF'S TIP (pre-run leg).
# Asked from git before the run so a wrong tree costs no network call, and asked
# AGAIN below from the token's own head= field, which is the field wave 28 had in
# front of it and did not read.
HEAD_SHA="$(git -C "$REPO" rev-parse --verify --quiet HEAD || true)"
if [ -n "$HEAD_SHA" ] && [ "$HEAD_SHA" != "$ORIGIN_SHA" ]; then # MUT:G-HEAD
  refuse 5 "HEAD of $REPO is ${HEAD_SHA:0:9}, not $ORIGIN_REF's tip ${ORIGIN_SHA:0:9} — a reading here describes some other tree (this is exactly what produced wave 28's false a=FAIL b=FAIL)." \
           "git -C $REPO fetch origin main && git -C $REPO checkout $ORIGIN_REF   (or point --repo at a worktree parked there)"
fi

# A pre-run refusal means the predicate is NEVER EXECUTED. Refusing after the
# fact would still leave a reading in the terminal for someone to quote.
if [ "$REFUSAL_CODE" -ne 0 ]; then
  echo "seal-run: the predicate was NOT executed." >&2
  report_refusals
  exit "$REFUSAL_CODE"
fi

# ---------------------------------------------------------------------------
# THE RUN. Output is buffered, because whether it may be shown at all is not
# known until the token has been adjudicated.
CMD=(node "$PREDICATE" --repo "$REPO")
[ -n "$EPIC" ] && CMD+=(--epic "$EPIC")
[ ${#PASSTHRU[@]} -gt 0 ] && CMD+=("${PASSTHRU[@]}")

OUT_FILE="$(mktemp -t seal-run.XXXXXX)"
trap 'rm -f "$OUT_FILE"' EXIT

"${CMD[@]}" >"$OUT_FILE" 2>&1
PRED_EXIT=$?

TOKEN="$(grep -m1 '^VERDICT-TOKEN: SEAL-PREDICATE' "$OUT_FILE" || true)"
if [ -z "$TOKEN" ]; then
  cat "$OUT_FILE"
  refuse 7 "the predicate printed no VERDICT-TOKEN line (it exited $PRED_EXIT), so there is nothing to adjudicate." \
           "run the predicate directly and read its output: node $PREDICATE --repo $REPO"
  report_refusals
  exit 7
fi

tok() { # <field name> -> value, empty when absent
  printf '%s\n' "$TOKEN" | tr ' ' '\n' | grep -m1 "^$1=" | cut -d= -f2- || true
}

TOK_HEAD="$(tok head)"
TOK_BUNAVAIL="$(tok b-unavailable)"
# Only the REFUSED token carries `reason=`; it is empty on every other verdict.
TOK_REASON="$(tok reason)"

# The word immediately after `SEAL-PREDICATE` is the token's own name for what it
# is: SEAL, NO-SEAL, REFUSED, LADDER-ONLY. Read positionally because it is the one
# field the predicate emits WITHOUT a `name=` prefix.
TOK_VERDICT="$(printf '%s\n' "$TOKEN" | awk '{print $3}')"
TOK_A="$(tok a)"
TOK_C="$(tok c)"
TOK_RUNGS="$(tok b-rungs)"

# ---------------------------------------------------------------------------
# NOT EVERY EXIT 0 IS A SEAL (task-5e2a9e6cb5b6fe74).
#
# `--ladder-only` reads clause (b) and DELIBERATELY reads neither clause (a) nor
# bucket (c). It exits 0 on purpose — charter D335: an instrument that reads and
# then exits 1 gets wired into CI as a gate, and a gate is a verdict again. So the
# predicate carries the condition in LETTERS, and says so at length: a ladder-only
# run prints five numbered paragraphs headed WHAT THIS READING IS NOT, the second
# of which states it is not clause (a) and not bucket (c), "printed a=NOT-READ
# c=NOT-READ below, in the token itself, so no reader can quote this run as the
# seal".
#
# This wrapper then quoted it as the seal. Measured 2026-09-02 over origin/main at
# 185c07d034: `seal-run.sh --repo <tip> -- --successor TERMINAL --ladder-only`
# printed `seal-run: VOUCHED — SEAL (predicate exit 0)` on the line directly below
# a token reading `LADDER-ONLY … a=NOT-READ c=NOT-READ`. The wrapper's whole
# purpose is that a reading which cannot be quoted must not arrive in quotable
# form; this was that promise running backwards, in the one line an operator greps.
#
# THE TEST IS THE CLAUSES, NOT THE MODE NAME. Keying only on the literal
# `LADDER-ONLY` would leave the next partial mode to be born unguarded under a new
# name. A verdict is a statement about (a), (b) AND (c) together, so exit 0 earns
# the word SEAL only when the token declines to say that any clause went unread.
# The mode name is kept as a third, independent trigger so a token that omits the
# a=/c= fields entirely still cannot be laundered.
#
# THE EXIT CODE DOES NOT MOVE. D335 makes ladder-only's 0 load-bearing, and this
# defect was never in the code — it was in the letters. Changing the exit here
# would re-create the gate D335 forbids while fixing nothing an operator reads.
IS_PARTIAL=0
if [ "$TOK_VERDICT" = "LADDER-ONLY" ] || [ "$TOK_A" = "NOT-READ" ] || [ "$TOK_C" = "NOT-READ" ]; then # MUT:G-PARTIAL
  IS_PARTIAL=1
fi

# ---------------------------------------------------------------------------
# REFUSAL 5 — post-run leg, read off the token itself.
#
# THE TOKEN'S head= IS ABBREVIATED. The predicate builds it from `git rev-parse
# --short HEAD`, so it is 7-plus characters, never the 40 this wrapper resolved
# $ORIGIN_SHA to. A flat `!=` therefore fired refusal 5 on EVERY live read —
# including over a tree parked exactly at the tip, where the reading it withheld
# was `b-clean=6/6 b-unavailable=0/6`. It also took the exit code away from
# refusal 6 (refusals are collected and REFUSAL_CODE keeps the FIRST), so a tree
# that could not read clause-(b) history exited 5 and never 6.
#
# A bare 7-character floor is NOT the fix: a checkout configured `core.abbrev=4`
# emits head=c2de and would still be refused for being correct. So ask THIS repo
# what it abbreviates the tip to and accept that at whatever length it chose;
# only a head the repo did not produce has to clear git's own 7-character floor,
# which is what keeps a 1-character head and a same-length LIE refusable.
MIN_ABBREV=7
ORIGIN_SHORT="$(git -C "$REPO" rev-parse --short "$ORIGIN_SHA" 2>/dev/null || true)"

head_is_tip() { # <token head=> -> 0 when it names $ORIGIN_SHA, 1 when it names some other tree
  local h="$1"
  [ "$h" = "$ORIGIN_SHA" ] && return 0
  [ -n "$ORIGIN_SHORT" ] && [ "$h" = "$ORIGIN_SHORT" ] && return 0
  [ "${#h}" -ge "$MIN_ABBREV" ] && [ "${ORIGIN_SHA:0:${#h}}" = "$h" ]
}

if [ -n "$TOK_HEAD" ] && [ "$TOK_HEAD" != "NOT-READ" ] && ! head_is_tip "$TOK_HEAD"; then # MUT:G-TOKENHEAD
  refuse 5 "the token says head=$TOK_HEAD, which is not $ORIGIN_REF's tip $ORIGIN_SHA — the reading describes some other tree." \
           "take the reading from a worktree parked at $ORIGIN_REF"
fi

# ---------------------------------------------------------------------------
# REFUSAL 6 — b-unavailable NON-ZERO.
# The field is `N/M`. `0/M` is a read that succeeded and is not a refusal; the
# SEAL/NO-SEAL token omits the field entirely in that case, the LADDER-ONLY token
# always prints it.
if [ -n "$TOK_BUNAVAIL" ] && [ "${TOK_BUNAVAIL%%/*}" != "0" ]; then # MUT:G-BUNAVAIL
  refuse 6 "the token reports b-unavailable=$TOK_BUNAVAIL — the predicate could not read the history those clause-(b) rows needed. That is not a finding about the epic." \
           "take the reading from a full-history checkout (git fetch --unshallow), then re-read clause (b)"
fi

if [ "$REFUSAL_CODE" -ne 0 ]; then
  echo "seal-run: the reading is WITHHELD — it was taken over a tree that cannot be quoted." >&2
  echo "  the token's own diagnosis: head=${TOK_HEAD:-<absent>} b-unavailable=${TOK_BUNAVAIL:-0/0}" >&2
  if [ "$SHOW_WITHHELD" -eq 1 ]; then
    echo "  --show-withheld: the letters below are VOID." >&2
    cat "$OUT_FILE"
  fi
  report_refusals
  exit "$REFUSAL_CODE"
fi

# ---------------------------------------------------------------------------
# VOUCHED. The tree is full-history, parked at the origin ref, running the origin
# ref's own predicate, and the predicate read everything it needed. Whatever the
# predicate said below is quotable, and it is the PREDICATE's, not this wrapper's
# — including its own REFUSAL (exit 3), which vouching for the TREE cannot turn
# into a verdict about the epic.
cat "$OUT_FILE"
echo
case "$PRED_EXIT" in
  # A PARTIAL READING IS NOT A SEAL. The tree is vouched for and the reading is
  # quotable AS WHAT IT IS — a clause-(b) rung tally — which is why it prints in
  # full above and exits 0. What it is not is a verdict, and the word SEAL appears
  # nowhere on this line: an operator grepping for it must not land here.
  0) if [ "$IS_PARTIAL" -eq 1 ]; then
       echo "seal-run: NOT A VERDICT — this is a PARTIAL READING (${TOK_VERDICT:-mode unnamed}), a=${TOK_A:-<absent>} c=${TOK_C:-<absent>}."
       echo "          Clause (b) was read${TOK_RUNGS:+ (b-rungs=$TOK_RUNGS)}; clause (a) and bucket (c) were NOT. Nothing above certifies this epic."
       echo "          Exit 0 says the reading completed, never that it sealed. For a verdict, re-run WITHOUT --ladder-only and name a successor."
     else
       echo "seal-run: VOUCHED — SEAL (predicate exit 0)"
     fi ;;
  1) echo "seal-run: VOUCHED — NO SEAL (predicate exit 1)" ;;
  2) echo "seal-run: the predicate reported an INFRA FAULT (exit 2). No verdict was taken." ;;
  # NOT "VOUCHED", and NOT an infra fault. The tree is quotable; the PREDICATE
  # declined to measure it. Its `reason=` token field is the refusal's own name
  # (EMPTY-ROSTER, NO-SUCCESSOR, …) and is echoed verbatim rather than paraphrased
  # — an operator who greps for `NO SEAL` must not find this line.
  3) echo "seal-run: REFUSED — nothing was measured (predicate exit 3): ${TOK_REASON:-<no reason= field>}" ;;
  *) echo "seal-run: the predicate exited $PRED_EXIT, which is outside its documented 0/1/2/3 quartet." ;;
esac
echo "seal-run: read over $REPO at $ORIGIN_REF tip ${ORIGIN_SHA:0:9}; token head=${TOK_HEAD:-<absent>} b-unavailable=${TOK_BUNAVAIL:-0/0}"

# The predicate's refusal (3) is forwarded AS 3, not re-coded: this wrapper adds
# no judgement of its own to the predicate's verdicts, and a refusal it renamed
# would be a second name for one fact.
case "$PRED_EXIT" in
  0|1|2|3) exit "$PRED_EXIT" ;;
  *)       exit 2 ;;
esac
