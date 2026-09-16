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
#     FAIL  green arm: in-container wget /status.json failed
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
# HOW THE MUTATION ARM WORKS. The fix is SEVEN `assert_container_alive` calls
# (it was three when this harness was written; #18391 added the build-identity,
# plugin-census and LiveView-mount probes). The harness makes a mutated COPY of
# the script with those calls stripped — refusing if the anchor does not match
# exactly seven times, so a mutation that did not apply can never read as a
# catch — and runs the same scenarios against it. The mutant must name wget;
# the real script must name the container state. That is the proof re-earning
# itself on every run, not a pasted transcript.
#
# The seven are pinned BY NAME, not only by count: each call site carries a
# distinct label saying where it re-inspects, and the registry below compares
# that label SET. A probe that moves reds with its own name printed, so the pin
# cannot be satisfied by bumping a number (task-7f59063625b9a410 c2).
#
# WHAT IT DOES NOT CLAIM. Nothing about the real image, the real boot, or the
# intermittent event itself. It claims only that when the container dies after
# healthy, the harness says so — and that when the container is fine and the
# route 500s, the harness still blames the route.
set -uo pipefail

# ── INTERPRETER GUARD — must stay ABOVE the first process substitution ──────
# This file uses `<(…)` in the call-site registry below. bash reads a script
# incrementally, so a POSIX-mode shell TRUNCATES at the first `<(` and can exit
# 0 having run only the prefix — a vacuous green. The shebang does not protect
# against `sh scripts/compose-smoke.test.sh`; these two arms do.
if [ -z "${BASH_VERSION:-}" ]; then
  echo "compose-smoke.test.sh: needs bash (this script uses process substitution); run: bash scripts/compose-smoke.test.sh" >&2
  exit 2
fi
case ":${SHELLOPTS:-}:" in
  *:posix:*)
    echo "compose-smoke.test.sh: bash is in POSIX mode (invoked as \`sh\`?), which cannot parse this script's process substitution; run: bash scripts/compose-smoke.test.sh" >&2
    exit 2
    ;;
