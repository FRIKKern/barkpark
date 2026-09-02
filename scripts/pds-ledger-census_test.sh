#!/usr/bin/env bash
#
# MUTATION FIXTURES FOR THE PDS LEDGER CENSUS.
#
# THE SELFTEST IS THE DELIVERABLE, NOT A COURTESY. A census is a verb whose
# entire output is a success claim, and every failure mode this instrument
# exists to stop -- a rate-limited page, a silently capped page, a truncated
# page, a one-level lens, a cleanly-parsing failure envelope -- ALREADY exits 0
# and reports a SMALLER board when you get it wrong. So a selftest whose
# fixtures all pass proves nothing at all: it proves the checker runs, which was
# never in doubt. Every fixture below is a MUTATION that must make the census
# EXIT NON-ZERO, and each one asserts the exact exit code, so a guard that
# degrades into "always red" is caught by the green fixtures and a guard that
# degrades into "always green" is caught by the red ones.
#
# Shape borrowed from api/scripts/sobelow-baseline-staleness-check.sh --selftest,
# which is this repo's existing example of the pattern (8 fixtures, each pinned
# to a specific exit code).
#
# NO NETWORK. Every fixture runs through --fixture-dir, the census's canned-HTTP
# transport, which feeds the SAME status-scoring / shape-asserting / paging code
# the live run uses. A fixture that bypassed that code would prove nothing about
# the live run.
#
# EXIT CODES UNDER TEST (from the census)
#   0 coherent census    1 round-done predicate false    2 fail closed
#   3 usage              4 snapshot incoherent
#
# usage: bash scripts/pds-ledger-census_test.sh

set -uo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CENSUS="$HERE/pds-ledger-census.sh"
ROOT_SLUG="fixture-root"
FAILURES=0
CHECKS=0

TMP=$(mktemp -d "${TMPDIR:-/tmp}/pds-ledger-census-selftest.XXXXXX")
trap 'rm -rf -- "$TMP"' EXIT

# --- fixture construction -----------------------------------------------------
#
# `page <dir> <index> <status> <json>` writes one canned HTTP response.

page() {
  local dir=$1 index=$2 status=$3 body=$4
  mkdir -p "$dir"
  { printf 'HTTP %s\n' "$status"; printf '%s' "$body"; } > "$dir/page-$index.http"
}

# A row, as the query endpoint serves it. Deliberately three levels deep so a
# one-level lens has a grandchild to lose.
#
# The SIXTH field is the STRUCTURED `reopen_trigger`, and it is omitted from the
# JSON entirely when empty -- exactly how a row that never carried one is served.
# Clause 4(c) reads this field and nothing else, so a fixture that could only
# express a trigger as prose could not tell the two apart.
# The SEVENTH field is `_createdAt`, and it is likewise omitted when empty --
# the live `row()` shape has never carried one, and clause 4(a)'s anchor reads it
# ONLY for rows that are already live-and-bare, so every pre-existing fixture is
# untouched by its absence. An anchored fixture must supply it or fail closed.
# The EIGHTH is `wave_paper`, the field the epic ROOT row uses to name its own
# wave Paper, and it is omitted when empty for the same reason: a root that does
# not declare one binds nothing, which is the shape every pre-existing fixture
# here has and must keep having.
row() {
  local id=$1 parent=$2 lifecycle=$3 disposition=$4 reason=$5 trigger=${6:-} created=${7:-} wave=${8:-}
  local extra=''
  if [[ -n $trigger ]]; then
    extra=$(printf ',"reopen_trigger":"%s"' "$trigger")
  fi
  if [[ -n $created ]]; then
    extra+=$(printf ',"_createdAt":"%s"' "$created")
  fi
  if [[ -n $wave ]]; then
    extra+=$(printf ',"wave_paper":"%s"' "$wave")
  fi
  printf '{"_id":"%s","_type":"task","_updatedAt":"2020-01-01T00:00:00.000000Z","parent_id":%s,"lifecycle_status":"%s","disposition":"%s","disposition_reason":"%s"%s}' \
    "$id" "$parent" "$lifecycle" "$disposition" "$reason" "$extra"
}

# `paper <dir> <slug> <status> <json>` cans the ANCHOR read --
# GET /v1/data/doc/<dataset>/paper/<slug>. It runs through the same
# status-first / shape-asserted resolver the live run uses, so a fixture here
# proves something about the live anchor and not merely about the fixture.
paper() {
  local dir=$1 slug=$2 status=$3 body=$4
  mkdir -p "$dir"
  { printf 'HTTP %s\n' "$status"; printf '%s' "$body"; } > "$dir/paper-$slug.http"
}

# `drafts_page <dir> <index> <status> <json>` cans the SECOND lens --
# GET /v1/data/query?...&perspective=drafts. It is keyed on its own filename, so
# a fixture that cans NO drafts page models a source that does not offer the
# lens (reported UNREAD), and one that cans page 0 and then stops is still a
# TRUNCATED READ and still fails closed.
drafts_page() {
  local dir=$1 index=$2 status=$3 body=$4
  mkdir -p "$dir"
  { printf 'HTTP %s\n' "$status"; printf '%s' "$body"; } > "$dir/drafts-page-$index.http"
}

# A well-formed page envelope.
envelope() {
  local count=$1 offset=$2 limit=$3 docs=$4
  printf '{"result":{"count":%s,"offset":%s,"limit":%s,"perspective":"published","documents":[%s]}}' \
    "$count" "$offset" "$limit" "$docs"
}

# THE HEALTHY CORPUS. 7 rows over 2 pages of limit 4, so the walk MUST reach
# page 1 to be complete: `deep-a` and `deep-b` are grandchildren that live only
# on the second page. Every reason is distinct, every disposition is in
# vocabulary, every reason MENTIONS a reopen trigger in prose -- and exactly one
# row, `kid-c`, the only LIVE park, carries the STRUCTURED `reopen_trigger`
# field. That asymmetry is the point: a healthy board is 1 structured against 4
# prose-only, and the two numbers are reported side by side, never summed.
build_healthy() {
  local dir=$1
  local p0 p1
  p0="$(row "$ROOT_SLUG" 'null' open open 'root row. REOPEN: never'),"
  p0+="$(row kid-a "\"$ROOT_SLUG\"" open open 'kid a reason one. REOPEN: alpha'),"
  p0+="$(row kid-b "\"$ROOT_SLUG\"" done closed 'kid b reason two. REACTIVATE: bravo'),"
  p0+="$(row kid-c "\"$ROOT_SLUG\"" blocked parked 'kid c reason three. REOPEN: charlie' 'TRIGGER: charlie ships')"
  p1="$(row deep-a '"kid-a"' open open 'deep a reason four. REOPEN: delta'),"
  p1+="$(row deep-b '"kid-b"' cancelled closed 'deep b reason five. REOPEN: echo'),"
  p1+="$(row unrelated 'null' open open 'not under the root at all. REOPEN: foxtrot')"
  page "$dir" 0 200 "$(envelope 4 0 4 "$p0")"
  page "$dir" 1 200 "$(envelope 3 4 4 "$p1")"
}

# THE BOUND CORPUS. The healthy board, except that the ROOT ROW DECLARES ITS OWN
# WAVE PAPER (`wave_paper`, exactly as the live epic root does -- /v1/data/query
# flattens content.* to the top level), and `deep-a` is the LIVE BARE row born in
# 2030: residue of any round anchored before then. The declared slug is a
# PARAMETER so the same builder makes the bound fixture and the one whose
# declared Paper the source cannot serve.
build_bound() {
  local dir=$1 wave=$2
  local p0 p1
  p0="$(row "$ROOT_SLUG" 'null' open open 'root row. REOPEN: never' '' '' "$wave"),"
  p0+="$(row kid-a "\"$ROOT_SLUG\"" open open 'kid a reason one. REOPEN: alpha'),"
  p0+="$(row kid-b "\"$ROOT_SLUG\"" done closed 'kid b reason two. REACTIVATE: bravo'),"
  p0+="$(row kid-c "\"$ROOT_SLUG\"" blocked parked 'kid c reason three. REOPEN: charlie' 'TRIGGER: charlie ships')"
  p1="$(row deep-a '"kid-a"' open '' 'deep a reason four. REOPEN: delta' '' '2030-01-01T00:00:00.000000Z'),"
  p1+="$(row deep-b '"kid-b"' cancelled closed 'deep b reason five. REOPEN: echo'),"
  p1+="$(row unrelated 'null' open open 'unrelated. REOPEN: foxtrot')"
  page "$dir" 0 200 "$(envelope 4 0 4 "$p0")"
  page "$dir" 1 200 "$(envelope 3 4 4 "$p1")"
}

# THE CLAUSE-8 REPO. A REAL git repository, built here, with a real
# refs/remotes/origin/main and a real dangling commit -- not a table of canned
# answers. The clause shells out to the same `git cat-file` / `merge-base
# --is-ancestor` / `check-ignore` in this fixture as it does on the live board,
# so a green here is a property of the clause and not of a second implementation
# that agrees with it. It is hermetic (its own $TMP dir, its own object store),
# so nothing it does touches the checkout the selftest runs from.
#
# Sets: ON_SHA (a commit origin/main HAS), OFF_SHA (a REAL commit origin/main
# never saw -- committed on main and then reset away, so the object survives
# unreachable), BLOB_SHA (a blob, which owes existence and NOT ancestry).
build_reason_repo() {
  local dir=$1
  mkdir -p "$dir"
  git init -q "$dir" >/dev/null 2>&1
  git -C "$dir" symbolic-ref HEAD refs/heads/main
  git -C "$dir" config user.email 'pds-selftest@example.invalid'
  git -C "$dir" config user.name 'pds selftest'
  git -C "$dir" config commit.gpgsign false
  mkdir -p "$dir/scripts" "$dir/docs/api" "$dir/api/lib"
  printf 'real\n' > "$dir/scripts/real.sh"
  printf 'real\n' > "$dir/docs/api/real.md"
  printf 'real\n' > "$dir/api/lib/real.ex"
  printf 'build/\n' > "$dir/.gitignore"
  git -C "$dir" add -A >/dev/null
  git -C "$dir" commit -q -m base
  git -C "$dir" update-ref refs/remotes/origin/main HEAD
  ON_SHA=$(git -C "$dir" rev-parse --short=10 HEAD)
  BLOB_SHA=$(git -C "$dir" rev-parse --short=10 HEAD:scripts/real.sh)
  printf 'off\n' > "$dir/off.txt"
  git -C "$dir" add -A >/dev/null
  git -C "$dir" commit -q -m off
  OFF_SHA=$(git -C "$dir" rev-parse --short=10 HEAD)
  git -C "$dir" reset -q --hard "$ON_SHA"
  mkdir -p "$dir/build"
  printf 'artifact\n' > "$dir/build/artifact.txt"
}

# THE CITED CORPUS. Byte-for-byte the healthy board's SHAPE -- same ids, same
# lifecycles, same dispositions, same single structured trigger -- so it is
# round-done clean on clauses 1-7 and the ONLY thing that can move is clause 8.
# What changes is what the reasons CITE:
#
# THE CLOSURE IS FIVE ROWS -- the root and `unrelated` are outside it, exactly as
# in `build_healthy` -- so every count this section asserts is over kid-a, kid-b,
# kid-c, deep-a and deep-b:
#
#   kid-a   a dangling sha AND an absent path, in ONE reason  -> the mutation
#   kid-b   nothing at all                                    -> thin
#   kid-c   a live sha, a live path, and a BLOB               -> the positive arm
#   deep-a  a gitignored path                                 -> ignored
#   deep-b  `origin/main` and `8/10`                          -> foreign, so thin
#
# EVERY REASON IS BYTE-UNIQUE, which is the whole point: clause 1 passes on all
# five while clause 8 has something to say about one of them.
build_cited() {
  local dir=$1
  local p0 p1
  p0="$(row "$ROOT_SLUG" 'null' open open 'root row cites nothing. REOPEN: never'),"
  p0+="$(row kid-a "\"$ROOT_SLUG\"" open open "kid a cites $OFF_SHA and docs/api/absent.md. REOPEN: alpha"),"
  p0+="$(row kid-b "\"$ROOT_SLUG\"" done closed 'kid b cites nothing whatsoever. REACTIVATE: bravo'),"
  p0+="$(row kid-c "\"$ROOT_SLUG\"" blocked parked "kid c cites $ON_SHA, scripts/real.sh and blob $BLOB_SHA. REOPEN: charlie" 'TRIGGER: charlie ships')"
  p1="$(row deep-a '"kid-a"' open open 'deep a cites build/artifact.txt. REOPEN: delta'),"
  p1+="$(row deep-b '"kid-b"' cancelled closed 'deep b cites origin/main and 8/10. REOPEN: echo'),"
  p1+="$(row unrelated 'null' open open 'not under the root at all. REOPEN: foxtrot')"
  page "$dir" 0 200 "$(envelope 4 0 4 "$p0")"
  page "$dir" 1 200 "$(envelope 3 4 4 "$p1")"
}

# THE FAIL-FIRST CORPUS. The SAME seven rows, except every reason is a stale,
# wrong or invented citation that is nonetheless BYTE-UNIQUE. This is the row's
# own finding, made runnable: clause 1 must stay GREEN over it.
build_invented() {
  local dir=$1
  local p0 p1
  p0="$(row "$ROOT_SLUG" 'null' open open "root re-derived at $OFF_SHA per docs/api/ghost-one.md. REOPEN: never"),"
  p0+="$(row kid-a "\"$ROOT_SLUG\"" open open "kid a re-derived at $OFF_SHA per docs/api/ghost-two.md. REOPEN: alpha"),"
  p0+="$(row kid-b "\"$ROOT_SLUG\"" done closed "kid b re-derived at $OFF_SHA per docs/api/ghost-three.md. REACTIVATE: bravo"),"
  p0+="$(row kid-c "\"$ROOT_SLUG\"" blocked parked "kid c re-derived at $OFF_SHA per docs/api/ghost-four.md. REOPEN: charlie" 'TRIGGER: charlie ships')"
  p1="$(row deep-a '"kid-a"' open open "deep a re-derived at $OFF_SHA per docs/api/ghost-five.md. REOPEN: delta"),"
  p1+="$(row deep-b '"kid-b"' cancelled closed "deep b re-derived at $OFF_SHA per docs/api/ghost-six.md. REOPEN: echo"),"
  p1+="$(row unrelated 'null' open open "unrelated re-derived at $OFF_SHA per docs/api/ghost-seven.md. REOPEN: foxtrot")"
  page "$dir" 0 200 "$(envelope 4 0 4 "$p0")"
  page "$dir" 1 200 "$(envelope 3 4 4 "$p1")"
}

# A well-formed page envelope for the SECOND lens. The perspective it echoes is
# a PARAMETER, because the interesting failure is a source that answers
# `published` to a `perspective=drafts` request -- which is what the API does to
# an anonymous or public-read caller, silently.
drafts_envelope() {
  local count=$1 offset=$2 limit=$3 perspective=$4 docs=$5
  printf '{"result":{"count":%s,"offset":%s,"limit":%s,"perspective":"%s","documents":[%s]}}' \
    "$count" "$offset" "$limit" "$perspective" "$docs"
}

# THE BLIND-SPOT CORPUS. The healthy board plus TWO rows that carry the epic's
# slug prefix and hang off a foreign parent -- one LIVE (work this epic owns and
# cannot see) and one DONE (bookkeeping). The live one's parent is a PARAMETER:
# the same fixture built with a parent INSIDE the closure is the mutation that
# proves the arm is derived from the corpus and not from a name someone typed.
build_blind() {
  local dir=$1 stray_parent=$2
  local p1 p2
  build_healthy "$dir"
  p1="$(row deep-a '"kid-a"' open open 'deep a reason four. REOPEN: delta'),"
  p1+="$(row deep-b '"kid-b"' cancelled closed 'deep b reason five. REOPEN: echo'),"
  p1+="$(row unrelated 'null' open open 'not under the root at all. REOPEN: foxtrot'),"
  p1+="$(row pds-stray-open "$stray_parent" open open 'stray row six. REOPEN: golf')"
  p2="$(row pds-stray-done '"foreign-epic"' done closed 'stray row seven. REOPEN: hotel')"
  page "$dir" 1 200 "$(envelope 4 4 4 "$p1")"
  page "$dir" 2 200 "$(envelope 1 8 4 "$p2")"
}

