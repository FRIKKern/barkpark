#!/usr/bin/env bash
# toolchain-drift-check.sh — an Erlang or Elixir number lives in a version file,
# and nowhere else.
#
# CI must run the runtime production runs. Three asdf-format files hold the
# numbers, and scripts/toolchain-owners.tsv says which file feeds which
# consumer:
#
#   .tool-versions               the content server (asdf on the box reads it)
#   deploy/image.tool-versions   the release images (cloud/ and api/ Dockerfile)
#   tools/format.tool-versions   the formatter the format gate measures
#
# RULES, all read off that one table:
#   A  every erlef/setup-beam step reads its owner's file: `version-file:` plus
#      `version-type: strict`, no `otp-version:`/`elixir-version:`. A step with
#      no owner row reds, and so does a workflow row that feeds no step.
#   B  a Dockerfile row's `FROM hexpm/elixir:<elixir>-erlang-<otp>-…` tag spells
#      its owner's numbers. Docker cannot read the file, so this is the one
#      place a copy is allowed, and only because it is checked. Any other
#      Dockerfile that builds FROM an elixir/erlang image reds.
#   C  a script row reads its owner by path, or its ERLANG_VERSION /
#      ELIXIR_VERSION defaults equal the owner's lines.
#   D  a .tool-versions row's erlang line equals its owner's.
#   E  no workflow, script or Dockerfile pins a version itself: no
#      `otp-version:`/`elixir-version:` key, no `otp:`/`elixir:`/`erlang:`
#      matrix, no `27.0-1.18.1`-shaped cache key (hash the file instead), no `elixir:<n>`/`erlang:<n>` image outside a row, no
#      `asdf|mise install erlang|elixir <n>`, no `*_VERSION=<n>` default
#      outside a row. Comment lines are prose and are not read.
#
# EXIT CODES: 0 clean · 1 drift (each finding printed with file:line) ·
# 2 refused (a version file or the table is unreadable; never a pass).
#
# bash 3.2 compatible; no YAML library, no network.
#
# Usage: toolchain-drift-check.sh [--root DIR] [--check | --selftest]

set -uo pipefail

SELF="${BASH_SOURCE[0]}"
ROOT="$(cd "$(dirname "$SELF")/.." && pwd)"
MODE=--check
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root) ROOT="${2:?--root needs a directory}"; shift 2 ;;
    --check|--selftest) MODE="$1"; shift ;;
    *) echo "usage: $(basename "$SELF") [--root DIR] [--check|--selftest]" >&2; exit 2 ;;
  esac
done
TABLE_REL="scripts/toolchain-owners.tsv"
SELF_REL="scripts/toolchain-drift-check.sh"

refuse() { echo "REFUSAL: $*" >&2; exit 2; }
drift() { echo "DRIFT  $*"; }

# tv_get <file> <tool> -> the version on the `<tool> <version>` line
tv_get() {
  sed -n "s/^[[:space:]]*$2[[:space:]][[:space:]]*\([^[:space:]#][^[:space:]#]*\).*$/\1/p" "$1" | head -1
}

# Non-comment lines of a file that match an ERE, as `line:text`.
pin_lines() { grep -n -E "$2" "$1" 2>/dev/null | grep -v -E '^[0-9]+:[[:space:]]*#'; }

# Repo files matching shell globs: git's index on a work tree, find elsewhere.
list_files() {
  if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$ROOT" ls-files -- "$@"
  else
    (cd "$ROOT" && for g in "$@"; do
      find . -path "./${g%%/*}*" -type f 2>/dev/null | sed 's|^\./||' | while IFS= read -r p; do
        case "$p" in $g) printf '%s\n' "$p" ;; esac
      done
    done) | sort -u
  fi
}