esac

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
      url=""; body=0; hdrs=0; rpc=0
      for a in "$@"; do
        case "$a" in
          http://*) url="$a" ;;
          rpc)      rpc=1 ;;
          -S)       hdrs=1 ;;
        esac
      done
      # `wget -O -` reads the BODY; `-O /dev/null` only asserts the status.
      case "$*" in *"-O -"*) body=1 ;; esac

      # ── the plugin census (assert_plugin_census) ──────────────────────────
      if [ "$rpc" = 1 ]; then
        case "$sc" in
          census_rpc_down)
            echo "Could not contact remote node barkpark@localhost" >&2; exit 1 ;;
          census_no_json)
            echo "some banner line that is not a census"; exit 0 ;;
          census_failed)
            echo '{"ok":false,"plugin_count":9,"schema_count":5,"failed":["bulldocs","frt","media","onixedit","scaffy","sheets"],"plugins":[{"name":"bulldocs","module":"Elixir.Barkpark.Plugins.Bulldocs","status":"failed","schema_count":0,"schemas":[],"error":"%File.Error{}"}]}'
            exit 0 ;;
          census_empty)
            echo '{"ok":true,"plugin_count":0,"schema_count":0,"failed":[],"plugins":[]}'
            exit 0 ;;
          *)
            echo '{"ok":true,"plugin_count":9,"schema_count":14,"failed":[],"plugins":[{"name":"bulldocs","module":"Elixir.Barkpark.Plugins.Bulldocs","status":"ok","schema_count":1,"schemas":["paper"],"error":null},{"name":"sheets","module":"Elixir.Barkpark.Plugins.Sheets","status":"ok","schema_count":1,"schemas":["sheet"],"error":null}]}'
            exit 0 ;;
        esac
      fi

      # ── the LiveView dead render (assert_liveview_mount) ──────────────────
      case "$url" in
        */studio/*)
          touch "$st/probed"
          case "$sc" in
            live500)
              echo "  HTTP/1.1 500 Internal Server Error" >&2
              echo "wget: server returned error: HTTP/1.1 500 Internal Server Error" >&2
              exit 8 ;;
            live_noconn)
              echo "wget: can't connect to remote host: Connection refused" >&2; exit 4 ;;
            live_logcrash)
              # The status line looks fine; the crash is only in the log.
              echo "  HTTP/1.1 302 Found" >&2; exit 8 ;;
            *)
              echo "  HTTP/1.1 302 Found" >&2; exit 8 ;;
          esac ;;
      esac

      case "$sc:$url" in
        death:*)
          echo "wget: can't connect to remote host: Connection refused" >&2; exit 1 ;;
        death_login:*/login)
          echo "wget: can't connect to remote host: Connection refused" >&2; exit 1 ;;
        death_login:*)
          # /status.json still serves; the container dies right after it.
          touch "$st/dead"; exit 0 ;;
        http500:*/status.json)
          echo "wget: server returned error: HTTP/1.1 500 Internal Server Error" >&2; exit 1 ;;
      esac

      # ── build identity (assert_build_identity) reads two BODIES ───────────
      if [ "$body" = 1 ]; then
        case "$url" in
          */status.json)      echo '{"version":"0.42.7.0"}'; exit 0 ;;
          */v1/capabilities*) echo '{"build":{"release":"0.42.7"}}'; exit 0 ;;
        esac
      fi
      exit 0 ;;
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
  logs)
    echo "[fake] api | 12:00:00.000 [info] boot log tail"
    # THE DELTA the mount probe reads: lines that appear only AFTER the probe
    # has run. `live_logcrash` is the shape where the status line is innocent
    # and only the log names the crash.
    if [ -f "$st/probed" ] && [ "$sc" = live_logcrash ]; then
      echo "[fake] api | 12:00:01.000 [error] GenServer terminating"
      echo "[fake] api | 12:00:01.000 [error] ** (UndefinedFunctionError) function Mix.env/0 is undefined (module Mix is not available)"
    fi
    exit 0 ;;
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
check "fix is present at every call site" 7 "$ANCHORS"

# ── THE CALL SITES BY NAME, NOT BY COUNT (task-7f59063625b9a410 c2) ─────────
# The bare `7` above pinned a QUANTITY. A quantity that drifts reds with
# `want 7 got 8` and names nothing, so whoever moved it can satisfy the pin by
# bumping the number — which is how the previous pins (`want 3 got 5`,
# `want 2 got 4`) sat red on main for a day and were then closed by bumping.
# Every call site already carries a distinct second argument naming WHERE it
# re-inspects, so the set of those labels is a REGISTRY: adding, deleting or
# renaming a probe point reds below with the label printed, and the only way to
# satisfy it is to write the new name down.
ALIVE_LABELS() { # ALIVE_LABELS <file> -> the sorted second-argument set
  # shellcheck disable=SC2016
  sed -n 's/^ *assert_container_alive "\$cid" "\(.*\)".*/\1/p' "$1" | LC_ALL=C sort
}
ALIVE_EXPECTED="$(LC_ALL=C sort <<'REGISTRY'
after the health-wait loop
the failed /status.json probe
the failed /login probe
the failed ${LIVE_PROBE_PATH} dead-render probe
the failed plugin-census rpc
the failed /status.json body read
the failed /v1/capabilities?build=1 read
REGISTRY
)"
ALIVE_ACTUAL="$(ALIVE_LABELS "$SMOKE")"
if [ "$ALIVE_ACTUAL" != "$ALIVE_EXPECTED" ]; then
  echo "── assert_container_alive call sites moved. Name the movers, do not bump a number ──"
  diff <(printf '%s\n' "$ALIVE_EXPECTED") <(printf '%s\n' "$ALIVE_ACTUAL") || true
  echo "──────────────────────────────────────────────────────────────────────────────────"
fi
check "every call site is a REGISTERED, named probe point" 1 \
  "$([ "$ALIVE_ACTUAL" = "$ALIVE_EXPECTED" ] && echo 1 || echo 0)"
