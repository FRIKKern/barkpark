#!/usr/bin/env bash
# compose-smoke — the self-host compose stack's gate (self-host-blessing S6).
#
# The FIRST CI gate that has ever built api/Dockerfile (charter D1). Driven by
# .github/workflows/compose-smoke.yml; each subcommand's exit code IS the gate
# (create-quickstart-smoke idiom: one script, one final status, no partial green).
#
# Subcommands:
#   refusal        REFUSAL ARM (D20). Compose up with a SHORT SECRET_KEY_BASE and
#                  otherwise-valid generated secrets. The api container must EXIT
#                  NON-ZERO at the migrate step and its logs must carry the anchor
#                  line from runtime.exs's boot refusal. NEVER an HTTP probe:
#                  Plug's 64-byte floor is LAZY — a short secret serves
#                  /status.json 200 and only 500s on /login — so an HTTP probe of
#                  /status.json is structurally blind to the trap (measured).
#   green          GREEN ARM (D20). Generated secrets → compose up → healthcheck
#                  healthy → IN-CONTAINER `docker compose exec api wget` of
#                  /status.json AND /login (the session route — the one Plug's
#                  floor actually protects), both must succeed. Never a host-port
#                  curl: a host beam.smp already bound to :4000 produced a
#                  measured false 200.
#                  Then BUILD IDENTITY: /status.json's version and the authed
#                  /v1/capabilities?build=1 block must both carry a real vA.B.C
#                  release, never the literal "unknown" (task-2ab4f5f0a07e887a).
#                  See assert_build_identity below for why a green boot proves
#                  nothing about it.
#   census         scripts/env-census.py over BOTH runtime roots (api + cloud);
#                  any drift between code's env reads and the compose passthrough
#                  allowlists is a failure (charter D14/D15).
#   blessing-grep  D23: no blessing language on the self-host surface before the
#                  W2 runbook exists. The hedge word is "experimental".
#
# The D17 skip-the-image escape hatch is FORBIDDEN here and in the workflow —
# by name, which is why this file never spells it: vix builds fine on musl with
# no libvips (measured), and skipping the image build would be the D4
# anti-pattern inside the D1 gate.
#
# Timeouts: local measures are order-of-magnitude only (cold build 114s, boot
# 25s on a warm laptop). Ceilings below are derived for a cold shared runner:
# health wait defaults to 600s (first boot runs migrations + seeds behind a
# start_period of 300s); override with COMPOSE_SMOKE_HEALTH_TIMEOUT for slower
# hosts. The workflow's job-level timeout-minutes bounds everything else.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# The refusal's first line in api/config/runtime.exs (S1c, PR #10953). The
# "(#{got})" suffix varies; this prefix does not.
ANCHOR='SECRET_KEY_BASE must be at least 64 bytes'

note() { printf '»» %s\n' "$*"; }
pass() { printf 'PASS  %s\n' "$*"; }
die()  { printf 'FAIL  %s\n' "$*" >&2; exit 1; }

# ── shared plumbing ──────────────────────────────────────────────────────────

PROJECT=""

compose() { docker compose -p "$PROJECT" "$@"; }

cleanup() {
  local rc=$?
  if [ -n "$PROJECT" ]; then
    note "cleanup: docker compose -p $PROJECT down"
    docker compose -p "$PROJECT" down -v --remove-orphans >/dev/null 2>&1 || true
    docker rm -f "${PROJECT}-probe" >/dev/null 2>&1 || true
  fi
  exit "$rc"
}

# Every secret the compose file hard-requires (`:?`), minted fresh per run with
# the same commands .env.example teaches. SECRET_KEY_BASE is deliberately NOT
# set here — each arm sets its own (that difference IS the experiment).
export_common_env() {
  BARKPARK_CLOAK_KEY="$(openssl rand -base64 32)"
  BARKPARK_KEK="$(openssl rand -base64 32)"                        # decodes to exactly 32 bytes (D12)
  PREVIEW_JWT_SECRET="$(openssl rand -base64 32)"
  BARKPARK_RELEASE_CAPTURE_HMAC_SECRET="$(openssl rand -base64 32)" # >= 32 bytes required
  PHX_HOST=localhost
  # The BUILD-IDENTITY probe in the green arm reads /v1/capabilities?build=1,
  # and `maybe_put_build/3` withholds the build block from tier "none" — an
  # anonymous read of that URL is structurally blind to the thing under test.
  # `Barkpark.Seeds.Clean.bootstrap_admin_token/1` installs THIS value when it
  # is set (the `bp setup` path), so entrypoint.sh's seed step hands the probe a
  # real admin credential. Minted per run, never a fixed literal.
  BARKPARK_SEED_ADMIN_TOKEN="bp_admin_$(openssl rand -hex 24)"
  export BARKPARK_CLOAK_KEY BARKPARK_KEK PREVIEW_JWT_SECRET \
    BARKPARK_RELEASE_CAPTURE_HMAC_SECRET PHX_HOST BARKPARK_SEED_ADMIN_TOKEN
}

