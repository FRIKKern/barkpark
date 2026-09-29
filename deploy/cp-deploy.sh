#!/usr/bin/env bash
# Refresh the Barkpark Cloud CONTROL PLANE (barkpark.cloud / barkpark-cp) to
# origin/main. Run on the box as root (the CD workflow scps this + the
# cross-built provisioner binary, then executes it).
#
#   bash cp-deploy.sh [path-to-prebuilt-linux-amd64-provisioner]
#   bash cp-deploy.sh --rollback-preflight   # read-only: can we roll back?
#   bash cp-deploy.sh --rollback             # recreate the dormant slot with
#                                            # CURRENT cloud/.env, then flip
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
# ---- PRIVATE COPY: a run must only ever execute ITS OWN bytes --------------
# The CD workflow scps this script to a SHARED path on the box (/tmp/<name>.sh)
# and runs `bash /tmp/<name>.sh`. bash reads a script INCREMENTALLY, by byte
# offset, from an fd it keeps open WHILE executing it — so when a later run's
# scp rewrites that path under a still-running bash (routine here: every queued
# run queues on the box while newer merges keep arriving), the
# running shell reads shifted bytes of a DIFFERENT file and dies mid-deploy on
# a parse error. Observed on barkpark-cp: "line 329: return: can only `return'
# from a function or sourced script" then "line 334: what: unbound variable"
# (run 34021843141), and "line 383: syntax error near unexpected token `)'"
# (run 34025907184) — function bodies executed as top-level code, the signature
# of a script rewritten under a running bash.
#
# So: before anything else, re-exec from a private copy whose name no other run
# knows; the shared path may then be rewritten freely. The copy lives OUTSIDE
# any checkout on purpose — these deploy scripts run git reset --hard /
# checkout in the app dir, which would eat a copy kept there — and it unlinks
# itself the moment it
# starts, so nothing accumulates in /tmp even if the run is killed (bash holds
# the fd open and keeps reading through it after the unlink).
# The guard carries the copy's PATH, not a bare 1, so an inherited
# BARKPARK_DEPLOY_PRIVATE_COPY can never make a non-copy invocation delete the
# real script. Copy failure is a WARNING, never a refusal: the shared path is
# what we have today, and a deploy that refuses to run is worse than one that
# runs with the old exposure.
if [ "${BARKPARK_DEPLOY_PRIVATE_COPY:-}" = "$0" ]; then
  rm -f "$0" 2>/dev/null || true
  unset BARKPARK_DEPLOY_PRIVATE_COPY
elif [ -f "$0" ] && [ -r "$0" ]; then
  __bp_self="$(mktemp "${TMPDIR:-/tmp}/bp-deploy-self.XXXXXX" 2>/dev/null)" || __bp_self=""
  if [ -n "$__bp_self" ] && cat "$0" > "$__bp_self" 2>/dev/null; then
    export BARKPARK_DEPLOY_PRIVATE_COPY="$__bp_self"
    exec bash "$__bp_self" "$@"
  fi
  [ -n "$__bp_self" ] && rm -f "$__bp_self" 2>/dev/null
  echo "[private-copy] WARNING: could not copy $0 aside; running from the shared path, where a concurrent rewrite can corrupt this run" >&2
fi
# ---- end PRIVATE COPY ------------------------------------------------------

set -uo pipefail

APP="${BARKPARK_APP_DIR:-/opt/barkpark}"
COMPOSE_FILE="$APP/cloud/docker-compose.yml"
CADDYFILE="${BARKPARK_CADDYFILE:-/etc/caddy/Caddyfile}"
LOCK="${BARKPARK_DEPLOY_LOCK:-/var/lock/barkpark-cp-deploy.lock}"

