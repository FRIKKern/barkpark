#!/usr/bin/env bash
# deploy-reliability-exit-run.sh — the only sanctioned way to TAKE the
# deploy-reliability epic's EXIT READING.
#
# It runs the owner's own `bp cloud deployments` over a PINNED window and prints
# the three numbers the epic exits on: live_rate, never_covered, and the
# environment split behind never_covered. It adds NO judgement of its own about
# the fleet. What it adds is a REFUSAL: the conditions under which the binary the
# reading came out of cannot be vouched for, and under which this wrapper
# declines to hand a number over at all.
#
# WHY THIS EXISTS (deploy-reliability wave 34)
#
#   Wave 33 ruled WIND DOWN, NOT YET ON THE INSTRUMENT. The fleet's numbers are
#   boring; the number REPORTING them read 0, 3 or 5 depending on where two dates
#   went, and the law governing that was pinned by nothing. Two separate things
#   were wrong at once:
#
#     1. THE WINDOW FLOATED. `--days N` ends at `now`, and there is no `--as-of`
#        flag, so two runs of the same command minutes apart are two different
#        windows. At the command's own default width (7 days) never_covered reads
#        0; at 14/21 it reads 2; at 23/24/26 it reads 3; at 27/30/45 it reads 5
#        and saturates. Every one of those is a correct answer to a different
#        question, and none of them is re-runnable. This wrapper refuses --days.
#
#     2. THE PRODUCER WAS NOT ON THE HISTORY. The `bp` on the owner's PATH is
#        built from 0789ab90a, which is NOT an ancestor of origin/main, and it
#        answers `bp cloud deployments` with `unknown cloud command` — the census
#        source file does not exist in that commit at all. A reading taken from a
#        binary off the history is indistinguishable, once pasted, from a reading
#        taken from the shipped one.
#
# THE REFUSALS — a refusal is NEVER a finding about the fleet
#
#   3  SHALLOW REPOSITORY      ancestry of the producer commit is decided against
#                              this object database. A shallow clone does not
#                              carry the history to decide it, and reports the
#                              same rc=128 an invented sha does.
#   4  CENSUS SOURCE DRIFT     the census command's source in this checkout is not
#                              origin/main's copy, so the rebuild this wrapper is
#                              about to recommend would mint yet another
#                              off-history binary.
#   5  PRODUCER OFF-HISTORY    `git merge-base --is-ancestor <producer> origin/main`
#                              answered rc=1: the commit exists here and is NOT on
#                              origin/main's history. The reading would describe
#                              some other program. Also fires post-run when the
#                              route echoes back a window that is not the one that
#                              was asked for.
#   6  UNAVAILABLE HISTORY     `--is-ancestor` answered rc=128: the producer commit
#                              is not in this object database at all, so ancestry
#                              could not be EVALUATED. That is "I could not look",
#                              and collapsing it into "not an ancestor" turns it
#                              into a confident refusal — do not. Also fires
#                              post-run when the census reports rows whose box
#                              marker was UNREADABLE.
#   7  UNUSABLE INPUT          no work tree, no origin ref, no producer binary, no
#                              provenance stamp on it, no JSON parser, `--days`,
#                              or a window that is not from < to. Nothing was read.
#
# EXIT CODES — the ratified taxonomy, reused verbatim from scripts/seal-run.sh
#
#   0  READING       a quotable exit reading
#   1  NEGATIVE      the route answered and its answer is a REFUSAL OF THE NUMBER
#                    (live_rate.refused) — a finding about the data, not the tree
#   2  INFRA FAULT   the producer exited non-zero, printed no parseable JSON, or
#                    the route errored (auth, 422, timeout)
#   3  REFUSED — shallow repository
#   4  REFUSED — census source drift
#   5  REFUSED — the producing binary is off origin/main's history
#   6  REFUSED — ancestry could not be evaluated / the census could not read rows
#   7  REFUSED — the inputs are unusable. Nothing was read.
#
#   0-2 are the reading's own triad. 3-7 are this wrapper's, and NONE of them is
#   a statement about deploy reliability. An operator who greps for a bad number
#   must never find one that actually meant "I was pointed at the wrong binary".
#
# WITHHOLDING. A post-run refusal (5 via the echoed window, 6 via unreadable
# rows) does NOT print the reading. A number that came out of a tree this wrapper
# cannot vouch for is exactly the artefact that gets pasted into a wave paper;
# printing it with a warning above it has already lost. Pass --show-withheld only
# when debugging, and accept that the digits are void.
#
# NOT A RE-POINT OF seal-run.sh. That script's `--predicate` flag is a decoy: its
# drift refusal compares against a hardcoded constant the flag never feeds, its
# interpreter and token grep are hardcoded, and the flag has zero coverage across
# its harness. Here every flag feeds the thing it names — `--bp` is the binary
# that is executed, `--repo` is the git database ancestry is asked of, `--from` /
# `--to` are the window that is sent — and each is exercised by the harness.
# seal-run.sh is not modified, not sourced, and not invoked.
#
# COST. `bp cloud deployments` is capped CLIENT-side at 90s
# (internal/cloudclient/client.go, FleetDeployCensusTimeout), applied absolutely
# with NO retry, and there is no server-side route budget. Observed serial cost:
# 44.2 / 45.4 / 49.1 / 56.7s at a 27-day width on a loaded host, and 39s for this
# script's own 39-day read on a quieter one — a 39-57s band against a 90s cap. A
# timeout here reads as a SLOW PLANE, not a broken gauge — and the route emits no
# request id, so a failed reading has no correlator.
#
# READ-ONLY. Every git call is a read (rev-parse, merge-base, hash-object). The
# census route is a GET. Nothing is fetched, written, checked out or created.
#
#   bash scripts/deploy-reliability-exit-run.sh
#   bash scripts/deploy-reliability-exit-run.sh --bp ./dist/bp --repo .
#
# Mutation proofs: bash scripts/deploy-reliability-exit-run.test.sh

