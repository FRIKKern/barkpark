#!/usr/bin/env bash
#
# already-fixed.sh — "is this already on origin/main?", answered BY CONTENT.
#
# WHY CONTENT, AND NEVER A PR's merged FLAG
#
#   This repo SQUASH-merges, and stacked PRs merge into their PARENT branch,
#   not into main. `gh pr view --json merged` therefore reports merged:true for
#   changes that are ABSENT from origin/main. That is the most expensive lie a
#   25-agent fleet can believe: it makes one agent skip work that never
#   shipped, and another redo work that did.
#
#   Every verdict below is read out of the origin/main TREE (git show,
#   git grep) or out of main's HISTORY (git log -S, git log --grep). No merged
#   flag is consulted anywhere, in any mode. In --task mode gh is used ONLY to
#   ENUMERATE the PRs that mention a task id; the reachability column beside
#   each of them is still computed from main's history.
#
# USAGE
#
#   already-fixed.sh [--no-fetch] <path> <grep-pattern>
#       Does origin/main:<path> contain <grep-pattern> (ERE)?
#
#   already-fixed.sh [--no-fetch] --symbol <name>
#       Does the origin/main tree mention <name> (ERE) in any code file?
#
#   already-fixed.sh [--no-fetch] --task <task-id>
#       Which PRs — merged AND open — mention <task-id>, on what head branch,
#       and are their changes reachable from origin/main BY CONTENT?
#
#   --no-fetch   skip `git fetch origin main` and read the origin/main you
#                already have. Faster; may be stale. The verdict says which.
#
# EXIT CODES
#   0  PRESENT on origin/main   — the WHERE is printed: file:line, plus the
#                                 commit that introduced it (git log -S)
#   1  ABSENT from origin/main
#   2  usage error, or origin/main itself could not be read (never guessed)
#
# The verdict is ALWAYS the first line of stdout, so a caller can read it with
# `head -1` and a human can read it without scrolling.

set -euo pipefail

PROG="$(basename -- "$0")"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# Code extensions searched by --symbol. Deliberately code-only: a symbol name
# that survives only in docs or in a lockfile is not "already fixed".
CODE_PATHSPECS=(
  '*.ex' '*.exs' '*.heex' '*.eex'
  '*.go'
  '*.ts' '*.tsx' '*.js' '*.jsx' '*.mjs' '*.cjs'
  '*.py' '*.rb' '*.rs' '*.sh' '*.bash'
  '*.sql' '*.yml' '*.yaml'
)

# Spelled out here rather than sed-ed out of the header: a line-anchored
# `sed -n '3,41p' $0` silently prints the wrong block the day a comment grows.
usage() {
  cat <<'EOF'
usage: already-fixed.sh [--no-fetch] <path> <grep-pattern>
       already-fixed.sh [--no-fetch] --symbol <name>
       already-fixed.sh [--no-fetch] --task <task-id>

  Is this already on origin/main? Answered BY CONTENT (git show / git grep /
  git log -S), never by a PR's merged flag — this repo squash-merges and
  stacked PRs report merged:true while absent from main.

  --no-fetch   read the origin/main you already have; the verdict says so.

exit: 0 PRESENT on origin/main   1 ABSENT from origin/main
      2 usage error, or origin/main unreadable (never guessed)
EOF
}

die_usage() {
  printf '%s: %s\n\n' "$PROG" "$1" >&2
  usage >&2
  exit 2
}

# say_verdict <PRESENT|ABSENT> — always the first line printed.
say_verdict() {
  case "$1" in
    PRESENT) printf 'PRESENT on origin/main\n' ;;
    ABSENT)  printf 'ABSENT from origin/main\n' ;;
    *)       printf 'ABSENT from origin/main\n' ;;
  esac
}

# ── argument parsing ─────────────────────────────────────────────────────────

MODE=""
NEEDLE=""
TARGET_PATH=""
DO_FETCH=1