# ---- 429 backoff, shared (task-90059c5c680f6665) ---------------------------
# This script is SHIPPED STANDALONE: .github/workflows/deploy.yml scps it ALONE
# to /tmp/<name>.$R.sh on the box, and the private-copy preamble above then
# re-execs it out of TMPDIR. So NO path relative to the running file reaches
# scripts/lib/bp-curl.sh — not $0, not BASH_SOURCE. The one place the helper
# does exist on the box is the checkout this script deploys: $APP.
#
# Guarded, and the degrade is NAMED rather than silent. A box whose checkout
# predates the helper must still deploy, and sourcing a missing file to take a
# deploy down over a health PROBE would be a worse outage than an unhandled 429.
# The shim reproduces bp_curl_code's contract exactly, including the part that
# bites: on a transport failure it must print NOTHING (bare `curl -w` prints
# 000 AND fails, so a naive `|| echo 000` shim would print 000000 — the latent
# double named in scripts/lib/bp-curl.sh's header).
if [ -r "$APP/scripts/lib/bp-curl.sh" ]; then
  # shellcheck disable=SC1091
  . "$APP/scripts/lib/bp-curl.sh"
else
  echo "[cp-deploy] WARNING: $APP/scripts/lib/bp-curl.sh absent — the health probes below run WITHOUT the shared 429 backoff" >&2
  bp_curl_code() { local __c; __c="$(curl -w '%{http_code}' "$@")" || return $?; printf '%s' "$__c"; }
fi

# ---- MODE (gr-blk-cp-deploy-rollback-stale-env) -----------------------------
# The default mode is the deploy. `--rollback` / `--rollback-preflight` select
# the EMERGENCY path, which used to exist only as prose in a comment near the
# flip. Prose is the wrong medium for this: it is followed by a human under
# pressure, on a box, with production already broken, and every step of it is a
# step that can be typed wrong. Worse, the recipe it replaced taught
# `docker start` — see do_rollback below for why that silently serves stale env.
MODE=deploy
case "${1:-}" in
  --rollback)           MODE=rollback; shift ;;
  --rollback-preflight) MODE=rollback-preflight; shift ;;
  --*)
    echo "[cp-deploy] unknown flag: $1 (want --rollback or --rollback-preflight)" >&2
    exit 2 ;;
esac
PROV_BIN="${1:-}"
log() { echo "[cp-deploy $(date -u +%H:%M:%S)] $*"; }
compose() { docker compose -f "$COMPOSE_FILE" --profile blue --profile green "$@"; }

