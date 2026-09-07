#!/usr/bin/env bash
# scripts/lib/check-runs.test.sh — the shared check-run reader's own harness.
#
# WHY THIS FILE EXISTS. scripts/lib/check-runs.sh is read by the required-check
# drift guard, scripts/release-scan.sh and scripts/absent-context-census.sh, and
# until now it had NO harness of its own: `git ls-files scripts/lib` returned the
# library and nothing else. It broke, in production, in the one way a shell
# script that assembles JSON breaks — it put the whole payload on ARGV — and the
# only reader was a CI log nobody was reading.
#
# THE DEFECT THIS PINS. `jq --argjson runs "$acc"` passes the ENTIRE accumulated
# feed as ONE argument. Linux caps a SINGLE argument at MAX_ARG_STRLEN =
# 32 * PAGE_SIZE = 131072 bytes independently of ARG_MAX, so on the runner the
# exec failed with `Argument list too long` once a head carried more check runs
# than fit. Measured on FRIKKern/barkpark sha d580983459: 83 runs / 255,330 bytes
# compact = 1.9x the cap, ~3,076 bytes per run, so only ~42 runs fit. This repo
# routinely carries 80-90. It failed CLOSED — callers got a refusal, not a wrong
# answer — which is the only reason it was survivable, and the reason it went
# unnoticed for so long: the guard was blind exactly when the feed was biggest.
#
# THE PATH THIS HARNESS DRIVES, stated because the last E2BIG defect in this repo
# hid behind a harness that drove a --fixture path carrying no payload while
# production drove the live one: this drives `check_runs_feed`, the real public
# entry point, which is a direct wrapper over `_check_runs_fetch`. Only the
# NETWORK is stubbed (a fake `gh` on PATH). The assembly under test runs for real.
set -uo pipefail

unset CDPATH
HERE="$(cd -P -- "$(dirname -- "$0")" && pwd)"
LIB="$HERE/check-runs.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1" >&2; }