while [ $# -gt 0 ]; do
  case "$1" in
    --no-fetch) DO_FETCH=0; shift ;;
    --symbol)
      [ -n "$MODE" ] && die_usage "pick one mode: --symbol, --task, or <path> <pattern>"
      [ $# -ge 2 ] || die_usage "--symbol needs a name"
      MODE=symbol; NEEDLE="$2"; shift 2 ;;
    --task)
      [ -n "$MODE" ] && die_usage "pick one mode: --symbol, --task, or <path> <pattern>"
      [ $# -ge 2 ] || die_usage "--task needs a task id"
      MODE=task; NEEDLE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --*) die_usage "unknown flag: $1" ;;
    *)
      [ -n "$MODE" ] && die_usage "unexpected argument: $1"
      [ $# -ge 2 ] || die_usage "path mode needs BOTH <path> and <grep-pattern>"
      MODE=path; TARGET_PATH="$1"; NEEDLE="$2"; shift 2 ;;
  esac
done

[ -n "$MODE" ] || die_usage "no mode given"
[ -n "$NEEDLE" ] || die_usage "empty search term"

cd -- "$ROOT"

# ── origin/main must be readable, or we refuse to answer ─────────────────────

STALE_NOTE=""
if [ "$DO_FETCH" = 1 ]; then
  if ! git fetch origin main --quiet 2>/dev/null; then
    STALE_NOTE="  (WARNING: git fetch origin main FAILED — reading a possibly stale origin/main)"
  fi
else
  STALE_NOTE="  (--no-fetch: origin/main may be stale)"
fi

if ! git rev-parse --verify --quiet origin/main >/dev/null 2>&1; then
  printf 'HOLD: origin/main is not readable in %s — refusing to guess.\n' "$ROOT" >&2
  printf '      Run: git fetch origin main   then retry.\n' >&2
  exit 2
fi
MAIN_SHA="$(git rev-parse --short origin/main)"

# introducer <regex> [path...] — the commit on main that first added the match.
# Pickaxe, regex-mode: this is the "who shipped it" column, and it is history,
# never a merged flag.
introducer() {
  local rx="$1"; shift
  git log origin/main --oneline --max-count=1 --pickaxe-regex "-S$rx" -- "$@" 2>/dev/null || true
}

# ── mode: path ───────────────────────────────────────────────────────────────

run_path_mode() {
  local blob hits intro
  if ! blob="$(git show "origin/main:$TARGET_PATH" 2>/dev/null)"; then
    say_verdict ABSENT
    printf '  origin/main@%s%s\n' "$MAIN_SHA" "$STALE_NOTE"
    printf '  the path itself does not exist on origin/main: %s\n' "$TARGET_PATH"
    return 1
  fi

  hits="$(grep -nE -- "$NEEDLE" <<<"$blob" || true)"
  if [ -z "$hits" ]; then
    say_verdict ABSENT
    printf '  origin/main@%s%s\n' "$MAIN_SHA" "$STALE_NOTE"
    printf '  %s exists on origin/main but does not match: %s\n' "$TARGET_PATH" "$NEEDLE"
    return 1
  fi

  say_verdict PRESENT
  printf '  origin/main@%s%s\n' "$MAIN_SHA" "$STALE_NOTE"
  printf '  pattern: %s\n' "$NEEDLE"
  printf '%s\n' "$hits" | sed "s|^|  $TARGET_PATH:|"
  intro="$(introducer "$NEEDLE" "$TARGET_PATH")"
  if [ -n "$intro" ]; then
    printf '  introduced by: %s\n' "$intro"
  else
    printf '  introduced by: (no pickaxe hit — the line may predate the pattern)\n'
  fi
  return 0
}

# ── mode: symbol ─────────────────────────────────────────────────────────────

run_symbol_mode() {
  local hits intro
  hits="$(git grep -nE -e "$NEEDLE" origin/main -- "${CODE_PATHSPECS[@]}" 2>/dev/null || true)"
  if [ -z "$hits" ]; then
    say_verdict ABSENT
    printf '  origin/main@%s%s\n' "$MAIN_SHA" "$STALE_NOTE"
    printf '  no code file on origin/main matches: %s\n' "$NEEDLE"
    printf '  (searched: %s)\n' "${CODE_PATHSPECS[*]}"
    return 1
  fi

  say_verdict PRESENT
  printf '  origin/main@%s%s\n' "$MAIN_SHA" "$STALE_NOTE"
  printf '  symbol: %s\n' "$NEEDLE"
  printf '%s\n' "$hits" | sed 's|^origin/main:|  |'
  intro="$(introducer "$NEEDLE")"
  if [ -n "$intro" ]; then
    printf '  introduced by: %s\n' "$intro"
  else
    printf '  introduced by: (no pickaxe hit)\n'
  fi
  return 0
}

# ── mode: task ───────────────────────────────────────────────────────────────

# reachable_by_content <needle> — commits on main whose DIFF or MESSAGE carries
# the needle. This, and not merged:true, is what "landed on main" means here.
reachable_by_content() {
  local needle="$1" by_diff by_msg
  by_diff="$(git log origin/main --oneline --max-count=5 --pickaxe-regex "-S$needle" 2>/dev/null || true)"
  by_msg="$(git log origin/main --oneline --max-count=5 --grep="$needle" 2>/dev/null || true)"
  printf '%s\n%s\n' "$by_diff" "$by_msg" | grep -v '^$' | sort -u || true
}

repo_slug() {
  local url
  url="$(git remote get-url origin 2>/dev/null || true)"
  [ -n "$url" ] || return 0
  url="${url%.git}"
  case "$url" in
    *github.com[:/]*) printf '%s\n' "${url##*github.com}" | sed 's|^[:/]||' ;;
    *) : ;;
  esac
}

