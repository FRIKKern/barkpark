#!/usr/bin/env bash
#
# THE TRIPWIRE FOR A COLUMN THAT CAN STOP BEING PRODUCED (dr-w28 follow-up).
#
# deploy.yml's record-delivery job emits `merged_at` only for a commit whose
# COMMITTER is GitHub's own merge machinery: a merge/squash commit's committer
# date IS the merge instant, while a commit pushed straight to main carries the
# author's local time, which is not a merge instant at all. That NULL arm is
# correct — but it keys on ONE hard-coded email, and nothing noticed if it
# moved. If merges ever start arriving under another identity (a merge queue, a
# bot, GitHub changing the address), EVERY row's `merged_at` goes NULL, the
# recorder still answers `delivered=true`, and a column quietly reads 100% null
# forever. A null that used to be a fabricated timestamp is an improvement; a
# column that silently empties is not something any reader will notice.
#
# So this script owns the literal — it is the SINGLE definition, and deploy.yml
# reads it from here via `--print-committer` — and it is also the check that
# LOSES when the literal stops matching reality: given the very lines the
# recorder built its rows from (`%H %cd %ce`), it re-derives the arm each row
# landed on and REFUSES when a batch big enough to mean something produced no
# timestamp at all while naming some other committer.
#
# It does NOT re-derive `merged_at` from anywhere else. D483 blessed the `%cd`
# producer; there is no GitHub API call here, per sha or otherwise, and this
# script never writes a row.
#
# Usage:
#   merged-at-committer-tripwire.sh --print-committer
#       Print the blessed committer email and exit 0. The one definition.
#
#   merged-at-committer-tripwire.sh <rangefile> [<rangefile> ...]
#       Each rangefile holds one row per line, `<sha> <committer-date> <email>`,
#       exactly as `git log --format='%H %cd %ce'` writes it. A file that does
#       not exist is SKIPPED, not an error: a leg that did not deploy leaves no
#       range behind.
#
#         exit 0  the batch produced at least one `merged_at`, or it was too
#                 small / too empty to mean anything (both said out loud).
#         exit 1  TRIPPED — see the ::error:: it prints.
#         exit 2  it could not measure (bad usage, unreadable input).
#
# Env:
#   TRIPWIRE_MIN_ROWS   how many all-NULL rows constitute a batch worth
#                       screaming about. Default 3. One or two NULL rows is an
#                       ordinary direct push to main; three in one batch, all
#                       committed by somebody who is not the blessed identity,
#                       is the identity having MOVED.

set -uo pipefail
# Word splitting is the POINT here (rows are space-separated fields), so glob
# expansion is turned OFF rather than trusted not to fire: an unquoted split of
# a line containing `*` would otherwise expand against the working directory.
set -f

# ── THE ONE DEFINITION ──────────────────────────────────────────────────────
# Every other copy of this address in the repo is a comment. deploy.yml's
# record-delivery job assigns `GITHUB_MERGE_COMMITTER` from `--print-committer`
# below, which is what makes mutating THIS line red the harness rather than
# silently retune production. 200/200 commits on main were committed by it when
# this was written.
BLESSED_MERGE_COMMITTER="noreply@github.com"

MIN_ROWS="${TRIPWIRE_MIN_ROWS:-3}"

case "${MIN_ROWS}" in
  '' | *[!0-9]*)
    echo "merged-at-committer-tripwire: TRIPWIRE_MIN_ROWS='${MIN_ROWS}' is not a number — refusing to guess" >&2
    exit 2
    ;;
esac

if [ "$#" -eq 0 ]; then
  echo "usage: merged-at-committer-tripwire.sh --print-committer | <rangefile> [<rangefile>...]" >&2
  exit 2
fi

if [ "$1" = "--print-committer" ]; then
  if [ "$#" -ne 1 ]; then
    echo "merged-at-committer-tripwire: --print-committer takes no other arguments" >&2
    exit 2
  fi
  printf '%s\n' "$BLESSED_MERGE_COMMITTER"
  exit 0
fi

total=0
produced=0
blank=0
read_any=0
# Parallel arrays rather than an associative array: this has to run under the
# /bin/sh-ish bash on any runner image, and a foreign-committer tally is at most
# a handful of entries.
foreign_emails=""
foreign_counts=""

