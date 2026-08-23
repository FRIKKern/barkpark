#!/usr/bin/env bash
# crown-reconcile.sh — the crown stops self-certifying.
#
# WHAT WAS BROKEN
#
# Every verdict this repository produces about `platform_deliveries` is produced
# INSIDE the delivering run. `record-delivery` (deploy.yml) sets `delivered=true`
# from the rc of its own POST, and `report-recorder-failure` fires only when THAT
# run's POST failed. Both are structurally blind to the two shapes that matter:
#
#   * a run whose `if:` gated the recorder off — no POST, so no rc, so no scream
#   * a run that never reached the recorder job at all
#
# Both leave a DELIVERED SHA WITH NO ROW, and nothing anywhere says so. Measured
# 2026-08-09: barkpark.cloud was serving a95bc7ca9747cb3d90a361c4d54eb2c068a24e32
# and `GET /v1/deliveries?sha=a95bc7ca9…` answered `count: 0`. The crown had no
# record of the commit production was actually running.
#
# THIS SCRIPT IS THE FIRST THING IN THE REPO THAT READS THE ACTIONS API AND THE
# CROWN TOGETHER. It asks three questions and each one can lose:
#
#   BEHIND    a successful DELIVERING deploy.yml run in the window delivered a
#             head sha the crown has no row for. The run happened; the record
#             does not exist.
#   WRONG     a crown row inside the window was written by no successful
#             delivering run. The record exists; the run does not.
#   SERVING   the sha barkpark.cloud reports it is SERVING has no `cp` row. This
#             is the a95bc7ca9 case, and it is the sharpest of the three: the
#             box is running code the platform's own record has never heard of.
#
# WHY SHA-DRIVEN AND NOT WINDOW-DRIVEN
#
# `PlatformDelivery.list/1` accepts ONLY `:sha` and `:limit` (platform_delivery.ex)
# and `GET /v1/deliveries` passes through only those two (router.ex). "Rows over a
# pinned window" is NOT expressible today, and this slice adds no migration and no
# route change. So the runs drive: enumerate successful runs, then ask the crown
# one sha at a time. An unknown sha is an honest empty list, and that empty IS the
# BEHIND verdict.
#
# WHY DOCS-ONLY RUNS ARE NOT COUNTED
#
# deploy.yml's `changes` job path-filters, so a docs-only merge succeeds with BOTH
# deploy legs skipped — it delivered nothing and must produce no row. Counting it
# would manufacture a BEHIND on every docs merge and drown the real ones. A run is
# a DELIVERING run here only when its `control-plane` or `instance` job concluded
# `success`; that is read per run from the jobs API, never assumed.
#
# CARRIED ROWS ARE NOT WRONG. ~36% of merged shas have no run of their own and
# ride a later sha's range; the recorder marks those `carried: true`. A carried
# row naming a sha with no run of its own is CORRECT, so only NON-carried rows can
# be WRONG. A row whose `carried` is absent was never measured — it is printed as
# UNCLASSIFIED and is never counted clean.
#
# THE ALIBI IS `delivering_run_id`, NOT THE HEAD SHA (charter D496).
#
# This axis first alibied a non-carried row by looking for its sha among the
# delivering runs' HEAD shas, and that premise was inverted four minutes before
# this script merged: the recorder now writes the sha the BOX WAS SERVING as the
# primary `carried=false` row and stores the run's own trigger sha as `carried=true`.
# When a deploy's `git pull` races past its trigger sha — two merges 13s apart,
# coalesced into one run — the served sha structurally CANNOT appear in a set built
# from head shas, and a correct row was accused of being a ghost (measured live:
# `wrong=1/28` naming 8e83b709a, a row that was right).
#
# So a non-carried row is legitimate iff its `delivering_run_id` is in the
# delivering set — the recorder's own statement of which run wrote it, already on
# both read paths (PlatformDelivery.to_json/1 and the SQL fallback's SELECT above),
# so no migration and no route change. The head-sha comparison survives ONLY as the
# fallback for a row that carries no `delivering_run_id` at all, which is how rows
# written before that field existed are still judged rather than waved through.
#
# PREDATES-WRITER IS A NAMED CLASS, NOT A NARROWED WINDOW (charter D496).
#
# `record-delivery` — the only thing that writes `platform_deliveries` from inside
# a run — came into existence at RECORDER_BIRTH_ISO below (PR #11167, merge
# 67f4a6ab2). A delivering run created BEFORE that instant had nothing that could
# have recorded it, so calling it BEHIND is an accusation with no defendant. It is
# reported in its OWN class, with its own count and the birth instant printed, and
# it is excluded from the BEHIND denominator. It is deliberately NOT hidden by
# shrinking the window: an exemption has to be a printed denominator, never a
# quieter one. If EVERY delivering run in the window predates the writer there is
# no denominator left, and that is a warning (rc 2), never a green.
#
# CREDENTIALS: NONE ARE ADDED. Two read paths, in this order, and the one that
# answered is printed:
#
#   1. CROWN_API_TOKEN in the environment (a read-ability PAT) — the local /
#      operator path, used to prove this script on live data by hand.
#   2. CP_HOST + DEPLOY_SSH_KEY — the CI path, and the same one deploy.yml's
#      recorder already documents: SSH the control plane, discover the container
#      BY IMAGE TAG (never by name: blue/green renames it), read the token out of
#      the running container, issue the read from the box.
#
#      The route's reader tier is `require_user_or_pat` + `require_ability("read")`
#      while WORKER_TOKEN is the WORKER principal, so that GET can answer 401/403.
#      When it does, this falls back to reading `platform_deliveries` directly out
#      of the control plane's own postgres container — the same crown, the same
#      box, the same SSH, no new secret and no route change — and says out loud
#      which reader produced the answer. A read that cannot happen is rc 2, never
#      a green.
#
# AN EXPLICITLY-EMPTY PAT IS A CONFIGURATION FAULT, A MISSING ONE IS NOT
# (charter D530).
#
# A MISSING CROWN_API_TOKEN is the CI path: it falls through to the SSH reader
# above and returns 0, and making it fatal would break the only reader that
# actually runs on a schedule today. But `CROWN_API_TOKEN=` — the variable SET
# and EMPTY — is a different statement: a reader was explicitly asked for and is
# not there. Both printed `reader=ssh`, IDENTICALLY, so an operator who exported
# an empty token was silently downgraded to a reader they did not choose. Set
# but empty is now rc 3, with its own sentence; unset still falls through.
#
# WHICH READER ANSWERED IS A VERDICT FIELD, NOT A `note:` (charter D531).
#
# `reader=ssh` names the TRANSPORT. It does NOT say whether the rows came from
# `/v1/deliveries` or from the control plane's postgres container after a 401 to
# the WORKER principal — and a live run printed that downgrade TEN times, as a
# `note:` on stderr, behind a header that said only `reader=ssh`. The reader that
# ANSWERED is now counted per read and printed as its own line beside the
# verdict, and it rides the VERDICT sentence itself.
#
# A GRACE IS A DEFERRAL, SO IT MUST LEAVE A DEBT BEHIND (charter D511).
#
# The serving check grants a grace to a serving sha whose process is younger than
# SERVING_GRACE_SECONDS: a deploy may still be in flight and its recorder may not
# have posted yet. That grace used to persist NOTHING, and the check only ever
# reads the sha the box is serving RIGHT NOW, so the deferral had no deferred
# re-read. Measured 2026-08-09: 4c8314c94's deploy run 31316124617 was CANCELLED
# with zero jobs — no row could ever exist for it — yet barkpark.cloud served it
# 13:34Z–13:42Z. Four consecutive runs graced it (ages -3s / 53s / 105s / 200s),
# then the box moved to 02475d0ec and the accusation became UNMAKEABLE. Any sha
# replaced inside 1200s was structurally unaccusable, which at today's merge
# cadence is most of them.
#
# So a granted grace now writes `<sha> <first-seen-epoch>` to a RE-ASK LIST that
# survives the run (--state-file / CROWN_STATE_FILE; $WORK is rm -rf'd by the
# cleanup trap, so the list cannot live there). The boundary, stated explicitly:
#
#   * ENTERING the list: the ONLY writer is the serving grace. A sha the box
#     serves, with no `cp` row, whose process is younger than the grace.
#   * WHILE ON the list: every later run re-asks the crown about that sha,
#     WHETHER OR NOT the box still serves it. Still no row → GRACED-UNRECORDED,
#     exit 1. The grace is charged against FIRST-SEEN, not against process age,
#     so one sha gets ONE grace window of SERVING_GRACE_SECONDS in total and
#     never a fresh one per run.
#   * CLEAN RETIREMENT: a `cp` row appearing for that sha. That is the only exit
#     that means the system worked.
#   * DIRTY RETIREMENT: REASK_MAX_SECONDS with no row. The sha has already been
#     accused on every run in between, so ageing off ends an unbounded list
#     rather than forgiving anything — and it is printed as an unreadable
#     condition, never as silence.
#   * NO LIST AT ALL (nothing carries the state file between runs): the re-read
#     degrades to within-run only. That is a real hole, and it is the workflow's
#     job to point CROWN_STATE_FILE at a path that persists.
#
# THE RE-ASK LIST STATES ITSELF, BECAUSE AN ABSENT LIST LOOKED EXACTLY LIKE AN
# EMPTY ONE (charter D533).
#
# `state_load` used to open with `[ -f "$STATE_FILE" ] || return 0` — a bare
# silent early return — and the workflow set CROWN_STATE_FILE NOWHERE, so every
# scheduled run wrote the list to a fresh ubuntu-latest VM that was then
# destroyed. GRACED-UNRECORDED was STRUCTURALLY UNABLE TO FIRE in production,
# and nothing said so: measured 2026-08-09 on this script's own base fixture, an
# ABSENT state file and a PRESENT-but-header-only one produced output with the
# SAME md5 (4b4399a7f447f078b11943d574892e3e), both ending in `RECONCILED: …
# and no earlier grace is still owed a row` — an ASSERTION about a memory the
# run did not have.
#
# So the list now states itself on EVERY run, in ONE line, over four states:
#
#   UNCONFIGURED   no path at all → already a reason(), so rc 2. Unchanged.
#   ABSENT         a path, no file. A REASON: the memory was DESTROYED between
#                  runs, and a grace granted on a previous run cannot be
#                  re-asked. NOT counted clean.
#   ABSENT-FIRST-RUN
#                  a path, no file, and the CALLER has PROVEN the persistent
#                  store has never held a list (CROWN_STATE_FIRST_RUN=1). There
#                  is no memory to have lost, so there is nothing to re-ask and
#                  nothing to accuse. NOT a fault. See below — this claim is the
#                  caller's, and only a caller that actually looked may make it.
#   PRESENT-EMPTY  the file exists and holds nothing. NOT a fault — it is the
#                  affirmative statement that nothing is owed.
#   PRESENT        N entries loaded.
#
# A FIRST RUN IS NOT A DESTROYED MEMORY, AND ONLY THE CALLER CAN TELL THEM APART
# (charter D545).
#
# This script sees exactly one thing: a local path with no file behind it. That
# byte-identical absence is produced by THREE different worlds — the store has
# never been written (a genuine first run), the store was written and then lost,
# and the transport that would have fetched it failed. Calling all three
# DESTROYED pages on the first run past every harness fix, by construction, over
# a file that has never existed; calling all three FIRST RUN launders the two
# that matter. Neither reading is available from here.
#
# The caller CAN tell them apart, because the caller holds the store. So the
# statement is the caller's and it is explicit: CROWN_STATE_FIRST_RUN=1 means
# "I reached the persistent store, and it holds no list yet". The workflow sets
# it ONLY from a remote existence test that SUCCEEDED — a fetch that failed
# leaves it unset, so transport silence still lands in ABSENT and still pages.
#
# A GRACE IS A DEFERRAL, AND A DEFERRAL IS NOT A SILENCE (charter D545).
#
# rc 2 used to mean four unrelated things at once: an empty population, a window
# whose every run predates the recorder, a genuine unreadable condition — and the
# SERVING GRACE, whose own printed sentence calls itself a DEFERRAL. Measured
# over crown-reconcile.yml's entire history: rc=2 fired SIX times, FIVE of them
# the benign in-flight grace (four of those the same sha in four consecutive
# minutes) and ZERO of them a real crown mismatch. An alarm that is wrong five
# times in six gets muted, and a muted alarm is a dead gate.
#
# So the grace no longer sets UNREADABLE. It goes through defer(), which counts
# and names it exactly as reason() does but keeps it out of the silence, and it
# exits 4 — NOT YET DUE — which the workflow renders as a ::warning and a green
# step. NOTHING IS FORGIVEN BY THIS: the grace still writes the sha to the
# re-ask list, and the next run that still finds no row fires GRACED-UNRECORDED
# and exits 1. The accusation is deferred by one run, which is what "deferred"
# has always meant here. An unreadable condition in the SAME run still wins: 2
# is checked before 4, so a deferral can never launder a silence.
#
# and `state_save` closes symmetrically with `wrote M entry(ies)`. `wrote M>0`
# followed by the next run's `loaded 0` is the eviction signature, readable with
# no new instrument. D (dropped) is counted SEPARATELY from N so a corrupted
# list cannot masquerade as a short one.
#
# WHERE THE LIST LIVES IS THE WORKFLOW'S DECISION, AND IT IS NOT actions/cache.
# `actions/cache` evicts after 7 days SILENTLY, and a cache miss is
# indistinguishable from an empty list — which is the exact defect above. The
# workflow instead fetches and writes the list back over the SSH it already
# holds, to /var/lib/crown-reconcile/ on CP_HOST, and names that location to
# this script through CROWN_STATE_STORAGE so the printed line says WHERE the
# memory was supposed to be, not just which local path was read.
#
# WHY A CLOCK IN THE FUTURE IS A FAULT AND NOT A KINDNESS
#
# `age` used to be an unguarded subtraction, so run 31316144030 printed "only -3s
# old" and granted the grace. A serving_since AHEAD of now means the two clocks
# disagree, and a guard that reads a disagreement as "probably in flight" has
# chosen the comforting direction. A negative age is now its own printed fault
# and the missing row is accused, not excused.
#
# THE SILENCE NAMES ITSELF
#
# Every `UNREADABLE=1` site goes through reason(), which both warns and appends
# to a list the exit-2 sentence enumerates. It previously printed three counters
# for eight sites — all four graced runs above printed `0 sha(s) unreadable, 0
# run(s) with no job list, 0 row(s) with carried never measured` while exiting 2.
# The reason for the silence must be inside the sentence that announces it.
#
# AN EMPTY WINDOW ON A VERIFIED CROWN IS A DEFERRAL, NOT A PAGE (charter D597).
#
# The empty-population arm used to exit 2 unconditionally, and rc 2 pages. A
# repo that simply stops merging for a day empties the 24h window BY
# CONSTRUCTION, so the reconciler reds every 6 hours forever: measured
# 2026-08-15T18:28Z..08-17, SIX consecutive scheduled runs, every one "COULD
# NOT VERIFY: the population was EMPTY", #11217 at 41 comments. An alarm that
# pages on quiescence is the rc-4 lesson again — paging here is what mutes the
# alarm for the one case that is not.
#
# So an empty window may read GREEN — as a NAMED deferral (QUIET WINDOW), with
# its own ::warning, never as RECONCILED — and ONLY when ALL THREE hold:
#
#   (1) the serving-sha check RAN and VERIFIED that the sha the box is serving
#       has its cp row — production runs a commit the record knows;
#   (2) the re-ask list was PRESENT-EMPTY — read, and affirmatively owing
#       nothing. A graced deferral still owed a row must NOT go green, and a
#       list that is ABSENT or unread proves nothing;
#   (3) ZERO ledger rows sit inside the window. Rows-exist-but-no-runs STAYS
#       rc 2: a row with no run is an accusation source, not quiescence.
#
# Any OTHER silence still outranks quiescence: the only reason() the arm
# tolerates is the reverse direction's own no-alibi refusal, which an empty
# window fires by construction — and that refusal line is printed INSIDE the
# deferral text, because quiescence-green must not imply the reverse direction
# was checked.
#
# STATED RESIDUAL, not code: a repo quiet for 60 days trips GitHub's
# scheduled-workflow auto-disable, and a quiescence-green run produces no
# failure heartbeat that would notice the schedule going dark.
#
# EXIT CODES  0 = reconciled — every delivering run has its row, every row has its
#                 run, and the serving sha is recorded. ALSO 0: a QUIET WINDOW —
#                 zero delivering runs, zero in-window rows, serving sha verified
#                 recorded, re-ask list PRESENT-EMPTY — announced as a named
#                 deferral with its own ::warning, never as RECONCILED
#             1 = BEHIND or WRONG (or SERVING-UNRECORDED, or GRACED-UNRECORDED
#                 — a sha an earlier run graced and nothing ever recorded), WITH
#                 COUNTS
#             2 = could not read, or the population was empty (including a window
#                 whose every delivering run PREDATES the recorder) — a WARNING
#                 that is never counted clean. A rate with no denominator is
#                 refused. An empty population escapes to the QUIET WINDOW
#                 deferral (rc 0) ONLY under the three conditions above;
#                 anything short of all three stays here.
#                 An ABSENT re-ask list is one of these conditions: a memory
#                 that was destroyed cannot re-ask, so it is a named silence.
#                 A DECLARED first run (CROWN_STATE_FIRST_RUN=1) is not.
#             3 = CONFIGURATION fault only (no jq/gh, no credential, bad flag,
#                 or CROWN_API_TOKEN set but EMPTY — a reader asked for and not
#                 supplied. UNSET is not a fault: it falls through to SSH.)
#             4 = NOT YET DUE. Everything that could be read reconciled, nothing
#                 is accused, and a DEFERRAL is open — today that is the serving
#                 grace, whose accusation the next run collects. It is a
#                 ::warning, not a page, and it is NOT a green either: the
#                 sentence names every deferral that fired. rc 2 outranks it, so
#                 a deferral never launders a silence.
#
# USAGE
#   scripts/crown-reconcile.sh --repo FRIKKern/barkpark
#   scripts/crown-reconcile.sh --window-hours 6
#   scripts/crown-reconcile.sh --state-file /var/lib/crown/graced.txt
#   scripts/crown-reconcile.sh --runs-fixture r.json --jobs-fixture j.json \
#       --crown-fixture c.json --health-fixture h.json --now 2026-08-09T12:00:00Z
#
# The fixture flags make every classification hermetically provable; see
# scripts/crown-reconcile.test.sh, which breaks the comparison five ways and
# requires a red for each.
#
# TRANSPORT: no JSON payload is ever handed to jq as an argv word. Linux caps a
# single argv string at 131,072 bytes independently of ARG_MAX and a run listing
# crosses it. Every list travels by `--slurpfile` or stdin (charter D486).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

