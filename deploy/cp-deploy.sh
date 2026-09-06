#!/usr/bin/env bash
# Refresh the Barkpark Cloud CONTROL PLANE (barkpark.cloud / barkpark-cp) to
# origin/main. Run on the box as root (the CD workflow scps this + the
# cross-built provisioner binary, then executes it).
#
#   bash cp-deploy.sh [path-to-prebuilt-linux-amd64-provisioner]
#
# ZERO-DOWNTIME blue/green: the control plane is two compose slots behind
# profiles (blue=:4100, green=:4101); exactly one serves at a time and host
# Caddy proxies barkpark.cloud to its port. A deploy builds the image while
# the active slot keeps serving, boots the IDLE slot (auto-migrates on boot),
# health-gates it, then flips Caddy's upstream (graceful reload — no dropped
# connections) and stops the old slot. An unhealthy new slot is simply stopped
# again — the active slot is never touched, so a bad deploy costs no downtime.
# Consequence: migrations must be backward-compatible (expand/contract) for
# the seconds both slots overlap. Go is NOT installed on barkpark-cp, so the
# provisioner is cross-built by the runner and passed in.
set -uo pipefail

APP="${BARKPARK_APP_DIR:-/opt/barkpark}"
COMPOSE_FILE="$APP/cloud/docker-compose.yml"
CADDYFILE="${BARKPARK_CADDYFILE:-/etc/caddy/Caddyfile}"
LOCK="${BARKPARK_DEPLOY_LOCK:-/var/lock/barkpark-cp-deploy.lock}"
PROV_BIN="${1:-}"
log() { echo "[cp-deploy $(date -u +%H:%M:%S)] $*"; }
compose() { docker compose -f "$COMPOSE_FILE" --profile blue --profile green "$@"; }

# Serialize overlapping runs (back-to-back merges, manual + CD).
exec 9>"$LOCK"
if ! flock -n 9; then
  log "another deploy holds the lock — queueing (max 30 min)"
  flock -w 1800 9 || { log "gave up waiting for the deploy lock"; exit 15; }
fi

cd "$APP" || { log "no $APP"; exit 10; }
OLD="$(git rev-parse HEAD)"
log "current=$OLD"

# ---- Docker version: ASSERT it answers, and LOG it (dr-w20-bl-cp-deploy-...).
# The 48h47m blackout below is a DAEMON-BEHAVIOUR bug, and this box's docker is
# mutable state that no commit records: a reprovision, a snapshot rebake or an
# unattended upgrade can move it under us and nothing in the repo would date the
# change. Read off barkpark-cp on 2026-09-02 (L1): server 29.6.1, API 1.55,
# compose v5.2.0, containerd v2.2.5, runc 1.3.6, overlayfs — and `docker network
# disconnect -f` (the clearer below) confirmed present with its --force flag.
# A mismatch WARNS and never refuses: a stale pin that blocks every deploy is
# worse than drift you can read in the log (same call as the headroom guard).
DOCKER_VER="$(docker version --format '{{.Server.Version}}' 2>/dev/null)"
if [ -z "$DOCKER_VER" ]; then
  log "WARNING: 'docker version' did not answer — the daemon may be down or unreachable; continuing (compose will fail loudly if it is)"
else
  log "docker server $DOCKER_VER / compose $(docker compose version --short 2>/dev/null || echo '?')"
  EXPECT_DOCKER_MAJOR="${BARKPARK_EXPECT_DOCKER_MAJOR:-29}"
  case "$DOCKER_VER" in
    "$EXPECT_DOCKER_MAJOR".*) : ;;
    *) log "WARNING: docker server $DOCKER_VER is not the expected ${EXPECT_DOCKER_MAJOR}.x — deploy/ was written and verified against ${EXPECT_DOCKER_MAJOR}.x on barkpark-cp (2026-09-02); the wedged-endpoint clearer below leans on 'docker network disconnect -f' and 'docker network inspect', whose behaviour may differ. Override the expectation with BARKPARK_EXPECT_DOCKER_MAJOR." ;;
  esac
fi

docker tag cloud-control_plane:latest cloud-control_plane:rollback 2>/dev/null \
  && log "tagged rollback image" || log "no current image to tag (first deploy?)"