# THE DRAFTS LENS, CANNED. Four rows, one of each kind the split must tell
# apart, plus one OUT OF SCOPE row that must never be named:
#   drafts.pds-hidden-x  -> no published twin           = HIDDEN WORK
#   drafts.kid-b         -> published twin is `done`    = PHANTOM (edit shadow)
#   drafts.kid-a         -> published twin is `open`    = already in the denominator
#   drafts.foreign       -> parent outside the closure  = not this epic's at all
# The second page is EMPTY and present on purpose: the drafts read pages exactly
# like the published one, and a short page is what ends it.
build_blind_drafts() {
  local dir=$1
  local d0
  d0="$(row drafts.pds-hidden-x '"kid-a"' open open 'never published at all. REOPEN: india'),"
  d0+="$(row drafts.kid-b "\"$ROOT_SLUG\"" open open 'edit shadow of a DONE row. REOPEN: juliet'),"
  d0+="$(row drafts.kid-a "\"$ROOT_SLUG\"" open open 'edit shadow of a LIVE row. REOPEN: kilo'),"
  d0+="$(row drafts.foreign 'null' open open 'another epic entirely. REOPEN: lima')"
  drafts_page "$dir" 0 200 "$(drafts_envelope 4 0 4 drafts "$d0")"
  drafts_page "$dir" 1 200 "$(drafts_envelope 0 4 4 drafts '')"
}

# THE HOSTILE WORKING DIRECTORY. `plant_stray <path> <module>` writes a stray
# copy of a stdlib module that the census imports transitively. It is FAITHFUL
# on purpose: it announces itself on stderr and then loads the REAL module off
# the stdlib path and re-exports it, so the census keeps working and its exit
# code stays correct. That is the dangerous shape -- 23 of the 49 names reachable
# from this census's imports execute a stray's top level while the run still
# exits 0 -- and it is why the isolation check cannot be an exit-code assertion.
STRAY_SENTINEL='PDS-STRAY-EXECUTED'
plant_stray() {
  local path=$1 module=$2
  cat > "$path" <<STRAYEOF
import sys
sys.stderr.write("$STRAY_SENTINEL $module\n")
import importlib.util, os, os.path
_real = os.path.join(os.path.dirname(os.__file__), "$module.py")
_spec = importlib.util.spec_from_file_location("_pds_real_$module", _real)
_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_mod)
globals().update({k: v for k, v in vars(_mod).items() if not k.startswith("__")})
STRAYEOF
}

# --- assertion helpers --------------------------------------------------------

expect_status() {
  local label=$1 want=$2
  shift 2
  CHECKS=$((CHECKS + 1))
  local got=0 out
  out=$("$@" 2>&1) || got=$?
  if [[ $got -ne $want ]]; then
    printf 'SELFTEST FAIL: %s — expected exit %d, got %d\n%s\n' "$label" "$want" "$got" "$out" >&2
    FAILURES=$((FAILURES + 1))
    return 1
  fi
  printf '  ok    %-52s exit %d\n' "$label" "$got"
}

# A red exit is not enough: it has to be red for the RIGHT reason, or a guard
# can rot into a different failure and the fixture will never notice.
expect_status_matching() {
  local label=$1 want=$2 needle=$3
  shift 3
  CHECKS=$((CHECKS + 1))
  local got=0 out
  out=$("$@" 2>&1) || got=$?
  if [[ $got -ne $want ]]; then
    printf 'SELFTEST FAIL: %s — expected exit %d, got %d\n%s\n' "$label" "$want" "$got" "$out" >&2
    FAILURES=$((FAILURES + 1))
    return 1
  fi
  if [[ $out != *"$needle"* ]]; then
    printf 'SELFTEST FAIL: %s — exit %d was right but the reason was not: expected to find %q\n%s\n' \
      "$label" "$got" "$needle" "$out" >&2
    FAILURES=$((FAILURES + 1))
    return 1
  fi
  printf '  ok    %-52s exit %d  (%s)\n' "$label" "$got" "$needle"
}

expect_output_contains() {
  local label=$1 needle=$2
  shift 2
  CHECKS=$((CHECKS + 1))
  local out
  out=$("$@" 2>&1)
  if [[ $out != *"$needle"* ]]; then
    printf 'SELFTEST FAIL: %s — output did not contain %q\n%s\n' "$label" "$needle" "$out" >&2
    FAILURES=$((FAILURES + 1))
    return 1
  fi
  printf '  ok    %-52s contains %q\n' "$label" "$needle"
}

expect_output_lacks() {
  local label=$1 needle=$2
  shift 2
  CHECKS=$((CHECKS + 1))
  local out
  out=$("$@" 2>&1)
  if [[ $out == *"$needle"* ]]; then
    printf 'SELFTEST FAIL: %s — output contained %q and must not\n%s\n' "$label" "$needle" "$out" >&2
    FAILURES=$((FAILURES + 1))
    return 1
  fi
  printf '  ok    %-52s lacks %q\n' "$label" "$needle"
}

# expect_stdout_only_contains is the MIRROR of expect_json_stdout: it keeps the
# streams separate and asserts the needle is on STDOUT specifically. 2>&1 helpers
# cannot tell the two apart, so without this one, moving a human line to stderr
# looks identical to leaving it on stdout — the same blindness that let the JSON
# stream stay poisoned for two waves, pointed the other way. The exit code is the
# census's own, captured directly, never through a pipe.
expect_stdout_only_contains() {
  local label=$1 needle=$2 want=$3
  shift 3
  CHECKS=$((CHECKS + 1))
  local got=0
  local so="$TMP/sonly.$CHECKS" se="$TMP/senly.$CHECKS"
  "$@" > "$so" 2> "$se" || got=$?
  if [[ $got -ne $want ]]; then
    printf 'SELFTEST FAIL: %s — expected exit %d, got %d\n%s\n%s\n' "$label" "$want" "$got" \
      "$(cat "$so")" "$(cat "$se")" >&2
    FAILURES=$((FAILURES + 1))
    return 1
  fi
  if ! grep -qF -- "$needle" "$so"; then
    printf 'SELFTEST FAIL: %s — %q is not on STDOUT (stderr: %s)\n%s\n' "$label" "$needle" \
      "$(grep -cF -- "$needle" "$se" || true)" "$(cat "$so")" >&2
    FAILURES=$((FAILURES + 1))
    return 1
  fi
  printf '  ok    %-52s stdout contains %q\n' "$label" "$needle"
}

# STDOUT IS THE MACHINE CHANNEL, AND THIS IS THE ONLY HELPER THAT CAN PROVE IT.
# Every other helper captures `2>&1`, which is exactly why the census could dump
# a human predicate block onto the same stdout as its JSON for two waves without
# a single fixture noticing. Here stdout and stderr go to SEPARATE files, the
# census's OWN exit code is captured directly (never through a pipe -- `| tail`
# reports the PIPELINE's status and will happily print RC=0 over a failing
# census), stdout must be non-empty, and stdout must parse as ONE JSON document.
# jq is the validator when it exists; python3 is the fallback, because python3 is
# already a hard requirement of the census and jq is not.
expect_json_stdout() {
  local label=$1 want=$2
  shift 2
  CHECKS=$((CHECKS + 1))
  local got=0 jrc=0 validator bytes
  local so="$TMP/stdout.$CHECKS" se="$TMP/stderr.$CHECKS"
  "$@" > "$so" 2> "$se" || got=$?
  bytes=$(wc -c < "$so" | tr -d ' ')
  if command -v jq >/dev/null 2>&1; then
    validator=jq
    jq -e . "$so" >/dev/null 2>&1 || jrc=$?
  else
    validator=python3
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$so" >/dev/null 2>&1 || jrc=$?
  fi
  if [[ $got -ne $want ]]; then
    printf 'SELFTEST FAIL: %s — expected exit %d, got %d\n%s\n%s\n' "$label" "$want" "$got" \
      "$(cat "$so")" "$(cat "$se")" >&2
    FAILURES=$((FAILURES + 1))
    return 1
  fi
  if [[ $bytes -eq 0 ]]; then
    printf 'SELFTEST FAIL: %s — exit %d was right but stdout was EMPTY; a failing run is when its payload matters most\n%s\n' \
      "$label" "$got" "$(cat "$se")" >&2
    FAILURES=$((FAILURES + 1))
    return 1
  fi
  if [[ $jrc -ne 0 ]]; then
    printf 'SELFTEST FAIL: %s — exit %d was right but stdout is NOT one JSON document (%s exit %d)\n%s\n' \
      "$label" "$got" "$validator" "$jrc" "$(cat "$so")" >&2
    FAILURES=$((FAILURES + 1))
    return 1
  fi
  printf '  ok    %-52s exit %d  (%s ok, %s bytes on stdout)\n' "$label" "$got" "$validator" "$bytes"
}

# THE INTERPRETER LAUNCH IS PART OF THE CONTRACT, AND ONLY THIS HELPER CAN SEE
# IT. The census feeds its program to python3 on STDIN, which puts the CURRENT
# WORKING DIRECTORY on sys.path[0] unless the interpreter is started isolated --
# so any *.py in the CWD whose name collides with a module the census imports
# transitively is EXECUTED by the instrument that certifies this epic's round.
# The exit code cannot see that: a faithful stray leaves every code path and
# every status correct and merely runs first. So this check asserts BOTH halves,
# the census's own exit code AND the absence of the stray's sentinel, and plants
# TWO strays reached by two different import chains, so a green here is a
# property of how the interpreter is launched and not of one module's name.
expect_isolated() {
  local label=$1 want=$2
  shift 2
  CHECKS=$((CHECKS + 1))
  local got=0 hits
  local hostile="$TMP/hostile.$CHECKS"
  mkdir -p "$hostile"
  plant_stray "$hostile/bisect.py" bisect
  plant_stray "$hostile/random.py" random
  local out="$TMP/hostile-out.$CHECKS"
  ( cd "$hostile" && "$@" ) > "$out" 2>&1 || got=$?
  hits=$(grep -cF -- "$STRAY_SENTINEL" "$out" || true)
  if [[ $got -ne $want ]]; then
    printf 'SELFTEST FAIL: %s — expected exit %d, got %d (from a CWD holding stray bisect.py/random.py)\n%s\n' \
      "$label" "$want" "$got" "$(cat "$out")" >&2
    FAILURES=$((FAILURES + 1))
    return 1
  fi
  if [[ $hits -ne 0 ]]; then
    printf 'SELFTEST FAIL: %s — exit %d was right but the census EXECUTED %d stray module(s) it found in the working directory; a correct exit code proves nothing when foreign code ran first\n%s\n' \
      "$label" "$got" "$hits" "$(cat "$out")" >&2
    FAILURES=$((FAILURES + 1))
    return 1
  fi
  printf '  ok    %-52s exit %d  (0 strays executed)\n' "$label" "$got"
}

# THE SUBSET IS PROVEN BY DIFFING TWO RUNS, NEVER BY PINNING AN ID. A pinned id
# goes stale the moment the fixture gains a row, and a stale pin that still
# passes is worse than no pin at all -- it asserts a membership nobody rechecked.
# These two read the census's OWN `sampled:` lines back out and compare them.
sampled_ids() {
  "$@" 2>&1 | sed -n 's/^      sampled: //p' | sort
}

expect_sample_stable() {
  local label=$1
  shift
  CHECKS=$((CHECKS + 1))
  local a b
  a=$(sampled_ids run "$@" --reason-sample-seed round-one)
  b=$(sampled_ids run "$@" --reason-sample-seed round-one)
  if [[ -z $a ]]; then
    printf 'SELFTEST FAIL: %s — the run printed NO sampled ids at all, so nothing was compared\n' "$label" >&2
    FAILURES=$((FAILURES + 1))
    return 1
  fi
  if [[ $a != "$b" ]]; then
    printf 'SELFTEST FAIL: %s — the same seed selected different rows\n  %s\n  %s\n' "$label" "$a" "$b" >&2
    FAILURES=$((FAILURES + 1))
    return 1
  fi
  printf '  ok    %-52s stable (%s)\n' "$label" "$(echo "$a" | tr '\n' ' ')"
}

expect_sample_rotates() {
  local label=$1
  shift
  CHECKS=$((CHECKS + 1))
  local a b
  a=$(sampled_ids run "$@" --reason-sample-seed round-one)
  b=$(sampled_ids run "$@" --reason-sample-seed round-two)
  if [[ -z $a || -z $b ]]; then
    printf 'SELFTEST FAIL: %s — a run printed NO sampled ids, so nothing was compared\n' "$label" >&2
    FAILURES=$((FAILURES + 1))
    return 1
  fi
  if [[ $a == "$b" ]]; then
    printf 'SELFTEST FAIL: %s — two different seeds selected the SAME rows, so the seed does nothing\n  %s\n' "$label" "$a" >&2
    FAILURES=$((FAILURES + 1))
    return 1
  fi
  printf '  ok    %-52s rotates (%s | %s)\n' "$label" \
    "$(echo "$a" | tr '\n' ' ')" "$(echo "$b" | tr '\n' ' ')"
}

run() {
  bash "$CENSUS" --root "$ROOT_SLUG" --pace 0 --retries 0 "$@"
}

echo "pds-ledger-census selftest: mutation fixtures"
echo

# =============================================================================
# CONTROL. The instrument must be able to be GREEN, or every red below is
# meaningless.
# =============================================================================
echo "control — a healthy 2-page corpus"
HEALTHY="$TMP/healthy"
build_healthy "$HEALTHY"
expect_status "healthy corpus censuses cleanly" 0 \
  run --page-limit 4 --fixture-dir "$HEALTHY"
# It must reach page 1: deep-a/deep-b are grandchildren that exist ONLY there,
# and `unrelated` (page 1, no parent) must NOT be counted.
expect_output_contains "closure is 5, not 3 (page 1 was read)" "closure     5 descendants" \
  run --page-limit 4 --fixture-dir "$HEALTHY"
expect_output_contains "live is 3 (done + cancelled are terminal)" "live        3" \
  run --page-limit 4 --fixture-dir "$HEALTHY"
expect_output_contains "reasons are all distinct" "distinct reason hashes          5" \
  run --page-limit 4 --fixture-dir "$HEALTHY"
# STRUCTURED and PROSE are counted separately and never summed: 1 row carries the
# field, 4 only talk about it. A summed counter would print 5 and call it coverage.
expect_output_contains "structured triggers are counted alone" "carrying a reopen trigger       1   (structured" \
  run --page-limit 4 --fixture-dir "$HEALTHY"
expect_output_contains "prose mentions are counted as DECORATION, beside" "prose-only REOPEN mention       4   (DECORATION" \
  run --page-limit 4 --fixture-dir "$HEALTHY"
expect_output_contains "no off-vocabulary dispositions" "(none)" \
  run --page-limit 4 --fixture-dir "$HEALTHY"
# The done-condition must be able to be GREEN too. A predicate that is red on
# everything is not a predicate.
expect_status "--assert-round-done PASSES on a clean board" 0 \
  run --page-limit 4 --fixture-dir "$HEALTHY" --assert-round-done
# ...and it must green WITHOUT executing anything it happens to find next to it.
expect_isolated "a shadowed CWD is neither read nor run" 0 \
  run --page-limit 4 --fixture-dir "$HEALTHY" --assert-round-done
echo

# =============================================================================
# CLAUSE 3 — RATE LIMITING. The 429 body is VALID JSON. A census that scores on
# "json.load succeeded", or on an `error.code` key, reads this AS DATA and
# counts the rows it never got as leaves.
# =============================================================================
echo "clause 3 — a rate-limited fetch must FAIL, never be counted as a leaf"
RATE="$TMP/rate-limited"
build_healthy "$RATE"
page "$RATE" 1 429 '{"ok":false,"error":{"code":"rate_limited","message":"slow down"}}'
expect_status_matching "429 on page 1 fails closed" 2 "rate limited" \
  run --page-limit 4 --fixture-dir "$RATE"
# and it must NOT quietly report the 3 rows it did get
expect_status_matching "429 reports no board at all" 2 "refusing to treat a rate-limited response as an empty page" \
  run --page-limit 4 --fixture-dir "$RATE"
# with retries budgeted, it backs off and then still fails closed
expect_status_matching "429 still fails after its retries" 2 "after 2 retries" \
  bash "$CENSUS" --root "$ROOT_SLUG" --pace 0 --retries 2 --page-limit 4 --fixture-dir "$RATE"
# backoff must RECOVER, not merely fail: 429 on the first attempt, the real page
# on the retry. A guard that only ever reds under 429 would be a different bug.
RECOVER="$TMP/rate-limited-recovers"
build_healthy "$RECOVER"
cp "$RECOVER/page-1.http" "$RECOVER/page-1-keep.http"
page "$RECOVER" 1 429 '{"ok":false,"error":{"code":"rate_limited"}}'
mv "$RECOVER/page-1.http" "$RECOVER/page-1-attempt-0.http"
mv "$RECOVER/page-1-keep.http" "$RECOVER/page-1.http"
expect_status "429 then success on retry censuses cleanly" 0 \
  bash "$CENSUS" --root "$ROOT_SLUG" --pace 0 --retries 2 --page-limit 4 --fixture-dir "$RECOVER"
# a 429 on the FIRST page must not read as an empty population either
RATE0="$TMP/rate-limited-first"
page "$RATE0" 0 429 '{"ok":false,"error":{"code":"rate_limited"}}'
expect_status_matching "429 on page 0 is not an empty board" 2 "rate limited" \
  run --page-limit 4 --fixture-dir "$RATE0"
echo