# ── refusal arm ──────────────────────────────────────────────────────────────

arm_refusal() {
  PROJECT=bp-smoke-refusal
  trap cleanup EXIT

  export_common_env
  # 27 bytes — the same class as the old docker-compose.yml:23 pseudo-default
  # (26-byte `$(openssl rand -base64 48)` literal) that booted clean and 500'd
  # the first session. Under the S1c refusal this must now die AT BOOT.
  export SECRET_KEY_BASE='deliberately-short-27-bytes'

  note "refusal arm: building the image (api/Dockerfile, repo-root context)"
  compose build api

  note "refusal arm: starting db and waiting for healthy"
  compose up -d --wait db

  local log rc
  log="$(mktemp -t compose-smoke-refusal.XXXXXX)"
  note "refusal arm: running the api container (entrypoint = migrate → seed → serve)"
  set +e
  compose run --no-deps --name "${PROJECT}-probe" api >"$log" 2>&1
  rc=$?
  set -e
  # Belt and braces: the attached run output IS the container's log stream, but
  # grep the daemon-side log too in case the attach dropped bytes.
  docker logs "${PROJECT}-probe" >>"$log" 2>&1 || true

  echo "── container output ──"
  cat "$log"
  echo "──────────────────────"

  if [ "$rc" -eq 0 ]; then
    die "refusal arm: api container exited 0 with a ${#SECRET_KEY_BASE}-byte SECRET_KEY_BASE — the boot refusal did not fire"
  fi
  pass "api container exited non-zero (rc=$rc) at the migrate step — it never reached serving"

  # The assertion is the LOG ANCHOR, never an HTTP probe (see header).
  if ! grep -F -q "$ANCHOR" "$log"; then
    die "refusal arm: container logs do not contain the anchor line '$ANCHOR'"
  fi
  pass "container logs carry the anchor: '$ANCHOR'"
  rm -f "$log"
}

# Re-inspect the container's liveness and, when it has MOVED, fail with the
# container-state cause rather than the caller's cause.
#
# THE DEFECT THIS CLOSES. The health-wait loop below inspects Running /
# RestartCount / Health.Status every 5s and dies with a precise container-state
# message — but it `break`s the moment health reads healthy, and nothing
# re-inspected those two signals ever again. The very next statement was the
# in-container wget. So a container that died, restarted, or lost its listener
# in the window between the last health probe and the exec was reported as
# "in-container wget /status.json failed": an HTTP probe failure, when what
# actually happened was a boot crash. Measured twice (#12879, #12889); it sent
# two investigations at the diff instead of at the boot.
#
# Called after the loop breaks AND on every probe failure, so an exec that
# cannot connect always answers "is the container still there?" before blaming
# the request. When the container IS still cleanly running this is a no-op and
# the caller's own probe-failure message stands (that is the negative arm).
assert_container_alive() { # assert_container_alive <cid> <where>
  local cid="$1" where="$2" running restarts status
  running="$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null || echo unknown)"
  restarts="$(docker inspect -f '{{.RestartCount}}' "$cid" 2>/dev/null || echo unknown)"
  status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null || echo unknown)"
  if [ "$running" = "true" ] && [ "$restarts" = "0" ]; then
    return 0
  fi
  note "green arm: container re-inspected at ${where} — it is no longer cleanly running"
  echo "── api container logs ──"
  docker logs --tail 100 "$cid" 2>&1 || true
  echo "────────────────────────"
  die "green arm: api container is not cleanly running (running=$running restarts=$restarts health=$status) — with valid generated secrets a boot must never crash or restart"
}

