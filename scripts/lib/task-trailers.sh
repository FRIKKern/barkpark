#!/usr/bin/env bash
# shellcheck shell=bash
# ── THE `Task:` TRAILER GRAMMAR — ONE COPY, SOURCED BY BOTH READERS ──────────
#
# There are TWO texts that can carry a `Task:` trailer, and this repo has one
# reader for each:
#
#   the PR BODY            read by scripts/pr-task-gate.sh   (the required
#                          `PR references an active task` merge gate)
#   the COMMIT MESSAGE     read by scripts/landed-mark.sh    (credits the row
#                          once the squash lands on main)
#
# They are NOT the same text. This repo's squash setting is COMMIT_MESSAGES
# (measured 2026-09-09, task-6275588f44322ab9), so the commit GitHub writes on
# main carries the BRANCH COMMITS' messages and not the PR body. Both readers
# therefore see a text the other cannot, and each has already been bitten by
# owning its own regex:
#
#   • #5290 went RED on a correct trailer while #5307 went green with the same
#     id written bare, because the grammar then lived inline in the workflow
#     YAML where no test could reach it and it dropped backtick-wrapped ids.
#   • task-6275588f44322ab9: landed-mark read ONLY the commit body, missed a
#     trailer that lived in the PR body, and left 3 rows unmarked.
#   • task-ee5b82efaee0fb0b (this file's reason for existing): the gate read
#     ONLY the PR body, so PR #19417 merged as 9f931a6f8 carrying
#     `Task: task-PENDING-nightly` — a row that does not exist — while its body
#     named a real one. git log is what a future auditor reads, and the gate
#     meant to prevent exactly that could not see the text it lands.
#
# So the grammar lives HERE, in one sourceable file with its own selftest
# (`bash scripts/lib/task-trailers.sh --selftest`), and the readers hold no
# second copy of the regex.
#
# ACCEPTED — case-insensitive, at COLUMN 0, surrounding backticks stripped:
#     Task: cch-bl-some-slug
#     Task: `cch-bl-some-slug`
#     task:   `cch-bl-some-slug`
#
# DELIBERATELY NOT ACCEPTED — each would be its own decision, not a wider
# character class, and each yields NO id (which the callers turn into their own
# verdict, never into a silent pass):
#   • a trailer that is not at the start of its line — "see Task: x" mid-sentence
#   • other markdown wrappers — **Task:** x, _x_, [x](url), <x>, "x"
#   • a bare id with no `Task:` label, or a `Task:` label with no id after it
#
# COLUMN 0 IS LOAD-BEARING. Arbitrary leading whitespace used to be allowed, so
# an EXAMPLE trailer quoted inside a fenced code block MATCHED. This fleet's
# briefs, PR bodies and handoff messages quote real, currently-claimed ids
# constantly — the realistic vector was never a crafted attack, it was a routine
# paste. A quoted example is not at column 0.
#
# AND IT NEVER PICKS. `head -1` resolved ambiguity BY POSITION and `tail -1`
# would have been exactly as wrong — it does not remove the hijack, it only
# changes which quote wins. A GATE THAT RESOLVES AMBIGUITY BY POSITION IS
# GUESSING, AND A GUESS IN A MERGE GATE IS A GUESS IN THE PERMISSIVE DIRECTION.
# The same id repeated is not ambiguity (a body may restate its own trailer), so
# ids are deduplicated BEFORE they are counted.

# task_trailer_ids <text> — every DISTINCT column-0 `Task:` id, one per line.
# Always rc 0: "no trailer" is an ANSWER (empty stdout), never a failure. The
# `|| true` is why — grep exits 1 on no match, and under a caller's `pipefail`
# that would turn silence into an error the caller cannot distinguish from a
# broken read.
task_trailer_ids() {
  printf '%s' "${1-}" \
    | grep -ioE '^task:[[:space:]]*`?[a-z0-9][a-z0-9._/-]*`?' \
    | sed -E 's/^[Tt][Aa][Ss][Kk]:[[:space:]]*//' \
    | tr -d '`' \
    | awk 'NF && !seen[$0]++' || true
}

# task_trailer_count <text> — how many DISTINCT ids the grammar sees. Printed so
# a caller can assert the scan was NOT EMPTY: a positive control that does not
# check this proves nothing, because a scan that reads zero trailers passes
# every "all trailers resolve" rule vacuously.
task_trailer_count() {
  local ids; ids="$(task_trailer_ids "${1-}")"
  printf '%s' "$ids" | grep -c . || true
}