git checkout -- . 2>/dev/null || true
# ---- Probe origin BEFORE the pull and NAME the cause (task-a14a2f489452e95d).
# 2026-09-02 13:58Z-19:28Z every control-plane deploy died at the pull below with
# a bare "pull failed" (exit 11) while git's own stderr said
#     fatal: could not read Username for 'https://github.com': No such device or address
#     fatal: expected flush after ref listing
# THREE unrelated faults print that same first line, and the outage ran three
# hours because the deploy log named none of them:
#   PROTOCOL PIN STALE     — the pull's protocol.version=0 pin (see the block
#                            below) is itself what origin now refuses, while the
#                            default handshake succeeds from this box
#   REMOTE UNAUTHENTICATED — origin still serves anonymous reads, so this box's
#                            remote URL or credential helper is the broken part
#   REPO PRIVATE (or moved) — anonymous info/refs answers 401/404 (CLAUDE.md
#                            past-mistake #9): the box needs an authenticated
#                            remote before the repo can be private
# ls-remote is the same ref-listing handshake as the pull without a working-tree
# write, and it runs WITH THE PULL'S OWN protocol pin — a green probe therefore
# means the pull gets the same answer. Probing unpinned would have failed on the
# very box the pin was added for and turned this guard into the outage.
# On failure the differential runs (an unpinned retry, then an anonymous curl of
# info/refs), git's stderr is quoted VERBATIM, and the verdict lands in the log
# AND in an ::error:: line so the check-run summary carries the reason rather
# than a naked exit code.
# `timeout` is coreutils: present on the box, absent on a stock Mac running the harness.
PROBE_TIMEOUT="$(command -v timeout || command -v gtimeout || true)"
# shellcheck disable=SC2069  # `2>&1 >/dev/null` is deliberate and in this order: stderr
# takes the caller's stdout (the capture) and stdout goes to /dev/null, so the probe
# yields git's stderr ALONE. The order shellcheck suggests would capture the ref list.
probe_ls_remote() { ${PROBE_TIMEOUT:+$PROBE_TIMEOUT 60} git -c core.hooksPath=/dev/null "$@" ls-remote --exit-code -h origin main 2>&1 >/dev/null; }
log "git ls-remote origin (probe before pull, same protocol pin as the pull)"
PROBE_ERR="$(probe_ls_remote -c protocol.version=0)"
PROBE_RC=$?
if [ "$PROBE_RC" -ne 0 ]; then
  case "$PROBE_ERR" in
    *"could not read Username"*|*"Authentication failed"*|*"Repository not found"*|*" 403"*|*" 401"*)
      if probe_ls_remote >/dev/null 2>&1; then
        PROBE_WHY="PROTOCOL PIN STALE: origin refuses the pinned protocol.version=0 handshake but the default one succeeds from this box ($(git --version 2>/dev/null)) — drop the pin on the pull below"
      else
        ORIGIN_URL="$(git remote get-url origin 2>/dev/null)"
        INFO_REFS_CODE="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "${ORIGIN_URL%.git}.git/info/refs?service=git-upload-pack" 2>/dev/null || echo 000)"
        case "$INFO_REFS_CODE" in
          200) PROBE_WHY="REMOTE UNAUTHENTICATED: origin answers anonymous info/refs 200, so this box's remote or credential helper is broken, not the repo" ;;
          401|404) PROBE_WHY="REPO PRIVATE (or moved): anonymous info/refs answers $INFO_REFS_CODE — this box needs an authenticated remote before the repo can be private (CLAUDE.md past-mistake #9)" ;;
          *) PROBE_WHY="origin unreachable while probing info/refs (curl $INFO_REFS_CODE): network, DNS or a GitHub outage" ;;
        esac
      fi ;;
    *)
      case "$PROBE_RC" in
        124) PROBE_WHY="origin did not answer within 60 s (network, DNS or a GitHub outage)" ;;
        *)   PROBE_WHY="origin refused the ref listing (network, DNS, or a moved/renamed repo)" ;;
      esac ;;
  esac
  log "pull refused before it ran — $PROBE_WHY"
  printf '%s\n' "$PROBE_ERR" | sed 's/^/    git: /'
  echo "::error::cp-deploy: pull refused — $PROBE_WHY — $(printf '%s' "$PROBE_ERR" | head -1)"
  exit 11
fi
log "git pull"
# protocol.version=0 IS LOAD-BEARING — do not delete it as cargo cult because you
# cannot reproduce the failure from a modern box. THE OUTAGE IT ENDS (2026-09-02):
# every control-plane deploy from ~15:22Z failed here, and barkpark-cp sat 49
# commits behind (serving a5d8a53d; last good 12:33Z at fe8184d6) while the
# CONTENT-INSTANCE job of the very same workflow run succeeded every time.
#
# THE SIGNATURE, verbatim from six consecutive runs' control-plane job:
#     fatal: could not read Username for 'https://github.com': No such device or address
#     fatal: expected flush after ref listing
#
# THE MEASUREMENT that names the culprit: barkpark-cp runs git 2.34.1 (Ubuntu
# 22.04). From THAT box, with THAT remote and THOSE credentials (none — the repo
# is public and this fetch is anonymous), protocol v2 fails as above while
# protocol v0 AND v1 both succeed. Guerrilla runs git 2.43 and never failed,
# which is exactly why the instance job stayed green through all six runs. So the
# variable is the git version's protocol-v2 implementation, not the network, not
# the token, and NOT repository visibility — the "could not read Username" line
# reads like Past Mistake #9 (repo went private) and a sibling reader concluded
# precisely that; the v0/v1-succeed-from-the-same-box measurement is what
# separates the two. git 2.34.1's v2 ref-listing parse cannot survive GitHub's
# current advertisement, and it misreports the parse failure as an auth prompt.
#
# v0 rather than v1: both were measured working, and v0 is git's own pre-2.26
# default — the most-travelled server path there is, and the one value that
# needs no version negotiation at all. v1 is v0 plus a version handshake that
# exists mainly to exercise negotiation; it buys nothing here and takes the
# rarer code path on both ends.
#
# The -c rides the pull the same way the hook-path pin above it does; git
# exports it as GIT_CONFIG_PARAMETERS, so the `git fetch` that `git pull` forks
# inherits it (measured: the fetch advertises v0, not `version 2`).
# Remove this pin only once barkpark-cp's git is >= 2.43 AND you have re-run the
# v2 fetch from the box and watched it succeed.
git -c core.hooksPath=/dev/null -c protocol.version=0 pull --ff-only origin main || { log "pull failed"; exit 11; }
NEW="$(git rev-parse HEAD)"
log "target=$NEW"

