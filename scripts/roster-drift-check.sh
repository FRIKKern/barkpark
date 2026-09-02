#!/usr/bin/env bash
# roster-drift-check.sh — the two agent-facing ROSTERS must match the code.
#
# WHY THIS EXISTS. Two roster claims in the two highest-traffic agent documents
# had silently undercounted for months:
#
#   root CLAUDE.md  named  6 plugins; 11 modules `use Barkpark.Plugin`
#   api/CLAUDE.md   named  7 task mutation_event kinds; 14 are emitted
#
# Neither is the kind of error a reader catches. A roster reads as complete by
# construction — nothing about "(OnixEdit, Bulldocs, Tasks, Media, Sheets, Frt)"
# announces that five names are missing — so an agent builds a duplicate plugin,
# or a consumer switches on half the event vocabulary and silently drops the
# rest. A truncated enum in a consumer is a bug that never raises.
#
# So the rosters are DERIVED here and compared to what the docs say. The docs
# still name the members (an agent reading the router must not have to run a
# script to learn what exists), but the names are now checked rather than
# trusted, and the doc says where they come from so the next reader can
# re-derive instead of believing a count.
#
# TRIGGER: invoked as §9 of scripts/docs-anchors-check.sh, which runs in the
# `Doc budgets + anchors` job. doc-gates.yml triggers on `.ex` paths, so ADDING
# A PLUGIN MODULE fires this check on that very PR. Like every other arm of that
# job it is ADVISORY — it reds its own check run and cannot block a merge (the
# context carries an S4 exclusion in .github/required-checks.json).
#
# usage: roster-drift-check.sh [--selftest|--help]
#   ROSTER_ROOT=<dir> overrides the tree that is walked (used by --selftest).

set -euo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

usage() {
  echo "usage: roster-drift-check.sh [--selftest|--help]"
  echo "  (no args)   compare documented rosters to the code (exit 0 pass / 1 drift)"
  echo "  --selftest  run the hermetic fixture suite (exit 0 pass / 1 fail)"
  echo "  ROSTER_ROOT=<dir> overrides the tree walked"
}

MODE=run
if [ "$#" -gt 0 ]; then
  case "$1" in
    --selftest) MODE=selftest ;;
    -h|--help) usage; exit 0 ;;
    *) echo "roster-drift-check: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
fi
if [ "$#" -gt 1 ]; then
  echo "roster-drift-check: unexpected extra argument: $2" >&2; usage >&2; exit 2
fi

# --- derivation ---------------------------------------------------------------
#
# PLUGIN MODULES. The naive `git grep -l 'use Barkpark.Plugin'` that filed this
# defect over-matches THREE ways, and each one was live in this tree:
#   1. plugin.ex itself carries `use Barkpark.Plugin` inside its @moduledoc
#      example, indented — a doc, not an implementation.
#   2. registry.ex, registry/resolver_chain.ex and structure.ex mention the
#      phrase in `#` comments and @moduledoc prose.
#   3. git's `*` in a pathspec CROSSES `/`, so `api/lib/barkpark/plugins/*.ex`
#      also matched `plugins/registry/resolver_chain.ex` one level down.
# Hence: a real `use` at the start of a line (never inside prose), and a
# maxdepth-1 file list (never a crossing glob).
derive_plugins() {
  local root="$1" d="$1/api/lib/barkpark/plugins" f
  [ -d "$d" ] || return 0
  find "$d" -maxdepth 1 -type f -name '*.ex' 2>/dev/null | LC_ALL=C sort | while read -r f; do
    if grep -qE '^[[:space:]]*use Barkpark\.Plugin([,[:space:]]|$)' "$f"; then
      basename "$f" .ex
    fi
  done
}

# TASK MUTATION EVENTS. Only EMITTED event names count. The owner is the
# `@event_task_*` module attribute set — verb names like `task.get` are API
# surface, not mutation_events, and never appear as one of these attributes.
derive_events() {
  local root="$1" d="$1/api/lib"
  [ -d "$d" ] || return 0
  grep -rhoE '@event_task_[a-z_]+ "task\.[a-z_]+"' "$d" 2>/dev/null \
    | sed -E 's/.*"(task\.[a-z_]+)"/\1/' | LC_ALL=C sort -u
}

