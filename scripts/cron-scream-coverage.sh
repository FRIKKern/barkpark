#!/usr/bin/env bash
# cron-scream-coverage.sh — a cron'd workflow's RED must reach a declared reader.
#
# ─────────────────────────────────────────────────────────────────────────────
#  THE QUESTION, AND WHY IT IS NOT THE ONE THE FILING ASKED
# ─────────────────────────────────────────────────────────────────────────────
# task-e6fe244ece2b5d27 was filed as "four daily smoke crons run with no
# failure-reporting step and no watcher". Measured on origin/main 2026-09-23,
# ALL FOUR NAMED WORKFLOWS ALREADY HAVE A READER:
#
#   search-starter-smoke.yml  push: branches [main]  AND its step
#                             `Escalate a failing beat to a human`, which runs
#                             `bash scripts/file-ci-failure-issue.sh`
#   studio-journey-smoke.yml  push: branches [main]
#   paper-readers.yml         its step `Report failure to a human`
#   codebase-intel.yml        its step `Report failure to a human`
#
# RE-DERIVE, rather than trust the four lines above. The whole matrix, both
# mechanisms, every cron'd workflow:
#
#     bash scripts/cron-scream-coverage.sh --list
#
# The R3 half alone — note it is NOT filtered to cron'd workflows and returns
# every notifier invoker in the tree (22 of them today), so it is a lead, not
# the verdict:
#
#     grep -rln 'bash .*file-ci-failure-issue\.sh' .github/workflows/
#
# The filing is not stale by half; it is 0-for-4. And the two questions it asked
# for — did the cron DISPATCH, did it CONCLUDE green — are BOTH already answered
# on this tree, by two instruments that predate this file:
#
#   scripts/cron-overdue-probe.sh     DISPATCH. Bounds every `critical` row at
#                                     3x its interval, and FIRES a
#                                     workflow_dispatch rescue rather than
#                                     merely reporting silence.
#   scripts/scheduled-arm-health.sh   CONCLUSION, scoped `event=schedule` (the
#                                     scoping is the point: a push-green inside
#                                     a streak of scheduled reds certifies a
#                                     dead cron as healthy). Six verdicts, incl.
#                                     NEVER SUCCEEDED / LAUNDERED / VACUOUS CRON.
#
# SO THE HOLE IS NOT THE VERDICT. IT IS THE READER OF THE VERDICT.
# scheduled-arm-health.yml — the very instrument that answers both questions —
# declares NO push arm and NO pull_request arm by design, and invokes no
# notifier. Its red renders on no pull request and is invisible to
# main-red-owner.yml, whose population filter is the enumeration loop in
# scripts/main-red-predicate.sh under the banner comment
# `--- enumerate workflows carrying a push: arm ---`, whose body is
# `grep -qE '^[[:space:]]*push:' "$f" || continue` — so a schedule-only workflow is
# STRUCTURALLY OUTSIDE the one mechanism that gives a red on main an owner.
# It was measured red 5 of its 5 most recent runs. Nobody was told, and by
# construction nobody could have been.
#
# ─────────────────────────────────────────────────────────────────────────────
#  THE PREDICATE (this is the deliverable, and it is a RULE, not a list)
# ─────────────────────────────────────────────────────────────────────────────
# A cron'd workflow NEEDS a scream  iff  its red reaches NO declared reader.
#
# Exactly two reader mechanisms exist in this tree, and both are mechanical:
#
#   R2  A BRANCH-DRIVEN `push:` ARM. This enrols the workflow in
#       main-red-predicate.sh's population, and main-red-owner.yml (hourly)
#       turns a >2 h red on main's tip into ONE deduped GitHub issue. Note the
#       asymmetry that makes this work at all: the POPULATION filter is the
#       push arm, but the READ is `actions/workflows/<f>/runs?branch=main`
#       with NO event filter — so a SCHEDULED red is owned too, provided the
#       file happens to also carry a push arm. Tags-only push arms do not
#       count: they cannot produce a main run. Same partition
#       main-red-predicate.sh draws under its `TAGS-ONLY PUSH ARMS ARE NOT
#       BRANCH-DRIVEN` comment.
#
#   R3  AN INVOCATION OF scripts/file-ci-failure-issue.sh. Files (or appends
#       to) one deduped issue per CI_FAILURE_KEY, and escalates once after
#       ESCALATE_AFTER repeats rather than appending forever.
#
# AND — THE PRONG THAT KILLS THE NAIVE SWEEP — A `pull_request:` ARM IS NOT A
# READER OF A SCHEDULED RED. A scheduled run renders a check run on no pull
# request head. A PR arm proves the workflow's CODE still executes on PR
# inputs; it says nothing about what the cron concluded at 04:47Z. Eight of
# this tree's cron'd workflows carry a PR arm, and for six of them it is the
# ONLY thing that looks like coverage.
#
# WHY THIS DISSOLVES THE INFINITE REGRESS WITHOUT A SKIP LIST. The obvious
# objection to any such guard is that a watcher would need a watcher. It does
# not, because the watchers are not EXEMPTED here — they PASS, on the merits:
# breakglass-watch, main-gate-watch, main-red-owner, cron-overdue-probe and
# stale-verdict-watch are all READ, every one of them by a mechanism
# cron-overdue-probe.sh's own `check_fallbacks` already demanded of every
# `critical` row. The regress terminates at main-red-owner.yml, which carries
# R2, and whose SILENCE (as opposed to its red) is bounded by
# cron-overdue-probe's `main-red-owner.yml|critical|60` line. Two instruments,
# each the other's backstop, and neither one a special case in this file.
#
# A naive sweep — "scheduled workflow with zero `if: failure()`" — returns 20+
# and sweeps in breakglass-watch, main-red-owner, cron-overdue-probe and
# stale-verdict-watch. This predicate returns 8. The difference is entirely the
# two prongs above.
#
# ─────────────────────────────────────────────────────────────────────────────
#  WHY `if: failure()` IS NOT THE DETECTOR, THOUGH IT IS THE OBVIOUS ONE
# ─────────────────────────────────────────────────────────────────────────────
# The filing counted `if: failure()`. That string is a CONDITION, not a
# destination: a step can carry it and merely echo into a run log nobody opens.
# Conversely search-starter-smoke.yml's step `Escalate a failing beat to a
# human` invokes the notifier with NO `if: failure()` on it at all — the step
# reads the journey report and decides for itself — and it is a genuine reader.
# So the detector keys on the INVOCATION.
#
# AND IT KEYS ON AN INVOCATION, NOT A MENTION. required-checks-drift.yml carries
# `- "scripts/file-ci-failure-issue.sh"` as an entry in its `paths:`
# trigger-filter list — the notifier named as a file to WATCH, not a call to
# it. A `grep -F`
# for the basename scores that file R3 and is WRONG; it happens to reach the
# right VERDICT because that workflow also carries R2, which is precisely the
# shape that hides a broken detector behind a correct answer. R3 therefore
# requires `bash <path>/file-ci-failure-issue.sh`.
#
# ─────────────────────────────────────────────────────────────────────────────
#  THE LEDGER, AND WHY THIS GUARD IS NOT BORN SCREAMING
# ─────────────────────────────────────────────────────────────────────────────
# Eight workflows are UNREAD today. A guard that reds on eight things the day
# it lands is a guard whose readers learn to dismiss it — the exact failure
# task-e6fe244ece2b5d27 exists to prevent, reached from a new side. So the
# eight are LEDGERED below, each with a dated disposition, and this guard is a
# RATCHET over that ledger:
#
#   NEW UNREAD    a cron'd workflow is UNREAD and carries no ledger row  -> RED
#   STALE ROW     a ledgered workflow HAS a reader now                   -> RED
#   GONE ROW      a ledgered workflow no longer declares a cron          -> RED
#
# THIS HAPPENED DURING THIS VERY COMMIT, AND THE ROW IS GONE BECAUSE OF IT.
# The ledger shipped with a NINTH row, scheduled-arm-health.yml, dated
# 2026-09-23 and annotated "EXPECTED TO GO STALE the moment the R3 wiring
# lands". Wiring it in the same commit made the guard print, against the real
# tree and with nobody asking it to:
#
#   STALE ROW   scheduled-arm-health.yml — the ledger records it as UNREAD, but
#               it now has a reader (R3). The world got better than the ledger;
#               delete the row.
#
# The row was deleted, which is what took the ledger from nine to eight. That
# is the ratchet's second arm firing on the real artifact rather than on a
# fixture, and it is the reason this file trusts the arm at all.
#
# THE RATCHET HAS TWO FAILURE DIRECTIONS AND BOTH ARE RED. The second and third
# arms fire when the world gets BETTER than the ledger's record of it. That is
# deliberate: a ledger row that has quietly become false is how a guard's
# population rots downward until it measures nothing, and "delete the row" is a
# one-line fix the red names precisely.
#
# WHAT THIS GUARD DOES **NOT** CATCH, stated rather than discovered later:
#   · It is a CONFIGURATION guard. It reads the workflow tree, touches no
#     network, and asks whether a reader is DECLARED. It cannot tell you that
#     main-red-owner's hourly cron is itself being delivered (cron-overdue-probe
#     asks that), nor whether an issue it filed was ever opened by a human.
#     FILED IS NOT ROUTED — file-ci-failure-issue.sh's own header says the repo
#     reads UNSUBSCRIBED, so an unassigned issue reaches nobody. A green here
#     means "a declared path to a human exists", never "a human was reached".
#   · It says NOTHING about whether the cron dispatched or what it concluded.
#     Those are the other two instruments' questions and this file does not
#     re-ask them.
#   · R2 is scored from the workflow FILE. If branch protection, repo settings
#     or a disabled workflow stop main runs from happening, the push arm is
#     still declared and this guard still scores it READ.
#   · A ledger row's PROSE is not checked against anything. The dates and
#     reasons below are a human record; only the workflow names are mechanical.
#   · GitHub disables scheduled workflows after 60 days of repo inactivity.
#     Nothing here notices that.
#
# USAGE
#   bash scripts/cron-scream-coverage.sh              # report the verdict
#   bash scripts/cron-scream-coverage.sh --list       # print the full matrix
#   bash scripts/cron-scream-coverage.sh --selftest   # verdict + mutation arms
#   bash scripts/cron-scream-coverage.sh --workflows <dir> --ledger <file>
#
# EXIT CODES
#   0  every cron'd workflow is READ, or is UNREAD with a matching ledger row
#   1  a NEW UNREAD workflow, or a STALE/GONE ledger row
#   2  REFUSAL — the workflow dir is missing, or ZERO cron'd workflows were
#      found. A clean census over an empty corpus is never reported as health.
#   3  a --selftest mutation arm did not behave, i.e. this instrument can no
#      longer report. DISTINCT from 1 so "the guard is broken" can never be
#      read as "the tree is clean".

