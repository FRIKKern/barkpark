#!/usr/bin/env bash
# compose-smoke.test.sh — the green arm must name the CAUSE it actually has.
#
#   bash scripts/compose-smoke.test.sh      (exit 0 = all green)
#
# THE DEFECT THIS PINS. scripts/compose-smoke.sh's health-wait loop inspects
# .State.Running / .State.RestartCount / .State.Health.Status every 5s and dies
# with an exact container-state message on a crash or a restart. It `break`s the
# instant health reads healthy — and, before this harness existed, nothing ever
# re-inspected Running or RestartCount again. The next statement was the
# in-container `wget`. A container that died between the last health probe and
# the exec was therefore reported as:
#
#     FAIL  green arm: in-container wget /api/schemas failed
#
# an HTTP probe failure, when the truth was "the container is no longer cleanly
# running" — a message the script already knew how to write. Measured twice
# (#12879, #12889). A harness that names the wrong cause is worse than one that
# says nothing, because it is confidently wrong.
#
# HOW IT IS PROVED WITHOUT DOCKER. compose-smoke.sh reaches the daemon only
# through `docker` (via compose(), `docker inspect`, `docker logs`). This
# harness puts a FAKE `docker` first on PATH that answers those argv shapes from
# a scripted state machine, and runs the real green arm against it. No image is
# built, no daemon is needed, and the run takes under a second.
#
# HOW THE MUTATION ARM WORKS. The fix is three `assert_container_alive` calls.
# The harness makes a mutated COPY of the script with those calls stripped —
# refusing if the anchor does not match exactly three times, so a mutation that
# did not apply can never read as a catch — and runs the same scenarios against
# it. The mutant must name wget; the real script must name the container state.
# That is the proof re-earning itself on every run, not a pasted transcript.
#
# WHAT IT DOES NOT CLAIM. Nothing about the real image, the real boot, or the
# intermittent event itself. It claims only that when the container dies after
# healthy, the harness says so — and that when the container is fine and the
# route 500s, the harness still blames the route.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SMOKE="${COMPOSE_SMOKE_SH:-$ROOT/scripts/compose-smoke.sh}"

pass=0; fail=0; cases=0
check() { # check <label> <expected> <actual>
  cases=$((cases+1))
  if [ "$2" = "$3" ]; then pass=$((pass+1)); printf 'ok   %-64s (%s)\n' "$1" "$3"
  else fail=$((fail+1)); printf 'FAIL %-64s want %s got %s\n' "$1" "$2" "$3"; fi
}
has() { # has <haystack-file> <needle> -> 1|0
  grep -Fq -- "$2" "$1" && echo 1 || echo 0
}

[ -r "$SMOKE" ] || { echo "FAIL: cannot read $SMOKE" >&2; exit 2; }

TMP="$(mktemp -d -t compose-smoke-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# ── the fake docker ─────────────────────────────────────────────────────────
mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<'FAKE'
#!/usr/bin/env bash
# Fake docker for compose-smoke.test.sh. Answers only the argv shapes
# compose-smoke.sh's green arm actually issues; anything else is a hard error,
# so a drift in the script's docker usage reds this harness instead of silently
# passing through.
set -uo pipefail
st="$FAKE_DOCKER_STATE"
printf '%s\n' "$*" >> "$st/argv.log"
sc="$FAKE_DOCKER_SCENARIO"

dead() { [ -f "$st/dead" ]; }