# =============================================================================
# CLAUSE 1 — PAGING. `limit=5000` is answered HTTP 200 with `limit: 1000`. The
# server never says it capped. A reader that trusts its own request reports a
# smaller board and exits 0.
# =============================================================================
echo "clause 1 — an unpaginated / truncated read must FAIL, not shrink the board"
CAPPED="$TMP/silently-capped"
build_healthy "$CAPPED"
# asked for everything in one page; the source silently answers with a 4-row cap
expect_status_matching "silently capped page fails closed" 2 "server silently capped the page" \
  run --page-limit 5000 --fixture-dir "$CAPPED"
# count says 4, only 2 documents arrived: a truncated page
TRUNC="$TMP/truncated"
build_healthy "$TRUNC"
page "$TRUNC" 0 200 "$(envelope 4 0 4 "$(row "$ROOT_SLUG" 'null' open open 'root. REOPEN: never'),$(row kid-a "\"$ROOT_SLUG\"" open open 'kid a. REOPEN: alpha')")"
expect_status_matching "count != delivered documents fails closed" 2 "truncated page at offset 0" \
  run --page-limit 4 --fixture-dir "$TRUNC"
# the source stops answering mid-read: a truncated read, not a smaller board
SHORT="$TMP/short-read"
build_healthy "$SHORT"
rm -f "$SHORT/page-1.http"
expect_status_matching "source stops answering mid-read fails closed" 2 "that is a truncated read, not a smaller board" \
  run --page-limit 4 --fixture-dir "$SHORT"
# answering a different offset than the one asked for
SKEW="$TMP/offset-skew"
build_healthy "$SKEW"
page "$SKEW" 1 200 "$(envelope 1 0 4 "$(row deep-a '"kid-a"' open open 'deep a. REOPEN: delta')")"
expect_status_matching "wrong offset echoed fails closed" 2 "server answered a different page" \
  run --page-limit 4 --fixture-dir "$SKEW"
echo

# =============================================================================
# CLAUSE 2 — THE LENS. `.children` is one level. On the live board it scores 181
# of 287. The guard is a fixpoint assertion, not a claim about which lens was
# used, so it catches any walk that stops early.
# =============================================================================
echo "clause 2 — a one-level .children lens must FAIL"
expect_status_matching "--lens children fails closed on a grandchild" 2 "closure is NOT closed under parent_id" \
  run --page-limit 4 --fixture-dir "$HEALTHY" --lens children
expect_status_matching "and it names the rows it dropped" 2 "escaped: deep-a (parent kid-a)" \
  run --page-limit 4 --fixture-dir "$HEALTHY" --lens children
echo

# =============================================================================
# CLAUSE 3 — ENVELOPES. /v1/data fails with error.code, /v1/tasks with `reason`.
# Both parse. Neither is data.
# =============================================================================
echo "clause 3 — a malformed / foreign envelope must FAIL"
TASKSHAPE="$TMP/tasks-envelope"
build_healthy "$TASKSHAPE"
page "$TASKSHAPE" 1 200 '{"ok":false,"reason":"task_not_found"}'
expect_status_matching "a 200 /v1/tasks-shaped failure fails closed" 2 "no \`result\` object" \
  run --page-limit 4 --fixture-dir "$TASKSHAPE"
ARRAY="$TMP/array-body"
build_healthy "$ARRAY"
page "$ARRAY" 1 200 '[]'
expect_status_matching "a 200 whose body is a list fails closed" 2 "not an object" \
  run --page-limit 4 --fixture-dir "$ARRAY"
NOTJSON="$TMP/not-json"
build_healthy "$NOTJSON"
page "$NOTJSON" 1 200 '<html>502 upstream</html>'
expect_status_matching "a 200 that is not JSON fails closed" 2 "unparseable body" \
  run --page-limit 4 --fixture-dir "$NOTJSON"
MISSINGKEY="$TMP/missing-key"
build_healthy "$MISSINGKEY"
page "$MISSINGKEY" 1 200 '{"result":{"count":0,"offset":4,"limit":4}}'
expect_status_matching "result without documents fails closed" 2 "result.documents is missing" \
  run --page-limit 4 --fixture-dir "$MISSINGKEY"
FIVEHUNDRED="$TMP/five-hundred"
build_healthy "$FIVEHUNDRED"
page "$FIVEHUNDRED" 1 500 '{"ok":false,"error":{"code":"internal"}}'
expect_status_matching "a 500 is never a leaf" 2 "a non-2xx is never a leaf" \
  run --page-limit 4 --fixture-dir "$FIVEHUNDRED"
echo

# =============================================================================
# CLAUSE 5 — THE INSTANT. A snapshot or an average, never both.
# =============================================================================
echo "clause 5 — the named instant must be coherent"
DRIFT="$TMP/drifted"
build_healthy "$DRIFT"
# a descendant stamped in the year 3000 lands inside any window this run has
page "$DRIFT" 1 200 "$(envelope 3 4 4 "$(printf '{"_id":"deep-a","_type":"task","_updatedAt":"3000-01-01T00:00:00.000000Z","parent_id":"kid-a","lifecycle_status":"open","disposition":"open","disposition_reason":"deep a. REOPEN: delta"}'),$(row deep-b '"kid-b"' cancelled closed 'deep b. REOPEN: echo'),$(row unrelated 'null' open open 'unrelated. REOPEN: foxtrot')")"
# (a future stamp is outside the window, so it must NOT red — only rows that
# moved INSIDE the window do)
expect_status "a future _updatedAt is not drift" 0 \
  run --page-limit 4 --fixture-dir "$DRIFT"
NOSTAMP="$TMP/no-stamp"
build_healthy "$NOSTAMP"
page "$NOSTAMP" 1 200 "$(envelope 3 4 4 "$(printf '{"_id":"deep-a","_type":"task","parent_id":"kid-a","lifecycle_status":"open","disposition":"open","disposition_reason":"deep a. REOPEN: delta"}'),$(row deep-b '"kid-b"' cancelled closed 'deep b. REOPEN: echo'),$(row unrelated 'null' open open 'unrelated. REOPEN: foxtrot')")"
expect_status_matching "a row with no _updatedAt fails closed" 2 "carries no _updatedAt" \
  run --page-limit 4 --fixture-dir "$NOSTAMP"
BADSTAMP="$TMP/bad-stamp"
build_healthy "$BADSTAMP"
page "$BADSTAMP" 1 200 "$(envelope 3 4 4 "$(printf '{"_id":"deep-a","_type":"task","_updatedAt":"last tuesday","parent_id":"kid-a","lifecycle_status":"open","disposition":"open","disposition_reason":"deep a. REOPEN: delta"}'),$(row deep-b '"kid-b"' cancelled closed 'deep b. REOPEN: echo'),$(row unrelated 'null' open open 'unrelated. REOPEN: foxtrot')")"
expect_status_matching "an unreadable _updatedAt fails closed" 2 "unreadable _updatedAt" \
  run --page-limit 4 --fixture-dir "$BADSTAMP"
DUPES="$TMP/dupes"
build_healthy "$DUPES"
page "$DUPES" 1 200 "$(envelope 3 4 4 "$(row kid-a "\"$ROOT_SLUG\"" open open 'kid a again — the corpus shifted. REOPEN: alpha'),$(row deep-a '"kid-a"' open open 'deep a. REOPEN: delta'),$(row deep-b '"kid-b"' cancelled closed 'deep b. REOPEN: echo')")"
expect_status_matching "a row served twice is an incoherent snapshot" 4 "shifted under pagination" \
  run --page-limit 4 --fixture-dir "$DUPES"
echo

# =============================================================================
# FAIL-CLOSED POPULATIONS. A census with nothing in it has not passed.
# =============================================================================
echo "fail-closed — an empty or rootless population is never a pass"
EMPTY="$TMP/empty"
page "$EMPTY" 0 200 "$(envelope 0 0 4 '')"
expect_status_matching "zero rows fails closed" 2 "empty population" \
  run --page-limit 4 --fixture-dir "$EMPTY"
ROOTLESS="$TMP/rootless"
page "$ROOTLESS" 0 200 "$(envelope 1 0 4 "$(row somebody-else 'null' open open 'nothing to do with the root. REOPEN: never')")"
expect_status_matching "a missing root fails closed" 2 "is not in the" \
  run --page-limit 4 --fixture-dir "$ROOTLESS"
CHILDLESS="$TMP/childless"
page "$CHILDLESS" 0 200 "$(envelope 1 0 4 "$(row "$ROOT_SLUG" 'null' open open 'root with no children. REOPEN: never')")"
expect_status_matching "a childless root fails closed" 2 "zero descendants" \
  run --page-limit 4 --fixture-dir "$CHILDLESS"
echo

# =============================================================================
# THE DONE-CONDITION. It must be able to fail in each of its own directions --
# otherwise the round can be declared done by a predicate that cannot say no.
# =============================================================================
echo "done-condition — each half must be able to say no"
BOILER="$TMP/boilerplate"
build_healthy "$BOILER"
# two rows share a reason verbatim (modulo whitespace): 5 non-empty, 4 distinct
page "$BOILER" 1 200 "$(envelope 3 4 4 "$(row deep-a '"kid-a"' open open 'kid a reason one.   REOPEN:   alpha'),$(row deep-b '"kid-b"' cancelled closed 'deep b reason five. REOPEN: echo'),$(row unrelated 'null' open open 'unrelated. REOPEN: foxtrot')")"
expect_status_matching "duplicate reasons red the predicate" 1 "collapse to 4 hashes" \
  run --page-limit 4 --fixture-dir "$BOILER" --assert-round-done
# ...and the census itself still exits 0: duplicate reasons are a finding, not a
# transport failure.
expect_status "duplicate reasons alone do not red the census" 0 \
  run --page-limit 4 --fixture-dir "$BOILER"
VOCAB="$TMP/off-vocabulary"
build_healthy "$VOCAB"
# uppercase `OPEN` — the exact 67-row split measured on the live board
page "$VOCAB" 1 200 "$(envelope 3 4 4 "$(row deep-a '"kid-a"' open OPEN 'deep a reason four. REOPEN: delta'),$(row deep-b '"kid-b"' cancelled closed 'deep b reason five. REOPEN: echo'),$(row unrelated 'null' open open 'unrelated. REOPEN: foxtrot')")"
expect_status_matching "off-vocabulary disposition reds the predicate" 1 "carry a disposition outside" \
  run --page-limit 4 --fixture-dir "$VOCAB" --assert-round-done
expect_output_contains "and the case split is visible, not averaged" "OPEN                 1" \
  run --page-limit 4 --fixture-dir "$VOCAB"
NOREASONS="$TMP/no-reasons"
build_healthy "$NOREASONS"
page "$NOREASONS" 0 200 "$(envelope 4 0 4 "$(row "$ROOT_SLUG" 'null' open open ''),$(row kid-a "\"$ROOT_SLUG\"" open open ''),$(row kid-b "\"$ROOT_SLUG\"" done closed ''),$(row kid-c "\"$ROOT_SLUG\"" blocked parked '')")"
page "$NOREASONS" 1 200 "$(envelope 2 4 4 "$(row deep-a '"kid-a"' open open ''),$(row deep-b '"kid-b"' cancelled closed '')")"
expect_status_matching "an all-empty board is unstarted, not done" 1 "zero non-empty reasons" \
  run --page-limit 4 --fixture-dir "$NOREASONS" --assert-round-done
echo

# =============================================================================
# CLAUSE 4 — LIVE COVERAGE. Every fixture below EXITS 0 against the census as it
# stood on origin/main before this clause existed, because clauses 1-3 are
# closure-scoped and structurally cannot see a live row that says nothing. Three
# reds and four greens: the reds prove the clause can say no, and the greens
# prove it says no to the RIGHT rows — a clause 4 that reds on terminal rows, or
# on a shared family trigger, would be a different and worse instrument.
# =============================================================================
echo "clause 4 — a LIVE row that says nothing must red the round-done predicate"

# (a) BARE: a live row with no disposition at all. It lands in the `<unset>`
# bucket that clauses 1-3 never read.
BARE="$TMP/live-bare"
build_healthy "$BARE"
page "$BARE" 1 200 "$(envelope 3 4 4 "$(row deep-a '"kid-a"' open '' 'deep a reason four. REOPEN: delta'),$(row deep-b '"kid-b"' cancelled closed 'deep b reason five. REOPEN: echo'),$(row unrelated 'null' open open 'unrelated. REOPEN: foxtrot')")"
expect_status_matching "a live row with no disposition reds the predicate" 1 "LIVE row(s) carry NO disposition" \
  run --page-limit 4 --fixture-dir "$BARE" --assert-round-done
expect_status_matching "and it NAMES the silent row" 1 "deep-a" \
  run --page-limit 4 --fixture-dir "$BARE" --assert-round-done
expect_output_contains "live_bare is a ROW-ID LIST in --json" "$(printf '"live_bare": [\n    "deep-a"\n  ]')" \
  run --page-limit 4 --fixture-dir "$BARE" --json

# (b) an adjudicated live row with no reason: a verdict it cannot prove.
NOREASONLIVE="$TMP/live-adjudicated-no-reason"
build_healthy "$NOREASONLIVE"
page "$NOREASONLIVE" 1 200 "$(envelope 3 4 4 "$(row deep-a '"kid-a"' open closed ''),$(row deep-b '"kid-b"' cancelled closed 'deep b reason five. REOPEN: echo'),$(row unrelated 'null' open open 'unrelated. REOPEN: foxtrot')")"
expect_status_matching "a live verdict with no reason reds the predicate" 1 "carry NO disposition_reason" \
  run --page-limit 4 --fixture-dir "$NOREASONLIVE" --assert-round-done
expect_output_contains "live_adjudicated_no_reason is a ROW-ID LIST in --json" "$(printf '"live_adjudicated_no_reason": [\n    "deep-a"\n  ]')" \
  run --page-limit 4 --fixture-dir "$NOREASONLIVE" --json

# (c) LIVEPARK: a live park with no way back out.
LIVEPARK="$TMP/live-park-no-trigger"
build_healthy "$LIVEPARK"
page "$LIVEPARK" 1 200 "$(envelope 3 4 4 "$(row deep-a '"kid-a"' open parked 'deep a reason four, parked with no way back'),$(row deep-b '"kid-b"' cancelled closed 'deep b reason five. REOPEN: echo'),$(row unrelated 'null' open open 'unrelated. REOPEN: foxtrot')")"
expect_status_matching "a live park with no reopen_trigger reds the predicate" 1 "carry NO structured reopen_trigger" \
  run --page-limit 4 --fixture-dir "$LIVEPARK" --assert-round-done
expect_output_contains "live_park_no_trigger is a ROW-ID LIST in --json" "$(printf '"live_park_no_trigger": [\n    "deep-a"\n  ]')" \
  run --page-limit 4 --fixture-dir "$LIVEPARK" --json

# DECORATED — THE FIXTURE THAT EARNS THE CLAUSE. `kid-c` is a live park whose
# reason SAYS "REOPEN: charlie" in prose while the structured field is DROPPED.
# A trigger test that inherited the prose regex would call this covered. It is
# decoration, and PDS-D336(b) condemns scoring it.
DECORATED="$TMP/decorated-trigger"
build_healthy "$DECORATED"
page "$DECORATED" 0 200 "$(envelope 4 0 4 "$(row "$ROOT_SLUG" 'null' open open 'root row. REOPEN: never'),$(row kid-a "\"$ROOT_SLUG\"" open open 'kid a reason one. REOPEN: alpha'),$(row kid-b "\"$ROOT_SLUG\"" done closed 'kid b reason two. REACTIVATE: bravo'),$(row kid-c "\"$ROOT_SLUG\"" blocked parked 'kid c reason three. REOPEN: charlie')")"
expect_status_matching "prose 'REOPEN: charlie' is NOT a trigger" 1 "carry NO structured reopen_trigger" \
  run --page-limit 4 --fixture-dir "$DECORATED" --assert-round-done
expect_status_matching "and the decorated row is named" 1 "kid-c" \
  run --page-limit 4 --fixture-dir "$DECORATED" --assert-round-done
expect_output_contains "the prose mention is still visible, as DECORATION" "prose-only REOPEN mention       5" \
  run --page-limit 4 --fixture-dir "$DECORATED"

# TERMBARE / TERMPARK — the SAME two mutations on TERMINAL rows. Clause 4 is
# live-scoped: a finished row is allowed to be silent, and a clause that reds
# here would demand the round re-adjudicate history.
echo
echo "clause 4 — but a TERMINAL row is allowed to be silent (live-scoped, not closure-scoped)"
TERMBARE="$TMP/terminal-bare"
build_healthy "$TERMBARE"
page "$TERMBARE" 1 200 "$(envelope 3 4 4 "$(row deep-a '"kid-a"' open open 'deep a reason four. REOPEN: delta'),$(row deep-b '"kid-b"' cancelled '' 'deep b reason five. REOPEN: echo'),$(row unrelated 'null' open open 'unrelated. REOPEN: foxtrot')")"
expect_status "a TERMINAL row with no disposition does not red" 0 \
  run --page-limit 4 --fixture-dir "$TERMBARE" --assert-round-done