set -u

WF_DIR=".github/workflows"
LEDGER_FILE=""
MODE=report

# ── THE LEDGER ───────────────────────────────────────────────────────────────
# file|dated disposition. Eight rows, measured on origin/main d4e2557b0,
# 2026-09-23, task-e6fe244ece2b5d27.
DEFAULT_LEDGER='absent-context-census.yml|2026-09-23: schedule-only BY A COMMITTED TEST — absent-context-census.test.sh §7 asserts this workflow is schedule-only, so R2 is forbidden here, not merely absent. Its own hermetic mutation suite runs as step one of every run, so an instrument that has lost the ability to report says so before its verdict is believed. R3 is the open remedy and is a one-step change.
chronicle-paper.yml|2026-09-23: nightly narrative digest, report class. Carries a pull_request arm, which is NOT a reader of a scheduled red (see the predicate above) — this row exists so that fact is recorded rather than mistaken for coverage. A late or failed chronicle costs one night of prose and gates nothing.
elixir-nightly.yml|2026-09-23: the long Elixir suite, nightly, report class. The HIGHEST-VALUE row in this ledger: its red means the Elixir test suite is broken in a way the per-PR matrix does not run, and today that reaches nobody at all. R3 is the remedy. Not taken in this change because this lane fences .github/workflows/** + scripts/** and the disposition deserves its own PR against a measured run history.
landed-open-report.yml|2026-09-23: daily ledger digest. Its own header states a red here means THE READ FAILED and that findings exit 0 into the step summary, and it deliberately carries no push arm so it renders no check run anywhere. Accepted UNREAD: the digest is a convenience, and the ledger it reports on is queryable directly with bp.
pds-scratch-round-trip.yml|2026-09-23: daily boot/verify/teardown of the PDS scratch target. Schedule + workflow_dispatch ONLY and its header measures the run at >10 min (two full compiles), calling a per-PR venue a WRONG build. So R2 is deliberately absent; R3 would be the right reader and is not yet wired.
release-curator-draft.yml|2026-09-23: daily scan that opens or refreshes ONE draft GitHub Release for a human to bless. Schedule + workflow_dispatch by design (its header rules out a push arm as noise that would make the draft chase main). The draft is a standing invitation, not a safety net; a failed refresh costs a day.
weekly-changelog.yml|2026-09-23: weekly changelog digest, report class. Carries a pull_request arm (not a reader of a scheduled red). A missed week costs a changelog entry and gates nothing.'

usage() { sed -n '2,150p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --workflows) WF_DIR="$2"; shift 2 ;;
    --ledger)    LEDGER_FILE="$2"; shift 2 ;;
    --list)      MODE=list; shift ;;
    --selftest)  MODE=selftest; shift ;;
    -h|--help)   usage ;;
    *) echo "cron-scream-coverage: unknown argument '$1'" >&2; usage ;;
  esac
done

ledger() {
  if [ -n "$LEDGER_FILE" ]; then cat "$LEDGER_FILE"; else printf '%s\n' "$DEFAULT_LEDGER"; fi
}

# ── DETECTORS ────────────────────────────────────────────────────────────────

declares_cron() { grep -qE '^[[:space:]]*-[[:space:]]*cron:' "$1"; }

# R2 — a BRANCH-DRIVEN push arm. A tags-only push arm is structurally incapable
# of a main run, so it enrols the file in main-red-predicate.sh's population
# only to be reported N/A there; it is not a reader. Same partition that file
# uses, so the two instruments cannot disagree about who is enrolled.
has_r2() {
  grep -qE '^[[:space:]]*push:' "$1" || return 1
  python3 - "$1" <<'PYEOF'
import sys, re
lines = open(sys.argv[1], encoding="utf-8", errors="replace").read().split("\n")
pi = next((i for i, l in enumerate(lines) if re.match(r"^\s*push:\s*(#.*)?$", l)), None)
if pi is None:
    sys.exit(0)          # `push:` with an inline value; treat as branch-driven
ind = len(lines[pi]) - len(lines[pi].lstrip())
keys = set()
for l in lines[pi + 1:]:
    if not l.strip() or l.lstrip().startswith("#"):
        continue
    if len(l) - len(l.lstrip()) <= ind:
        break
    if ":" in l:
        keys.add(l.strip().split(":")[0])
# tags-only -> NOT branch-driven -> not a reader
sys.exit(1 if ("tags" in keys and not {"branches", "branches-ignore"} & keys) else 0)
PYEOF
}

# R3 — an INVOCATION of the notifier, never a mention of its path. See the
# required-checks-drift.yml `paths:`-list specimen in the header.
has_r3() { grep -qE 'bash[[:space:]]+[^[:space:]]*file-ci-failure-issue\.sh' "$1"; }

# ── THE CENSUS ───────────────────────────────────────────────────────────────
# Emits one `<file>\t<READ|UNREAD>\t<mechanisms>` row per cron'd workflow.
census() {
  local dir="$1" f b r2 r3 mech
  [ -d "$dir" ] || { echo "cron-scream-coverage: REFUSING — no such workflows dir: $dir" >&2; return 2; }
  local n=0
  # `find` rather than a glob: a glob that matches nothing behaves differently
  # under bash nullglob and zsh, and this file is run by both.
  local list
  list="$(find "$dir" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null | LC_ALL=C sort)"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    declares_cron "$f" || continue
    n=$((n + 1))
    b="$(basename "$f")"
    r2=0; r3=0
    has_r2 "$f" && r2=1
    has_r3 "$f" && r3=1
    mech=""
    [ "$r2" = 1 ] && mech="R2"
    [ "$r3" = 1 ] && mech="${mech:+$mech,}R3"
    if [ -z "$mech" ]; then
      printf '%s\tUNREAD\t-\n' "$b"
    else
      printf '%s\tREAD\t%s\n' "$b" "$mech"
    fi
  done <<EOF
$list
EOF
  # ZERO IS A REFUSAL, NEVER A PASS. An empty corpus reported clean is the
  # shape this whole tree keeps re-learning: an absence is not caught by
  # reading the result, only by a control on the population.
  if [ "$n" -eq 0 ]; then
    echo "cron-scream-coverage: REFUSING — ZERO cron-declaring workflows under $dir. A clean census over an empty corpus is not a clean census." >&2
    return 2
  fi
  return 0
}

report() {
  local rows rc=0 b state mech line led_names row_names
  rows="$(census "$WF_DIR")" || return $?

  led_names="$(ledger | awk -F'|' 'NF{print $1}' | LC_ALL=C sort -u)"
  row_names="$(printf '%s\n' "$rows" | awk -F'\t' '{print $1}' | LC_ALL=C sort -u)"

  local total read_n unread_n
  total="$(printf '%s\n' "$rows" | grep -c . || true)"
  read_n="$(printf '%s\n' "$rows" | awk -F'\t' '$2=="READ"' | grep -c . || true)"
  unread_n="$(printf '%s\n' "$rows" | awk -F'\t' '$2=="UNREAD"' | grep -c . || true)"

  echo "cron-scream-coverage: $total cron-declaring workflow(s) under $WF_DIR — READ $read_n, UNREAD $unread_n"

  # THE CONTROL ON THE PREDICATE ITSELF. A detector that scores every row the
  # same way discriminates nothing, and a uniform verdict is the signature of a
  # broken instrument rather than of a uniform world. Both classes must be
  # non-empty or this file refuses to render a verdict at all.
  if [ "$read_n" -eq 0 ] || [ "$unread_n" -eq 0 ]; then
    echo "cron-scream-coverage: REFUSING — the predicate returned a UNIFORM verdict ($read_n READ / $unread_n UNREAD). One class empty means the detector, not the tree, is what changed." >&2
    return 2
  fi

  if [ "$MODE" = list ]; then
    printf '%s\n' "$rows" | while IFS="$(printf '\t')" read -r b state mech; do
      printf '  %-8s %-42s %s\n' "$state" "$b" "$mech"
    done
  fi

  # ARM 1 — a NEW UNREAD workflow with no ledger row.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    b="${line%%	*}"
    case "$(printf '%s\n' "$led_names" | grep -Fx "$b" || true)" in
      "") echo "  NEW UNREAD  $b — declares a cron, and its red reaches NO declared reader (no branch-driven push: arm, no file-ci-failure-issue.sh invocation). Wire one, or add a dated row to the ledger in scripts/cron-scream-coverage.sh."
          rc=1 ;;
    esac
  done <<EOF
$(printf '%s\n' "$rows" | awk -F'\t' '$2=="UNREAD"{print $1}')
EOF

  # ARM 2/3 — the ratchet's other direction: a ledger row that is no longer true.
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    if ! printf '%s\n' "$row_names" | grep -Fxq "$b"; then
      echo "  GONE ROW    $b — the ledger lists it, but it declares no cron in $WF_DIR (or the file is gone). Delete the row."
      rc=1
      continue
    fi
    state="$(printf '%s\n' "$rows" | awk -F'\t' -v n="$b" '$1==n{print $2}')"
    if [ "$state" = "READ" ]; then
      mech="$(printf '%s\n' "$rows" | awk -F'\t' -v n="$b" '$1==n{print $3}')"
      echo "  STALE ROW   $b — the ledger records it as UNREAD, but it now has a reader ($mech). The world got better than the ledger; delete the row."
      rc=1
    fi
  done <<EOF
$led_names
EOF

  if [ "$rc" = 0 ]; then
    echo "OK — every cron'd workflow either reaches a declared reader or carries a dated ledger row."
  else
    echo "::error::cron-scream-coverage: a cron'd workflow's red reaches nobody, or the ledger no longer describes the tree."
  fi
  return $rc
}

# ── SELFTEST ─────────────────────────────────────────────────────────────────
# ONE DERIVATION, BOTH DIRECTIONS. The real-tree verdict is produced HERE, so
# this is the verdict and not a proof-of-proof; the mutation arms then run the
# SAME code over a scratch copy of the real tree.
# The scratch root is a GLOBAL, not a `local`. An EXIT trap fires in the shell's
# top-level scope where a function-local is already out of scope, so
# `trap 'rm -rf "$tmp"' EXIT` over a local printed `tmp: unbound variable` under
# `set -u` AFTER the verdict line — a cleanup that never ran, reported nowhere.
SCRATCH=""
cleanup() { [ -n "${SCRATCH:-}" ] && rm -rf "$SCRATCH"; return 0; }

selftest() {
  local pass=0 fail=0 out rc tmp
  SCRATCH="$(mktemp -d)"; tmp="$SCRATCH"
  trap cleanup EXIT

  echo "── cron-scream-coverage --selftest ──"

  # The real verdict first. A mutation suite that never asks the real question
  # is a fixture talking to itself.
  echo "[real tree]"
  out="$(report)"; rc=$?
  printf '%s\n' "$out"
  if [ "$rc" = 0 ]; then
    pass=$((pass + 1)); echo "  ok   c0 the real tree passes"
  else
    fail=$((fail + 1)); echo "  FAIL c0 the real tree does NOT pass (rc=$rc) — see the verdict above"
  fi

  # A scratch copy of the REAL workflow tree. Mutations are applied to the copy.
  cp -R "$WF_DIR" "$tmp/wf"
  local led="$tmp/ledger"; ledger > "$led"

  # ── c1 — STRIP A READER, THE GUARD MUST RED BY NAME ────────────────────────
  # Subject: a workflow that is READ by R2 ALONE (so removing the push arm
  # leaves it genuinely unread) and is NOT in the ledger. Chosen from the live
  # census rather than hard-coded: a hard-coded name is a snapshot that rots.
  local victim
  victim="$(census "$tmp/wf" | awk -F'\t' '$2=="READ" && $3=="R2"{print $1}' \
            | while IFS= read -r c; do
                printf '%s\n' "$(ledger | awk -F'|' 'NF{print $1}')" | grep -Fxq "$c" || { printf '%s\n' "$c"; break; }
              done | head -1)"
  if [ -z "$victim" ]; then
    fail=$((fail + 1)); echo "  FAIL c1 no R2-only, unledgered workflow to mutate — the arm measured nothing"
  else
    # Comment out the `push:` key and every line indented under it. Blunt and
    # sufficient: the detector's question is whether a branch-driven push arm
    # is declared.
    python3 - "$tmp/wf/$victim" <<'PYEOF'
import sys, re
p = sys.argv[1]
lines = open(p, encoding="utf-8").read().split("\n")
pi = next((i for i, l in enumerate(lines) if re.match(r"^\s*push:\s*(#.*)?$", l)), None)
if pi is not None:
    ind = len(lines[pi]) - len(lines[pi].lstrip())
    lines[pi] = "#MUT " + lines[pi]
    for j in range(pi + 1, len(lines)):
        l = lines[j]
        if not l.strip():
            continue
        if len(l) - len(l.lstrip()) <= ind:
            break
        lines[j] = "#MUT " + l
open(p, "w", encoding="utf-8").write("\n".join(lines))
PYEOF
    rc=0; out="$(WF_DIR="$tmp/wf" LEDGER_FILE="$led" report 2>&1)" || rc=$?
    case "$out" in
      *"NEW UNREAD  $victim"*)
        if [ "$rc" = 1 ]; then
          pass=$((pass + 1)); echo "  ok   c1 stripping $victim's push arm reds BY NAME (rc=1)"
        else
          fail=$((fail + 1)); echo "  FAIL c1 named $victim but exited $rc, expected 1"
        fi ;;
      *) fail=$((fail + 1)); echo "  FAIL c1 stripping $victim's push arm did NOT red by name (rc=$rc)"; printf '%s\n' "$out" ;;
    esac

    # ── c2 — RESTORE, THE GUARD MUST GO GREEN ────────────────────────────────
    cp "$WF_DIR/$victim" "$tmp/wf/$victim"
    rc=0; out="$(WF_DIR="$tmp/wf" LEDGER_FILE="$led" report 2>&1)" || rc=$?
    if [ "$rc" = 0 ]; then
      pass=$((pass + 1)); echo "  ok   c2 restoring $victim's push arm goes green (rc=0)"
    else
      fail=$((fail + 1)); echo "  FAIL c2 restored tree still exits $rc"; printf '%s\n' "$out"
    fi
  fi

  # ── c3 — A BRAND-NEW UNREAD CRON'D WORKFLOW REDS BY NAME ───────────────────
  # The arm that matters for the future: the guard's job is to refuse the NEXT
  # one, not to describe today's eight.
  cat > "$tmp/wf/zz-mutant-probe.yml" <<'YEOF'
name: zz-mutant-probe
on:
  schedule:
    - cron: "0 4 * * *"
jobs:
  probe:
    runs-on: ubuntu-latest
    steps:
      - run: echo probe
YEOF
  rc=0; out="$(WF_DIR="$tmp/wf" LEDGER_FILE="$led" report 2>&1)" || rc=$?
  case "$out" in
    *"NEW UNREAD  zz-mutant-probe.yml"*)
      if [ "$rc" = 1 ]; then
        pass=$((pass + 1)); echo "  ok   c3 a new unread cron'd workflow reds BY NAME (rc=1)"
      else
        fail=$((fail + 1)); echo "  FAIL c3 named the mutant but exited $rc"
      fi ;;
    *) fail=$((fail + 1)); echo "  FAIL c3 a new unread cron'd workflow did not red by name (rc=$rc)"; printf '%s\n' "$out" ;;
  esac

  # ── c3b — THE SAME MUTANT WITH A READER IS ACCEPTED ────────────────────────
  # The control on c3. Without it, c3 passes even if the guard reds on EVERY
  # new workflow, which would discriminate nothing.
  rm -f "$tmp/wf/zz-mutant-probe.yml"
  cat > "$tmp/wf/zz-mutant-probe.yml" <<'YEOF'
name: zz-mutant-probe
on:
  schedule:
    - cron: "0 4 * * *"
  push:
    branches: [main]
jobs:
  probe:
    runs-on: ubuntu-latest
    steps:
      - run: echo probe
YEOF
  rc=0; out="$(WF_DIR="$tmp/wf" LEDGER_FILE="$led" report 2>&1)" || rc=$?
  if [ "$rc" = 0 ]; then
    pass=$((pass + 1)); echo "  ok   c3b the SAME mutant carrying a push arm is accepted (rc=0) — the guard reds on the absence of a reader, not on novelty"
  else
    fail=$((fail + 1)); echo "  FAIL c3b a readered mutant still reds (rc=$rc)"; printf '%s\n' "$out"
  fi
  rm -f "$tmp/wf/zz-mutant-probe.yml"

  # ── c4 — THE RATCHET'S OTHER DIRECTION: A LEDGER ROW GOES STALE ────────────
  local lrow
  lrow="$(ledger | awk -F'|' 'NF{print $1}' | head -1)"
  cp "$WF_DIR/$lrow" "$tmp/wf/$lrow" 2>/dev/null || true
  python3 - "$tmp/wf/$lrow" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
s = s.replace("\njobs:\n", "\n  push:\n    branches: [main]\n\njobs:\n", 1)
open(p, "w", encoding="utf-8").write(s)
PYEOF
  rc=0; out="$(WF_DIR="$tmp/wf" LEDGER_FILE="$led" report 2>&1)" || rc=$?
  case "$out" in
    *"STALE ROW   $lrow"*)
      if [ "$rc" = 1 ]; then
        pass=$((pass + 1)); echo "  ok   c4 a ledger row whose workflow GAINED a reader reds BY NAME (rc=1) — the ratchet fires in the healthy direction too"
      else
        fail=$((fail + 1)); echo "  FAIL c4 named the stale row but exited $rc"
      fi ;;
    *) fail=$((fail + 1)); echo "  FAIL c4 a stale ledger row did not red by name (rc=$rc)"; printf '%s\n' "$out" ;;
  esac
  cp "$WF_DIR/$lrow" "$tmp/wf/$lrow"

  # ── c5 — A GONE LEDGER ROW REDS ────────────────────────────────────────────
  out="$(WF_DIR="$tmp/wf" LEDGER_FILE="$tmp/led-gone" report 2>&1)"; rc=0
  printf 'zz-not-a-workflow.yml|fixture row naming a file that does not exist\n' > "$tmp/led-gone"
  out="$(WF_DIR="$tmp/wf" LEDGER_FILE="$tmp/led-gone" report 2>&1)" || rc=$?
  case "$out" in
    *"GONE ROW    zz-not-a-workflow.yml"*)
      pass=$((pass + 1)); echo "  ok   c5 a ledger row naming a non-cron'd/absent file reds BY NAME" ;;
    *) fail=$((fail + 1)); echo "  FAIL c5 a gone ledger row did not red by name (rc=$rc)"; printf '%s\n' "$out" ;;
  esac

  # ── c6 — AN EMPTY CORPUS REFUSES (exit 2), NEVER PASSES ────────────────────
  mkdir -p "$tmp/empty"
  rc=0; out="$(WF_DIR="$tmp/empty" LEDGER_FILE="$led" report 2>&1)" || rc=$?
  if [ "$rc" = 2 ]; then
    pass=$((pass + 1)); echo "  ok   c6 a workflow dir with ZERO cron'd workflows REFUSES (rc=2), never reports health"
  else
    fail=$((fail + 1)); echo "  FAIL c6 an empty corpus exited $rc, expected 2"
  fi

  # ── c7 — THE MENTION-vs-INVOCATION DISCRIMINATION ─────────────────────────
  # The detector trap this file's header names. A paths-list entry naming the
  # notifier must NOT score as a reader.
  mkdir -p "$tmp/wf3"
  cat > "$tmp/wf3/a-mention.yml" <<'YEOF'
name: a-mention
on:
  schedule:
    - cron: "0 4 * * *"
  pull_request:
    paths:
      - "scripts/file-ci-failure-issue.sh"
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
YEOF
  cat > "$tmp/wf3/b-invocation.yml" <<'YEOF'
name: b-invocation
on:
  schedule:
    - cron: "0 4 * * *"
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: bash scripts/file-ci-failure-issue.sh
YEOF
  local m_state i_state
  m_state="$(census "$tmp/wf3" | awk -F'\t' '$1=="a-mention.yml"{print $2}')"
  i_state="$(census "$tmp/wf3" | awk -F'\t' '$1=="b-invocation.yml"{print $2}')"
  if [ "$m_state" = "UNREAD" ] && [ "$i_state" = "READ" ]; then
    pass=$((pass + 1)); echo "  ok   c7 a paths-list MENTION of the notifier scores UNREAD; an INVOCATION scores READ"
  else
    fail=$((fail + 1)); echo "  FAIL c7 mention=$m_state invocation=$i_state (expected UNREAD/READ)"
  fi

  # ── c8 — A TAGS-ONLY PUSH ARM IS NOT A READER ──────────────────────────────
  mkdir -p "$tmp/wf4"
  cat > "$tmp/wf4/tags-only.yml" <<'YEOF'
name: tags-only
on:
  schedule:
    - cron: "0 4 * * *"
  push:
    tags:
      - "v*"
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
YEOF
  cat > "$tmp/wf4/branchy.yml" <<'YEOF'
name: branchy
on:
  schedule:
    - cron: "0 4 * * *"
  push:
    branches: [main]
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
YEOF
  local t_state br_state
  t_state="$(census "$tmp/wf4" | awk -F'\t' '$1=="tags-only.yml"{print $2}')"
  br_state="$(census "$tmp/wf4" | awk -F'\t' '$1=="branchy.yml"{print $2}')"
  if [ "$t_state" = "UNREAD" ] && [ "$br_state" = "READ" ]; then
    pass=$((pass + 1)); echo "  ok   c8 a TAGS-ONLY push arm scores UNREAD (it cannot produce a main run); a branches arm scores READ"
  else
    fail=$((fail + 1)); echo "  FAIL c8 tags-only=$t_state branchy=$br_state (expected UNREAD/READ)"
  fi

  echo "── selftest: $pass passed, $fail failed ──"
  [ "$fail" -eq 0 ] || return 3
  return 0
}

case "$MODE" in
  selftest) selftest ;;
  *)        report ;;
esac
