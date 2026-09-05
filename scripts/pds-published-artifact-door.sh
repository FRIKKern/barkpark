#!/usr/bin/env bash
#
# pds-published-artifact-door.sh — refuse an export subpath that the frozen
# published artifact under main's own version literal cannot serve.
#
# WHY THIS EXISTS
# ---------------
# `npm i @barkpark/react` gets the SHIPPED JavaScript of the frozen
# 1.0.0-preview.1 tarball, not main. When main adds an export subpath without
# bumping the version literal, the registry advertises a surface the published
# bytes cannot serve, and an installer gets a resolution error for a subpath the
# repository swears exists. Nothing else in this repo can refuse that.
#
# THE REQUIRED LEG — the SURFACE clause, and ONLY this one:
#
#   exports(HEAD) MUST BE A SUBSET OF exports(R)
#   where R = the commit that last CHANGED that package's version literal.
#
# R is DERIVED, never pinned: walk the package.json history from the ref and
# take the first commit whose `version` differs from its parent's. A genuine
# release bumps the literal, which moves R onto the release commit itself, so
# the door is structurally SILENT on releases rather than silent by exception.
#
# DERIVING R REQUIRES REAL HISTORY, AND A SHALLOW CLONE IS REFUSED. The walk
# compares each commit to its PARENT. On a shallow clone the walk hits the graft
# boundary, `<c>^` does not resolve, and resolve_r hands back the boundary commit
# itself — on `fetch-depth: 1` that is HEAD. R == ref makes exports(R) identical
# to exports(HEAD) by construction, every package PASSES, and the run is
# byte-plausible: a VACUOUS PASS, indistinguishable from a clean tree unless you
# read the R column and notice every row carries the same sha. That is exactly
# what elixir-nightly run 33717527961 emitted. A door that cannot derive R has
# MEASURED NOTHING, so it exits 2 (ERROR) and names the missing runner
# dependency, rather than descending to 0.
#
# WHAT THIS DOOR STRUCTURALLY CANNOT SEE
# --------------------------------------
# THE REQUIRED LEG READS THE exports MAP ONLY. A package that changes BEHAVIOUR
# under an unchanged version literal — a repaired function body, a reversed
# error contract, a deleted stub — adds no export key and PASSES this door.
# That is exactly #9601: main's repaired Reference.tsx says the opposite of the
# shipped preview.1 JavaScript, the surfaces are identical, and this leg is
# silent on it. That sentence is PRINTED on every run, because prose that lives
# only in a comment is what a copy-paste drops.
#
# THREE ESCAPE HATCHES, ALL MANDATORY:
#   * `"private": true`               — never published, nothing to contradict
#   * the literal `0.0.0-placeholder` — keyed on the LITERAL, never on registry
#                                       absence: BOTH placeholder packages ARE
#                                       published at that literal, so "not on
#                                       npm" would be the wrong test
#   * js/.changeset/config.json `ignore` — read at the REF, never hardcoded
#
# UNSCOPED PACKAGES: a package is named by its package.json `name`, never by
# building @barkpark/$dir — create-barkpark-app is unscoped and any name-builder
# that assumes the scope silently stops checking it.
#
# RELEASE DEBT IS REPORTED, NEVER REFUSED. Hundreds of changesets sit on main; a
# required leg that refused on debt would block every js PR until someone ran
# release.yml, and it would be the leg that gets weakened. It is a column, not a
# verdict.
#
# OFFLINE BY CONSTRUCTION. Every read is `git show <ref>:<path>`. No network
# command appears anywhere in this file. The sourcemap byte oracle is an
# ENHANCEMENT arm that prints SKIP-WITH-REASON and cannot move the exit code.
#
# USAGE
#   scripts/pds-published-artifact-door.sh [<ref>]   # default origin/main
#   scripts/pds-published-artifact-door.sh --selftest
#
# EXIT STATUS
#   0  every checked package advertises only what its frozen artifact can serve
#   1  at least one REFUSAL — a subpath added since R
#   2  the door itself failed (bad ref, unreadable tree) — measured nothing
#   3  bad usage
#
set -uo pipefail

SELF="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
PKG_ROOT="js/packages"
CHANGESET_CONFIG="js/.changeset/config.json"
PLACEHOLDER_LITERAL="0.0.0-placeholder"

