#!/usr/bin/env bash
#
# main-red-hold.sh — a red that REPRODUCES ON CLEAN MAIN gets an OWNER and a
# per-TREE merge hold, in one motion.
#
# WHY THIS EXISTS (task-fdd556e0b6ba071b, ruled 2026-09-13). Three defects
# reached main behind a green merge button in ONE round: a doc-budget breach
# that merged 82 bytes over cap behind a NEUTRAL breaker verdict, a published
# package changed with no changeset against a rule enforced since June, and a
# live `go test` failure in internal/taskboard the fleet merged through all
# afternoon. One mechanism, three instances.
#
# THE BOUNDARY IS NOT THE PROBLEM AND THIS SCRIPT DOES NOT TOUCH IT. Widening
# the four required contexts is the WRONG fix, for two structural reasons both
# measured in this repo:
#   * a paths-filtered workflow emits NO check run on a non-matching PR, so its
#     name can never be made required without deadlocking the branch — that is
#     why the S4 exclusions in .github/required-checks.json exist;
#   * a required job carrying `if: needs.changes.outputs.*` is SKIPPED on most
#     PRs, and A SKIPPED JOB COUNTS AS PASSING for a required context. Adding
#     conditional jobs to the required set buys a green that asserts nothing
#     and makes 4/4 WEAKER, not stronger.
# The required four are a MERGE gate. They were never a health claim about
# main. The actual gap is that a red which reproduces on main has NO OWNER and
# NO HOLD — all three escapes were UNOWNED rather than unnoticed.
#
# THE FIVE PROPERTIES, each one a criterion of the row above.
#
#  1. REPRODUCTION IS THE TRIGGER AND IT IS MECHANICAL. `open` refuses to
#     record anything it did not run itself. It creates a DETACHED, CLEAN
#     checkout of main carrying no PR changes, runs the reproduction command
#     there, and reads the exit code DIRECTLY (`rc=$?` on an unpiped command —
#     a gate piped to `tail` reports tail's exit code, and this fleet has
#     misread `rc=0` off exactly that shape). A red read from a CI log or a
#     rollup CANNOT open a hold: there is no flag that takes one. That step is
#     what separates a real red from an INHERITED or a FLAKY one, and it cost
#     four minutes by hand for the two packages measured on 2026-09-13.
#
#  2. SCOPE IS PER-TREE AND DERIVED, NOT DECLARED. There is no `--tree` flag.
#     The affected trees are derived from the reproduction's own OUTPUT (the
#     failing package, then failing tracked files), falling back to path
#     arguments in the command itself. A hand-maintained list is a snapshot; a
#     derivation is a rule, and this repo has already been bitten by a skip
#     list that was 2 items and was really 8.
#     PER-TREE AND NOT FLEET-WIDE, for a measured reason: a fleet-wide hold is
#     too expensive to keep honestly and gets lifted under pressure — one was
#     issued and retracted on the morning of 2026-09-13 — and a hold that gets
#     lifted has taught everyone that holds are negotiable.
#
#  3. AN OWNER IS ASSIGNED IN THE SAME MOTION. `--owner` is mandatory; its
#     absence is a CANNOT READ, not a default. The owner is written into
#     .github/main-red-holds.json — a COMMITTED file a lane reads, not a
#     message in a channel that scrolls.
#
#  4. IT LIFTS ON A MEASUREMENT, NOT ON A CLAIM. `lift` re-runs the hold's OWN
#     recorded reproduction command on a clean checkout of a LATER main sha and
#     clears only on exit 0, quoting that sha and that exit code. There is no
#     --force and no --skip-repro; `lift` has no path that skips the
#     re-measurement (proved by arm 7 of --selftest).
#
#  5. IT REFUSES LOUDLY RATHER THAN FAILING OPEN. Every unreadable input prints
#     a line beginning `main-red-hold: CANNOT READ —` and exits 3. That line is
#     never byte-identical to the clear/no-hold line (asserted, arm 10a). Three
#     of the refusals are MUTATION-PROVED in both directions by --selftest arms
#     13a/13b/13c: the guard is deleted from a scratch copy, the mutant is shown
#     to behave DIFFERENTLY on the same input (it falls open, or it opens a
#     hold out of a typo), and the original is shown to still refuse.
#
# USAGE
#
#   main-red-hold.sh open  --owner <who> --repro '<command>' [--task <id>]
#                          [--id <slug>] [--main-ref <ref>] [--no-fetch]
#                          [--registry <path>] [--note <text>]
#   main-red-hold.sh check [--changed-since <ref>] [--paths-from <file|->]
#                          [--registry <path>] [<path> ...]
#   main-red-hold.sh lift  --id <slug> [--main-ref <ref>] [--no-fetch]
#                          [--registry <path>]
#   main-red-hold.sh list  [--registry <path>]
#   main-red-hold.sh --selftest
#
# EXIT CODES — chosen so the BAD news is always non-zero
#   open   0 NO HOLD (did not reproduce) · 1 HOLD OPENED · 2 usage · 3 CANNOT READ
#   check  0 CLEAR                       · 1 HELD        · 2 usage · 3 CANNOT READ
#   lift   0 LIFTED                      · 1 HOLD STANDS · 2 usage · 3 CANNOT READ
#
# bash 3.2 compatible (macOS system bash): no associative arrays, no mapfile,
# no process substitution (scripts/posix-vacuous-green-census.sh reds a new
# scripts/*.sh that uses `<(` without the shebang-independent interpreter
# guard; this file simply does not use it).

set -uo pipefail

PROG="$(basename -- "$0")"
SELF="${BASH_SOURCE[0]}"
ROOT="${MAIN_RED_HOLD_ROOT:-$(cd -- "$(dirname -- "$SELF")/.." && pwd)}"
REGISTRY_DEFAULT=".github/main-red-holds.json"

cannot_read() {
  printf '%s: CANNOT READ — %s\n' "$PROG" "$1" >&2
}

die_usage() {
  printf '%s: %s\n' "$PROG" "$1" >&2
  printf 'run `%s --help` for usage\n' "$PROG" >&2
  exit 2
}

usage() {
  sed -n '/^# USAGE/,/^# bash 3.2/p' "$SELF" | sed 's/^# \{0,1\}//'
}

# ---------------------------------------------------------------------------
# registry helpers
# ---------------------------------------------------------------------------

