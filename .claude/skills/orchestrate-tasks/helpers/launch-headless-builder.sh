#!/usr/bin/env bash
#
# launch-headless-builder.sh — the ONE launch recipe for a headless `claude -p`
# builder, and the post-mortem that tells a ceiling-kill from a normal finish.
#
# WHY (task-018fc84f61c33923, MEASURED 2026-09-05 by lead-search: five headless
# builders, five deaths, one cause). A builder launched as
#
#     nohup claude -p "<prompt>" --model opus --dangerously-skip-permissions
#
# TERMINATES ITS OWN BACKGROUND TASKS after 600 s. The CLI says so once, and
# only when it happens:
#
#     Background tasks still running after 600s; terminating.
#     Set CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 to wait indefinitely.
#
# On this repo an Elixir gate cannot beat that ceiling under load: `mix test` in
# a fresh worktree compiles ~75 deps from scratch and a campaign routinely puts
# the box at load 80-100 with dozens of peer `mix` runs contending for one
# machine-wide compile slot.
#
# WHY IT LOOKS LIKE SOMETHING ELSE. The builder does the analysis, writes the
# code, and dies before it can gate, commit or push. The exit is CLEAN — the
# transcript ends on a calm "waiting for the compile" line and the SessionEnd
# hooks fire normally — so it reads as a model that ran out of things to say,
# not as a killed process. Two of the five reported real progress in their last
# line and left 14 modified files uncommitted. Nothing warned the launching
# lead; the cause was found only because ONE of the five happened to print the
# ceiling message, and all five logs were then read together.
#
# THE SIGNATURE OF A CEILING-KILL, so a lead never has to read five logs side
# by side again (`--check` below decides it mechanically):
#   * the log's last lines are CALM — a note about waiting, no error, no summary
#   * the worktree is DIRTY: modified files, no commit, no branch pushed
#   * and, only sometimes, the "Background tasks still running after" line
# The third is the only unambiguous one and it is the one that is usually
# missing, which is why `--check` also weighs the first two.
#
# THE BELT AND THE BRACES, all three, because they are load-bearing TOGETHER:
#   BELT    CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 — this script exports it.
#   BRACES  gates run in the FOREGROUND through the machine-wide slot
#           (helpers/with-slot.sh, or the mix/go PATH wrappers). Never `&`,
#           never run_in_background: backgrounding a compile is precisely what
#           exposes it to the ceiling.
#   SLOT    helpers/with-slot.sh caps heavy gates at SLOTS (default 3) across
#           every lead and worker. On 2026-09-05 $ORCH/.slots was EMPTY while
#           the box sat at load 100 killing builders — ten lanes compiling at
#           once against a semaphore built to stop exactly that.
#
# USAGE
#   launch-headless-builder.sh --prompt <file> --log <file> [--model opus] \
#       [--worktree <dir>] [--cwd <dir>] [-- <extra claude args>]
#   launch-headless-builder.sh --check <log> [--worktree <dir>]
#   launch-headless-builder.sh --print-recipe     # the three lines, for a doc
#   launch-headless-builder.sh --selftest
#
# --check EXIT: 0 clean finish · 1 CEILING-KILL (or a suspected one) · 2 cannot
# measure (the log is missing/unreadable — never folded into "clean").
#
# bash 3.2 compatible (macOS system bash).

set -uo pipefail

SELF="${BASH_SOURCE[0]}"

# The terminating line the CLI prints, as a grep pattern. Kept in ONE place so
# the harness asserts the same string the checker looks for.
CEILING_PATTERN='Background tasks still running after'
CEILING_HINT='CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS'

die() { echo "launch-headless-builder.sh: $*" >&2; exit 2; }

print_recipe() {
  cat <<'EOR'
# THE LAUNCH RECIPE — all three lines, always.
CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 nohup claude -p "$(cat prompt.md)" \
  --model opus --dangerously-skip-permissions > "$LOG" 2>&1 &
# then, when it exits:
bash .claude/skills/orchestrate-tasks/helpers/launch-headless-builder.sh --check "$LOG" --worktree "$WT"
EOR
}

