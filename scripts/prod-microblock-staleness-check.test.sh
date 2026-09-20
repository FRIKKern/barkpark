#!/usr/bin/env bash
# Selftest for scripts/prod-microblock-staleness-check.sh.
#
# GRADED HARDER THAN THE SCRIPT. The guard exists because a reader that silently
# answers zero IS the defect, so the arms that matter most are the five
# CANNOT-READ ones and the proof that the exit codes are mutually distinct.
#
# THE NETWORK STUB IS HONEST. Each arm writes a fake `curl` that echoes a RAW
# status.json body and nothing else; the script does its own fetching, parsing,
# validation and git resolution. A stub that returned the verdict would skip
# every line under test.
#
# EVERY ARM ASSERTS ITS FIXTURE FIRST. An arm whose setup silently failed passes
# for the wrong reason, so each one proves the sha it feeds is (or is not) known
# to git before it asserts anything about the verdict.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$REPO_ROOT/scripts/prod-microblock-staleness-check.sh"
REF="${PROD_MICROBLOCK_REF:-origin/main}"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/prod-staleness-test.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

pass=0; fail=0
ok()   { echo "  ok   $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL $1" >&2; fail=$((fail+1)); }

# Read the codes from the script itself so a renumbering cannot make this file
# silently assert the wrong numbers.
eval "$(bash "$CHECK" --exit-codes)"
echo "exit codes under test: OK=$OK BEHIND=$BEHIND CANNOT_READ=$CANNOT_READ FORKED=$FORKED"

# ── arm 0: the four exit codes are mutually distinct ─────────────────────────
echo "arm 0: the exit codes are mutually distinct"
distinct="$(printf '%s\n' "$OK" "$BEHIND" "$CANNOT_READ" "$FORKED" | sort -u | grep -c .)"
if [ "$distinct" -eq 4 ]; then
  ok "OK/BEHIND/CANNOT-READ/FORKED are four different numbers"
else
  bad "only $distinct distinct exit codes among OK=$OK BEHIND=$BEHIND CANNOT_READ=$CANNOT_READ FORKED=$FORKED"
fi

# A fake curl that prints $1 verbatim on stdout and exits $2 (default 0).
make_curl() {
  local path="$TMP/curl-$3" body="$1" rc="${2:-0}"
  {
    echo '#!/usr/bin/env bash'
    echo "cat <<'RAWBODY'"
    printf '%s\n' "$body"
    echo 'RAWBODY'
    echo "exit $rc"
  } > "$path"
  chmod +x "$path"
  echo "$path"
}
# A fake curl that prints NOTHING and fails, as curl does for an unreachable host.
make_dead_curl() {
  local path="$TMP/curl-dead"
  printf '%s\n' '#!/usr/bin/env bash' \
    'echo "curl: (6) Could not resolve host: unreachable.invalid" >&2' \
    'exit 6' > "$path"
  chmod +x "$path"
  echo "$path"
}

run() { # run <fake-curl> ; prints combined output, returns the script's code
  PROD_MICROBLOCK_CURL="$1" PROD_MICROBLOCK_STATUS_URL="http://stub.invalid/status.json" \
    bash "$CHECK" 2>&1
}

assert_arm() { # assert_arm <label> <expected-code> <must-contain> <actual-code> <output>
  local label="$1" want="$2" needle="$3" got="$4" out="$5"
  if [ "$got" -ne "$want" ]; then
    bad "$label: expected exit $want, got $got"
    printf '%s\n' "$out" | sed 's/^/       | /' >&2
    return
  fi
  if ! printf '%s' "$out" | grep -q -- "$needle"; then
    bad "$label: exit $want but the output never said '$needle'"
    printf '%s\n' "$out" | sed 's/^/       | /' >&2
    return
  fi
  ok "$label -> exit $got, output names '$needle'"
}

# ── FIXTURE: a sha git KNOWS and that is genuinely behind the ref ────────────
# ca4534461 is what 89.167.28.206 served on 2026-09-20. Any old ancestor works;
# the arm proves the property it needs rather than trusting the constant.
BEHIND_SHA="${PROD_MICROBLOCK_TEST_BEHIND_SHA:-ca4534461}"
echo "arm 1: POSITIVE CONTROL — a known-behind sha must RED and name the count"
fixture_rc=0
git -C "$REPO_ROOT" rev-parse --verify --quiet "${BEHIND_SHA}^{commit}" >/dev/null || fixture_rc=1
git -C "$REPO_ROOT" merge-base --is-ancestor "$BEHIND_SHA" "$REF" 2>/dev/null || fixture_rc=1
expected_behind="$(git -C "$REPO_ROOT" rev-list --count "${BEHIND_SHA}..${REF}" 2>/dev/null || echo 0)"
if [ "$fixture_rc" -ne 0 ]; then
  bad "arm 1 FIXTURE: $BEHIND_SHA is not a git-known ancestor of $REF — the arm cannot measure anything"
