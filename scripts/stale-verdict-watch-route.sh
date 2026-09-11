#!/usr/bin/env bash
# stale-verdict-watch-route.sh — turn scripts/stale-verdict-watch.sh's rc into A
# JOB'S verdict, so that "a conflicted PR is asserting a stale green" and "this
# watch could not look" red under DIFFERENT check-run names.
#
# WHY THIS FILE EXISTS (task-bc902e08cdfd2ee7)
#
# stale-verdict-watch.sh defines ten outcomes. Until this split, .github/
# workflows/stale-verdict-watch.yml mapped EIGHT of them — 1, 3, 4, 5, 6, 7, 9
# and the undefined catch-all — to `exit 1` inside ONE step of ONE job named
# `Stale verdict watch`. So these two rendered identically:
#
#   rc 1  a CONFLICTING pull request is asserting a green required verdict main
#         has moved past. The watch LOOKED and found a real stale green. Remedy:
#         rebase or close a NAMED pull request, now.
#   rc 6  UNREACHABLE — the pull-request list could not be read at all. The watch
#         could not look. Remedy: nothing; the next scheduled run clears it, and
#         only a 6 that PERSISTS is anybody's work.
#
# MEASURED, not assumed: run 34589487018 (2026-09-11T10:29:43Z, main) emitted
# "UNREACHABLE — the pull-request list could not be read after 3 attempt(s), so
# this run classified nothing", exited 6, and appears in `gh run list --workflow
# stale-verdict-watch.yml --branch main` as the name `Stale verdict watch` with
# conclusion `failure` — character for character what an rc-1 CONFLICTING
# verdict produces. An operator reading the run list could not tell "go fix a
# pull request" from "wait 30 minutes" without opening the log.
#
# The split is a JOB split, never a `|| true`: a watch that could not look must
# never report success. On a read fault the WORKFLOW RUN still fails — the fault
# job carries the red — and the `Stale verdict watch` job is SKIPPED rather than
# green, because "this run has no population" must not render as "no pull
# request is asserting a stale green".
#
# WHY A SCRIPT AND NOT A `case` INLINE IN THE YAML
#
# A routing table living in a `run:` block cannot be driven by a harness: you
# cannot force rc=6 and rc=1 on a YAML expression without GitHub. Here both jobs
# shell THIS file, and scripts/stale-verdict-watch.test.sh §(m) runs it once per
# (role, rc) pair and asserts exactly which role reds — the forced-both-ways
# proof, offline, with no GitHub in the loop.
#
# CONTRACT
#   stale-verdict-watch-route.sh fault   <rc>   # the read-fault job's classifier
#   stale-verdict-watch-route.sh verdict <rc>   # the staleness job's classifier
#
#   THE READ-FAULT SET is 3 4 5 6 7 — and 9. Every one of them is a run that
#   holds NO verdict about the pull requests: 3 could not read the spec or the
#   list, 4 read the payload and could not compute from it, 5 read the
#   population and classified not one row, 6 never read the list at all, 7 read
#   the list and not main's history, 9 refused before issuing a rollup budget it
#   could not afford. None of them names a pull request a human must go touch.
#
#   THE VERDICT SET is 0 1 2 8 — every run that DID look. 0 clean, 1 a novel
#   stale green (RED), 2 partial coverage (warning, not a green claim about the
#   unread rows), 8 BASELINE DRIFT (the pin outlived the debt; the remedy is to
#   delete a line from scripts/stale-verdict-watch.baseline, which is the
#   opposite of 1's remedy and so gets its own sentence rather than the old
#   "not a verdict it defines" catch-all).
#
#   role=fault:   a read-fault rc -> exit 1 with that class's sentence.
#                 A verdict rc -> exit 0: the read had a population, and whether
#                 a stale green is in it is the sibling job's subject.
#                 Any other rc -> exit 1: an rc stale-verdict-watch.sh does not
#                 define is a fault OF THE INSTRUMENT, which is this job's.
#   role=verdict: 0 -> exit 0 · 1 -> exit 1 · 2 -> exit 0 (warning) ·
#                 8 -> exit 1 (BASELINE DRIFT).
#                 A read-fault rc -> exit 1 as a ROUTING ERROR: the workflow's
#                 job-level `if:` is supposed to SKIP this job on one, so
#                 reaching here means the wiring drifted. It reds rather than
#                 guessing.
#                 Empty/undefined rc -> exit 1 CANNOT READ, never a silent 0.
#
# bash 3.2 compatible (macOS system bash): no `${var@Q}`, no associative arrays.
set -uo pipefail

usage() {
  echo "usage: stale-verdict-watch-route.sh <fault|verdict> <rc>" >&2
  echo "  rc is scripts/stale-verdict-watch.sh's exit code; see its EXIT CODES header" >&2
}

if [ "$#" -ne 2 ]; then
  echo "CANNOT READ: stale-verdict-watch-route.sh needs exactly two arguments, got $#" >&2
  usage
  exit 1
fi

role="$1"
rc="$2"