REPO="${GITHUB_REPOSITORY:-FRIKKern/barkpark}"
WINDOW_HOURS=24
# The reverse direction reads a bounded page of the newest rows. The route clamps
# `limit` itself; this is the ask, not a promise about what comes back.
ROW_LIMIT=100
# Runs are fetched over a WIDER window than they are examined over, so a row whose
# delivering run was created just before the window start is not mis-called WRONG.
GRACE_HOURS=6
# A serving sha whose process started less than this many seconds ago may simply
# be a deploy still in flight whose recorder has not posted yet. Younger than this
# is a WARNING; older is a RED.
SERVING_GRACE_SECONDS=1200
# How far a serving_since may sit AHEAD of now before the disagreement is called
# a clock fault rather than inter-host jitter. DERIVED FROM TWO LIVE MEASUREMENTS,
# not felt: run 31332764821 reported 3s ahead on an NTP-healthy plane (ordinary
# jitter between the box and the runner, and it will recur), and run 31334953628
# reported 54s ahead because a deploy was genuinely IN FLIGHT. So the value must
# EXCEED 3 and must never REACH 54 — the 54s shape belongs to the in-flight arm
# below, which names the running run, not to a widened epsilon that would swallow
# it silently. scripts/crown-reconcile.test.sh reads this constant back out and
# asserts the BAND 4 <= EPS < 54, so a later widening reds.
SERVING_SKEW_EPSILON_SECONDS=15
# How long an `in_progress` deploy.yml run for the served sha may keep DEFERRING
# the missing-row accusation (charged against the sha's FIRST-SEEN instant, like
# the grace above). Without a cap the in-flight arm re-defers for as long as
# GitHub reports the run in_progress, so a HUNG run bought amnesty bounded only
# by GitHub's own ~6h default job timeout — a bound this script never stated
# (dr-w34-fu-inflight-deferral-is-unbounded). MEASURED, not felt: across the 50
# most recent successful deploy.yml runs (runs API, read 2026-08-23), duration
# was median 501s, p90 1175s, max 6495s. The cap must EXCEED that observed max —
# a slow-but-real deploy is this arm's whole purpose — and fall far below the
# ~21600s a hung job may sit in_progress by default. 10800s is ~1.66x the
# observed maximum. Past it, the run stops being an alibi: the sha is accused
# (SERVING-INFLIGHT-EXPIRED + SERVING-UNRECORDED, exit 1), naming the hung run.
SERVING_INFLIGHT_CAP_SECONDS=10800
# How long a graced sha stays on the RE-ASK LIST. It is accused on every run in
# between, so this bounds the LIST, not the accusation. See the boundary above.
REASK_MAX_SECONDS=86400
# The re-ask list itself. It MUST outlive the run — $WORK is deleted by the
# cleanup trap — so it defaults outside the working directory and the caller is
# expected to point it somewhere that persists between runs.
STATE_FILE="${CROWN_STATE_FILE:-${TMPDIR:-/tmp}/crown-reconcile-graced.txt}"
# WHERE that path is supposed to persist, in words, for the printed line. The
# caller knows this and the script cannot: a path under $RUNNER_TEMP is a
# destroyed VM unless something ships it off the box. Unset, it is derived
# below, and a path that lives in a temp directory says so rather than implying
# a memory it does not have.
STATE_STORAGE="${CROWN_STATE_STORAGE:-}"
# The CALLER's statement that the persistent store has never held a list. Only a
# caller that actually reached the store may say this — the workflow sets it from
# a remote existence test that SUCCEEDED, and leaves it unset when the fetch
# failed, so transport silence keeps landing in ABSENT. Any value other than the
# literal 1 is read as "not claimed": a typo must not become a first run.
STATE_FIRST_RUN="${CROWN_STATE_FIRST_RUN:-}"
# The instant `record-delivery` first existed: PR #11167, merge commit 67f4a6ab2.
# Re-derivable by hand, which is why the commit is named beside it:
#   TZ=UTC git show -s --format='%H %cd %s' --date=iso-strict 67f4a6ab2
# A delivering run created before this could not have been recorded by anything.
RECORDER_BIRTH_ISO="2026-08-09T09:39:44Z"
RECORDER_BIRTH_PR="#11167"
RECORDER_BIRTH_COMMIT="67f4a6ab2"
API_BASE="${CROWN_API_BASE:-https://api.barkpark.cloud}"
HEALTH_URL="${CROWN_HEALTH_URL:-https://barkpark.cloud/health}"

