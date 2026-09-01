#!/usr/bin/env bash
#
# doc-gates-paths-parity-check.sh — .github/workflows/doc-gates.yml carries TWO
# hand-maintained trigger lists, `push.paths` and `pull_request.paths`, of ~70
# globs each. This guard asserts they are SET-EQUAL.
#
# WHY THIS EXISTS (CI gate-wiring + spec-generator wave, cgsiw-s3)
# -----------------------------------------------------------------------------
# The premise of the whole wave: a guard can be perfectly written and still
# vacuous AS A GATE if the wiring never invokes it on the PR that breaks it.
# doc-gates hosts roughly fourteen guards behind one hand-enumerated `paths:`
# filter — and behind it TWICE, because push and pull_request each carry their
# own copy. Two hand-maintained copies of a 70-entry list is a drift machine.
# The two failure directions are NOT symmetric and both are silent:
#
#   * an entry on `pull_request` but not on `push` — the gate checks the PR and
#     then goes dark on the merge, so a main-only regression (a direct push, or
#     a merge that resolves differently than either parent) is never
#     re-asserted.
#   * an entry on `push` but not on `pull_request` — the gate reds AFTER the
#     merge, on protected main, which is the failure mode this epic exists to
#     remove: a permanently-correct red nobody can land a fix through.
#
# It has ALREADY DRIFTED, which is the point. On origin/main today `push.paths`
# carries `api/test/**/*.exs` and `pull_request.paths` does not — 70 globs
# against 69. That specific asymmetry is behaviourally harmless because
# `**/*.exs` is in BOTH lists and subsumes it, and THAT is exactly why it went
# unnoticed: a harmless drift and a load-bearing one arrive by the identical
# mechanism (someone edits one list and not the other) and look identical in a
# diff. A guard is cheap and re-earns itself every run; a code review does not.
#
# THE PIN, AND WHY IT IS NOT A WAIVER
# -----------------------------------------------------------------------------
# The live one-sided entry above is PINNED in KNOWN_ONE_SIDED below rather than
# fixed here, because .github/workflows/doc-gates.yml is owned by a sibling
# slice this wave (cgsiw-s1, unmerged at the time of writing) and a second
# writer would collide with it. The pin is a ratchet, not a waiver, and it cuts
# BOTH ways:
#
#   * any one-sided entry that is NOT pinned reds immediately (exit 1). The pin
#     buys today's known drift, never tomorrow's.
#   * a pinned entry that has STOPPED drifting also reds (exit 1, STALE PIN).
#     So the PR that finally adds `api/test/**/*.exs` to `pull_request.paths`
#     must delete its pin line in the same change. The pin cannot rot into a
#     permanent blind spot, because it retires itself loudly.
#
# The one-line fix is handed to cgsiw-s5-doc-gates-paths-gaps, which owns
# doc-gates.yml's paths block after cgsiw-s1 lands. Removing the pin line here
# is part of that fix.
#
# FAIL CLOSED. Scanning zero globs is the vacuous pass this guard exists to
# refuse. A doc-gates.yml that cannot be read, cannot be parsed, has no
# push/pull_request `paths:` block, or has a block that extracts to ZERO
# entries, is a HARNESS FAILURE — exit 2 with a `HARNESS-UNAVAILABLE:` line —
# never a pass. An unparseable workflow is precisely when a parity claim is
# worth least, so it must not be able to produce one.
#
# MUTATION-PROVEN. The bundled `--selftest` drives THIS script over mktemp
# fixtures in both directions (a matched pair PASSES and a one-sided pair REDS —
# a guard that only ever reds is not a measurement either), plus the fail-closed
# arm and the unknown-argument refusal. The set comparison itself was then
# disarmed in a scratch copy to prove the selftest reds when the guard stops
# guarding; that disarm run is recorded in the commit message body of the change
# that introduced this file:
#
#     armed:    doc-gates-paths-parity-check --selftest: 15 passed, 0 failed, rc 0
#     disarmed: both `comm` lines in the MUT-SETCMP block replaced by `true` in
#               a scratch copy — 11 passed, 4 FAILED, rc 1. The four that went
#               red are exactly the drift-detecting ones: "push-only entry reds"
#               and "pull_request-only entry reds" both returned rc 0 with an
#               "OK — 2 globs on push, 1 on pull_request" line (the vacuous
#               green), and the two pin cases inverted because a guard that
#               sees no drift necessarily reports every pin as STALE. The
#               fail-closed and unknown-argument cases stayed green, correctly:
#               they do not depend on the comparison.
#
# HERMETIC: no network, no `bp`, no `gh`, writes only under mktemp. python3 +
# PyYAML is the only dependency, and its absence is exit 2, never a skip.
#
# USAGE
#   doc-gates-paths-parity-check.sh              # the tripwire (CI + local gate)
#   doc-gates-paths-parity-check.sh --selftest   # mutation-prove both directions
#
# EXIT CODES
#   0  the two lists are set-equal (modulo pinned, still-current entries)
#   1  drift: an unpinned one-sided entry, or a stale pin
#   2  harness unavailable, or an argument this script does not understand