die() { printf 'door: %s\n' "$*" >&2; exit 2; }

# Print the header comment block. The boundary is DERIVED — a hardcoded last
# line silently truncates the moment the header grows.
usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$SELF"; }

# ── readers: every one of them is `git show`, and that is the offline property ──
blob_at() { git show "$1:$2" 2>/dev/null; }

# READER FAILURES ARE NAMED, NEVER CLASSIFIED. These helpers used to swallow
# every failure into empty output (`except: sys.exit(0)`), so a python3 spawn
# hiccup or a truncated read under CI load made `private` read as not-true and
# a private package got CHECKED instead of SKIPPED (measured: the hatch-private
# selftest arm failing on a PR that could not touch it). A parse/read failure
# now exits 3 — an ABSENT field is still exit 0 with empty output — and every
# call site converts a 3 into a named ERROR row or a die, so load turns into a
# visible REFUSED-TO-MEASURE instead of a wrong verdict.
json_field() { # <json on stdin> <dotted field>
  python3 -c '
import json,sys
try: d = json.load(sys.stdin)
except Exception: sys.exit(3)
v = d.get(sys.argv[1])
if v is None: sys.exit(0)
print(v if not isinstance(v, bool) else ("true" if v else "false"))
' "$1"
}

exports_keys() { # <json on stdin> -> one key per line, sorted
  python3 -c '
import json,sys
try: d = json.load(sys.stdin)
except Exception: sys.exit(3)
e = d.get("exports")
if isinstance(e, dict):
    for k in sorted(e): print(k)
'
}

ignore_list() { # <ref>
  # An ABSENT config is a legitimately empty ignore list; an UNREADABLE one is
  # a reader failure (return 3) — an empty list born from a failed read would
  # silently un-skip every ignored package.
  git cat-file -e "$1:$CHANGESET_CONFIG" 2>/dev/null || return 0
  blob_at "$1" "$CHANGESET_CONFIG" | python3 -c '
import json,sys
try: d = json.load(sys.stdin)
except Exception: sys.exit(3)
for n in d.get("ignore", []) or []: print(n)
'
}

# R = the commit that last CHANGED this package.json version literal, at or
# before <ref>. Derived by walking the file history and comparing each commit to
# its parent. The FIRST such commit is R.
resolve_r() { # <ref> <path>
  local ref="$1" path="$2" c v p pv
  for c in $(git log --format=%H "$ref" -- "$path" 2>/dev/null); do
    # Existence-aware on purpose: a commit where the blob is ABSENT (the
    # package\'s birth parent, or a deletion commit git log also lists) reads
    # as an empty version, exactly as before. Only a blob that EXISTS and then
    # fails to parse — or a reader that fails under load — returns 3, so a
    # transient failure can never mis-pick R.
    if git cat-file -e "$c:$path" 2>/dev/null; then
      v="$(blob_at "$c" "$path" | json_field version)" || return 3
    else
      v=""
    fi
    if ! p="$(git rev-parse --verify -q "$c^" 2>/dev/null)"; then printf '%s\n' "$c"; return 0; fi
    if git cat-file -e "$p:$path" 2>/dev/null; then
      pv="$(blob_at "$p" "$path" | json_field version)" || return 3
    else
      pv=""
    fi
    [ "$v" != "$pv" ] && { printf '%s\n' "$c"; return 0; }
  done
  printf '\n'
}

# TRUE when this repository's history is truncated (a `--depth` clone, or
# actions/checkout's default fetch-depth: 1). Two independent reads: the
# porcelain question, and the graft file in the COMMON dir (a linked worktree's
# own git-dir never holds it). Either one answering yes is enough — a guard that
# needs both would go dark on the older git that lacks the porcelain form.
is_shallow_repo() {
  [ "$(git rev-parse --is-shallow-repository 2>/dev/null)" = "true" ] && return 0
  local common; common="$(git rev-parse --git-common-dir 2>/dev/null)" || return 1
  [ -n "$common" ] && [ -f "$common/shallow" ]
}