# ---- CUTOVER LEDGER (dr-w26-bl-cp-deploy-eats-a-scheduled-sampler-tick) -----
# WHAT THIS IS FOR. `Oban.Plugins.Cron` (OSS) enqueues only on a tick a RUNNING
# node observes; it never backfills a tick nobody was up for. A control-plane
# container replacement crossing a cron boundary therefore eats that tick
# SILENTLY: no `oban_jobs` row is created, so there is no `discarded`, no
# `retryable`, no failed row, nothing to count. Measured on 2026-08-08: the
# 15-minute `usage_samples` series reads 23:22 / 23:37 / [NOTHING] / 00:07 /
# 00:22 across a clean blue/green cutover, and `UsageSamplerWorker` showed
# 664 completed / 1 discarded — the loss is invisible from the job table.
#
# THE ONLY WAY ANYONE COULD TELL a missing MEASUREMENT from a stopped WORKER
# was reading container uptime BY HAND (`docker ps`, `Exited (137) …`), on the
# box, after the fact — an instrument that (a) needs ssh, (b) is gone the moment
# the container is recreated again, and (c) reads identically to "someone
# already remediated it" when it is stale.
#
# So the deploy writes down its OWN cutover window, in a durable append-only
# file, at the three instants that bound it. That turns the question
# "was a deploy crossing 23:52Z?" into a grep instead of a live box walk, and it
# is what `deploy/cp-cutover-gaps.sh` reads to classify each missing tick as
# deploy-attributable or unexplained. The deploy is the only party that KNOWS
# these instants; nothing downstream can reconstruct them.
#
# NON-FATAL, ALWAYS. Every call is `|| true`-equivalent by construction (the
# function swallows its own failures): a full disk or a read-only /opt must
# never turn a good deploy red over bookkeeping. A ledger that is missing lines
# degrades the analyzer to "unexplained", which is the SAFE direction — it
# over-reports work for a human rather than laundering a loss into "expected".
CUTOVER_LEDGER="${BARKPARK_CP_CUTOVER_LEDGER:-$APP/.slots/cp-cutovers.log}"
# Bounded on purpose: ~6 lines per deploy and ~80 control-plane deploys a week
# means an unbounded file is a slow leak on a box whose disk filling is already
# a recorded outage (2026-08-31). 4000 lines is >6 weeks of history at that rate.
CUTOVER_LEDGER_MAX_LINES="${BARKPARK_CP_CUTOVER_LEDGER_MAX_LINES:-4000}"
# One id per RUN of this script, so the analyzer can pair a start with its end
# even when two deploys interleave in the file (they cannot today — the deploy
# lock serializes them — but the pairing must not DEPEND on that).
CUTOVER_DEPLOY_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
cutover_stamp() {
  local event="$1"; shift
  local line ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)" || return 0
  line="CPCUTOVER deploy_id=${CUTOVER_DEPLOY_ID} event=${event} ts=${ts}"
  line="${line} old_sha=${OLD:-unknown} new_sha=${NEW:-unknown}"
  line="${line} active_port=${ACTIVE_PORT:-unknown} target_slot=${TARGET:-unknown}"
  line="${line} run_id=${GITHUB_RUN_ID:-none}"
  [ "$#" -gt 0 ] && line="${line} $*"
  mkdir -p "$(dirname "$CUTOVER_LEDGER")" 2>/dev/null || return 0
  printf '%s\n' "$line" >> "$CUTOVER_LEDGER" 2>/dev/null || return 0
  # Trim from the FRONT (oldest first) and only when over budget. `tail -n` into
  # a temp then move: an in-place truncate of a file another process may be
  # appending to is how a ledger loses the line it was just given.
  local n
  n="$(wc -l < "$CUTOVER_LEDGER" 2>/dev/null || echo 0)"
  case "$n" in ''|*[!0-9\ ]*) return 0 ;; esac
  if [ "$n" -gt "$CUTOVER_LEDGER_MAX_LINES" ]; then
    tail -n "$CUTOVER_LEDGER_MAX_LINES" "$CUTOVER_LEDGER" > "$CUTOVER_LEDGER.trim" 2>/dev/null &&
      mv "$CUTOVER_LEDGER.trim" "$CUTOVER_LEDGER" 2>/dev/null
  fi
  return 0
}

# Serialize overlapping runs (back-to-back merges, manual + CD).
# ---- Queued-lock heartbeat (task-8811b4b25c529dbe) --------------------------
# A SILENT wait is what killed the CI leg, never the deploy itself. `flock -w
# <budget> 9` carries no bytes on the ssh session that started this script, and
# the GitHub runner's NAT tears an idle session down after roughly five minutes:
# ssh exits 255, the step fails, and the run is recorded as a FAILED production
# deploy for the crime of queueing. Measured on main 2026-09-05..06: ten of the
# last fourteen failed deploy.yml runs died exactly that way, every one of them
# after logging the "holds the lock" line above.
#
# So wait in heartbeat-sized STEPS instead of one long silent one. The contract
# is identical to `flock -w <budget> 9` -- return 0 the moment the lock is
# taken, non-zero once the budget is exhausted, and the TOTAL budget is
# unchanged (the steps sum to it exactly) -- but a line lands at most every
# $BARKPARK_LOCK_HEARTBEAT_SECS, so the session carries bytes AND a human
# reading the log sees a QUEUE rather than a hang.
#
# The env var exists ONLY so deploy/*_test.sh can drive this at 1 s; nothing on
# a box sets it. A non-numeric or sub-second value falls back to 60 rather than
# spinning.
queue_for_deploy_lock() {
  local budget="$1" label="${2:-the deploy lock}" beat waited=0 step
  beat="${BARKPARK_LOCK_HEARTBEAT_SECS:-60}"
  case "$beat" in ''|*[!0-9]*) beat=60 ;; esac
  [ "$beat" -lt 1 ] && beat=60
  while [ "$waited" -lt "$budget" ]; do
    step=$(( budget - waited ))
    [ "$step" -gt "$beat" ] && step="$beat"
    flock -w "$step" 9 && return 0
    waited=$(( waited + step ))
    log "still queued for $label — ${waited}s waited of ${budget}s max"
  done
  return 1
}