[ -r "$LIB" ] || { echo "check-runs.test: cannot read $LIB — refusing to report a pass over nothing" >&2; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

# THE FIXTURE SIZE IS DERIVED, NOT TYPED. It must exceed the biggest argument
# this platform will accept, or the whole file is theatre: on Linux the binding
# limit is MAX_ARG_STRLEN (131072), on macOS it is ARG_MAX; taking the max of the
# two plus a margin fails the argv shape on BOTH, so the arms below mean the same
# thing wherever they run.
ARGMAX="$(getconf ARG_MAX 2>/dev/null || echo 131072)"
LINUX_MAX_ARG_STRLEN=$((32 * $(getconf PAGE_SIZE 2>/dev/null || echo 4096)))
TARGET=$(( (ARGMAX > LINUX_MAX_ARG_STRLEN ? ARGMAX : LINUX_MAX_ARG_STRLEN) + 262144 ))

python3 - "$TARGET" "$TMP/feed.json" <<'PY'
import json, sys
target = int(sys.argv[1]); runs = []; i = 0
while len(json.dumps(runs, separators=(',', ':'))) < target:
    runs.append({
        "id": 100000000 + i,
        "name": f"gate-{i} / a realistically long job name segment",
        "head_sha": "0" * 40, "status": "completed", "conclusion": "success",
        "app": {"id": 15368, "slug": "github-actions"},
        "output": {"title": None, "summary": None, "annotations_count": 0,
                   "text": "x" * 4096},   # padding: real runs carry output blobs
    })
    i += 1
json.dump({"total_count": len(runs), "check_runs": runs}, open(sys.argv[2], "w"))
PY
N="$(python3 -c "import json,sys;print(json.load(open('$TMP/feed.json'))['total_count'])")"
ACC_BYTES="$(python3 -c "import json;d=json.load(open('$TMP/feed.json'));print(len(json.dumps(d['check_runs'],separators=(',',':'))))")"

printf '\n── the shared check-run reader: the feed goes on STDIN, never ARGV ──\n'
printf '  fixture: %s run(s), %s bytes of accumulated feed (ARG_MAX %s, MAX_ARG_STRLEN %s)\n' \
  "$N" "$ACC_BYTES" "$ARGMAX" "$LINUX_MAX_ARG_STRLEN"

# NON-VACUITY, FIRST AND HALTING. A fixture that fits in an argument cannot
# distinguish the fix from the defect, and every arm below would pass on the
# BROKEN library. This is the control that must hit.
if [ "$ACC_BYTES" -le "$LINUX_MAX_ARG_STRLEN" ] || [ "$ACC_BYTES" -le "$ARGMAX" ]; then
  echo "check-runs.test: VACUOUS FIXTURE — $ACC_BYTES bytes does not exceed both limits; every arm below would pass on the broken library. Refusing to measure." >&2
  exit 2
fi
ok "the fixture EXCEEDS both argument limits, so the arms below can tell the fix from the defect"

# THE ARM THAT PROVES THE SIZE IS LOAD-BEARING. This is the OLD call shape,
# reconstructed inline: if the platform accepts it, the fixture is too small and
# a green below would mean nothing. It must FAIL.
acc_json="$(python3 -c "import json;d=json.load(open('$TMP/feed.json'));print(json.dumps(d['check_runs'],separators=(',',':')))")"
argv_rc=0
jq -c -n --argjson runs "$acc_json" '{check_runs: $runs}' >/dev/null 2>&1 || argv_rc=$?
if [ "$argv_rc" -ne 0 ]; then
  ok "the PRE-FIX shape (jq --argjson <whole feed>) still FAILS at this size (rc $argv_rc) — the regression this pins is reproducible on demand"
else
  bad "the pre-fix argv shape SUCCEEDED at $ACC_BYTES bytes — this platform's limit is higher than assumed and the arms below are vacuous"
fi

cat >"$TMP/bin/gh" <<'FAKE'
#!/usr/bin/env bash
[ "${1:-}" = "api" ] || { echo "fake gh: only \`gh api\` is emulated: $*" >&2; exit 1; }
case "$2" in
  *page=1*) cat "$CHECK_RUNS_TEST_FEED" ;;
  *)        printf '{"total_count":0,"check_runs":[]}' ;;
esac
FAKE
chmod +x "$TMP/bin/gh"

# shellcheck source=/dev/null
. "$LIB"

out_f="$TMP/out.json"; err_f="$TMP/out.err"
CHECK_RUNS_TEST_FEED="$TMP/feed.json" PATH="$TMP/bin:$PATH" \
  check_runs_feed o/r 0000000000000000000000000000000000000000 >"$out_f" 2>"$err_f"
rc=$?

if [ "$rc" -eq 0 ]; then
  ok "check_runs_feed RETURNS at a feed size that the pre-fix shape could not exec (rc 0)"
else
  bad "check_runs_feed refused (rc $rc) on a well-formed feed: $(head -1 "$err_f")"
fi

got="$(jq -r '.check_runs | length' <"$out_f" 2>/dev/null || echo -1)"
if [ "$got" = "$N" ]; then
  ok "…and it returns ALL $N runs — the payload survived the round trip, not just the exec"
else
  bad "expected $N runs, got $got — a feed that execs but loses rows is the worse failure"
fi

tot="$(jq -r '.total_count' <"$out_f" 2>/dev/null || echo -1)"
if [ "$tot" = "$N" ]; then
  ok "…and total_count is preserved at $N (the completeness proof still has its operand)"
else
  bad "total_count is $tot, expected $N"
fi

if [ ! -s "$err_f" ]; then
  ok "…and it said nothing on stderr — a clean read is silent"
else
  bad "stderr was not empty on a clean read: $(head -1 "$err_f")"
fi

printf '\n'
if [ "$FAIL" -eq 0 ]; then
  printf 'check-runs.test.sh: PASS (%d/%d)\n' "$PASS" "$((PASS + FAIL))"; exit 0
else
  printf 'check-runs.test.sh: FAILED (%d passed, %d failed)\n' "$PASS" "$FAIL" >&2; exit 1
fi