# ── green arm ────────────────────────────────────────────────────────────────

arm_green() {
  PROJECT=bp-smoke-green
  trap cleanup EXIT

  export_common_env
  export SECRET_KEY_BASE="$(openssl rand -base64 64)"   # 88 chars — margin above the 64-byte floor

  note "green arm: building the image (api/Dockerfile, repo-root context)"
  compose build

  note "green arm: docker compose up -d"
  compose up -d

  local cid
  cid="$(compose ps -q api)"
  [ -n "$cid" ] || die "green arm: no api container after up -d"

  local timeout="${COMPOSE_SMOKE_HEALTH_TIMEOUT:-600}"
  local waited=0 status running restarts
  note "green arm: waiting up to ${timeout}s for the api healthcheck (first boot = migrations + seeds)"
  while :; do
    running="$(docker inspect -f '{{.State.Running}}' "$cid")"
    restarts="$(docker inspect -f '{{.RestartCount}}' "$cid")"
    status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid")"
    if [ "$restarts" != "0" ] || { [ "$running" != "true" ] && [ "$status" != "healthy" ]; }; then
      echo "── api container logs ──"
      docker logs "$cid" 2>&1 | tail -n 100
      echo "────────────────────────"
      die "green arm: api container is not cleanly running (running=$running restarts=$restarts health=$status) — with valid generated secrets a boot must never crash or restart"
    fi
    if [ "$status" = "healthy" ]; then
      break
    fi
    if [ "$waited" -ge "$timeout" ]; then
      echo "── api container logs ──"
      docker logs "$cid" 2>&1 | tail -n 100
      echo "────────────────────────"
      die "green arm: healthcheck not healthy after ${timeout}s (status=$status)"
    fi
    sleep 5
    waited=$((waited + 5))
  done
  pass "api healthcheck healthy after ~${waited}s"

  # The loop can only have broken on health=healthy. That is a PAST observation;
  # re-read the present before the probes attribute anything to HTTP.
  assert_container_alive "$cid" "after the health-wait loop"

  # IN-CONTAINER probes via exec, verbatim the charter D20 commands. busybox
  # wget exits non-zero on any HTTP error status, so exit 0 asserts the 200.
  note "green arm: in-container probe /status.json"
  if ! compose exec -T api wget -q -O /dev/null http://localhost:4000/status.json; then
    assert_container_alive "$cid" "the failed /status.json probe"
    die "green arm: in-container wget /status.json failed"
  fi
  pass "/status.json serves in-container"

  # /login is the SESSION route — the only probe Plug's lazy 64-byte floor can
  # actually fail. /status.json alone is structurally blind to a short secret.
  note "green arm: in-container probe /login (session route)"
  if ! compose exec -T api wget -q -O /dev/null http://localhost:4000/login; then
    assert_container_alive "$cid" "the failed /login probe"
    die "green arm: in-container wget /login failed — the session route is the one a bad SECRET_KEY_BASE breaks"
  fi
  pass "/login serves in-container — session key derivation works"

  assert_build_identity "$cid"
  assert_liveview_mount "$cid"
  assert_plugin_census "$cid"
}

