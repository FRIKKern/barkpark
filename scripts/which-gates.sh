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
# AND, WHEN A GO CHANGE MOVES A JSON TAG, one WHY paragraph after the rows: the
# Elixir census tests that grep that Go package, the gates they ride in on, and
# the `==` pins they hold, all read out of the census AT RUN TIME (section 6).
# The rows say a Go diff dispatches the Cloud gate; that paragraph says why an
# Elixir suite reds over Go source that go build/vet/test call green.
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
    sed -n '2,45p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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
#
# MENTION IS NOT EXECUTION — and a `#` comment is not the only way to mention.
# Measured on origin/main 2026-09-10 (task-1cea7edd271d588b). PR #17141 gave
# console-harness.yml's dispatcher a verdict wrapper whose refusal prose NAMES
# the primitive and its flag inside an `echo`:
#
#     echo "::error::dispatcher ${v}: scripts/console-path-escape-check.sh --match console exited ${rc}. …"
#
# That line is not a comment, so the old scan counted it as a SECOND call site
# for the same (primitive, set). Two consequences, both silent: the Console gate
# printed TWICE, and — because the label disambiguator keys on "this primitive
# has more than one call site" (the elixir compile/test case) — both rows came
# out as `Console gate [console]`. Every reader and every assertion looking for
# a `Console gate` row found none. The instrument that exists to tell a builder
# a REQUIRED gate will run had stopped naming that gate, in an advisory job.
#
# So a call site must sit at COMMAND POSITION: at the start of a `run:` scalar,
# after a shell separator (`|`, `;`, `&`, `(`), or behind an invoking verb
# (`bash`/`sh`/`exec`/`source`). Prose that quotes the command reads as prose.
# Every real dispatcher call site in this repo is `… | bash scripts/<x> --match
# <set>` (cloud.yml, console-harness.yml, elixir.yml x2), so this is a
# tightening that keeps all four and drops the quote.
if [ ! -d "$WORKFLOW_DIR" ]; then
  cannot_read "$WORKFLOW_DIR — no workflow directory, so no dispatch call site can be discovered."
  exit 1
fi

# ── THE PINNED SHAPE (task-3a81e68f7027ca98) ────────────────────────────────
# Since cloud.yml, console-harness.yml and elixir.yml pin their path-set script
# to the MERGE REF, the literal primitive name no longer sits at the call site:
# the dispatchers shell `bash "$pin_script" --match <set>` (cloud.yml through a
# `match_set --match <set>` wrapper over the same line), and the literal lives
# in the step's `pin_script="scripts/<x>-path-escape-check.sh"` assignment.
#
# Measured 2026-09-11 on the branch that landed the pin: with only the literal
# pattern below, this scan found ZERO call sites repo-wide and the script
# printed its CANNOT READ and exited 1. That is the guard working — and it is
# also the whole roster gone, so the pattern has to learn the new shape rather
# than the guard be loosened.
#
# The primitive for a pinned site is resolved PER FILE from that assignment. A
# file with a pinned call site and no assignment resolves to nothing and the
# row is dropped by the emptiness guard below — never guessed at.
PIN_ASSIGN_RE='^[[:space:]]*pin_script="(scripts/[A-Za-z0-9_-]*path-escape-check\.sh)"'
PINNED_SITE_RE='(^|[|;&(]|[[:space:]])(bash|sh|exec|source|match_set)[[:space:]]+("?\$\{?pin_script\}?"?[[:space:]]+)?--match[[:space:]]+[A-Za-z0-9_-]'

CALL_SITE_RE='(^|[|;&(]|[[:space:]](bash|sh|exec|source)|^[[:space:]]*(-[[:space:]]+)?run:)[[:space:]]*scripts/[A-Za-z0-9_-]*path-escape-check\.sh[[:space:]]+--match'