TERMPARK="$TMP/terminal-park"
build_healthy "$TERMPARK"
page "$TERMPARK" 1 200 "$(envelope 3 4 4 "$(row deep-a '"kid-a"' open open 'deep a reason four. REOPEN: delta'),$(row deep-b '"kid-b"' cancelled parked 'deep b reason five, parked and finished'),$(row unrelated 'null' open open 'unrelated. REOPEN: foxtrot')")"
expect_status "a TERMINAL park with no reopen_trigger does not red" 0 \
  run --page-limit 4 --fixture-dir "$TERMPARK" --assert-round-done

# SHAREDTRIG — PDS-D336(a), pinned in the other direction. Three live parks, two
# of them sharing ONE trigger verbatim over DISTINCT reasons. Only REASONS must
# be distinct; a family trigger is legitimate and is what the board's best eight
# rows already do. This fixture exists so a later wave cannot quietly tighten
# clause 4(c) into a trigger-distinctness check and break them.
SHAREDTRIG="$TMP/shared-trigger"
build_healthy "$SHAREDTRIG"
page "$SHAREDTRIG" 1 200 "$(envelope 3 4 4 "$(row deep-a '"kid-a"' open parked 'deep a reason four, its own distinct reason' 'REOPEN when the Hetzner rate cap lifts'),$(row deep-b '"kid-b"' open parked 'deep b reason five, a different distinct reason' 'REOPEN when the Hetzner rate cap lifts'),$(row unrelated 'null' open open 'unrelated. REOPEN: foxtrot')")"
expect_status "a family trigger shared over distinct reasons does NOT red" 0 \
  run --page-limit 4 --fixture-dir "$SHAREDTRIG" --assert-round-done
expect_output_contains "all three live parks count as covered" "live parked with NO reopen_trigger     0   (of 3 parked)" \
  run --page-limit 4 --fixture-dir "$SHAREDTRIG"

# TERMDUP — clauses 1-3 were NOT silently rescoped to live. A duplicate reason on
# a TERMINAL row still reds, because distinctness is a property of everything
# ever written.
TERMDUP="$TMP/terminal-duplicate-reason"
build_healthy "$TERMDUP"
page "$TERMDUP" 1 200 "$(envelope 3 4 4 "$(row deep-a '"kid-a"' open open 'deep a reason four. REOPEN: delta'),$(row deep-b '"kid-b"' cancelled closed 'kid b reason two. REACTIVATE: bravo'),$(row unrelated 'null' open open 'unrelated. REOPEN: foxtrot')")"
expect_status_matching "a duplicate reason on a TERMINAL row still reds (1-3 stay closure-scoped)" 1 "collapse to 4 hashes" \
  run --page-limit 4 --fixture-dir "$TERMDUP" --assert-round-done
echo

# =============================================================================
# CLAUSE 6 — THE CLAIMABLE-AND-CLOSED CONTRADICTION (PDS-D372/D373).
#
# Every fixture in this section EXITS 0 against the census as it stood on
# origin/main before the clause existed — verified by running each one against
# the unmodified script first. That is the whole point of the section: clause 4
# COUNTS these rows in its numerator as satisfied (they carry a disposition)
# while `bp task ready` hands them to a worker, so the board is simultaneously
# adjudicated shut and dispatched as work and nothing anywhere says so.
#
# Two reds and three greens. The reds prove the clause can say no on BOTH
# claimable lifecycles. The greens are the load-bearing half: a TERMINAL closed
# row must stay silent (a clause that reds there demands the round re-adjudicate
# history), a LIVE PARK with a structured trigger must stay silent (this is the
# fixture that refuses the parked-inclusive form on the record — it reds the
# CONTROL and SHAREDTRIG, measured 7 of 80), and an OFF-VOCABULARY disposition on
# a claimable row must be treated as LIVE and left to clause 3 (a rule phrased
# `!= 'open'` would sweep 26 rows out of a neighbour epic's queue).
# =============================================================================
echo "clause 6 — a CLAIMABLE row the ledger calls closed must red the predicate"

# (a) OPEN + closed. The plainest form: the queue will hand this row out.
CONTRAOPEN="$TMP/live-closed-on-open"
build_healthy "$CONTRAOPEN"
page "$CONTRAOPEN" 1 200 "$(envelope 3 4 4 "$(row deep-a '"kid-a"' open closed 'deep a reason four, adjudicated shut while still claimable. REOPEN: delta'),$(row deep-b '"kid-b"' cancelled closed 'deep b reason five. REOPEN: echo'),$(row unrelated 'null' open open 'unrelated. REOPEN: foxtrot')")"
expect_status_matching "a live+closed row on \`open\` reds the predicate" 1 "are CLAIMABLE and dispositioned \`closed\`" \
  run --page-limit 4 --fixture-dir "$CONTRAOPEN" --assert-round-done
expect_status_matching "and it NAMES the contradictory row" 1 "deep-a" \
  run --page-limit 4 --fixture-dir "$CONTRAOPEN" --assert-round-done
expect_output_contains "live_contradiction is a ROW-ID LIST in --json, never a count" \
  "$(printf '"live_contradiction": [\n    "deep-a"\n  ]')" \
  run --page-limit 4 --fixture-dir "$CONTRAOPEN" --json

# (b) BLOCKED + closed. `blocked` is claimable-in-principle and appears ONLY in
# the closure, never at level 1 — a clause built from a `.children` vocabulary
# would not even know the value is legal.
CONTRABLOCKED="$TMP/live-closed-on-blocked"
build_healthy "$CONTRABLOCKED"
page "$CONTRABLOCKED" 1 200 "$(envelope 3 4 4 "$(row deep-a '"kid-a"' blocked closed 'deep a reason four, blocked and adjudicated shut. REOPEN: delta'),$(row deep-b '"kid-b"' cancelled closed 'deep b reason five. REOPEN: echo'),$(row unrelated 'null' open open 'unrelated. REOPEN: foxtrot')")"
expect_status_matching "a live+closed row on \`blocked\` reds the predicate too" 1 "are CLAIMABLE and dispositioned \`closed\`" \
  run --page-limit 4 --fixture-dir "$CONTRABLOCKED" --assert-round-done

# (c) TERMINAL + closed — the ordinary, correct shape. `done`/`closed` is what a
# finished row is SUPPOSED to look like, and it must stay green or the clause is
# just "always red".
TERMCLOSED="$TMP/terminal-closed"
build_healthy "$TERMCLOSED"
page "$TERMCLOSED" 1 200 "$(envelope 3 4 4 "$(row deep-a '"kid-a"' done closed 'deep a reason four, finished and shut. REOPEN: delta'),$(row deep-b '"kid-b"' cancelled closed 'deep b reason five. REOPEN: echo'),$(row unrelated 'null' open open 'unrelated. REOPEN: foxtrot')")"
expect_status "a TERMINAL row dispositioned closed does NOT red" 0 \
  run --page-limit 4 --fixture-dir "$TERMCLOSED" --assert-round-done
expect_output_contains "and live_contradiction is empty for it" '"live_contradiction": []' \
  run --page-limit 4 --fixture-dir "$TERMCLOSED" --json

# (d) THE REFUSED FORM. A LIVE park carrying a STRUCTURED reopen_trigger. A park
# awaiting its trigger is not a contradiction; it is a park, and clause 4(c)
# already owns it. Extending clause 6 to `parked` was measured to fail 7 of 80
# checks including the CONTROL (build_healthy's blocked+parked `kid-c`, inherited
# by all 34 fixture dirs) and SHAREDTRIG, the PDS-D336(a) pin. This fixture is
# the tripwire on that.
LIVEPARKOK="$TMP/live-park-with-trigger"
build_healthy "$LIVEPARKOK"
page "$LIVEPARKOK" 1 200 "$(envelope 3 4 4 "$(row deep-a '"kid-a"' open parked 'deep a reason four, parked with a real way back out' 'REOPEN when the Hetzner rate cap lifts'),$(row deep-b '"kid-b"' cancelled closed 'deep b reason five. REOPEN: echo'),$(row unrelated 'null' open open 'unrelated. REOPEN: foxtrot')")"
expect_status "a LIVE park with a structured trigger does NOT red (closed-only)" 0 \
  run --page-limit 4 --fixture-dir "$LIVEPARKOK" --assert-round-done
expect_output_contains "the two live parks are covered and uncontradicted" '"live_contradiction": []' \
  run --page-limit 4 --fixture-dir "$LIVEPARKOK" --json

# (e) THE VOCABULARY TRAP. A claimable row carrying an OFF-VOCABULARY PROSE
# disposition — the literal value 26 `tgw*` rows of a NEIGHBOUR epic carry. It is
# UNRECOGNISED, therefore LIVE, therefore clause 3's business and not clause 6's.
# A rule phrased `disposition IS NOT NULL AND != 'open'` reds here and quietly
# deletes another epic's queue.
OFFVOCABLIVE="$TMP/live-off-vocabulary-prose"
build_healthy "$OFFVOCABLIVE"
page "$OFFVOCABLIVE" 1 200 "$(envelope 3 4 4 "$(row deep-a '"kid-a"' open 'open - demoted child of truth-grip-epic (charter D117)' 'deep a reason four. REOPEN: delta'),$(row deep-b '"kid-b"' cancelled closed 'deep b reason five. REOPEN: echo'),$(row unrelated 'null' open open 'unrelated. REOPEN: foxtrot')")"
expect_output_contains "an off-vocabulary prose disposition is NOT a contradiction" '"live_contradiction": []' \
  run --page-limit 4 --fixture-dir "$OFFVOCABLIVE" --json
expect_status_matching "it is clause 3's business, and clause 3 alone reds it" 1 "carry a disposition outside" \
  run --page-limit 4 --fixture-dir "$OFFVOCABLIVE" --assert-round-done
expect_output_lacks "and clause 6 stays silent about it" "are CLAIMABLE and dispositioned" \
  run --page-limit 4 --fixture-dir "$OFFVOCABLIVE" --assert-round-done
# CASE IS PART OF THE VALUE here too: `CLOSED` is off-vocabulary, so it is
# unrecognised, so it is LIVE. Clause 3 reds it; clause 6 does not pretend to
# know what it meant.
UPPERCLOSED="$TMP/live-uppercase-closed"
build_healthy "$UPPERCLOSED"
page "$UPPERCLOSED" 1 200 "$(envelope 3 4 4 "$(row deep-a '"kid-a"' open CLOSED 'deep a reason four. REOPEN: delta'),$(row deep-b '"kid-b"' cancelled closed 'deep b reason five. REOPEN: echo'),$(row unrelated 'null' open open 'unrelated. REOPEN: foxtrot')")"
expect_output_contains "an uppercase CLOSED is off-vocabulary, not a contradiction" '"live_contradiction": []' \
  run --page-limit 4 --fixture-dir "$UPPERCLOSED" --json
echo

# =============================================================================
# CLAUSE 7 — THE LEDGER LAPSE (PDS-D638). THREE SHAPES, TWO KEYS, AND A MUTANT
# THAT CAN FIRE.
#
# Two waves running, slice rows lapsed to `open` with their work DONE, and each
# debrief wrote the same paragraph. The paragraph becomes an arm here — and the
# arm's whole difficulty is that its shapes DO NOT SHARE A KEY:
#
#   SHAPE A keys on claim.expired_at (+ previous_worker, + a null worker, + no
#   released_at/closed_at): the TTL sweeper's exact fingerprint.
#
#   SHAPE B CANNOT. A shape-B row does NOT carry expired_at BY CONSTRUCTION —
#   the lease is still HELD and the REAP is what writes that field — so a check
#   keyed on expired_at passes VACUOUSLY on shape B 100% of the time, forever.
#   Its only honest key is the HELD LEASE'S AGE against the TTL. And because
#   shape B self-heals into shape A within <= TTL+60s, a live board has no
#   shape-B row most instants: an arm that merely watched the board would be a
#   permanent green that has NEVER ONCE FIRED. So STALELEASE below INJECTS a
#   synthetic in_progress row whose claim.ts_iso is older than the TTL. That
#   fixture is the difference between an arm and a decoration.
#
#   SHAPE C is reported on its own line and never folded: `open` while still
#   wearing a finished claim. A worker-keyed check reads it as HELD; an
#   expiry-keyed check cannot see it at all.
#
# THE GREENS ARE LOAD-BEARING, as everywhere else in this file: a RELEASED
# claim, a FRESH lease and a TERMINAL row wearing an expired claim must all stay
# silent, or the arm is just "always red" and proves nothing when it fires.
# =============================================================================
echo "clause 7 — the ledger lapse, in three shapes that do not share a key"

# `claim_row` is `row` plus the top-level `claim` object /v1/data/query serves
# beside it. The claim is passed as raw JSON so a fixture can express EXACTLY
# which fields the sweeper left behind — which is the entire key of shape A.
claim_row() {
  local id=$1 parent=$2 lifecycle=$3 disposition=$4 reason=$5 claim=$6
  printf '{"_id":"%s","_type":"task","_updatedAt":"2020-01-01T00:00:00.000000Z","parent_id":%s,"lifecycle_status":"%s","disposition":"%s","disposition_reason":"%s","claim":%s}' \
    "$id" "$parent" "$lifecycle" "$disposition" "$reason" "$claim"
}

# The two rows every clause-7 page 1 keeps, so nothing ELSE in the file's
# predicate can red and be mistaken for this clause firing.
CLAUSE7_TAIL="$(row deep-b '"kid-b"' cancelled closed 'deep b reason five. REOPEN: echo'),$(row unrelated 'null' open open 'unrelated. REOPEN: foxtrot')"

# A stale lease and a fresh one. The FRESH one is generated at RUN TIME on
# purpose: a fixture that hard-coded "recently" would rot into a stale lease and
# the green control would flip red on a day nobody was looking.
STALE_TS='2020-01-01T00:00:00.000000Z'
FRESH_TS=$(date -u +%Y-%m-%dT%H:%M:%S.000000Z)

# (a) SHAPE A — reverted to `open` by the sweeper, work evidence still on it.
LAPSEA="$TMP/lapse-shape-a"
build_healthy "$LAPSEA"
page "$LAPSEA" 1 200 "$(envelope 3 4 4 "$(claim_row deep-a '"kid-a"' open open 'deep a reason four. REOPEN: delta' '{"worker":null,"previous_worker":"epic-builder-wave-42","expired_at":"2026-07-30T10:00:00.000000Z","ts_iso":"2026-07-30T09:00:00.000000Z","now":{"text":"gating; branch pushed"}}'),$CLAUSE7_TAIL")"
expect_status_matching "a reverted-to-open lapsed claim reds the predicate" 1 "row(s) are SHAPE A" \
  run --page-limit 4 --fixture-dir "$LAPSEA" --assert-round-done
expect_status_matching "and it NAMES the lapsed row and its remedy" 1 "REMEDY: re-claim and close on the evidence already there: deep-a" \
  run --page-limit 4 --fixture-dir "$LAPSEA" --assert-round-done
expect_output_contains "the work-evidence sub-count is reported beside the shape" \
  "shape A  reverted-to-open after expiry       1   (1 carrying work evidence)" \
  run --page-limit 4 --fixture-dir "$LAPSEA"
expect_output_contains "lapse_shape_a is a ROW-ID LIST in --json, never a count" \
  "$(printf '"lapse_shape_a": [\n    "deep-a"\n  ]')" \
  run --page-limit 4 --fixture-dir "$LAPSEA" --json
expect_output_contains "and the work evidence is its own list" \
  "$(printf '"lapse_shape_a_work_evidence": [\n    "deep-a"\n  ]')" \
  run --page-limit 4 --fixture-dir "$LAPSEA" --json
# A lapsed row with NO now-line is still shape A — the sub-count is a sub-count,
# not the key. A key that demanded work evidence would miss every lapse that
# happened before the worker wrote one.
LAPSEANOEV="$TMP/lapse-shape-a-no-evidence"
build_healthy "$LAPSEANOEV"
page "$LAPSEANOEV" 1 200 "$(envelope 3 4 4 "$(claim_row deep-a '"kid-a"' open open 'deep a reason four. REOPEN: delta' '{"worker":null,"previous_worker":"epic-builder-wave-41","expired_at":"2026-07-30T10:00:00.000000Z","ts_iso":"2026-07-30T09:00:00.000000Z"}'),$CLAUSE7_TAIL")"
expect_output_contains "a lapse with no now-line is still shape A, with 0 evidence" \
  "shape A  reverted-to-open after expiry       1   (0 carrying work evidence)" \
  run --page-limit 4 --fixture-dir "$LAPSEANOEV"