exec 9>"$LOCK"
if ! flock -n 9; then
  log "another deploy holds the lock — queueing (max 30 min)"
  queue_for_deploy_lock 1800 || { log "gave up waiting for the deploy lock"; exit 15; }
fi

cd "$APP" || { log "no $APP"; exit 10; }

# ============================================================================
# ROLLBACK — RECREATE, NEVER `docker start` (gr-blk-cp-deploy-rollback-stale-env)
# ============================================================================
# WHY THIS IS CODE AND NOT A COMMENT. The flip below keeps the old slot's
# container STOPPED so a human can go back in seconds, and this script used to
# document that return trip as "flip the Caddyfile port back, reload caddy,
# `docker start` it". Two things are wrong with that sentence and both of them
# fail SILENTLY, which is the worst possible property for the one path you take
# when production is already broken:
#
#   1. `docker start` RESUMES AN EXISTING CONTAINER OBJECT. It replays the
#      environment baked in at the instant that container was CREATED and
#      recomputes nothing. A slot that predates a cloud/.env change therefore
#      comes back serving the OLD env: a variable added since (say
#      PLATFORM_ADMIN_EMAILS) is simply absent — no error, no warning, a 200 on
#      every probe, and operator access quietly gone. The AUTOMATED path never
#      has this problem because the deploy exports cloud/.env before build and
#      up, so the compose service config-hash moves when a variable does and
#      `up` RECREATES rather than reuses. The manual path must take that door.
#
#   2. IT FLIPPED CADDY FIRST. The prose recipe seds the Caddyfile back before
#      the old slot is running at all, so between the reload and the start the
#      public front points at a dead port. This function inverts that order:
#      recreate, health-gate, and only THEN flip — the same order the deploy
#      uses, for the same reason.
#
# AND IT FAILS CLOSED. Every precondition below REFUSES with a named reason and
# a distinct exit code rather than doing its best. A rollback that half-works
# looks like it worked, and the operator stops looking.
rollback_refuse() { log "REFUSING ROLLBACK: $1"; return "$2"; }