# Secrets are passthrough — export cloud/.env so compose resolves them.
if [ ! -f cloud/.env ]; then log "MISSING cloud/.env — abort (containers untouched)"; git reset --hard "$OLD"; exit 12; fi
set -a; . cloud/.env; set +a

# The slot must be able to state which commit it serves (dr-w20-s1). Sourced
# from $NEW — the sha this run just checked out — never a second `git rev-parse`,
# so it can never disagree with what was actually deployed. This export sits
# AFTER the .env source on purpose: a stale BARKPARK_GIT_SHA left in cloud/.env
# must not be able to win. compose passes it through via the bare
# `- BARKPARK_GIT_SHA` line in cloud/docker-compose.yml; GET /health reads it.
export BARKPARK_GIT_SHA="$NEW"

# ---- Which slot serves now? Caddy's upstream port is the source of truth.
# SLOT PORTS ONLY (this used to grep the loose 'localhost:41[0-9]{2}'): any
# OTHER localhost:41xx line in the Caddyfile — a sibling service, an admin
# route, a future front — is picked up by `head -1` as if it were the active
# slot, and the flip sed below then rewrites THAT line instead of the real
# upstream. instance-deploy.sh pinned its own grep to exactly the two slot ports
# for precisely this reason; cp-deploy was left behind on the loose pattern.
#
# The ports are also read from the SAME place compose publishes them
# (PORT_BLUE/PORT_GREEN out of cloud/.env, sourced above), never hardcoded:
# `[ "$ACTIVE_PORT" = "4100" ]` compared a configurable port against a literal,
# so an operator who set PORT_BLUE/PORT_GREEN in cloud/.env silently inverted
# the slot derivation and every deploy targeted the LIVE slot.
BLUE_PORT="${PORT_BLUE:-4100}"
GREEN_PORT="${PORT_GREEN:-4101}"
ACTIVE_PORT="$(grep -oE "localhost:(${BLUE_PORT}|${GREEN_PORT})" "$CADDYFILE" | head -1 | cut -d: -f2)"
ACTIVE_PORT="${ACTIVE_PORT:-$BLUE_PORT}"
if [ "$ACTIVE_PORT" = "$BLUE_PORT" ]; then
  TARGET=green; TARGET_PORT="$GREEN_PORT"
else
  TARGET=blue; TARGET_PORT="$BLUE_PORT"
fi
# The target and the live port must DISAGREE. Deploying onto the port Caddy is
# already serving means recreating the LIVE container — every "active slot
# untouched / no downtime" claim in this log becomes a lie, and the health gate
# below then probes the very slot it is tearing down. This can only fire when
# the derivation above is wrong (PORT_BLUE and PORT_GREEN set to the same value,
# or a future edit that breaks the branch), so it never fires on a correctly
# configured box. Fail closed BEFORE anything is built, booted or stopped.
if [ "$TARGET_PORT" = "$ACTIVE_PORT" ]; then
  log "REFUSING: slot '$TARGET' resolves to :$TARGET_PORT, the port Caddy already serves — deploying there would recreate the LIVE container (check PORT_BLUE/PORT_GREEN in cloud/.env)"
  git reset --hard "$OLD"
  exit 16
fi
log "active upstream :$ACTIVE_PORT -> deploying slot '$TARGET' on :$TARGET_PORT"

# The slot that is SERVING RIGHT NOW — the one container the endpoint clearer
# below must never unplug. Derived from the SAME blue/green marker the flip
# uses (ACTIVE_PORT, read out of the Caddyfile above), never guessed, so the
# guard cannot disagree with the deploy about which slot is live.
if [ "$TARGET" = blue ]; then ACTIVE_SLOT=green; else ACTIVE_SLOT=blue; fi
CP_NETWORK="${BARKPARK_CP_NETWORK:-cloud_default}"
SERVING_CONTAINER="${COMPOSE_PROJECT_NAME:-cloud}-control_plane_${ACTIVE_SLOT}-1"