# task_trailer_single <text> — the ONE id, or rc 4 (AMBIGUOUS) with the
# offending ids on stderr. Empty stdout + rc 0 when there is no trailer at all.
# Ambiguity gets its own code because it must not be reported as absence: the
# author of an ambiguous body HAS named their task, and telling them to add a
# trailer they already wrote is the kind of wrong instruction that gets a gate
# worked around rather than satisfied.
task_trailer_single() {
  local ids n
  ids="$(task_trailer_ids "${1-}")"
  n="$(printf '%s' "$ids" | grep -c . || true)"
  case "$n" in
    ''|0) return 0 ;;
    1)    printf '%s' "$ids"; return 0 ;;
  esac
  printf 'ambiguous task reference — %s distinct `Task:` ids at column 0: %s. Exactly one is required: keep the real trailer at column 0 and indent, fence or reword every example id.\n' \
    "$n" "$(printf '%s' "$ids" | tr '\n' ' ' | sed 's/ *$//')" >&2
  return 4
}

# ── SELFTEST ────────────────────────────────────────────────────────────────
# Runs on every PR: scripts/pr-task-gate.test.sh calls it, and that harness is
# the `PR task gate self-test` job in .github/workflows/pr-task-gate.yml, which
# has NO paths filter. So this file is covered on every PR including the ones
# that edit it — no shell-harnesses.yml row is needed or wanted.
if [ "${1:-}" = "--selftest" ]; then
  tt_pass=0; tt_fail=0
  tt() { # tt <label> <expected-stdout-with-|-between-ids> <text>
    local label="$1" want="$2" text="$3" got
    got="$(task_trailer_ids "$text" | tr '\n' '|' | sed 's/|$//')"
    if [ "$got" = "$want" ]; then tt_pass=$((tt_pass+1)); printf 'ok   %-46s\n' "$label"
    else tt_fail=$((tt_fail+1)); printf 'FAIL %-46s want [%s] got [%s]\n' "$label" "$want" "$got"; fi
  }
  tt "bare id"              "task-aaa"  "$(printf 'subject\n\nTask: task-aaa\n')"
  tt "backticked id"        "task-aaa"  "$(printf 'subject\n\nTask: `task-aaa`\n')"
  tt "lowercase label"      "task-aaa"  "$(printf 'task:   task-aaa\n')"
  tt "no trailer"           ""          "$(printf 'subject\n\nbody prose\n')"
  tt "indented is ignored"  ""          "$(printf 'subject\n\n    Task: task-quoted\n')"
  tt "mid-sentence ignored" ""          "$(printf 'see Task: task-quoted for details\n')"
  tt "dedup repeats"        "task-aaa"  "$(printf 'Task: task-aaa\nTask: task-aaa\n')"
  tt "two distinct, both"   "task-aaa|task-bbb" "$(printf 'Task: task-aaa\nTask: task-bbb\n')"
  # The MULTI-COMMIT shape this file was added for: several branch commits
  # concatenated, one real row and one that does not exist. BOTH must come back
  # — the caller decides, and a grammar that returned only the first would hide
  # exactly the dead pointer the gate now refuses.
  tt "concatenated commits" "task-real|task-PENDING-nightly" \
    "$(printf 'fix(a): one\n\nTask: task-real\n\nfix(b): two\n\nTask: task-PENDING-nightly\n')"

  tts() { # tts <label> <expected-rc> <text>
    local label="$1" want="$2" text="$3" got
    task_trailer_single "$text" >/dev/null 2>&1; got=$?
    if [ "$got" = "$want" ]; then tt_pass=$((tt_pass+1)); printf 'ok   %-46s (rc %s)\n' "$label" "$got"
    else tt_fail=$((tt_fail+1)); printf 'FAIL %-46s want rc %s got %s\n' "$label" "$want" "$got"; fi
  }
  tts "single: one id is rc 0"       0 "$(printf 'Task: task-aaa\n')"
  tts "single: no trailer is rc 0"   0 "$(printf 'nothing here\n')"
  tts "single: two distinct is rc 4" 4 "$(printf 'Task: task-aaa\nTask: task-bbb\n')"
  tts "single: repeat is not rc 4"   0 "$(printf 'Task: task-aaa\nTask: task-aaa\n')"

  # COUNT is what a positive control asserts on. Pin both ends: a scan that
  # reads zero satisfies "every trailer resolves" vacuously.
  if [ "$(task_trailer_count "$(printf 'Task: task-aaa\nTask: task-bbb\n')")" = "2" ] \
     && [ "$(task_trailer_count "no trailer at all")" = "0" ]; then
    tt_pass=$((tt_pass+1)); printf 'ok   %-46s\n' "count: 2 for two ids, 0 for none"
  else
    tt_fail=$((tt_fail+1)); printf 'FAIL %-46s\n' "count: 2 for two ids, 0 for none"
  fi

  echo "task-trailers selftest: passed $tt_pass  failed $tt_fail"
  [ "$tt_fail" = 0 ]
  exit $?
fi
