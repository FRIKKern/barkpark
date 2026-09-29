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

# ═══════════════════════════════════════════════════════════════════════════
# THE BOUNDED RETRY OVER A TRANSIENT READ (task-6469556f8bb2ea51)
#
# THE FAULT. scripts/bp-merge.sh's pre-flight refused on 3 of 5 merges on
# 2026-09-11 with `BLOCKED: … cannot read check runs for <sha>`, and the same
# command 15-20 s later against the same head merged. GitHub's check-runs
# pagination is not a snapshot: a run created between page 1 and page 2 moves
# the accumulated length off the `total_count` page one reported, and the
# completeness proof refuses the set it cannot vouch for. Correctly. The thing
# that retried was a human.
#
# WHAT THESE ARMS MUST DISTINGUISH, and the control that proves they can: the
# fake `gh` below answers a MISMATCHED `total_count` on read-round 1 and a
# consistent one from round 2, so the ONLY difference between a pass and a
# refusal is whether a second round happened. Row (d) turns the ladder OFF
# against the IDENTICAL stub and demands the refusal — without it every arm
# here would pass on the incumbent library.
#
# NOTHING IS LIVE. The network is a script on PATH; the sleep is 0.
printf '\n── the bounded retry: a transient read is taken again, a refusal is not ──\n'

RT="$TMP/retry"; mkdir -p "$RT/bin"
# 100 runs — a FULL page, so the walk pages and the completeness proof is
# reachable. A short page would end the read on page one and measure nothing.
python3 - "$RT/page.json" <<'PY'
import json, sys
json.dump([{"id": 900000 + i, "name": f"gate-{i}", "status": "completed",
            "conclusion": "success", "app": {"id": 15368}} for i in range(100)],
          open(sys.argv[1], "w"))
PY

# CR_BAD_ROUNDS read-rounds answer total_count 150 against 200 delivered rows —
# the exact `read N … but the feed reports total_count M` shape. Later rounds
# answer 200 and agree. CR_MALFORMED makes page 2 unparseable (a PERMANENT
# refusal), CR_GH_FAIL makes every call fail with the given stderr.
cat >"$RT/bin/gh" <<'FAKE'
#!/usr/bin/env bash
[ "${1:-}" = "api" ] || { echo "fake gh: only \`gh api\` is emulated: $*" >&2; exit 1; }
n=$(cat "$CR_CALLS" 2>/dev/null || echo 0); n=$((n + 1)); printf '%s' "$n" >"$CR_CALLS"
if [ -n "${CR_GH_FAIL:-}" ]; then printf '%s\n' "$CR_GH_FAIL" >&2; exit 1; fi
round=$(( (n + 1) / 2 ))
case "$2" in
  *"&page=1")
    if [ "$round" -le "${CR_BAD_ROUNDS:-0}" ]; then tc=150; else tc=200; fi
    jq -n --argjson tc "$tc" --slurpfile r "$CR_PAGE" '{total_count:$tc, check_runs:$r[0]}' ;;
  *"&page=2")
    if [ -n "${CR_MALFORMED:-}" ]; then printf '{"not_a_feed":true}'; exit 0; fi
    jq -n --slurpfile r "$CR_PAGE" '{total_count:200, check_runs:$r[0]}' ;;
  *) printf '{"total_count":0,"check_runs":[]}' ;;
esac
FAKE
chmod +x "$RT/bin/gh"

# One read under a named environment. Returns rc; leaves stdout in $RT/out,
# stderr in $RT/err and the gh CALL COUNT in $RT/calls — the count is what
# proves an attempt actually happened rather than being claimed.
retry_read() { # $1 = retries · rest = extra VAR=VAL for the stub
  local retries="$1"; shift
  printf '0' >"$RT/calls"
  ( export PATH="$RT/bin:$PATH" CR_CALLS="$RT/calls" CR_PAGE="$RT/page.json" \
           BARKPARK_CHECK_RUNS_RETRIES="$retries" BARKPARK_CHECK_RUNS_RETRY_SLEEP=0
    for kv in "$@"; do export "${kv?}"; done
    check_runs_feed o/r 1111111111111111111111111111111111111111 ) \
    >"$RT/out" 2>"$RT/err"
}
calls() { cat "$RT/calls"; }

# ── (a) TRANSIENT, THEN SETTLES ────────────────────────────────────────────
retry_read 3 CR_BAD_ROUNDS=1; rc=$?
if [ "$rc" -eq 0 ]; then ok "a mismatched total_count on round 1 and a consistent feed on round 2 PROCEEDS (rc 0)"
else bad "the retry did not recover a transient read: rc $rc — $(head -1 "$RT/err")"; fi
got="$(jq -r '.check_runs | length' <"$RT/out" 2>/dev/null || echo -1)"
if [ "$got" = "200" ]; then ok "…and it returns the COMPLETE 200-run set, not a salvaged partial one"
else bad "expected 200 runs after the retry, got $got"; fi
if [ "$(calls)" = "4" ]; then ok "…and gh was called 4 times — 2 pages x 2 rounds, so the second attempt is MEASURED, not claimed"
else bad "expected 4 gh calls (2 rounds x 2 pages), saw $(calls) — the attempt count is not what the ladder claims"; fi
case "$(cat "$RT/err")" in
  *"but the feed reports total_count 150 — refusing (the set cannot be vouched for"*)
    ok "…and round 1's own refusal reason was printed in the INCUMBENT wording before the retry" ;;
  *) bad "the failed attempt's reason was swallowed: $(head -2 "$RT/err")" ;;
