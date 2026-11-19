#!/usr/bin/env bash
# toolchain-drift-check.test.sh — the drift gate must be able to fail.
#
# Plants a small git tree that passes, then breaks it one way at a time and
# asserts each break exits non-zero and names the path. Every case the check
# has ever caught on PR #27394 is a plant here, so a rebuild cannot lose one
# silently: P01-P21 (R01-R20 are the same numbers), V1-V9 and E1-E6. Each
# fails through rule 1 or rule 2 of toolchain-drift-check.sh, not a check
# written for it. N1-N6 are what the check does NOT see, kept green on purpose
# so a change in that shows here: the wall that holds is task-1c24786728762c92,
# which asserts what runs.
#
# Run: bash scripts/toolchain-drift-check.test.sh

# A POSIX-mode shell would mis-parse this script; refuse before anything runs.
# Enforced by scripts/posix-vacuous-green-census.sh.
if [ -z "${BASH_VERSION:-}" ]; then
  echo "toolchain-drift-check.test.sh: needs bash (it uses here-strings and the check it drives); run: bash scripts/toolchain-drift-check.test.sh" >&2
  exit 2
fi
case ":${SHELLOPTS:-}:" in
  *:posix:*)
    echo "toolchain-drift-check.test.sh: bash is in POSIX mode (invoked as \`sh\`?), which cannot parse it; run: bash scripts/toolchain-drift-check.test.sh" >&2
    exit 2
    ;;
esac

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
data  scripts/names.test.sh  past check names
pin  tools/format.tool-versions  1.19.5  the formatter's Elixir
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
  printf '#!/bin/sh\n# reads the pin\nsed -n p "$ROOT/tools/format.tool-versions"\nnode -e "fetch(\\"http://127.0.0.1:4000\\")"\ncommand -v node 2>/dev/null\n' > "$d/scripts/fmt.sh"
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
expect "R01/P01 literal otp-version in a setup-beam step (rule 2)" r01 1 'ci.yml:11 (job test): 27.0 on a line naming erlang, but .tool-versions says erlang 27.3.4'
plant r06; mkdir -p "$T/r06/cloud"; printf 'erlang 26.2.5\nelixir 1.17.3-otp-26\n' > "$T/r06/cloud/.tool-versions"; stage r06
expect "R06/P06 a stray version file (rule 1)" r06 1 'cloud/.tool-versions: a version file'
plant r10; add_after r10/$W '  prod:' '    env:\n      OTP_VERSION: "27.0"'; stage r10
expect "R10/P10 an env version in an owned workflow (rule 2)" r10 1 'ci.yml:23 (job prod): 27.0 on a line naming erlang, but .tool-versions says erlang 27.3.4'
plant r13; mkdir -p "$T/r13/.github/actions/beam"
printf 'runs:\n  using: composite\n  steps:\n    - uses: erlef/setup-beam@v1\n      with:\n        otp-version: "26.2"\n' > "$T/r13/.github/actions/beam/action.yml"; stage r13
expect "R13/P13 a composite action names a version (rule 2)" r13 1 '.github/actions/beam/action.yml:6: 26.2 on a line naming erlang, and no row ties'
plant r15; add_after r15/$W '  prod:' '    steps:\n      - run: asdf install erlang 26.2.5'; stage r15
expect "R15/P15 asdf install in an owned workflow (rule 2)" r15 1 'ci.yml:23 (job prod): 26.2.5 on a line naming erlang, but .tool-versions says erlang 27.3.4'
plant r16; add_after r16/$W '  prod:' '    container: hexpm/elixir:1.17.3-erlang-26.2.5-debian-bookworm-20240612-slim'; stage r16
expect "R16/P16 a container image in an owned workflow (rule 2)" r16 1 'ci.yml:22 (job prod): 1.17.3 on a line naming'
plant r17; printf 'asdf install erlang 26.2.5\n' >> "$T/r17/deploy/install.sh"; stage r17
expect "R17/P17 asdf install in an owned deploy script (rule 2)" r17 1 'deploy/install.sh:4: 26.2.5 on a line naming erlang, but .tool-versions says erlang 27.3.4'
plant r18; printf '#!/bin/sh\nelixir --version | grep -q "Elixir 1.18.1" || exit 2\n' > "$T/r18/scripts/vcheck.sh"; stage r18
expect "R18/P18 a script asserts a version (rule 2)" r18 1 'scripts/vcheck.sh:2: 1.18.1 on a line naming elixir, and no row ties'
plant r19; edit r19/$W '9s/uses: erlef\/setup-beam@v1/uses: "erlef\/setup-beam@v1"/;11s/version-file: .tool-versions/version-file: tools\/format.tool-versions/'; stage r19
expect "R19/P19 a quoted uses reads the wrong file (rule 2)" r19 1 'ci.yml:9 (job test): reads tools/format.tool-versions, but'
plant r20; add_after r20/$W '  prod:' '    strategy:\n      matrix:\n        otp:\n          - "27.0"'; stage r20
expect "R20/P20 a block-list matrix axis (rule 2)" r20 1 'ci.yml:25 (job prod): 27.0 on a line naming erlang, but .tool-versions says erlang 27.3.4'