# ── LiveView mount (task-0b75a09ab8057598) ───────────────────────────────────
#
# WHY LIVENESS IS NOT ENOUGH. Every probe above this line is a plain controller:
# /status.json, /login, /v1/capabilities. NONE of them mounts a LiveView, and
# gh-8461 was a release-only crash in `BarkparkWeb.LiveAuth.authorize/4` —
# `dev_browser_token_fallback/0` called `Mix.env()`, which `mix release` does not
# ship. Every :admin / :ops / :scoped_admin mount raised UndefinedFunctionError
# in the image while the two probed controller routes stayed perfectly green.
# The release booted, reported healthy, served both probes, and the entire
# Studio admin surface was dead behind them.
#
# WHY AN UNAUTHENTICATED DEAD RENDER IS THE RIGHT PROBE, not a weaker one.
# `authorize/4` builds its candidate list as
# `Enum.filter([dev_browser_token_fallback(), session["api_token"]], &is_binary/1)`
# — the fallback is called UNCONDITIONALLY, before anything looks at the
# session. So an anonymous disconnected-render GET of an :admin route runs the
# whole on_mount chain and would have hit the gh-8461 raise. It needs no cookie
# jar, no CSRF scrape and no websocket client: one wget, and it lands exactly
# where the bug lived. A healthy build halts that chain with a 302 to the denial
# target; a broken one 500s.
#
# WHAT THIS DOES NOT CLAIM. It never reaches the LiveView module's own mount/3
# (the on_mount chain halts first), so a crash INSIDE a specific LiveView is out
# of its reach. It covers the on_mount/live_session layer — the shared code path
# every admin and ops LiveView goes through, and the one gh-8461 broke.
#
# THE DISCRIMINATION c0 REQUIRES. wget's exit code alone cannot tell a mount
# crash from a container that stopped answering — both are non-zero. So this
# reads the STATUS LINE out of `wget -S`: no HTTP status line at all is a
# CONNECTION failure (and re-inspects the container before blaming anything),
# a 5xx is a MOUNT CRASH, and anything else passes with the code printed.
# `--max-redirect=0` keeps the 302 visible instead of following it to a 200.
LIVE_PROBE_PATH="${COMPOSE_SMOKE_LIVE_PATH:-/studio/org-admin}"

assert_liveview_mount() { # assert_liveview_mount <cid>
  local cid="$1" out status before logdelta anchor
  out="$(mktemp -t compose-smoke-live.XXXXXX)"
  logdelta="$(mktemp -t compose-smoke-livelog.XXXXXX)"

  # Mark where the container log is NOW, so the anchor grep below reads only
  # what THIS probe produced. Grepping the whole boot log would blame the mount
  # for anything that happened during migrations or seeding.
  before="$(docker logs "$cid" 2>&1 | wc -l | tr -d " ")"

  note "green arm: in-container LiveView dead render ${LIVE_PROBE_PATH} (on_mount chain)"
  set +e
  compose exec -T api wget -S -O /dev/null --max-redirect=0 \
    "http://localhost:4000${LIVE_PROBE_PATH}" >"$out" 2>&1
  set -e

  # wget -S writes the response headers to stderr, which is folded into $out.
  status="$(sed -n "s|^ *HTTP/[0-9.]* \([0-9][0-9][0-9]\).*|\1|p" "$out" | head -1)"

  if [ -z "$status" ]; then
    echo "── wget output ──"
    cat "$out"
    echo "─────────────────"
    assert_container_alive "$cid" "the failed ${LIVE_PROBE_PATH} dead-render probe"
    die "green arm: ${LIVE_PROBE_PATH} returned NO HTTP status line — a connection failure, not a mount verdict. The container is still cleanly running, so the listener answered nothing at all."
  fi

  case "$status" in
    5*)
      echo "── wget output ──"
      cat "$out"
      echo "─────────────────"
      echo "── container logs since the probe ──"
      docker logs "$cid" 2>&1 | tail -n +$((before + 1))
      echo "────────────────────────────────────"
      die "green arm: ${LIVE_PROBE_PATH} answered HTTP ${status} — the LiveView MOUNT CRASHED in the release image. This is the gh-8461 shape: the container is healthy, the controller routes serve, and every admin/ops mount is dead."
      ;;
  esac
  pass "${LIVE_PROBE_PATH} dead render answered HTTP ${status} — the on_mount chain ran without raising"

  # THE CHEAP NET, in the refusal arm's shape: a log ANCHOR grepped out of a
  # FILE (never `printf | grep -q`, which returns 141 under pipefail when grep
  # -q exits early). A mount that crashes logs loudly even when the status line
  # is rewritten by an error handler, so this catches the shape the status code
  # can miss. Scoped to the lines this probe produced.
  docker logs "$cid" 2>&1 | tail -n +$((before + 1)) >"$logdelta"
  for anchor in "UndefinedFunctionError" "(exit) an exception was raised"; do
    if grep -F -q "$anchor" "$logdelta"; then
      echo "── container logs since the probe ──"
      cat "$logdelta"
      echo "────────────────────────────────────"
      die "green arm: the ${LIVE_PROBE_PATH} dead render logged '$anchor' — a mount-time crash, whatever status code came back"
    fi
  done
  pass "no mount-crash anchor in the container log for ${LIVE_PROBE_PATH}"
  rm -f "$out" "$logdelta"
}