# The setup-beam steps of one workflow, one `|`-separated row each (not tabs:
# `read` collapses runs of tab, so an empty field would shift the rest):
#   line  job  version-file  version-type  literal-keys  line-of-first-literal
setup_beam_steps() {
  awk '
    function ind(s) { match(s, /^ */); return RLENGTH }
    function val(s) { sub(/^[^:]*:[[:space:]]*/, "", s); sub(/[[:space:]]+#.*$/, "", s)
                      gsub(/["\047]/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    function emit() { printf "%d|%s|%s|%s|%s|%d\n", start, job, vf, vt, lit, litline; instep = 0 }
    /^jobs:[[:space:]]*$/ { injobs = 1 }
    /^[A-Za-z]/ && !/^jobs:/ { injobs = 0 }
    injobs && /^  [A-Za-z0-9_-]+:[[:space:]]*(#.*)?$/ { if (instep) emit(); job = $0; sub(/^  /, "", job); sub(/:.*/, "", job) }
    instep && !/^[[:space:]]*(#.*)?$/ {
      if (ind($0) < k) emit()
      else {
        l = $0; sub(/^[[:space:]]+/, "", l)
        if (l ~ /^version-file:/) vf = val(l)
        else if (l ~ /^version-type:/) vt = val(l)
        else if (l ~ /^(otp|elixir)-version:/) { key = l; sub(/:.*/, "", key); if (lit == "") litline = NR; lit = lit (lit == "" ? "" : ",") key }
      }
    }
    !instep && /uses:[[:space:]]*erlef\/setup-beam@/ { instep = 1; start = NR; k = index($0, "uses:") - 1; vf = ""; vt = ""; lit = ""; litline = 0 }
    END { if (instep) emit() }
  ' "$1"
}

run_check() {
  local table="$ROOT/$TABLE_REL" owner consumer path job rows="" n=0
  [ -f "$table" ] || refuse "no owner table at $TABLE_REL"
  rows="$(grep -v -E '^[[:space:]]*(#|$)' "$table" | awk 'NF { print $1 "\t" $2 }')"
  [ -n "$rows" ] || refuse "$TABLE_REL has no rows"

  # Every owner must be a readable version file with both lines.
  echo "VERSION FILES"
  for owner in $(printf '%s\n' "$rows" | cut -f1 | sort -u); do
    [ -f "$ROOT/$owner" ] || refuse "$owner is named by $TABLE_REL but does not exist"
    [ -n "$(tv_get "$ROOT/$owner" erlang)" ] || refuse "$owner has no \`erlang <version>\` line"
    [ -n "$(tv_get "$ROOT/$owner" elixir)" ] || refuse "$owner has no \`elixir <version>\` line"
    printf '  %-28s erlang %-12s elixir %s\n' "$owner" "$(tv_get "$ROOT/$owner" erlang)" "$(tv_get "$ROOT/$owner" elixir)"
  done
  echo

  owner_of() { # owner_of <workflow> <job> -> the job row, else the workflow row
    local o
    o="$(printf '%s\n' "$rows" | awk -F'\t' -v c="$1#$2" '$2 == c { print $1; exit }')"
    [ -n "$o" ] || o="$(printf '%s\n' "$rows" | awk -F'\t' -v c="$1" '$2 == c { print $1; exit }')"
    printf '%s' "$o"
  }

  # ── A: setup-beam steps ────────────────────────────────────────────────────
  local wf line vf vt lit litline want fed="" steps=0
  for wf in $(list_files '.github/workflows/*.yml' '.github/workflows/*.yaml'); do
    [ -f "$ROOT/$wf" ] || continue
    while IFS='|' read -r line job vf vt lit litline; do
      [ -n "$line" ] || continue
      steps=$((steps + 1))
      want="$(owner_of "$wf" "$job")"
      if [ -z "$want" ]; then
        drift "$wf:$line (job $job): a setup-beam step with no row in $TABLE_REL. Add the row naming the version file it must read."
        continue
      fi
      if printf '%s\n' "$rows" | awk -F'\t' -v c="$wf#$job" '$2 == c { f = 1 } END { exit !f }'; then
        fed="$fed$wf#$job
"
      else
        fed="$fed$wf
"
      fi
      [ -z "$lit" ] || drift "$wf:$litline (job $job): names a version itself ($lit). Use \`version-file: $want\` and \`version-type: strict\`."
      [ "$vt" = strict ] || drift "$wf:$line (job $job): \`version-type: strict\` is missing; setup-beam refuses a version file without it."
      case "$vf" in
        "$want"|*/"$want") : ;;
        "") drift "$wf:$line (job $job): no \`version-file:\`; it must read $want." ;;
        *) drift "$wf:$line (job $job): reads $vf, but $TABLE_REL says $want." ;;
      esac
    done <<EOF
$(setup_beam_steps "$ROOT/$wf")
EOF
  done

  # ── B, C, D: one pass over the rows ───────────────────────────────────────
  local tag want_ex want_otp got
  while IFS="$(printf '\t')" read -r owner consumer; do
    n=$((n + 1))
    path="${consumer%%#*}"
    if [ ! -f "$ROOT/$path" ]; then
      drift "$TABLE_REL: row \`$owner $consumer\`: $path does not exist. Delete the row."
      continue
    fi
    case "$path" in
      .github/workflows/*)
        printf '%s' "$fed" | grep -q -x -F "$consumer" \
          || drift "$TABLE_REL: row \`$owner $consumer\` feeds no setup-beam step. Delete the row." ;;
      Dockerfile|*/Dockerfile)
        tag="$(sed -n 's/^[[:space:]]*FROM[[:space:]][[:space:]]*hexpm\/elixir:\([^[:space:]]*\).*$/\1/p' "$ROOT/$path" | head -1)"
        want_ex="$(tv_get "$ROOT/$owner" elixir)"; want_ex="${want_ex%%-otp-*}"
        want_otp="$(tv_get "$ROOT/$owner" erlang)"
        case "$tag" in
          "") drift "$path: no \`FROM hexpm/elixir:<tag>\` line, so it cannot spell $owner." ;;
          "$want_ex-erlang-$want_otp-"*) : ;;
          *) drift "$path:$(grep -n -m1 'FROM[[:space:]].*hexpm/elixir:' "$ROOT/$path" | cut -d: -f1): FROM hexpm/elixir:$tag, but $owner says elixir $want_ex, erlang $want_otp." ;;
        esac ;;
      *.sh)
        if grep -q -E '(ERLANG|ELIXIR)_VERSION:-' "$ROOT/$path"; then
          for t in erlang elixir; do
            want="$(tv_get "$ROOT/$owner" $t)"
            got="$(sed -n "s/^[[:space:]]*$(echo $t | tr a-z A-Z)_VERSION=\"\${$(echo $t | tr a-z A-Z)_VERSION:-\([^}]*\)}\".*/\1/p" "$ROOT/$path" | head -1)"
            [ "$got" = "$want" ] || drift "$path: default $t is '${got:-unreadable}', but $owner says $want."
          done
        else
          grep -q -F "$owner" "$ROOT/$path" || drift "$path: neither reads $owner by path nor carries defaults equal to it."
        fi ;;
      *.tool-versions)
        want="$(tv_get "$ROOT/$owner" erlang)"; got="$(tv_get "$ROOT/$path" erlang)"
        [ "$got" = "$want" ] || drift "$path: erlang $got, but $owner says $want." ;;
      *) drift "$TABLE_REL: row \`$owner $consumer\`: no rule knows a consumer of this kind." ;;
    esac
  done <<EOF