# ── one break of each other kind ─────────────────────────────────────────────
plant d;   edit d/img/Dockerfile 's/27\.3\.4\.13-debian/27.3.4.12-debian/'; stage d
expect "P04/L2 a Dockerfile FROM drifts from its owner" d 1 'img/Dockerfile:1: 27.3.4.12 on a line naming'
plant e;   printf 'jobs:\n  x:\n    steps:\n      - uses: erlef/setup-beam@v1\n        with:\n          version-file: .tool-versions\n          version-type: strict\n' > "$T/e/.github/workflows/new.yml"; stage e
expect "P09/L5 a setup-beam step in a workflow with no row" e 1 'new.yml:4 (job x): a setup-beam step with no version-file row'
plant f;   printf '.tool-versions  .github/workflows/gone.yml\n' >> "$T/f/$TABLE_REL"; printf 'jobs:\n  x:\n    steps:\n      - run: true\n' > "$T/f/.github/workflows/gone.yml"; stage f
expect "a row that feeds no step" f 1 'row `.tool-versions .github/workflows/gone.yml` feeds no setup-beam step'
plant g;   printf '.tool-versions  .github/workflows/ghost.yml\n' >> "$T/g/$TABLE_REL"; stage g
expect "P08 a row naming a missing file" g 1 '.github/workflows/ghost.yml does not exist'
plant i;   edit i/deploy/install.sh 's/27\.3\.4}/27.3.3}/'; stage i
expect "a script default drifts" i 1 'deploy/install.sh:2: 27.3.3 on a line naming erlang, but .tool-versions says erlang 27.3.4'
plant j;   edit j/$W '/version-type: strict/d'; stage j
expect "version-type strict missing" j 1 'ci.yml:9 (job test): `version-type: strict` is missing'
plant k;   edit k/tools/format.tool-versions 's/^erlang 27.3.4$/erlang 27.3.3/'; stage k
expect "a consumer version file's erlang drifts" k 1 'tools/format.tool-versions: erlang 27.3.3, but .tool-versions says 27.3.4'
plant ke;  edit ke/$TABLE_REL '/^pin  tools\/format.tool-versions/d'; stage ke
expect "a consumer version file's elixir differs with no pin row" ke 1 'tools/format.tool-versions: elixir 1.19.5-otp-27, but .tool-versions says 1.18.4-otp-27'
plant kp;  edit kp/tools/format.tool-versions 's/^elixir 1.19.5-otp-27$/elixir 1.19.6-otp-27/'; stage kp
expect "a consumer's elixir moves off its pin" kp 1 'tools/format.tool-versions: elixir 1.19.6-otp-27, but .tool-versions says 1.18.4-otp-27'
plant l;   printf 'FROM elixir:1.17-alpine\n' > "$T/l/Dockerfile"; stage l
expect "an unowned Dockerfile builds FROM elixir" l 1 'Dockerfile:1: 1.17 on a line naming elixir, and no row ties'
plant m;   printf 'jobs:\n  x:\n    steps:\n      - uses: erlef/setup-beam@v1\n        with:\n          version-file: barkpark/.tool-versions\n          version-type: strict\n' > "$T/m/.github/workflows/sub.yml"
printf '.tool-versions  .github/workflows/sub.yml\n' >> "$T/m/$TABLE_REL"; stage m
expect "a checkout in a subdirectory reads <dir>/<file>" m 0
plant p;   printf 'jobs:\n  x:\n    steps:\n      - uses: actions/cache@v4\n        with:\n          key: deps-otp27.0-ex1.18.1-x\n' > "$T/p/.github/workflows/k.yml"; stage p
expect "a cache key spells the versions" p 1 'k.yml:6 (job x): 27.0 on a line naming erlang, and no row ties'
plant q;   printf 'asdf install erlang 26.2.5\n' >> "$T/q/scripts/names.test.sh"; stage q
expect "a data file: its row covers every token in it, an install too" q 0
plant da;  printf 'jobs:\n  x:\n    name: Test (Elixir 1.18.1 / OTP 27.0)\n' > "$T/da/.github/workflows/names.yml"
printf 'data  .github/workflows/names.yml  past check names\n' >> "$T/da/$TABLE_REL"; stage da
expect "a data row on a workflow file" da 1 'data row `.github/workflows/names.yml`: only a test or fixture path'
plant db;  printf '#!/bin/sh\necho "Test (Elixir 1.18.1 / OTP 27.0)"\n' > "$T/db/scripts/names.sh"
printf 'data  scripts/names.sh  past check names\n' >> "$T/db/$TABLE_REL"; stage db
expect "a data row on a non-test script" db 1 'data row `scripts/names.sh`: only a test or fixture path'
plant dc;  edit dc/$TABLE_REL 's/^data  scripts\/names.test.sh .*/data  scripts\/names.test.sh/'; stage dc
expect "a data row with no reason" dc 1 'data row `scripts/names.test.sh` gives no reason'
plant dd;  printf '#!/bin/sh\necho "no versions here"\n' > "$T/dd/scripts/names.test.sh"; stage dd
expect "a data row whose file holds no version text" dd 1 'data row `scripts/names.test.sh` carries no version literal'
plant s;   awk 'BEGIN { for (i = 1; i <= 4000; i++) print "asdf install erlang 26.2." i }' > "$T/s/scripts/big.sh"; stage s
expect "4000 findings (output far past a pipe buffer) still fail" s 1 'scripts/big.sh:4000:'
# ── the review's forms and file kinds, each on a line that names its tool ──
plant v1;  printf 'ELIXIR_VERSION ?= 1.17.3\nERLANG_VERSION := 27.3.4\n' > "$T/v1/Makefile"; printf '.tool-versions  Makefile\n' >> "$T/v1/$TABLE_REL"; stage v1
expect "V1 Makefile ?= (owned)" v1 1 'Makefile:1: 1.17.3 on a line naming elixir, but .tool-versions says elixir 1.18.4-otp-27'
plant v2;  printf 'ERLANG_VERSION := 26.2.5\n' > "$T/v2/Makefile"; stage v2
expect "V2 Makefile := (no row)" v2 1 'Makefile:1: 26.2.5 on a line naming erlang, and no row ties'
plant v3;  printf ': "${ERLANG_VERSION:=26.2.5}"\n' >> "$T/v3/deploy/install.sh"; stage v3
expect "V3 a := default in a deploy script" v3 1 'deploy/install.sh:4: 26.2.5 on a line naming erlang, but .tool-versions says erlang 27.3.4'
plant v4;  printf 'ENV ERLANG_VERSION 26.2.5\n' >> "$T/v4/img/Dockerfile"; stage v4
expect "V4 Dockerfile ENV with a space" v4 1 'img/Dockerfile:3: 26.2.5 on a line naming erlang, but deploy/image.tool-versions says erlang 27.3.4.13'
plant v5;  printf 'services:\n  api:\n    image: hexpm/elixir:1.17.3-erlang-26.2.5-alpine\n' > "$T/v5/docker-compose.yml"; stage v5
expect "V5 a compose image" v5 1 'docker-compose.yml:3: 1.17.3 on a line naming'
plant v6;  printf 'FROM hexpm/elixir:1.17.3-erlang-26.2.5-alpine\n' > "$T/v6/Containerfile"; stage v6
expect "V6 a Containerfile FROM" v6 1 'Containerfile:1: 1.17.3 on a line naming'
plant v7;  printf '[tools]\nerlang = "26.2.5"\n\n[tools.elixir]\nversion = "1.17.3"\n' > "$T/v7/.mise.toml"; stage v7
expect "V7 a mise table, both shapes" v7 1 '.mise.toml:5: 1.17.3 on a line naming elixir, and no row ties'
plant v8;  printf 'apt-get install -y esl-erlang=1:26.2.5-1\nkerl build 26.2.5 26.2.5\n' >> "$T/v8/deploy/install.sh"; stage v8
expect "V8 apt esl-erlang and kerl build" v8 1 'deploy/install.sh:5: 26.2.5 on a line naming erlang'
plant v9;  printf 'V=26.2.5; asdf install erlang "$V"\n' >> "$T/v9/deploy/install.sh"; stage v9
expect "V9 a variable on the install line" v9 1 'deploy/install.sh:4: 26.2.5 on a line naming erlang'
plant n1;  printf 'V=26.2.5\nasdf install erlang "$V"\n' >> "$T/n1/deploy/install.sh"; stage n1
expect "N1 NOT CAUGHT: V=26.2.5 on a line naming no tool (task-1c24786728762c92)" n1 0
plant n2;  printf 'V=26.2\nasdf install erlang "$V"\n' >> "$T/n2/deploy/install.sh"; stage n2
expect "N2 NOT CAUGHT: V=26.2 on a line naming no tool (task-1c24786728762c92)" n2 0
plant n3;  printf 'asdf install erlang \\\n  26.2.5\n' >> "$T/n3/deploy/install.sh"; stage n3
expect "N3 NOT CAUGHT: a line continuation splits tool and number (task-1c24786728762c92)" n3 0
plant n4;  add_after n4/$W '  prod:' '    strategy:\n      matrix:\n        beam: ["26.2.5"]'; add_after n4/$W '    steps:' '      - run: asdf install erlang ${{ matrix.beam }}'; stage n4
expect "N4 NOT CAUGHT: a neutral matrix key (task-1c24786728762c92)" n4 0
plant n5;  printf 'ERLVSN=26.2.5\nasdf install erlang "$ERLVSN"\n' >> "$T/n5/deploy/install.sh"; stage n5
expect "N5 NOT CAUGHT: ERLVSN= names no tool word (task-1c24786728762c92)" n5 0
plant n6;  printf 'FROM elixir:latest\nFROM hexpm/elixir@sha256:%s\n' "$(printf '4f1c9e0a7b2d%.0s' 1 2 3 4 5 6 | cut -c1-64)" > "$T/n6/img/Dockerfile.x"; stage n6
expect "N6 NOT CAUGHT: FROM erlang:latest and an @sha256 digest (task-1c24786728762c92)" n6 0