elif [ "$expected_behind" -lt 1 ]; then
  bad "arm 1 FIXTURE: $BEHIND_SHA is 0 commits behind $REF — there is no gap to see"
else
  ok "arm 1 FIXTURE: $BEHIND_SHA is a git-known ancestor of $REF, $expected_behind commits behind"
  c="$(make_curl "{\"status\":\"operational\",\"commit\":\"$BEHIND_SHA\"}" 0 behind)"
  out="$(run "$c")"; rc=$?
  assert_arm "arm 1 positive control" "$BEHIND" "BEHIND: the box is $expected_behind commits behind" "$rc" "$out"
  # The guard must SEE the gap, not merely dislike it.
  if printf '%s' "$out" | grep -qE "^behind   $expected_behind commits$"; then
    ok "arm 1: the reported count equals git's own rev-list count ($expected_behind)"
  else
    bad "arm 1: the reported count does not match git's $expected_behind"
    printf '%s\n' "$out" | sed 's/^/       | /' >&2
  fi
fi

# ── arm 2: a CURRENT sha greens ──────────────────────────────────────────────
echo "arm 2: the ref's own sha greens"
CURRENT_SHA="$(git -C "$REPO_ROOT" rev-parse --verify --quiet "${REF}^{commit}" || true)"
if [ -z "$CURRENT_SHA" ]; then
  bad "arm 2 FIXTURE: $REF does not resolve — nothing to compare against"
else
  ok "arm 2 FIXTURE: $REF resolves to $CURRENT_SHA"
  c="$(make_curl "{\"status\":\"operational\",\"commit\":\"$CURRENT_SHA\"}" 0 current)"
  out="$(run "$c")"; rc=$?
  assert_arm "arm 2 current sha" "$OK" "OK: the box serves $REF exactly" "$rc" "$out"
fi

# ── arms 3-7: CANNOT-READ. None of these may exit 0, and none may exit $BEHIND.
echo "arm 3: unreachable host"
c="$(make_dead_curl)"
if [ -x "$c" ]; then ok "arm 3 FIXTURE: the fake curl exists and exits non-zero"; else bad "arm 3 FIXTURE: no fake curl"; fi
out="$(run "$c")"; rc=$?
assert_arm "arm 3 unreachable" "$CANNOT_READ" "CANNOT-READ" "$rc" "$out"

echo "arm 4: 200 with no commit key"
c="$(make_curl '{"status":"operational","version":"0.2.26.929"}' 0 nokey)"
if bash "$c" | grep -q '"status"'; then ok "arm 4 FIXTURE: the stub emits a raw JSON body with no commit key"; else bad "arm 4 FIXTURE: stub body wrong"; fi
out="$(run "$c")"; rc=$?
assert_arm "arm 4 no commit key" "$CANNOT_READ" "no usable \"commit\" key" "$rc" "$out"

echo "arm 5: commit present but empty"
c="$(make_curl '{"status":"operational","commit":""}' 0 empty)"
if bash "$c" | grep -q '"commit":""'; then ok "arm 5 FIXTURE: the stub emits commit=\"\""; else bad "arm 5 FIXTURE: stub body wrong"; fi
out="$(run "$c")"; rc=$?
assert_arm "arm 5 empty commit" "$CANNOT_READ" "no usable \"commit\" key" "$rc" "$out"

echo "arm 6: a sha git has never seen"
UNKNOWN_SHA=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
if git -C "$REPO_ROOT" rev-parse --verify --quiet "${UNKNOWN_SHA}^{commit}" >/dev/null 2>&1; then
  bad "arm 6 FIXTURE: git KNOWS $UNKNOWN_SHA — the arm would measure the wrong thing"
else
  ok "arm 6 FIXTURE: git does not know $UNKNOWN_SHA"
  c="$(make_curl "{\"status\":\"operational\",\"commit\":\"$UNKNOWN_SHA\"}" 0 unknown)"
  out="$(run "$c")"; rc=$?
  assert_arm "arm 6 unknown sha" "$CANNOT_READ" "git does not know the served sha" "$rc" "$out"
fi

echo "arm 7: malformed JSON"
c="$(make_curl '<html><body>502 Bad Gateway</body></html>' 0 malformed)"
if bash "$c" | grep -q '502'; then ok "arm 7 FIXTURE: the stub emits a non-JSON body"; else bad "arm 7 FIXTURE: stub body wrong"; fi
out="$(run "$c")"; rc=$?
assert_arm "arm 7 malformed JSON" "$CANNOT_READ" "not parseable JSON" "$rc" "$out"