set -uo pipefail

# The census command's source. Refusal 4 compares THIS path, and the remedy names
# THIS path — the two are the same string, read from the same variable.
CENSUS_SRC_REL="internal/cli/cloud_deploy_census_cmd.go"

# The pinned window. `from` sits at or before the oldest admitting instant
# (2026-07-14T11:28:18Z), so never_covered is at its saturation value; `to` is a
# fixed past instant, never `now`.
FROM="2026-07-01T00:00:00Z"
TO="2026-08-09T00:00:00Z"

BP="bp"
REPO=""
ORIGIN_REF="origin/main"
PY="${PYTHON:-python3}"
SHOW_WITHHELD=0

usage() {
  cat <<'EOF'
  bash scripts/deploy-reliability-exit-run.sh [options]

  --bp <path>          the producing binary to execute (default: bp from PATH)
  --repo <path>        the checkout ancestry is decided against (default: this script's repo root)
  --from <instant>     window start, RFC3339 (default: 2026-07-01T00:00:00Z)
  --to <instant>       window end, RFC3339 and never `now` (default: 2026-08-09T00:00:00Z)
  --origin-ref <ref>   the ref that defines "the shipped history" (default: origin/main)
  --show-withheld      print a withheld reading anyway (the digits are void)

  --days is REFUSED on purpose: its right edge is `now`, so the reading is not re-runnable.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --bp)          BP="${2-}"; shift 2 ;;
    --repo)        REPO="${2-}"; shift 2 ;;
    --from)        FROM="${2-}"; shift 2 ;;
    --to)          TO="${2-}"; shift 2 ;;
    --origin-ref)  ORIGIN_REF="${2-}"; shift 2 ;;
    --show-withheld) SHOW_WITHHELD=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    --days)        DAYS_SEEN=1; shift; [ $# -gt 0 ] && shift ;;
    --days=*)      DAYS_SEEN=1; shift ;;
    *) echo "deploy-reliability-exit-run: unknown argument: $1" >&2; usage >&2; exit 7 ;;
  esac
done