$rows
EOF

  # ── E: nothing else pins a version ────────────────────────────────────────
  local f hit owned
  owned="$(printf '%s\n' "$rows" | cut -f2 | sed 's/#.*//' | sort -u)"
  for f in $(list_files '.github/workflows/*.yml' '.github/workflows/*.yaml'); do
    pin_lines "$ROOT/$f" '(otp|elixir)-version:|^[[:space:]]*(otp|elixir|erlang):[[:space:]]*\[|(otp|-)2[0-9]\.[0-9][0-9.]*-(ex)?1\.[0-9]+\.[0-9]' | while IFS= read -r hit; do
      drift "$f:${hit%%:*}: names a version: ${hit#*:}"
    done
  done
  for f in $(list_files 'scripts/*.sh' 'deploy/*.sh' '*.sh' 'Makefile' '*Dockerfile*' '.github/workflows/*.yml'); do
    [ "$f" = "$SELF_REL" ] || [ ! -f "$ROOT/$f" ] && continue
    printf '%s\n' "$owned" | grep -q -x -F "$f" && continue
    pin_lines "$ROOT/$f" '(hexpm/)?(elixir|erlang):[0-9]|(asdf|mise) install (erlang|elixir)[ @]+[0-9]|(ERLANG|ELIXIR|OTP)_VERSION(=|:-)"?[0-9]' | while IFS= read -r hit; do
      drift "$f:${hit%%:*}: pins a version outside $TABLE_REL: ${hit#*:}"
    done
  done

  # Findings are counted by main_check from the DRIFT lines: the loops above
  # run in pipeline subshells and cannot carry a counter out.
  return 0
}