# --- what the docs claim ------------------------------------------------------
#
# Both extractors are ANCHORED on a phrase the prose owns, and both fail LOUD on
# an empty result. An extractor that silently returns nothing compares "" to ""
# and agrees with itself — the exact vacuity that lets a roster gate go dark.
#
# THE SHAPE GUARD IS LOAD-BEARING. `sed` passes a NON-matching line through
# UNCHANGED, so without the `grep -qE` shape assertion below, a reworded
# sentence does not yield an empty set — it yields the prose itself, chopped on
# commas, and the comparison reports fictional members instead of naming the
# real problem. Caught by this script's own reworded-sentence selftest arm.
documented_plugins() {
  local f="$1/CLAUDE.md" line
  [ -f "$f" ] || return 0
  line=$(grep -m1 'Plugins ride the' "$f" 2>/dev/null || true)
  printf '%s' "$line" | grep -qE 'behaviour[^(]*\([^)]+\)' || return 0
  printf '%s' "$line" \
    | sed -E 's/.*behaviour[^(]*\(([^)]*)\).*/\1/' \
    | tr ',' '\n' | tr -d ' ' | tr '[:upper:]' '[:lower:]' \
    | grep -v '^$' | LC_ALL=C sort
}

documented_events() {
  local f="$1/api/CLAUDE.md" line
  [ -f "$f" ] || return 0
  # Anchored on "Task mutations emit", NOT on "mutation_events": the latter
  # first appears in the Key files table ("`mutation_events` emit"), which
  # carries no roster at all, and -m1 would stop there.
  line=$(grep -m1 'Task mutations emit' "$f" 2>/dev/null || true)
  printf '%s' "$line" | grep -qE 'task\.\{[^}]+\}' || return 0
  printf '%s' "$line" \
    | sed -E 's/.*task\.\{([^}]*)\}.*/\1/' \
    | tr ',' '\n' | tr -d ' ' | grep -v '^$' | sed 's/^/task./' | LC_ALL=C sort
}

FAIL=0

compare_roster() {
  # $1 = human label, $2 = doc location, $3 = derived list, $4 = documented list
  local label="$2" derived="$3" documented="$4" dn cn
  dn=$(printf '%s' "$derived" | grep -c . || true)
  cn=$(printf '%s' "$documented" | grep -c . || true)

  if [ "$dn" -eq 0 ]; then
    echo "FAIL: $1 — derived ZERO entries from the code. The derivation went dark;"
    echo "      an empty derived set would agree with an empty doc and pass silently."
    FAIL=1
    return
  fi
  if [ "$cn" -eq 0 ]; then
    echo "FAIL: $1 — extracted ZERO entries from $label. The doc sentence was"
    echo "      reworded out from under this check; re-anchor the extractor."
    FAIL=1
    return
  fi
  if [ "$derived" = "$documented" ]; then
    echo "ok:   $1 — $label names all $dn, matching the code"
    return
  fi

  echo "FAIL: $1 — $label is out of sync with the code."
  printf '%s\n' "$documented" > "/tmp/rdc-doc.$$"
  printf '%s\n' "$derived"    > "/tmp/rdc-code.$$"
  comm -13 "/tmp/rdc-doc.$$" "/tmp/rdc-code.$$" | sed 's/^/      IN CODE, NOT IN THE DOC: /'
  comm -23 "/tmp/rdc-doc.$$" "/tmp/rdc-code.$$" | sed 's/^/      IN THE DOC, NOT IN CODE: /'
  rm -f "/tmp/rdc-doc.$$" "/tmp/rdc-code.$$"
  echo "      doc names $cn, code has $dn. Update $label to the derived set."
  FAIL=1
}

run_gate() {
  local root="$1"
  compare_roster "plugin roster" "CLAUDE.md" \
    "$(derive_plugins "$root")" "$(documented_plugins "$root")"
  compare_roster "task mutation_events roster" "api/CLAUDE.md" \
    "$(derive_events "$root")" "$(documented_events "$root")"
}