# FIRES-WHEN-IT-SHOULD. Present-in-file is not a guard. Rename ONE label in a
# copy and the comparison above must go to 0 — otherwise the registry is inert
# and would accept a silently-moved probe point.
ALIVE_RENAMED="$(ALIVE_LABELS "$SMOKE" | sed '1s/.*/A LABEL NOBODY REGISTERED/' | LC_ALL=C sort)"
check "the registry FIRES on a renamed call site (control)" 0 \
  "$([ "$ALIVE_RENAMED" = "$ALIVE_EXPECTED" ] && echo 1 || echo 0)"
check "the control mutated exactly one label (not a vacuous no-op)" 1 \
  "$(diff <(printf '%s\n' "$ALIVE_ACTUAL") <(printf '%s\n' "$ALIVE_RENAMED") | grep -c '^> ' || true)"

# shellcheck disable=SC2016
sed 's/^\( *\)assert_container_alive "\$cid".*/\1: # MUTATED: fix removed/' "$SMOKE" \
  > "$TMP/mutant/scripts/compose-smoke.sh"
chmod +x "$TMP/mutant/scripts/compose-smoke.sh" "$TMP/real/scripts/compose-smoke.sh"
MUT_DIFF="$(diff "$SMOKE" "$TMP/mutant/scripts/compose-smoke.sh" | grep -c '^>' || true)"
check "mutation applied (non-empty diff, one line per site)" 7 "$MUT_DIFF"
# shellcheck disable=SC2016
check "mutant carries no live call site" 0 \
  "$(grep -c '^ *assert_container_alive "\$cid"' "$TMP/mutant/scripts/compose-smoke.sh" || true)"

# ── THE PRE-FIX MUTANT — the green arm as it stood before this slice ────────
# The mutation removes the two calls this slice adds, leaving exactly the arm
# that shipped: liveness + build identity, no registration outcome, no mount.
# It is the control for "a probe never seen red is not known to probe anything":
# against a release where six plugins are dead OR every admin mount 500s, THIS
# arm must still exit 0 — and the real one must not.
mkdir -p "$TMP/prefix/scripts"
# shellcheck disable=SC2016
NEWCALLS="$(grep -cE '^ *assert_(liveview_mount|plugin_census) "\$cid"' "$SMOKE" || true)"
check "both new probes are called from the green arm" 2 "$NEWCALLS"
sed -E 's/^( *)assert_(liveview_mount|plugin_census) "\$cid".*/\1: # PRE-FIX: probe removed/' "$SMOKE" \
  > "$TMP/prefix/scripts/compose-smoke.sh"
chmod +x "$TMP/prefix/scripts/compose-smoke.sh"
# shellcheck disable=SC2016
check "pre-fix mutant carries no live new-probe call" 0 \
  "$(grep -cE '^ *assert_(liveview_mount|plugin_census) "\$cid"' "$TMP/prefix/scripts/compose-smoke.sh" || true)"

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
WGET_MSG='in-container wget /status.json failed'
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
# DERIVED, NOT REMEMBERED. /status.json + /login + the two build-identity body
# reads + the LiveView dead render. If a probe is added or deleted, this reds
# and whoever moved it must say which.
check "the green arm has exactly five in-container wget probes" 5 "$EXECS"
rc="$(run mutant death_login)"
check "mutant: a death before /login blames the /login wget" 1 "$(has "$TMP/out" "$LOGIN_MSG")"
check "mutant: never names the container state"          0 "$(has "$TMP/out" "$STATE_MSG")"
rc="$(run real death_login)"
sed -n '1,40p' "$TMP/out"
check "real: /status.json still passed"                   1 "$(has "$TMP/out" '/status.json serves in-container')"
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
echo "== 5. PLUGIN CENSUS — registration OUTCOME reds where liveness passed =="
# task-a6ef8e3b2c78054f. The census fixture is the FILED defect verbatim: six of
# nine plugins failed to register, every HTTP route still serves.
CENSUS_MSG='plugins failed to register their document types'
rc="$(run prefix census_failed)"
check "PRE-FIX: six dead plugins PASS the old green arm"   0 "$rc"
check "PRE-FIX: never names the registration failure"      0 "$(has "$TMP/out" "$CENSUS_MSG")"
rc="$(run real census_failed)"
sed -n '1,60p' "$TMP/out"
check "real: six dead plugins RED the green arm"           1 "$rc"
check "real: names the registration failure"               1 "$(has "$TMP/out" "$CENSUS_MSG")"
check "real: names the culprit plugins"                    1 "$(has "$TMP/out" "bulldocs,frt,media,onixedit,scaffy,sheets")"
check "real: the HTTP probes were all green first"         1 "$(has "$TMP/out" '/login serves in-container')"
rc="$(run real census_empty)"
check "real: a census of ZERO plugins is not a pass"       1 "$rc"
check "real: names the vacuity floor"                      1 "$(has "$TMP/out" 'a green with no subject')"
rc="$(run real census_no_json)"
check "real: a census with no JSON envelope is not a pass" 1 "$rc"
check "real: refuses to read a missing census as healthy"  1 "$(has "$TMP/out" 'Refusing to read a missing census')"
rc="$(run real census_rpc_down)"
check "real: an unreachable census node fails"             1 "$rc"