set -euo pipefail

SELF="doc-gates-paths-parity-check"
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_TARGET="$REPO_ROOT/.github/workflows/doc-gates.yml"

# DOC_GATES_PATHS_PARITY_TARGET retargets the read at another file. Two callers:
# the selftest (fixtures), and the LIVE shell-harnesses.yml invocation in the
# doc-gates-paths-parity job — added after the 2026-09-01 measurement found that
# file's twin lists had drifted 94 vs 85 with nine one-way entries, the exact
# hazard this guard was built for, on a file it did not watch. It cannot weaken
# the default run — pointing it at the real doc-gates.yml gives the identical
# verdict.
TARGET="${DOC_GATES_PATHS_PARITY_TARGET:-$DEFAULT_TARGET}"

# The pinned one-sided entries, one per line, as `<side-it-is-ON>:<glob>`.
# See "THE PIN, AND WHY IT IS NOT A WAIVER" above: an entry here must STILL be
# one-sided or the guard reds. Deleting a line is how the fix lands.
KNOWN_ONE_SIDED='push:api/test/**/*.exs'

# The pin set is env-overridable ONLY when the target has been retargeted away
# from the real doc-gates.yml. For the DEFAULT target there is deliberately NO
# environment hatch that can silence the gate. For a retargeted LIVE run the
# pins arrive from the workflow step that sets the env — which is the same
# reviewed surface as this constant, so a pin cannot appear without a diff in
# .github/workflows/ any more than one can appear here.
if [ "$TARGET" != "$DEFAULT_TARGET" ]; then
  KNOWN_ONE_SIDED="${DOC_GATES_PATHS_PARITY_PINS-}"
fi

harness_unavailable() {
  echo "HARNESS-UNAVAILABLE: $SELF: $1"
  exit 2
}

# ---------------------------------------------------------------------------
# extract — the two paths blocks, as `<side><TAB><glob>` lines
# ---------------------------------------------------------------------------
# A REAL yaml parse, not a sed sweep: "unparseable" has to be a state this guard
# can reach and refuse, and only a parser can report it. PyYAML resolves the
# bare `on:` key to the boolean True (YAML 1.1), so both spellings are tried.
extract_paths() {
  python3 - "$TARGET" <<'PY'
import sys

try:
    import yaml
except Exception as exc:  # any import failure is unavailability, never a skip
    print("python3 cannot import yaml (%s)" % exc, file=sys.stderr)
    sys.exit(3)

path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as fh:
        doc = yaml.safe_load(fh)
except Exception as exc:  # read/parse failure is unavailability, never a skip
    print("cannot parse %s (%s)" % (path, exc), file=sys.stderr)
    sys.exit(3)

if not isinstance(doc, dict):
    print("%s did not parse to a mapping" % path, file=sys.stderr)
    sys.exit(3)

# `on:` resolves to the YAML 1.1 boolean True; accept the quoted spelling too.
triggers = doc.get(True, doc.get("on"))
if not isinstance(triggers, dict):
    print("%s has no `on:` mapping" % path, file=sys.stderr)
    sys.exit(3)

out = []
for side in ("push", "pull_request"):
    block = triggers.get(side)
    if not isinstance(block, dict):
        print("%s has no `on.%s:` mapping" % (path, side), file=sys.stderr)
        sys.exit(3)
    if "paths" not in block:
        print("%s has no `on.%s.paths:` block" % (path, side), file=sys.stderr)
        sys.exit(3)
    globs = block.get("paths")
    if not isinstance(globs, list):
        print("%s: on.%s.paths is not a list" % (path, side), file=sys.stderr)
        sys.exit(3)
    for g in globs:
        if not isinstance(g, str) or not g.strip():
            print("%s: on.%s.paths has a non-string entry" % (path, side), file=sys.stderr)
            sys.exit(3)
        out.append("%s\t%s" % (side, g))

sys.stdout.write("\n".join(out) + ("\n" if out else ""))
PY
}