[ -z "$REPO" ] && REPO="$(cd "$(dirname "$0")/.." && pwd)"

# ---------------------------------------------------------------------------
# Refusals are COLLECTED, not short-circuited: a stale checkout of a shallow
# clone trips three at once, and an operator who fixes only the one they were
# told about comes straight back. The exit code is the FIRST refusal in
# evaluation order (the most fundamental), but every one is printed.
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
  echo "deploy-reliability-exit-run: REFUSED TO READ — no exit reading was taken."
  echo "=============================================================================="
  for entry in "${REFUSALS[@]}"; do
    IFS=$'\x1f' read -r code head remedy <<<"$entry"
    echo
    echo "  [exit $code] $head"
    echo "    do this: $remedy"
  done
  echo
  echo "  Every line above is a fact about the BINARY and the CHECKOUT at $REPO."
  echo "  None of it is a statement about deploy reliability, and none of it is a"
  echo "  live_rate, a never_covered, or any other number about the fleet."
  echo
}

# The remedy for an off-history producer, in ONE place so it can never drift into
# the `make cli-install` half. Rebuilding from a diverged checkout mints the SAME
# diverged binary — which is the loop `make doctor` currently prints.
rebuild_remedy() {
  echo "git -C $REPO pull --rebase   THEN   make cli-install   (cli-install alone rebuilds the same diverged checkout)"
}

# ---------------------------------------------------------------------------
# UNUSABLE INPUT (exit 7) — short-circuits: none of the other refusals is even
# askable without a work tree, an origin ref, a producer and a JSON parser.

if [ -n "${DAYS_SEEN-}" ]; then # MUT:G-DAYS
  refuse 7 "--days is refused: a --days window's right edge is \`now\`, and there is no --as-of flag, so two runs minutes apart read two different windows (never_covered reads 0 at the built-in 7-day default and 5 at 27 days or wider)." \
           "pass an explicit --from/--to instead, e.g. --from $FROM --to $TO"
  report_refusals; exit 7
fi

if [ ! -d "$REPO" ] || ! git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  refuse 7 "--repo $REPO is not a git work tree, so the producer's ancestry cannot be decided against anything." \
           "point --repo at a checkout of this repository"
  report_refusals; exit 7
fi
REPO="$(cd "$REPO" && pwd)"

if ! command -v "$PY" >/dev/null 2>&1; then
  refuse 7 "no JSON parser: \`$PY\` is not on PATH, so the census envelope cannot be read." \
           "install python3, or set PYTHON=<a python3 on this host>"
  report_refusals; exit 7
fi

BP_RESOLVED="$(command -v "$BP" 2>/dev/null || true)"
if [ -z "$BP_RESOLVED" ]; then
  refuse 7 "the producing binary \`$BP\` is not executable from here, so there is nothing to take a reading with." \
           "pass --bp <path to a bp built from a commit on $ORIGIN_REF>, or run make cli-install"
  report_refusals; exit 7
fi

ORIGIN_SHA="$(git -C "$REPO" rev-parse --verify --quiet "$ORIGIN_REF^{commit}" || true)"
if [ -z "$ORIGIN_SHA" ]; then
  refuse 7 "$ORIGIN_REF does not resolve in $REPO, so there is no shipped history to judge the producer against." \
           "git -C $REPO fetch origin main   (then re-run)"
  report_refusals; exit 7
fi

if [ -z "$FROM" ] || [ -z "$TO" ] || ! [ "$FROM" \< "$TO" ]; then
  refuse 7 "the window is not from < to (--from '$FROM' --to '$TO'); a half-open or inverted window is not a reading." \
           "pass --from and --to as RFC3339 instants with from strictly before to"
  report_refusals; exit 7
fi