echo ""
echo "== 6. LIVEVIEW MOUNT — a dead mount reds where the controllers passed =="
# task-0b75a09ab8057598. live500 is the gh-8461 shape: healthy container,
# controller routes green, every admin/ops mount 500s.
CRASH_MSG='the LiveView MOUNT CRASHED'
CONN_MSG='a connection failure, not a mount verdict'
rc="$(run prefix live500)"
check "PRE-FIX: a dead admin mount PASSES the old green arm" 0 "$rc"
check "PRE-FIX: never names the mount"                       0 "$(has "$TMP/out" "$CRASH_MSG")"
rc="$(run real live500)"
sed -n '1,60p' "$TMP/out"
check "real: a dead admin mount REDS the green arm"          1 "$rc"
check "real: names the mount crash"                          1 "$(has "$TMP/out" "$CRASH_MSG")"
check "real: does NOT call it a connection failure"          0 "$(has "$TMP/out" "$CONN_MSG")"
rc="$(run real live_noconn)"
check "real: no status line also fails"                      1 "$rc"
check "real: names it a CONNECTION failure, not a crash"     1 "$(has "$TMP/out" "$CONN_MSG")"
check "real: does NOT relabel it a mount crash"              0 "$(has "$TMP/out" "$CRASH_MSG")"
rc="$(run real live_logcrash)"
check "real: an innocent 302 with a crash in the log fails"  1 "$rc"
check "real: names the log anchor"                           1 "$(has "$TMP/out" 'UndefinedFunctionError')"
check "real: the 302 itself was accepted first"              1 "$(has "$TMP/out" 'answered HTTP 302')"

echo ""
echo "== 7. GREEN EVIDENCE — a pass NAMES what registered (a6ef c2) =="
rc="$(run real ok)"
check "real: a clean run still exits 0"                      0 "$rc"
check "real: the run log carries the schema COUNTS"          1 "$(has "$TMP/out" '9 plugins registered 14 schemas')"
check "real: the run log names the schema TYPE NAMES"        1 "$(has "$TMP/out" 'paper')"
check "real: the mount probe passed with its status code"    1 "$(has "$TMP/out" 'answered HTTP 302')"
check "real: no unhandled argv in the fullest scenario"      0 "$(has "$TMP/out" 'unhandled')"

echo ""
echo "---"
echo "compose-smoke green-arm cause attribution: $pass passed, $fail failed, $cases cases"
# COUNT FLOOR. A harness whose cases stopped running is a harness that passes
# for the wrong reason. Every case above is unconditional, so the count is a
# constant: if it drops, something silently stopped executing.
FLOOR=50
if [ "$cases" -lt "$FLOOR" ]; then
  echo "FAIL: only $cases cases ran, floor is $FLOOR — the harness went partly vacuous." >&2
  exit 2
fi
[ "$fail" = 0 ]