# ONE scan, so the two lists below cannot drift out of index with each other.
# (They previously used two DIFFERENT comment filters — `^[[:space:]]*#` against
# `:[[:space:]]*#` — which is a misalignment waiting for its first comment.)
call_site_raw="$(
  grep -HE "$CALL_SITE_RE" "$WORKFLOW_DIR"/*.yml 2>/dev/null |
    grep -vE '^[^:]+:[[:space:]]*#'
)"

call_sites="$(
  printf '%s\n' "$call_site_raw" |
    sed -nE 's|^[^:]+:.*(scripts/[A-Za-z0-9_-]*path-escape-check\.sh)[[:space:]]+--match[[:space:]]*([A-Za-z0-9_-]*).*|\1 \2|p'
)"

# Which workflow each call site came from — same scan, same filter, same order.
call_site_files="$(
  printf '%s\n' "$call_site_raw" |
    sed -E 's|:.*||'
)"

# The pinned sites, appended so the two lists stay index-aligned. One pass per
# workflow file, because the primitive is a property of the FILE (its
# `pin_script=` assignment), not of the line.
for _wf in "$WORKFLOW_DIR"/*.yml; do
  [ -r "$_wf" ] || continue
  _prim="$(sed -nE "s|${PIN_ASSIGN_RE}.*|\\1|p" "$_wf" | sed -n 1p)"
  [ -n "$_prim" ] || continue
  _sets="$(
    grep -E "$PINNED_SITE_RE" "$_wf" 2>/dev/null |
      grep -vE '^[[:space:]]*#' |
      sed -nE 's|.*--match[[:space:]]+([A-Za-z0-9_-]+).*|\1|p'
  )"
  while IFS= read -r _set; do
    [ -n "$_set" ] || continue
    call_sites="${call_sites:+$call_sites
}$_prim $_set"
    call_site_files="${call_site_files:+$call_site_files
}$_wf"
  done <<EOF
$_sets
EOF
done

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

  # -----------------------------------------------------------------------
  # 6. WHY a dispatched gate will read your GO source — the census couplings
  # -----------------------------------------------------------------------
  # task-5ddbd0702c213aec, found on PR #16682. The rows above already answer
  # "does the Cloud gate run on my change?" — a Go diff under the cloudclient
  # package prints `Cloud gate  DISPATCHED  (required)`. What they do not
  # answer is WHY a Go-only diff dispatches an ELIXIR suite, and that silence
  # is a trap: an Elixir census test greps the Go package and pins its json-tag
  # vocabulary with `==`, so adding, removing or RENAMING one tag reds a
  # required context while `go build`, `go vet` and `go test ./internal/...`
  # stay green on BOTH sides. The coupling is invisible from the side the
  # builder is standing on, and a doc line loses to a green Go gate.
  #
  # NO SECOND PATH SET, the same constraint as the rest of this file. Nothing
  # here names a directory the dispatchers own. The couplings are DISCOVERED by
  # two LANGUAGE tests, not by a list:
  #   * an Elixir test that resolves a path with `@name Path.expand(…, __DIR__)`
  #   * whose resolved target IS Go source (a `.go` file, or a directory holding
  #     `.go` files)
  # is by construction an Elixir test whose subject is Go source. The pins are
  # then read OUT OF THAT FILE at run time, by the census's own definition of a
  # pin — the `^\s*@([a-z_]+) -?\d+\s*$` line its own SINGLE PIN arm discovers
  # with. Not one pin name or pin value is written down in this script; a copy
  # here would be the very mirror defect the census exists to catch.
  #
  # AND IT IS KEYED ON A TAG DELTA, NOT ON A PATH. A Go edit that adds, removes
  # or renames no json tag cannot move these pins, and a note that fires on
  # every Go edit is ignored inside a week — strictly worse than silence.
  go_changed=""
  printf '%s\n' "$changed" | grep -E '\.go$' >/dev/null && go_changed=1

  if [ -n "$go_changed" ]; then
    # The one infrastructure root this section reads, in the same class as
    # WORKFLOW_DIR and REQUIRED_SPEC above: where this repo keeps the Elixir
    # tests. It is not a dispatcher's path set and nothing is matched against it.
    # `pwd`-normalised: WHICH_GATES_ROOT can carry a doubled slash (a TMPDIR
    # ending in `/` does it), and a prefix test against an un-normalised root
    # silently matches NOTHING — every coupling would be filtered out and the
    # refusal below would read as "the scan is broken" on a perfectly good tree.
    ROOT_ABS="$(cd -- "$REPO_ROOT" 2>/dev/null && pwd)" || ROOT_ABS="$REPO_ROOT"
    CENSUS_ROOT="$ROOT_ABS/cloud/test"

    couplings=""
    if [ ! -d "$CENSUS_ROOT" ]; then
      cannot_read "$CENSUS_ROOT — this change carries Go source, and the Elixir test root where a Go-reading census would live is absent. NOT a skip: nothing answered."
    else
      raw="$(
        grep -rnE '^[[:space:]]*@[a-z_]+ Path\.expand\("[^"]+", __DIR__\)' "$CENSUS_ROOT" --include='*_test.exs' 2>/dev/null |
          sed -nE 's|^([^:]+):[0-9]+:[[:space:]]*@([a-z_]+) Path\.expand\("([^"]+)".*|\1 \2 \3|p'
      )"
      # Resolve each `Path.expand` exactly as Elixir does — relative to the
      # test file's OWN directory — then keep only the ones that land on Go.
      while IFS=' ' read -r cfile cattr crelpath; do
        [ -n "$crelpath" ] || continue
        target="$(cd -- "$(dirname -- "$cfile")" 2>/dev/null && cd -- "$(dirname -- "$crelpath")" 2>/dev/null && printf '%s/%s' "$(pwd)" "$(basename -- "$crelpath")")" || continue
        [ -n "$target" ] || continue
        case "$target" in "$ROOT_ABS"/*) ;; *) continue ;; esac
        if [ -f "$target" ]; then
          case "$target" in *.go) ;; *) continue ;; esac
        elif [ -d "$target" ]; then
          ls "$target"/*.go >/dev/null 2>&1 || continue
        else
          continue
        fi
        couplings="$(printf '%s\n%s' "$couplings" "${cfile#"$ROOT_ABS"/}|$cattr|${target#"$ROOT_ABS"/}")"
      done <<RAW_EOF
$raw
RAW_EOF
      couplings="$(printf '%s\n' "$couplings" | sed '/^$/d' | sort -u)"
      if [ -z "$couplings" ]; then
        cannot_read "$CENSUS_ROOT/**/*_test.exs — this change carries Go source, and the scan for '@name Path.expand(…, __DIR__)' attributes resolving onto Go source found ZERO. Either every Go-reading census was renamed or moved, or this scan is broken; either way a silent empty roster tells a Go builder its change is uncoupled when it is not."
      fi
    fi

    # Which discovered Go roots does this change actually land in?
    hit=""
    while IFS='|' read -r cfile cattr croot; do
      [ -n "$croot" ] || continue
      pat="^$(printf '%s' "$croot" | sed 's|[][\.*^$/]|\\&|g')(/|$)"
      printf '%s\n' "$changed" | grep -E "$pat" >/dev/null || continue
      hit="$(printf '%s\n%s' "$hit" "$cfile|$cattr|$croot")"
    done <<HIT_EOF