# ── the rest of the review's plants (plants.sh numbers) ──────────────────────
plant p01b; edit p01b/$W '26s/version-file: .tool-versions/otp-version: "27.0"/'; stage p01b
expect "P01b/L1 literal otp-version in the prod job only" p01b 1 'ci.yml:26 (job prod): 27.0 on a line naming erlang'
plant p02; add_after p02/$W '          version-type: strict' '          elixir-version: "1.18.1"'; stage p02
expect "P02 elixir-version beside version-file" p02 1 'ci.yml:13 (job test): 1.18.1 on a line naming elixir, but .tool-versions says elixir'
plant p03; add_after p03/$W '  prod:' '    strategy:\n      matrix:\n        otp: ["27.0"]'; stage p03
expect "P03 a flow-list matrix axis" p03 1 'ci.yml:24 (job prod): 27.0 on a line naming erlang'
plant p05; edit p05/deploy/image.tool-versions 's/^erlang 27.3.4.13$/erlang 27.3.4.12/'; stage p05
expect "P05 the image version file moves, the FROM does not" p05 1 'img/Dockerfile:1: 27.3.4.13 on a line naming'
plant p07; printf 'name: x\non: push\njobs:\n  x:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: erlef/setup-beam@v1\n        with:\n          install-hex: true\n' > "$T/p07/.github/workflows/x.yml"; stage p07
expect "P07 a new workflow's setup-beam reads no version file" p07 1 'x.yml:7 (job x): a setup-beam step with no version-file row'
plant p11; edit p11/$W '11s/version-file: .tool-versions/otp-version: ${{ env.OTP }}/'; stage p11
expect "P11 an env expression into setup-beam" p11 1 'ci.yml:11 (job test): names a version itself (otp-version)'
plant p12; printf 'name: x\non: push\njobs:\n  x:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: erlef/setup-beam@v1\n        with: &beam\n          version-file: .tool-versions\n          version-type: strict\n' > "$T/p12/.github/workflows/a.yml"; stage p12
expect "P12 a YAML anchor on setup-beam inputs, workflow not in the table" p12 1 'a.yml:7 (job x): a setup-beam step with no version-file row'
plant p14; printf '#!/bin/sh\nasdf install erlang 26.2.5\n' > "$T/p14/scripts/boot-x.sh"; stage p14
expect "P14 asdf install in a new script" p14 1 'scripts/boot-x.sh:2: 26.2.5 on a line naming erlang, and no row ties'
plant p21; printf '#!/bin/sh\nelixir --version | grep -q "^Elixir 1\\.18\\.1" || exit 2\n' > "$T/p21/scripts/sobelow.sh"; printf '.tool-versions  scripts/sobelow.sh\n' >> "$T/p21/$TABLE_REL"; stage p21
expect "P21 the Sobelow shape, an escaped version in an owned script" p21 1 'scripts/sobelow.sh:2: 1.18.1 on a line naming elixir, but .tool-versions says'