do_rollback() {
  preflight_only="${1:-0}"

  # (a) compose file. Without it there is no service to recreate at all.
  if [ ! -r "$COMPOSE_FILE" ]; then
    rollback_refuse "no readable $COMPOSE_FILE — this box has no compose slots to recreate" 20
    return $?
  fi

  # (b) cloud/.env. THE POINT OF THE WHOLE FUNCTION. A recreate without it
  # boots the slot with an EMPTY environment; `docker start` would have
  # "worked" here, which is exactly the trap. Refuse and say so.
  if [ ! -r "$APP/cloud/.env" ]; then
    rollback_refuse "$APP/cloud/.env is missing or unreadable, so a recreate cannot pick up current configuration. Do NOT fall back to 'docker start': that resumes the dormant container with the environment baked in when it was CREATED, serving stale secrets and allowlists with no signal. Restore cloud/.env first." 21
    return $?
  fi
  set -a
  # shellcheck disable=SC1091
  . "$APP/cloud/.env"
  set +a

  # (c) the rollback image. Both slots are `image: cloud-control_plane:latest`
  # in cloud/docker-compose.yml, so a recreate WITHOUT the retag brings back the
  # code you are rolling back FROM — a rollback that rolls nothing back and
  # reports success.
  if ! docker image inspect cloud-control_plane:rollback >/dev/null 2>&1; then
    rollback_refuse "image cloud-control_plane:rollback does not exist (never deployed here, or pruned). Both slots run cloud-control_plane:latest, so recreating now would reinstall the CURRENT code under the guise of a rollback." 22
    return $?
  fi

  # (d) which slot serves, and which one we are going back to. Derived from the
  # SAME Caddyfile marker the deploy flip uses, never guessed.
  BLUE_PORT="${PORT_BLUE:-4100}"
  GREEN_PORT="${PORT_GREEN:-4101}"
  RB_LIVE_PORT="$(grep -oE "localhost:(${BLUE_PORT}|${GREEN_PORT})" "$CADDYFILE" | head -1 | cut -d: -f2)"
  if [ -z "$RB_LIVE_PORT" ]; then
    rollback_refuse "$CADDYFILE names neither :$BLUE_PORT nor :$GREEN_PORT as 'localhost:<port>' — the live slot cannot be derived, and guessing it would flip the public front onto a dead port." 23
    return $?
  fi
  if [ "$RB_LIVE_PORT" = "$BLUE_PORT" ]; then
    RB_SLOT=green; RB_PORT="$GREEN_PORT"
  else
    RB_SLOT=blue; RB_PORT="$BLUE_PORT"
  fi
  if [ "$RB_PORT" = "$RB_LIVE_PORT" ]; then
    rollback_refuse "rollback slot '$RB_SLOT' resolves to :$RB_PORT, the port Caddy already serves (PORT_BLUE and PORT_GREEN agree in cloud/.env) — recreating there would tear down the LIVE container." 24
    return $?
  fi
  log "rollback: live :$RB_LIVE_PORT -> recreating slot '$RB_SLOT' on :$RB_PORT from cloud/.env + cloud-control_plane:rollback"

  if [ "$preflight_only" = 1 ]; then
    # Read-only. It has touched no image tag, no container and no Caddyfile.
    echo "ROLLBACK_SLOT=$RB_SLOT"
    echo "ROLLBACK_PORT=$RB_PORT"
    echo "LIVE_PORT=$RB_LIVE_PORT"
    log "rollback preflight OK — nothing was changed"
    return 0
  fi

  # (e) retag, then RECREATE. --force-recreate is what makes the current
  # cloud/.env reach the container (it is the whole fix); --no-build keeps this
  # a seconds-long operation on the image just retagged.
  if ! docker tag cloud-control_plane:rollback cloud-control_plane:latest; then
    rollback_refuse "could not retag cloud-control_plane:rollback -> :latest; a recreate now would boot the CURRENT code" 22
    return $?
  fi
  if ! compose up -d --force-recreate --no-build "control_plane_$RB_SLOT"; then
    rollback_refuse "compose could not recreate control_plane_$RB_SLOT — Caddy was NOT touched, the slot on :$RB_LIVE_PORT is still serving" 25
    return $?
  fi

  # (f) health-gate BEFORE the flip. The prose recipe had no gate at all.
  rb_ok=0
  for _ in $(seq 1 36); do
    code="$(bp_curl_code -s -o /dev/null --max-time 6 "http://localhost:${RB_PORT}/" || echo 000)"
    # `case`, not `echo | grep -q`: under this file's `pipefail` the reader
    # exits at the first match, `echo` takes SIGPIPE and pipefail hands back 141,
    # so a HEALTHY code reads as unhealthy. `$code` is short enough that it has
    # never fired here, but the shape is the hazard and a pattern match needs no
    # pipe at all (fix 1 in scripts/pipefail-sigpipe-scan.sh's preference order).
    case "$code" in 200|301|302) rb_ok=1; log "rollback slot $RB_SLOT healthy ($code)"; break ;; esac
    sleep 5
  done
  if [ "$rb_ok" != 1 ]; then
    rollback_refuse "recreated slot $RB_SLOT never became healthy on :$RB_PORT — Caddy was NOT flipped, so whatever is serving on :$RB_LIVE_PORT keeps serving. Roll forward or fix the image." 26
    return $?
  fi

  # (g) flip, with the same did-it-land assertion the deploy uses: a sed that
  # matched nothing leaves the file byte-identical and every check after it
  # still passes.
  cp -a "$CADDYFILE" "$CADDYFILE.pre-rollback"
  sed -i "s/localhost:${RB_LIVE_PORT}/localhost:${RB_PORT}/g" "$CADDYFILE"
  if grep -q "localhost:${RB_LIVE_PORT}" "$CADDYFILE" || ! grep -q "localhost:${RB_PORT}" "$CADDYFILE"; then
    cp -a "$CADDYFILE.pre-rollback" "$CADDYFILE"
    rollback_refuse "the Caddyfile rewrite did not land (upstream is not spelled 'localhost:<slot port>') — file restored, nothing flipped" 27
    return $?
  fi
  if ! caddy validate --config "$CADDYFILE" >/dev/null 2>&1; then
    cp -a "$CADDYFILE.pre-rollback" "$CADDYFILE"
    rollback_refuse "Caddyfile invalid after the rollback flip — file restored, nothing flipped" 27
    return $?
  fi
  if ! systemctl reload caddy; then
    cp -a "$CADDYFILE.pre-rollback" "$CADDYFILE"; systemctl reload caddy || true
    rollback_refuse "caddy reload failed — Caddyfile restored" 27
    return $?
  fi
  log "ROLLED BACK: Caddy now -> :$RB_PORT (slot $RB_SLOT, recreated with current cloud/.env)"
  log "the slot on :$RB_LIVE_PORT is left RUNNING on purpose — inspect it, then stop it by hand once you are satisfied"
  return 0
}

