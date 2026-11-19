#!/usr/bin/env bash
# toolchain-drift-check.test.sh — the drift gate must be able to fail.
#
# Plants a small git tree that passes, then breaks it one way at a time and
# asserts each break exits non-zero and names the path. Cases R01-R20 are the
# review's plants on PR #27394 (each fails through rule 1 or rule 2 of
# toolchain-drift-check.sh, not a check written for it).
#
# Run: bash scripts/toolchain-drift-check.test.sh

set -euo pipefail

CHECK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/toolchain-drift-check.sh"
TABLE_REL="scripts/toolchain-owners.tsv"
T="$(mktemp -d "${TMPDIR:-/tmp}/tdrift.XXXXXX")" || { echo "HARNESS-UNAVAILABLE: mktemp failed" >&2; exit 2; }
trap 'rm -rf "$T"' EXIT
PASS=0 FAIL=0

plant() { # plant <dir>: a clean git tree that must pass
  local d="$T/$1"
  mkdir -p "$d/.github/workflows" "$d/scripts" "$d/deploy" "$d/tools" "$d/img"
  printf 'erlang 27.3.4\nelixir 1.18.4-otp-27\nnodejs 26.5.0\n' > "$d/.tool-versions"
  printf '# images\nerlang 27.3.4.13\nelixir 1.18.4-otp-27\n' > "$d/deploy/image.tool-versions"
  printf 'erlang 27.3.4\nelixir 1.19.5-otp-27\n' > "$d/tools/format.tool-versions"
  cat > "$d/$TABLE_REL" <<'TSV'
# owners
.tool-versions  .github/workflows/ci.yml
.tool-versions  deploy/install.sh
.tool-versions  tools/format.tool-versions
deploy/image.tool-versions  img/Dockerfile
tools/format.tool-versions  .github/workflows/ci.yml#format
tools/format.tool-versions  scripts/fmt.sh
data  scripts/names.test.sh
TSV
  cat > "$d/.github/workflows/ci.yml" <<'YML'
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
  prod:
    runs-on: ubuntu-latest
    steps:
      - uses: erlef/setup-beam@v1
        with:
          version-file: .tool-versions
          version-type: strict
YML
  printf 'FROM hexpm/elixir:1.18.4-erlang-27.3.4.13-debian-bookworm-20260623-slim AS build\nFROM debian:bookworm-slim\n' > "$d/img/Dockerfile"
  printf '#!/bin/sh\nERLANG_VERSION="${ERLANG_VERSION:-27.3.4}"\nELIXIR_VERSION="${ELIXIR_VERSION:-1.18.4-otp-27}"\n' > "$d/deploy/install.sh"
  printf '#!/bin/sh\n# reads the pin\nsed -n p "$ROOT/tools/format.tool-versions"\n' > "$d/scripts/fmt.sh"
  printf '#!/bin/sh\necho "Test (Elixir 1.18.1 / OTP 27.0)"\n' > "$d/scripts/names.test.sh"
  git -C "$d" init -q
  stage "$1"
}
stage() { git -C "$T/$1" add -A; }
edit() { sed "$2" "$T/$1" > "$T/$1.new"; mv "$T/$1.new" "$T/$1"; }
add_after() { # add_after <file> <exact line> <text, \n allowed>
  awk -v k="$2" -v t="$3" '{ print } $0 == k && !d { print t; d = 1 }' "$T/$1" > "$T/$1.new"
  mv "$T/$1.new" "$T/$1"
}
expect() { # expect <label> <case dir> <exit> [text the output must carry]
  local out rc=0
  out="$(bash "$CHECK" --root "$T/$2" --check 2>&1)" || rc=$?
  if [ "$rc" -ne "$3" ]; then
    FAIL=$((FAIL + 1)); echo "FAIL - $1 -> exit $rc (want $3)"; sed 's/^/       /' <<<"$out"; return 0
  fi
  case "$out" in
    *"${4:-}"*) PASS=$((PASS + 1)); echo "ok   - $1 -> exit $3${4:+, names '$4'}" ;;
    *) FAIL=$((FAIL + 1)); echo "FAIL - $1 -> exit $3 but does not name '$4'"; sed 's/^/       /' <<<"$out" ;;
  esac
}
W=.github/workflows/ci.yml