if [ "${1:-}" = "compose" ]; then
  shift
  while [ "${1:-}" = "-p" ]; do shift 2; done
  sub="${1:-}"; shift 2>/dev/null || true
  case "$sub" in
    build|up|pull|down) exit 0 ;;
    ps)   echo "fakecid00000001"; exit 0 ;;
    exec)
      url=""
      for a in "$@"; do case "$a" in http://*) url="$a" ;; esac; done
      case "$sc:$url" in
        death:*)
          echo "wget: can't connect to remote host: Connection refused" >&2; exit 1 ;;
        death_login:*/login)
          echo "wget: can't connect to remote host: Connection refused" >&2; exit 1 ;;
        death_login:*)
          # /api/schemas still serves; the container dies right after it.
          touch "$st/dead"; exit 0 ;;
        http500:*/api/schemas)
          echo "wget: server returned error: HTTP/1.1 500 Internal Server Error" >&2; exit 1 ;;
        *) exit 0 ;;
      esac ;;
    *) echo "fake docker: unhandled compose subcommand '$sub'" >&2; exit 97 ;;
  esac
fi

case "${1:-}" in
  inspect)
    shift; fmt=""
    while [ $# -gt 0 ]; do
      case "$1" in -f|--format) fmt="$2"; shift 2 ;; *) shift ;;
    esac
    done
    case "$fmt" in
      *Health*)
        echo healthy
        # THE WINDOW: in the `death` scenario the container dies the instant the
        # health probe reports healthy — i.e. between the loop's break and the exec.
        [ "$sc" = "death" ] && touch "$st/dead"
        ;;
      *Running*)      dead && echo false || echo true ;;
      *RestartCount*) dead && echo 1 || echo 0 ;;
      *) echo "fake docker: unhandled inspect format '$fmt'" >&2; exit 97 ;;
    esac
    exit 0 ;;
  logs) echo "[fake] api | 12:00:00.000 [info] boot log tail"; exit 0 ;;
  rm)   exit 0 ;;
  *) echo "fake docker: unhandled argv: $*" >&2; exit 97 ;;
esac
FAKE
chmod +x "$TMP/bin/docker"

# ── the mutant: the same script with the fix removed ─────────────────────────
mkdir -p "$TMP/mutant/scripts" "$TMP/real/scripts"
cp "$SMOKE" "$TMP/real/scripts/compose-smoke.sh"
# `$cid` below is a LITERAL: it is the text in compose-smoke.sh, not a variable here.
# shellcheck disable=SC2016
ANCHORS="$(grep -c 'assert_container_alive "\$cid"' "$SMOKE" || true)"
check "fix is present at all three call sites" 3 "$ANCHORS"
# shellcheck disable=SC2016
sed 's/^\( *\)assert_container_alive "\$cid".*/\1: # MUTATED: fix removed/' "$SMOKE" \
  > "$TMP/mutant/scripts/compose-smoke.sh"
chmod +x "$TMP/mutant/scripts/compose-smoke.sh" "$TMP/real/scripts/compose-smoke.sh"
MUT_DIFF="$(diff "$SMOKE" "$TMP/mutant/scripts/compose-smoke.sh" | grep -c '^>' || true)"
check "mutation applied (non-empty diff, one line per site)" 3 "$MUT_DIFF"
# shellcheck disable=SC2016
check "mutant carries no live call site" 0 \
  "$(grep -c '^ *assert_container_alive "\$cid"' "$TMP/mutant/scripts/compose-smoke.sh" || true)"

# ── the runner ──────────────────────────────────────────────────────────────
run() { # run <variant real|mutant> <scenario> -> writes $TMP/out, echoes rc
  local variant="$1" scenario="$2" st
  st="$TMP/state.$variant.$scenario"; rm -rf "$st"; mkdir -p "$st"
  FAKE_DOCKER_STATE="$st" FAKE_DOCKER_SCENARIO="$scenario" \
  COMPOSE_SMOKE_HEALTH_TIMEOUT=10 \
  PATH="$TMP/bin:$PATH" \
    bash "$TMP/$variant/scripts/compose-smoke.sh" green > "$TMP/out" 2>&1
  echo $?
}

STATE_MSG='api container is not cleanly running'
WGET_MSG='in-container wget /api/schemas failed'
LOGIN_MSG='in-container wget /login failed'

