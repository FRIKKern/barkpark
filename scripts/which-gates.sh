#!/usr/bin/env bash
#
# which-gates.sh — which CI gates does THIS change dispatch?
#
# WHY IT EXISTS (task-cb42bf8ab0539891, measured on PR #16608). A builder was
# briefed "node --test, the preview smoke, console-path-escape-check" for a
# console-static-only diff and went red on TWO REQUIRED contexts: the Console
# gate also runs __refusal_copy_census.mjs, and the Cloud gate runs the whole
# cloud Elixir suite because console_reader_census_test.exs reads app.js. The
# gate list had been derived from the LANE (who owns the files) instead of from
# the WORKFLOWS (which dispatch on the paths). The doctrine that fixes that was
# prose in a lead brief, and a rule that is only words survives exactly as long
# as everyone remembers it. This is the same rule, executable.
#
# THE ONE DESIGN CONSTRAINT: this wrapper carries NO path set of its own. Every
# verdict is produced by SHELLING THE PRIMITIVE THE DISPATCHER ITSELF SHELLS —
# scripts/<x>-path-escape-check.sh --match <set> — and the (primitive, set)
# pairs are DISCOVERED by scanning .github/workflows/ for those very call sites.
# Re-implementing a path set here would give a reader a second answer to a
# question that already has exactly one, and the second one would rot.
#
# A FAILED READ IS NEVER A SKIP. If a discovered primitive is missing, exits
# non-zero, or prints anything other than `true`/`false`, this script prints a
# distinct `CANNOT READ:` line naming it and exits non-zero. `SKIPPED` means a
# primitive said `false`; it never means "nobody answered".
#
# USAGE
#   which-gates.sh                      # refs/remotes/origin/main...HEAD
#   which-gates.sh <git-range>          # e.g. origin/main...HEAD, HEAD~3..HEAD
#   which-gates.sh --stdin              # changed paths on stdin, one per line
#
# OUTPUT: one row per dispatcher-backed workflow —
#   Console gate     DISPATCHED  (required)
# `(required)` is read from .github/required-checks.json, never hardcoded, so a
# reader can see at a glance which DISPATCHED rows actually block the merge.
#
# EXIT: 0 every row has a verdict · 1 at least one CANNOT READ · 2 bad usage.
#
# bash 3.2 compatible (macOS system bash): no associative arrays, no mapfile.

set -uo pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${WHICH_GATES_ROOT:-$(cd -- "$SELF_DIR/.." && pwd)}"

WORKFLOW_DIR="$REPO_ROOT/.github/workflows"
REQUIRED_SPEC="$REPO_ROOT/.github/required-checks.json"

DEFAULT_RANGE="refs/remotes/origin/main...HEAD"

rc=0
cannot_read() { echo "CANNOT READ: $*" >&2; rc=1; }

# ---------------------------------------------------------------------------
# 1. the changed-path set
# ---------------------------------------------------------------------------
mode="range"
range="$DEFAULT_RANGE"
case "${1:-}" in
  --stdin) mode="stdin" ;;
  -h | --help)
    sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  "") ;;
  --*)
    echo "which-gates: unknown argument '$1'" >&2
    echo "usage: $0 [<git-range>|--stdin]" >&2
    exit 2
    ;;
  *) range="$1" ;;
esac

if [ "$mode" = "stdin" ]; then
  changed="$(cat)"
else
  # --no-renames: rename detection prints only the DESTINATION, so a `git mv`
  # out of a dispatched tree would read as "that tree lost nothing". Both
  # dispatchers pass this flag; so does this. `-z | tr` survives a quoted path.
  changed="$(git -C "$REPO_ROOT" -c core.quotepath=false diff -z --name-only --no-renames "$range" 2>/dev/null | tr '\0' '\n')" || changed=""
  if [ -z "$changed" ]; then
    if ! git -C "$REPO_ROOT" rev-parse --verify --quiet "${range%%.*}" >/dev/null 2>&1 &&
      ! git -C "$REPO_ROOT" diff --quiet "$range" >/dev/null 2>&1; then
      cannot_read "git range '$range' — it does not resolve in $REPO_ROOT, so no changed-path set exists to answer over."
      exit 1
    fi
  fi