main_check() {
  local out rc
  out="$(run_check)"; rc=$?
  [ "$rc" -eq 2 ] && exit 2
  printf '%s\n' "$out"
  if printf '%s\n' "$out" | grep -q '^DRIFT '; then
    echo
    echo "FAIL - $(printf '%s\n' "$out" | grep -c '^DRIFT ') finding(s). Every Erlang/Elixir number belongs in a version file named by $TABLE_REL."
    exit 1
  fi
  echo "ok   - every setup-beam step, Dockerfile and script reads its version file; nothing else pins a version."
  exit 0
}

# ── selftest: a planted tree, one defect at a time ─────────────────────────
TDRIFT_TMP=""
selftest() {
  local pass=0 fail=0 out rc
  TDRIFT_TMP="$(mktemp -d "${TMPDIR:-/tmp}/tdrift.XXXXXX")" || { echo "HARNESS-UNAVAILABLE: mktemp failed" >&2; exit 2; }
  trap 'rm -rf "$TDRIFT_TMP"' EXIT

  plant() { # plant <dir>: a clean tree that must pass
    local d="$1"
    mkdir -p "$d/.github/workflows" "$d/scripts" "$d/deploy" "$d/tools" "$d/img"
    printf 'erlang 27.3.4\nelixir 1.18.4-otp-27\nnodejs 26.5.0\n' > "$d/.tool-versions"
    printf '# images\nerlang 27.3.4.13\nelixir 1.18.4-otp-27\n' > "$d/deploy/image.tool-versions"
    printf 'erlang 27.3.4\nelixir 1.19.5-otp-27\n' > "$d/tools/format.tool-versions"
    cat > "$d/$TABLE_REL" <<'T'
# owners
.tool-versions  .github/workflows/ci.yml
.tool-versions  deploy/install.sh
.tool-versions  tools/format.tool-versions
deploy/image.tool-versions  img/Dockerfile
tools/format.tool-versions  .github/workflows/ci.yml#format
tools/format.tool-versions  scripts/fmt.sh
T
    cat > "$d/.github/workflows/ci.yml" <<'W'
name: ci
on: push
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      # otp-version: "27.0" in a comment is prose
      - name: Setup BEAM
        uses: erlef/setup-beam@v1
        with:
          version-file: .tool-versions
          version-type: strict
      - run: mix test
  format:
    runs-on: ubuntu-latest
    steps:
      - uses: erlef/setup-beam@v1
        with:
          version-file: "tools/format.tool-versions"
          version-type: strict
W
    printf 'FROM hexpm/elixir:1.18.4-erlang-27.3.4.13-debian-bookworm-20260623-slim AS build\nFROM debian:bookworm-slim\n' > "$d/img/Dockerfile"
    printf '#!/bin/sh\nERLANG_VERSION="${ERLANG_VERSION:-27.3.4}"\nELIXIR_VERSION="${ELIXIR_VERSION:-1.18.4-otp-27}"\n' > "$d/deploy/install.sh"
    printf '#!/bin/sh\n# reads the pin\nsed -n p "$ROOT/tools/format.tool-versions"\n' > "$d/scripts/fmt.sh"
  }
  probe() { bash "$SELF" --root "$1" --check 2>&1; }
  ok()  { pass=$((pass + 1)); echo "ok   - $*"; }
  bad() { fail=$((fail + 1)); echo "FAIL - $*"; }
  expect() { # expect <label> <dir> <rc> [text the output must carry]
    out="$(probe "$2")"; rc=$?
    if [ "$rc" -ne "$3" ]; then bad "$1 -> exit $rc (want $3)"; printf '%s\n' "$out" | sed 's/^/       /'; return; fi
    if [ -n "${4:-}" ]; then
      case "$out" in *"$4"*) ok "$1 -> exit $3, names '$4'" ;; *) bad "$1 -> exit $3 but does not name '$4'" ;; esac
    else ok "$1 -> exit $3"; fi
  }
  sedi() { sed "$1" "$2" > "$2.new" && mv "$2.new" "$2"; }
  local t="$TDRIFT_TMP"

  plant "$t/a";  expect "A clean tree" "$t/a" 0 "erlang 27.3.4.13"

  plant "$t/b";  sedi 's/          version-file: .tool-versions/          otp-version: "27.0"/' "$t/b/.github/workflows/ci.yml"
  expect "B planted otp-version: \"27.0\" in a setup-beam step" "$t/b" 1 'ci.yml:11 (job test): names a version itself (otp-version)'

  plant "$t/c";  sedi 's|version-file: "tools/format.tool-versions"|version-file: .tool-versions|' "$t/c/.github/workflows/ci.yml"
  expect "C the format job reads the wrong file" "$t/c" 1 "reads .tool-versions, but $TABLE_REL says tools/format.tool-versions"

  plant "$t/d";  sedi 's/27\.3\.4\.13-debian/27.3.4.12-debian/' "$t/d/img/Dockerfile"
  expect "D Dockerfile FROM drifts from its version file" "$t/d" 1 "but deploy/image.tool-versions says elixir 1.18.4, erlang 27.3.4.13"

  plant "$t/e";  printf 'jobs:\n  x:\n    steps:\n      - uses: erlef/setup-beam@v1\n        with:\n          version-file: .tool-versions\n          version-type: strict\n' > "$t/e/.github/workflows/new.yml"
  expect "E a setup-beam step in a workflow with no row" "$t/e" 1 "new.yml:4 (job x): a setup-beam step with no row"

  plant "$t/f";  printf '.tool-versions  .github/workflows/gone.yml\n' >> "$t/f/$TABLE_REL"; printf 'jobs:\n  x:\n    steps:\n      - run: true\n' > "$t/f/.github/workflows/gone.yml"
  expect "F a row that feeds no step" "$t/f" 1 "feeds no setup-beam step"

  plant "$t/g";  printf 'jobs:\n  x:\n    strategy:\n      matrix:\n        otp: ["27.0"]\n' > "$t/g/.github/workflows/m.yml"
  expect "G a version matrix outside any setup-beam step" "$t/g" 1 'm.yml:5: names a version'

  plant "$t/h";  printf '#!/bin/sh\nasdf install erlang 26.2.5\n' > "$t/h/scripts/boot.sh"
  expect "H a script installs a version itself" "$t/h" 1 "scripts/boot.sh:2: pins a version"

  plant "$t/i";  sedi 's/27\.3\.4}/27.3.3}/' "$t/i/deploy/install.sh"
  expect "I a script default drifts" "$t/i" 1 "default erlang is '27.3.3', but .tool-versions says 27.3.4"

  plant "$t/j";  sedi '/version-type: strict/d' "$t/j/.github/workflows/ci.yml"
  expect "J version-type strict missing" "$t/j" 1 "version-type: strict"

  plant "$t/k";  sedi 's/^erlang 27.3.4$/erlang 27.3.3/' "$t/k/tools/format.tool-versions"
  expect "K the formatter file's erlang drifts" "$t/k" 1 "tools/format.tool-versions: erlang 27.3.3"

  plant "$t/l";  printf 'FROM elixir:1.17-alpine\n' > "$t/l/Dockerfile"
  expect "L an unowned Dockerfile builds FROM elixir" "$t/l" 1 "Dockerfile:1: pins a version"

  plant "$t/m";  printf 'jobs:\n  x:\n    steps:\n      - uses: erlef/setup-beam@v1\n        with:\n          version-file: barkpark/.tool-versions\n          version-type: strict\n' > "$t/m/.github/workflows/sub.yml"
  printf '.tool-versions  .github/workflows/sub.yml\n' >> "$t/m/$TABLE_REL"
  expect "M a checkout in a subdirectory reads <dir>/<file>" "$t/m" 0

  plant "$t/p";  printf 'jobs:\n  x:\n    steps:\n      - uses: actions/cache@v4\n        with:\n          key: deps-otp27.0-ex1.18.1-x\n' > "$t/p/.github/workflows/k.yml"
  expect "P a cache key spells the versions" "$t/p" 1 'k.yml:6: names a version'

  plant "$t/n";  rm -f "$t/n/deploy/image.tool-versions"
  expect "N a missing version file refuses" "$t/n" 2 "REFUSAL"

  plant "$t/o";  rm -f "$t/o/$TABLE_REL"
  expect "O a missing table refuses" "$t/o" 2 "REFUSAL"

  echo
  echo "selftest: ${pass} passed, ${fail} failed"
  [ "$fail" -eq 0 ]
}

case "$MODE" in
  --selftest) selftest ;;
  --check)    main_check ;;
esac