# ---------------------------------------------------------------------------
# THE PRODUCER'S PROVENANCE. `bp version -o json` carries the commit that was
# stamped in by -ldflags. A bare `go build` leaves it EMPTY and the key is
# omitted entirely — absent provenance is a REFUSAL, never an assumption.
VERSION_JSON="$("$BP_RESOLVED" version -o json 2>/dev/null || true)"
PRODUCER_COMMIT="$(printf '%s' "$VERSION_JSON" | "$PY" -c '
import json,sys
try: d = json.load(sys.stdin)
except Exception: d = {}
c = d.get("commit") or ""
print(c if isinstance(c, str) else "")
' 2>/dev/null || true)"

if [ -z "$PRODUCER_COMMIT" ] || [ "$PRODUCER_COMMIT" = "unknown" ]; then # MUT:G-NOSTAMP
  refuse 7 "$BP_RESOLVED carries NO commit stamp (\`bp version -o json\` printed ${VERSION_JSON:-<nothing>}) — a plain \`go build\` omits the key, so this binary's provenance is unknowable and its reading is unattributable." \
           "make cli-install   (it stamps cliCommit via -ldflags and refuses to install an unstamped binary)"
fi

# ---------------------------------------------------------------------------
# REFUSAL 3 — SHALLOW REPOSITORY. Reported in its own right because a shallow
# clone is the ordinary cause of the rc=128 below, and an operator told only
# "unknown commit" would go looking for the wrong thing.
SHALLOW="$(git -C "$REPO" rev-parse --is-shallow-repository 2>/dev/null || echo unknown)"
if [ "$SHALLOW" = "true" ]; then # MUT:G-SHALLOW
  refuse 3 "$REPO is a SHALLOW repository — the producer's ancestry cannot be evaluated against a history that is not here." \
           "git -C $REPO fetch --unshallow   (or point --repo at a full-history worktree)"
fi

# ---------------------------------------------------------------------------
# REFUSAL 4 — CENSUS SOURCE DRIFT. Compared as git blob ids, so this is byte
# identity and not a line count. It matters because the remedy for every other
# refusal here is "rebuild from this checkout": if the checkout's census source
# is not the shipped one, that rebuild mints a binary this wrapper would have to
# refuse all over again.
WANT_BLOB="$(git -C "$REPO" rev-parse --verify --quiet "$ORIGIN_REF:$CENSUS_SRC_REL" || true)"
HAVE_BLOB=""
[ -f "$REPO/$CENSUS_SRC_REL" ] && HAVE_BLOB="$(git -C "$REPO" hash-object "$REPO/$CENSUS_SRC_REL" 2>/dev/null || true)"
if [ -n "$WANT_BLOB" ] && [ "$WANT_BLOB" != "$HAVE_BLOB" ]; then # MUT:G-DRIFT
  refuse 4 "the census source in this checkout is NOT $ORIGIN_REF's copy of $CENSUS_SRC_REL (blob ${HAVE_BLOB:0:9} vs ${WANT_BLOB:0:9}) — rebuilding here would mint a different program under the same name." \
           "git -C $REPO checkout $ORIGIN_REF -- $CENSUS_SRC_REL   (or point --repo at a worktree parked at $ORIGIN_REF)"
fi