cmd_launch() {
  local prompt="" log="" model="opus" wt="" cwd="" 
  while [ $# -gt 0 ]; do
    case "$1" in
      --prompt)   prompt="${2:-}"; shift 2 ;;
      --log)      log="${2:-}"; shift 2 ;;
      --model)    model="${2:-}"; shift 2 ;;
      --worktree) wt="${2:-}"; shift 2 ;;
      --cwd)      cwd="${2:-}"; shift 2 ;;
      --)         shift; break ;;
      *) die "unknown argument '$1'" ;;
    esac
  done
  [ -n "$prompt" ] || die "--prompt <file> is required"
  [ -n "$log" ] || die "--log <file> is required"
  [ -f "$prompt" ] || die "CANNOT READ prompt file $prompt"
  command -v claude >/dev/null 2>&1 || die "claude is not on PATH"
  mkdir -p "$(dirname "$log")" || die "cannot create $(dirname "$log")"
  [ -n "$cwd" ] && { cd "$cwd" || die "cannot cd $cwd"; }

  # THE BELT. 0 = wait indefinitely; see the header.
  export CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0
  echo "launch-headless-builder.sh: CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 (no 600 s background ceiling)" >&2
  nohup claude -p "$(cat "$prompt")" --model "$model" --dangerously-skip-permissions "$@" > "$log" 2>&1 &
  local pid=$!
  echo "PID=$pid"
  echo "LOG=$log"
  [ -n "$wt" ] && echo "WORKTREE=$wt"
  echo "CHECK=bash $SELF --check $log${wt:+ --worktree $wt}"
  return 0
}

cmd_check() {
  local log="${1:-}" wt="" verdict=0 dirty="" unpushed=""
  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --worktree) wt="${2:-}"; shift 2 ;;
      *) die "unknown argument '$1'" ;;
    esac
  done
  [ -n "$log" ] || die "usage: --check <log> [--worktree <dir>]"
  if [ ! -f "$log" ] || [ ! -r "$log" ]; then
    echo "CANNOT READ $log — no verdict. This is a REFUSAL, not a clean finish." >&2
    return 2
  fi

  if grep -q "$CEILING_PATTERN" "$log"; then
    echo "CEILING-KILL: the log carries the terminating-background-tasks line:"
    grep -n "$CEILING_PATTERN" "$log" | sed 's/^/  /'
    echo "  FIX: relaunch with CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 (see --print-recipe)."
    verdict=1
  else
    echo "no '$CEILING_PATTERN' line in $log"
  fi

  if [ -n "$wt" ]; then
    if [ ! -d "$wt" ]; then
      echo "CANNOT READ worktree $wt — the dirt half of the signature is UNMEASURED." >&2
      [ "$verdict" -eq 0 ] && return 2
    else
      dirty=$(git -C "$wt" status --porcelain 2>/dev/null)
      if [ -n "$dirty" ]; then
        echo "DIRTY WORKTREE: $(printf '%s\n' "$dirty" | wc -l | tr -d ' ') uncommitted path(s) in $wt"
        printf '%s\n' "$dirty" | sed 's/^/  /'
        echo "  A killed builder leaves exactly this: real work, no commit, no branch."
        verdict=1
      else
        echo "worktree $wt is clean"
      fi
      unpushed=$(git -C "$wt" log --branches --not --remotes --oneline 2>/dev/null)
      if [ -n "$unpushed" ]; then
        echo "UNPUSHED COMMITS in $wt:"
        printf '%s\n' "$unpushed" | sed 's/^/  /'
        echo "  The branch ref outlives the directory only once it is PUSHED."
        verdict=1
      fi
    fi
  fi

  if [ "$verdict" -eq 0 ]; then
    echo "CLEAN FINISH: no ceiling line, nothing uncommitted, nothing unpushed."
  else
    echo "VERDICT: this run did NOT finish cleanly — treat its report as partial."
  fi
  return $verdict
}