fi

changed="$(printf '%s\n' "$changed" | sed '/^$/d')"

if [ -z "$changed" ]; then
  # Same polarity as every dispatcher in this repo: an empty set is not a skip.
  # A revert pair or a branch-sync PR nets to nothing, and both cloud.yml and
  # console-harness.yml answer `true` and run EVERYTHING there rather than green
  # a required context nothing measured. Say so instead of printing false rows.
  echo "changed-path set is EMPTY over '${range}'."
  echo "Every dispatcher in this repo answers an empty set with TRUE and runs the WHOLE suite (a skip would green a required context nothing measured). Treat every gate below as DISPATCHED."
fi

# ---------------------------------------------------------------------------
# 2. the required contexts — read, never hardcoded
# ---------------------------------------------------------------------------
required_contexts=""
if [ ! -r "$REQUIRED_SPEC" ]; then
  cannot_read "$REQUIRED_SPEC — the required-context spec is absent or unreadable, so no row can be marked (required)."
else
  required_contexts="$(jq -r '.protection.required_status_checks.checks[].context' "$REQUIRED_SPEC" 2>/dev/null)" || required_contexts=""
  if [ -z "$required_contexts" ]; then
    cannot_read "$REQUIRED_SPEC — .protection.required_status_checks.checks[].context yielded NO context. An empty required set would silently print every row as advisory."
  fi
fi

is_required() {
  [ -n "$required_contexts" ] || return 1
  printf '%s\n' "$required_contexts" | grep -Fxq -- "$1"
}

# The label for a workflow: the required context this workflow publishes, found
# by matching the spec's context strings against the workflow's own `name:`
# values. Never a table in this file — a table would go stale the day a job is
# renamed, and would then name a context that does not exist.
label_for_workflow() {
  local wf="$1" ctx
  while IFS= read -r ctx; do
    [ -n "$ctx" ] || continue
    if grep -qE "^[[:space:]]*name:[[:space:]]+${ctx}[[:space:]]*$" "$wf" 2>/dev/null; then
      printf '%s' "$ctx"
      return 0
    fi
  done <<EOF
$required_contexts
EOF
  basename "$wf" .yml
}

# ---------------------------------------------------------------------------
# 3. discover the dispatch call sites
# ---------------------------------------------------------------------------
# One row per (workflow, primitive, set), scraped from the very lines the
# dispatchers run. Whole-line comments are dropped: a workflow that DISCUSSES a
# primitive is not a workflow that dispatches on it.
if [ ! -d "$WORKFLOW_DIR" ]; then
  cannot_read "$WORKFLOW_DIR — no workflow directory, so no dispatch call site can be discovered."
  exit 1
fi