# (b) THE GREENS FOR SHAPE A. A RELEASE writes released_at and a CLOSE writes
# closed_at; only a LAPSE nulls the worker while preserving previous_worker. If
# either of those rows counted, the arm would be reporting ordinary lifecycle as
# a defect.
RELEASED="$TMP/lapse-released-not-lapsed"
build_healthy "$RELEASED"
page "$RELEASED" 1 200 "$(envelope 3 4 4 "$(claim_row deep-a '"kid-a"' open open 'deep a reason four. REOPEN: delta' '{"worker":null,"previous_worker":"epic-builder-wave-42","expired_at":"2026-07-30T10:00:00.000000Z","released_at":"2026-07-30T10:05:00.000000Z","ts_iso":"2026-07-30T09:00:00.000000Z"}'),$CLAUSE7_TAIL")"
expect_status "a RELEASED claim is not a lapse (released_at present)" 0 \
  run --page-limit 4 --fixture-dir "$RELEASED" --assert-round-done
expect_output_contains "and shape A stays empty for it" '"lapse_shape_a": []' \
  run --page-limit 4 --fixture-dir "$RELEASED" --json
# EVERY CONJUNCT OF SHAPE A'S KEY IS LOAD-BEARING, and these three fixtures are
# what make that TRUE rather than asserted. Drop any one of them from the key and
# one of these greens flips red:
#   - no expired_at  -> a vacancy nobody can attribute to the sweeper. The remedy
#     ("re-claim and close on the evidence") rests on the reap having happened;
#     without the stamp there is no evidence it did.
#   - no previous_worker -> a claim object that never named a holder is not a
#     lapse, it is an empty claim.
#   - closed_at present -> the row was CLOSED after the lapse. That is the
#     lifecycle working, not a re-open lie.
NOEXPIRY="$TMP/lapse-vacated-no-expiry"
build_healthy "$NOEXPIRY"
page "$NOEXPIRY" 1 200 "$(envelope 3 4 4 "$(claim_row deep-a '"kid-a"' open open 'deep a reason four. REOPEN: delta' '{"worker":null,"previous_worker":"epic-builder-wave-42","ts_iso":"2026-07-30T09:00:00.000000Z","now":{"text":"gating"}}'),$CLAUSE7_TAIL")"
expect_status "a vacated claim with NO expired_at is not an expiry" 0 \
  run --page-limit 4 --fixture-dir "$NOEXPIRY" --assert-round-done
expect_output_contains "and shape A stays empty without the sweeper's stamp" '"lapse_shape_a": []' \
  run --page-limit 4 --fixture-dir "$NOEXPIRY" --json
NOPREV="$TMP/lapse-no-previous-worker"
build_healthy "$NOPREV"
page "$NOPREV" 1 200 "$(envelope 3 4 4 "$(claim_row deep-a '"kid-a"' open open 'deep a reason four. REOPEN: delta' '{"worker":null,"expired_at":"2026-07-30T10:00:00.000000Z","ts_iso":"2026-07-30T09:00:00.000000Z"}'),$CLAUSE7_TAIL")"
expect_status "an expired claim that never named a holder is not a lapse" 0 \
  run --page-limit 4 --fixture-dir "$NOPREV" --assert-round-done
LAPSETHENCLOSED="$TMP/lapse-then-closed"
build_healthy "$LAPSETHENCLOSED"
page "$LAPSETHENCLOSED" 1 200 "$(envelope 3 4 4 "$(claim_row deep-a '"kid-a"' open open 'deep a reason four. REOPEN: delta' '{"worker":null,"previous_worker":"epic-builder-wave-42","expired_at":"2026-07-30T10:00:00.000000Z","closed_at":"2026-07-30T12:00:00.000000Z","ts_iso":"2026-07-30T09:00:00.000000Z"}'),$CLAUSE7_TAIL")"
expect_status "a lapse that was then CLOSED is the lifecycle working" 0 \
  run --page-limit 4 --fixture-dir "$LAPSETHENCLOSED" --assert-round-done
TERMLAPSE="$TMP/lapse-terminal"
build_healthy "$TERMLAPSE"
page "$TERMLAPSE" 1 200 "$(envelope 3 4 4 "$(claim_row deep-a '"kid-a"' done closed 'deep a reason four, finished. REOPEN: delta' '{"worker":null,"previous_worker":"epic-builder-wave-42","expired_at":"2026-07-30T10:00:00.000000Z","ts_iso":"2026-07-30T09:00:00.000000Z"}'),$CLAUSE7_TAIL")"
expect_status "a TERMINAL row wearing an expired claim does NOT red" 0 \
  run --page-limit 4 --fixture-dir "$TERMLAPSE" --assert-round-done

# (c) SHAPE B — THE ARM THAT WOULD OTHERWISE NEVER FIRE. A synthetic
# `in_progress` row whose lease is older than the TTL. IT CARRIES NO
# `expired_at`, exactly as a live shape-B row cannot: this fixture is what makes
# an expired_at-keyed shape-B check provably vacuous rather than arguably so.
STALELEASE="$TMP/lapse-shape-b-stale-lease"
build_healthy "$STALELEASE"
page "$STALELEASE" 1 200 "$(envelope 3 4 4 "$(claim_row deep-a '"kid-a"' in_progress open 'deep a reason four. REOPEN: delta' "$(printf '{"worker":"epic-builder-that-finished","epoch":3,"ts_iso":"%s","now":{"text":"committing"}}' "$STALE_TS")"),$CLAUSE7_TAIL")"
expect_status_matching "a lease held past the TTL reds the predicate" 1 "row(s) are SHAPE B" \
  run --page-limit 4 --fixture-dir "$STALELEASE" --assert-round-done
expect_status_matching "and its remedy is bp task release, not a re-claim" 1 "REMEDY: \`bp task release\`: deep-a" \
  run --page-limit 4 --fixture-dir "$STALELEASE" --assert-round-done
# THE SUBSTITUTION, PINNED. The fixture that reds shape B carries NO expired_at,
# so an expired_at-keyed shape-B check greens on it — and shape A must ALSO stay
# empty here, or the two shapes would be reading the same key after all.
expect_output_contains "the shape-B row carries NO expired_at, so shape A is empty" '"lapse_shape_a": []' \
  run --page-limit 4 --fixture-dir "$STALELEASE" --json
expect_output_contains "lapse_shape_b is its own ROW-ID LIST" \
  "$(printf '"lapse_shape_b": [\n    "deep-a"\n  ]')" \
  run --page-limit 4 --fixture-dir "$STALELEASE" --json
expect_output_contains "and the arm prints the TTL it judged against" "TTL 2700s, key: instant - claim.ts_iso" \
  run --page-limit 4 --fixture-dir "$STALELEASE"

# THE KEY IS THE TTL, AND THE TTL IS THE SERVER'S. Widen it past the fixture's
# age and the SAME row greens; that is the proof the arm reads a lease age and
# not a hard-coded year.
expect_status "the same stale lease GREENS under a wider TTL" 0 \
  env BARKPARK_TASK_LEASE_TTL_SECONDS=100000000000 \
  bash "$CENSUS" --root "$ROOT_SLUG" --pace 0 --retries 0 --page-limit 4 \
  --fixture-dir "$STALELEASE" --assert-round-done
expect_status_matching "an unreadable TTL env is a usage error, never a fallback" 3 "refusing to fall back" \
  env BARKPARK_TASK_LEASE_TTL_SECONDS=soon \
  bash "$CENSUS" --root "$ROOT_SLUG" --pace 0 --retries 0 --page-limit 4 \
  --fixture-dir "$STALELEASE"

# (d) THE GREEN FOR SHAPE B: a lease taken JUST NOW. A held lease inside its TTL
# is a worker working, not a lapse.
FRESHLEASE="$TMP/lapse-fresh-lease"
build_healthy "$FRESHLEASE"
page "$FRESHLEASE" 1 200 "$(envelope 3 4 4 "$(claim_row deep-a '"kid-a"' in_progress open 'deep a reason four. REOPEN: delta' "$(printf '{"worker":"epic-builder-still-working","epoch":1,"ts_iso":"%s","now":{"text":"building"}}' "$FRESH_TS")"),$CLAUSE7_TAIL")"
expect_status "a lease taken just now does NOT red" 0 \
  run --page-limit 4 --fixture-dir "$FRESHLEASE" --assert-round-done
expect_output_contains "and shape B is empty for it" '"lapse_shape_b": []' \
  run --page-limit 4 --fixture-dir "$FRESHLEASE" --json

# (e) FAIL CLOSED ON A HELD LEASE THAT CANNOT BE PLACED. An `in_progress` row
# held by a worker with no readable claim.ts_iso sits on neither side of the
# TTL, and a row the arm cannot place is never counted as fresh — exit 2,
# exactly as clause 5 does for _updatedAt.
NOLEASETS="$TMP/lapse-no-ts-iso"
build_healthy "$NOLEASETS"
page "$NOLEASETS" 1 200 "$(envelope 3 4 4 "$(claim_row deep-a '"kid-a"' in_progress open 'deep a reason four. REOPEN: delta' '{"worker":"epic-builder-unplaceable","epoch":1}'),$CLAUSE7_TAIL")"
expect_status_matching "a held lease with no ts_iso fails closed" 2 "never counted as fresh" \
  run --page-limit 4 --fixture-dir "$NOLEASETS" --assert-round-done
BADLEASETS="$TMP/lapse-bad-ts-iso"
build_healthy "$BADLEASETS"
page "$BADLEASETS" 1 200 "$(envelope 3 4 4 "$(claim_row deep-a '"kid-a"' in_progress open 'deep a reason four. REOPEN: delta' '{"worker":"epic-builder-unplaceable","ts_iso":"last tuesday"}'),$CLAUSE7_TAIL")"
expect_status_matching "an unreadable ts_iso fails closed too" 2 "cannot be placed on either side" \
  run --page-limit 4 --fixture-dir "$BADLEASETS" --assert-round-done

# (f) SHAPE C — `open` while still wearing a finished claim. It is NEITHER of
# the other two shapes and its remedy is a third thing, so it gets its own line.
SHAPEC="$TMP/lapse-shape-c"
build_healthy "$SHAPEC"
page "$SHAPEC" 1 200 "$(envelope 3 4 4 "$(claim_row deep-a '"kid-a"' open open 'deep a reason four. REOPEN: delta' '{"worker":"epic-builder-wave-40","epoch":2,"ts_iso":"2026-07-29T09:00:00.000000Z","closed_at":"2026-07-29T11:00:00.000000Z"}'),$CLAUSE7_TAIL")"
expect_status_matching "an open row wearing a closed claim reds the predicate" 1 "row(s) are SHAPE C" \
  run --page-limit 4 --fixture-dir "$SHAPEC" --assert-round-done
expect_status_matching "and its remedy is a THIRD thing: clear the stale claim" 1 "REMEDY: clear the stale claim: deep-a" \
  run --page-limit 4 --fixture-dir "$SHAPEC" --assert-round-done
expect_output_contains "shape C is NOT folded into shape A" '"lapse_shape_a": []' \
  run --page-limit 4 --fixture-dir "$SHAPEC" --json
expect_output_contains "shape C is NOT folded into shape B either" '"lapse_shape_b": []' \
  run --page-limit 4 --fixture-dir "$SHAPEC" --json
expect_output_contains "shape C is its own ROW-ID LIST" \
  "$(printf '"lapse_shape_c": [\n    "deep-a"\n  ]')" \
  run --page-limit 4 --fixture-dir "$SHAPEC" --json

# (g) THE CONTROL. A board with no claims at all is silent on all three shapes —
# an arm that reds on the healthy corpus would make every red above meaningless.
expect_status "the healthy corpus is silent on all three shapes" 0 \
  run --page-limit 4 --fixture-dir "$HEALTHY" --assert-round-done
expect_output_contains "shape A reads 0 on a healthy board" \
  "shape A  reverted-to-open after expiry       0" \
  run --page-limit 4 --fixture-dir "$HEALTHY"
expect_output_contains "shape B reads 0 on a healthy board" \
  "shape B  in_progress held past the lease     0" \
  run --page-limit 4 --fixture-dir "$HEALTHY"
expect_output_contains "shape C reads 0 on a healthy board" \
  "shape C  open with a claim never cleared     0" \
  run --page-limit 4 --fixture-dir "$HEALTHY"

# (h) THE LENS IS PRINTED, AND IT IS DERIVED. /v1/data/query answers
# perspective: published, so a lapsed `drafts.` row is invisible to this arm and
# visible to `bp task ls --all`. The perspective is read back off
# result.perspective rather than asserted in a comment.
expect_output_contains "the arm prints the LENS it read, derived from the response" \
  "lens        /v1/data/query perspective:published" \
  run --page-limit 4 --fixture-dir "$HEALTHY"
# THE CAVEAT IS AMENDED, NOT RETIRED (wave 47). It still says the two lenses
# disagree BY CONSTRUCTION -- that part was never in doubt -- but the DIRECTION
# it implied was wrong, and the amendment carries the measurement that settles
# it: shape A 24 -> 27, the +3 being edit shadows of `done` rows. Both halves are
# pinned, so retiring either one reds.
expect_output_contains "the caveat still says the lenses DISAGREE by construction" \
  "the two lenses DISAGREE by construction" \
  run --page-limit 4 --fixture-dir "$HEALTHY"
expect_output_contains "and it now carries the MEASURED direction, not an implication" \
  "shape A 24 -> 27" \
  run --page-limit 4 --fixture-dir "$HEALTHY"
expect_output_contains "and refuses to quote B/C as verified (0 on both lenses)" \
  "UNDISCRIMINATED" \
  run --page-limit 4 --fixture-dir "$HEALTHY"
expect_output_contains "the lens is machine-readable in --json" '"lens_perspective": "published"' \
  run --page-limit 4 --fixture-dir "$HEALTHY" --json
# A source that does NOT say which perspective it answered with is reported as
# `<unset>`, never assumed to be published.
NOPERSP="$TMP/lapse-no-perspective"
build_healthy "$NOPERSP"
page "$NOPERSP" 0 200 '{"result":{"count":4,"offset":0,"limit":4,"documents":['"$(row "$ROOT_SLUG" 'null' open open 'root row. REOPEN: never'),$(row kid-a "\"$ROOT_SLUG\"" open open 'kid a reason one. REOPEN: alpha'),$(row kid-b "\"$ROOT_SLUG\"" done closed 'kid b reason two. REACTIVATE: bravo'),$(row kid-c "\"$ROOT_SLUG\"" blocked parked 'kid c reason three. REOPEN: charlie' 'TRIGGER: charlie ships')"']}}'
expect_output_contains "a source that names no perspective is <unset>, not assumed" \
  "perspective:<unset>+published" \
  run --page-limit 4 --fixture-dir "$NOPERSP"
echo

# =============================================================================
# CLAUSE 4(a) — THE ROUND ANCHOR (PDS-D364/D365). 4(a) unanchored is
# structurally unreachable by any round that discovers work: a row is BORN bare,
# so a round that files one row can never certify. The anchor says WHICH ROUND
# the clause is asking about — and the danger it introduces is the opposite one,
# that a round seals itself by moving the anchor. So the reds below are as
# important as the greens: an argv anchor is REFUSED, an unresolvable Paper
# FAILS CLOSED, and a row the predicate cannot place FAILS CLOSED.
# =============================================================================
echo "clause 4(a) — the round anchor is DERIVED, and it defers rather than excuses"
WAVE_SLUG="pds-wave-26-fixture"
ANCHOR_TS="2025-01-01T00:00:00.000000Z"

# ANCHORED — `deep-a` is a LIVE BARE row BORN IN THE YEAR 2030: residue of any
# round anchored before then, in scope for any round anchored after.
ANCHORED="$TMP/anchored"
build_healthy "$ANCHORED"
page "$ANCHORED" 1 200 "$(envelope 3 4 4 "$(row deep-a '"kid-a"' open '' 'deep a reason four. REOPEN: delta' '' '2030-01-01T00:00:00.000000Z'),$(row deep-b '"kid-b"' cancelled closed 'deep b reason five. REOPEN: echo'),$(row unrelated 'null' open open 'unrelated. REOPEN: foxtrot')")"
paper "$ANCHORED" "$WAVE_SLUG" 200 "$(printf '{"result":{"_id":"%s","_type":"paper","_createdAt":"%s"}}' "$WAVE_SLUG" "$ANCHOR_TS")"

# UNANCHORED, the wave-25 behaviour, unchanged: the newborn row reds the round.
expect_status_matching "unanchored, a newborn bare row still reds 4(a)" 1 "LIVE row(s) carry NO disposition" \
  run --page-limit 4 --fixture-dir "$ANCHORED" --assert-round-done
# ANCHORED ON THE WAVE PAPER: the same row is DEFERRED, and NAMED while it is.
expect_status "--anchor-from-paper defers the newborn row and the round certifies" 0 \
  run --page-limit 4 --fixture-dir "$ANCHORED" --assert-round-done --anchor-from-paper "$WAVE_SLUG"
expect_output_contains "the residue is an ENUMERATED NAMED list, not a count" "residue: deep-a" \
  run --page-limit 4 --fixture-dir "$ANCHORED" --assert-round-done --anchor-from-paper "$WAVE_SLUG"
expect_output_contains "the derived anchor is printed with its provenance" "paper/$WAVE_SLUG _createdAt $ANCHOR_TS" \
  run --page-limit 4 --fixture-dir "$ANCHORED" --anchor-from-paper "$WAVE_SLUG"