RUNS_FIXTURE=""
JOBS_FIXTURE=""
CROWN_FIXTURE=""
HEALTH_FIXTURE=""
NOW_OVERRIDE=""

WORK="$(mktemp -d 2>/dev/null || mktemp -d -t crown-reconcile)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

say() { echo "$*"; }
warn() { echo "$*" >&2; }

usage() { sed -n '1,/^set -uo pipefail$/p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 ;;
    --window-hours) WINDOW_HOURS="${2:-}"; shift 2 ;;
    --grace-hours) GRACE_HOURS="${2:-}"; shift 2 ;;
    --limit) ROW_LIMIT="${2:-}"; shift 2 ;;
    --runs-fixture) RUNS_FIXTURE="${2:-}"; shift 2 ;;
    --jobs-fixture) JOBS_FIXTURE="${2:-}"; shift 2 ;;
    --crown-fixture) CROWN_FIXTURE="${2:-}"; shift 2 ;;
    --health-fixture) HEALTH_FIXTURE="${2:-}"; shift 2 ;;
    --now) NOW_OVERRIDE="${2:-}"; shift 2 ;;
    --state-file) STATE_FILE="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) warn "unknown flag: $1"; exit 3 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { warn "CONFIG: jq is required"; exit 3; }

case "$WINDOW_HOURS" in ''|*[!0-9]*) warn "CONFIG: --window-hours must be a whole number of hours, got '$WINDOW_HOURS'"; exit 3 ;; esac
case "$GRACE_HOURS" in ''|*[!0-9]*) warn "CONFIG: --grace-hours must be a whole number of hours, got '$GRACE_HOURS'"; exit 3 ;; esac
case "$ROW_LIMIT" in ''|*[!0-9]*) warn "CONFIG: --limit must be a whole number, got '$ROW_LIMIT'"; exit 3 ;; esac

FIXTURE_MODE=0
[ -n "$RUNS_FIXTURE" ] && FIXTURE_MODE=1

# ── clocks ───────────────────────────────────────────────────────────────────
epoch_of() { # <iso8601> -> seconds, or empty
  local iso="$1" plain
  [ -n "$iso" ] || return 1
  # ISO-8601 ONLY, shape-checked BEFORE date(1) sees it. GNU date -d also
  # accepts a relative grammar — `yesterday`, `now`, `2 hours ago` — so on a
  # Linux runner `--now yesterday` PARSED and silently shifted the whole
  # comparison window by a day, while BSD date on a mac refused it. The verdict
  # must not depend on which date(1) the runner has, and a window this script
  # cannot state is a window it must refuse.
  case "$iso" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]*) ;;
    *) return 1 ;;
  esac
  date -u -d "$iso" +%s 2>/dev/null && return 0
  # BSD/macOS date, where the harness usually runs. Fractional seconds and the
  # trailing Z are stripped first; `%%.*` alone would mangle an instant that has
  # no fraction into `...ZZ`.
  plain="${iso%Z}"
  plain="${plain%%.*}"
  date -u -j -f "%Y-%m-%dT%H:%M:%S" "$plain" +%s 2>/dev/null && return 0
  return 1
}

if [ -n "$NOW_OVERRIDE" ]; then
  NOW_EPOCH="$(epoch_of "$NOW_OVERRIDE")" || { warn "CONFIG: --now is not an ISO-8601 instant: $NOW_OVERRIDE"; exit 3; }
else
  NOW_EPOCH="$(date -u +%s)"
fi
RECORDER_BIRTH_EPOCH="$(epoch_of "$RECORDER_BIRTH_ISO")" || { warn "CONFIG: RECORDER_BIRTH_ISO is not an ISO-8601 instant: $RECORDER_BIRTH_ISO"; exit 3; }
CUTOFF_EPOCH=$((NOW_EPOCH - WINDOW_HOURS * 3600))
WIDE_EPOCH=$((CUTOFF_EPOCH - GRACE_HOURS * 3600))
iso_of() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null; }
CUTOFF_ISO="$(iso_of "$CUTOFF_EPOCH")"
NOW_ISO="$(iso_of "$NOW_EPOCH")"

# ── the named silences ───────────────────────────────────────────────────────
# The ONLY way UNREADABLE is set. A condition that mutes part of the comparison
# has to say which one it was, in the exit-2 sentence itself and not only in a
# warning a reader may never scroll back to.
UNREADABLE=0
REASONS_FILE=""
reason() { # <sentence>
  UNREADABLE=1
  warn "  $*"
  [ -n "$REASONS_FILE" ] && printf '%s\n' "$*" >> "$REASONS_FILE"
  return 0
}

# ── the named deferrals ──────────────────────────────────────────────────────
# A DEFERRAL is not a silence. It says "the comparison ran, it found nothing to
# accuse YET, and the accusation is owed to a LATER run" — which is only honest
# because the debt is written to the re-ask list before this process exits. It
# is counted and named exactly like a reason(), and deliberately does NOT touch
# UNREADABLE: folding it into the silence is what made the crown alarm wrong
# five times in six and one code away from being muted.
DEFERRED=0
DEFERRALS_FILE=""
defer() { # <sentence>
  DEFERRED=$((DEFERRED + 1))
  warn "  $*"
  [ -n "$DEFERRALS_FILE" ] && printf '%s\n' "$*" >> "$DEFERRALS_FILE"
  return 0
}

# ── the re-ask list ──────────────────────────────────────────────────────────
# Line format: `<sha> <first-seen-epoch>`, one per line, `#` comments ignored.
# Deliberately NOT json: this file is written and read by this script alone, and
# a line-oriented format needs no jq at all, so no payload can reach an argv word
# (charter D486).