reg_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *)  printf '%s/%s\n' "$ROOT" "$1" ;;
  esac
}

reg_read() {
  # $1 = registry path. Prints the JSON on stdout, or refuses.
  local reg="$1"
  if [ ! -f "$reg" ]; then
    printf '{"version":1,"holds":[]}\n'
    return 0
  fi
# <<MUT:registry-parse-refusal
  if ! jq -e 'type == "object" and (.holds | type) == "array"' "$reg" >/dev/null 2>&1; then
    cannot_read "registry $reg is not readable JSON with a .holds array — refusing to report CLEAR off a file I could not parse"
    return 3
  fi
# MUT:registry-parse-refusal>>
  cat "$reg"
}

require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    cannot_read "jq is not on PATH; the hold registry is JSON and cannot be read without it"
    return 3
  fi
  return 0
}

# ---------------------------------------------------------------------------
# clean checkout of main
# ---------------------------------------------------------------------------

CLEAN_DIR=""
cleanup_clean() {
  if [ -n "$CLEAN_DIR" ] && [ -d "$CLEAN_DIR" ]; then
    git -C "$ROOT" worktree remove --force "$CLEAN_DIR" >/dev/null 2>&1 || rm -rf "$CLEAN_DIR"
    CLEAN_DIR=""
  fi
}
trap cleanup_clean EXIT INT TERM

resolve_main_sha() {
  # $1 = ref, $2 = do_fetch (1/0). Prints sha, or refuses (3).
  local ref="$1" do_fetch="$2" sha=""
  if [ "$do_fetch" = "1" ]; then
    case "$ref" in
      origin/*) git -C "$ROOT" fetch -q origin "${ref#origin/}" >/dev/null 2>&1 || true ;;
      *)        git -C "$ROOT" fetch -q origin >/dev/null 2>&1 || true ;;
    esac
  fi
  sha="$(git -C "$ROOT" rev-parse --verify --quiet "${ref}^{commit}" 2>/dev/null)"
# <<MUT:mainref-refusal
  if [ -z "$sha" ]; then
    cannot_read "cannot reach main: '$ref' does not resolve to a commit in $ROOT (fetch failed, or the ref does not exist)"
    return 3
  fi
# MUT:mainref-refusal>>
  printf '%s\n' "$sha"
  return 0
}

make_clean_checkout() {
  # $1 = sha. Sets the GLOBAL CLEAN_DIR. Refuses (3) if the checkout is not
  # clean or not the requested sha — a checkout carrying anything is not
  # evidence about main.
  #
  # IT PRINTS NOTHING, AND MUST NEVER BE CALLED IN `$(...)`. Measured
  # 2026-09-13 during this script's own build: called through a command
  # substitution it set CLEAN_DIR inside a SUBSHELL, the EXIT trap in the
  # parent saw an empty variable, and every run leaked a detached git worktree
  # (three of them, before a `git worktree list` caught it). Callers read the
  # global after `make_clean_checkout "$sha" || return 3`.
  local sha="$1" dir head dirty
  dir="$(mktemp -d "${TMPDIR:-/tmp}/main-red-hold.XXXXXX")" || {
    cannot_read "cannot create a temporary directory for the clean checkout"; return 3; }
  rmdir "$dir" 2>/dev/null
  if ! git -C "$ROOT" worktree add --detach "$dir" "$sha" >/dev/null 2>&1; then
    cannot_read "cannot create a clean detached checkout of $sha (git worktree add failed)"
    rm -rf "$dir"
    return 3
  fi
  CLEAN_DIR="$dir"
  head="$(git -C "$dir" rev-parse HEAD 2>/dev/null)"
  if [ "$head" != "$sha" ]; then
    cannot_read "the checkout at $dir is at $head, not the requested $sha"
    return 3
  fi
  dirty="$(git -C "$dir" status --porcelain 2>/dev/null)"
  if [ -n "$dirty" ]; then
    cannot_read "the checkout at $dir is NOT clean — it carries changes, so nothing run in it is evidence about main"
    return 3
  fi
  return 0
}

run_repro() {
  # $1 = clean dir, $2 = command, $3 = log file. Prints nothing; returns the
  # reproduction's OWN exit code. Read DIRECTLY: no pipe anywhere on this path.
  local dir="$1" cmd="$2" log="$3" rc=0
  ( cd "$dir" && eval "$cmd" ) >"$log" 2>&1
  rc=$?
  return $rc
}

# ---------------------------------------------------------------------------
# tree derivation — DERIVED from the failure, never declared
# ---------------------------------------------------------------------------
#
# Three tiers, strongest first; the FIRST tier that yields a tree wins, and the
# weaker tiers are not consulted. That order matters: tier D2 reads file:line
# tokens out of the output, and a golden-file diff PRINTS FIXTURE CONTENT that
# can contain paths belonging to other trees. When the runner has already named
# the failing package (D1), that naming is authoritative and D2's contamination
# never gets a vote.

derive_trees() {
  # $1 = log, $2 = clean dir, $3 = repro command. Prints one tree per line.
  local log="$1" dir="$2" cmd="$3" mod="" out="" tier=""

  # D1 — the test runner named the failing PACKAGE.
  #      Go: `FAIL\t<module>/<pkg>\t<time>`  →  <pkg> relative to the module.
  if [ -f "$dir/go.mod" ]; then
    mod="$(awk '$1=="module"{print $2; exit}' "$dir/go.mod" 2>/dev/null)"
  fi
  if [ -n "$mod" ]; then
    out="$(awk -v m="$mod/" '$1=="FAIL" && index($2,m)==1 {print substr($2, length(m)+1)}' "$log" 2>/dev/null | sort -u)"
    if [ -n "$out" ]; then tier="D1-package"; fi
  fi

  # D2 — tracked FILES named in the output, reduced to their directories.
  if [ -z "$out" ]; then
    local cand keep=""
    for cand in $(grep -oE '[A-Za-z0-9_][A-Za-z0-9_./-]*\.[A-Za-z0-9_]+:[0-9]+' "$log" 2>/dev/null \
                  | sed 's/:[0-9]*$//' | sort -u); do
      case "$cand" in */*) : ;; *) continue ;; esac
      if git -C "$dir" ls-files --error-unmatch -- "$cand" >/dev/null 2>&1; then
        keep="$keep