# db+postfix must NEVER be left stopped: a recreate (image/config changed by the
# pull) stops the old containers first, and on Docker 29 the follow-up network
# disconnect can 500 ("container … is not connected to the network") while the
# teardown is still settling — compose aborts BETWEEN stop-old and start-new. An
# immediate retry simply starts the already-created containers. Without this,
# every deploy after a cloud/ config change killed the db and the control plane
# served 500s on all DB-backed routes until someone noticed (16h on 2026-07-21,
# and re-broken by every subsequent merge — the site LOOKS up because the static
# SPA still serves).
#
# ===========================================================================
# THE WEDGED ENDPOINT (dr-w20-bl-cp-deploy-cannot-clear-a-wedged-endpoint)
# ===========================================================================
# THE OUTAGE. 2026-07-21T07:59:48Z .. 07-23T08:46:54Z: 48h47m, 121 deploy.yml
# runs, 84 failures, 37 cancelled, ZERO successes. 82 of the 84 are exit 13 and
# the SAME thing in two phrasings — the daemon refusing the recreate with
#   network cloud_default has active endpoints (name:"cloud-control_plane_green-1" id:"9a7aab2dba5b")
# (65 runs, this function) or its sibling
#   container ... is not connected to the network cloud_default
# (15 runs, the slot boot below). The endpoint id 9a7aab2dba5b is BYTE-IDENTICAL
# across 27 hours: ONE stale endpoint re-hit by every merge, not 84 independent
# races.
#
# WHY SLEEP-AND-RETRY IS NOT ENOUGH — MEASURED, NOT ASSUMED. The one-shot retry
# (#5584, 5866f3b90, 2026-07-22T01:05:26Z) was live for the blackout's final 27
# hours: 66 of the 84 failures land after it and 65 of those 66 carry `FAILED
# twice`. The retry is measured 0-FOR-65. That is not bad luck — a stale
# endpoint is DAEMON STATE, and sleeping 3 seconds does not remove daemon state,
# so the second `up` meets the identical refusal as the first. The retry is KEPT
# (it does clear the genuinely transient teardown race it was written for) but
# it can no longer be the only lever: a retry only helps once the blocker is
# GONE, and nothing here was removing the blocker.
#
# WHAT ACTUALLY ENDED IT, read off the box 2026-09-02 (L1, not CI logs):
#   docker network inspect cloud_default --format '{{.Created}}'
#     -> 2026-07-23T09:48:58.600589216Z
# while the daemon's own `bridge` network is dated 2026-07-22T00:58:15Z (=
# docker.service ExecMainStartTimestamp) and the box has not rebooted since
# 2026-06-29. So cloud_default was DESTROYED AND RECREATED BY HAND at 09:48:58Z
# — 17 minutes into the first successful run (29995701440, 09:31:55Z..09:57:36Z,
# 25m41s against a ~7min norm), which was sitting on this script's own
# `flock -w 1800` while the operator worked. No commit records any of it.
#
# The same read rules out the two cheaper remedies. `systemctl restart docker`
# was ALREADY TRIED, at 2026-07-22T00:58:14Z — 17h into the blackout — and the
# blackout ran 32 HOURS LONGER (no docker package moved: /var/log/apt shows only
# kernel/wget/sqlite3 that morning). And the retry is the 0-for-65 above.
#
# THE REMEDY THIS INSTALLS. Recreating the network is a full-downtime hammer: it
# requires every attached container stopped, the live DB and the SERVING slot
# included. `docker network disconnect -f` is the surgical form of the same act,
# and it is present on this box's docker (29.6.1, `-f, --force` confirmed). So:
# when the daemon says one of its OWN two strings, enumerate cloud_default's
# endpoints, disconnect the ones whose container NO LONGER EXISTS, and then
# retry — a retry that now happens after the blocker has been removed.

# Disconnect every $CP_NETWORK endpoint whose container is gone. Returns 0 when
# it cleared at least one (so a retry is worth something), 1 when it cleared
# nothing. Never fatal: this runs on a path that is already failing.
clear_wedged_endpoints() {
  cleared=0
  while IFS=' ' read -r cid cname; do
    [ -n "$cid" ] && [ -n "$cname" ] || continue
    # GUARD — NEVER unplug the slot that is serving traffic right now. A running
    # container's endpoint is not the fault anyway (the wedge is an endpoint
    # whose container is GONE), but this is the one mistake that would convert a
    # failed deploy into a live outage, so it is checked by name and first.
    if [ "$cname" = "${SERVING_CONTAINER:-}" ]; then
      log "endpoint '$cname' is the SERVING slot on :$ACTIVE_PORT — never disconnecting it"
      continue
    fi
    # STALE = the daemon still holds an endpoint for a container it no longer
    # has. A container that still exists is a legitimate attachment; leave it.
    # A dangling endpoint can also key as 'ep-<endpoint id>' with no container
    # at all, which is stale by construction.
    case "$cid" in
      ep-*) : ;;
      *) if docker inspect --type container "$cid" >/dev/null 2>&1; then continue; fi ;;
    esac
    log "STALE ENDPOINT on $CP_NETWORK: '$cname' (container $cid no longer exists) — docker network disconnect -f"
    if docker network disconnect -f "$CP_NETWORK" "$cname" >/dev/null 2>&1; then
      cleared=$((cleared + 1))
    else
      log "WARNING: could not disconnect '$cname' from $CP_NETWORK"
    fi
  done <<EOF
$(docker network inspect "$CP_NETWORK" --format '{{range $id, $c := .Containers}}{{$id}} {{$c.Name}}
{{end}}' 2>/dev/null)
EOF
  [ "$cleared" -gt 0 ]
}

# `compose up -d …` with the endpoint repair. On a failure it reads the DAEMON'S
# OWN WORDS to choose: the wedge (clear the stale endpoint, then retry) or the
# transient teardown race (#5584's sleep, then retry). Exactly one retry either
# way — the change is not "retry harder", it is "retry after removing the thing
# that refused you".
compose_up_repair() {
  what="$1"; shift
  out="$(compose up -d "$@" 2>&1)"; rc=$?
  [ -n "$out" ] && printf '%s\n' "$out"
  [ "$rc" = 0 ] && return 0
  if printf '%s' "$out" | grep -qE 'has active endpoints|is not connected to the network'; then
    log "$what: the daemon refused on a WEDGED ENDPOINT — the exact shape of the 2026-07-21 48h47m blackout, whose sleep-and-retry was measured 0-for-65. Clearing the endpoint BEFORE the retry."
    clear_wedged_endpoints || log "$what: the daemon named a wedged endpoint but none of $CP_NETWORK's endpoints is stale — retrying once anyway"
  else
    log "$what hit the recreate race — retrying"
    sleep 3
  fi
  out="$(compose up -d "$@" 2>&1)"; rc=$?
  [ -n "$out" ] && printf '%s\n' "$out"
  return "$rc"
}