tally_foreign() {
  seen_email="$1"
  new_emails=""
  new_counts=""
  found=0
  i=1
  for e in $foreign_emails; do
    c="$(printf '%s\n' "$foreign_counts" | cut -d' ' -f"$i")"
    if [ "$e" = "$seen_email" ]; then
      c=$((c + 1))
      found=1
    fi
    new_emails="${new_emails}${new_emails:+ }${e}"
    new_counts="${new_counts}${new_counts:+ }${c}"
    i=$((i + 1))
  done
  if [ "$found" -eq 0 ]; then
    new_emails="${new_emails}${new_emails:+ }${seen_email}"
    new_counts="${new_counts}${new_counts:+ }1"
  fi
  foreign_emails="$new_emails"
  foreign_counts="$new_counts"
}

for f in "$@"; do
  if [ ! -e "$f" ]; then
    echo "merged-at-committer-tripwire: ${f} does not exist — that leg produced no range, skipping"
    continue
  fi
  if [ ! -r "$f" ]; then
    echo "merged-at-committer-tripwire: ${f} exists and cannot be read — refusing to report a null-rate over a file it did not see" >&2
    exit 2
  fi
  read_any=1
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    # `<sha> <date> <email>`; neither a sha, an ISO timestamp nor an email can
    # contain a space, so a positional split is safe. A 2-field line is git
    # having printed NO committer email, which is its own arm below.
    # shellcheck disable=SC2086 # deliberate split into fields; globbing is off (set -f)
    set -- $line
    email="${3:-}"
    total=$((total + 1))
    if [ -z "$email" ]; then
      blank=$((blank + 1))
    elif [ "$email" = "$BLESSED_MERGE_COMMITTER" ]; then
      produced=$((produced + 1))
    else
      tally_foreign "$email"
    fi
  done < "$f"
done

if [ "$read_any" -eq 0 ]; then
  echo "merged-at-committer-tripwire: no range file existed — nothing was recorded this run, so there is no null-rate to report"
  exit 0
fi

if [ "$total" -eq 0 ]; then
  echo "merged-at-committer-tripwire: the range files held no rows — no null-rate to report"
  exit 0
fi

nulls=$((total - produced))
# Integer percent, floored. It is a headline, not an accounting figure.
null_pct=$(((nulls * 100) / total))
echo "merged_at: ${produced}/${total} row(s) carry a timestamp, ${nulls} NULL (null-rate ${null_pct}%), blessed committer ${BLESSED_MERGE_COMMITTER}"
if [ -n "$foreign_emails" ]; then
  i=1
  for e in $foreign_emails; do
    c="$(printf '%s\n' "$foreign_counts" | cut -d' ' -f"$i")"
    echo "merged_at: ${c} row(s) were committed by ${e}, which is NOT the blessed merge committer"
    i=$((i + 1))
  done
fi

if [ "$produced" -gt 0 ]; then
  echo "merged-at-committer-tripwire: the blessed committer still produces timestamps — not tripped"
  exit 0
fi

if [ "$total" -lt "$MIN_ROWS" ]; then
  echo "merged-at-committer-tripwire: ${total} row(s) produced no timestamp, below the ${MIN_ROWS}-row floor — an ordinary direct push to main looks exactly like this, so it is NOT tripped"
  exit 0
fi

if [ -z "$foreign_emails" ]; then
  echo "::warning::merged_at is NULL on all ${total} row(s) and git named NO committer on any of them — the producer read nothing to key on. That is not the identity having moved, so the tripwire does not fire, but it is not a healthy batch either."
  exit 0
fi

echo "::error::merged_at HAS STOPPED BEING PRODUCED: all ${total} row(s) in this batch landed on the NULL arm, and every one names a committer other than ${BLESSED_MERGE_COMMITTER} (see the lines above). The column is not empty because these commits were direct pushes — the merge identity itself has MOVED, and until scripts/merged-at-committer-tripwire.sh's BLESSED_MERGE_COMMITTER is updated to match it, EVERY future row's merged_at is NULL while the recorder keeps answering delivered=true."
exit 1