$(dirname -- "$cand")"
      fi
    done
    out="$(printf '%s\n' "$keep" | sed '/^$/d' | sort -u)"
    if [ -n "$out" ]; then tier="D2-tracked-file"; fi
  fi

  # D3 — path arguments in the reproduction COMMAND that are real directories.
  if [ -z "$out" ]; then
    local tok keep3=""
    for tok in $cmd; do
      tok="${tok#./}"
      tok="${tok%/...}"
      tok="${tok%/}"
      case "$tok" in
        ''|-*|*=*) continue ;;
        */*) : ;;
        *) continue ;;
      esac
      if [ -d "$dir/$tok" ]; then
        keep3="$keep3
$tok"
      fi
    done
    out="$(printf '%s\n' "$keep3" | sed '/^$/d' | sort -u)"
    if [ -n "$out" ]; then tier="D3-command-path"; fi
  fi

  [ -n "$out" ] || return 1

  # Normalise: drop any tree that is a descendant of another in the set, so a
  # hold never claims the same files twice under two names.
  local a b drop
  printf '%s\n' "$out" | while IFS= read -r a; do
    [ -n "$a" ] || continue
    drop=0
    printf '%s\n' "$out" | while IFS= read -r b; do
      [ -n "$b" ] || continue
      [ "$a" = "$b" ] && continue
      case "$a" in "$b"/*) exit 7 ;; esac
    done || drop=1
    [ "$drop" = "0" ] && printf '%s\n' "$a"
  done
  printf '%s\n' "$tier" >"${MAIN_RED_HOLD_TIER_FILE:-/dev/null}"
  return 0
}

# ---------------------------------------------------------------------------
# open
# ---------------------------------------------------------------------------

cmd_open() {
  local owner="" repro="" task="" slug="" mainref="origin/main" do_fetch=1 reg="$REGISTRY_DEFAULT" note=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --owner)    [ $# -ge 2 ] || die_usage "--owner needs a value"; owner="$2"; shift 2 ;;
      --repro)    [ $# -ge 2 ] || die_usage "--repro needs a command"; repro="$2"; shift 2 ;;
      --task)     [ $# -ge 2 ] || die_usage "--task needs a value"; task="$2"; shift 2 ;;
      --id)       [ $# -ge 2 ] || die_usage "--id needs a value"; slug="$2"; shift 2 ;;
      --main-ref) [ $# -ge 2 ] || die_usage "--main-ref needs a ref"; mainref="$2"; shift 2 ;;
      --registry) [ $# -ge 2 ] || die_usage "--registry needs a path"; reg="$2"; shift 2 ;;
      --note)     [ $# -ge 2 ] || die_usage "--note needs a value"; note="$2"; shift 2 ;;
      --no-fetch) do_fetch=0; shift ;;
      *) die_usage "unknown argument to open: $1" ;;
    esac
  done

  require_jq || return 3

  # THE OWNER IS NOT OPTIONAL AND HAS NO DEFAULT. A hold with no owner is a
  # stalled tree; all three escapes that motivated this script were UNOWNED.
  if [ -z "$owner" ]; then
    cannot_read "--owner is mandatory: a hold with no owner is a stalled tree, and this script will not invent one"
    return 3
  fi
  if [ -z "$repro" ]; then
    cannot_read "--repro is mandatory: a hold is opened by RUNNING the failure on clean main, never by quoting a CI log"
    return 3
  fi

  local reg_abs sha dir log rc trees tierfile tier
  reg_abs="$(reg_path "$reg")"

  sha="$(resolve_main_sha "$mainref" "$do_fetch")" || return 3
  make_clean_checkout "$sha" || return 3
  dir="$CLEAN_DIR"

  log="$(mktemp "${TMPDIR:-/tmp}/main-red-hold-log.XXXXXX")" || {
    cannot_read "cannot create a log file for the reproduction"; return 3; }

  printf '%s: reproducing on a CLEAN detached checkout of %s (%s) at %s\n' "$PROG" "$mainref" "$sha" "$dir"
  printf '%s:   $ %s\n' "$PROG" "$repro"
  run_repro "$dir" "$repro" "$log"
  rc=$?
  printf '%s:   exit code (read directly, unpiped): %s\n' "$PROG" "$rc"

# <<MUT:repro-unrunnable
  if [ "$rc" -eq 127 ] || [ "$rc" -eq 126 ]; then
    cannot_read "the reproduction command could not be EXECUTED (exit $rc: command not found / not executable). A typo is not a red, and this refuses rather than manufacturing a hold out of one."
    sed -n '1,20p' "$log" >&2
    rm -f "$log"
    return 3
  fi
# MUT:repro-unrunnable>>

  if [ "$rc" -eq 0 ]; then
    printf 'NO HOLD: the failure did NOT reproduce on clean main %s (exit 0). Nothing recorded.\n' "$sha"
    rm -f "$log"
    return 0
  fi

  tierfile="$(mktemp "${TMPDIR:-/tmp}/main-red-hold-tier.XXXXXX")"
  trees="$(MAIN_RED_HOLD_TIER_FILE="$tierfile" derive_trees "$log" "$dir" "$repro")"
  tier="$(cat "$tierfile" 2>/dev/null)"
  rm -f "$tierfile"

  # A derivation that yields the repo ROOT is not a per-tree scope, it is a
  # fleet-wide hold wearing one — refuse it by name.
  case "
$trees" in
    *"
."*|*"
/"*) cannot_read "the derivation produced the repository ROOT as the affected tree; that is a fleet-wide hold wearing a per-tree name, and this refuses to open it"
         rm -f "$log"; return 3 ;;
  esac

# <<MUT:tree-refusal
  if [ -z "$trees" ]; then
    cannot_read "the failure reproduced (exit $rc) but NO affected tree could be derived from its output or from the command; refusing to open a hold whose scope I cannot state. Reproduction log head:"
    sed -n '1,20p' "$log" >&2
    rm -f "$log"
    return 3
  fi
# MUT:tree-refusal>>

  [ -n "$slug" ] || slug="$(printf '%s\n' "$trees" | head -1 | tr '/.' '--')-$(date -u +%Y%m%d)"

  local now trees_json head_log
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  trees_json="$(printf '%s\n' "$trees" | sed '/^$/d' | jq -R . | jq -s .)"
  head_log="$(sed -n '1,40p' "$log")"
  rm -f "$log"

  local existing new
  existing="$(reg_read "$reg_abs")" || return 3
  new="$(printf '%s' "$existing" | jq \
      --arg id "$slug" --argjson trees "$trees_json" --arg repro "$repro" \
      --arg owner "$owner" --arg task "$task" --arg sha "$sha" \
      --arg now "$now" --arg tier "$tier" --arg note "$note" --arg rc "$rc" \
      --arg log "$head_log" '
      .version = 1
      | .holds = ((.holds // []) | map(select(.id != $id)) + [{
          id: $id, trees: $trees, repro: $repro, owner: $owner,
          task: (if $task == "" then null else $task end),
          opened_at: $now, opened_on_sha: $sha, opened_exit: ($rc|tonumber),
          derivation: $tier,
          note: (if $note == "" then null else $note end),
          reproduction_head: $log
        }])')" || {
      cannot_read "could not write the hold into $reg_abs"; return 3; }

  mkdir -p "$(dirname -- "$reg_abs")"
  printf '%s\n' "$new" >"$reg_abs" || {
    cannot_read "could not write $reg_abs"; return 3; }

  printf 'HOLD OPENED: %s\n' "$slug"
  printf '  reproduced on : CLEAN checkout of %s (%s)\n' "$mainref" "$sha"
  printf '  command       : %s\n' "$repro"
  printf '  exit code     : %s (read directly, not through a pipe)\n' "$rc"
  printf '  affected trees: %s\n' "$(printf '%s' "$trees" | tr '\n' ' ')"
  printf '  derived by    : %s (no --tree flag exists; scope is derived, never declared)\n' "$tier"
  printf '  OWNER         : %s\n' "$owner"
  [ -n "$task" ] && printf '  task          : %s\n' "$task"
  printf '  recorded in   : %s (committed — a lane reads this file, not a message)\n' "$reg"
  printf '  lifts when    : `%s lift --id %s` re-runs that command on a LATER main sha and it exits 0\n' "$PROG" "$slug"
  return 1
}

# ---------------------------------------------------------------------------
# check
# ---------------------------------------------------------------------------

cmd_check() {
  local since="" pathsfrom="" reg="$REGISTRY_DEFAULT" argpaths=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --changed-since) [ $# -ge 2 ] || die_usage "--changed-since needs a ref"; since="$2"; shift 2 ;;
      --paths-from)    [ $# -ge 2 ] || die_usage "--paths-from needs a file"; pathsfrom="$2"; shift 2 ;;
      --registry)      [ $# -ge 2 ] || die_usage "--registry needs a path"; reg="$2"; shift 2 ;;
      -*) die_usage "unknown argument to check: $1" ;;
      *) argpaths="$argpaths
$1"; shift ;;
    esac
  done

  require_jq || return 3

  local reg_abs json nholds paths=""
  reg_abs="$(reg_path "$reg")"
  json="$(reg_read "$reg_abs")" || return 3
  nholds="$(printf '%s' "$json" | jq '.holds | length')"

  if [ -n "$since" ]; then
    if ! git -C "$ROOT" rev-parse --verify --quiet "${since}^{commit}" >/dev/null 2>&1; then
      cannot_read "--changed-since '$since' does not resolve to a commit in $ROOT; an unresolvable base is not an empty diff"
      return 3
    fi
    paths="$(git -C "$ROOT" diff --name-only "${since}...HEAD" 2>/dev/null)"
    if [ $? -ne 0 ]; then
      cannot_read "git diff --name-only ${since}...HEAD failed in $ROOT"
      return 3
    fi
  fi
  if [ -n "$pathsfrom" ]; then
    if [ "$pathsfrom" = "-" ]; then
      paths="$paths
$(cat)"
    elif [ -f "$pathsfrom" ]; then
      paths="$paths
$(cat "$pathsfrom")"
    else
      cannot_read "--paths-from '$pathsfrom' is not a readable file"
      return 3
    fi
  fi
  paths="$paths$argpaths"
  paths="$(printf '%s\n' "$paths" | sed '/^$/d' | sort -u)"

  if [ -z "$paths" ] && [ -z "$since" ]; then
    cannot_read "no changed paths were given (pass paths, --paths-from, or --changed-since); an empty argument list is not a clean PR"
    return 3
  fi
  # AN EMPTY DIFF IS A MISCONFIGURED BASE, NOT A CLEAN PR. `--changed-since`
  # resolving to a commit and then yielding ZERO paths is the shape that made
  # a default-paginated read look like proof of absence elsewhere in this repo:
  # the read succeeded and measured nothing. Refuse rather than print CLEAR.
  if [ -z "$paths" ]; then
    cannot_read "the diff ${since}...HEAD in $ROOT names ZERO changed paths; an empty diff is a misconfigured base ref, not a clean PR, and CLEAR off zero paths asserts nothing"
    return 3
  fi

  local npaths
  npaths="$(printf '%s\n' "$paths" | sed '/^$/d' | wc -l | tr -d ' ')"
  printf '%s: %s open hold(s) in %s; %s changed path(s) to judge\n' "$PROG" "$nholds" "$reg" "$npaths"

  if [ "$nholds" = "0" ]; then
    printf 'CLEAR: no tree is held.\n'
    return 0
  fi

  local held=0 i n id owner task trees t p hit
  n="$nholds"
  i=0
  while [ "$i" -lt "$n" ]; do
    id="$(printf '%s' "$json" | jq -r ".holds[$i].id")"
    owner="$(printf '%s' "$json" | jq -r ".holds[$i].owner")"
    task="$(printf '%s' "$json" | jq -r ".holds[$i].task // \"\"")"
    trees="$(printf '%s' "$json" | jq -r ".holds[$i].trees[]")"
    hit=""
    for t in $trees; do
      while IFS= read -r p; do
        [ -n "$p" ] || continue
        case "$p" in
          "$t"|"$t"/*) hit="$hit
$p ($t)" ;;
        esac
      done <<INNER_EOF
$paths
INNER_EOF
    done
    if [ -n "$hit" ]; then
      held=1
      printf 'HELD: %s\n' "$id"
      printf '  held trees : %s\n' "$(printf '%s' "$trees" | tr '\n' ' ')"
      printf '  OWNER      : %s\n' "$owner"
      [ -n "$task" ] && [ "$task" != "null" ] && printf '  task       : %s\n' "$task"
      printf '  opened on  : %s (exit %s)\n' \
        "$(printf '%s' "$json" | jq -r ".holds[$i].opened_on_sha")" \
        "$(printf '%s' "$json" | jq -r ".holds[$i].opened_exit")"
      printf '  repro      : %s\n' "$(printf '%s' "$json" | jq -r ".holds[$i].repro")"
      printf '  your changed files inside it:%s\n' "$hit"
      printf '  lifts by   : %s lift --id %s  (re-runs that command on a later main sha; there is no --force)\n' "$PROG" "$id"
    else
      printf 'not held: %s (trees: %s) — this change touches none of them\n' \
        "$id" "$(printf '%s' "$trees" | tr '\n' ' ')"
    fi
    i=$((i + 1))
  done

  if [ "$held" = "1" ]; then
    return 1
  fi
  printf 'CLEAR: this change touches no held tree.\n'
  return 0
}

# ---------------------------------------------------------------------------
# lift  — on a MEASUREMENT, never on a claim
# ---------------------------------------------------------------------------

cmd_lift() {
  local slug="" mainref="origin/main" do_fetch=1 reg="$REGISTRY_DEFAULT"
  while [ $# -gt 0 ]; do
    case "$1" in
      --id)       [ $# -ge 2 ] || die_usage "--id needs a value"; slug="$2"; shift 2 ;;
      --main-ref) [ $# -ge 2 ] || die_usage "--main-ref needs a ref"; mainref="$2"; shift 2 ;;
      --registry) [ $# -ge 2 ] || die_usage "--registry needs a path"; reg="$2"; shift 2 ;;
      --no-fetch) do_fetch=0; shift ;;
      # THERE IS DELIBERATELY NO --force AND NO --skip-repro. A hold that can be
      # lifted by assertion is a hold that gets lifted under pressure, and then
      # everyone has learned that holds are negotiable. Arm 7 of --selftest
      # pins this by asserting both spellings are rejected as usage errors.
      *) die_usage "unknown argument to lift: $1 (there is no --force and no --skip-repro: a hold lifts on a re-measurement or not at all)" ;;
    esac
  done

  require_jq || return 3
  [ -n "$slug" ] || die_usage "lift needs --id <slug>"

  local reg_abs json repro opened_sha owner
  reg_abs="$(reg_path "$reg")"
  json="$(reg_read "$reg_abs")" || return 3

  if ! printf '%s' "$json" | jq -e --arg id "$slug" '.holds[] | select(.id == $id)' >/dev/null 2>&1; then
    cannot_read "no hold with id '$slug' in $reg (holds present: $(printf '%s' "$json" | jq -r '[.holds[].id] | join(", ")'))"
    return 3
  fi
  repro="$(printf '%s' "$json" | jq -r --arg id "$slug" '.holds[] | select(.id == $id) | .repro')"
  opened_sha="$(printf '%s' "$json" | jq -r --arg id "$slug" '.holds[] | select(.id == $id) | .opened_on_sha')"
  owner="$(printf '%s' "$json" | jq -r --arg id "$slug" '.holds[] | select(.id == $id) | .owner')"

  local sha dir log rc same_sha=0
  sha="$(resolve_main_sha "$mainref" "$do_fetch")" || return 3

  # A LIFT MEASURES A LATER MAIN, NEVER AN EARLIER ONE. Re-measuring on a sha
  # that PREDATES the one the hold was opened on cannot say anything about the
  # fix, and it is the shape a stale checkout produces silently: the command
  # runs, exits 0, and the hold clears against code the fix never reached.
  if [ "$sha" = "$opened_sha" ]; then
    same_sha=1
  elif ! git -C "$ROOT" merge-base --is-ancestor "$opened_sha" "$sha" >/dev/null 2>&1; then
    cannot_read "'$mainref' resolves to $sha, which is NOT a descendant of the sha this hold was opened on ($opened_sha). A lift measures a LATER main; measuring an older or divergent one clears the hold against code the fix never reached."
    return 3
  fi

  make_clean_checkout "$sha" || return 3
  dir="$CLEAN_DIR"
  log="$(mktemp "${TMPDIR:-/tmp}/main-red-hold-lift.XXXXXX")" || {
    cannot_read "cannot create a log file for the lift measurement"; return 3; }

  printf '%s: re-measuring hold %s on a CLEAN detached checkout of %s (%s)\n' "$PROG" "$slug" "$mainref" "$sha"
  printf '%s:   opened on : %s\n' "$PROG" "$opened_sha"
  printf '%s:   $ %s\n' "$PROG" "$repro"
  run_repro "$dir" "$repro" "$log"
  rc=$?
  printf '%s:   exit code (read directly, unpiped): %s\n' "$PROG" "$rc"

  if [ "$rc" -eq 127 ] || [ "$rc" -eq 126 ]; then
    cannot_read "the recorded reproduction command could not be EXECUTED on $sha (exit $rc); the hold STANDS and this is not a verdict about it"
    rm -f "$log"
    return 3
  fi

  if [ "$rc" -ne 0 ]; then
    printf 'HOLD STANDS: %s still reproduces on clean main %s (exit %s). Owner: %s\n' "$slug" "$sha" "$rc" "$owner"
    sed -n '1,20p' "$log"
    rm -f "$log"
    return 1
  fi
  rm -f "$log"

  local new
  new="$(printf '%s' "$json" | jq --arg id "$slug" '.holds = (.holds | map(select(.id != $id)))')" || {
    cannot_read "could not rewrite $reg_abs to drop the lifted hold"; return 3; }
  printf '%s\n' "$new" >"$reg_abs" || { cannot_read "could not write $reg_abs"; return 3; }

  printf 'LIFTED: %s\n' "$slug"
  if [ "$same_sha" = "1" ]; then
    printf '  NOTE: main has NOT moved since this hold was opened. The same command on the SAME sha now exits 0, so the original red was FLAKY, not fixed. That is worth saying out loud rather than recording as a fix.\n'
  fi
  printf '  measured on: CLEAN checkout of %s (%s)\n' "$mainref" "$sha"
  printf '  command    : %s\n' "$repro"
  printf '  exit code  : 0 (read directly, not through a pipe)\n'
  printf '  was opened on: %s\n' "$opened_sha"
  printf '  removed from : %s\n' "$reg"
  return 0
}

cmd_list() {
  local reg="$REGISTRY_DEFAULT"
  while [ $# -gt 0 ]; do
    case "$1" in
      --registry) [ $# -ge 2 ] || die_usage "--registry needs a path"; reg="$2"; shift 2 ;;
      *) die_usage "unknown argument to list: $1" ;;
    esac
  done
  require_jq || return 3
  local json
  json="$(reg_read "$(reg_path "$reg")")" || return 3
  printf '%s' "$json" | jq -r '
    if (.holds | length) == 0 then "no open holds"
    else (.holds[] | "\(.id)\towner=\(.owner)\ttrees=\(.trees | join(","))\topened_on=\(.opened_on_sha)\trepro=\(.repro)")
    end'
  return 0
}

# ---------------------------------------------------------------------------
# --selftest
# ---------------------------------------------------------------------------

ST_PASS=0
ST_FAIL=0
st_ok()   { ST_PASS=$((ST_PASS+1)); printf 'PASS  %s\n' "$1"; }
st_bad()  { ST_FAIL=$((ST_FAIL+1)); printf 'FAIL  %s\n' "$1"; }
st_is()   { # name expected actual
  if [ "$2" = "$3" ]; then st_ok "$1"; else st_bad "$1 — expected [$2] got [$3]"; fi
}

selftest() {
  command -v jq >/dev/null 2>&1 || { cannot_read "jq is not on PATH; --selftest cannot run"; return 3; }
  command -v git >/dev/null 2>&1 || { cannot_read "git is not on PATH; --selftest cannot run"; return 3; }

  local base fix reg rc out mutant
  base="$(mktemp -d "${TMPDIR:-/tmp}/main-red-hold-st.XXXXXX")"
  fix="$base/fixture"
  mkdir -p "$fix/internal/widget" "$fix/scripts"
  printf 'module example.com/fix\n\ngo 1.25.0\n' >"$fix/go.mod"
  printf 'package widget\n' >"$fix/internal/widget/w.go"
  printf 'package widget\n' >"$fix/internal/widget/w_test.go"
  printf '#!/bin/sh\necho unrelated\n' >"$fix/scripts/unrelated.sh"
  git -C "$fix" init -q -b main >/dev/null 2>&1
  git -C "$fix" config user.email st@example.com
  git -C "$fix" config user.name selftest
  git -C "$fix" add -A >/dev/null 2>&1
  git -C "$fix" commit -qm "fixture" >/dev/null 2>&1
  local sha0
  sha0="$(git -C "$fix" rev-parse HEAD)"

  # PRECONDITION assertions — a control says nothing about a setup that never
  # reached the state it is supposed to measure.
  if [ -d "$fix/internal/widget" ]; then st_ok "0a precondition: the fixture really has internal/widget"; else st_bad "0a precondition: fixture tree missing"; fi
  if [ -n "$sha0" ]; then st_ok "0b precondition: fixture main resolves to $sha0"; else st_bad "0b precondition: fixture has no commit"; fi

  reg="$base/holds.json"
  local RED='printf "FAIL\texample.com/fix/internal/widget\t0.10s\n"; exit 1'
  local GREEN='printf "ok\texample.com/fix/internal/widget\t0.10s\n"; exit 0'
  local RED_NO_TREE='printf "something broke and names nothing\n"; exit 1'
  # A typo'd command that still carries a REAL path argument: without the 127
  # guard, D3 derives internal/widget from that argument and the typo becomes a
  # hold. That is what arm 13b discriminates.
  local TYPO='this-command-does-not-exist-anywhere-9f3a ./internal/widget/'
  local RUN="MAIN_RED_HOLD_ROOT=$fix bash $SELF"

  # 1 — a repro that exits 0 opens nothing.
  out="$(eval "$RUN" open --owner lane:cli --repro "'$GREEN'" --main-ref main --no-fetch --registry "$reg" 2>&1)"; rc=$?
  st_is "1 open on a green repro exits 0 (NO HOLD)" "0" "$rc"
  case "$out" in *"NO HOLD"*) st_ok "1b it says NO HOLD" ;; *) st_bad "1b missing NO HOLD: $out" ;; esac
  if [ ! -f "$reg" ]; then st_ok "1c nothing was recorded"; else st_bad "1c a registry was written for a green repro"; fi

  # 2 — a repro that reproduces opens a hold, per-tree, owner recorded.
  out="$(eval "$RUN" open --owner lane:cli --task task-xyz --id st-hold --repro "'$RED'" --main-ref main --no-fetch --registry "$reg" 2>&1)"; rc=$?
  st_is "2 open on a reproducing repro exits 1 (HOLD OPENED)" "1" "$rc"
  st_is "2b tree is DERIVED as internal/widget" "internal/widget" "$(jq -r '.holds[0].trees[0]' "$reg" 2>/dev/null)"
  st_is "2c owner recorded in the committed registry" "lane:cli" "$(jq -r '.holds[0].owner' "$reg" 2>/dev/null)"
  st_is "2d the sha it reproduced on is recorded" "$sha0" "$(jq -r '.holds[0].opened_on_sha' "$reg" 2>/dev/null)"
  st_is "2e the exit code it read is recorded" "1" "$(jq -r '.holds[0].opened_exit' "$reg" 2>/dev/null)"
  st_is "2f derivation tier is D1-package (derived, not declared)" "D1-package" "$(jq -r '.holds[0].derivation' "$reg" 2>/dev/null)"
  case "$out" in *"OWNER         : lane:cli"*) st_ok "2g the open prints the owner in the same motion" ;; *) st_bad "2g owner not printed by open" ;; esac

  # 3 + 4 — BOTH DIRECTIONS IN ONE RUN.
  out="$(eval "$RUN" check --registry "$reg" internal/widget/w.go 2>&1)"; rc=$?
  st_is "3 a change INSIDE the held tree is HELD (exit 1)" "1" "$rc"
  case "$out" in *"HELD: st-hold"*) st_ok "3b it names the hold" ;; *) st_bad "3b: $out" ;; esac
  case "$out" in *"OWNER      : lane:cli"*) st_ok "3c the hold verdict carries the owner" ;; *) st_bad "3c owner missing from HELD verdict" ;; esac
  out="$(eval "$RUN" check --registry "$reg" scripts/unrelated.sh 2>&1)"; rc=$?
  st_is "4 a change OUTSIDE the held tree is NOT held (exit 0)" "0" "$rc"
  case "$out" in *"CLEAR"*) st_ok "4b it says CLEAR" ;; *) st_bad "4b: $out" ;; esac
  # and a mixed change is held (the held file decides, not the count)
  out="$(eval "$RUN" check --registry "$reg" scripts/unrelated.sh internal/widget/w.go 2>&1)"; rc=$?
  st_is "4c a mixed change is HELD" "1" "$rc"

  # 5 — lift refuses while the failure still reproduces.
  out="$(eval "$RUN" lift --id st-hold --main-ref main --no-fetch --registry "$reg" 2>&1)"; rc=$?
  st_is "5 lift while still red exits 1 (HOLD STANDS)" "1" "$rc"
  st_is "5b the hold is still in the registry" "1" "$(jq '.holds | length' "$reg")"

  # 6 — lift clears on a MEASUREMENT on a LATER main sha.
  printf 'package widget // fixed\n' >"$fix/internal/widget/w.go"
  git -C "$fix" add -A >/dev/null 2>&1
  git -C "$fix" commit -qm "fix the widget" >/dev/null 2>&1
  local sha1
  sha1="$(git -C "$fix" rev-parse HEAD)"
  if [ "$sha1" != "$sha0" ]; then st_ok "6a precondition: main really moved ($sha0 -> $sha1)"; else st_bad "6a precondition: main did not move, the lift would measure the SAME sha"; fi
  jq --arg r "$GREEN" '.holds[0].repro = $r' "$reg" >"$reg.tmp" && mv "$reg.tmp" "$reg"
  out="$(eval "$RUN" lift --id st-hold --main-ref main --no-fetch --registry "$reg" 2>&1)"; rc=$?
  st_is "6 lift on a green re-measurement exits 0 (LIFTED)" "0" "$rc"
  case "$out" in *"$sha1"*) st_ok "6b the LIFTED verdict quotes the later sha" ;; *) st_bad "6b later sha not quoted: $out" ;; esac
  case "$out" in *"exit code  : 0"*) st_ok "6c the LIFTED verdict quotes the exit code" ;; *) st_bad "6c exit code not quoted" ;; esac
  st_is "6d the hold is gone" "0" "$(jq '.holds | length' "$reg")"

  # 6e — a lift against an OLDER/divergent main is refused. The fixture's first
  #      commit is an ancestor of the second, so lifting a hold opened on sha1
  #      against sha0 is the "measured an earlier main" shape.
  git -C "$fix" branch -f older "$sha0" >/dev/null 2>&1
  jq --arg r "$GREEN" --arg s "$sha1" '.holds = [{id:"st-old", trees:["internal/widget"], repro:$r, owner:"x", task:null, opened_at:"t", opened_on_sha:$s, opened_exit:1, derivation:"D1-package", note:null, reproduction_head:""}]' "$reg" >"$reg.tmp" && mv "$reg.tmp" "$reg"
  out="$(eval "$RUN" lift --id st-old --main-ref older --no-fetch --registry "$reg" 2>&1)"; rc=$?
  st_is "6e lift against an EARLIER main sha is CANNOT READ (exit 3)" "3" "$rc"
  case "$out" in *"NOT a descendant"*) st_ok "6f it says the sha is not a descendant" ;; *) st_bad "6f: $out" ;; esac
  st_is "6g and the hold survived the refused lift" "1" "$(jq '.holds | length' "$reg")"
  jq '.holds = []' "$reg" >"$reg.tmp" && mv "$reg.tmp" "$reg"

  # 7 — there is NO manual lift path.
  eval "$RUN" lift --id st-hold --force --registry "$reg" >/dev/null 2>&1; rc=$?
  st_is "7 lift --force is a usage error, not a lift" "2" "$rc"
  eval "$RUN" lift --id st-hold --skip-repro --registry "$reg" >/dev/null 2>&1; rc=$?
  st_is "7b lift --skip-repro is a usage error, not a lift" "2" "$rc"

  # ---- REFUSALS ----------------------------------------------------------
  local NOOWNER CANNOT
  out="$(eval "$RUN" open --repro "'$RED'" --main-ref main --no-fetch --registry "$base/r8.json" 2>&1)"; rc=$?
  st_is "8 open with no --owner is CANNOT READ (exit 3)" "3" "$rc"
  case "$out" in *"CANNOT READ"*"--owner is mandatory"*) st_ok "8b it says why" ;; *) st_bad "8b: $out" ;; esac

  out="$(eval "$RUN" open --owner x --repro "'$RED'" --main-ref no/such/ref --no-fetch --registry "$base/r9.json" 2>&1)"; rc=$?
  st_is "9 open against an unreachable main is CANNOT READ (exit 3)" "3" "$rc"
  case "$out" in *"cannot reach main"*) st_ok "9b it says it cannot reach main" ;; *) st_bad "9b: $out" ;; esac

  out="$(eval "$RUN" open --owner x --repro "'$RED_NO_TREE'" --main-ref main --no-fetch --registry "$base/r10.json" 2>&1)"; rc=$?
  st_is "10 a red with no derivable tree is CANNOT READ (exit 3)" "3" "$rc"
  if [ ! -f "$base/r10.json" ]; then st_ok "10b and it recorded nothing"; else st_bad "10b it wrote a scopeless hold"; fi
  # 10a — the refusal line is NOT byte-identical to the clear line.
  CANNOT="$(printf '%s' "$out" | grep 'CANNOT READ' | head -1)"
  NOOWNER="$(eval "$RUN" open --owner x --repro "'$GREEN'" --main-ref main --no-fetch --registry "$base/r10b.json" 2>&1 | grep 'NO HOLD' | head -1)"
  if [ -n "$CANNOT" ] && [ "$CANNOT" != "$NOOWNER" ]; then st_ok "10a the refusal line differs from the no-hold line"; else st_bad "10a refusal and no-hold are indistinguishable"; fi

  out="$(eval "$RUN" open --owner x --repro "'$TYPO'" --main-ref main --no-fetch --registry "$base/r10c.json" 2>&1)"; rc=$?
  st_is "10c an UNRUNNABLE repro is CANNOT READ, not a red" "3" "$rc"

  printf 'this is not json\n' >"$base/bad.json"
  out="$(eval "$RUN" check --registry "$base/bad.json" internal/widget/w.go 2>&1)"; rc=$?
  st_is "11 an unparseable registry is CANNOT READ (exit 3), never CLEAR" "3" "$rc"

  out="$(eval "$RUN" check --registry "$reg" --changed-since no/such/ref 2>&1)"; rc=$?
  st_is "12 an unresolvable --changed-since is CANNOT READ (exit 3)" "3" "$rc"

  out="$(eval "$RUN" check --registry "$reg" 2>&1)"; rc=$?
  st_is "12b check with no paths at all is CANNOT READ, not CLEAR" "3" "$rc"

  # 12c — a resolvable base that yields an EMPTY diff is a misconfigured base,
  #       not a clean PR. HEAD...HEAD is the minimal reproduction of that shape.
  out="$(eval "$RUN" check --registry "$reg" --changed-since HEAD 2>&1)"; rc=$?
  st_is "12c a resolvable base with a ZERO-path diff is CANNOT READ, not CLEAR" "3" "$rc"
  case "$out" in *"ZERO changed paths"*) st_ok "12d it says the diff was empty" ;; *) st_bad "12d: $out" ;; esac

  # ---- MUTATION PROOFS: each guard is shown LOAD-BEARING ------------------
  # The guard is deleted from a scratch copy of this script; the mutant must
  # behave DIFFERENTLY on the SAME input. A guard whose removal changes nothing
  # was never a guard.
  mutate() { # $1 = marker, $2 = out path
    awk -v m="$1" '
      $0 ~ ("^# <<MUT:" m "$") { skip=1; next }
      $0 ~ ("^# MUT:" m ">>$")  { skip=0; next }
      skip != 1 { print }
    ' "$SELF" >"$2"
  }

  # 13a — tree-refusal. Original: CANNOT READ (arm 10). Mutant: opens a hold
  #       with an EMPTY tree set, which then holds nothing = fail-open.
  mutant="$base/mut-tree.sh"
  mutate "tree-refusal" "$mutant"
  if [ "$(wc -l <"$mutant")" -lt "$(wc -l <"$SELF")" ]; then st_ok "13a-pre the mutation actually removed lines"; else st_bad "13a-pre the mutation removed nothing — the marker did not match"; fi
  MAIN_RED_HOLD_ROOT="$fix" bash "$mutant" open --owner x --repro "$RED_NO_TREE" --main-ref main --no-fetch --registry "$base/m13a.json" >/dev/null 2>&1; rc=$?
  st_is "13a mutant (tree guard gone) opens a hold where the original refused" "1" "$rc"
  MAIN_RED_HOLD_ROOT="$fix" bash "$mutant" check --registry "$base/m13a.json" internal/widget/w.go >/dev/null 2>&1; rc=$?
  st_is "13a2 and that hold holds NOTHING (CLEAR) — the guard was load-bearing" "0" "$rc"

  # 13b — repro-unrunnable. Original: CANNOT READ (arm 10c). Mutant: treats a
  #       typo's 127 as a red and manufactures a hold.
  mutant="$base/mut-repro.sh"
  mutate "repro-unrunnable" "$mutant"
  if [ "$(wc -l <"$mutant")" -lt "$(wc -l <"$SELF")" ]; then st_ok "13b-pre the mutation actually removed lines"; else st_bad "13b-pre the mutation removed nothing"; fi
  MAIN_RED_HOLD_ROOT="$fix" bash "$mutant" open --owner x --repro "$TYPO" --main-ref main --no-fetch --registry "$base/m13b.json" >/dev/null 2>&1; rc=$?
  if [ "$rc" = "1" ]; then st_ok "13b mutant (127 guard gone) manufactures a HOLD out of a typo (exit 1, original 3)"; else st_bad "13b mutant exited $rc, expected 1 — the 127 guard is not what produces the original refusal"; fi
  if [ -f "$base/m13b.json" ]; then st_ok "13b2 and the mutant wrote that bogus hold to the registry"; else st_bad "13b2 the mutant recorded nothing, so this arm discriminates nothing"; fi

  # 13c — registry-parse-refusal. Original: CANNOT READ (arm 11). Mutant:
  #       reports CLEAR off a file it could not parse.
  mutant="$base/mut-reg.sh"
  mutate "registry-parse-refusal" "$mutant"
  if [ "$(wc -l <"$mutant")" -lt "$(wc -l <"$SELF")" ]; then st_ok "13c-pre the mutation actually removed lines"; else st_bad "13c-pre the mutation removed nothing"; fi
  out="$(MAIN_RED_HOLD_ROOT="$fix" bash "$mutant" check --registry "$base/bad.json" internal/widget/w.go 2>&1)"; rc=$?
  if [ "$rc" != "3" ]; then st_ok "13c mutant (registry guard gone) fails OPEN on unparseable JSON (exit $rc, original 3)"; else st_bad "13c mutant still refused: $out"; fi

  # 13d — NO DETACHED WORKTREE IS LEAKED. The clean checkout is a real git
  #       worktree of the repo under test; a run that leaves one behind poisons
  #       the next run's `git worktree list` and, in CI, the runner's disk. This
  #       arm was written because the first cut leaked one PER RUN (see the
  #       header on make_clean_checkout).
  local leaked
  leaked="$(git -C "$fix" worktree list 2>/dev/null | grep -c 'main-red-hold\.')"
  st_is "13d no detached clean-checkout worktree was leaked by any arm above" "0" "$leaked"

  # 14 — the restored original still refuses (the mutations did not leak).
  eval "$RUN" check --registry "$base/bad.json" internal/widget/w.go >/dev/null 2>&1; rc=$?
  st_is "14 the unmutated script still refuses the same input" "3" "$rc"

  rm -rf "$base"
  printf '\n%s --selftest: %s passed, %s failed\n' "$PROG" "$ST_PASS" "$ST_FAIL"
  [ "$ST_FAIL" -eq 0 ] || return 1
  return 0
}

# ---------------------------------------------------------------------------

[ $# -ge 1 ] || die_usage "a subcommand is required (open | check | lift | list | --selftest)"
SUB="$1"; shift
case "$SUB" in
  open)  cmd_open "$@" ;;
  check) cmd_check "$@" ;;
  lift)  cmd_lift "$@" ;;
  list)  cmd_list "$@" ;;
  --selftest) selftest ;;
  -h|--help) usage; exit 0 ;;
  *) die_usage "unknown subcommand: $SUB" ;;
esac
exit $?