# ── plugin census (task-a6ef8e3b2c78054f) ────────────────────────────────────
#
# WHY A LIVENESS PROBE CAN NEVER BE SUFFICIENT HERE. `Plugins.Bootstrap` is
# deliberately degradation-tolerant: `do_install_for_plugin/3` wraps the
# plugin's `register_schemas/1` in a try/rescue, LOGS the raise, and returns
# `{:error, {:raised, ...}}`; `register_all_schemas/0` folds those into a return
# value and never raises. Boot continues. The container reaches
# healthcheck-healthy and every HTTP route above answers 200 with whatever
# schemas DID register. That is how this gate's green arm reported PASS for
# weeks while six of nine plugins were dead in every released build (PR #13708 /
# task-f44c1839cb28b0af). No number of HTTP probes fixes that, because the
# failure is swallowed before it can reach a response.
#
# SO THIS PROBE READS REGISTRATION OUTCOME. `Barkpark.Plugins.Census` (shipped
# by #16197 for exactly this purpose) reads `Plugins.Registry.all/0` against
# what `Plugins.RunStatus` recorded when `register_all_schemas/0` walked the
# registry at boot, and returns `ok: false` plus a `failed` list if any plugin
# raised, returned a non-list, had its module fail to load, or was never
# reached.
#
# `rpc`, NOT `eval`, AND NOT `cli/0`. RunStatus is an in-memory GenServer in the
# RUNNING node (run_status.ex: "Tiny in-memory GenServer"), so `bin/barkpark
# eval` — a fresh node with no application state — would census an empty
# RunStatus and report every plugin `"not_registered"`: a false red, or worse, a
# green read of nothing. And `Census.cli/0`, which the module doc offers as the
# release entry point, ends in `System.halt/1` — over `rpc` that halts the
# RUNNING API NODE, killing the container mid-gate. This calls `report_json/0`
# and makes the assertion in the shell instead.
#
# THE EVIDENCE REQUIREMENT (criterion 3 of the row). A green run must let a
# reader tell "the stack booted" from "the stack booted correctly", so the
# counts and the per-plugin schema type names are PRINTED on success, not only
# on failure.
#
# VACUITY FLOOR. A census that saw zero plugins is a green with no subject. This
# image compiles the whole plugin registry in, so zero means the census read
# nothing — that is a failure here. A deliberately plugin-free build sets
# COMPOSE_SMOKE_MIN_PLUGINS=0 and says so out loud.
assert_plugin_census() { # assert_plugin_census <cid>
  local cid="$1" raw json ok failed counts min
  min="${COMPOSE_SMOKE_MIN_PLUGINS:-1}"
  raw="$(mktemp -t compose-smoke-census.XXXXXX)"

  note "green arm: in-container plugin census (registration OUTCOME, never liveness)"
  if ! compose exec -T api bin/barkpark rpc \
        "IO.puts(Barkpark.Plugins.Census.report_json())" >"$raw" 2>&1; then
    echo "── rpc output ──"
    cat "$raw"
    echo "────────────────"
    assert_container_alive "$cid" "the failed plugin-census rpc"
    die "green arm: could not read the plugin census in-container (bin/barkpark rpc Barkpark.Plugins.Census.report_json/0)"
  fi

  # The envelope is one line of JSON; `rpc` may print banner lines around it.
  json="$(grep -m1 "^{" "$raw" || true)"
  if [ -z "$json" ]; then
    echo "── rpc output ──"
    cat "$raw"
    echo "────────────────"
    die "green arm: the plugin census rpc printed no JSON envelope. Refusing to read a missing census as a healthy one."
  fi

  ok="$(printf "%s" "$json" | python3 -c "import json,sys; print(json.load(sys.stdin).get(\"ok\"))")"
  failed="$(printf "%s" "$json" | python3 -c "import json,sys; print(\",\".join(json.load(sys.stdin).get(\"failed\") or []))")"
  counts="$(printf "%s" "$json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get(\"plugin_count\",-1), d.get(\"schema_count\",-1))")"

  local plugin_count schema_count
  plugin_count="${counts%% *}"
  schema_count="${counts##* }"

  if [ "$plugin_count" -lt "$min" ]; then
    die "green arm: the plugin census saw ${plugin_count} plugins, floor is ${min} — a census of nothing is a green with no subject. If this image is deliberately plugin-free, set COMPOSE_SMOKE_MIN_PLUGINS=0."
  fi

  if [ "$ok" != "True" ]; then
    echo "── plugin census ──"
    printf "%s" "$json" | python3 -m json.tool
    echo "───────────────────"
    die "green arm: plugins failed to register their document types in the release image: ${failed:-<none named>}. Boot continued anyway — Plugins.Bootstrap rescues and logs — which is exactly why the HTTP probes above are all green."
  fi

  # NAME WHAT REGISTERED. This is the line that lets a reader tell a correct
  # boot from a merely live one.
  printf "%s" "$json" | python3 -c "
import json,sys
d = json.load(sys.stdin)
for p in d.get('plugins', []):
    print('      %-14s %-18s %2d  %s' % (p.get('name'), p.get('status'), p.get('schema_count', 0), ', '.join(p.get('schemas') or [])))
"
  pass "plugin census ok: ${plugin_count} plugins registered ${schema_count} schemas, 0 failed"
  rm -f "$raw"
}

# ── build identity (task-2ab4f5f0a07e887a) ───────────────────────────────────
#
# WHY THIS IS A GATE AND NOT A NICETY. `.git` is excluded from this image's
# build context (api/Dockerfile.dockerignore), so Barkpark.BuildInfo's
# `git describe` tier CANNOT fire inside the image — the identity comes from the
# checked-in VERSION file the Dockerfile COPYs, or from nowhere. When it comes
# from nowhere the failure is SILENT and the image is otherwise perfectly green:
# it builds, boots, reaches healthy and serves both probes above, while
# `Barkpark.SelfUpdate.Checker.run_check/0` parses BuildInfo.release() with
# ^\d+\.\d+\.\d+$, takes its {:running, :error} arm, and reports
# `running release is "unknown" (no vA.B.C build tag)` FOREVER. The update check
# is then structurally dead on the one install shape it exists for, and the
# Studio nav renders `Barkpark vunknown · unknown`. Every existing arm of this
# script is blind to that, by construction.
#
# TWO SURFACES, ON PURPOSE:
#   * /status.json      — public, unauthenticated, and what an operator reads.
#                         Carries BuildInfo.version() verbatim.
#   * /v1/capabilities?build=1 — the manifest block every SDK/CLI consumer sees,
#                         and the surface the task names. It is AUTHED: the
#                         build key is withheld from tier "none", so this probe
#                         uses the admin token export_common_env seeded.
# The release assertion below applies EXACTLY the regex parse_release/1 applies,
# so a pass here is a statement about the checker, not a look-alike of it.
assert_build_identity() { # assert_build_identity <cid>
  local cid="$1" body version release caps

  note "green arm: in-container build identity — /status.json"
  if ! body="$(compose exec -T api wget -q -O - http://localhost:4000/status.json)"; then
    assert_container_alive "$cid" "the failed /status.json body read"
    die "green arm: could not read the /status.json body in-container"
  fi

  version="$(printf '%s' "$body" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("version",""))')"
  [ -n "$version" ] || die "green arm: /status.json carries no \"version\" key"

  if [ "$version" = "unknown" ]; then
    die "green arm: the image reports build version \"unknown\". This image compiles with NO .git, so BuildInfo's git tier cannot fire — the repo-root VERSION file is the tier that must, and it did not reach the build. Check the \`COPY VERSION /VERSION\` line in api/Dockerfile and that VERSION holds one A.B.C line."
  fi

  # A.B.C.D — BuildInfo's canonical shape. D is the commits-since-tag distance
  # and is 0 for a VERSION-file build, which is the honest value there.
  if ! printf '%s' "$version" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
    die "green arm: build version '$version' is not A.B.C.D"
  fi
  pass "/status.json reports build version $version (not \"unknown\")"

  release="$(printf '%s' "$version" | cut -d. -f1-3)"
  # VERBATIM parse_release/1 (api/lib/barkpark/self_update/checker.ex).
  if ! printf '%s' "$release" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    die "green arm: release '$release' fails SelfUpdate.Checker.parse_release/1's ^A.B.C\$ — run_check/0 would take its {:running, :error} arm forever"
  fi
  pass "release $release parses under parse_release/1 — run_check/0 cannot take the {:running, :error} arm"

  note "green arm: in-container build identity — /v1/capabilities?build=1 (authed)"
  if ! caps="$(compose exec -T api wget -q -O - \
        --header="Authorization: Bearer ${BARKPARK_SEED_ADMIN_TOKEN}" \
        'http://localhost:4000/v1/capabilities?build=1')"; then
    assert_container_alive "$cid" "the failed /v1/capabilities?build=1 read"
    die "green arm: could not read /v1/capabilities?build=1 in-container with the seeded admin token"
  fi

  local caps_release
  caps_release="$(printf '%s' "$caps" | python3 -c 'import json,sys; print((json.load(sys.stdin).get("build") or {}).get("release",""))')"
  if [ -z "$caps_release" ]; then
    die "green arm: /v1/capabilities?build=1 returned no build.release. The block is withheld from tier \"none\", so an empty value most likely means the seeded admin token was not accepted — not that the build identity is missing."
  fi
  if ! printf '%s' "$caps_release" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    die "green arm: the capabilities build block reports release '$caps_release', which parse_release/1 refuses"
  fi
  if [ "$caps_release" != "$release" ]; then
    die "green arm: /status.json and the capabilities build block disagree ($release vs $caps_release)"
  fi
  pass "capabilities build block reports release $caps_release — the manifest surface agrees with /status.json"
}

# ── env census (both roots) ──────────────────────────────────────────────────

arm_census() {
  note "census: scripts/env-census.py --root api"
  python3 scripts/env-census.py --root api
  note "census: scripts/env-census.py --root cloud"
  python3 scripts/env-census.py --root cloud
  pass "env census green on both runtime roots"
}

# ── blessing-word grep (D23) ─────────────────────────────────────────────────

arm_blessing_grep() {
  # The banned vocabulary, assembled by concatenation so this file can be
  # scanned by its own gate without matching itself. Hedge word: experimental.
  local words
  words='sup''ported|ble''ssed|production[- ]ready|offi''cial'

  # The self-host surface: the charter fence files that exist plus the install-
  # adjacent docs. docs/setup/SELF-HOST.md joins automatically when W2 lands it.
  local files=(
    docker-compose.yml
    .env.example
    cloud/docker-compose.yml
    cloud/.env.example
    api/Dockerfile
    api/Dockerfile.dockerignore
    api/entrypoint.sh
    scripts/env-census.py
    scripts/compose-smoke.sh
    .github/workflows/compose-smoke.yml
    deploy.sh
    README.md
    deploy/README.md
    docs/ops/PROD_OPS.md
    docs/setup/SETUP.md
    docs/setup/GO-LIVE.md
    docs/setup/SELF-HOST.md
  )

  local f allow hits bad=0
  for f in "${files[@]}"; do
    if [ ! -f "$f" ]; then
      note "blessing-grep: $f absent (ok — joins the scan when it lands)"
      continue
    fi
    # Per-file allowlist of KNOWN false positives (charter D23), pinned to the
    # exact phrase so new blessing prose in the same file still reds.
    case "$f" in
      deploy/README.md)     allow='not_sup''ported' ;;
      docs/ops/PROD_OPS.md) allow='offi''cial ARM64 binary' ;;
      README.md)            allow='offi''cial home' ;;
      *)                    allow='' ;;
    esac
    hits="$(grep -inE "$words" "$f" || true)"
    if [ -n "$allow" ] && [ -n "$hits" ]; then
      hits="$(printf '%s\n' "$hits" | grep -ivE "$allow" || true)"
    fi
    if [ -n "$hits" ]; then
      printf 'FAIL  blessing language in %s (the runbook does not exist yet — the hedge word is "experimental"):\n%s\n' "$f" "$hits" >&2
      bad=1
    fi
  done

  [ "$bad" -eq 0 ] || exit 1
  pass "no blessing language on the self-host surface"
}

# ── dispatch ─────────────────────────────────────────────────────────────────

case "${1:-}" in
  refusal)       arm_refusal ;;
  green)         arm_green ;;
  census)        arm_census ;;
  blessing-grep) arm_blessing_grep ;;
  *)
    echo "usage: $0 refusal|green|census|blessing-grep" >&2
    exit 2
    ;;
esac