case "$MODE" in
  rollback)           do_rollback 0; exit $? ;;
  rollback-preflight) do_rollback 1; exit $? ;;
esac
# ---- end ROLLBACK ----------------------------------------------------------
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

# The slot must ALSO be able to state which PROVISIONER binary this box runs,
# separately from the app sha — the two legitimately diverge. The provisioner is
# cross-built on the runner from actions/checkout@v4 at the run's headSha, while
# the app sha above comes from the `git pull --ff-only` a few lines up, which
# under back-to-back merges can land AHEAD of that headSha. One "version" field
# would be ambiguous; these are two readings of two different things.
#
# Read out of the ARTIFACT (`--version` on the binary this run is about to
# install), never out of $NEW: $NEW is the app's sha and would make the two
# fields agree by construction, which is the exact inference this exists to kill.
# --version needs no control-url, no token and no network, and exits 0 even when
# the binary carries no stamp.
#
# STRICTLY 40 lowercase hex or EMPTY. An unstamped binary (plain `go build`, or
# any binary older than the --version flag) prints nothing on stdout, and an
# empty value stays empty — absent means absent, an honest null, never an
# invented or partial value. Mirrors the bare `- BARKPARK_PROVISIONER_SHA`
# passthrough in cloud/docker-compose.yml, the same shape as BARKPARK_GIT_SHA.
#
# WINDOW, stated rather than hidden: the binary is installed later in this script
# (the provisioner restart is a gate near the end). If that restart fails, the
# script restores the previous binary AND fails the run — so a slot claiming a
# sha the box did not keep is always a RED deploy, never a quiet green.
BARKPARK_PROVISIONER_SHA=""
if [ -n "$PROV_BIN" ] && [ -f "$PROV_BIN" ]; then
  [ -x "$PROV_BIN" ] || chmod 0755 "$PROV_BIN" 2>/dev/null || true
  _prov_sha="$("$PROV_BIN" --version 2>/dev/null | head -1 | tr -d '[:space:]')"
  # Here-string, not `printf | grep -q` — a producer process that can be killed
  # by the reader's early exit is what returns 141 under pipefail.
  if grep -qE '^[0-9a-f]{40}$' <<<"$_prov_sha"; then
    BARKPARK_PROVISIONER_SHA="$_prov_sha"
  else
    log "provisioner binary carries NO usable build sha (--version gave '${_prov_sha}') — reporting absent"
  fi
  unset _prov_sha