# ── token cutting (E1-E6) and the devcontainer kind ──────────────────────────
plant e1;  printf '#!/bin/sh\nelixir --version | grep -Eq '"'"'^Elixir 1\\.17\\.3'"'"'\n' > "$T/e1/scripts/vcheck.sh"; stage e1
expect "E1 a backslash inside the number" e1 1 'scripts/vcheck.sh:2: 1.17.3 on a line naming elixir'
plant e4;  printf 'FROM erlang:26-alpine\n' >> "$T/e4/img/Dockerfile"; stage e4
expect "E4 a bare major after a tool word (erlang:26-alpine)" e4 1 'img/Dockerfile:3: 26 on a line naming erlang, but deploy/image.tool-versions says erlang 27.3.4.13'
plant e5;  printf 'erlangVersion=26.2.5\n' >> "$T/e5/deploy/install.sh"; stage e5
expect "E5 a tool word that ends at a case change (erlangVersion)" e5 1 'deploy/install.sh:4: 26.2.5 on a line naming erlang'
plant e6;  printf 'mise use erlang@26\n' >> "$T/e6/deploy/install.sh"; stage e6
expect "E6 erlang@26" e6 1 'deploy/install.sh:4: 26 on a line naming erlang'
plant mf;  printf 'ELIXIR_FLAG=1\nWITH_ELIXIR=0\n' >> "$T/mf/deploy/install.sh"; stage mf
expect "a one-digit number after a tool word is a flag, not a version" mf 0
plant mj;  printf 'FROM erlang:27-alpine AS tools\n' >> "$T/mj/img/Dockerfile"; stage mj
expect "a bare major equal to the owner's major passes" mj 0
plant dv;  mkdir -p "$T/dv/.devcontainer"; printf '{"image": "hexpm/elixir:1.17.3-erlang-26.2.5-debian-bookworm-20240612-slim"}\n' > "$T/dv/.devcontainer/devcontainer.json"; stage dv
expect "a devcontainer.json is read" dv 1 '.devcontainer/devcontainer.json:1: 1.17.3 on a line naming'
plant dw;  mkdir -p "$T/dw/.devcontainer"; printf '{ "features": { "ghcr.io/x/elixir-asdf:2": { "elixirVersion": "1.17.3" } } }\n' > "$T/dw/.devcontainer/devcontainer.json"; stage dw
expect "a devcontainer feature's elixirVersion" dw 1 '.devcontainer/devcontainer.json:1: 1.17.3 on a line naming elixir'