esac
case "$(cat "$RT/err")" in
  *"TRANSIENT read (attempt 1 of 3) — retrying in 0s"*) ok "…and the retry itself announced attempt 1 of 3" ;;
  *) bad "no per-attempt retry note on stderr: $(head -3 "$RT/err")" ;;
esac

# ── (b) NEVER SETTLES — STILL A REFUSAL, IN THE INCUMBENT WORDING ──────────
retry_read 3 CR_BAD_ROUNDS=99; rc=$?
if [ "$rc" -eq 2 ]; then ok "a read that NEVER settles still REFUSES with the documented rc 2 — a retry that ran out is not a pass"
else bad "an unsettleable read returned rc $rc, not 2"; fi
if [ ! -s "$RT/out" ]; then ok "…and it put ZERO bytes on stdout — never a zero-row set, never a partial one"
else bad "an exhausted retry emitted $(wc -c <"$RT/out") bytes on stdout"; fi
if [ "$(calls)" = "6" ]; then ok "…and it stopped at 3 attempts (6 gh calls) — the ladder is BOUNDED, not a spin"
else bad "expected 6 gh calls for 3 bounded attempts, saw $(calls)"; fi
case "$(tail -2 "$RT/err" | head -1)" in
  *"read 200 check runs for 1111111111111111111111111111111111111111 but the feed reports total_count 150 — refusing (the set cannot be vouched for; a re-run may have landed mid-read, retry)"*)
    ok "…and the LAST refusal is byte-identical to the incumbent line — the wording did not move" ;;
  *) bad "the final refusal wording changed: $(tail -2 "$RT/err" | head -1)" ;;
esac

# ── (c) A PERMANENT REFUSAL IS NEVER RETRIED ───────────────────────────────
retry_read 3 CR_MALFORMED=1; rc=$?
if [ "$rc" -eq 2 ] && [ "$(calls)" = "2" ]; then
  ok "a MALFORMED page-2 payload refuses on the FIRST round (rc 2, 2 gh calls) — a second identical read would say the same thing"
else bad "a permanent refusal was retried or misgraded: rc $rc, $(calls) gh calls"; fi
retry_read 3 CR_GH_FAIL="gh: HTTP 403: Bad credentials"; rc=$?
if [ "$rc" -eq 2 ] && [ "$(calls)" = "1" ]; then
  ok "a 403 Bad credentials refuses AT ONCE (1 gh call) — a bad token is not a blip, and sleeping on it hides it"
else bad "a 403 was retried or misgraded: rc $rc, $(calls) gh calls"; fi
retry_read 2 CR_GH_FAIL="gh: HTTP 502: Bad gateway"; rc=$?
if [ "$rc" -eq 2 ] && [ "$(calls)" = "2" ]; then
  ok "…while a 502 IS retried (2 calls for 2 attempts), so the classifier discriminates rather than blanket-retrying"
else bad "a 502 was not retried: rc $rc, $(calls) gh calls"; fi

# ── (d) THE NON-VACUITY CONTROL — THE LADDER OFF, THE SAME STUB ────────────
# BARKPARK_CHECK_RUNS_RETRIES=1 is the default and is today's library exactly.
# If this passes, row (a) measured the retry and not the stub.
retry_read 1 CR_BAD_ROUNDS=1; rc=$?
if [ "$rc" -eq 2 ] && [ "$(calls)" = "2" ]; then
  ok "CONTROL: with the ladder OFF (the DEFAULT), the identical round-1 stub refuses at once — so row (a) measured the retry"
else bad "CONTROL FAILED: retries=1 did not refuse on the first round (rc $rc, $(calls) calls) — every arm above is vacuous"; fi
case "$(cat "$RT/err")" in
  *"retrying in"*) bad "CONTROL FAILED: the default emitted a retry note — the ladder is not opt-in" ;;
  *) ok "…and it said nothing about retrying: the loop-over-many-heads callers pay nothing" ;;
esac

printf '\n'
if [ "$FAIL" -eq 0 ]; then
  printf 'check-runs.test.sh: PASS (%d/%d)\n' "$PASS" "$((PASS + FAIL))"; exit 0
else
  printf 'check-runs.test.sh: FAILED (%d passed, %d failed)\n' "$PASS" "$FAIL" >&2; exit 1
fi