# ---------------------------------------------------------------------------
# REFUSALS 5 AND 6 — ANCESTRY, ON THREE OUTCOMES.
#
# `git merge-base --is-ancestor` answers with THREE exit codes, and the third is
# the one that matters:
#   0    the commit is on $ORIGIN_REF's history  -> current (it IS the tip) or behind
#   1    the commit is HERE and is not on it     -> refusal 5
#   128  the commit is not in this object database at all -> unknown (refusal 6)
#
# NOTE ON THE WORD, so this file and tooling/grip/provenance.mjs cannot be read
# as disagreeing: provenance.mjs grades FIVE rungs and separates `diverged` from
# `ahead_of_main`. rc=1 here covers BOTH of them — a commit ahead of main is
# also not on main's history — and this script does not need to tell them apart,
# because the LAW is the same for both: quotable iff ancestry is current or
# behind, so both refuse with 5. The refusal text below therefore says "is NOT
# on origin/main's history", which is true of either rung, and never claims the
# narrower word `diverged` at the operator.
# Both were measured on the owner's host: rc=1 for the PATH binary's real commit
# 0789ab90a, rc=128 for an invented sha. Collapsing 128 into "not an ancestor"
# turns "I could not look" into a confident refusal.
ANCESTRY="unknown"
if [ -n "$PRODUCER_COMMIT" ]; then
  git -C "$REPO" merge-base --is-ancestor "$PRODUCER_COMMIT" "$ORIGIN_SHA" >/dev/null 2>&1
  ANC_RC=$?
  case "$ANC_RC" in
    0) if [ "$(git -C "$REPO" rev-parse --verify --quiet "$PRODUCER_COMMIT^{commit}" || true)" = "$ORIGIN_SHA" ]; then
         ANCESTRY="current"
       else
         ANCESTRY="behind"
       fi ;;
    # rc=1 is "not on main's history" and covers BOTH provenance.mjs rungs
    # `diverged` and `ahead_of_main`; this script never has to separate them
    # because both are non-quotable and both refuse with 5. Named for the law
    # it triggers, not for one of the two rungs it might be.
    1)   ANCESTRY="off_history" ;;
    128) ANCESTRY="unknown" ;;
    *)   ANCESTRY="unknown" ;;
  esac
fi

# QUOTABLE <=> ancestry IN {current, behind}. Anything else fails closed.
if [ "$ANCESTRY" = "off_history" ]; then # MUT:G-DIVERGED
  refuse 5 "the producing binary was built from $PRODUCER_COMMIT, which EXISTS here and is NOT on $ORIGIN_REF's history (--is-ancestor rc=1) — its reading describes a program that was never shipped." \
           "$(rebuild_remedy)"
fi
if [ -n "$PRODUCER_COMMIT" ] && [ "$ANCESTRY" = "unknown" ]; then # MUT:G-UNKNOWNANC
  refuse 6 "the producing binary names commit $PRODUCER_COMMIT, which is NOT IN THIS OBJECT DATABASE (--is-ancestor rc=128) — ancestry could not be evaluated at all. This is 'I could not look', not 'it is off the history'." \
           "git -C $REPO fetch origin main (and --unshallow if this clone is shallow), then re-run; if the commit is still unknown, the binary came from somewhere this checkout cannot see"
fi

# A pre-flight refusal means the census is NEVER CALLED. Refusing afterwards
# would still leave a number in the terminal for someone to quote.
if [ "$REFUSAL_CODE" -ne 0 ]; then
  echo "deploy-reliability-exit-run: the census was NOT called." >&2
  report_refusals
  echo "  producer: $BP_RESOLVED  commit=${PRODUCER_COMMIT:-<absent>}  ancestry=$ANCESTRY  ($ORIGIN_REF tip ${ORIGIN_SHA:0:9})"
  exit "$REFUSAL_CODE"
fi

# ---------------------------------------------------------------------------
# THE READING. Buffered, because whether it may be shown at all is not known
# until the envelope has been adjudicated.
OUT_FILE="$(mktemp -t dr-exit-run.XXXXXX)"
RENDER_FILE="$(mktemp -t dr-exit-render.XXXXXX)"
trap 'rm -f "$OUT_FILE" "$RENDER_FILE"' EXIT

echo "deploy-reliability-exit-run: calling the census over [$FROM .. $TO] — observed cost band 39-57s, client cap 90s applied absolutely with no retry." >&2
START_TS=$(date +%s)
"$BP_RESOLVED" cloud deployments --from "$FROM" --to "$TO" >"$OUT_FILE" 2>&1
BP_EXIT=$?
ELAPSED=$(( $(date +%s) - START_TS ))

# The renderer. It reads ONLY the fields the exit reading is defined over, and it
# never computes a fleet failure percentage: `failure_rate` is refused by the
# route itself at every window width from 7 to 45 days, because all of them
# straddle the deferred-settle boundary at 2026-08-05T21:13:50Z. This wrapper
# prints that refusal and its reason, and no percentage.
READ_STATUS="$("$PY" - "$OUT_FILE" "$FROM" "$TO" "$RENDER_FILE" <<'PYEOF'
import json, sys