ensure_shared_services() { compose_up_repair "db/postfix up" db postfix; }

# Rolls back git + image tag and stops the target slot; the active slot keeps
# serving throughout, so every abort path here is zero-downtime. Re-asserts
# db+postfix so no abort path can strand them stopped.
abort_deploy() {
  compose rm -sf "control_plane_$TARGET" >/dev/null 2>&1 || true
  docker tag cloud-control_plane:rollback cloud-control_plane:latest 2>/dev/null || true
  git reset --hard "$OLD"
  ensure_shared_services || log "WARNING: db/postfix still down after abort — API is dead until they start"
}

# A killed deploy (dropped SSH, cancelled CD run) must not strand db+postfix
# stopped mid-recreate either — that was the original 16h outage. EXIT alone is
# not enough: bash skips EXIT traps on an unhandled SIGHUP/TERM, and a dropped
# SSH session delivers exactly SIGHUP.
trap 'ensure_shared_services >/dev/null 2>&1 || true' EXIT
trap 'ensure_shared_services >/dev/null 2>&1 || true; exit 130' HUP INT TERM

# ---- Pre-build headroom guard (2026-08-31 outage: the box hit 100% of 38G —
# 839 never-pruned deploy images + 14GB build cache — and Postgres could not
# write pgsql_tmp, 500ing GET /v1/barkparks; the whole fleet surface went dark).
# A `docker compose build` on a nearly-full disk digs the hole DEEPER (build
# cache + a new image land before anything could be reclaimed) and the thing it
# starves is the LIVE DB sharing this filesystem — so below the floor we refuse
# outright, before any container is touched. Measures the filesystem holding
# docker's data (falls back to / when /var/lib/docker is not its own thing).
# Fails OPEN only when df itself cannot answer — a guard that refuses every
# deploy on a healthy box is worse than none (same call as the fleet build
# gate) — and that skip is logged loudly.
HEADROOM_PATH="${BARKPARK_HEADROOM_PATH:-/var/lib/docker}"
[ -d "$HEADROOM_PATH" ] || HEADROOM_PATH=/
MIN_FREE_GB="${BARKPARK_MIN_FREE_GB:-5}"
if ! echo "$MIN_FREE_GB" | grep -qE '^[0-9]+$'; then
  log "WARNING: BARKPARK_MIN_FREE_GB='$MIN_FREE_GB' is not a whole number of GB — using the default 5G floor"
  MIN_FREE_GB=5
fi
AVAIL_KB="$(df -Pk "$HEADROOM_PATH" 2>/dev/null | awk 'NR==2 {print $4}')"
if ! echo "$AVAIL_KB" | grep -qE '^[0-9]+$'; then
  log "WARNING: could not measure free space on $HEADROOM_PATH (df answered '$AVAIL_KB') — headroom guard SKIPPED, deploy continues"
elif [ "$AVAIL_KB" -lt "$((MIN_FREE_GB * 1024 * 1024))" ]; then
  AVAIL_H="$(awk "BEGIN{printf \"%.1fG\", $AVAIL_KB/1048576}")"
  log "REFUSING to build: only $AVAIL_H free on $HEADROOM_PATH, below the ${MIN_FREE_GB}G floor — a build on a full disk digs the hole deeper and can kill the live DB (2026-08-31: 100% disk 500'd the fleet API). Remediation: GitHub Actions -> cp-ops -> box-prune with box_ip pointed at THIS box, or on the box: docker image prune -af && docker builder prune -af. Floor override: BARKPARK_MIN_FREE_GB."
  git reset --hard "$OLD"
  exit 17
else
  AVAIL_H="$(awk "BEGIN{printf \"%.1fG\", $AVAIL_KB/1048576}")"
  log "headroom ok: $AVAIL_H free on $HEADROOM_PATH (floor ${MIN_FREE_GB}G)"
fi

log "docker compose build (active slot still serving)"
if ! compose build; then
  log "BUILD FAILED — reset + abort (no downtime)"; git reset --hard "$OLD"; exit 13
fi

# Free the target port if a stale/failed slot (or the pre-blue/green legacy
# `control_plane` service) still holds it, then boot the new slot.
for c in $(docker ps -q --filter "publish=$TARGET_PORT"); do
  log "stopping stale container on :$TARGET_PORT ($c)"; docker stop -t 30 "$c"
done
if ! ensure_shared_services; then
  log "db/postfix up FAILED twice — abort (active slot untouched)"; abort_deploy; exit 13