# ---------------------------------------------------------------------------
# check — set-equality of the two lists, against the pin
# ---------------------------------------------------------------------------
check() {
  # Byte collation everywhere: sort and comm must agree or the set difference is
  # a locale artefact rather than a finding.
  export LC_ALL=C

  command -v python3 >/dev/null 2>&1 \
    || harness_unavailable "python3 is not on PATH — the workflow is yaml-parsed with it"
  [ -f "$TARGET" ] \
    || harness_unavailable "cannot read $TARGET — the parity clause has nothing to scan (a failure, never a skip)"

  local raw rc=0
  raw="$(extract_paths 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    harness_unavailable "$(printf '%s' "$raw" | tr '\n' ' ')"
  fi

  local push_list pr_list n_push n_pr
  push_list="$(printf '%s\n' "$raw" | awk -F'\t' '$1=="push"{print $2}' | sort -u)"
  pr_list="$(printf '%s\n' "$raw" | awk -F'\t' '$1=="pull_request"{print $2}' | sort -u)"
  n_push="$(printf '%s' "$push_list" | grep -c . || true)"
  n_pr="$(printf '%s' "$pr_list" | grep -c . || true)"

  # THE FAIL-CLOSED ARM. A block that extracts to zero globs would make every
  # comparison below trivially satisfiable — scanning zero globs is the vacuous
  # pass this guard exists to refuse.
  [ "$n_push" -gt 0 ] \
    || harness_unavailable "on.push.paths extracted 0 globs from $TARGET — scanning zero globs is the vacuous pass this guard exists to refuse"
  [ "$n_pr" -gt 0 ] \
    || harness_unavailable "on.pull_request.paths extracted 0 globs from $TARGET — scanning zero globs is the vacuous pass this guard exists to refuse"

  # `push:<glob>` for every glob on push and not on pull_request, and mirrored.
  # MUT-SETCMP: the two comm(1) invocations below ARE the set comparison. The
  # disarm proof recorded in this file's header neuters exactly this block and
  # watches the selftest go red.
  local one_sided
  one_sided="$(
    {
      comm -23 <(printf '%s\n' "$push_list") <(printf '%s\n' "$pr_list") | sed 's/^/push:/'
      comm -13 <(printf '%s\n' "$push_list") <(printf '%s\n' "$pr_list") | sed 's/^/pull_request:/'
    } | grep -Ev '^(push|pull_request):$' | sort || true
  )"

  local pinned
  pinned="$(printf '%s\n' "${KNOWN_ONE_SIDED-}" | grep . | sort -u || true)"

  local unpinned stale problems=0
  unpinned="$(comm -23 <(printf '%s\n' "$one_sided" | grep . || true) \
                       <(printf '%s\n' "$pinned"    | grep . || true) || true)"
  stale="$(comm -13 <(printf '%s\n' "$one_sided" | grep . || true) \
                    <(printf '%s\n' "$pinned"    | grep . || true) || true)"

  local line side glob other
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    side="${line%%:*}"
    glob="${line#*:}"
    other="pull_request"
    [ "$side" = "pull_request" ] && other="push"
    echo "::error::$SELF: DRIFT: '$glob' is on on.$side.paths but MISSING from on.$other.paths" >&2
    problems=$((problems + 1))
  done <<< "$unpinned"

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    side="${line%%:*}"
    glob="${line#*:}"
    echo "::error::$SELF: STALE PIN: '$glob' is pinned as $side-only but the two lists now agree on it — delete its line from KNOWN_ONE_SIDED in scripts/$SELF.sh" >&2
    problems=$((problems + 1))
  done <<< "$stale"

  if [ "$problems" -gt 0 ]; then
    echo "$SELF: $problems problem(s) — on.push.paths and on.pull_request.paths have drifted" >&2
    echo "$SELF: the two trigger lists must stay set-equal; edit BOTH or neither." >&2
    return 1
  fi

  # The pinned, still-current entries are reported loudly on the GREEN path too:
  # a green that quietly carries a known asymmetry is how the next reader learns
  # the wrong lesson.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    side="${line%%:*}"
    glob="${line#*:}"
    echo "$SELF: NOTE: '$glob' is $side-only and PINNED (known drift, owner cgsiw-s5-doc-gates-paths-gaps)"
  done <<< "$pinned"

  echo "$SELF: OK — $n_push globs on push, $n_pr on pull_request, set-equal modulo the pin ($TARGET)"
  return 0
}