# Where the list is SUPPOSED to persist, in words. Derived only when the caller
# did not say, and a temp path is named as the hole it is rather than passed off
# as a memory.
state_storage() {
  if [ -n "$STATE_STORAGE" ]; then printf '%s' "$STATE_STORAGE"; return 0; fi
  [ -n "$STATE_FILE" ] || { printf 'nowhere'; return 0; }
  case "$STATE_FILE" in
    /tmp/*|/var/tmp/*|/private/tmp/*|"${TMPDIR:-/nonexistent-tmpdir}"*)
      printf 'a temp directory — this does NOT survive a run boundary' ;;
    *) printf 'a local path; set CROWN_STATE_STORAGE to say where it persists' ;;
  esac
}

STATE_LOADED=0
STATE_DROPPED=0
STATE_STATE=""
state_load() { # -> $WORK/reask.txt, and ONE printed line, always
  : > "$WORK/reask.txt"
  local sha ts
  STATE_LOADED=0
  STATE_DROPPED=0
  if [ -z "$STATE_FILE" ]; then
    STATE_STATE="UNCONFIGURED"
    reason "no re-ask list path was configured — a grace granted now cannot be re-asked on the next run"
  elif [ ! -f "$STATE_FILE" ] && [ "$STATE_FIRST_RUN" = "1" ]; then
    # The caller reached the persistent store and found no list there. There is
    # no memory to have lost, so there is no grace an earlier run could have
    # granted, so there is nothing to re-ask — and pretending otherwise pages a
    # human about a file that has never existed. NOT a fault, and it still says
    # exactly what it is rather than passing for PRESENT-EMPTY, which would be a
    # claim about a file that was read.
    STATE_STATE="ABSENT-FIRST-RUN"
  elif [ ! -f "$STATE_FILE" ]; then
    # NOT silence, and NOT clean. state_save writes its header unconditionally,
    # so after any run that reached the save the file EXISTS even holding zero
    # entries. Absent WITHOUT the caller's first-run statement therefore means
    # the memory was destroyed between runs — or the transport that would have
    # carried it failed, which is the same loss — and neither can re-ask a grace
    # an earlier run granted.
    STATE_STATE="ABSENT"
    reason "the re-ask list at $STATE_FILE does not exist and the caller did NOT state that the persistent store is empty (CROWN_STATE_FIRST_RUN=1) — the memory was destroyed between runs or the fetch that would have carried it failed, and a grace granted on a previous run cannot be re-asked. NOT counted clean."
  else
    while read -r sha ts _; do
      case "$sha" in ''|'#'*) continue ;; esac
      case "$sha" in *[!0-9a-fA-F]*) STATE_DROPPED=$((STATE_DROPPED + 1)); reason "a re-ask list line did not start with a sha and was dropped: '$sha'"; continue ;; esac
      case "${ts:-}" in ''|*[!0-9]*) STATE_DROPPED=$((STATE_DROPPED + 1)); reason "the re-ask entry for $sha carries no first-seen instant and was dropped"; continue ;; esac
      STATE_LOADED=$((STATE_LOADED + 1))
      printf '%s %s\n' "$sha" "$ts" >> "$WORK/reask.txt"
    done < "$STATE_FILE"
    if [ "$STATE_LOADED" -eq 0 ]; then
      # An affirmative statement, not a fault: the file is there, it was read,
      # and it says nothing is owed.
      STATE_STATE="PRESENT-EMPTY"
    else
      STATE_STATE="PRESENT"
    fi
  fi
  say "RE-ASK LIST: ${STATE_FILE:-<none>} [$(state_storage)] — ${STATE_STATE}; loaded ${STATE_LOADED} entry(ies), dropped ${STATE_DROPPED} malformed line(s)."
  if [ "$STATE_STATE" = "ABSENT-FIRST-RUN" ]; then
    say "  the caller states the persistent store has never held a list, so there is no earlier grace to re-ask — this is a FIRST RUN, not a destroyed memory. A run that could not REACH the store leaves this unstated and is reported as ABSENT."
  fi
  return 0
}

state_first_seen() { # <sha> -> first-seen epoch, or empty
  awk -v s="$1" '$1 == s { print $2; exit }' "$WORK/reask.txt" 2>/dev/null
}

state_save() { # <file of "sha epoch" lines to keep>
  local kept
  kept="$(awk 'NF' "$1" 2>/dev/null | sort -u | wc -l | tr -d ' ')"
  if [ -z "$STATE_FILE" ]; then
    # state_load already said UNCONFIGURED and reason()'d it; the symmetric line
    # still prints, because "wrote M, then loaded 0" is the eviction signature
    # and it only reads if BOTH halves are always there.
    say "RE-ASK LIST: wrote 0 entry(ies) to <none> — no path was configured, so ${kept} entry(ies) were DISCARDED."
    return 0
  fi
  mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null
  # WRITE-THEN-MOVE, never a truncating redirect. `> "$STATE_FILE"` truncates
  # BEFORE the first byte is written, so a process killed mid-write leaves a
  # SHORT list — and a short list is indistinguishable from a list that legitimately
  # drained, which is precisely the accusation-losing shape this file exists to
  # prevent. The rename is atomic on the same filesystem, so a reader sees either
  # the whole old list or the whole new one.
  if {
    printf '# crown-reconcile re-ask list — "<sha> <first-seen-epoch>". Written %s.\n' "$NOW_ISO"
    sort -u "$1"
  } > "$STATE_FILE.tmp.$$" 2>/dev/null && mv -f "$STATE_FILE.tmp.$$" "$STATE_FILE" 2>/dev/null; then
    say "RE-ASK LIST: wrote ${kept} entry(ies) to $STATE_FILE [$(state_storage)]."
  else
    rm -f "$STATE_FILE.tmp.$$" 2>/dev/null
    reason "the re-ask list could not be written to $STATE_FILE — a grace granted now will not be re-asked"
    say "RE-ASK LIST: FAILED to write ${kept} entry(ies) to $STATE_FILE [$(state_storage)]."
  fi
  return 0
}

# ── the two readers ──────────────────────────────────────────────────────────
READER=""
SSH=""
# WHICH reader actually produced rows, counted per read. The transport is known
# before the first read; the reader is not, because the SSH transport carries
# two of them and only a 401 to the WORKER principal decides which one answers.
READS_ROUTE=0
READS_SQL=0
READS_FIXTURE=0
READS_FAILED=0
SQL_DOWNGRADE_HTTP=""
select_reader() {
  if [ "$FIXTURE_MODE" = "1" ]; then
    READER="fixture"
    return 0
  fi
  # SET BUT EMPTY is not the same statement as UNSET. Unset means "I did not ask
  # for the PAT reader" and falls through to the SSH reader below — the path CI
  # actually runs, which must keep working. Empty means "I asked for the PAT
  # reader and handed it nothing", and silently answering that with a different
  # reader is the downgrade this guard exists to refuse.
  if [ "${CROWN_API_TOKEN+set}" = "set" ] && [ -z "${CROWN_API_TOKEN}" ]; then
    warn "CONFIG: CROWN_API_TOKEN is SET BUT EMPTY. A reader that was explicitly asked for and is not there is a configuration fault, not a silent downgrade to the CP_HOST + DEPLOY_SSH_KEY reader. UNSET it to choose the SSH reader deliberately, or give it a read-ability PAT."
    return 3
  fi
  if [ -n "${CROWN_API_TOKEN:-}" ]; then
    READER="pat"
    return 0
  fi
  if [ -n "${CP_HOST:-}" ] && [ -n "${DEPLOY_SSH_KEY:-}" ]; then
    install -m 600 /dev/null "$WORK/key" 2>/dev/null || { warn "CONFIG: could not stage the deploy key"; return 3; }
    printf '%s\n' "$DEPLOY_SSH_KEY" > "$WORK/key"
    SSH="ssh -i $WORK/key -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$WORK/known -o ConnectTimeout=20"
    READER="ssh"
    return 0
  fi
  warn "CONFIG: no way to read the crown. Set CROWN_API_TOKEN (a read-ability PAT), or CP_HOST + DEPLOY_SSH_KEY for the on-box read deploy.yml already uses."
  return 3
}

# The remote read, written once and shipped over stdin so nothing is interpolated
# into a remote shell string. Emits a single line: CR_BODY=<json envelope>.
write_remote_reader() {
  cat > "$WORK/remote.sh" <<'REMOTE'
set -u
QS="$1"
CID="$(docker ps -q --filter ancestor=cloud-control_plane:latest | head -1)"
if [ -z "$CID" ]; then echo "CR_ERROR=no_control_plane_container"; exit 0; fi
WT="$(docker exec "$CID" printenv WORKER_TOKEN)"
if [ -z "$WT" ]; then echo "CR_ERROR=empty_worker_token"; exit 0; fi
CODE="$(curl -s -o /tmp/cr-body.json -w '%{http_code}' --max-time 30 -H "authorization: Bearer $WT" "https://barkpark.cloud/v1/deliveries?$QS")"
echo "CR_HTTP=$CODE"
if [ "$CODE" = "200" ]; then
  echo "CR_VIA=route"
  echo "CR_BODY=$(tr -d '\n' < /tmp/cr-body.json)"
  rm -f /tmp/cr-body.json
  exit 0
fi
# The reader route is user-or-PAT; WORKER_TOKEN is the worker principal, so a
# 401/403 here is a TIER MISMATCH, not a broken box. Read the same rows straight
# out of the control plane's own postgres container instead — same crown, same
# SSH, no new credential.
if [ "$CODE" != "401" ] && [ "$CODE" != "403" ]; then
  echo "CR_ERROR=http_$CODE"
  rm -f /tmp/cr-body.json
  exit 0
fi
DBID="$(docker ps -q --filter ancestor=postgres:15-alpine | head -1)"
if [ -z "$DBID" ]; then echo "CR_ERROR=no_db_container"; exit 0; fi
PU="$(docker exec "$DBID" printenv POSTGRES_USER)"
PD="$(docker exec "$DBID" printenv POSTGRES_DB)"
if [ -z "$PU" ] || [ -z "$PD" ]; then echo "CR_ERROR=no_db_env"; exit 0; fi
SHA=""
LIM="100"
for kv in $(echo "$QS" | tr '&' ' '); do
  case "$kv" in
    sha=*) SHA="${kv#sha=}" ;;
    limit=*) LIM="${kv#limit=}" ;;
  esac
done
case "$LIM" in ''|*[!0-9]*) LIM=100 ;; esac
case "$SHA" in ''|*[!0-9a-f]*) WHERE="" ;; *) WHERE="WHERE sha = '$SHA'" ;; esac
SQL="SELECT coalesce(json_agg(row_to_json(t)), '[]'::json) FROM (SELECT sha, target, carried, delivering_run_id, to_char(first_seen_at, 'YYYY-MM-DD\"T\"HH24:MI:SSZ') AS first_seen_at FROM platform_deliveries $WHERE ORDER BY first_seen_at DESC LIMIT $LIM) t"
ROWS="$(docker exec "$DBID" psql -U "$PU" -d "$PD" -tAc "$SQL" 2>/dev/null)"
if [ -z "$ROWS" ]; then echo "CR_ERROR=sql_read_failed"; exit 0; fi
echo "CR_VIA=sql"
echo "CR_BODY={\"deliveries\":$ROWS}"
REMOTE
}

# crown_read <query-string> <out-file> -> 0 read / 2 could not read
crown_read() {
  local qs="$1" out="$2" body http via
  case "$READER" in
    fixture)
      [ -f "$CROWN_FIXTURE" ] || { READS_FAILED=$((READS_FAILED + 1)); warn "  crown fixture is unreadable: ${CROWN_FIXTURE:-<none>}"; return 2; }
      jq 'if type == "array" then {deliveries: .} else error("not an array") end' "$CROWN_FIXTURE" > "$out" 2>/dev/null \
        || { READS_FAILED=$((READS_FAILED + 1)); warn "  crown fixture is not a JSON array of rows"; return 2; }
      READS_FIXTURE=$((READS_FIXTURE + 1))
      return 0
      ;;
    pat)
      http="$(curl -s -o "$WORK/body.json" -w '%{http_code}' --max-time 30 \
        -H "authorization: Bearer $CROWN_API_TOKEN" "$API_BASE/v1/deliveries?$qs")"
      if [ "$http" != "200" ]; then
        READS_FAILED=$((READS_FAILED + 1))
        warn "  the crown answered HTTP ${http:-<none>} for ?$qs"
        return 2
      fi
      cp "$WORK/body.json" "$out"
      READS_ROUTE=$((READS_ROUTE + 1))
      return 0
      ;;
    ssh)
      body="$($SSH "root@${CP_HOST}" "bash -s '$qs'" < "$WORK/remote.sh" 2>&1)"
      if [ $? -ne 0 ]; then
        READS_FAILED=$((READS_FAILED + 1))
        warn "  the control plane was not reachable over SSH for ?$qs"
        return 2
      fi
      via="$(printf '%s\n' "$body" | sed -n 's/^CR_VIA=//p')"
      http="$(printf '%s\n' "$body" | sed -n 's/^CR_HTTP=//p')"
      printf '%s\n' "$body" | sed -n 's/^CR_BODY=//p' > "$out"
      if [ ! -s "$out" ]; then
        READS_FAILED=$((READS_FAILED + 1))
        warn "  the crown could not be read on the box for ?$qs: $(printf '%s\n' "$body" | sed -n 's/^CR_ERROR=//p')"
        return 2
      fi
      if [ "$via" = "sql" ]; then
        READS_SQL=$((READS_SQL + 1))
        SQL_DOWNGRADE_HTTP="$http"
      else
        READS_ROUTE=$((READS_ROUTE + 1))
      fi
      return 0
      ;;
  esac
  return 2
}

# WHICH reader answered, as a field — printed on every path that reaches a
# verdict, and folded into the verdict sentence itself. The transport is in the
# header; this is the reader, and the two are not the same fact.
reader_answered() {
  local names=""
  [ "$READS_FIXTURE" -gt 0 ] && names="fixture"
  [ "$READS_ROUTE" -gt 0 ] && names="${names:+$names+}route"
  [ "$READS_SQL" -gt 0 ] && names="${names:+$names+}postgres-container"
  printf '%s' "${names:-none}"
}

say_reader() {
  local detail=""
  if [ "$READS_SQL" -gt 0 ]; then
    detail=" — the /v1/deliveries route answered HTTP ${SQL_DOWNGRADE_HTTP:-<none>} to the WORKER principal, so those rows came from the control plane's own postgres container, NOT from the route"
  fi
  say "READER: transport=${READER:-<none>}, answered by $(reader_answered) (route=${READS_ROUTE}, postgres-container=${READS_SQL}, fixture=${READS_FIXTURE}, unreadable=${READS_FAILED})${detail}"
}

# ── the runs ─────────────────────────────────────────────────────────────────
fetch_runs() { # -> writes $WORK/runs-raw.json, 0 ok / 2 could not read
  if [ "$FIXTURE_MODE" = "1" ]; then
    [ -f "$RUNS_FIXTURE" ] || { warn "  runs fixture is unreadable: $RUNS_FIXTURE"; return 2; }
    cp "$RUNS_FIXTURE" "$WORK/runs-raw.json"
    return 0
  fi
  command -v gh >/dev/null 2>&1 || { warn "CONFIG: gh is required to enumerate deploy.yml runs"; return 3; }
  # NO `&status=success` HERE, DELIBERATELY. A deploy that is STILL RUNNING is
  # the single most useful thing to know before accusing the sha it is putting
  # on the box, and `status=success` meant those bytes were never fetched at
  # all. The success POPULATION is unchanged by construction: the jq that builds
  # .examined/.wide still filters `.conclusion == "success"` itself, so every
  # count downstream sees exactly what it saw before. The only other reader of
  # this file is PAGE_ROWS/PAGE_OLDEST, which counts the raw page and already
  # discloses truncation as `N+`; run_delivers() is called for examined success
  # runs only, so an in_progress run never reaches a jobs lookup.
  if ! gh api "repos/$REPO/actions/workflows/deploy.yml/runs?branch=main&per_page=100" \
    > "$WORK/runs-raw.json" 2>"$WORK/runs-err.txt"; then
    warn "  could not list deploy.yml runs: $(head -1 "$WORK/runs-err.txt")"
    return 2
  fi
  return 0
}

# Is a deploy.yml run for this exact sha STILL RUNNING right now? Keyed on the
# SERVED sha and nothing else: "some deploy is busy" is not an alibi for the
# particular commit being accused. Answered out of the same run page every other
# question is answered from — no second request, no second credential — which is
# only possible because fetch_runs stopped asking the API for successes only.
serving_run_in_flight() { # <sha> -> prints the run id, 0 in flight / 1 not
  local sha="$1" id
  [ -s "$WORK/runs-raw.json" ] || return 1
  id="$(jq -r --arg sha "$sha" \
    'first(.workflow_runs[]? | select(.head_sha == $sha and .status == "in_progress") | .id | tostring) // empty' \
    "$WORK/runs-raw.json" 2>/dev/null)"
  [ -n "$id" ] || return 1
  printf '%s' "$id"
  return 0
}

# A run DELIVERS only when control-plane or instance concluded success.
run_delivers() { # <run-id> -> 0 delivers / 1 does not / 2 could not read
  local id="$1" out="$WORK/jobs-$id.json"
  if [ "$FIXTURE_MODE" = "1" ]; then
    [ -f "$JOBS_FIXTURE" ] || return 2
    jq --arg id "$id" '.[$id] // empty' "$JOBS_FIXTURE" > "$out" 2>/dev/null
    [ -s "$out" ] || return 2
  else
    if ! gh api "repos/$REPO/actions/runs/$id/jobs?per_page=100" --jq '.jobs' > "$out" 2>/dev/null; then
      return 2
    fi
  fi
  local hits
  hits="$(jq '[.[] | select((.name == "control-plane" or .name == "instance") and .conclusion == "success")] | length' "$out" 2>/dev/null)"
  [ -n "$hits" ] || return 2
  [ "$hits" -gt 0 ] && return 0
  return 1
}

# ── run ──────────────────────────────────────────────────────────────────────
select_reader || exit 3
[ "$READER" = "ssh" ] && write_remote_reader

say "crown-reconcile — repo=$REPO reader-transport=$READER window=${WINDOW_HOURS}h ($CUTOFF_ISO .. $NOW_ISO)"

REASONS_FILE="$WORK/reasons.txt"
: > "$REASONS_FILE"
DEFERRALS_FILE="$WORK/deferrals.txt"
: > "$DEFERRALS_FILE"
state_load

fetch_runs
rc=$?
[ "$rc" = "3" ] && exit 3
if [ "$rc" != "0" ]; then
  say ""
  say "COULD NOT READ: the deploy.yml run list did not answer. Nothing was compared, and this is NOT a clean run."
  say_reader
  exit 2
fi

# Two populations: the EXAMINED window, and a wider one used only so a row near
# the boundary is not mis-called WRONG.
jq --argjson cut "$CUTOFF_EPOCH" --argjson wide "$WIDE_EPOCH" \
  '[.workflow_runs[]
    | select(.conclusion == "success")
    | {id: (.id | tostring), sha: .head_sha, created: .created_at, at: (.created_at | fromdateiso8601)}]
   | {examined: [.[] | select(.at >= $cut)], wide: [.[] | select(.at >= $wide)]}' \
  "$WORK/runs-raw.json" > "$WORK/runs.json" 2>/dev/null
if [ ! -s "$WORK/runs.json" ]; then
  say ""
  say "COULD NOT READ: the run list did not parse as an Actions runs payload. Nothing was compared."
  say_reader
  exit 2
fi

SUCCESS_COUNT="$(jq '.examined | length' "$WORK/runs.json")"
# One page of 100 is the bound. The population is a FLOOR only when that page
# BOTH filled AND failed to reach back past the cutoff — a filled page whose
# oldest run predates the window has seen the whole window and is exact. Printed
# as `N+`, never rounded down silently.
PAGE_ROWS="$(jq '.workflow_runs | length' "$WORK/runs-raw.json" 2>/dev/null || echo 0)"
PAGE_OLDEST="$(jq -r '[.workflow_runs[] | .created_at | fromdateiso8601] | min // 0' "$WORK/runs-raw.json" 2>/dev/null || echo 0)"
if [ "${PAGE_ROWS:-0}" -ge 100 ] && [ "${PAGE_OLDEST:-0}" -gt "$CUTOFF_EPOCH" ]; then
  warn "  note: the 100-run page filled without reaching the window start — the population below is a FLOOR, printed as N+"
  FLOOR="+"
else
  FLOOR=""
fi

# Which of those actually delivered?
: > "$WORK/delivering.txt"
JOBS_UNREADABLE=0
NONDELIVERING=0
while IFS=' ' read -r id sha at; do
  [ -n "$id" ] || continue
  run_delivers "$id"
  case $? in
    0) printf '%s %s %s\n' "$id" "$sha" "$at" >> "$WORK/delivering.txt" ;;
    1) NONDELIVERING=$((NONDELIVERING + 1)) ;;
    *) JOBS_UNREADABLE=$((JOBS_UNREADABLE + 1))
       reason "run $id: its job list could not be read — it is NOT counted as reconciled" ;;
  esac
done < <(jq -r '.examined[] | "\(.id) \(.sha) \(.at)"' "$WORK/runs.json")

DELIVERING="$(awk 'NF' "$WORK/delivering.txt" | wc -l | tr -d ' ')"

# The wide set of delivering runs, for the reverse direction — BOTH their ids
# (the alibi a row states for itself) and their head shas (the fallback for a row
# that states none). Runs outside the examined window are included here only as an
# ALIBI for a row, never as a population this verdict reports a rate over.
: > "$WORK/wide-shas.txt"
: > "$WORK/wide-runs.txt"
while IFS=' ' read -r id sha; do
  [ -n "$id" ] || continue
  if run_delivers "$id"; then
    printf '%s\n' "$sha" >> "$WORK/wide-shas.txt"
    printf '%s\n' "$id" >> "$WORK/wide-runs.txt"
  fi
done < <(jq -r '.wide[] | "\(.id) \(.sha)"' "$WORK/runs.json")

say ""
say "POPULATION: ${SUCCESS_COUNT}${FLOOR} successful deploy.yml run(s) on main in the window; ${DELIVERING} of them DELIVERED (a control-plane or instance leg concluded success), ${NONDELIVERING} delivered nothing (both legs skipped — docs-only merges), ${JOBS_UNREADABLE} unreadable."

# ── BEHIND: a delivering run whose head sha the crown has no row for ─────────
BEHIND=0
BEHIND_UNREADABLE=0
PREDATES=0
: > "$WORK/behind.txt"
: > "$WORK/predates.txt"
while IFS=' ' read -r id sha at; do
  [ -n "$sha" ] || continue
  # A run that finished before `record-delivery` existed cannot be BEHIND: there
  # was no writer to be behind. It gets its own printed class, not silence.
  if [ -n "${at:-}" ] && [ "$at" -lt "$RECORDER_BIRTH_EPOCH" ] 2>/dev/null; then
    PREDATES=$((PREDATES + 1))
    printf '%s %s\n' "$sha" "$id" >> "$WORK/predates.txt"
    continue
  fi
  if crown_read "sha=$sha" "$WORK/rows-$sha.json"; then
    n="$(jq --arg sha "$sha" '[.deliveries[] | select(.sha == $sha)] | length' "$WORK/rows-$sha.json" 2>/dev/null)"
    [ -n "$n" ] || n=0
    if [ "$n" -eq 0 ]; then
      BEHIND=$((BEHIND + 1))
      printf '%s %s\n' "$sha" "$id" >> "$WORK/behind.txt"
    fi
  else
    BEHIND_UNREADABLE=$((BEHIND_UNREADABLE + 1))
    reason "the crown could not be asked about $sha (delivered by run $id) — that run is NOT counted as reconciled"
  fi
done < "$WORK/delivering.txt"

# The BEHIND denominator is the delivering runs that a writer actually existed
# for. It is printed beside PREDATES below, so the exemption is a denominator a
# reader can subtract, never a hidden window.
RECONCILABLE=$((DELIVERING - PREDATES))

# ── WRONG: a row inside the window naming a sha no delivering run delivered ──
WRONG=0
UNCLASSIFIED=0
ROWS_EXAMINED=0
# The quiescence count, for the QUIET WINDOW arm below (charter D597). Distinct
# from ROWS_EXAMINED on purpose: an in-window row seen down the no-alibi branch
# was COUNTED but never CLASSIFIED — there is no alibi source to judge it
# against — so it must never inflate the WRONG denominator.
QUIET_ROWS=0
QUIET_ROWS_READ=0
# The refusal is a variable so the QUIET WINDOW arm can tolerate EXACTLY this
# sentence and no other — a guard pinned to prose that could drift from the
# reason() call would silently tolerate nothing, or everything.
NOALIBI_REASON="no delivering run in the widened window — the reverse direction has no alibi source and was NOT checked"
: > "$WORK/wrong.txt"
sort -u "$WORK/wide-shas.txt" > "$WORK/wide-shas-sorted.txt"
sort -u "$WORK/wide-runs.txt" > "$WORK/wide-runs-sorted.txt"
WIDE_SHAS="$(awk 'NF' "$WORK/wide-shas-sorted.txt" | wc -l | tr -d ' ')"
if [ "$WIDE_SHAS" -eq 0 ]; then
  # Without a single delivering run in the widened window there is no ALIBI
  # source, and every row would be accused of being a ghost. That is the
  # comforting-direction mistake inverted — loud, but manufactured. Refuse.
  reason "$NOALIBI_REASON"
  # The QUIESCENCE question is narrower than the WRONG question and still needs
  # an answer here: "do any rows sit inside the window at all?" needs no alibi
  # source, only a count. A read that fails leaves QUIET_ROWS_READ=0, and the
  # QUIET WINDOW arm below fails CLOSED on it — an uncounted window can never
  # green.
  if crown_read "limit=$ROW_LIMIT" "$WORK/recent.json"; then
    QUIET_ROWS="$(jq --argjson cut "$CUTOFF_EPOCH" \
      '[.deliveries[]
        | select((.first_seen_at // "") != "")
        | . + {at: (try (.first_seen_at | sub("\\.[0-9]+"; "") | sub("Z?$"; "Z") | fromdateiso8601) catch 0)}
        | select(.at >= $cut)] | length' "$WORK/recent.json" 2>/dev/null)"
    case "${QUIET_ROWS:-}" in ''|*[!0-9]*) QUIET_ROWS=0 ;; *) QUIET_ROWS_READ=1 ;; esac
  fi
elif crown_read "limit=$ROW_LIMIT" "$WORK/recent.json"; then
  jq --argjson cut "$CUTOFF_EPOCH" \
    '[.deliveries[]
      | select((.first_seen_at // "") != "")
      | . + {at: (try (.first_seen_at | sub("\\.[0-9]+"; "") | sub("Z?$"; "Z") | fromdateiso8601) catch 0)}
      | select(.at >= $cut)]' "$WORK/recent.json" > "$WORK/recent-window.json" 2>/dev/null
  if [ -s "$WORK/recent-window.json" ]; then
    ROWS_EXAMINED="$(jq 'length' "$WORK/recent-window.json")"
    QUIET_ROWS="$ROWS_EXAMINED"
    QUIET_ROWS_READ=1
    while IFS=' ' read -r sha carried run; do
      [ -n "$sha" ] || continue
      if [ "$carried" = "true" ]; then
        continue
      elif [ "$carried" = "null" ]; then
        UNCLASSIFIED=$((UNCLASSIFIED + 1))
        reason "row $sha: 'carried' was never measured — it cannot be ruled correct or wrong, and is NOT counted clean"
        continue
      fi
      # The alibi the row states for ITSELF, first: the run the recorder says
      # wrote it. The head-sha comparison is reached only when the row states no
      # run at all, because a served sha legitimately differs from every run's
      # head sha whenever a deploy's pull races past its trigger.
      if [ "$run" != "-" ]; then
        grep -qx "$run" "$WORK/wide-runs-sorted.txt" && continue
      else
        grep -qx "$sha" "$WORK/wide-shas-sorted.txt" && continue
      fi
      WRONG=$((WRONG + 1))
      printf '%s %s\n' "$sha" "$run" >> "$WORK/wrong.txt"
      # `.carried // "null"` would be WRONG here: jq's `//` treats `false` as
      # empty, so every honestly-measured `carried: false` row would report as
      # unmeasured — the comforting direction. Presence is asked for explicitly,
      # and `delivering_run_id` is read the same way for the same reason.
    done < <(jq -r '.[] | "\(.sha) \(if has("carried") and .carried != null then (.carried | tostring) else "null" end) \(if has("delivering_run_id") and .delivering_run_id != null and ((.delivering_run_id | tostring) != "") then (.delivering_run_id | tostring) else "-" end)"' "$WORK/recent-window.json" | sort -u)
  else
    reason "the recent-row page did not parse — the reverse direction was NOT checked"
  fi
else
  reason "the recent-row page could not be read — the reverse direction was NOT checked"
fi

# ── SERVING: what the box says it is running, versus the crown ───────────────
SERVING_RED=0
# 1 ONLY when the serving check RAN end-to-end and the served sha HAS its cp
# row. Condition (1) of the QUIET WINDOW arm (charter D597): a check that was
# skipped, could not read, or found no row leaves this 0 — quiescence can never
# be asserted over an unverified crown.
SERVING_VERIFIED=0
SERVING_SHA=""
SERVING_SKEW=0
SERVING_SKEW_AHEAD=0
SERVING_INFLIGHT_RUN=""
SERVING_INFLIGHT_EXPIRED=""
SERVING_INFLIGHT_AGE=0
SERVING_SINCE=""
GRACED_THIS_RUN=""
if [ -n "$HEALTH_FIXTURE" ] || [ "$FIXTURE_MODE" != "1" ]; then
  if [ -n "$HEALTH_FIXTURE" ]; then
    if [ -f "$HEALTH_FIXTURE" ]; then cp "$HEALTH_FIXTURE" "$WORK/health.json"; else : > "$WORK/health.json"; fi
  else
    curl -s --max-time 20 "$HEALTH_URL" > "$WORK/health.json" 2>/dev/null
  fi
  SERVING_SHA="$(jq -r '.serving_sha // .git_sha // empty' "$WORK/health.json" 2>/dev/null)"
  if [ -z "$SERVING_SHA" ]; then
    reason "${HEALTH_URL} did not name a serving sha — the serving check did NOT run"
  else
    since="$(jq -r '.serving_since // empty' "$WORK/health.json" 2>/dev/null)"
    SERVING_SINCE="$since"
    since_epoch="$(epoch_of "$since" 2>/dev/null || echo 0)"
    age=$((NOW_EPOCH - ${since_epoch:-0}))
    if crown_read "sha=$SERVING_SHA" "$WORK/rows-serving.json"; then
      cp_rows="$(jq --arg sha "$SERVING_SHA" '[.deliveries[] | select(.sha == $sha and .target == "cp")] | length' "$WORK/rows-serving.json" 2>/dev/null)"
      [ -n "$cp_rows" ] || cp_rows=0
      if [ "$cp_rows" -eq 0 ]; then
        # The grace is charged against the FIRST time this sha was seen serving
        # and unrecorded, not against the process age the box reports now. A sha
        # already on the re-ask list cannot buy a fresh grace by being restarted.
        #
        # `graced_age` bounds the EPSILON and GRACE arms below at
        # SERVING_GRACE_SECONDS, and the IN-FLIGHT arm at its own, longer
        # SERVING_INFLIGHT_CAP_SECONDS (measured derivation at the constant),
        # so none of the three can defer forever. A run still `in_progress`
        # past the cap stops being an alibi and the accusation fires below as
        # SERVING-INFLIGHT-EXPIRED, naming the hung run.
        first_seen="$(state_first_seen "$SERVING_SHA")"
        [ -n "$first_seen" ] || first_seen="$NOW_EPOCH"
        graced_age=$((NOW_EPOCH - first_seen))
        # THE ORDER OF THESE ARMS IS THE BEHAVIOUR: IN-FLIGHT, then EPSILON,
        # then SKEW, then GRACE, then RED. The negative-age skew guard is right
        # about a real clock fault and WRONG about a deploy that is still
        # running, because there the disagreement IS the in-flight signal — a
        # box that came up seconds ago reports a serving_since the runner's
        # clock has not reached. Asked in the other order, the skew arm wins
        # first and the crown pages on a deploy nobody has finished.
        inflight_run="$(serving_run_in_flight "$SERVING_SHA")"
        if [ -n "$inflight_run" ] && [ "$graced_age" -lt "$SERVING_INFLIGHT_CAP_SECONDS" ]; then # MUT:G-INFLIGHT-CAP
          SERVING_INFLIGHT_RUN="$inflight_run"
          # defer(), NOT reason(). Everything was read; the answer is "not yet".
          # The debt goes to the re-ask list with every other deferral, so a
          # deploy that runs and still never records is accused by a later run.
          GRACED_THIS_RUN="$SERVING_SHA"
          defer "SERVING IN FLIGHT: the serving sha $SERVING_SHA has no cp row, but deploy.yml run ${inflight_run} for that exact sha is STILL RUNNING — the recorder has not had its turn, so the accusation is DEFERRED to the next run rather than fired at a deploy in progress (first seen $(iso_of "$first_seen"))"
        elif [ -n "$inflight_run" ]; then
          # The alibi EXPIRED. The run has reported in_progress since beyond
          # SERVING_INFLIGHT_CAP_SECONDS (charged against first-seen): that is
          # a hung run, not a slow deploy, and a hung run must not hold the
          # accusation off for the rest of GitHub's own timeout. Falls to RED
          # with its own named sentence below, never to the skew arm — the
          # disagreement here is explained, and its explanation is the fault.
          SERVING_INFLIGHT_EXPIRED="$inflight_run"
          SERVING_INFLIGHT_AGE="$graced_age"
          SERVING_RED=1
        elif [ "${since_epoch:-0}" -gt 0 ] && [ "$age" -lt 0 ] && [ $((0 - age)) -le "$SERVING_SKEW_EPSILON_SECONDS" ] && [ "$graced_age" -lt "$SERVING_GRACE_SECONDS" ]; then
          # Ordinary inter-host jitter, measured at 3s on an NTP-healthy plane.
          # A few seconds of disagreement between two machines is not a fault,
          # and calling it one turns every fresh deploy into a page. It is still
          # a DEFERRAL, never a pass: the debt is written exactly as the grace's
          # is, so nothing is forgiven — only postponed.
          GRACED_THIS_RUN="$SERVING_SHA"
          defer "SERVING GRACE: the serving sha $SERVING_SHA has no cp row and its serving_since is ${SERVING_SKEW_EPSILON_SECONDS}s-or-less ahead of now ($((0 - age))s) — inter-host jitter, not a clock fault, so the accusation is DEFERRED to the next run rather than dropped (first seen $(iso_of "$first_seen"))"
        elif [ "${since_epoch:-0}" -gt 0 ] && [ "$age" -lt 0 ]; then
          # A serving_since AHEAD of now by more than the epsilon, with no run
          # in flight to explain it, means the clocks disagree. "Probably in
          # flight" is the comforting reading of a disagreement, so this is a
          # FAULT with its own sentence, and the missing row is accused.
          SERVING_SKEW=1
          SERVING_SKEW_AHEAD=$((0 - age))
          SERVING_RED=1
        elif [ "${since_epoch:-0}" -gt 0 ] && [ "$age" -lt "$SERVING_GRACE_SECONDS" ] && [ "$graced_age" -lt "$SERVING_GRACE_SECONDS" ]; then
          GRACED_THIS_RUN="$SERVING_SHA"
          # defer(), NOT reason(). This is not a condition that could not be
          # read — everything was read, and the answer is "not yet". The debt is
          # written to the re-ask list six lines below and collected by the next
          # run as GRACED-UNRECORDED, exit 1.
          defer "SERVING GRACE: the serving sha $SERVING_SHA has no cp row, but that process is only ${age}s old — a deploy may still be in flight, so the accusation is DEFERRED to the next run rather than dropped (first seen $(iso_of "$first_seen"))"
        else
          SERVING_RED=1
        fi
      else
        # The served sha has its cp row: the check ran and the crown answered
        # for the exact commit production is running.
        SERVING_VERIFIED=1
      fi
    else
      reason "the crown could not be asked about the serving sha — the serving check did NOT run"
    fi
  fi
fi

# ── THE DEFERRED RE-READ: every sha a grace was ever granted to ──────────────
# A grace deferred an accusation; this is where the deferral is collected. The
# question is asked of the CROWN, not of the box, so it survives the box moving
# on to another sha — which is precisely what made 4c8314c94 unaccusable.
GRACED_RED=0
: > "$WORK/graced.txt"
: > "$WORK/reask-keep.txt"
while IFS=' ' read -r gsha gts; do
  [ -n "$gsha" ] || continue
  gage=$((NOW_EPOCH - gts))
  if [ "$gsha" = "$GRACED_THIS_RUN" ]; then
    # Its grace window is still open and this run already said so by name.
    printf '%s %s\n' "$gsha" "$gts" >> "$WORK/reask-keep.txt"
    continue
  fi
  if [ "$gage" -gt "$REASK_MAX_SECONDS" ]; then
    reason "the graced sha $gsha aged off the re-ask list after ${REASK_MAX_SECONDS}s with no cp row — it was accused on every run in between, and the list is bounded, not forgiving"
    continue
  fi
  if crown_read "sha=$gsha" "$WORK/rows-graced-$gsha.json"; then
    grows="$(jq --arg sha "$gsha" '[.deliveries[] | select(.sha == $sha and .target == "cp")] | length' "$WORK/rows-graced-$gsha.json" 2>/dev/null)"
    [ -n "$grows" ] || grows=0
    if [ "$grows" -gt 0 ]; then
      say "  note: the graced sha $gsha was recorded after all — retired from the re-ask list"
      continue
    fi
    GRACED_RED=$((GRACED_RED + 1))
    printf '%s %s\n' "$gsha" "$gts" >> "$WORK/graced.txt"
    printf '%s %s\n' "$gsha" "$gts" >> "$WORK/reask-keep.txt"
  else
    reason "the crown could not be asked about the graced sha $gsha — it stays on the re-ask list and is NOT counted clean"
    printf '%s %s\n' "$gsha" "$gts" >> "$WORK/reask-keep.txt"
  fi
done < "$WORK/reask.txt"

if [ -n "$GRACED_THIS_RUN" ] && ! grep -q "^$GRACED_THIS_RUN " "$WORK/reask-keep.txt"; then
  printf '%s %s\n' "$GRACED_THIS_RUN" "$NOW_EPOCH" >> "$WORK/reask-keep.txt"
fi
state_save "$WORK/reask-keep.txt"

# ── the verdict ──────────────────────────────────────────────────────────────
pct() { # <numerator> <denominator>
  [ "${2:-0}" -gt 0 ] || { printf 'n/a'; return; }
  awk -v n="$1" -v d="$2" 'BEGIN { printf "%.1f%%", (n * 100) / d }'
}

say ""
say_reader
say ""
if [ "$PREDATES" -gt 0 ]; then
  say "PREDATES-WRITER: ${PREDATES} of ${DELIVERING} delivering run(s) were created before the record-delivery job existed (born ${RECORDER_BIRTH_ISO}, PR ${RECORDER_BIRTH_PR}, merge ${RECORDER_BIRTH_COMMIT}) — nothing could have recorded them, so they are NOT counted BEHIND. They are printed here rather than hidden by a narrower window:"
  while IFS=' ' read -r sha id; do
    say "    ${sha}  (run ${id}) — delivered before any recorder existed"
  done < "$WORK/predates.txt"
  say ""
fi
if [ "$BEHIND" -gt 0 ]; then
  say "BEHIND: ${BEHIND} of ${RECONCILABLE} delivering run(s) examined ($(pct "$BEHIND" "$RECONCILABLE")) delivered a sha the crown has NO row for:"
  while IFS=' ' read -r sha id; do
    say "    ${sha}  (run ${id}) — delivered, never recorded"
  done < "$WORK/behind.txt"
fi
if [ "$WRONG" -gt 0 ]; then
  say "WRONG: ${WRONG} of ${ROWS_EXAMINED} crown row(s) examined ($(pct "$WRONG" "$ROWS_EXAMINED")) were written by no delivering run:"
  while IFS=' ' read -r sha run; do
    if [ "${run:--}" = "-" ]; then
      say "    ${sha} — recorded with no delivering run id, and no delivering run has that head sha"
    else
      say "    ${sha} — recorded as delivered by run ${run}, which is not a delivering run in the window"
    fi
  done < "$WORK/wrong.txt"
fi
if [ "$SERVING_SKEW" -gt 0 ]; then
  say "SERVING-CLOCK-SKEW: barkpark.cloud reports serving_since ${SERVING_SINCE:-<none>}, which is ${SERVING_SKEW_AHEAD}s in the FUTURE. A grace granted off a clock that disagrees is not leniency, it is a fault — so the missing row below is ACCUSED rather than excused."
fi
if [ -n "$SERVING_INFLIGHT_EXPIRED" ]; then
  say "SERVING-INFLIGHT-EXPIRED: deploy.yml run ${SERVING_INFLIGHT_EXPIRED} for the serving sha has reported in_progress for ${SERVING_INFLIGHT_AGE}s (first-seen-charged), past the ${SERVING_INFLIGHT_CAP_SECONDS}s cap — a hung run is not an alibi, so the missing row below is ACCUSED rather than deferred again."
fi
if [ "$SERVING_RED" -gt 0 ]; then
  say "SERVING-UNRECORDED: barkpark.cloud reports it is SERVING ${SERVING_SHA} and the crown has no cp row for it — production is running a commit its own record has never heard of."
fi
if [ "$GRACED_RED" -gt 0 ]; then
  say "GRACED-UNRECORDED: ${GRACED_RED} sha(s) were granted the serving grace on an earlier run and STILL have no cp row. The grace was a DEFERRAL, and this is the deferred accusation — it fires whether or not the box still serves them:"
  while IFS=' ' read -r gsha gts; do
    say "    ${gsha}  (first seen $(iso_of "$gts"), $((NOW_EPOCH - gts))s ago) — graced, then never recorded"
  done < "$WORK/graced.txt"
fi

if [ "$BEHIND" -gt 0 ] || [ "$WRONG" -gt 0 ] || [ "$SERVING_RED" -gt 0 ] || [ "$GRACED_RED" -gt 0 ]; then
  say ""
  say "VERDICT: NOT reconciled — behind=${BEHIND}/${RECONCILABLE} delivering runs, wrong=${WRONG}/${ROWS_EXAMINED} rows, serving-unrecorded=${SERVING_RED}, graced-unrecorded=${GRACED_RED}, predates-writer=${PREDATES}/${DELIVERING}, reader=$(reader_answered), re-ask-list=${STATE_STATE}."
  exit 1
fi

if [ "$DELIVERING" -eq 0 ]; then
  # ── QUIET WINDOW (charter D597): an empty window on a VERIFIED crown ───────
  # A repo that stops merging empties this window BY CONSTRUCTION, and rc 2
  # here filed every 6 hours forever (6-run streak 2026-08-15..17, #11217 at 41
  # comments). Quiescence reads green ONLY when all three hold: (1) the serving
  # check verified the served sha has its cp row, (2) the re-ask list was
  # PRESENT-EMPTY, (3) zero ledger rows sit inside the window. Any OTHER
  # reason() than the reverse direction's structural no-alibi refusal is a real
  # silence and still outranks quiescence — the refusal itself is unavoidable
  # on an empty window and is repeated inside the deferral text below, because
  # a green here must not imply the reverse direction was checked.
  QUIET_OTHER_REASONS="$(grep -vxF "$NOALIBI_REASON" "$REASONS_FILE" 2>/dev/null | awk 'NF' | wc -l | tr -d ' ')"
  if [ "$SERVING_VERIFIED" = "1" ] && [ "$STATE_STATE" = "PRESENT-EMPTY" ] && [ "$QUIET_ROWS_READ" = "1" ] && [ "$QUIET_ROWS" -eq 0 ] && [ "${QUIET_OTHER_REASONS:-1}" -eq 0 ]; then
    say ""
    say "QUIET WINDOW: ${SUCCESS_COUNT}${FLOOR} successful run(s) in the window and none of them delivered — and the crown is VERIFIED as far as an empty window allows: the serving sha ${SERVING_SHA} has its cp row, the re-ask list was PRESENT-EMPTY (nothing graced is still owed a row), and ZERO crown row(s) sit inside the window (nothing was delivered and nothing claims to have been). This is a NAMED DEFERRAL, not a reconciliation: the verdict over a real population is deferred to the next run whose window holds one."
    say "  the reverse direction has no alibi source on an empty window and was NOT checked — quiescence-green does not imply the reverse direction was checked."
    say "::warning::QUIET WINDOW — zero delivering deploy.yml runs in the last ${WINDOW_HOURS}h on a verified crown (serving sha recorded, re-ask list PRESENT-EMPTY, zero in-window rows). A deferral, not a silence: paging here is what mutes the alarm for the one case that is not."
    exit 0
  fi
  say ""
  if [ "$QUIET_ROWS_READ" = "1" ] && [ "$QUIET_ROWS" -gt 0 ]; then
    # Rows-exist-but-no-runs is NOT quiescence and STAYS rc 2: a row claiming a
    # delivery no run made is an accusation source, unjudgeable without an
    # alibi population.
    say "ROWS WITHOUT RUNS: ${QUIET_ROWS} crown row(s) sit inside the window while NO delivering run does — a row with no run is an accusation source, not quiescence, so this stays a warning."
  fi
  say "COULD NOT VERIFY: the population was EMPTY — ${SUCCESS_COUNT}${FLOOR} successful run(s) in the window and none of them delivered. A rate with no denominator is refused, so this is a warning, not a green."
  exit 2
fi

if [ "$RECONCILABLE" -eq 0 ]; then
  say ""
  say "COULD NOT VERIFY: all ${DELIVERING} delivering run(s) in the window PREDATE the recorder's birth (${RECORDER_BIRTH_ISO}, PR ${RECORDER_BIRTH_PR}) — there is nothing a writer could have recorded, so the BEHIND denominator is zero. A rate with no denominator is refused, so this is a warning, not a green."
  exit 2
fi

# SILENCE OUTRANKS DEFERRAL, always. A run that both granted a grace and failed
# to read something is a run that failed to read something; checking rc 4 first
# would let one benign deferral launder a real silence into a warning.
if [ "$UNREADABLE" != "0" ]; then
  say ""
  REASON_COUNT="$(awk 'NF' "$REASONS_FILE" 2>/dev/null | wc -l | tr -d ' ')"
  say "COULD NOT FULLY READ: ${REASON_COUNT} unreadable condition(s) fired. Everything that COULD be read reconciled, but this run is NOT clean. Each condition, by name:"
  if [ "${REASON_COUNT:-0}" -eq 0 ]; then
    # UNREADABLE was set without going through reason(). The counters this
    # sentence used to print could be all zeros while it exited 2; an unnamed
    # silence is now a stated bug rather than a row of noughts.
    say "    - (unnamed — UNREADABLE was set without a reason, which is a BUG in this script)"
  else
    awk 'NF { c[$0]++; if (!($0 in seen)) { seen[$0] = 1; order[++n] = $0 } }
         END { for (i = 1; i <= n; i++) printf "    - %s%s\n", order[i], (c[order[i]] > 1 ? " (x" c[order[i]] ")" : "") }' "$REASONS_FILE"
  fi
  exit 2
fi

if [ "$DEFERRED" != "0" ]; then
  say ""
  DEFER_COUNT="$(awk 'NF' "$DEFERRALS_FILE" 2>/dev/null | wc -l | tr -d ' ')"
  say "NOT YET DUE: ${DEFER_COUNT} deferred condition(s) fired. Everything was READ, nothing is accused, and every accusation this run held back was written to the re-ask list — the next run that still finds no row fires GRACED-UNRECORDED and exits 1. This is a warning, not a page, and it is not a green either. Each deferral, by name:"
  if [ "${DEFER_COUNT:-0}" -eq 0 ]; then
    # DEFERRED was incremented without going through defer(). Same shape as the
    # unnamed-silence bug above, and stated for the same reason.
    say "    - (unnamed — DEFERRED was incremented without a deferral, which is a BUG in this script)"
  else
    awk 'NF { c[$0]++; if (!($0 in seen)) { seen[$0] = 1; order[++n] = $0 } }
         END { for (i = 1; i <= n; i++) printf "    - %s%s\n", order[i], (c[order[i]] > 1 ? " (x" c[order[i]] ")" : "") }' "$DEFERRALS_FILE"
  fi
  exit 4
fi

say ""
say "RECONCILED: all ${RECONCILABLE} delivering run(s) in the window have their row, all ${ROWS_EXAMINED} row(s) in the window have their run, the serving sha ${SERVING_SHA:-<not checked>} is recorded, and no earlier grace is still owed a row — read by $(reader_answered), against a re-ask list that was ${STATE_STATE} with ${STATE_LOADED} entry(ies)."
exit 0
