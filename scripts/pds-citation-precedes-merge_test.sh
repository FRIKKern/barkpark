#!/usr/bin/env bash
#
# PAIRED TEST for scripts/pds-citation-precedes-merge.sh.
#
# Every case builds a THROWAWAY GIT REPO with its own fixture charter, so the
# subject resolves against a corpus this file wrote and nothing else. The real
# charter is never read here: a test whose verdict moves when an unrelated PR
# lands is not a test.
#
# THE D-NUMBERS IN THE FIXTURES ARE BUILT ARITHMETICALLY, NEVER WRITTEN AS
# PREFIXED LITERALS. pds-record-parity.sh axis D scans `scripts/pds-*` for
# prefixed D-numbers and demands each resolve in the REAL charter; a planted
# phantom written literally here would red that arm by construction. The
# subject's own header carries the same note for the same reason.
#
# WHAT IS PROVEN, IN BOTH DIRECTIONS:
#   1  cites a number the BASE charter defines            -> PASS   (0)
#   2  cites a number NOTHING defines                     -> FAIL   (1), named
#   3  cites nothing at all                               -> PASS   (0)
#   4  cites a number THIS PR's own charter diff defines  -> PASS   (0)  same-PR
#   5  cites a number only the BRANCH's charter defines   -> FAIL   (1)  the D643 shape
#   6  a lens that reads nothing                          -> UNCHECKED (2)
#   7  a lens that resolves everything                    -> UNCHECKED (2)  probe control
#   9  a lens that counts any PDS-D it sees               -> UNCHECKED (2)  probe control
#   8  the charter is absent on the base ref              -> UNCHECKED (2)
#
# WIRED (task-68c3064b51854cd3): this file runs on the `PDS census / parity /
# scratch-target harnesses` job, as the arm named "PDS citation precedes merge"
# in .github/shell-harness-legs.json (the matrix collapse moved the per-leg
# `run:` bodies out of .github/workflows/shell-harnesses.yml and into that
# file; the job's `scripts/pds-*.sh` workflow-level glob already DISPATCHES on
# an edit to this file or to the predicate beside it, so both halves are now
# executed by CI and not only by hand). It REPLACES the `MANUAL PROOF` census
# exemption header this file carried from PR #18542 until the wiring landed —
# that exemption was a handoff, and this arm is the line it was waiting for.
# The exemption marker is deliberately not spelled in full anywhere below: it is
# the exact string scripts/selftest-wiring-census.sh greps for over the first 60
# lines, and a file that both RUNS in CI and still declares the exemption would
# be counted EXEMPT rather than RUN — the census would stop measuring this file
# on the very commit that wired it. Mirrors the WIRED header on
# scripts/pds-charter-anchors-check_test.sh — same job, same fence, same shape.
# Baseline at authoring: 10 passed, 0 failed.
#
# Cases 6, 7 and 9 are the mutations that matter: they break the READER, not the
# corpus, and each must refuse to print a verdict. An absence is never caught by
# inspection — a broken reader and a clean corpus produce the same empty output,
# so the only defence is a control that MUST fire.
#
set -uo pipefail

SUBJECT="$(cd "$(dirname "$0")" && pwd)/pds-citation-precedes-merge.sh"
LENS_REAL="$(cd "$(dirname "$0")" && pwd)/pds-record-parity.sh"
CHARTER_REL=".claude/workflows/bp-pds-charter.md"