call_sites="$(
  grep -hE 'scripts/[A-Za-z0-9_-]*path-escape-check\.sh[[:space:]]+--match' "$WORKFLOW_DIR"/*.yml 2>/dev/null |
    grep -vE '^[[:space:]]*#' |
    sed -nE 's|.*(scripts/[A-Za-z0-9_-]*path-escape-check\.sh)[[:space:]]+--match[[:space:]]*([A-Za-z0-9_-]*).*|\1 \2|p'
)"

# Which workflow each call site came from — grep -H, same filter, same order.
call_site_files="$(
  grep -HE 'scripts/[A-Za-z0-9_-]*path-escape-check\.sh[[:space:]]+--match' "$WORKFLOW_DIR"/*.yml 2>/dev/null |
    grep -vE ':[[:space:]]*#' |
    sed -E 's|:.*||'
)"

if [ -z "$call_sites" ]; then
  cannot_read "$WORKFLOW_DIR/*.yml — found ZERO '--match' dispatch call sites. Either every dispatcher was rewritten or this scan is broken; either way an empty roster would print as 'no gates dispatched'."
  exit 1
fi

# ---------------------------------------------------------------------------
# 4. ask each primitive
# ---------------------------------------------------------------------------
# NO PIPE around the primitive: `cmd | tail` reports tail's exit code, and this
# script's whole contract is that a failed read is loud. Output to a variable,
# status from the command itself.
ask() { # ask <abs-primitive> [set] ; echoes true|false, returns non-zero on refusal
  local prim="$1" set="${2:-}" out status
  if [ -n "$set" ]; then
    out="$(printf '%s\n' "$changed" | bash "$prim" --match "$set" 2>&1)"
  else
    out="$(printf '%s\n' "$changed" | bash "$prim" --match 2>&1)"
  fi
  status=$?
  [ $status -eq 0 ] || {
    printf '%s' "$out"
    return 1
  }
  printf '%s' "$out"
  return 0
}

row() { printf '%-22s %-11s %s\n' "$1" "$2" "$3"; }

seen_prims=""
i=0
printf '%s\n' "$call_sites" | {
  while IFS=' ' read -r rel set; do
    [ -n "$rel" ] || continue
    i=$((i + 1))
    wf="$(printf '%s\n' "$call_site_files" | sed -n "${i}p")"
    prim="$REPO_ROOT/$rel"

    if [ ! -r "$prim" ]; then
      cannot_read "$rel — dispatched by $(basename "${wf:-a workflow}") --match ${set:-<no set>}, but the file is absent or unreadable. NOT a skip: nothing answered."
      continue
    fi

    verdict="$(ask "$prim" "$set")" || {
      cannot_read "$rel --match ${set:-<no set>} — exited non-zero. It said: ${verdict:-<no output>}"
      continue
    }
    case "$verdict" in
    true | false) ;;
    *)
      cannot_read "$rel --match ${set:-<no set>} — printed '${verdict:-<empty>}', which is neither true nor false. Refusing to render it as a verdict."
      continue
      ;;
    esac

    label="$(label_for_workflow "$wf")"
    # Two sets under one context (elixir compile/test) must not print as one row
    # that hides which half fired: name the set whenever the workflow has more
    # than one call site for the same primitive.
    if [ "$(printf '%s\n' "$call_sites" | grep -cF -- "$rel ")" -gt 1 ]; then
      label="$label [$set]"
    fi

    note=""
    is_required "$(printf '%s' "$label" | sed 's/ \[.*//')" && note="(required)"

    if [ "$verdict" = "true" ]; then row "$label" "DISPATCHED" "$note"; else row "$label" "SKIPPED" "$note"; fi
    seen_prims="$seen_prims $rel"
  done

  # -----------------------------------------------------------------------
  # 5. primitives that exist but NO workflow shells
  # -----------------------------------------------------------------------
  # go-tests.yml is the live case: it computes its verdict in-job with awk that
  # is character-for-character the same as go-path-escape-check.sh's, so the
  # primitive exists and is authoritative while no workflow line shells it. Its
  # row is printed WITH THAT PROVENANCE ATTACHED rather than guessed at or
  # silently dropped; a primitive that cannot self-answer prints UNKNOWN and the
  # reason, never a verdict.
  for prim in "$REPO_ROOT"/scripts/*-path-escape-check.sh; do
    [ -r "$prim" ] || continue
    rel="scripts/$(basename "$prim")"
    case " $seen_prims " in *" $rel "*) continue ;; esac
    stem="$(basename "$prim" -path-escape-check.sh)"
    verdict="$(ask "$prim" "")" || verdict=""
    case "$verdict" in
    true) row "$stem" "DISPATCHED" "(no workflow --match call site; verdict from $rel --match, the primitive's own copy of the in-job parser)" ;;
    false) row "$stem" "SKIPPED" "(no workflow --match call site; verdict from $rel --match, the primitive's own copy of the in-job parser)" ;;
    *) row "$stem" "UNKNOWN" "($rel exists but no workflow shells its --match, and it gave no true/false answer without a set argument this script will not invent)" ;;
    esac
  done

  exit $rc
}
rc=$?

exit "$rc"