echo ""
echo "== 0. RED WITHOUT THE FIX — the mutant reproduces the filed symptom =="
rc="$(run mutant death)"
sed -n '1,40p' "$TMP/out"
check "mutant: green arm fails"                        1 "$rc"
check "mutant: blames the wget probe (the WRONG cause)" 1 "$(has "$TMP/out" "$WGET_MSG")"
check "mutant: never names the container state"         0 "$(has "$TMP/out" "$STATE_MSG")"
check "mutant: reached healthy first"                   1 "$(has "$TMP/out" 'api healthcheck healthy')"

echo ""
echo "== 1. GREEN WITH THE FIX — the same death now names the container =="
rc="$(run real death)"
sed -n '1,40p' "$TMP/out"
check "real: green arm fails"                           1 "$rc"
check "real: names the container state (the RIGHT cause)" 1 "$(has "$TMP/out" "$STATE_MSG")"
check "real: reports running=false restarts=1"          1 "$(has "$TMP/out" 'running=false restarts=1')"
check "real: does NOT blame the wget probe"             0 "$(has "$TMP/out" "$WGET_MSG")"
check "real: carries the docker logs tail"              1 "$(has "$TMP/out" '[fake] api |')"
check "real: says where it re-inspected"                1 "$(has "$TMP/out" 'after the health-wait loop')"

echo ""
echo "== 2. THE SIBLING PROBE — /login, derived from the script's own exec set =="
EXECS="$(grep -c 'compose exec -T api wget' "$SMOKE" || true)"
check "the green arm has exactly two in-container probes" 2 "$EXECS"
rc="$(run mutant death_login)"
check "mutant: a death before /login blames the /login wget" 1 "$(has "$TMP/out" "$LOGIN_MSG")"
check "mutant: never names the container state"          0 "$(has "$TMP/out" "$STATE_MSG")"
rc="$(run real death_login)"
sed -n '1,40p' "$TMP/out"
check "real: /api/schemas still passed"                  1 "$(has "$TMP/out" '/api/schemas serves in-container')"
check "real: names the container state at /login"        1 "$(has "$TMP/out" "$STATE_MSG")"
check "real: does NOT blame the /login wget"             0 "$(has "$TMP/out" "$LOGIN_MSG")"
check "real: says where it re-inspected"                 1 "$(has "$TMP/out" 'the failed /login probe')"

echo ""
echo "== 3. NEGATIVE ARM — container fine, route 500s: still a PROBE failure =="
rc="$(run real http500)"
sed -n '1,40p' "$TMP/out"
check "real: green arm fails"                            1 "$rc"
check "real: blames the wget probe"                      1 "$(has "$TMP/out" "$WGET_MSG")"
check "real: does NOT relabel it a container death"      0 "$(has "$TMP/out" "$STATE_MSG")"

echo ""
echo "== 4. NON-VACUITY — an all-healthy run must still pass end to end =="
rc="$(run real ok)"
check "real: a clean run exits 0"                        0 "$rc"
check "real: both probes passed"                         1 "$(has "$TMP/out" '/login serves in-container')"
check "real: no container-state message on a clean run"  0 "$(has "$TMP/out" "$STATE_MSG")"
# The fake refuses unknown argv with 97; a clean run proves we modelled the
# real argv shapes rather than swallowing them.
check "fake docker met no unhandled argv"                0 "$(has "$TMP/out" 'unhandled')"

echo ""
echo "---"
echo "compose-smoke green-arm cause attribution: $pass passed, $fail failed, $cases cases"
# COUNT FLOOR. A harness whose cases stopped running is a harness that passes
# for the wrong reason. Every case above is unconditional, so the count is a
# constant: if it drops, something silently stopped executing.
FLOOR=22
if [ "$cases" -lt "$FLOOR" ]; then
  echo "FAIL: only $cases cases ran, floor is $FLOOR — the harness went partly vacuous." >&2
  exit 2
fi
[ "$fail" = 0 ]