# An rc that is not a plain non-negative integer is never a verdict. `''` is the
# shape a missing `needs.<job>.outputs.rc` takes when the upstream job died
# before its step wrote GITHUB_OUTPUT — the one case where a blank must not read
# as a zero.
case "$rc" in
  ''|*[!0-9]*)
    echo "::error::CANNOT READ — stale-verdict-watch.sh's exit code did not reach this job (rc='$rc'). The upstream job died before it published one; this is not a verdict about the pull requests and is not a pass."
    exit 1
    ;;
esac

case "$role" in
  fault)
    case "$rc" in
      3)
        echo "::error::CONFIGURATION FAULT — this run's credential cannot read the pull-request list, or the required-check spec is unreadable. A watch that cannot read what it watches must not report success. THIS IS NOT A STATEMENT ABOUT ANY PULL REQUEST: the sibling check run 'Stale verdict watch' is SKIPPED for this run precisely because no population was adjudicated."
        exit 1
        ;;
      4)
        echo "::error::COMPUTE FAULT — the pull-request list WAS read and the verdict could not be computed from it (malformed payload, or jq could not run). This is not a credential fault: the read succeeded. See the byte count in the log above. No pull request is named by this red."
        exit 1
        ;;
      5)
        echo "::error::BLIND RUN — the pull-request list WAS read and NOT ONE row could be classified: every open row's mergeability was still UNKNOWN after re-polling, so this verdict covers zero pull requests. It is not a green, and this run fails rather than reporting one. GitHub computes mergeability lazily and invalidates it behind a merge, so this is usually TRANSIENT: the next scheduled run re-reads the population and clears this by itself, with nobody touching anything. A 5 that PERSISTS across runs means the read itself is broken — look at the poll budget and the token, not at the pull requests."
        exit 1
        ;;
      6)
        echo "::error::UNREACHABLE — the pull-request list could not be read after every attempt, so this run classified ZERO rows and does not know how many pull requests exist. This is not a green: no population was ever read. It is usually TRANSIENT (rate limit, or Actions transport) and the next scheduled run clears it by itself. A 6 that PERSISTS is the token or the poll budget, not the pull requests."
        exit 1
        ;;
      7)
        echo "::error::DISTANCE UNREADABLE — the pull requests WERE read and main's commit history was NOT, so no staleness distance exists this run and no row can be called stale or clean. This is not a credential fault on the pull-request read: that read worked. Look at the commits API, not at the PR list."
        exit 1
        ;;
      9)
        echo "::error::ROLLUP BUDGET EXCEEDED — more CONFLICTING pull requests need a status rollup than --rollup-max allows, so this run refused BEFORE issuing them rather than re-creating the timeout that made this watch blind. This is not a green and not a pass: the population was read, the conflicted set is too large to adjudicate within budget, and the log above names the count and the cap. REMEDY: drain the conflicted population, or raise --rollup-max deliberately with a measurement behind it."
        exit 1
        ;;
      0|1|2|8)
        echo "the watch looked (stale-verdict-watch.sh rc=$rc). Whether a conflicted pull request is asserting a stale green is the 'Stale verdict watch' check run's subject, not this one's."
        exit 0
        ;;
      *)
        echo "::error::INSTRUMENT FAULT — stale-verdict-watch.sh exited $rc, which is not one of the outcomes its EXIT CODES header defines. An undefined rc is a fault of the instrument, so it reds HERE and not on the sibling."
        exit 1
        ;;
    esac
    ;;
  verdict)
    case "$rc" in
      0)
        echo "no conflicted pull request is asserting a green required verdict the pinned baseline does not already cover."
        exit 0
        ;;
      1)
        echo "::error::A CONFLICTING pull request is asserting a green required verdict main has moved past. It re-dispatches nothing, so this cannot clear itself: rebase or close the PRs named above. This run fails, and it will keep failing every 30 minutes."
        exit 1
        ;;
      2)
        echo "::warning::rows were still mergeable=UNKNOWN after re-polling. That is a SILENCE, not a green — those rows are named in the log above and will be re-read on the next run."
        exit 0
        ;;
      8)
        echo "::error::BASELINE DRIFT — no novel row, and at least one PINNED entry in scripts/stale-verdict-watch.baseline is no longer reported. The debt shrank and the committed file did not. REMEDY: delete the healed line from the baseline. This is the OPPOSITE of the rc-1 remedy: nobody needs to touch a pull request."
        exit 1
        ;;
      3|4|5|6|7|9)
        echo "::error::ROUTING ERROR — rc=$rc is a READ FAULT and this job's \`if:\` is supposed to SKIP it on one, leaving the scream to the 'Stale verdict watch read fault' check run. Reaching here means .github/workflows/stale-verdict-watch.yml's job wiring drifted from scripts/stale-verdict-watch.test.sh section (m). Reds rather than reporting a verdict it does not have."
        exit 1
        ;;
      *)
        echo "::error::stale-verdict-watch.sh exited $rc, which is not a verdict it defines"
        exit 1
        ;;
    esac
    ;;
  *)
    echo "CANNOT READ: unknown role '$role' — expected 'fault' or 'verdict'" >&2
    usage
    exit 1
    ;;
esac