fi
export BARKPARK_PROVISIONER_SHA
log "provisioner sha=${BARKPARK_PROVISIONER_SHA:-<absent>}"

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
# The cutover window OPENS here: every container replacement this run can
# perform happens after this line, so a cron tick lost to this deploy is lost
# inside [deploy_start, deploy_end].
cutover_stamp deploy_start

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
  seen=0
  # MATERIALISED, not consumed straight out of the heredoc's command
  # substitution: the count identity below needs an enumeration side that a
  # short read cannot move.
  endpoints="$(docker network inspect "$CP_NETWORK" --format '{{range $id, $c := .Containers}}{{$id}} {{$c.Name}}
{{end}}' 2>/dev/null)"
  enumerated="$(printf '%s' "$endpoints" | grep -c . || true)"
  while IFS=' ' read -r cid cname; do
    [ -n "$cid" ] && [ -n "$cname" ] || continue
    # MUT-SPLICE: endpoint-count-identity
    # THE WORK SIDE — tallied above every `continue`, so it counts endpoints
    # REACHED. `$cleared` is the OUTCOME, not the coverage.
    seen=$((seen + 1))
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
$endpoints
EOF
  # ── THE COUNT IDENTITY (task-fb55d468c7dea75b) ─────────────────────────────
  # This loop reads the endpoint list on fd 0. Its body already starts THREE
  # subprocesses (`docker inspect`, `docker network disconnect`, `log`), and the
  # next one added that reads stdin — an `ssh`, a `read`, a `docker` subcommand
  # that prompts — swallows the remaining endpoints and the loop ENDS EARLY with
  # no error and no non-zero status. `$cleared` is read off this same loop, so a
  # sweep that reached endpoint 1 of 6 leaves the other five WEDGED and reports a
  # smaller number in the same words as a complete sweep — and the caller then
  # retries a `compose up -d` against a network that is still blocked, which is
  # the 2026-07-21 48h47m blackout's exact shape.
  #
  # NOT FATAL, deliberately: this runs on a path that is already failing, and a
  # `die` here would convert a repairable deploy into an aborted one. The
  # refusal is that the function reports FAILURE (return 1) and says both
  # numbers, so it can never claim a clearance it did not complete.
  # MUT-ANCHOR: endpoint-count-identity
  if [ "$seen" -ne "$enumerated" ]; then
    log "SHORT ENDPOINT SWEEP on $CP_NETWORK: examined $seen of $enumerated endpoint(s) the daemon listed. The sweep loop ended before the list did (a loop-body child that reads stdin consumes the rest silently), so $((enumerated - seen)) endpoint(s) were never even examined and a stale one may still be wedging the network. Reporting FAILURE rather than '$cleared cleared' — a partial sweep must not read as a completed one."
    return 1
  fi
  # MUT-END: endpoint-count-identity
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
  # HERE-STRING, not `printf … | grep -q`.  `$out` is a whole `compose up -d`
  # transcript — pulls, per-container Creating/Started lines — and the daemon
  # names the wedged endpoint EARLY in it.  Under this file's `pipefail`,
  # `grep -q` answers at that first match and closes the pipe, `printf` takes
  # SIGPIPE and dies 141, and pipefail hands 141 back as the pipeline's status.
  # 141 is not 0, so the branch reads "not a wedged endpoint", the repair below
  # is skipped, and the 2026-07-21 48h47m blackout gets its sleep-and-retry that
  # was measured 0-for-65.  The failure is OUTPUT-LENGTH DEPENDENT: it hides on a
  # quiet box and appears exactly when the deploy is big and noisy.  A here-string
  # has no producer process to kill.
  if grep -qE 'has active endpoints|is not connected to the network' <<<"$out"; then
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
  # An abort still booted (and now removes) a container, and `ensure_shared_services`
  # below can restart db/postfix — so the cutover window must be CLOSED here too.
  # Without this stamp an aborted deploy leaves an open-ended window and the
  # analyzer falls back to its bounded default, which over-attributes.
  cutover_stamp deploy_aborted result=abort
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
  code="$(bp_curl_code -s -o /dev/null --max-time 6 "http://localhost:${TARGET_PORT}/" || echo 000)"
  # 404 is NOT accepted: it used to be, on the theory that "some route
  # answered" proves a live app — but a container that serves nothing but
  # 404s (image booted, app crashed, wrong port, static server up with the
  # SPA missing) is exactly the broken-deploy shape this gate exists to
  # catch, and 404 waved it through as "healthy". Only redirect/success on
  # '/' counts now.
  # `case`, not `echo | grep -q` — see the rollback probe above: under pipefail
  # a SIGPIPE'd producer turns a healthy code into an unhealthy verdict.
  case "$code" in 200|301|302) ok=1; log "slot $TARGET healthy ($code)"; break ;; esac
  sleep 5