fi
log "boot slot $TARGET (auto-migrates on boot; active slot untouched)"
# Same repair: the slot's own up can trip the identical recreate race when it
# (re)starts db as a dependency, and it is the path that carried the blackout's
# SECOND phrasing ("container ... is not connected to the network cloud_default",
# 15 of the 84 runs) straight into SLOT BOOT FAILED.
if ! compose_up_repair "slot boot" --no-build "control_plane_$TARGET"; then
  log "SLOT BOOT FAILED — abort (active slot untouched)"; abort_deploy; exit 13
fi

ok=0
for _ in $(seq 1 36); do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 "http://localhost:${TARGET_PORT}/" || true)"
  # 404 is NOT accepted: it used to be, on the theory that "some route
  # answered" proves a live app — but a container that serves nothing but
  # 404s (image booted, app crashed, wrong port, static server up with the
  # SPA missing) is exactly the broken-deploy shape this gate exists to
  # catch, and 404 waved it through as "healthy". Only redirect/success on
  # '/' counts now.
  if echo "$code" | grep -qE '^(200|301|302)$'; then ok=1; log "slot $TARGET healthy ($code)"; break; fi
  sleep 5
done
if [ "$ok" != "1" ]; then
  log "slot $TARGET UNHEALTHY — stopping it; :$ACTIVE_PORT was never touched (no downtime)"
  abort_deploy; exit 14
fi

# The '/' gate only proves the static SPA serves — it stayed green through a 16h
# outage where every DB-backed route 500'd. Require a DB-touching endpoint too:
# bad-creds login must answer 401 (a live auth stack), not 5xx/000 (dead pool).
dbcode="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
  -X POST -H 'content-type: application/json' \
  -d '{"email":"cp-deploy-probe@invalid.example","password":"x"}' \
  "http://localhost:${TARGET_PORT}/v1/auth/login" || true)"
if [ "$dbcode" != "401" ]; then
  log "slot $TARGET DB probe failed (login=$dbcode, want 401) — abort (active slot untouched)"
  abort_deploy; exit 14
fi
log "slot $TARGET DB probe ok (login=401)"

# ---- Hot swap: point Caddy at the new slot (graceful reload, no drops).
cp -a "$CADDYFILE" "$CADDYFILE.pre-deploy"
sed -i "s/localhost:${ACTIVE_PORT}/localhost:${TARGET_PORT}/g" "$CADDYFILE"
# Did the rewrite actually MOVE the upstream? A sed whose pattern matched
# nothing (the Caddyfile spells the upstream 127.0.0.1:<port>, a hand-edit
# changed the line, ACTIVE_PORT was misread) leaves the file BYTE-IDENTICAL —
# and every step after this still reports success: `caddy validate` passes on an
# unchanged file, the reload succeeds, and the public probe below answers 200
# because the OLD slot is still the one serving. The deploy then stops that old
# slot and barkpark.cloud goes dark, having logged "healthy" the whole way. No
# downstream check can see this; only the file itself can.
if grep -q "localhost:${ACTIVE_PORT}" "$CADDYFILE" || ! grep -q "localhost:${TARGET_PORT}" "$CADDYFILE"; then
  log "FLIP DID NOT LAND: after the rewrite $CADDYFILE still carries :$ACTIVE_PORT (or never gained :$TARGET_PORT) — the upstream is not written as 'localhost:<slot port>'; restoring, no swap"
  cp -a "$CADDYFILE.pre-deploy" "$CADDYFILE"; abort_deploy; exit 14
fi
if ! caddy validate --config "$CADDYFILE" >/dev/null 2>&1; then
  log "Caddyfile invalid after port flip — restoring, no swap"
  cp -a "$CADDYFILE.pre-deploy" "$CADDYFILE"; abort_deploy; exit 14
fi
if ! systemctl reload caddy; then
  log "caddy reload failed — restoring, no swap"
  cp -a "$CADDYFILE.pre-deploy" "$CADDYFILE"; systemctl reload caddy || true
  abort_deploy; exit 14
fi
code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 --resolve "barkpark.cloud:443:127.0.0.1" "https://barkpark.cloud/" || true)"
log "Caddy now -> :$TARGET_PORT (https://barkpark.cloud/ = $code)"
# GATE, not just a log line. instance-deploy.sh's twin of this curl was fixed in
# pds-bl-w49; cp-deploy's was left captured, logged and never tested, so a
# control-plane deploy whose flip landed on a dead front still exited 0. The
# pre-flip loop above only proves the app answers on its OWN port
# (localhost:$TARGET_PORT) — it cannot see a Caddy reload that "succeeded" onto
# a stale worker, or TLS/SNI misrouting on the PUBLIC hostname. This is the
# first and only proof that barkpark.cloud itself reaches the new slot, and it
# runs while the old slot is STILL RUNNING and not yet retired — so failing here
# can still flip back and walk away clean instead of retiring the one container
# that was actually serving. Same accepted class as the pre-flip probe: only a
# success or a redirect on '/' counts.
if ! echo "$code" | grep -qE '^(200|301|302)$'; then
  log "post-flip public health check FAILED (https://barkpark.cloud/ = $code) — flipping back to :$ACTIVE_PORT; the old slot is still running and was never retired"
  cp -a "$CADDYFILE.pre-deploy" "$CADDYFILE"
  if caddy validate --config "$CADDYFILE" >/dev/null 2>&1; then
    systemctl reload caddy || log "WARN: caddy reload failed while reverting the flip — Caddyfile restored on disk, reload it by hand"
  else
    log "WARN: the pre-deploy Caddyfile backup does not validate — Caddy left as-is, fix by hand"
  fi
  abort_deploy; exit 14