# ---------------------------------------------------------------------------
# --selftest — BOTH directions, over mktemp fixtures, planting nothing
# ---------------------------------------------------------------------------
ST_PASS=0
ST_FAIL=0
# The fixture dir is a GLOBAL, not a `local`: the EXIT trap fires after the
# function frame is gone, so `set -u` would turn a `local tmp` into an
# unbound-variable error inside the cleanup itself — a red that has nothing to
# do with the verdict.
ST_TMP=""

st_ok() { ST_PASS=$((ST_PASS + 1)); echo "  PASS  $1"; }
st_no() { ST_FAIL=$((ST_FAIL + 1)); echo "  FAIL  $1"; }

# run_case <label> <expected-rc> <fixture> <pins> <needle-that-must-appear>
run_case() {
  local label="$1" want="$2" fixture="$3" pins="$4" needle="$5"
  local out rc=0
  out="$(DOC_GATES_PATHS_PARITY_TARGET="$fixture" DOC_GATES_PATHS_PARITY_PINS="$pins" \
        bash "${BASH_SOURCE[0]}" 2>&1)" || rc=$?
  if [ "$rc" -eq "$want" ] && printf '%s' "$out" | grep -qF -- "$needle"; then
    st_ok "$label (rc=$rc)"
  else
    st_no "$label — expected rc=$want with '$needle', got rc=$rc"
    printf '%s\n' "$out" | sed 's/^/          /'
  fi
}

# write_fixture <file> <push-globs, newline-separated> <pr-globs, newline-separated>
write_fixture() {
  local file="$1" push="$2" pr="$3"
  {
    echo "name: fixture"
    echo "on:"
    echo "  push:"
    echo "    branches: [main]"
    echo "    paths:"
    printf '%s\n' "$push" | grep . | sed 's/^/      - "/; s/$/"/' || true
    echo "  pull_request:"
    echo "    paths:"
    printf '%s\n' "$pr" | grep . | sed 's/^/      - "/; s/$/"/' || true
    echo "jobs:"
    echo "  noop:"
    echo "    runs-on: ubuntu-latest"
    echo "    steps:"
    echo "      - run: true"
  } > "$file"
}