echo "arm 7b: the literal string \"unknown\" (BuildInfo's degraded value)"
c="$(make_curl '{"status":"operational","commit":"unknown"}' 0 unknownword)"
out="$(run "$c")"; rc=$?
assert_arm "arm 7b commit=unknown" "$CANNOT_READ" "is not hexadecimal" "$rc" "$out"

echo "arm 7c: a short/garbage sha"
c="$(make_curl '{"status":"operational","commit":"abc"}' 0 short)"
out="$(run "$c")"; rc=$?
assert_arm "arm 7c short sha" "$CANNOT_READ" "not a 7-40 character hex sha" "$rc" "$out"

# ── arm 8: THE CENTRAL PROPERTY ──────────────────────────────────────────────
# A failed read must never be byte-identical to a green. Compare the actual
# bytes, not just the codes: this is the one assertion the whole file exists for.
echo "arm 8: a failed read is not byte-identical to a green"
c_ok="$(make_curl "{\"commit\":\"$CURRENT_SHA\"}" 0 cmp-ok)"
green_out="$(run "$c_ok")"; green_rc=$?
c_dead="$(make_dead_curl)"
dead_out="$(run "$c_dead")"; dead_rc=$?
if [ "$green_rc" -eq "$dead_rc" ]; then
  bad "arm 8: a green and a failed read share exit code $green_rc"
elif [ "$green_out" = "$dead_out" ]; then
  bad "arm 8: a green and a failed read produce identical output"
else
  ok "arm 8: green (exit $green_rc) and failed read (exit $dead_rc) differ in BOTH code and bytes"
fi
if printf '%s' "$dead_out" | grep -qE '0 commits behind'; then
  bad "arm 8: a failed read claimed '0 commits behind' — this IS the guarded defect"
else
  ok "arm 8: a failed read never says '0 commits behind'"
fi

# ── arm 9: FORKED is its own answer ──────────────────────────────────────────
# Build a real commit that is genuinely not an ancestor of the ref, in a throwaway
# clone, and point the check at it via a repo whose HEAD carries that history.
echo "arm 9: a non-ancestor sha is FORKED, not zero and not an error"
FORK_REPO="$TMP/forked"
git clone --quiet --no-local --shared "$REPO_ROOT" "$FORK_REPO" 2>/dev/null
if [ -d "$FORK_REPO/.git" ]; then
  git -C "$FORK_REPO" remote add origin-real "$REPO_ROOT" 2>/dev/null
  git -C "$FORK_REPO" fetch --quiet origin-real "$REF:refs/remotes/origin/main" 2>/dev/null || true
  git -C "$FORK_REPO" checkout --quiet -B forkarm "refs/remotes/origin/main" 2>/dev/null
  echo "forked-arm-$$" > "$FORK_REPO/.forked-arm-marker"
  git -C "$FORK_REPO" add .forked-arm-marker >/dev/null 2>&1
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
    git -C "$FORK_REPO" commit --quiet -m "fork arm" >/dev/null 2>&1
  FORK_SHA="$(git -C "$FORK_REPO" rev-parse HEAD)"
  mkdir -p "$FORK_REPO/scripts"
  cp "$CHECK" "$FORK_REPO/scripts/" 2>/dev/null
  if git -C "$FORK_REPO" merge-base --is-ancestor "$FORK_SHA" refs/remotes/origin/main 2>/dev/null; then
    bad "arm 9 FIXTURE: the built sha IS an ancestor of the ref — it is not forked"
  else
    ok "arm 9 FIXTURE: $FORK_SHA exists and is NOT an ancestor of $REF"
    c="$(make_curl "{\"commit\":\"$FORK_SHA\"}" 0 forked)"
    out="$(PROD_MICROBLOCK_CURL="$c" PROD_MICROBLOCK_STATUS_URL="http://stub.invalid/status.json" \
      bash "$FORK_REPO/scripts/prod-microblock-staleness-check.sh" 2>&1)"; rc=$?
    assert_arm "arm 9 forked sha" "$FORKED" "FORKED" "$rc" "$out"
    if printf '%s' "$out" | grep -qE 'behind   0 commits'; then
      bad "arm 9: a forked sha was reported as 0 commits behind"
    else
      ok "arm 9: a forked sha is never reported as 0 commits behind"
    fi
  fi
else
  bad "arm 9 FIXTURE: could not build a throwaway clone — the arm measured nothing"
fi

echo
echo "SUMMARY: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
echo "PASS: prod-microblock-staleness-check.sh reds on a real gap, greens on a current sha, and refuses loudly on all five cannot-read shapes."