plant c;   expect "clean tree" c 0 "erlang 27.3.4.13"

# ── the review's plants ───────────────────────────────────────────────────────
plant r01; edit r01/$W '11s/version-file: .tool-versions/otp-version: "27.0"/'; stage r01
expect "R01 literal otp-version in a setup-beam step (rule 2)" r01 1 'ci.yml:11 (job test): erlang 27.0, but .tool-versions says 27.3.4'
plant r06; mkdir -p "$T/r06/cloud"; printf 'erlang 26.2.5\nelixir 1.17.3-otp-26\n' > "$T/r06/cloud/.tool-versions"; stage r06
expect "R06 a stray version file (rule 1)" r06 1 'cloud/.tool-versions: a version file'
plant r10; add_after r10/$W '  prod:' '    env:\n      OTP_VERSION: "27.0"'; stage r10
expect "R10 an env version in an owned workflow (rule 2)" r10 1 'ci.yml:23 (job prod): erlang 27.0, but .tool-versions says 27.3.4'
plant r13; mkdir -p "$T/r13/.github/actions/beam"
printf 'runs:\n  using: composite\n  steps:\n    - uses: erlef/setup-beam@v1\n      with:\n        otp-version: "26.2"\n' > "$T/r13/.github/actions/beam/action.yml"; stage r13
expect "R13 a composite action names a version (rule 2)" r13 1 '.github/actions/beam/action.yml:6: a literal erlang version (26.2)'
plant r15; add_after r15/$W '  prod:' '    steps:\n      - run: asdf install erlang 26.2.5'; stage r15
expect "R15 asdf install in an owned workflow (rule 2)" r15 1 'ci.yml:23 (job prod): erlang 26.2.5, but .tool-versions says 27.3.4'
plant r16; add_after r16/$W '  prod:' '    container: hexpm/elixir:1.17.3-erlang-26.2.5-debian-bookworm-20240612-slim'; stage r16
expect "R16 a container image in an owned workflow (rule 2)" r16 1 'ci.yml:22 (job prod): elixir 1.17.3, but .tool-versions says 1.18.4-otp-27'
plant r17; printf 'asdf install erlang 26.2.5\n' >> "$T/r17/deploy/install.sh"; stage r17
expect "R17 asdf install in an owned deploy script (rule 2)" r17 1 'deploy/install.sh:4: erlang 26.2.5, but .tool-versions says 27.3.4'
plant r18; printf '#!/bin/sh\nelixir --version | grep -q "Elixir 1.18.1" || exit 2\n' > "$T/r18/scripts/vcheck.sh"; stage r18
expect "R18 a script asserts a version (rule 2)" r18 1 'scripts/vcheck.sh:2: a literal elixir version (1.18.1)'
plant r19; edit r19/$W '9s/uses: erlef\/setup-beam@v1/uses: "erlef\/setup-beam@v1"/;11s/version-file: .tool-versions/version-file: tools\/format.tool-versions/'; stage r19
expect "R19 a quoted uses reads the wrong file (rule 2)" r19 1 'ci.yml:9 (job test): reads tools/format.tool-versions, but'
plant r20; add_after r20/$W '  prod:' '    strategy:\n      matrix:\n        otp:\n          - "27.0"'; stage r20
expect "R20 a block-list matrix axis (rule 2)" r20 1 'ci.yml:25 (job prod): erlang 27.0, but .tool-versions says 27.3.4'