expect_output_contains "live_bare_residue is a ROW-ID LIST in --json" "$(printf '"live_bare_residue": [\n    "deep-a"\n  ]')" \
  run --page-limit 4 --fixture-dir "$ANCHORED" --anchor-from-paper "$WAVE_SLUG" --json
# ...and 4(a)'s DENOMINATOR is still the whole live board: deferring a row must
# not quietly shrink what the clause claims to have covered. The NUMERATOR is
# literal in the other direction (review, wave 26): a deferred row does NOT
# carry a disposition, so it is not counted as one. 3 live rows, 1 deferred,
# 2 actually dispositioned -> "2/3 PASS" plus the named residue line. Printing
# "3/3" here would be a success claim about a row nobody looked at, which is the
# defect class this whole epic exists to kill.
expect_output_contains "4(a)'s denominator is the WHOLE live board and its numerator is literal" \
  "live rows carrying a disposition               2/3" \
  run --page-limit 4 --fixture-dir "$ANCHORED" --assert-round-done --anchor-from-paper "$WAVE_SLUG"
expect_output_contains "the deferred row is NOT counted as dispositioned" \
  "deferred to the next round (RESIDUE)        1" \
  run --page-limit 4 --fixture-dir "$ANCHORED" --assert-round-done --anchor-from-paper "$WAVE_SLUG"

# TERMINATION. The same row is IN SCOPE for the next round: anchor after its
# birth and it reds again. Residue is deferred by exactly one round, never
# forever — this is the fixture that would catch an anchor that hides rows.
expect_status_matching "the residue is IN SCOPE for the NEXT round" 1 "LIVE row(s) carry NO disposition" \
  run --page-limit 4 --fixture-dir "$ANCHORED" --assert-round-done --anchor 2031-01-01T00:00:00Z

# TERMINATION, the other half: adjudicating the residue GREENS the round with or
# without an anchor, and files no new rows (the closure is the same 5).
ADJUDICATED="$TMP/anchored-adjudicated"
build_healthy "$ADJUDICATED"
page "$ADJUDICATED" 1 200 "$(envelope 3 4 4 "$(row deep-a '"kid-a"' open open 'deep a reason four, now adjudicated. REOPEN: delta' '' '2030-01-01T00:00:00.000000Z'),$(row deep-b '"kid-b"' cancelled closed 'deep b reason five. REOPEN: echo'),$(row unrelated 'null' open open 'unrelated. REOPEN: foxtrot')")"
paper "$ADJUDICATED" "$WAVE_SLUG" 200 "$(printf '{"result":{"_createdAt":"%s"}}' "$ANCHOR_TS")"
expect_status "adjudicated residue certifies UNANCHORED too" 0 \
  run --page-limit 4 --fixture-dir "$ADJUDICATED" --assert-round-done
expect_status "adjudicated residue certifies anchored, with zero residue" 0 \
  run --page-limit 4 --fixture-dir "$ADJUDICATED" --assert-round-done --anchor 2031-01-01T00:00:00Z
expect_output_contains "adjudicating filed no new rows (closure unchanged)" "closure     5 descendants" \
  run --page-limit 4 --fixture-dir "$ADJUDICATED" --anchor-from-paper "$WAVE_SLUG"
expect_output_contains "and the residue line reads 0" "deferred to the next round (RESIDUE)        0" \
  run --page-limit 4 --fixture-dir "$ADJUDICATED" --assert-round-done --anchor-from-paper "$WAVE_SLUG"

# FAIL CLOSED ON A ROW THE PREDICATE CANNOT PLACE — exactly as clause 5 does for
# _updatedAt. A live bare row with no readable birth instant sits on neither side
# of the anchor, and an unplaceable row is never excused into the residue.
NOBIRTH="$TMP/anchored-no-createdat"
build_healthy "$NOBIRTH"
page "$NOBIRTH" 1 200 "$(envelope 3 4 4 "$(row deep-a '"kid-a"' open '' 'deep a reason four. REOPEN: delta'),$(row deep-b '"kid-b"' cancelled closed 'deep b reason five. REOPEN: echo'),$(row unrelated 'null' open open 'unrelated. REOPEN: foxtrot')")"
paper "$NOBIRTH" "$WAVE_SLUG" 200 "$(printf '{"result":{"_createdAt":"%s"}}' "$ANCHOR_TS")"
expect_status_matching "a bare live row with NO _createdAt fails closed under an anchor" 2 "cannot place it" \
  run --page-limit 4 --fixture-dir "$NOBIRTH" --assert-round-done --anchor-from-paper "$WAVE_SLUG"
# ...and the SAME fixture unanchored is exit 1, not 2: the birth read fires only
# under an anchor, so no pre-existing fixture can be broken by it.
expect_status_matching "the same fixture unanchored is a plain 4(a) red" 1 "LIVE row(s) carry NO disposition" \
  run --page-limit 4 --fixture-dir "$NOBIRTH" --assert-round-done
BADBIRTH="$TMP/anchored-bad-createdat"
build_healthy "$BADBIRTH"
page "$BADBIRTH" 1 200 "$(envelope 3 4 4 "$(row deep-a '"kid-a"' open '' 'deep a reason four. REOPEN: delta' '' 'last tuesday'),$(row deep-b '"kid-b"' cancelled closed 'deep b reason five. REOPEN: echo'),$(row unrelated 'null' open open 'unrelated. REOPEN: foxtrot')")"
expect_status_matching "an unreadable _createdAt fails closed under an anchor" 2 "cannot place it" \
  run --page-limit 4 --fixture-dir "$BADBIRTH" --assert-round-done --anchor 2031-01-01T00:00:00Z

# THE ANCHOR RESOLVER FAILS CLOSED IN EVERY DIRECTION. It NEVER falls back to
# now(): an anchor at now() excuses every row the round just filed.
echo
echo "clause 4(a) — an anchor that cannot be resolved is never a default"
ANCHOR404="$TMP/anchor-404"
build_healthy "$ANCHOR404"
paper "$ANCHOR404" "$WAVE_SLUG" 404 '{"ok":false,"error":{"code":"not_found"}}'
expect_status_matching "a 404 wave Paper fails closed" 2 "refusing to fall back to now()" \
  run --page-limit 4 --fixture-dir "$ANCHOR404" --assert-round-done --anchor-from-paper "$WAVE_SLUG"
ANCHORBAD="$TMP/anchor-unreadable"
build_healthy "$ANCHORBAD"
paper "$ANCHORBAD" "$WAVE_SLUG" 200 '{"result":{"_createdAt":"last tuesday"}}'
expect_status_matching "an unreadable Paper _createdAt fails closed" 2 "is not an anchor" \
  run --page-limit 4 --fixture-dir "$ANCHORBAD" --assert-round-done --anchor-from-paper "$WAVE_SLUG"
ANCHORNONE="$TMP/anchor-no-createdat"
build_healthy "$ANCHORNONE"
paper "$ANCHORNONE" "$WAVE_SLUG" 200 '{"result":{"_id":"pds-wave-26-fixture"}}'
expect_status_matching "a Paper with no _createdAt at all fails closed" 2 "missing or unreadable _createdAt" \
  run --page-limit 4 --fixture-dir "$ANCHORNONE" --assert-round-done --anchor-from-paper "$WAVE_SLUG"
ANCHORENV="$TMP/anchor-foreign-envelope"
build_healthy "$ANCHORENV"
paper "$ANCHORENV" "$WAVE_SLUG" 200 '{"ok":false,"reason":"paper_not_found"}'
expect_status_matching "a cleanly-parsing failure envelope is not an anchor" 2 "no \`result\` object resolving anchor Paper" \
  run --page-limit 4 --fixture-dir "$ANCHORENV" --assert-round-done --anchor-from-paper "$WAVE_SLUG"
expect_status_matching "a Paper the source does not serve at all fails closed" 2 "unresolvable anchor is never a default" \
  run --page-limit 4 --fixture-dir "$HEALTHY" --assert-round-done --anchor-from-paper "$WAVE_SLUG"

# =============================================================================
# CLAUSE 4(a) — THE ANCHOR IS BOUND TO THE ROUND IT CERTIFIES (wave 26's own
# named residual, paid in wave 28).
#
# Deriving the instant from a Paper closed only half the hole: NOTHING checked
# that the Paper IS this round's. Passing an EARLIER wave's slug yields an
# EARLIER anchor, so MORE rows fall after it and are DEFERRED as residue -- a
# greener 4(a) bought by MOVING THE BOUNDARY instead of adjudicating the rows.
#
# THE MUTATION IS THE PROOF, AND IT IS THE SAME ROW TWICE. `$BOUND` is one
# fixture whose ROOT declares `wave_paper: $WAVE_SLUG`. Anchored on that slug it
# certifies; anchored on `$OLD_SLUG` -- an older Paper the same fixture serves,
# under which `deep-a` is residue just the same, so the OLD census exits 0 on
# this exact invocation -- it must now be REFUSED. A binding that only printed
# the slug it used would pass the first and fail the second.
# =============================================================================
echo
echo "clause 4(a) — the anchor is BOUND to the round being certified"
OLD_SLUG="pds-wave-25-fixture"
OLD_ANCHOR_TS="2024-01-01T00:00:00.000000Z"

BOUND="$TMP/anchor-bound"
build_bound "$BOUND" "$WAVE_SLUG"
paper "$BOUND" "$WAVE_SLUG" 200 "$(printf '{"result":{"_id":"%s","_type":"paper","_createdAt":"%s"}}' "$WAVE_SLUG" "$ANCHOR_TS")"
paper "$BOUND" "$OLD_SLUG" 200 "$(printf '{"result":{"_id":"%s","_type":"paper","_createdAt":"%s"}}' "$OLD_SLUG" "$OLD_ANCHOR_TS")"

# THE DEFAULT IS THE BINDING. No anchor flag at all: the round names its own
# Paper, so the census reads it and certifies -- and the SAME fixture without a
# declared wave_paper ($ANCHORED, above) reds 4(a), which is what proves the
# anchor came from the field and not from the flag.
expect_status "the anchor is DERIVED from the root's wave_paper with no flag at all" 0 \
  run --page-limit 4 --fixture-dir "$BOUND" --assert-round-done
expect_output_contains "and the derivation names the FIELD it came from" \
  "epic $ROOT_SLUG wave_paper=$WAVE_SLUG" \
  run --page-limit 4 --fixture-dir "$BOUND"
expect_output_contains "the binding is STATED, never left to be assumed" \
  "BOUND to the round" \
  run --page-limit 4 --fixture-dir "$BOUND"
expect_output_contains "the resolved slug is machine-readable in --json" \
  "\"round_anchor_slug\": \"$WAVE_SLUG\"" \
  run --page-limit 4 --fixture-dir "$BOUND" --json
expect_output_contains "and so is the binding verdict" \
  '"round_anchor_binding": "bound"' \
  run --page-limit 4 --fixture-dir "$BOUND" --json

# THE DEFECT, RED. This invocation exits 0 against the census as it stood before
# this change -- the older Paper resolves, deep-a is deferred, the round
# certifies -- which is exactly the silent boundary move.
expect_status_matching "an EARLIER wave's Paper is REFUSED, not silently honoured" 3 \
  "does not match the round being certified" \
  run --page-limit 4 --fixture-dir "$BOUND" --assert-round-done --anchor-from-paper "$OLD_SLUG"
expect_status_matching "and the refusal NAMES the slug the round declares" 3 \
  "declares \`wave_paper: $WAVE_SLUG\`" \
  run --page-limit 4 --fixture-dir "$BOUND" --assert-round-done --anchor-from-paper "$OLD_SLUG"
expect_status_matching "and it says what the older anchor would have bought" 3 \
  "MOVING THE BOUNDARY" \
  run --page-limit 4 --fixture-dir "$BOUND" --anchor-from-paper "$OLD_SLUG"
# The round's OWN Paper on argv is still accepted: the refusal is keyed on
# DISAGREEMENT, not on the flag being present.
expect_status "the round's OWN Paper is accepted on argv too" 0 \
  run --page-limit 4 --fixture-dir "$BOUND" --assert-round-done --anchor-from-paper "$WAVE_SLUG"

# THE OVERRIDE EXISTS AND IT IS LOUD. An escape hatch that did not print would
# be the original hole with one more flag in front of it.
expect_status "--anchor-unbound accepts the divergence" 0 \
  run --page-limit 4 --fixture-dir "$BOUND" --assert-round-done --anchor-from-paper "$OLD_SLUG" --anchor-unbound
expect_output_contains "and it SAYS SO in the human render" "ANCHOR UNBOUND" \
  run --page-limit 4 --fixture-dir "$BOUND" --anchor-from-paper "$OLD_SLUG" --anchor-unbound
expect_output_contains "and in the payload, as an override" '"round_anchor_binding": "override"' \
  run --page-limit 4 --fixture-dir "$BOUND" --anchor-from-paper "$OLD_SLUG" --anchor-unbound --json
expect_status_matching "a flag that overrides nothing is refused" 3 "overrides nothing" \
  run --page-limit 4 --fixture-dir "$BOUND" --anchor-unbound

# A ROOT THAT DECLARES NOTHING BINDS NOTHING -- and that is REPORTED, never read
# as agreement. This is the shape every pre-existing fixture in this file has,
# so it is also the check that says why none of them changed.
expect_output_contains "a root with no wave_paper binds nothing, and says that too" \
  '"round_anchor_binding": "unverifiable"' \
  run --page-limit 4 --fixture-dir "$ANCHORED" --anchor-from-paper "$WAVE_SLUG" --json

# THE OPT-OUT GOES ONE WAY ONLY: --no-anchor is the UNANCHORED clause, which
# defers nothing, so it can never seal a round.
expect_status_matching "--no-anchor opts back INTO the stricter clause" 1 \
  "LIVE row(s) carry NO disposition" \
  run --page-limit 4 --fixture-dir "$BOUND" --assert-round-done --no-anchor
expect_status_matching "--no-anchor with an anchor flag is a usage error" 3 "mutually exclusive" \
  run --page-limit 4 --fixture-dir "$BOUND" --no-anchor --anchor-from-paper "$WAVE_SLUG"

# THE DEFAULT FAILS CLOSED TOO. A root that declares a Paper the source cannot
# serve is an UNRESOLVABLE anchor, and an unresolvable anchor is never a default
# -- least of all now that the default is the one nobody types.
BOUND404="$TMP/anchor-bound-unserved"
build_bound "$BOUND404" "$WAVE_SLUG"
expect_status_matching "a declared wave_paper the source cannot serve fails closed" 2 \
  "unresolvable anchor is never a default" \
  run --page-limit 4 --fixture-dir "$BOUND404"

# ...AND IT STILL TERMINATES. The deferred row is IN SCOPE for the next round,
# bound anchor or not.
expect_status_matching "the residue is IN SCOPE for the NEXT round, bound too" 1 \
  "LIVE row(s) carry NO disposition" \
  run --page-limit 4 --fixture-dir "$BOUND" --assert-round-done --anchor 2031-01-01T00:00:00Z

# CLAUSE 5 IS ORTHOGONAL. The anchor is the ROUND window; clause 5 asserts the
# census's own READ window. Widening clause 5 to the round window would trip on
# every residue write and make a certifying run impossible — so the racing
# fixture must exit 4 IDENTICALLY with and without an anchor.
echo
echo "clause 4(a) — the round window and clause 5's read window stay orthogonal"
expect_status_matching "a racing corpus is exit 4 WITHOUT an anchor" 4 "shifted under pagination" \
  run --page-limit 4 --fixture-dir "$DUPES"
paper "$DUPES" "$WAVE_SLUG" 200 "$(printf '{"result":{"_createdAt":"%s"}}' "$ANCHOR_TS")"
expect_status_matching "the SAME racing corpus is exit 4 WITH one" 4 "shifted under pagination" \
  run --page-limit 4 --fixture-dir "$DUPES" --assert-round-done --anchor-from-paper "$WAVE_SLUG"
expect_status_matching "an unreadable _updatedAt still fails closed under an anchor" 2 "unreadable _updatedAt" \
  run --page-limit 4 --fixture-dir "$BADSTAMP" --anchor 2031-01-01T00:00:00Z
echo

# =============================================================================
# --json IS THE MACHINE CHANNEL. Every other helper in this file captures
# `2>&1`, which is precisely why the census could write its human ROUND-DONE
# PREDICATE block onto the same stdout as its JSON payload for two waves without
# one fixture noticing: `jq -e .` exited 5 with "Invalid numeric literal", and
# the GREEN path was poisoned identically — a healthy fixture exited 0 and jq
# still failed. The certificate was unpipeable exactly when it certified.
#
# expect_json_stdout is the only helper that separates the streams, and it takes
# the census's OWN exit code rather than a pipeline's.
# =============================================================================
echo "--json — stdout is one JSON document, on the red path AND on the green one"
expect_json_stdout "--json alone is pipeable" 0 \
  run --page-limit 4 --fixture-dir "$HEALTHY" --json