FAILS=0
pass() { printf '  PASS  %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; FAILS=$((FAILS + 1)); }

# D-numbers, assembled — see the header.
D_BASE=$((100 + 0))       # defined in the fixture base charter
D_BASE2=$((100 + 1))      # also defined in the base charter
D_NEW=$((100 + 2))        # defined only by the branch
D_PHANTOM=$((9000 + 91))  # defined nowhere

mk_repo() { # mk_repo <dir>  — a base commit with a two-decision charter
  local d="$1"
  mkdir -p "$d/.claude/workflows" "$d/api"
  git -C "$d" init -q -b main
  git -C "$d" config user.email t@example.com
  git -C "$d" config user.name t
  git -C "$d" config commit.gpgsign false
  {
    echo "# Fixture charter"
    echo
    echo "### PDS-D${D_BASE} — THE FIRST DECISION."
    echo "body"
    echo
    echo "- **PDS-D${D_BASE2} — THE SECOND DECISION.** body"
  } > "$d/$CHARTER_REL"
  echo "seed" > "$d/api/seed.ex"
  git -C "$d" add -A
  git -C "$d" commit -q -m "base"
}

run() { # run <dir> [extra args...] -> stdout+stderr in $OUT, code in $RC
  local d="$1"; shift
  OUT="$(cd "$d" && bash "$SUBJECT" --root "$d" --base main --head HEAD --lens "$LENS_REAL" "$@" 2>&1)"
  RC=$?
}

expect() { # expect <label> <want-rc> [<must-contain>...]
  local label="$1" want="$2"; shift 2
  local ok=1 needle
  [ "$RC" -eq "$want" ] || { ok=0; printf '    got exit %s, wanted %s\n' "$RC" "$want"; }
  for needle in "$@"; do
    printf '%s' "$OUT" | grep -qF -- "$needle" || { ok=0; printf '    missing from output: %s\n' "$needle"; }
  done
  if [ "$ok" -eq 1 ]; then pass "$label"; else fail "$label"; printf '%s\n' "$OUT" | sed 's/^/      | /'; fi
}

echo "PDS CITATION PRECEDES MERGE — paired test"

# ── 1. the green that must stay green ────────────────────────────────────────
T1="$(mktemp -d)"; mk_repo "$T1"
git -C "$T1" checkout -q -b slice
echo "# see PDS-D${D_BASE} for why" >> "$T1/api/seed.ex"
git -C "$T1" commit -q -am "cite a defined decision"
run "$T1"
expect "1  cites a base-defined number -> PASS" 0 "PASS" "all three fired"

# ── 2. the red that must fire, by name ───────────────────────────────────────
echo "# and also PDS-D${D_PHANTOM}, which is nothing" >> "$T1/api/seed.ex"
git -C "$T1" commit -q -am "cite a phantom"
run "$T1"
expect "2  cites a phantom -> FAIL, named" 1 "FAIL" "PDS-D${D_PHANTOM}" "api/seed.ex"

# ── 3. no citation at all ────────────────────────────────────────────────────
T3="$(mktemp -d)"; mk_repo "$T3"
git -C "$T3" checkout -q -b slice
echo "# a change that cites no decision" >> "$T3/api/seed.ex"
git -C "$T3" commit -q -am "cite nothing"
run "$T3"
expect "3  cites nothing -> PASS, and says so" 0 "PASS" "introduces no PDS-D citation" "all three fired"

# ── 4. same-PR: the branch defines what it cites ─────────────────────────────
T4="$(mktemp -d)"; mk_repo "$T4"
git -C "$T4" checkout -q -b slice
printf '\n### PDS-D%s — DECIDED AND CITED IN ONE PR.\nbody\n' "$D_NEW" >> "$T4/$CHARTER_REL"
echo "# per PDS-D${D_NEW}" >> "$T4/api/seed.ex"
git -C "$T4" commit -q -am "charter + slice in one PR"
run "$T4"
expect "4  same-PR definition -> PASS, exemption named" 0 "PASS" "same-PR"

# ── 5. THE D643 SHAPE: the branch's charter knows it, main does not ──────────
# Identical to case 4 except the charter edit is REVERTED before the citing
# commit — i.e. the citation ships while the charter PR is still open. A lens
# that read the BRANCH's charter (pds-record-parity axis D) is green here.
T5="$(mktemp -d)"; mk_repo "$T5"
git -C "$T5" checkout -q -b charter-pr
printf '\n### PDS-D%s — LANDS IN A DIFFERENT PR, LATER.\nbody\n' "$D_NEW" >> "$T5/$CHARTER_REL"
git -C "$T5" commit -q -am "the charter PR, still open"
git -C "$T5" checkout -q -b slice main
echo "# per PDS-D${D_NEW}" >> "$T5/api/seed.ex"
git -C "$T5" commit -q -am "the slice that cites it"
run "$T5"
expect "5  cited only by an unmerged charter PR -> FAIL" 1 "FAIL" "PDS-D${D_NEW}"
# and the control: the SAME number passes once the charter is on the base ref
git -C "$T5" checkout -q main
git -C "$T5" merge -q --no-ff -m "charter merges first" charter-pr
run "$T5"
expect "5b control: same slice, charter now on base -> PASS" 0 "PASS"

# ── 6. MUTATION: a lens that reads nothing must not print a pass ─────────────
T6="$(mktemp -d)"; mk_repo "$T6"
git -C "$T6" checkout -q -b slice
echo "# see PDS-D${D_PHANTOM}" >> "$T6/api/seed.ex"
git -C "$T6" commit -q -am "cite a phantom"
BLIND="$T6/blind-lens.sh"; printf '#!/usr/bin/env bash\nexit 0\n' > "$BLIND"; chmod +x "$BLIND"
OUT="$(cd "$T6" && bash "$SUBJECT" --root "$T6" --base main --head HEAD --lens "$BLIND" 2>&1)"; RC=$?
expect "6  mutation: blind lens -> UNCHECKED, never a verdict" 2 "UNCHECKED"

# ── 7. MUTATION: a lens that resolves EVERYTHING must not print a pass ───────
GREEDY="$T6/greedy-lens.sh"; printf '#!/usr/bin/env bash\nseq 1 99999\n' > "$GREEDY"; chmod +x "$GREEDY"
OUT="$(cd "$T6" && bash "$SUBJECT" --root "$T6" --base main --head HEAD --lens "$GREEDY" 2>&1)"; RC=$?
expect "7  mutation: all-resolving lens -> UNCHECKED via the probe control" 2 "UNCHECKED" "probe control failed"

# ── 9. MUTATION: a lens that counts a prose MENTION as a definition ─────────
# The probe charter mentions a third number in prose. A lens that grabs any
# PDS-D it sees returns three numbers where two are defined, and must be refused
# BEFORE it is trusted to say a real citation resolves.
LOOSE="$T6/loose-lens.sh"
printf '#!/usr/bin/env bash\nf=""; while [ $# -gt 0 ]; do [ "$1" = "--charter" ] && f="$2"; shift; done\ngrep -oE "PDS-D[0-9]+" "$f" | sed "s/^PDS-D//" | sort -n -u\n' > "$LOOSE"
chmod +x "$LOOSE"
OUT="$(cd "$T6" && bash "$SUBJECT" --root "$T6" --base main --head HEAD --lens "$LOOSE" 2>&1)"; RC=$?
expect "9  mutation: mention-counting lens -> UNCHECKED via the probe control" 2 "UNCHECKED" "probe control failed"

# ── 8. no charter on the base ref ────────────────────────────────────────────
T8="$(mktemp -d)"; mk_repo "$T8"
git -C "$T8" rm -q "$CHARTER_REL"; git -C "$T8" commit -q -m "no charter"
git -C "$T8" checkout -q -b slice
echo "# see PDS-D${D_BASE}" >> "$T8/api/seed.ex"
git -C "$T8" commit -q -am "cite"
run "$T8"
expect "8  charter absent on base -> UNCHECKED" 2 "UNCHECKED"

rm -rf "$T1" "$T3" "$T4" "$T5" "$T6" "$T8"

echo
if [ "$FAILS" -eq 0 ]; then echo "SELFTEST PASS — 10/10"; exit 0; fi
echo "SELFTEST FAIL — $FAILS case(s)"; exit 1