run_door() { # <ref>
  local ref="$1"
  local sha; sha="$(git rev-parse --verify -q "$ref^{commit}")" || die "not a commit: $ref"

  # A REFUSAL TO MEASURE, PRINTED BEFORE ANY VERDICT CAN FORM. See the header:
  # on truncated history R collapses onto the boundary commit and every package
  # passes for a reason that has nothing to do with the published artifact.
  if is_shallow_repo; then
    printf 'pds-published-artifact-door — REF=%s (%s)\n\n' "$ref" "${sha:0:9}"
    printf 'ERROR: shallow history — R cannot be derived; fetch-depth: 0 required\n'
    printf '  R is the commit that last CHANGED a package version literal, found by walking\n'
    printf '  git log from REF and comparing each commit to its PARENT. On a truncated\n'
    printf '  history the walk hits the graft boundary, the parent does not resolve, and R\n'
    printf '  collapses onto the boundary commit — on fetch-depth: 1 that is REF itself. Then\n'
    printf '  exports(R) == exports(HEAD) for every package and the door PASSES having\n'
    printf '  compared a tree against itself. This run measured NOTHING and says so.\n'
    printf '  FIX THE VENUE: actions/checkout with `fetch-depth: 0`, or `git fetch\n'
    printf '  --unshallow` locally, then re-run.\n'
    printf '\nCOUNTS: enumerated 0, skipped 0, checked 0, REFUSALS 0, ERRORS 1\n'
    printf 'VERDICT: ERROR\n'
    return 2
  fi

  local ignores
  ignores="$(ignore_list "$ref")" || die "reader failed on $CHANGESET_CONFIG at $ref — refusing to verdict with an ignore list born from a failed read"

  printf 'pds-published-artifact-door — REF=%s (%s)\n\n' "$ref" "${sha:0:9}"
  printf 'IGNORE LIST (%s @ REF): %s\n\n' "$CHANGESET_CONFIG" "$(printf '%s' "$ignores" | tr '\n' ' ')"

  local enumerated=0 skipped=0 checked=0 refusals=0 errors=0
  local dirs d path pjson name ver priv r new_keys line
  local -a refuse_lines=() debt_lines=()

  dirs="$(git ls-tree --name-only "$ref" "$PKG_ROOT/" 2>/dev/null | sed 's#.*/##')"
  [ -n "$dirs" ] || die "no packages enumerated under $PKG_ROOT at $ref — the enumerator is broken, not the tree empty"

  printf '%-26s %-20s %-11s %s\n' "PACKAGE" "VERSION" "R" "VERDICT"
  for d in $dirs; do
    path="$PKG_ROOT/$d/package.json"
    pjson="$(blob_at "$ref" "$path")"
    if [ -z "$pjson" ]; then
      # A dir with NO package.json is a legit non-package entry — skipped
      # silently, as always. A blob that EXISTS and read as nothing is the
      # reader failing under load, and a silent skip there un-checks a real
      # package with no trace: name it as an ERROR instead.
      if git cat-file -e "$ref:$path" 2>/dev/null; then
        errors=$((errors + 1)); printf '%-26s %-20s %-11s ERROR reader failed (blob exists, read empty)\n' "$d" "-" "-"
      fi
      continue
    fi
    enumerated=$((enumerated + 1))

    # NAMED BY ITS package.json, never by @barkpark/$dir — create-barkpark-app
    # is unscoped and a scope-builder stops checking it silently. A json_field
    # rc 3 is a parse/read failure — an ERROR row, never a classification.
    if ! name="$(printf '%s' "$pjson" | json_field name)" ||
       ! ver="$(printf '%s' "$pjson" | json_field version)" ||
       ! priv="$(printf '%s' "$pjson" | json_field private)"; then
      errors=$((errors + 1)); printf '%-26s %-20s %-11s ERROR unreadable package.json (reader failed, not a verdict)\n' "$d" "-" "-"; continue
    fi
    [ -n "$name" ] || { errors=$((errors + 1)); printf '%-26s %-20s %-11s ERROR no name field\n' "$d" "-" "-"; continue; }

    if [ "$priv" = "true" ]; then
      skipped=$((skipped + 1)); printf '%-26s %-20s %-11s SKIP private:true\n' "$name" "$ver" "-"; continue
    fi
    if [ "$ver" = "$PLACEHOLDER_LITERAL" ]; then
      skipped=$((skipped + 1)); printf '%-26s %-20s %-11s SKIP version literal is %s\n' "$name" "$ver" "-" "$PLACEHOLDER_LITERAL"; continue
    fi
    if printf '%s\n' "$ignores" | grep -qxF "$name"; then
      skipped=$((skipped + 1)); printf '%-26s %-20s %-11s SKIP .changeset ignore\n' "$name" "$ver" "-"; continue
    fi

    if ! r="$(resolve_r "$ref" "$path")"; then
      errors=$((errors + 1)); printf '%-26s %-20s %-11s ERROR reader failed while deriving R (not a verdict)\n' "$name" "$ver" "-"; continue
    fi
    if [ -z "$r" ]; then
      errors=$((errors + 1)); printf '%-26s %-20s %-11s ERROR no R (version literal never changed)\n' "$name" "$ver" "-"; continue
    fi
    checked=$((checked + 1))

    # Both key sets are read INTO variables first: a process substitution\'s
    # exit status is invisible to comm, so a parse failure there used to yield
    # an empty set and a wrong verdict in either direction.
    local head_keys r_keys
    if ! head_keys="$(printf '%s' "$pjson" | exports_keys)"; then
      errors=$((errors + 1)); printf '%-26s %-20s %-11s ERROR unreadable exports at HEAD (reader failed)\n' "$name" "$ver" "${r:0:9}"; continue
    fi
    if ! r_keys="$(blob_at "$r" "$path" | exports_keys)"; then
      errors=$((errors + 1)); printf '%-26s %-20s %-11s ERROR unreadable exports at R (reader failed)\n' "$name" "$ver" "${r:0:9}"; continue
    fi
    new_keys="$(comm -23 <(printf '%s\n' "$head_keys") <(printf '%s\n' "$r_keys"))"

    if [ -n "$new_keys" ]; then
      refusals=$((refusals + 1))
      printf '%-26s %-20s %-11s REFUSE\n' "$name" "$ver" "${r:0:9}"
      refuse_lines+=("REFUSE: $name advertises export subpath(s) the frozen $ver artifact cannot serve: $(printf '%s' "$new_keys" | tr '\n' ' ' | sed 's/ $//')")
    else
      printf '%-26s %-20s %-11s PASS\n' "$name" "$ver" "${r:0:9}"
    fi

    # REPORTED, NEVER REFUSED.
    debt_lines+=("$name $(git rev-list --count "$r..$ref" -- "$PKG_ROOT/$d" 2>/dev/null) commit(s) touch $PKG_ROOT/$d since ${r:0:9}")
  done

  printf '\n'
  for line in "${refuse_lines[@]:-}"; do [ -n "$line" ] && printf '%s\n' "$line"; done
  [ ${#refuse_lines[@]} -gt 0 ] && printf '\n'

  printf 'RELEASE DEBT (reported, never refused — a debt leg would block every js PR):\n'
  for line in "${debt_lines[@]:-}"; do [ -n "$line" ] && printf '  %s\n' "$line"; done

  printf '\nENHANCEMENT ARM — published sourcemap byte oracle: SKIP-WITH-REASON\n'
  printf '  needs the registry tarballs; this door is offline by construction and the\n'
  printf '  arm can never move the exit code. react server.cjs.map/server.mjs.map carry\n'
  printf '  no sourcesContent, so they would SKIP even with a network.\n'

  printf '\nWHAT THIS DOOR STRUCTURALLY CANNOT SEE\n'
  printf '  The required leg reads the exports MAP only. A package that changes BEHAVIOUR\n'
  printf '  under an unchanged version literal — a repaired function body, a reversed\n'
  printf '  error contract, a deleted stub — adds no export key and PASSES this door.\n'

  printf '\nCOUNTS: enumerated %d, skipped %d, checked %d, REFUSALS %d, ERRORS %d\n' \
    "$enumerated" "$skipped" "$checked" "$refusals" "$errors"

  [ "$errors" -gt 0 ] && { printf 'VERDICT: ERROR\n'; return 2; }
  [ "$refusals" -gt 0 ] && { printf 'VERDICT: REFUSE\n'; return 1; }
  printf 'VERDICT: PASS\n'; return 0
}

main() {
  case "${1:---default}" in
    -h|--help|help) usage; exit 0 ;;
    --selftest)     exec bash "$(dirname "$SELF")/pds-published-artifact-door_test.sh" ;;
    --default)      run_door "origin/main" ;;
    -*)             printf 'door: unknown option: %s\n' "$1" >&2; exit 3 ;;
    *)              run_door "$1" ;;
  esac
}

main "$@"