# ── one break of each other kind ─────────────────────────────────────────────
plant d;   edit d/img/Dockerfile 's/27\.3\.4\.13-debian/27.3.4.12-debian/'; stage d
expect "a Dockerfile FROM drifts from its owner" d 1 'img/Dockerfile:1: erlang 27.3.4.12, but deploy/image.tool-versions says 27.3.4.13'
plant e;   printf 'jobs:\n  x:\n    steps:\n      - uses: erlef/setup-beam@v1\n        with:\n          version-file: .tool-versions\n          version-type: strict\n' > "$T/e/.github/workflows/new.yml"; stage e
expect "a setup-beam step in a workflow with no row" e 1 'new.yml:4 (job x): a setup-beam step with no version-file row'
plant f;   printf '.tool-versions  .github/workflows/gone.yml\n' >> "$T/f/$TABLE_REL"; printf 'jobs:\n  x:\n    steps:\n      - run: true\n' > "$T/f/.github/workflows/gone.yml"; stage f
expect "a row that feeds no step" f 1 'row `.tool-versions .github/workflows/gone.yml` feeds no setup-beam step'
plant g;   printf '.tool-versions  .github/workflows/ghost.yml\n' >> "$T/g/$TABLE_REL"; stage g
expect "a row naming a missing file" g 1 '.github/workflows/ghost.yml does not exist'
plant i;   edit i/deploy/install.sh 's/27\.3\.4}/27.3.3}/'; stage i
expect "a script default drifts" i 1 'deploy/install.sh:2: erlang 27.3.3, but .tool-versions says 27.3.4'
plant j;   edit j/$W '/version-type: strict/d'; stage j
expect "version-type strict missing" j 1 'ci.yml:9 (job test): `version-type: strict` is missing'
plant k;   edit k/tools/format.tool-versions 's/^erlang 27.3.4$/erlang 27.3.3/'; stage k
expect "a consumer version file's erlang drifts" k 1 'tools/format.tool-versions: erlang 27.3.3, but .tool-versions says 27.3.4'
plant l;   printf 'FROM elixir:1.17-alpine\n' > "$T/l/Dockerfile"; stage l
expect "an unowned Dockerfile builds FROM elixir" l 1 'Dockerfile:1: a literal elixir version (1.17)'
plant m;   printf 'jobs:\n  x:\n    steps:\n      - uses: erlef/setup-beam@v1\n        with:\n          version-file: barkpark/.tool-versions\n          version-type: strict\n' > "$T/m/.github/workflows/sub.yml"
printf '.tool-versions  .github/workflows/sub.yml\n' >> "$T/m/$TABLE_REL"; stage m
expect "a checkout in a subdirectory reads <dir>/<file>" m 0
plant p;   printf 'jobs:\n  x:\n    steps:\n      - uses: actions/cache@v4\n        with:\n          key: deps-otp27.0-ex1.18.1-x\n' > "$T/p/.github/workflows/k.yml"; stage p
expect "a cache key spells the versions" p 1 'k.yml:6 (job x): a literal erlang version (27.0)'
plant q;   printf 'asdf install erlang 26.2.5\n' >> "$T/q/scripts/names.test.sh"; stage q
expect "an install in a data file" q 1 'scripts/names.test.sh:3: installs or selects erlang 26.2.5'
plant s;   awk 'BEGIN { for (i = 1; i <= 4000; i++) print "asdf install erlang 26.2." i }' > "$T/s/scripts/big.sh"; stage s
expect "4000 findings (output far past a pipe buffer) still fail" s 1 'scripts/big.sh:4000:'
plant n;   rm -f "$T/n/deploy/image.tool-versions"; stage n
expect "a missing version file refuses" n 2 "REFUSAL"
plant o;   rm -f "$T/o/$TABLE_REL"; stage o
expect "a missing table refuses" o 2 "REFUSAL"
mkdir -p "$T/nogit/scripts"; printf '.tool-versions  x\n' > "$T/nogit/$TABLE_REL"
expect "a tree that is not a git work tree refuses" nogit 2 "not a git work tree"

echo
echo "selftest: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