raw_path, want_from, want_to, render_path = sys.argv[1:5]
with open(raw_path) as fh:
    raw = fh.read()
try:
    d = json.loads(raw)
except Exception:
    print("UNPARSEABLE")
    sys.exit(0)
if not isinstance(d, dict):
    print("UNPARSEABLE")
    sys.exit(0)
if d.get("ok") is False or "error" in d:
    err = d.get("error") or {}
    print("ROUTE-ERROR\t%s\t%s" % (err.get("code", "?"), err.get("message", "?")))
    sys.exit(0)

win = d.get("window") or {}
got_from, got_to = win.get("from"), win.get("to")

cov = d.get("coverage_cohorts") or {}
cohorts = cov.get("cohorts") or []
never = sum(int(c.get("never_covered") or 0) for c in cohorts)
unreadable = sum(int(c.get("unreadable") or 0) for c in cohorts)
too_young = sum(int(c.get("too_young") or 0) for c in cohorts)
pending = sum(int(c.get("pending") or 0) for c in cohorts)
split = {}
for c in cohorts:
    for e in (c.get("never_covered_by_environment") or []):
        split[e.get("environment", "?")] = split.get(e.get("environment", "?"), 0) + int(e.get("never_covered") or 0)

lr = d.get("live_rate") or {}
fr = d.get("failure_rate") or {}
comp = d.get("completeness") or {}

lines = []
w = lines.append
w("  window        [%s .. %s]   (pinned, both edges explicit; never --days)" % (got_from, got_to))
w("  as_of         %s   (coverage is bounded on the LEFT only — a later live build still counts)" % (cov.get("as_of") or "?"))
w("  population    volume=%s  live=%s  failed=%s  in_flight=%s  cancelled=%s  sites=%s of %s registered"
  % (d.get("volume"), d.get("live"), d.get("failed"), d.get("in_flight"), d.get("cancelled"),
     d.get("total_sites"), ((d.get("scope") or {}).get("registered_sites"))))
w("")
if lr.get("refused"):
    w("  live_rate     REFUSED — %s" % lr.get("reason"))
else:
    w("  live_rate     %s%%   (%s live of %s attempted)" % (lr.get("pct"), lr.get("numerator"), lr.get("sample")))
w("  never_covered %d   (rows still not followed by a later live build on their site, past the %ss maturity fence)"
  % (never, cov.get("maturity_seconds")))
if split:
    w("  split         %s" % "  ".join("%s=%d" % (k, v) for k, v in sorted(split.items(), key=lambda kv: -kv[1])))
else:
    w("  split         (none — never_covered is 0)")
w("  beside it     too_young=%d  pending=%d  unreadable=%d   (counted BESIDE never_covered, never inside it)"
  % (too_young, pending, unreadable))
w("")
w("  failure_rate  REFUSED — %s" % (fr.get("reason") or "the route did not publish a reason"))
w("                This wrapper prints NO fleet failure percentage. The refusal holds at every")
w("                window width from 7 to 45 days: all of them straddle the deferred-settle")
w("                boundary, and a window narrow enough to avoid it reads never_covered=0.")
w("  completeness  audited=%s accounted=%s unaccounted=%s balanced=%s"
  % (comp.get("audited"), comp.get("accounted"), comp.get("unaccounted"), str(comp.get("balanced")).lower()))
w("")
w("  the sites behind the non-zero are NOT on this wire: the route publishes never_covered by")
w("  ENVIRONMENT only, with no site ids attached. Naming them is dr-w34-s1's row.")

with open(render_path, "w") as fh:
    fh.write("\n".join(lines) + "\n")

status = "OK"
if got_from != want_from or got_to != want_to:
    status = "WINDOW-MISMATCH\t%s\t%s" % (got_from, got_to)
elif unreadable > 0:
    status = "UNREADABLE\t%d" % unreadable
elif lr.get("refused"):
    status = "LIVE-RATE-REFUSED\t%s" % (lr.get("reason") or "?")
print(status)
PYEOF
)"