selftest() {
  local d pass=0 fail=0 out rc
  d=$(mktemp -d) || die "mktemp failed"
  # shellcheck disable=SC2064
  trap "rm -rf '$d'" EXIT
  ok()  { pass=$((pass + 1)); echo "  PASS $*"; }
  bad() { fail=$((fail + 1)); echo "  FAIL $*"; }

  echo "== arm 1: the recipe this script PRINTS carries the env var (the doc and the code cannot drift)"
  print_recipe | grep -q "$CEILING_HINT=0" && ok "--print-recipe names $CEILING_HINT=0" || bad "recipe missing the env var"

  echo "== arm 2: a log carrying the terminating line is a CEILING-KILL (exit 1)"
  printf 'doing work\n%s 600s; terminating.\nSet %s=0 to wait indefinitely.\n' "$CEILING_PATTERN" "$CEILING_HINT" > "$d/kill.log"
  out=$(bash "$SELF" --check "$d/kill.log" 2>&1); rc=$?
  [ "$rc" -eq 1 ] && ok "exit 1" || bad "exit $rc, expected 1"
  printf '%s' "$out" | grep -q '^CEILING-KILL:' && ok "names the verdict" || bad "no CEILING-KILL line: $out"

  echo "== arm 3 (control): a CALM log with a CLEAN worktree is a clean finish (exit 0)"
  printf 'all done, 3 tests 0 failures\n' > "$d/ok.log"
  mkdir -p "$d/wt" && git -C "$d/wt" init -q && git -C "$d/wt" config user.email t@t && git -C "$d/wt" config user.name t
  echo x > "$d/wt/a"; git -C "$d/wt" add a; git -C "$d/wt" commit -qm init
  # A pushed branch is the point of the control: without a remote EVERY commit
  # reads as unpushed and arm 3 would red for the wrong reason.
  git init -q --bare "$d/remote.git"
  git -C "$d/wt" remote add origin "$d/remote.git"
  git -C "$d/wt" push -q -u origin HEAD:refs/heads/main
  out=$(bash "$SELF" --check "$d/ok.log" --worktree "$d/wt" 2>&1); rc=$?
  [ "$rc" -eq 0 ] && ok "exit 0" || bad "exit $rc, expected 0 — output: $out"
  printf '%s' "$out" | grep -q '^CLEAN FINISH:' && ok "says CLEAN FINISH" || bad "no CLEAN FINISH line"

  echo "== arm 4: the SILENT shape — a calm log but a DIRTY worktree still reds (this is the 2026-09-05 case)"
  echo y > "$d/wt/b"
  out=$(bash "$SELF" --check "$d/ok.log" --worktree "$d/wt" 2>&1); rc=$?
  [ "$rc" -eq 1 ] && ok "exit 1 on dirt alone, with no ceiling line in the log" || bad "exit $rc, expected 1"
  printf '%s' "$out" | grep -q '^DIRTY WORKTREE:' && ok "names the dirt" || bad "no DIRTY WORKTREE line"

  echo "== arm 5: an UNPUSHED commit reds too — committed is not durable until pushed"
  git -C "$d/wt" checkout -q -- . 2>/dev/null || true
  git -C "$d/wt" add b >/dev/null; git -C "$d/wt" commit -qm second
  out=$(bash "$SELF" --check "$d/ok.log" --worktree "$d/wt" 2>&1); rc=$?
  [ "$rc" -eq 1 ] && ok "exit 1 on unpushed commits" || bad "exit $rc, expected 1"
  printf '%s' "$out" | grep -q '^UNPUSHED COMMITS' && ok "names the unpushed commits" || bad "no UNPUSHED line"

  echo "== arm 6: a MISSING log is exit 2 — a failed read is never byte-identical to a clean finish"
  out=$(bash "$SELF" --check "$d/nope.log" 2>&1); rc=$?
  [ "$rc" -eq 2 ] && ok "exit 2" || bad "exit $rc, expected 2"
  printf '%s' "$out" | grep -q 'CANNOT READ' && ok "prints CANNOT READ" || bad "no CANNOT READ line"

  echo "== arm 7: a missing WORKTREE is exit 2, not a green — the dirt half went unmeasured"
  out=$(bash "$SELF" --check "$d/ok.log" --worktree "$d/gone" 2>&1); rc=$?
  [ "$rc" -eq 2 ] && ok "exit 2" || bad "exit $rc, expected 2"

  echo "== arm 8: launching without a prompt file REFUSES rather than launching blind"
  out=$(bash "$SELF" --prompt "$d/absent.md" --log "$d/x.log" 2>&1); rc=$?
  [ "$rc" -eq 2 ] && ok "exit 2 on an unreadable prompt" || bad "exit $rc, expected 2"

  echo
  echo "launch-headless-builder.sh selftest: $pass passed, $fail failed"
  [ "$fail" -eq 0 ] || return 1
  return 0
}

case "${1:---selftest}" in
  --selftest|selftest) selftest ;;
  --check)  shift; cmd_check "$@" ;;
  --print-recipe) print_recipe ;;
  -h|--help) sed -n '1,70p' "$SELF" ;;
  *) cmd_launch "$@" ;;
esac