# ── the reviewer's L, B and E plants, exact content (plants-LB.md) ──────────
F='FROM hexpm/elixir:1.18.4-erlang-27.3.4.13-debian-bookworm-20260623-slim AS build'
plant l3;  add_after l3/$W '  prod:' '    env:\n      KEY: mix-prod-deps-otp27.0-ex1.18.1'; stage l3
expect "L3 a cache key spells versions in an owned workflow" l3 1 'ci.yml:23 (job prod): 27.0 on a line naming erlang, but .tool-versions says'
plant l4;  printf '#!/bin/sh\nERLANG_VERSION=26.2.5\n' > "$T/l4/scripts/newthing.sh"; stage l4
expect "L4 a new script names a version" l4 1 'scripts/newthing.sh:2: 26.2.5 on a line naming erlang, and no row ties'
plant l6;  rm -f "$T/l6/deploy/install.sh"; stage l6
expect "L6 a table row whose consumer is gone" l6 1 'deploy/install.sh does not exist'
plant l7;  edit l7/$TABLE_REL '/^\.tool-versions  deploy\/install\.sh$/d'; stage l7
expect "L7 a consumer in no row" l7 1 'deploy/install.sh:2: 27.3.4 on a line naming erlang, and no row ties'
plant b01; mkdir -p "$T/b01/cloud"; printf 'services:\n  dev:\n    image: hexpm/elixir:1.17.3-erlang-26.2.5-debian-bookworm-20240612-slim\n' > "$T/b01/cloud/docker-compose.dev.yml"; stage b01
expect "B01 a compose image" b01 1 'cloud/docker-compose.dev.yml:3: 1.17.3 on a line naming'
plant b02; mkdir -p "$T/b02/cloud"; printf 'FROM elixir:1.17-alpine\n' > "$T/b02/cloud/Containerfile"; stage b02
expect "B02 a Containerfile" b02 1 'cloud/Containerfile:1: 1.17 on a line naming elixir'
plant b03; mkdir -p "$T/b03/api"; printf '[tools]\nerlang = "26.2.5"\nelixir = "1.17.3-otp-26"\n' > "$T/b03/api/.mise.toml"; stage b03
expect "B03 a mise config" b03 1 'api/.mise.toml:2: 26.2.5 on a line naming erlang'
plant b04; printf '#!/bin/sh\nV=26.2.5\nasdf install erlang "$V"\n' > "$T/b04/scripts/boot2.sh"; stage b04
expect "B04 NOT CAUGHT: two-line indirection (task-1c24786728762c92)" b04 0
plant b05; printf 'ELIXIR_VERSION ?= 1.17.3\nERLANG_VERSION := 26.2.5\n' > "$T/b05/Makefile"; stage b05
expect "B05 Makefile ?= and :=" b05 1 'Makefile:1: 1.17.3 on a line naming elixir'
plant b06; printf ': "${ERLANG_VERSION:=26.2.5}"\n' >> "$T/b06/deploy/install.sh"; stage b06
expect "B06 shell := default" b06 1 'deploy/install.sh:4: 26.2.5 on a line naming erlang, but'
plant b07; add_after b07/img/Dockerfile "$F" 'ENV ERLANG_VERSION 26.2.5'; stage b07
expect "B07 Dockerfile ENV in its space form" b07 1 'img/Dockerfile:2: 26.2.5 on a line naming erlang, but deploy/image.tool-versions'
plant b08; add_after b08/img/Dockerfile "$F" 'RUN apt-get install -y esl-erlang=1:26.2.5-1'; stage b08
expect "B08 an apt pin" b08 1 'img/Dockerfile:2: 26.2.5 on a line naming erlang, but deploy/image.tool-versions'
plant b09; printf '#!/bin/sh\nkerl build 26.2.5 r26\n' > "$T/b09/scripts/kerl.sh"; stage b09
expect "B09 kerl" b09 1 'scripts/kerl.sh:2: 26.2.5 on a line naming erlang'
plant b10; mkdir -p "$T/b10/api"; printf 'erlang 27.3.4\nelixir 1.17.3-otp-26\n' > "$T/b10/api/.tool-versions"; printf '.tool-versions  api/.tool-versions\n' >> "$T/b10/$TABLE_REL"; stage b10
expect "B10 a consumer .tool-versions whose elixir differs" b10 1 'api/.tool-versions: elixir 1.17.3-otp-26, but .tool-versions says 1.18.4-otp-27'
plant x1;  printf '#!/bin/sh\nelixir --version | grep -Eq '"'"'^Elixir 1\\.17\\.3'"'"' || exit 2\n' > "$T/x1/scripts/vcheck2.sh"; stage x1
expect "E1 escaped dots (plants-LB.md)" x1 1 'scripts/vcheck2.sh:2: 1.17.3 on a line naming elixir'
plant x1s; cat > "$T/x1s/scripts/sobelow-reconcile.sh" <<'SOB'
if ! grep -Eq '^Erlang/OTP 27([.[:space:]]|$)' <<<"$versions" ||
   ! grep -Eq '^Elixir 1\.18\.1([[:space:]]|$)' <<<"$versions"; then
  printf 'error: expected Elixir 1.18.1 / OTP 27, got:\n%s\n' "$versions" >&2