done
if [ "$ok" != "1" ]; then
  log "slot $TARGET UNHEALTHY — stopping it; :$ACTIVE_PORT was never touched (no downtime)"
  abort_deploy; exit 14
fi

# The '/' gate only proves the static SPA serves — it stayed green through a 16h
# outage where every DB-backed route 500'd. Require a DB-touching endpoint too:
# bad-creds login must answer 401 (a live auth stack), not 5xx/000 (dead pool).
dbcode="$(bp_curl_code -s -o /dev/null --max-time 10 \
  -X POST -H 'content-type: application/json' \
  -d '{"email":"cp-deploy-probe@invalid.example","password":"x"}' \
  "http://localhost:${TARGET_PORT}/v1/auth/login" || echo 000)"
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
code="$(bp_curl_code -sk -o /dev/null --max-time 10 --resolve "barkpark.cloud:443:127.0.0.1" "https://barkpark.cloud/" || echo 000)"
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

cutover_stamp flip target_port="$TARGET_PORT"

# ---- Drain, then retire the old slot. Its container is kept stopped (and its
# image is held by that stopped container, so no prune below can reclaim it) so
# a human can roll back in seconds.
#
# ROLLBACK — RUN THE SCRIPT, DO NOT HAND-TYPE A RECIPE, AND NEVER `docker start`
# (gr-blk-cp-deploy-rollback-stale-env). On the box, as root:
#
#   cd /opt/barkpark
#   bash deploy/cp-deploy.sh --rollback-preflight   # read-only; names the slot
#   bash deploy/cp-deploy.sh --rollback             # retag, recreate, gate, flip
#
# do_rollback() near the top of this file IS that recipe, executable: it takes
# the same deploy lock, retags cloud-control_plane:rollback -> :latest, sources
# cloud/.env, `up -d --force-recreate --no-build`s the dormant slot, HEALTH-GATES
# it, and only then flips Caddy — refusing, loudly and with a distinct exit code,
# at every precondition it cannot satisfy. Read its header for why `docker start`
# (which this comment used to teach) silently serves the environment baked into
# the dormant container at creation time, and why flipping Caddy first pointed
# the public front at a dead port.
sleep 5
for c in $(docker ps -q --filter "publish=$ACTIVE_PORT"); do
  log "stopping old slot container on :$ACTIVE_PORT ($c)"; docker stop -t 30 "$c"
done
# The OLD node's Oban scheduler dies here. Between `flip` and this line BOTH
# nodes are up; before `flip` only the old one is. Stamping all three means a
# reader can say which side of the handoff a missing tick fell on without ever
# asking the box what its containers were doing.
cutover_stamp old_slot_stopped

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

cutover_stamp deploy_end result=ok
log "DONE — control plane slot $TARGET live at $(git rev-parse --short HEAD)"