fi

# ---- Drain, then retire the old slot. Its container is kept stopped (and its
# image is held by that stopped container, so no prune below can reclaim it) so
# a human can roll back in seconds.
#
# ROLLBACK RECIPE — RECREATE, DO NOT `docker start` (gr-blk-cp-deploy-rollback-
# stale-env). This comment used to read "flip the Caddyfile port back, reload
# caddy, `docker start` it". `docker start` RESUMES an existing container
# object: it replays the environment BAKED IN at the moment that container was
# created and recomputes nothing. A slot that predates a cloud/.env change is
# therefore brought back serving the OLD env — a variable added since (say
# PLATFORM_ADMIN_EMAILS) is simply absent, silently, with no signal anywhere.
# The AUTOMATED path never has this problem: :104 exports cloud/.env before
# build and up, so the compose service config-hash changes when a variable does
# and `up` RECREATES rather than reuses. The manual path must take the same
# door. On the box, as root:
#
#   cd /opt/barkpark
#   sed -i "s/localhost:<new port>/localhost:<old port>/g" /etc/caddy/Caddyfile
#   caddy validate --config /etc/caddy/Caddyfile && systemctl reload caddy
#   # The rollback image, saved at :59 before the pull. Both slots are
#   # `image: cloud-control_plane:latest` in cloud/docker-compose.yml, so
#   # without this retag the recreate would bring back the NEW code.
#   docker tag cloud-control_plane:rollback cloud-control_plane:latest
#   set -a; . cloud/.env; set +a          # the same export the deploy uses
#   docker compose -f cloud/docker-compose.yml --profile blue --profile green \
#     up -d --force-recreate --no-build control_plane_<old slot>
#
# `--force-recreate` is what makes the current cloud/.env reach the container;
# `--no-build` keeps it a seconds-long operation on the image you just retagged.
sleep 5
for c in $(docker ps -q --filter "publish=$ACTIVE_PORT"); do
  log "stopping old slot container on :$ACTIVE_PORT ($c)"; docker stop -t 30 "$c"
done

# ---- Post-flip disk hygiene (the other half of the 2026-08-31 outage fix):
# every deploy used to leave one more image behind, forever — 839 of them when
# the box hit 100%. Prune here and ONLY here: every failure path above exits
# before this line, so a failed health gate / dead flip / unhealthy slot never
# prunes anything. `docker image prune -a` removes only images NO container
# references — the new slot's image is held by its RUNNING container and the
# rollback image is held by the just-stopped old-slot container (kept precisely
# for the recreate-based rollback recipe above), so both survive every prune by
# construction. Build cache keeps a floor (fast rebuilds) instead of growing
# forever. Non-fatal on purpose: the flip has already landed and been proven —
# a prune hiccup must not turn a good deploy red.
log "post-flip prune: unreferenced images + build cache (rollback slot's image survives — its stopped container references it)"
if img_out="$(docker image prune -af 2>&1)"; then
  log "image prune: $(printf '%s\n' "$img_out" | grep -i 'reclaimed' || echo 'nothing to reclaim')"
else
  log "WARNING: docker image prune failed (deploy unaffected): $(printf '%s\n' "$img_out" | tail -1)"
fi
CACHE_KEEP="${BARKPARK_BUILD_CACHE_KEEP:-2GB}"
if cache_out="$(docker builder prune -af --keep-storage "$CACHE_KEEP" 2>&1)"; then
  log "builder prune (cache floor $CACHE_KEEP): $(printf '%s\n' "$cache_out" | grep -iE 'reclaimed|^Total' | tail -1 || echo 'nothing to reclaim')"
elif cache_out="$(docker builder prune -af 2>&1)"; then
  # --keep-storage has been deprecated once already (buildx renamed it); if the
  # flag ever disappears the prune must still run — an unbounded cache is the
  # outage, a cold cache is only a slower next build.
  log "builder prune: --keep-storage refused, pruned ALL build cache instead: $(printf '%s\n' "$cache_out" | grep -iE 'reclaimed|^Total' | tail -1 || echo 'nothing to reclaim')"
else
  log "WARNING: docker builder prune failed (deploy unaffected): $(printf '%s\n' "$cache_out" | tail -1)"
fi
log "disk after prune: $(df -Pk "$HEADROOM_PATH" 2>/dev/null | awk 'NR==2 {printf "%.1fG free of %.1fG (%s used) on %s", $4/1048576, $2/1048576, $5, $6}')"