expect_json_stdout "--json --assert-round-done is pipeable WHEN IT CERTIFIES" 0 \
  run --page-limit 4 --fixture-dir "$HEALTHY" --json --assert-round-done
expect_json_stdout "--json --assert-round-done is pipeable when it REFUSES" 1 \
  run --page-limit 4 --fixture-dir "$CONTRAOPEN" --json --assert-round-done
# THE EXIT-4 PAYLOAD IS NOT REGRESSED. Clause 5's incoherence check runs AFTER
# the emit, so a failing run still carries its report. Computing the predicate
# after the emit instead of before it turns this into 0 bytes and jq exit 4 —
# a fresh honesty regression inside the honesty fix, which is why the predicate
# is a pure function called BEFORE the single emit site.
expect_json_stdout "an INCOHERENT run still emits its full payload (exit 4)" 4 \
  run --page-limit 4 --fixture-dir "$DUPES" --json
# THE PAYLOAD CARRIES A MACHINE VERDICT, not just counts. A scripted consumer
# that had to scrape "VERDICT: ROUND DONE" out of a text stream had no machine
# path at all.
expect_output_contains "round_done is false when the predicate refuses" '"round_done": false' \
  run --page-limit 4 --fixture-dir "$CONTRAOPEN" --json
expect_output_contains "and round_done_failures names the failing clause" "are CLAIMABLE and dispositioned" \
  run --page-limit 4 --fixture-dir "$CONTRAOPEN" --json
expect_output_contains "round_done is true on a healthy board" '"round_done": true' \
  run --page-limit 4 --fixture-dir "$HEALTHY" --json
expect_output_contains "and round_done_failures is then empty" '"round_done_failures": []' \
  run --page-limit 4 --fixture-dir "$HEALTHY" --json
# ...AND THE HUMAN MODE KEEPS ITS HUMAN STREAM. Routing the predicate to stderr
# UNCONDITIONALLY would fix the --json stream by splitting the DEFAULT render
# across two: the report on stdout, the verdict it exists to deliver on stderr,
# so `census.sh --assert-round-done > report.txt` captures everything except the
# answer. Without --json, stdout must still carry both.
expect_stdout_only_contains "without --json the predicate rides stdout with its report" \
  "ROUND-DONE PREDICATE" 0 run --page-limit 4 --fixture-dir "$HEALTHY" --assert-round-done
expect_stdout_only_contains "and so does the certifying verdict" \
  "VERDICT: ROUND DONE" 0 run --page-limit 4 --fixture-dir "$HEALTHY" --assert-round-done
echo

# =============================================================================
# THE DENOMINATOR AND THE REFUSAL (wave 47). A census that prints one number and
# names nothing outside it is a claim about a population it never looked outside
# of. Two arms, both DERIVED, both mutation-proven here over FIXTURES -- never
# against the live board, whose numbers move while this wave files rows.
#
# THE MUTATION IS THE PROOF. `pds-stray-open` is ONE row built twice: once
# parented OUTSIDE the closure (it must be named as a blind spot) and once
# INSIDE it (it must vanish from the block and land in the closure instead). An
# arm that printed a transcribed name would pass the first and fail the second.
# =============================================================================
echo "denominator + blind spots — derived, named, and mutation-proven"
BLIND_OUT="$TMP/blind-outside"
build_blind "$BLIND_OUT" '"foreign-epic"'
build_blind_drafts "$BLIND_OUT"

# THE DENOMINATOR NAMES ITS LENS AND ITS INSTANT. `open` is 2 here (kid-a,
# deep-a) -- COUNTED, and printed beside the rule that counted it.
expect_output_contains "the denominator is printed with its LENS named" \
  "open rows in the closure             2   lens: published + lifecycle_status == \`open\` (case-exact)" \
  run --page-limit 4 --fixture-dir "$BLIND_OUT"
expect_output_contains "and it refuses the two rejected keys by name" \
  "NOT live/non-terminal" \
  run --page-limit 4 --fixture-dir "$BLIND_OUT"
expect_output_contains "and it carries the command that re-derives it" \
  "re-derive   bash scripts/pds-ledger-census.sh" \
  run --page-limit 4 --fixture-dir "$BLIND_OUT"
# THE GUARD THIS INSTRUMENT HAS, NOT THE ONE A READER WOULD ASSUME. Measured:
# `echo scripts/pds-ledger-census.sh | bash scripts/elixir-path-escape-check.sh
# --match test` answers false; the same command answers true for
# scripts/pds-door-census.sh. So CI never runs these checks.
expect_output_contains "the UNGATED limit is printed, not left to be assumed" \
  "The REQUIRED Elixir" \
  run --page-limit 4 --fixture-dir "$BLIND_OUT"

# ARM 1 -- OUTSIDE THE CLOSURE, BY NAME.
expect_output_contains "a PDS-slugged row on a foreign parent is NAMED" \
  "pds-stray-open   (open, parent foreign-epic)" \
  run --page-limit 4 --fixture-dir "$BLIND_OUT"
expect_output_contains "and a TERMINAL one outside is counted APART, not as hidden work" \
  "+ 1 terminal row(s) outside the closure" \
  run --page-limit 4 --fixture-dir "$BLIND_OUT"
expect_output_contains "and the slug-prefix heuristic is declared as one" \
  "LIMIT: keyed on a SLUG PREFIX" \
  run --page-limit 4 --fixture-dir "$BLIND_OUT"

# THE MUTATION. The SAME row, re-parented INSIDE the closure: it must leave the
# block entirely and be counted by it instead.
BLIND_IN="$TMP/blind-inside"
build_blind "$BLIND_IN" '"kid-a"'
build_blind_drafts "$BLIND_IN"
expect_output_lacks "re-parented INSIDE the closure, it is no longer a blind spot" \
  "pds-stray-open   (open, parent" \
  run --page-limit 4 --fixture-dir "$BLIND_IN"
expect_output_contains "it is COUNTED instead -- the closure grew by one" \
  "closure     6 descendants" \
  run --page-limit 4 --fixture-dir "$BLIND_IN"
expect_output_contains "and the denominator grew with it" \
  "open rows in the closure             3" \
  run --page-limit 4 --fixture-dir "$BLIND_IN"
expect_output_contains "with arm 1 now empty, and saying so" \
  "(1) OUTSIDE THE CLOSURE      0" \
  run --page-limit 4 --fixture-dir "$BLIND_IN"

# ARM 2 -- THE DRAFTS LENS, SPLIT. A never-published row is HIDDEN WORK; a draft
# whose published twin is finished is an EDIT SHADOW. Summing them overcounts,
# which is exactly how 379 was reached on the live board.
expect_output_contains "a never-published draft is named as HIDDEN WORK" \
  "drafts.pds-hidden-x   (no published twin)" \
  run --page-limit 4 --fixture-dir "$BLIND_OUT"
expect_output_contains "a draft over a DONE twin is named a PHANTOM, with the twin" \
  "drafts.kid-b   (published twin: done)" \
  run --page-limit 4 --fixture-dir "$BLIND_OUT"
expect_output_contains "and phantoms are called edit shadows, not work" \
  "an EDIT SHADOW, never hidden work. Adding these to the denominator OVERCOUNTS." \
  run --page-limit 4 --fixture-dir "$BLIND_OUT"
expect_output_contains "a draft over a LIVE twin is neither -- it is already counted" \
  "drafts.kid-a   (published twin: open)" \
  run --page-limit 4 --fixture-dir "$BLIND_OUT"
expect_output_lacks "a draft OUTSIDE the closure is not this epic's blind spot" \
  "drafts.foreign" \
  run --page-limit 4 --fixture-dir "$BLIND_OUT"
# THE ARITHMETIC IS THE WHOLE POINT: the honest total adds the never-published
# row and NOT the phantom. If the split collapsed, this line would read 4.
expect_output_contains "the honest total adds hidden work and NOT the phantom" \
  "honest total                         3   = 2 + 1 never-published open row(s) below" \
  run --page-limit 4 --fixture-dir "$BLIND_OUT"
expect_output_contains "and the overcount is shown as the overcount it is" \
  "OVERCOUNT if phantoms added          4   1 phantom(s) are edit shadows" \
  run --page-limit 4 --fixture-dir "$BLIND_OUT"
expect_output_contains "clause 7's drafts delta is MEASURED on this run, not asserted" \
  "THIS RUN: drafts-lens delta  A +0  B +0  C +0" \
  run --page-limit 4 --fixture-dir "$BLIND_OUT"
expect_output_contains "the blind spots are machine-readable in --json" \
  '"id": "drafts.pds-hidden-x"' \
  run --page-limit 4 --fixture-dir "$BLIND_OUT" --json

# THE UNREAD STATE IS AN ABSENCE, NEVER A ZERO. Two ways to lose the lens, and
# both must SAY so: a source that cans no drafts page at all, and one that
# answers `published` to a perspective=drafts request -- which is precisely what
# the API does to an anonymous or public-read caller, silently.
expect_output_contains "no drafts fixture at all is UNREAD, not zero" \
  "(2) NEVER PUBLISHED      UNREAD   source offers no drafts perspective" \
  run --page-limit 4 --fixture-dir "$HEALTHY"
expect_output_contains "and the honest total is then UNMEASURED, not printed anyway" \
  "honest total                     UNMEASURED" \
  run --page-limit 4 --fixture-dir "$HEALTHY"
IGNORED="$TMP/blind-lens-ignored"
build_blind "$IGNORED" '"foreign-epic"'
drafts_page "$IGNORED" 0 200 "$(drafts_envelope 1 0 4 published "$(row drafts.pds-hidden-x '"kid-a"' open open 'pinned to published. REOPEN: mike')")"
expect_output_contains "a source that IGNORES the lens is UNREAD, never counted as 0" \
  "the lens was IGNORED, so the never-published class is UNMEASURED, not zero" \
  run --page-limit 4 --fixture-dir "$IGNORED"
expect_output_lacks "and the row it did serve is NOT reported as hidden work" \
  "drafts.pds-hidden-x   (no published twin)" \
  run --page-limit 4 --fixture-dir "$IGNORED"

# THE SOFTENING IS SCOPED TO THE FIRST PAGE AND TO NOTHING ELSE. A drafts read
# that starts and then stops is a TRUNCATED READ and still fails closed -- the
# same discipline the published read has always had.
TRUNCDRAFTS="$TMP/blind-drafts-truncated"
build_blind "$TRUNCDRAFTS" '"foreign-epic"'
drafts_page "$TRUNCDRAFTS" 0 200 "$(drafts_envelope 4 0 4 drafts "$(row drafts.pds-hidden-x '"kid-a"' open open 'one. REOPEN: november'),$(row drafts.kid-b "\"$ROOT_SLUG\"" open open 'two. REOPEN: oscar'),$(row drafts.kid-a "\"$ROOT_SLUG\"" open open 'three. REOPEN: papa'),$(row drafts.foreign 'null' open open 'four. REOPEN: quebec')")"
expect_status_matching "a TRUNCATED drafts read still fails closed" 2 \
  "that is a truncated read, not a smaller board" \
  run --page-limit 4 --fixture-dir "$TRUNCDRAFTS"
# ...and so does a drafts page that errors. A 500 on the second lens is not an
# absence, and smoothing it over is the defect this whole file refuses.
FIVEDRAFTS="$TMP/blind-drafts-500"
build_blind "$FIVEDRAFTS" '"foreign-epic"'
drafts_page "$FIVEDRAFTS" 0 500 '{"ok":false}'
expect_status_matching "a 500 on the drafts read is never an absence" 2 \
  "a non-2xx is never a leaf" \
  run --page-limit 4 --fixture-dir "$FIVEDRAFTS"

# THE PAGER'S OWN BLIND SPOT IS STATED, NOT FIXED. Explicit offsets over a
# mutating key can skip a row, and a second walk reading through the same pager
# inherits the skip -- so agreement between them is not a proof.
expect_output_contains "the census states the blind spot it did NOT fix" \
  "Two such walks AGREEING does not rule it out." \
  run --page-limit 4 --fixture-dir "$BLIND_OUT"
echo

# =============================================================================
# THE PAGED READ HAS A TOTAL ORDER. Without one, explicit offsets page the
# server's default `desc: updated_at` — a MUTATING key. A concurrent write
# teleports its row to index 0 and shifts every row between; the duplicate half
# of that shift exits 4, but a concurrent DELETE shifts rows UP and is a SILENT
# skip that nothing detects.
#
# ONLY ONE SPELLING IS CORRECT, and both traps are one keystroke away — probed
# live against guerrilla on 2026-07-31:
#   order=doc_id      -> HTTP 200, id sequence IDENTICAL to sending no order
#                        (it fails the `<field>:(asc|desc)` regex and silently
#                        falls back), while a no-order pair taken in the same
#                        interleave was stable. A "fix" spelled this way is a
#                        green diff with ZERO behaviour change.
#   order=doc_id:asc  -> HTTP 200, sorts jsonb_extract_path(content,'doc_id'),
#                        NULL for every task row: an unspecified order that can
#                        skip and duplicate with no concurrent write at all.
#   order=_createdAt:asc -> the real total order (3901 rows, zero ties).
# =============================================================================
echo "paging — the read is ordered by a stable key, and the spelling is pinned"
expect_output_contains "the census reports the order it actually paged in" \
  "order=_createdAt:asc" \
  run --page-limit 4 --fixture-dir "$HEALTHY"
expect_output_contains "and page_order is machine-readable in --json" \
  '"page_order": "_createdAt:asc"' \
  run --page-limit 4 --fixture-dir "$HEALTHY" --json
expect_output_lacks "TRAP (a): a directionless order= is never emitted" \
  "order=doc_id" \
  run --page-limit 4 --fixture-dir "$HEALTHY" --json
expect_output_lacks "TRAP (b): an all-NULL content key is never sorted on" \
  "doc_id:asc" \
  run --page-limit 4 --fixture-dir "$HEALTHY" --json
echo

# =============================================================================
# USAGE. Bad input is exit 3, never a quietly smaller board.
# =============================================================================
echo "usage — bad input is a usage error, never a board"
expect_status "--page-limit 0 is a usage error" 3 \
  run --page-limit 0 --fixture-dir "$HEALTHY"
expect_status "--fixture-dir that does not exist is a usage error" 3 \
  run --page-limit 4 --fixture-dir "$TMP/nope"
expect_status "an unknown --lens is rejected by argparse" 2 \
  run --page-limit 4 --fixture-dir "$HEALTHY" --lens sideways
# THE ARGV ANCHOR IS REFUSED IN A CERTIFYING RUN. On the live board
# `--anchor 2020-01-01T00:00:00Z` flips 4(a) from 157/172 FAIL to 172/172 PASS,
# so a raw anchor outside --fixture-dir would let a round seal itself by argv.
# This check needs no server: the guard fires before any transport is built.
expect_status_matching "--anchor outside --fixture-dir is REFUSED" 3 "seal itself by argv" \
  run --page-limit 4 --anchor 2020-01-01T00:00:00Z --assert-round-done
expect_status_matching "--anchor and --anchor-from-paper are mutually exclusive" 3 "mutually exclusive" \
  run --page-limit 4 --fixture-dir "$HEALTHY" --anchor 2020-01-01T00:00:00Z --anchor-from-paper "$WAVE_SLUG"
expect_status_matching "an --anchor that is not an instant is a usage error" 3 "not an ISO-8601 instant" \
  run --page-limit 4 --fixture-dir "$HEALTHY" --anchor "last tuesday"

# =============================================================================
# CLAUSE 8 — A REASON, READ AGAINST ITS OWN CITED ARTIFACTS (the wave-27
# reviewer's own residual, paid in wave 28).
#
# THE DEFECT, STATED AS A RUN. Clause 1 is `reason_hashes_distinct ==
# reasons_non_empty` and NOTHING ELSE. `$INVENTED` is seven reasons that are
# stale, wrong and invented -- every one of them re-derived "at" a commit that
# reached no branch, "per" a document that does not exist -- and every one of
# them BYTE-UNIQUE. Clause 1 greens on it, 7 == 7, exactly as it greens on a
# board of honest re-derivations. That is the finding, and the first four checks
# below are the finding, not a test of the fix.
#
# THE MUTATION IS ONE ROW WITH TWO DEFECTS. `kid-a` in `$CITED` cites BOTH a
# dangling sha AND an absent path, so a clause that stopped at the first failure
# would name one of them and look correct doing it. Both must appear in ONE run.
#
# THE ORACLE IS REAL GIT. `$RREPO` is an actual repository with an actual
# refs/remotes/origin/main and an actual unreachable commit; the clause runs the
# same `cat-file` / `merge-base --is-ancestor` / `check-ignore` here that it runs
# on the live board. A fixture that answered those questions from a table would
# prove something about the table.
# =============================================================================
echo
echo "clause 8 — a reason, read against what it CITES"
RREPO="$TMP/reason-repo"
build_reason_repo "$RREPO"