$couplings
HIT_EOF
    hit="$(printf '%s\n' "$hit" | sed '/^$/d')"

    if [ -n "$hit" ]; then
      roots="$(printf '%s\n' "$hit" | awk -F'|' '{print $3}' | sort -u | tr '\n' ' ')"

      # The gates ONE path dispatches — asked of the same primitives as the rows
      # above, never of a table, so this can never name a gate the dispatchers
      # do not. It is how the note says "Cloud gate" without knowing the words.
      gates_for_path() { # gates_for_path <repo-relative path>
        local saved="$changed" rel set wf j=0 v lbl acc=""
        changed="$1"
        while IFS=' ' read -r rel set; do
          [ -n "$rel" ] || continue
          j=$((j + 1))
          wf="$(printf '%s\n' "$call_site_files" | sed -n "${j}p")"
          [ -r "$REPO_ROOT/$rel" ] || continue
          v="$(ask "$REPO_ROOT/$rel" "$set")" || continue
          [ "$v" = "true" ] || continue
          lbl="$(label_for_workflow "$wf")"
          is_required "$lbl" && lbl="$lbl (required)"
          printf '%s\n' "$acc" | grep -Fxq -- "$lbl" || acc="$(printf '%s\n%s' "$acc" "$lbl")"
        done <<INNER_EOF
$call_sites
INNER_EOF
        changed="$saved"
        printf '%s\n' "$acc" | sed '/^$/d' | paste -sd, - | sed 's/,/, /g'
      }

      # THE TAG DELTA. Over a git range it is measured from the diff itself:
      # the json tag NAMES on removed lines against the ones on added lines. A
      # pure reorder, a comment, a renamed Go FIELD, a changed constant — all
      # leave the two sides equal and print nothing. Over --stdin there is no
      # before-state to diff, and that is SAID rather than guessed.
      fire=""
      delta_line=""
      if [ "$mode" = "range" ]; then
        dif="$(git -C "$REPO_ROOT" diff -U0 --no-renames "$range" -- $roots 2>/dev/null)"
        added="$(printf '%s\n' "$dif" | grep '^+' | grep -oE 'json:"[^",]+' | sed 's/json:"//' | sort)"
        removed="$(printf '%s\n' "$dif" | grep '^-' | grep -oE 'json:"[^",]+' | sed 's/json:"//' | sort)"
        if [ "$added" != "$removed" ]; then
          fire=1
          delta_line="json-tag delta over '${range}':  added [$(printf '%s' "$added" | tr '\n' ' ')]  removed [$(printf '%s' "$removed" | tr '\n' ' ')]"
        fi
      else
        fire=1
        delta_line="json-tag delta: NOT MEASURED — --stdin carries paths only, so there is no before-state to diff. Re-run over a git range for the delta."
      fi

      if [ -n "$fire" ]; then
        echo
        echo "PAYLOAD CENSUS COUPLING — an Elixir test reads the Go source this change touches."
        echo "  $delta_line"
        while IFS='|' read -r cfile cattr croot; do
          [ -n "$cfile" ] || continue
          crel="$cfile"
          if [ ! -r "$ROOT_ABS/$cfile" ]; then
            cannot_read "$crel — discovered as a census that reads $croot, but it is not readable, so its pins cannot be named."
            continue
          fi
          pins="$(grep -nE '^[[:space:]]*@[a-z_]+[[:space:]]+-?[0-9]+[[:space:]]*$' "$ROOT_ABS/$cfile" | sed -E 's|^([0-9]+):[[:space:]]*|\1 |')"
          regs="$(grep -nE '^[[:space:]]*@[a-z_]+ %\{[[:space:]]*$' "$ROOT_ABS/$cfile" | sed -E 's|^([0-9]+):[[:space:]]*@([a-z_]+).*|\1 \2|')"
          echo "  $croot"
          echo "    is read at test time by $crel (@$cattr)"
          echo "    which dispatches: $(gates_for_path "$crel")"
          echo "    its committed pins, read out of that file just now — never copied into this script:"
          printf '%s\n' "$pins" | while IFS=' ' read -r ln rest; do
            # `printf '%s\n' ""` still emits ONE line, so an unpinned census
            # would otherwise print a blank pin row naming no attribute.
            [ -n "$ln" ] || continue
            echo "      $rest    ($crel:$ln)"
          done
          printf '%s\n' "$regs" | while IFS=' ' read -r ln rname; do
            [ -n "$rname" ] || continue
            rows="$(awk -v s="$ln" 'NR>s{ if ($0 ~ /^  \}/) exit; if ($0 ~ /=>/) n++ } END{print n+0}' "$ROOT_ABS/$cfile")"
            echo "      @$rname    a ${rows}-row register    ($crel:$ln)"
          done
          if [ -z "$pins" ] && [ -z "$regs" ]; then
            # NO ATTRIBUTE PIN IS A SHAPE, NOT A FAILED READ (2026-09-10,
            # task-1cea7edd271d588b). This branch used to `cannot_read` and exit
            # 1 on the reasoning that "the pin symbols were renamed or deleted,
            # and naming a coupling whose pins cannot be found is theatre".
            # metrics_envelope_reader_census_test.exs (#17169, 2026-09-10) is
            # the counter-example that reached main: it reads the cloudclient
            # package's `MetricsResult` json tags — paths deliberately NOT
            # written here, see case 3 of the harness — and asserts over them
            # with SET comparisons inside the test bodies:
            # a legitimate coupling that never had an `@name <integer>` to lose.
            # Refusing it turned the whole deriver non-zero for every Go diff.
            #
            # A file's content cannot distinguish "pins were deleted" from
            # "pins were never written", so this reports the shape it measured
            # instead of guessing at history. The coupling itself — the reason
            # a required Elixir gate reds over a Go-only change — is announced
            # either way, which is what the note exists to say. Nothing is
            # invented: with no pin line read, no pin value is printed.
            echo "      NO ATTRIBUTE PIN — this census carries no '@name <integer>' line and no"
            echo "      '@name %{' register. It asserts over the Go source INSIDE its test bodies,"
            echo "      so there is no committed number to name here. It reds on a tag move anyway."
          fi
        done <<PRINT_EOF
$hit
PRINT_EOF
        echo "  These are '==' pins: growth reds them exactly as deletion does, and a tag"
        echo "  name that already exists rides free on the name union while still moving a"
        echo "  multiplicity register. go build, go vet and go test ./internal/... are GREEN"
        echo "  on BOTH sides — the Go toolchain cannot see this. Re-measure on THIS tree by"
        echo "  the census's own 999-technique, never by arithmetic, and re-measure again if"
        echo "  another PR moving the same pins lands first."
      fi
    fi
  fi

  exit $rc
}
rc=$?

exit "$rc"