STATUS_KIND="${READ_STATUS%%$'\t'*}"
STATUS_REST="${READ_STATUS#*$'\t'}"
[ "$STATUS_REST" = "$READ_STATUS" ] && STATUS_REST=""
STATUS_REST="$(printf '%s' "$STATUS_REST" | tr '\t' '|')"

# ---------------------------------------------------------------------------
# INFRA FAULT (exit 2) — the producer answered, but not with a census. This is
# NOT a refusal and NOT a finding: it is the plane being unavailable.
if [ "$BP_EXIT" -ne 0 ] || [ "$STATUS_KIND" = "UNPARSEABLE" ] || [ "$STATUS_KIND" = "ROUTE-ERROR" ]; then
  echo
  echo "deploy-reliability-exit-run: INFRA FAULT (exit 2) — no reading was taken."
  echo "  the producer exited $BP_EXIT after ${ELAPSED}s (client cap is 90s, applied absolutely, no retry)."
  case "$STATUS_KIND" in
    ROUTE-ERROR) echo "  the route named its own refusal: $STATUS_REST" ;;
    UNPARSEABLE) echo "  the output was not a JSON census envelope:"; sed 's/^/    | /' "$OUT_FILE" | head -20 ;;
  esac
  echo "  a timeout at ~90s is a SLOW PLANE, not a broken gauge — and the route emits no request id,"
  echo "  so a failed reading has no correlator. Re-run before concluding anything."
  exit 2
fi

# ---------------------------------------------------------------------------
# POST-RUN REFUSALS — these WITHHOLD the reading.
if [ "$STATUS_KIND" = "WINDOW-MISMATCH" ]; then # MUT:G-WINDOW
  refuse 5 "the route echoed back window [$STATUS_REST], which is not the window that was asked for [$FROM .. $TO] — the number describes some other span of time." \
           "re-run and compare the echoed window; if it still disagrees, the producing binary is rewriting the window it was given"
fi
if [ "$STATUS_KIND" = "UNREADABLE" ]; then # MUT:G-UNREADABLE
  refuse 6 "the census reports $STATUS_REST row(s) whose box content marker could not be read, so those rows cannot be classified as covered or never-covered at all. That is not a finding about deploy reliability." \
           "re-run the reading once the boxes are answering; until then the coverage number has a hole of unknown sign"
fi

if [ "$REFUSAL_CODE" -ne 0 ]; then
  echo "deploy-reliability-exit-run: the reading is WITHHELD — it was taken over an envelope that cannot be quoted." >&2
  if [ "$SHOW_WITHHELD" -eq 1 ]; then
    echo "  --show-withheld: the digits below are VOID." >&2
    cat "$RENDER_FILE"
  fi
  report_refusals
  exit "$REFUSAL_CODE"
fi

# ---------------------------------------------------------------------------
# VOUCHED. The producer is on the shipped history, the window came back the way
# it went out, and every row was readable.
echo
echo "=============================================================================="
echo "DEPLOY-RELIABILITY EXIT READING"
echo "=============================================================================="
cat "$RENDER_FILE"
echo
echo "  producer      $BP_RESOLVED  commit=$PRODUCER_COMMIT  ancestry=$ANCESTRY vs $ORIGIN_REF (tip ${ORIGIN_SHA:0:9})"
echo "  cost          ${ELAPSED}s   (observed band 39-57s; client cap 90s, absolute, no retry, no request id)"
echo "  what this is  a STUCK-SITE detector. It cannot tell an abandoned site from a stuck one,"
echo "                the preview arm is uncoverable by construction, and at the command's own"
echo "                default width (--days 7) this same number reads 0."
echo

if [ "$STATUS_KIND" = "LIVE-RATE-REFUSED" ]; then
  echo "deploy-reliability-exit-run: NEGATIVE (exit 1) — the route refused live_rate itself: $STATUS_REST"
  echo "  That is a finding about the DATA, not about this checkout. never_covered above still stands."
  exit 1
fi

echo "deploy-reliability-exit-run: READING (exit 0) — quotable."
exit 0