run_task_mode() {
  local landed pr_json search_json hold=0 slug
  local list_numbers search_numbers all_numbers n line mark
  landed="$(reachable_by_content "$NEEDLE")"

  # gh is an ENUMERATOR here, never an adjudicator. If it cannot be read we say
  # so loudly rather than print a short list that reads as "no PRs".
  pr_json=""
  if ! pr_json="$(gh pr list --state all --search "$NEEDLE" --limit 50 \
        --json number,title,headRefName,state,url 2>/dev/null)"; then
    hold=1; pr_json=""
  fi

  search_json=""
  slug="$(repo_slug)"
  if [ -n "$slug" ]; then
    if ! search_json="$(gh search prs "$NEEDLE" --repo "$slug" --limit 50 \
          --json number 2>/dev/null)"; then
      hold=1; search_json=""
    fi
  fi

  if [ -n "$landed" ]; then
    say_verdict PRESENT
    mark='[task text IS on main]'
  else
    say_verdict ABSENT
    mark='[task text NOT on main]'
  fi
  printf '  origin/main@%s%s\n' "$MAIN_SHA" "$STALE_NOTE"
  printf '  task: %s\n' "$NEEDLE"

  if [ -n "$landed" ]; then
    printf '  commits on origin/main carrying it (diff -S or message --grep):\n'
    printf '%s\n' "$landed" | sed 's|^|    |'
  else
    printf '  no commit on origin/main carries it in a diff or a message.\n'
  fi

  if [ "$hold" = 1 ]; then
    printf '\n  HOLD: a gh call FAILED. The PR list below is INCOMPLETE — do not\n'
    printf '        read a short list as "no PRs mention this task".\n'
  fi

  # Merge the two number sets. `gh search prs` cannot return headRefName, so a
  # number seen only there is resolved with a single `gh pr view`.
  list_numbers=""
  [ -n "$pr_json" ] && list_numbers="$(grep -oE '"number":[0-9]+' <<<"$pr_json" | cut -d: -f2 || true)"
  search_numbers=""
  [ -n "$search_json" ] && search_numbers="$(grep -oE '"number":[0-9]+' <<<"$search_json" | cut -d: -f2 || true)"
  all_numbers="$(printf '%s\n%s\n' "$list_numbers" "$search_numbers" | grep -E '^[0-9]+$' | sort -un || true)"

  printf '\n  PRs mentioning %s (number / state / head branch / title):\n' "$NEEDLE"
  if [ -z "$all_numbers" ]; then
    if [ "$hold" = 1 ]; then
      printf '    (none readable — see the HOLD above)\n'
    else
      printf '    (none)\n'
    fi
  else
    while IFS= read -r n; do
      [ -n "$n" ] || continue
      line="$(gh pr view "$n" --json number,title,headRefName,state,url \
              --template '#{{.number}} {{.state}} {{.headRefName}} {{.title}}' 2>/dev/null || true)"
      [ -n "$line" ] || line="#$n (gh pr view failed)"
      printf '    %s  %s\n' "$line" "$mark"
    done <<<"$all_numbers"
  fi

  printf '\n  Reminder: merged:true is NOT evidence. A stacked PR merges into its\n'
  printf '  parent branch and still reports merged:true while absent from main.\n'

  [ -n "$landed" ] && return 0
  return 1
}

case "$MODE" in
  path)   run_path_mode ;;
  symbol) run_symbol_mode ;;
  task)   run_task_mode ;;
  *)      die_usage "unreachable mode: $MODE" ;;
esac