SOB
printf '.tool-versions  scripts/sobelow-reconcile.sh\n' >> "$T/x1s/$TABLE_REL"; stage x1s
expect "E1 the original Sobelow lines (main 48a2b86)" x1s 1 'scripts/sobelow-reconcile.sh:2: 1.18.1 on a line naming elixir, but .tool-versions says'
plant x4;  mkdir -p "$T/x4/cloud"; printf 'FROM erlang:26-alpine\n' > "$T/x4/cloud/Dockerfile.erl"; stage x4
expect "E4 a major-only image tag (plants-LB.md)" x4 1 'cloud/Dockerfile.erl:1: 26 on a line naming erlang'
plant x5;  printf 'const erlangVersion = "26.2.5";\n' > "$T/x5/scripts/camel.mjs"; stage x5
expect "E5 camelCase (plants-LB.md)" x5 1 'scripts/camel.mjs:1: 26.2.5 on a line naming erlang'
plant x6;  printf '#!/bin/sh\nmise use --global erlang@26\n' > "$T/x6/scripts/m.sh"; stage x6
expect "E6 a major-only version in mise (plants-LB.md)" x6 1 'scripts/m.sh:2: 26 on a line naming erlang'
plant c1;  printf '#!/bin/sh\nmise use --global erlang@26 elixir@1.17\n' > "$T/c1/scripts/m.sh"; stage c1
expect "control: erlang@26 elixir@1.17" c1 1 'scripts/m.sh:2: '
plant c2;  printf 'ARG B=1.18.4-erlang-26.2.5\nFROM hexpm/elixir:${B}-debian-bookworm-20240612-slim\n' > "$T/c2/img/Dockerfile.b"; stage c2
expect "control: an ARG that names erlang" c2 1 'img/Dockerfile.b:1: '