INVENTED="$TMP/invented"
build_invented "$INVENTED"
CITED="$TMP/cited"
build_cited "$CITED"

# ---- FAIL-FIRST: clause 1 cannot see any of this -----------------------------
expect_output_contains "FAIL-FIRST: 5 invented reasons are all byte-DISTINCT" \
  "distinct reason hashes          5" \
  run --page-limit 4 --fixture-dir "$INVENTED" --reason-repo "$RREPO"
expect_output_contains "FAIL-FIRST: and clause 1 therefore says PASS over them" \
  "distinct reason hashes == non-empty reasons   5 == 5   PASS" \
  run --page-limit 4 --fixture-dir "$INVENTED" --reason-repo "$RREPO" --assert-round-done
expect_status "FAIL-FIRST: --assert-round-done GREENS on a wholly invented board" 0 \
  run --page-limit 4 --fixture-dir "$INVENTED" --reason-repo "$RREPO" --assert-round-done
# ...and clause 8 is the thing that is not fooled. Same corpus, same run.
expect_status_matching "and CLAUSE 8 reds the same board once armed" 1 \
  "cite an artifact that does not check out" \
  run --page-limit 4 --fixture-dir "$INVENTED" --reason-repo "$RREPO" \
      --assert-round-done --assert-reason-artifacts

# ---- THE MUTATION: BOTH defects, in ONE run, NAMED ---------------------------
expect_output_contains "the mutation names the DANGLING SHA" \
  "not-ancestor   kid-a -> $OFF_SHA" \
  run --page-limit 4 --fixture-dir "$CITED" --reason-repo "$RREPO"
expect_output_contains "the SAME run names the ABSENT PATH on the SAME row" \
  "path-missing   kid-a -> docs/api/absent.md" \
  run --page-limit 4 --fixture-dir "$CITED" --reason-repo "$RREPO"
expect_output_contains "both ride in --json as one findings list" \
  '"not-ancestor",' \
  run --page-limit 4 --fixture-dir "$CITED" --reason-repo "$RREPO" --json
expect_status_matching "armed, the two defects red ONE round" 1 "not-ancestor, path-missing" \
  run --page-limit 4 --fixture-dir "$CITED" --reason-repo "$RREPO" \
      --assert-round-done --assert-reason-artifacts

# ---- THE POSITIVE ARM: a citation that resolves must not be a finding --------
# Without this, "reds on everything" and "reds on the right thing" look the same.
expect_output_lacks "a live sha is NOT a finding" \
  "-> $ON_SHA" \
  run --page-limit 4 --fixture-dir "$CITED" --reason-repo "$RREPO"
expect_output_lacks "and neither is scripts/real.sh" \
  "-> scripts/real.sh" \
  run --page-limit 4 --fixture-dir "$CITED" --reason-repo "$RREPO"
# A BLOB owes EXISTENCE, never ancestry. `merge-base --is-ancestor <blob>` exits
# 128, so an ancestry-only clause files every `blob <sha>` citation as stale --
# which is exactly how four live rows were mis-filed before this arm existed.
expect_output_lacks "a BLOB citation resolves on existence, not ancestry" \
  "-> $BLOB_SHA" \
  run --page-limit 4 --fixture-dir "$CITED" --reason-repo "$RREPO"

# ---- HONEST ABOUT WHAT IT CANNOT SEE ----------------------------------------
# The row records that three of the 30 wave-27 reasons are DELIBERATELY thin and
# that one is an explicitly PARTIAL check wearing the same dress as the other 29.
# A clause that cannot tell thin-and-honest from wrong must SAY which it is
# doing, and must not convert the first into the second.
expect_output_contains "a reason citing NOTHING is reported as THIN" \
  "cite NOTHING -- NOT CHECKABLE" \
  run --page-limit 4 --fixture-dir "$CITED" --reason-repo "$RREPO"
expect_output_contains "and the thin count is on the PREDICATE line too" \
  "rows citing NOTHING (thin, NOT CHECKABLE)" \
  run --page-limit 4 --fixture-dir "$CITED" --reason-repo "$RREPO" --assert-round-done
expect_output_contains "thin rows never become findings" \
  '"thin": [' \
  run --page-limit 4 --fixture-dir "$CITED" --reason-repo "$RREPO" --json
expect_status "a board whose only unresolved rows are THIN is not red" 0 \
  run --page-limit 4 --fixture-dir "$HEALTHY" --reason-repo "$RREPO" \
      --assert-round-done --assert-reason-artifacts
# A GITIGNORED path is correctly absent from HEAD. Calling `build/artifact.txt`
# a stale citation would be a lie about a real file.
expect_output_contains "a gitignored path is IGNORED, not missing" \
  "ignored: deep-a -> build/artifact.txt" \
  run --page-limit 4 --fixture-dir "$CITED" --reason-repo "$RREPO"
# `origin/main` and `8/10` are slash-shaped and are not paths. Counted, so the
# size of what the clause declines to read is visible rather than assumed.
expect_output_contains "slash-shaped non-paths are FOREIGN and counted" \
  "slash-token(s) are NOT repo paths at all" \
  run --page-limit 4 --fixture-dir "$CITED" --reason-repo "$RREPO"
expect_output_lacks "and origin/main is never filed as a missing path" \
  "path-missing   deep-b" \
  run --page-limit 4 --fixture-dir "$CITED" --reason-repo "$RREPO"

# ---- REPORTED BEFORE IT IS ARMED --------------------------------------------
# The live board carries findings that are a CORPUS finding. Absorbing them into
# a build failure, or loosening the clause until they vanish, both throw the
# measurement away -- so the default REPORTS and --assert-reason-artifacts ARMS.
expect_status "unarmed, a board WITH findings still certifies" 0 \
  run --page-limit 4 --fixture-dir "$CITED" --reason-repo "$RREPO" --assert-round-done
expect_output_contains "and it says so, in the run that carries them" \
  "REPORTED, NOT ARMED" \
  run --page-limit 4 --fixture-dir "$CITED" --reason-repo "$RREPO"

# ---- THE SUBSET IS DETERMINISTIC AND ITS MEMBERSHIP IS PRINTED --------------
# The row permits a rotating subset. A sample whose membership is invisible
# restores the disease at one remove: the run names a number instead of the rows
# behind it.
expect_output_contains "a subset prints the RULE that selected it" \
  "rule: sha256(seed + NUL + row_id) ascending, first 2" \
  run --page-limit 4 --fixture-dir "$CITED" --reason-repo "$RREPO" --reason-sample 2
expect_output_contains "a subset says it is a SUBSET, with its size" \
  "membership  SUBSET 2 of 5 row(s)" \
  run --page-limit 4 --fixture-dir "$CITED" --reason-repo "$RREPO" --reason-sample 2
expect_output_contains "the FULL membership is printed, never elided" \
  "      sampled: " \
  run --page-limit 4 --fixture-dir "$CITED" --reason-repo "$RREPO" --reason-sample 2
expect_output_contains "an unsampled run says ALL, so membership needs no list" \
  "membership  ALL of 5 row(s)" \
  run --page-limit 4 --fixture-dir "$CITED" --reason-repo "$RREPO"
# DETERMINISM, PROVEN BY DIFFING TWO RUNS rather than by asserting one id: an
# id this file pins would go stale the moment the fixture gains a row, and a
# stale pin that still passes is worse than no pin.
expect_sample_stable "the SAME seed selects the SAME rows across runs" \
  --page-limit 4 --fixture-dir "$CITED" --reason-repo "$RREPO" --reason-sample 2
expect_sample_rotates "a DIFFERENT seed selects a DIFFERENT subset" \
  --page-limit 4 --fixture-dir "$CITED" --reason-repo "$RREPO" --reason-sample 2
expect_status_matching "--reason-sample 0 is a usage error, not an empty check" 3 "must be >= 1" \
  run --page-limit 4 --fixture-dir "$CITED" --reason-repo "$RREPO" --reason-sample 0

# ---- UNAVAILABLE IS A STATE, NEVER A PASS -----------------------------------
expect_output_contains "no repo means UNAVAILABLE, and it says NOT zero findings" \
  "This is NOT zero findings" \
  run --page-limit 4 --fixture-dir "$CITED" --reason-repo "$TMP"
expect_status_matching "armed, an unavailable oracle is a REFUSAL" 1 "could check NOTHING" \
  run --page-limit 4 --fixture-dir "$CITED" --reason-repo "$TMP" \
      --assert-round-done --assert-reason-artifacts
expect_status "unarmed, an unavailable oracle is reported and does not red" 0 \
  run --page-limit 4 --fixture-dir "$CITED" --reason-repo "$TMP" --assert-round-done

# ---- THE ORACLE CANNOT BE CHOSEN BY ARGV ------------------------------------
# Pointed at a repo where every citation happens to resolve, the clause reports
# zero over a board that has findings -- a green bought by choosing the oracle
# instead of by fixing the reasons. Same discipline as --anchor.
expect_status_matching "--reason-repo outside --fixture-dir is REFUSED" 3 \
  "a repo chosen by argv is a repo where every citation can be made to resolve" \
  run --page-limit 4 --reason-repo "$RREPO"
echo

if [[ $FAILURES -ne 0 ]]; then
  printf 'SELFTEST FAILED: %d of %d checks failed\n' "$FAILURES" "$CHECKS" >&2
  exit 1
fi

printf 'SELFTEST PASS: %d checks. The census greens on a healthy 2-page corpus and\n' "$CHECKS"
cat <<'SUMMARY'
REDS on: a 429 (whose body is valid JSON), a silently capped page, a page whose
count exceeds its documents, a source that stops answering mid-read, a wrong
echoed offset, a one-level .children lens, a /v1/tasks-shaped 200 failure, a
non-object body, a non-JSON body, a result with no documents, a 500, a missing
or unreadable _updatedAt, a row served twice, an empty population, a missing
root and a childless root -- and its done-condition can say no in all six of
its own directions: closure-scoped (duplicate reasons, off-vocabulary
dispositions, no reasons at all) and LIVE-scoped clause 4 (a live row with no
disposition, a live verdict with no reason, a live park with no STRUCTURED
reopen_trigger -- prose that merely says "REOPEN: charlie" is decoration and
reds). Clause 4 stays live-scoped: the same two mutations on TERMINAL rows do
NOT red, a family trigger shared over distinct reasons does NOT red, and a
duplicate reason on a terminal row STILL reds -- clauses 1-3 were not rescoped.

Clause 4(a) is ROUND-ANCHORED and the anchor cannot be argued: a raw --anchor
outside --fixture-dir is REFUSED (exit 3), and --anchor-from-paper fails closed
on a 404, a foreign envelope, an unreadable _createdAt, an absent _createdAt and
a Paper the source does not serve -- never falling back to now(). A live bare row
the anchor cannot PLACE fails closed too, while the same fixture unanchored is a
plain 4(a) red, so no pre-existing fixture is touched. Residue is an ENUMERATED
NAMED list, 4(a) still scores against the WHOLE live board, and it TERMINATES:
the same row is deferred by round N and IN SCOPE for round N+1, and adjudicating
it greens the round anchored or not, filing no new rows. Clause 5 stays
orthogonal -- the racing corpus exits 4 identically with and without an anchor.

THE ANCHOR IS ALSO BOUND TO THE ROUND IT CERTIFIES. The slug is DERIVED from the
epic root's own `wave_paper` with no flag at all; an --anchor-from-paper slug that
DISAGREES with it is REFUSED (exit 3, naming both slugs and what the older anchor
would have bought), and accepted only under --anchor-unbound, which prints
ANCHOR UNBOUND and rides in --json as round_anchor_binding=override. A root that
declares no wave_paper is reported `unverifiable` rather than passed -- which is
every pre-existing fixture here, and the reason none of them changed. --no-anchor
opts back into the UNANCHORED clause, which defers nothing and so cannot seal a
round, and a declared Paper the source cannot serve still fails closed.

CLAUSE 6 is the CLAIMABLE-AND-CLOSED contradiction (PDS-D372/D373), and it is
CLOSED-ONLY and CASE-EXACT. It reds on a live+closed row on `open` and on
`blocked`, naming the row; it stays SILENT on a terminal+closed row (the correct
shape of a finished row), on a LIVE park carrying a structured reopen_trigger
(the parked-inclusive form is refused on the record -- it reds the control and
SHAREDTRIG), on an off-vocabulary PROSE disposition and on an uppercase `CLOSED`
(both unrecognised, therefore LIVE, therefore clause 3's business alone). Every
fixture in that section exits 0 against the census as it stood before the clause
existed.

STDOUT IS THE MACHINE CHANNEL. expect_json_stdout separates the streams -- every
other helper captures 2>&1, which is why a human predicate block could sit on the
same stdout as the JSON payload for two waves unnoticed -- and asserts the
census's OWN exit code, never a pipeline's. `--json` is one parseable document
when it certifies (exit 0), when it refuses (exit 1) and when the snapshot is
INCOHERENT (exit 4, and the payload is still non-empty: the predicate is a pure
function computed BEFORE the single emit site precisely so that stays true). The
payload carries `round_done` and `round_done_failures`, so a consumer never has
to scrape a text stream for a verdict.

THE DENOMINATOR IS DERIVED AND THE REFUSAL IS NAMED (wave 47). The open count
is printed with the lens that produced it (published + `lifecycle_status` ==
`open`, case-exact, transitive slug-keyed closure), the instant it was taken and
the command that re-derives it -- no literal is pinned, because this board moves
while the wave reading it files rows. Beside it, the BLIND SPOTS block names
what that count cannot see: rows carrying the epic's slug prefix whose parent
chain never reaches the root (unreachable at ANY depth), and -- through a SECOND
paged read at `perspective=drafts` -- `open` drafts in scope of the root, SPLIT
by their published twin. The split is the finding: a draft with no twin is
HIDDEN WORK and joins the honest total, a draft whose twin is TERMINAL is an
EDIT SHADOW and joining it OVERCOUNTS (this is exactly how 379 was reached on
the live board where 376 was honest). Both arms are mutation-proven here: ONE
fixture row, `pds-stray-open`, is built twice -- parented outside the closure it
is NAMED, re-parented inside it the block is empty and the closure grew by one.
The drafts lens has an UNREAD state that is an ABSENCE and never a zero: a
source that cans no drafts page, and a source that answers `published` to a
`perspective=drafts` request (what the API silently does to an anonymous or
public-read caller) both print UNMEASURED. The softening stops there -- a drafts
read that truncates mid-lens, or answers 500, still fails closed.

CLAUSE 7's DRAFTS CAVEAT IS AMENDED, NOT RETIRED, and the amendment carries the
measurement that settles it: shape A 24 -> 27 over a drafts-inclusive read, the
+3 being edit shadows of `done` rows, so the published read does not UNDERCOUNT
shape A -- the drafts read MANUFACTURES three false lapses. Shapes B and C were
0 on BOTH lenses and are named UNDISCRIMINATED rather than quoted as agreement.
The per-run delta is scored by the SAME `lapse_shapes()` the published closure
is scored by, so it is a property of the lens and not of two key sets that
drifted apart.

THE GUARD IS PRINTED, INCLUDING WHAT IT IS NOT. `echo scripts/pds-ledger-census.sh
| bash scripts/elixir-path-escape-check.sh --match test` answers `false` while
the same command answers `true` for scripts/pds-door-census.sh: the required
Elixir gate does NOT dispatch this path, so every check in this file is
local-only and the census says so in its own output rather than letting a reader
assume CI coverage.

CLAUSE 8 READS A REASON AGAINST WHAT IT CITES, and the FAIL-FIRST fixture is
the finding rather than a test of the fix: FIVE wholly invented reasons ("re-
derived at <a commit that reached no branch> per <a document that does not
exist>"), each BYTE-UNIQUE, green clause 1 at 5 == 5 and exit 0 under
--assert-round-done -- exactly as an honest board does. The mutation is ONE row
citing BOTH a dangling sha AND an absent path, and both must be named in ONE
run, because a clause that stopped at the first would look correct naming half.
The oracle is a REAL git repository built here, with a real
refs/remotes/origin/main and a real unreachable commit, so the clause runs the
same `cat-file` / `merge-base --is-ancestor` / `check-ignore` it runs live; a
canned table would have proved something about the table. Both directions are
pinned: a BLOB citation must NOT be a finding (`merge-base --is-ancestor <blob>`
exits 128, and an ancestry-only clause files every `blob <sha>` as stale), a
thin row must NOT be a finding, and a gitignored path must NOT be a finding. The
subset is proven by DIFFING TWO RUNS rather than by pinning an id -- same seed,
same rows; different seed, different rows -- and its membership is printed in
full, because a sample nobody can enumerate names a number instead of the rows
behind it.

THE PAGED READ HAS A TOTAL ORDER: `order=_createdAt:asc`, reported back as
`page_order` so the discipline can be read rather than believed. Both traps are
pinned negatively -- a directionless `order=doc_id` (HTTP 200, silently ignored,
byte-for-byte the no-order response) and `order=doc_id:asc` (an all-NULL content
key, worse than no order at all) must never appear.
SUMMARY