# --- self-test ----------------------------------------------------------------
# Every arm plants ONE violation in a throwaway tree and asserts the gate reds
# with a NAMED line. A green a blind harness would also produce is not a seal —
# so the two vacuity arms (derived-empty, documented-empty) are here too: they
# are the failure mode this whole script exists to avoid.
if [ "$MODE" = "selftest" ]; then
  ST_FAIL=0
  FIXROOT=$(mktemp -d)
  trap 'rm -rf "$FIXROOT"' EXIT

  st_fixture() {
    local r="$1"
    rm -rf "$r"
    mkdir -p "$r/api/lib/barkpark/plugins/registry" "$r/api"
    for p in alpha beta; do
      printf 'defmodule Barkpark.Plugins.%s do\n  use Barkpark.Plugin, manifest_path: "x"\nend\n' "$p" \
        > "$r/api/lib/barkpark/plugins/$p.ex"
    done
    # DECOYS the real tree contains: a moduledoc example, a comment mention, and
    # a file one level DOWN that a crossing glob would wrongly pick up.
    printf 'defmodule Barkpark.Plugin do\n  @moduledoc """\n        use Barkpark.Plugin\n  """\nend\n' \
      > "$r/api/lib/barkpark/plugin.ex"
    printf 'defmodule R do\n  # mentions `use Barkpark.Plugin` in a comment\nend\n' \
      > "$r/api/lib/barkpark/plugins/registry.ex"
    printf 'defmodule RC do\n  use Barkpark.Plugin, manifest_path: "y"\nend\n' \
      > "$r/api/lib/barkpark/plugins/registry/resolver_chain.ex"
    printf 'defmodule T do\n  @event_task_claimed "task.claimed"\n  @event_task_closed "task.closed"\nend\n' \
      > "$r/api/lib/barkpark/tasks.ex"
    printf 'Plugins ride the `Barkpark.Plugin` behaviour — 2 today (Alpha, Beta) — off, it works.\n' \
      > "$r/CLAUDE.md"
    printf 'Task mutations emit `mutation_events` rows: `task.{claimed,closed}` (tasks.ex).\n' \
      > "$r/api/CLAUDE.md"
  }

  st_case() {
    # $1 = name, $2 = expected exit, $3 = expected substring, $4 = mutation
    local name="$1" want_rc="$2" want_msg="$3" mutate="$4" out rc
    st_fixture "$FIXROOT/r"
    ( cd "$FIXROOT/r" && eval "$mutate" ) >/dev/null 2>&1 || true
    set +e
    out=$(ROSTER_ROOT="$FIXROOT/r" "$SELF" 2>&1); rc=$?
    set -e
    if [ "$rc" -ne "$want_rc" ]; then
      echo "FAIL: selftest '$name' expected exit $want_rc, got $rc"
      printf '%s\n' "$out" | sed 's/^/        /'
      ST_FAIL=1
      return
    fi
    if ! printf '%s' "$out" | grep -qF -- "$want_msg"; then
      echo "FAIL: selftest '$name' exit $rc was right but the message never said: $want_msg"
      printf '%s\n' "$out" | sed 's/^/        /'
      ST_FAIL=1
      return
    fi
    echo "ok:   selftest $name (exit $rc)"
  }

  st_case "pristine fixture passes both rosters" 0 "matching the code" ':'
  st_case "a moduledoc example is NOT counted as a plugin" 0 \
    "plugin roster — CLAUDE.md names all 2" ':'
  st_case "a new plugin module reds the plugin roster" 1 \
    "IN CODE, NOT IN THE DOC: gamma" \
    'printf "defmodule G do\n  use Barkpark.Plugin, manifest_path: \"z\"\nend\n" > api/lib/barkpark/plugins/gamma.ex'
  st_case "a plugin the doc invents but code lacks reds" 1 \
    "IN THE DOC, NOT IN CODE: delta" \
    'sed -i.bak "s/(Alpha, Beta)/(Alpha, Beta, Delta)/" CLAUDE.md'
  st_case "a new emitted event reds the events roster" 1 \
    "IN CODE, NOT IN THE DOC: task.pulse" \
    'printf "@event_task_pulse \"task.pulse\"\n" >> api/lib/barkpark/tasks.ex'
  st_case "a plugin one level DOWN is not swept in by a crossing glob" 0 \
    "plugin roster — CLAUDE.md names all 2" ':'
  st_case "an empty derivation fails LOUD, never vacuously green" 1 \
    "derived ZERO entries from the code" \
    'rm -f api/lib/barkpark/plugins/alpha.ex api/lib/barkpark/plugins/beta.ex'
  st_case "a reworded doc sentence fails LOUD, never vacuously green" 1 \
    "extracted ZERO entries from CLAUDE.md" \
    'printf "Plugins ride the behaviour, see the code.\n" > CLAUDE.md'
  # Argument handling is not a roster case, so it is asserted directly rather
  # than through st_case (which never passes arguments through).
  set +e
  bad_out=$("$SELF" --nonsense 2>&1); bad_rc=$?
  set -e
  if [ "$bad_rc" -eq 2 ] && printf '%s' "$bad_out" | grep -qF 'unknown argument'; then
    echo "ok:   selftest bad argument exits 2 (exit $bad_rc)"
  else
    echo "FAIL: selftest 'bad argument' expected exit 2 naming it, got $bad_rc: $bad_out"
    ST_FAIL=1
  fi

  echo ""
  if [ "$ST_FAIL" -ne 0 ]; then
    echo "roster-drift-check --selftest: FAILED"
    exit 1
  fi
  echo "roster-drift-check --selftest: PASS (9 arms: pristine, moduledoc decoy, added plugin, phantom plugin, added event, nested-file decoy, derived-empty vacuity, doc-empty vacuity, bad arg)"
  exit 0
fi

# The bad-arg arm above re-invokes with an unknown argument; handled at the top.
ROOT="${ROSTER_ROOT:-$(cd "$(dirname "$SELF")/.." && pwd)}"
run_gate "$ROOT"

echo ""
if [ "$FAIL" -ne 0 ]; then
  echo "roster-drift-check: FAILED — a documented roster no longer matches the code."
  exit 1
fi
echo "roster-drift-check: PASS"