# ── image tags and pin rows ──────────────────────────────────────────────────
plant t1;  printf 'FROM postgres:16.4\n' > "$T/t1/img/Dockerfile.db"; stage t1
expect "an image tag with no pin row" t1 1 'img/Dockerfile.db:1: image tag :16.4 is pinned by no row'
plant t2;  printf 'FROM postgres:16.4\n' > "$T/t2/img/Dockerfile.db"; printf 'pin  img/Dockerfile.db  16.4  the test database image\n' >> "$T/t2/$TABLE_REL"; stage t2
expect "a pinned image tag passes" t2 0
plant t3;  printf 'pin  img/Dockerfile  16.4  the test database image\n' >> "$T/t3/$TABLE_REL"; stage t3
expect "a pin row whose token is gone" t3 1 'pin row `img/Dockerfile 16.4`: img/Dockerfile has no checked 16.4 any more'
plant t4;  printf 'FROM postgres:16.4\n' > "$T/t4/img/Dockerfile.db"; printf 'pin  img/Dockerfile.db  16.4\n' >> "$T/t4/$TABLE_REL"; stage t4
expect "a pin row that does not say what it pins" t4 1 'pin row `img/Dockerfile.db 16.4` does not say what it pins'

# ── line rows: one prose line, by the hash of its text ───────────────────────
line_plant() { # line_plant <dir>: a census line naming elixir beside CPU seconds, with its row
  plant "$1"
  printf '#!/bin/sh\ncat <<EOF\ngate-a PRICE elixir gate CPU=1.25+0.31s\nEOF\n' > "$T/$1/scripts/census.sh"
  printf 'line  scripts/census.sh  %s  gate-a :: CPU-second prices beside gate names\n' \
    "$(printf '%s' 'gate-a PRICE elixir gate CPU=1.25+0.31s' | git hash-object --stdin | cut -c1-12)" >> "$T/$1/$TABLE_REL"
  stage "$1"
}
line_plant h0; expect "a line row covers its line" h0 0
line_plant h1; printf 'gate-b PRICE elixir 1.17.3\n' >> "$T/h1/scripts/census.sh"; stage h1
expect "a NEW tool-named line in a file with line rows" h1 1 'scripts/census.sh:5: 1.17.3 on a line naming elixir'
line_plant h2; edit h2/scripts/census.sh 's/CPU=1.25/CPU=1.26/'; stage h2
expect "a covered line with one digit changed" h2 1 'scripts/census.sh:3: 1.26 on a line naming elixir'
line_plant h3; edit h3/scripts/census.sh '/^gate-a/d'; stage h3
expect "a line row whose line is gone" h3 1 'line row `scripts/census.sh'
line_plant h4; edit h4/$TABLE_REL 's/ :: CPU-second prices beside gate names//'; stage h4
expect "a line row with no reason" h4 1 'gives no reason. End it with'

plant n;   rm -f "$T/n/deploy/image.tool-versions"; stage n
expect "a missing version file refuses" n 2 "REFUSAL"
plant o;   rm -f "$T/o/$TABLE_REL"; stage o
expect "a missing table refuses" o 2 "REFUSAL"
mkdir -p "$T/nogit/scripts"; printf '.tool-versions  x\n' > "$T/nogit/$TABLE_REL"
expect "a tree that is not a git work tree refuses" nogit 2 "not a git work tree"

echo
echo "selftest: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