# ---- Pin the provisioner's control-url to the STABLE FRONT (dwb-16).
# ROOT CAUSE of the "/new froze at Starting" incident: the worker unit hardcoded
# `--control-url http://localhost:4100`, but this blue/green deploy FLIPS the
# active port (4100<->4101). After a flip the worker kept POSTing to the now-dead
# old port and was silently locked out — jobs sat pending, unclaimed, forever.
# The fix: pin the worker at the stable public front (Caddy always proxies it to
# whichever slot is live), so a port flip can never lock the worker out again.
# Idempotent: re-running rewrites the same value. Only touches the control-url.
PROV_UNIT="${BARKPARK_PROVISIONER_UNIT:-/etc/systemd/system/barkpark-provisioner.service}"
PROV_CONTROL_URL="${PROVISIONER_CONTROL_URL:-https://barkpark.cloud}"
if [ -f "$PROV_UNIT" ]; then
  if grep -qE -- '--control-url[= ]' "$PROV_UNIT"; then
    # Replace the flag's value (space- OR =-separated) with the stable front.
    sed -i -E "s#--control-url[= ][^[:space:]\"']+#--control-url ${PROV_CONTROL_URL}#g" "$PROV_UNIT"
    systemctl daemon-reload
    log "provisioner control-url pinned to $PROV_CONTROL_URL (blue/green-safe)"
  else
    log "provisioner unit has no --control-url flag; leaving control-url as-is"
  fi
else
  log "no provisioner unit at $PROV_UNIT; skipping control-url pin"
fi

# Provisioner worker (cross-built by the runner; Go absent on this host).
# The restart is a GATE, not a log line (dr-w20-bl-provisioner-restart-...).
# This script is `set -uo pipefail` with NO -e, so `systemctl restart` used to
# run with no `||` and no rc test, and the entire verdict was
# `log "provisioner: $(systemctl is-active ...)"` — which PRINTS the word
# `failed` and then falls through to `log DONE` and exit 0. Provisioning IS the
# control plane's product: a dead worker is the "/new froze at Starting"
# incident the control-url pin above was written to prevent, re-entering
# through the door beside it. The outer deploy.yml smoke cannot see it either —
# it only curls `/`.
#
# WHY THE VERDICT MOVES INSTEAD OF ONLY REPORTING (charter D327): D327's ruling
# on the static engine's `|| true` is that a step whose result is discarded
# must move the verdict, because a probe nobody acts on is indistinguishable
# from no probe at all. So a provisioner that will not come back RED-s the run.
#
# WHY IT DOES NOT ROLL THE DEPLOY BACK: this block runs AFTER the flip has
# landed, been publicly health-gated and the old slot retired. The web app is
# proven live on the new slot; unwinding that here would trade a broken worker
# for an outage. So the repair is scoped to the WORKER — restore the previous
# binary and restart it, so the box is left running the last provisioner known
# to boot — and then the script exits non-zero so CD goes red and a human
# looks. The deploy of the app stands; the RUN does not claim success.
PROV_INSTALL="${BARKPARK_PROVISIONER_BIN:-/usr/local/bin/barkpark-provisioner}"
PROV_UNIT_NAME="${BARKPARK_PROVISIONER_UNIT_NAME:-barkpark-provisioner}"
prov_state() { systemctl is-active "$PROV_UNIT_NAME" 2>/dev/null || true; }
if [ -n "$PROV_BIN" ] && [ -f "$PROV_BIN" ]; then
  log "install provisioner"
  cp "$PROV_INSTALL" "$PROV_INSTALL.bak" 2>/dev/null || true
  install -m 0755 "$PROV_BIN" "$PROV_INSTALL"
  restart_rc=0
  systemctl restart "$PROV_UNIT_NAME" || restart_rc=$?
  sleep 3
  state="$(prov_state)"
  log "provisioner: $state (restart rc=$restart_rc)"
  if [ "$restart_rc" != "0" ] || [ "$state" != "active" ]; then
    log "PROVISIONER FAILED TO COME BACK (restart rc=$restart_rc, is-active=$state) — the control plane is serving but cannot PROVISION; restoring the previous binary"
    if [ -f "$PROV_INSTALL.bak" ]; then
      install -m 0755 "$PROV_INSTALL.bak" "$PROV_INSTALL"
      systemctl restart "$PROV_UNIT_NAME" || true
      sleep 3
      log "provisioner after restoring the previous binary: $(prov_state)"
    else
      log "no $PROV_INSTALL.bak to restore — the worker is left as the new binary left it"
    fi
    log "control plane slot $TARGET IS LIVE and was NOT rolled back (the flip was proven before this step); failing the RUN so the dead provisioner cannot ride a green deploy"
    systemctl status "$PROV_UNIT_NAME" --no-pager -n 30 2>&1 | sed 's/^/[provisioner] /' || true
    exit 18
  fi
else
  log "no provisioner binary passed; leaving worker as-is"
fi

# Snapshot-management: install the nightly warm-image bake pipeline (script +
# systemd timer) from the checkout, idempotently — the timer keeps the baked
# snapshot tracking main, the provisioner resolves the newest labeled snapshot
# dynamically, and the pool reconciler recycles standing boxes onto it.
if [ -f deploy/bake-server-image.sh ]; then
  install -m 0755 deploy/bake-server-image.sh /usr/local/bin/barkpark-bake-server-image
  install -m 0644 deploy/systemd/barkpark-image-bake.service /etc/systemd/system/barkpark-image-bake.service
  install -m 0644 deploy/systemd/barkpark-image-bake.timer /etc/systemd/system/barkpark-image-bake.timer
  systemctl daemon-reload
  systemctl enable --now barkpark-image-bake.timer >/dev/null 2>&1 || true
  log "image-bake timer: $(systemctl is-enabled barkpark-image-bake.timer 2>/dev/null || echo not-installed)"
fi

log "DONE — control plane slot $TARGET live at $(git rev-parse --short HEAD)"