selftest() {
  local tmp
  ST_TMP="$(mktemp -d)"
  trap 'if [ -n "${ST_TMP:-}" ]; then rm -rf "$ST_TMP"; fi' EXIT
  tmp="$ST_TMP"

  echo "$SELF --selftest: fixtures under $tmp (nothing is written to the tree)"

  # ── direction 1: a MATCHED pair PASSES. A guard that only ever reds is not a
  # measurement either — the green arm has to be exercised too.
  write_fixture "$tmp/matched.yml" $'**/*.md\n**/*.ex\nscripts/foo.sh' $'**/*.md\n**/*.ex\nscripts/foo.sh'
  run_case "a matched pair passes" 0 "$tmp/matched.yml" "" \
    "3 globs on push, 3 on pull_request"

  # ── direction 2: a one-sided pair REDS, with the missing side named.
  write_fixture "$tmp/push_only.yml" $'**/*.md\napi/test/**/*.exs' $'**/*.md'
  run_case "push-only entry reds" 1 "$tmp/push_only.yml" "" \
    "'api/test/**/*.exs' is on on.push.paths but MISSING from on.pull_request.paths"

  write_fixture "$tmp/pr_only.yml" $'**/*.md' $'**/*.md\nweb/**/*.tsx'
  run_case "pull_request-only entry reds" 1 "$tmp/pr_only.yml" "" \
    "'web/**/*.tsx' is on on.pull_request.paths but MISSING from on.push.paths"

  # ── ordering is not drift: these are SETS, not sequences.
  write_fixture "$tmp/reordered.yml" $'b\na\nc' $'c\nb\na'
  run_case "a reordered but equal pair passes (sets, not sequences)" 0 "$tmp/reordered.yml" "" \
    "3 globs on push, 3 on pull_request"

  # ── the PIN, both ways: it buys today's known drift and nothing else, and it
  # retires itself the moment the drift it named is gone.
  run_case "a pinned one-sided entry passes with a NOTE" 0 "$tmp/push_only.yml" \
    'push:api/test/**/*.exs' "is push-only and PINNED"
  run_case "a STALE pin reds (the drift it named is gone)" 1 "$tmp/matched.yml" \
    'push:api/test/**/*.exs' "STALE PIN"
  run_case "an unpinned one-sided entry reds even with an unrelated pin" 1 "$tmp/pr_only.yml" \
    'push:api/test/**/*.exs' "'web/**/*.tsx' is on on.pull_request.paths"

  # ── FAIL CLOSED, five shapes. Every one is exit 2 with HARNESS-UNAVAILABLE and
  # NONE of them may reach exit 0: an unparseable workflow is exactly when a
  # parity claim is worth least.
  # An EXPLICIT empty sequence: `paths: []` parses to a perfectly valid list of
  # length zero, which every glob comparison below is trivially true over. This
  # is the vacuous pass, and it is the one shape a set-equality guard would
  # otherwise green on with a straight face — `[] == []`.
  printf 'name: emptypr\non:\n  push:\n    branches: [main]\n    paths:\n      - "**/*.md"\n  pull_request:\n    paths: []\njobs:\n  noop:\n    runs-on: ubuntu-latest\n    steps:\n      - run: true\n' > "$tmp/empty_pr.yml"
  run_case "a zero-entry pull_request.paths is HARNESS-UNAVAILABLE, not a pass" 2 \
    "$tmp/empty_pr.yml" "" "scanning zero globs is the vacuous pass this guard exists to refuse"

  printf 'name: emptypush\non:\n  push:\n    branches: [main]\n    paths: []\n  pull_request:\n    paths:\n      - "**/*.md"\njobs:\n  noop:\n    runs-on: ubuntu-latest\n    steps:\n      - run: true\n' > "$tmp/empty_push.yml"
  run_case "a zero-entry push.paths is HARNESS-UNAVAILABLE, not a pass" 2 \
    "$tmp/empty_push.yml" "" "on.push.paths extracted 0 globs"

  # BOTH sides empty — `[] == []` is the set-equality a naive guard reports as
  # OK. It must be exit 2 here, never exit 0.
  printf 'name: bothempty\non:\n  push:\n    branches: [main]\n    paths: []\n  pull_request:\n    paths: []\njobs:\n  noop:\n    runs-on: ubuntu-latest\n    steps:\n      - run: true\n' > "$tmp/both_empty.yml"
  run_case "two EQUAL but empty lists are HARNESS-UNAVAILABLE, not a pass" 2 \
    "$tmp/both_empty.yml" "" "scanning zero globs is the vacuous pass this guard exists to refuse"

  # A `paths:` key that is present but null (the shape a half-finished edit
  # leaves behind) is refused by the parser arm rather than read as empty.
  write_fixture "$tmp/null_pr.yml" $'**/*.md' ''
  run_case "a null pull_request.paths is HARNESS-UNAVAILABLE, not a pass" 2 \
    "$tmp/null_pr.yml" "" "on.pull_request.paths is not a list"

  printf 'name: broken\non:\n  push:\n    paths:\n   - "["\n  bad indent: [\n' > "$tmp/unparseable.yml"
  run_case "an unparseable doc-gates.yml is HARNESS-UNAVAILABLE, not a pass" 2 \
    "$tmp/unparseable.yml" "" "HARNESS-UNAVAILABLE"

  printf 'name: nopr\non:\n  push:\n    paths:\n      - "**/*.md"\njobs:\n  noop:\n    runs-on: ubuntu-latest\n    steps:\n      - run: true\n' > "$tmp/no_pr.yml"
  run_case "a missing on.pull_request block is HARNESS-UNAVAILABLE, not a pass" 2 \
    "$tmp/no_pr.yml" "" 'has no `on.pull_request:` mapping'

  run_case "a target that does not exist is HARNESS-UNAVAILABLE, not a pass" 2 \
    "$tmp/does-not-exist.yml" "" "the parity clause has nothing to scan"

  # ── the terminal unknown-argument arm (#12558): --bogus must REFUSE, never
  # fall through into the full gate.
  local out rc=0
  out="$(bash "${BASH_SOURCE[0]}" --bogus 2>&1)" || rc=$?
  if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -qF -- "unknown argument '--bogus'"; then
    st_ok "an unknown argument refuses at exit 2 (rc=$rc)"
  else
    st_no "an unknown argument should exit 2 with a usage line — got rc=$rc"
    printf '%s\n' "$out" | sed 's/^/          /'
  fi

  echo "$SELF --selftest: $ST_PASS passed, $ST_FAIL failed"
  [ "$ST_FAIL" -eq 0 ]
}

case "${1:---check}" in
  --selftest)
    selftest
    exit $?
    ;;
  --check) ;;
  *)
    echo "$SELF: unknown argument '$1'" >&2
    echo "usage: $0 [--check|--selftest]" >&2
    exit 2
    ;;
esac

check
