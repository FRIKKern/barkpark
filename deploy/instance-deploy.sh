#!/usr/bin/env bash
# Refresh a Barkpark CONTENT instance (e.g. guerrilla) to origin/main.
#
# Run on the box as root (the CD workflow scps this script + executes it).
# Idempotent, ASDF-aware, SERIALIZED (flock), ZERO-DOWNTIME blue/green.
#
# Blue/green (extends the 2026-07-01 build-aside fix): the app runs as systemd
# template units barkpark-slot@{blue,green} out of per-slot build roots of the
# SAME checkout (blue = api/_build_blue on :4000, green = api/_build_green on
# :4001); host Caddy proxies the public hostname to the active slot's port. A
# deploy clean-builds the IDLE slot's root (MIX_BUILD_ROOT) while the active
# slot keeps serving its own untouched root, migrates, boots the idle slot,
# health-gates it, then flips Caddy's upstream (graceful reload — no dropped
# connections) and retires the old slot. An unhealthy new slot is simply
# stopped again — the active slot is never touched, so a bad deploy costs no
# downtime. Consequence: migrations must be backward-compatible
# (expand/contract) for the minute both slots overlap.
#
# TWO CHANNELS, ONE SCRIPT — the git step is channel-gated on a $APP/.staging
# marker (fail-closed: absent => production channel):
#   * production (no .staging): `fetch origin main` then `reset --hard
#     FETCH_HEAD`, LOCKED to origin/main. A non-main DEPLOY_REF or non-origin
#     DEPLOY_REMOTE is REFUSED (exit 11) BEFORE the git step — a prod content box
#     can never be pushed to a branch, a PR, or a foreign remote. A content box
#     is a MIRROR of origin/main, never a source of truth, so it hard-resets
#     (converging even from a DIVERGENT HEAD — a stray commit made on the box, or
#     main rewritten under it) rather than `pull --ff-only`, which ABORTS on
#     divergence and silently jams the box off the deploy train. Divergence is
#     logged, not swallowed. The hard reset also discards committed build
#     artifacts (go.sum/bin churn), subsuming the old `git checkout -- .`.
#   * staging (.staging present): deploy ANY ref — DEPLOY_REF (default main),
#     DEPLOY_REMOTE (default origin) — via `fetch $DEPLOY_REMOTE $DEPLOY_REF`
#     then `reset --hard FETCH_HEAD`. This is the pre-merge proving path: try a
#     branch or a PR (DEPLOY_REF=pull/<n>/head) BEFORE it rides the auto-deploy
#     merge train.
# EVERY git path suppresses the repo's post-merge hook (core.hooksPath=.githooks
# on the box): that hook nukes the live _build and restarts the legacy `barkpark`
# unit — exactly the outage this script exists to prevent.
#
# ROLLBACK MODES (W6) — the same script owns the reverse flip:
#   --rollback-preflight  read-only: is a rollback possible right now? Typed
#                         exits (21 no_previous_slot, 22 not_supported, 23 lock
#                         held); exit 0 prints TARGET_SLOT=/TARGET_SHA= lines
#                         (machine-parsed by the instance controller).
#   --rollback            flip+reset to the IDLE slot at its RECORDED sha
#                         (.slots/<slot>.sha): git reset --hard <stamp>, reboot
#                         the slot, health-gate it on its OWN port, flip Caddy
#                         only on green, rewrite deploy STATE. Unhealthy = fail
#                         closed (slot re-disabled, Caddy untouched, checkout
#                         reset back, exit 24).
#
# SITE-DEPLOY PREFLIGHT (D593) — read-only, lock-free, typed:
#   --site-deploy-preflight  can this box HONOUR a site-deploy consent? Prints
#                         SITE_DEPLOY_CONSENT= and one SITE_DEPLOY_PREREQ_*=
#                         line per prerequisite; exits 0 (all met) / 31 npm not
#                         on the BEAM's PATH / 32 no flock(1) / 33 no python3 or
#                         caddy / 34 under 2G available RAM. See the block above
#                         MODE= for why each one is load-bearing.
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
LOCK="${BARKPARK_DEPLOY_LOCK:-/var/lock/barkpark-instance-deploy.lock}"
CADDYFILE="${BARKPARK_CADDYFILE:-/etc/caddy/Caddyfile}"

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
  echo "[instance-deploy] WARNING: $APP/scripts/lib/bp-curl.sh absent — the health probes below run WITHOUT the shared 429 backoff" >&2
  bp_curl_code() { local __c; __c="$(curl -w '%{http_code}' "$@")" || return $?; printf '%s' "$__c"; }
fi

HEALTH_HOST="${BARKPARK_HEALTH_HOST:-guerrilla.barkpark.cloud}"
# THE LIVENESS PATH every health gate below probes. NOT `/api/schemas`.
#
# `/api/schemas` is the LAST surviving legacy route (router.ex, the final
# `scope "/api"`), and it pipes through `BarkparkWeb.Plugs.LegacyDeprecation`,
# which stamps every response with
#
#     sunset: Wed, 31 Dec 2026 23:59:59 GMT
#
# That is a PUBLISHED removal date, not a hint. THE FAILURE MODE ON THAT DATE IS
# FAIL-CLOSED, NOT QUIET: every probe below captures the status with
# `-o /dev/null -w '%{http_code}'` (via bp_curl_code) and GATES on `= 200`, and
# curl's own exit status is deliberately discarded (`|| echo 000`) because the
# STATUS CODE is the signal. So a 404 from a retired route does not "go quiet" —
# it disables the freshly-booted slot, resets the checkout to the live sha and
# exits 24/14, or (post-flip) flips Caddy back. A healthy build on a healthy box
# would stop deploying everywhere, and the log would blame the slot.
#
# `/status.json` (router.ex: `get("/status.json", StatusController, :show_json)`)
# is the replacement: `pipe_through(:api)` only — no LegacyDeprecation, no
# deprecation/sunset header, no token (the `:api` pipeline runs `OptionalToken`),
# and not part of any versioned content contract. It is a STRICTLY STRONGER
# liveness signal than the route it replaces: `StatusController.show_json/2` ->
# `Barkpark.Status.health/0` -> `open_incidents/0` and `recent_incidents/1` are
# bare `Repo.all/1` calls (NOT wrapped in `Status.safe/2`), so an unreachable
# database raises and the probe sees 500, never 200. 200 means the endpoint is
# up AND the database answers. `curl -s <box>/status.json | jq -r .commit` is
# already the documented box smoke (CLAUDE.md).
#
# CONSUMERS OF THE SUNSET ROUTE, re-derived from origin/main on 2026-09-11 by
# `git grep -n 'api/schemas' -- . ':!api/'`. The list this block used to carry
# was the set PR #17745 CHECKED, not the set that exists: `cloud/support.go`
# does not exist (the Go consumer is `internal/cli/cloud/support.go`), the
# compose healthcheck is in the ROOT `docker-compose.yml` (not `cloud/`), and
# seven further code consumers were never listed at all.
#
# RETARGETED to /status.json in PR "every remaining health consumer leaves the
# sunset /api/schemas route" (task-539f1deeec25a8e7):
#   docker-compose.yml (api healthcheck)      scripts/deploy-rebuild.sh (BP_HEALTH_URL)
#   scripts/compose-smoke.sh (green arm)      scripts/create-quickstart-smoke.sh (boot poll)
#   scripts/pds-scratch-target.sh (probe)     internal/cli/cloud/support.go (SupportLocalHealthProbe)
#   deploy/uptime-kuma/README.md (monitor)    deploy/README.md (prose)
#
# STILL ON THE SUNSET ROUTE — out of that PR's fence, each still fails closed on
# 2027-01-01 unless repointed (file:line on origin/main 2b1fcaef7):
#   deploy.sh:356,419,427,434                 run.sh:18
#   Makefile:299,305,307                      bin/barkpark:175,244,270,275,372,404,426
#   deploy/site-deploy.sh:8 (comment only)    scripts/setup-windows.ps1:184,199,211
#   internal/cli/setup/assets/deploy.sh       internal/provisioner/support.go:1076
#   internal/cli/cloud/restore_driver.go:108,431   internal/cli/cloud_support_cmd.go:1685
#   internal/cli/hetzner_instance_cmd.go:706-1858  internal/cli/hetzner_instance_transfer_cmd.go:145
#   internal/cli/cloud_deploy_cmd.go:880           internal/cli/setup/local.go:461 (fallback, /v1/capabilities first)
# This script honours \$BARKPARK_HEALTH_PATH and needs no change either way.
HEALTH_PATH="${BARKPARK_HEALTH_PATH:-/status.json}"
BLUE_PORT="${BARKPARK_PORT_BLUE:-4000}"
GREEN_PORT="${BARKPARK_PORT_GREEN:-4001}"
# Remote MCP endpoint (viable-everywhere D19). MUST stay outside the blue/green
# slot ports: the port-flip sed rewrites localhost:<slot> globally on every
# deploy, and the ACTIVE_PORT greps match slot ports exactly.
MCP_PORT="${BARKPARK_PORT_MCP:-4010}"
MCP_ENV_FILE="${BARKPARK_MCP_ENV_FILE:-/etc/barkpark/mcp.env}"
# Connectors bridge (connectors charter D34/D46) — the persistent Node process
# behind the /connectors PATH route. Same rule as :4010: OUTSIDE the slot ports.
CONNECTORS_PORT="${BARKPARK_PORT_CONNECTORS:-4020}"
CONNECTORS_PATH_PREFIX="${BARKPARK_CONNECTORS_PATH_PREFIX:-/connectors}"
CONNECTORS_ENV_FILE="${BARKPARK_CONNECTORS_ENV_FILE:-/etc/barkpark/connectors.env}"
# Stable node path the committed unit's ExecStart points at (systemd cannot
# expand a variable in the executable position, and asdf's node lives under a
# versioned dir). The deploy symlinks this at the resolved node.
NODE_LINK="${BARKPARK_NODE_LINK:-/usr/local/bin/barkpark-node}"
# Where the deploy installs the Cloud sandbox runner (connectors charter D265).
# ClaudeChat resolves the BARE name "cloud-sandbox-runner" off the live BEAM PATH
# (/usr/local/bin is on it, /proc-proven), so the WRAPPER basename must be exactly
# that and :sandbox_runner config stays UNSET. Overridable ONLY so the offline
# harness can redirect both writes into its temp dir — production keeps the
# absolute /usr/local/bin paths the wrapper CONTENT hardcodes.
SANDBOX_RUNNER_BIN="${BARKPARK_SANDBOX_RUNNER_BIN:-/usr/local/bin/cloud-sandbox-runner}"
SANDBOX_RUNNER_MJS="${BARKPARK_SANDBOX_RUNNER_MJS:-/usr/local/bin/cloud-sandbox-runner.mjs}"
log() { echo "[instance-deploy $(date -u +%H:%M:%S)] $*"; }

# ---- ONE shared Caddyfile lock (site-spawner D27) --------------------------
# $CADDYFILE has a SECOND writer: deploy/site-deploy.sh arms a `handle_path
# /sites/<slug>/*` block into the same file. Both scripts do read -> backup ->
# rewrite -> mv, and an interleave silently DISCARDS one of them. A lost update
# is syntactically VALID, so the backup + `caddy validate` + revert discipline
# both scripts already have is structurally BLIND to it. Reproduced: site-deploy's
# losing write dropped this script's blue/green port flip and then reloaded Caddy
# onto the slot we were about to `systemctl disable --now` — a hard 502 on the
# content API that does not self-heal until the next deploy.
#
# So EVERY Caddyfile read-modify-write in this script (three route armings + two
# flip regions) runs under this leaf lock on fd 8, and site-deploy.sh takes the
# SAME lock around its whole arming function. Acquire order is identical in both
# (own lock fd 9 -> caddy lock fd 8) and the caddy lock is a leaf neither holds
# while waiting on the other's, so they cannot deadlock. It is deliberately NOT
# this script's own lock (fd 9): that one is held for the whole multi-minute run
# and would stall a site deploy for ten minutes.
CADDY_LOCK="${BARKPARK_CADDYFILE_LOCK:-/var/lock/barkpark-caddyfile.lock}"
if ! ( : > "$CADDY_LOCK" ) 2>/dev/null; then
  # Unwritable /var/lock (dev box, unprivileged CI) — still serialize, in TMPDIR.
  CADDY_LOCK="${TMPDIR:-/tmp}/barkpark-caddyfile.lock"
  # LOUD, because the failure mode is silent: the two writers only exclude each
  # other if they resolve the SAME path. Both run as root on the box and both get
  # /var/lock; if one falls back and the other does not, they serialize against
  # nothing. Pin BARKPARK_CADDYFILE_LOCK identically on both.
  log "WARN: /var/lock is not writable — Caddyfile lock falls back to $CADDY_LOCK; site-deploy.sh MUST resolve the same path (set BARKPARK_CADDYFILE_LOCK) or the two Caddyfile writers do not serialize"
fi
with_caddy_lock() { # <fn> [args…] — run a whole Caddyfile read-modify-write serialized
  exec 8>"$CADDY_LOCK" || { log "cannot open the Caddyfile lock $CADDY_LOCK — leaving Caddy untouched"; return 1; }
  if ! flock -w 120 8; then
    log "gave up waiting for the Caddyfile lock ($CADDY_LOCK) — leaving Caddy untouched"
    exec 8>&-
    return 1
  fi
  "$@"
  local rc=$?
  exec 8>&-
  return "$rc"
}

# ---- SITE-DEPLOY CONSENT + THE FOUR PER-BOX PREREQUISITES (D593) ----------
# A site build is NOT the same act as a self-update. It runs `npm ci` + `npm run
# build` over the SITE's own dependency tree, which executes third-party
# postinstall code on this box — api/config/runtime.exs gates it separately in
# exactly those words. `BARKPARK_SITE_DEPLOY_APPLY=1` in `.slots/%i.env` is the
# box owner's recorded CONSENT to that execution, which is why write_slot_env()
# below PRESERVES it and never SETS it (D38), and why a SPAWNED box arrives with
# site deploys off and 503s on its first one. That is the design, not a gap:
# nothing in a provisioning path may consent on a box owner's behalf, so this
# script does not, and neither does the spawner.
#
# What WAS prose and is now EXECUTABLE is the other half — the four things that
# must be true before a box can actually HONOUR its consent. Every one of them
# has a named failure already sitting in this tree:
#
#   npm on the BEAM's PATH  barkpark-slot@.service sets no PATH=, so the BEAM
#                           gets systemd's default plus whatever api/start.sh
#                           exports. An asdf node whose `npm` was never reshimmed
#                           is INVISIBLE there and the site BUILD dies on its
#                           first command. Derived by REPLAYING start.sh's own
#                           export line, so a change there moves this check too.
#   flock(1)                deploy/lib/site-deploy-common.sh:374-377 makes the
#                           fleet build admission gate FAIL OPEN without it — two
#                           builds compile at once on a one-slot box, and it says
#                           so only in a WARN nobody reads.
#   python3 or caddy        deploy/site-deploy.sh:311-318 — with neither, the
#                           throwaway HEALTH server cannot start, the gate cannot
#                           run AT ALL, and every site deploy fails at HEALTH.
#   >= 2G available RAM     one build slot at MemoryMax=1500M on a box with less
#                           headroom swap-thrashes; that is the shape that
#                           produced the DBConnection 500s.
#
# `--site-deploy-preflight` is read-only, takes NO lock (a running deploy must
# never hide the answer) and exits typed: 0 all met, 31 npm, 32 flock, 33 health
# server, 34 memory. It prints one machine-parsable line per prerequisite either
# way, so the operator sees all four even when the exit names the first.
SITE_PREREQ_MEMINFO="${BARKPARK_MEMINFO:-/proc/meminfo}"
SITE_PREREQ_MIN_AVAIL_KB="${BARKPARK_SITE_PREREQ_MIN_AVAIL_KB:-2097152}"   # 2 GiB
# systemd's documented fallback PATH for a unit that sets none (systemd.exec(5)).
SITE_PREREQ_BASE_PATH="${BARKPARK_BEAM_BASE_PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"

beam_path() { # the PATH the slot BEAM actually boots with, on stdout
  local base="$SITE_PREREQ_BASE_PATH" f p line
  # An EnvironmentFile PATH= would win over the unit's inherited environment.
  for f in "$APP/.slots/blue.env" "$APP/.slots/green.env"; do
    [ -f "$f" ] || continue
    p="$(sed -n 's/^PATH=//p' "$f" 2>/dev/null | tail -1)"
    [ -n "$p" ] && base="$p"
  done
  # REPLAY api/start.sh's own export (it IS the unit's ExecStart) instead of
  # re-typing it here — the same discipline instance-deploy_test.sh uses for the
  # name-encoding guard. A start.sh that stops prepending the shims must make
  # this check say so, not keep asserting a path nobody exports any more.
  line="$(grep -m1 '^export PATH=' "$APP/api/start.sh" 2>/dev/null || true)"
  if [ -n "$line" ]; then
    # The base PATH is set INSIDE the replay shell, never as a `PATH=… bash -c`
    # prefix: that prefix is used to find `bash` itself, so a base without a
    # shell on it (the harness fixture, or a slot env that pins a narrow PATH)
    # makes the replay exit 127 and silently degrade to the un-replayed base —
    # a check that stops reading start.sh without ever saying so.
    local replayed
    replayed="$(BP_BASE_PATH="$base" bash -c 'PATH="$BP_BASE_PATH"
'"$line"'
printf %s "$PATH"' 2>/dev/null || true)"
    printf '%s' "${replayed:-$base}"
  else
    printf '%s' "$base"
  fi
}

path_has() { # <cmd> <colon-path> — 0 if an executable <cmd> sits on <colon-path>
  local d rc=1
  local IFS=:
  # shellcheck disable=SC2086  # deliberate word-split of the colon path
  for d in $2; do
    [ -n "$d" ] && [ -x "$d/$1" ] && { rc=0; break; }
  done
  return "$rc"
}

site_deploy_consent() { # 0 = this box has recorded consent somewhere it is read
  local f
  for f in "$APP/.slots/blue.env" "$APP/.slots/green.env" "$APP/.env"; do
    [ -f "$f" ] && grep -qE '^BARKPARK_SITE_DEPLOY_APPLY=1[[:space:]]*$' "$f" 2>/dev/null && return 0
  done
  return 1
}

site_deploy_prereqs() { # prints 4 lines; 0 all met, else the LOWEST failing code
  local rc=0 bp avail
  bp="$(beam_path)"

  if path_has npm "$bp"; then
    echo "SITE_DEPLOY_PREREQ_NPM=ok"
  else
    echo "SITE_DEPLOY_PREREQ_NPM=MISSING no executable 'npm' on the BEAM's PATH ($bp) — an asdf node installed without a reshimmed npm is invisible to the slot unit and the site BUILD dies on its first command"
    [ "$rc" = 0 ] && rc=31
  fi

  if command -v flock >/dev/null 2>&1; then
    echo "SITE_DEPLOY_PREREQ_FLOCK=ok"
  else
    echo "SITE_DEPLOY_PREREQ_FLOCK=MISSING no flock(1) — the fleet build admission gate FAILS OPEN (site-deploy-common.sh:374-377), so two site builds can compile at once on a one-slot box; install util-linux"
    [ "$rc" = 0 ] && rc=32
  fi

  if command -v python3 >/dev/null 2>&1 || command -v caddy >/dev/null 2>&1; then
    echo "SITE_DEPLOY_PREREQ_HEALTH_SERVER=ok"
  else
    echo "SITE_DEPLOY_PREREQ_HEALTH_SERVER=MISSING neither python3 nor caddy — the throwaway HEALTH server cannot start, so site-deploy.sh cannot gate AT ALL and every site deploy fails at HEALTH"
    [ "$rc" = 0 ] && rc=33
  fi

  avail="$(awk '/^MemAvailable:/ { print $2; exit }' "$SITE_PREREQ_MEMINFO" 2>/dev/null || true)"
  case "$avail" in
    ''|*[!0-9]*)
      # A prerequisite that cannot be MEASURED is not met. Refusing to answer is
      # the one thing a preflight may never do quietly.
      echo "SITE_DEPLOY_PREREQ_MEMORY=UNKNOWN no MemAvailable in $SITE_PREREQ_MEMINFO — this box's build headroom cannot be measured, so it is not proven"
      [ "$rc" = 0 ] && rc=34 ;;
    *)
      if [ "$avail" -ge "$SITE_PREREQ_MIN_AVAIL_KB" ]; then
        echo "SITE_DEPLOY_PREREQ_MEMORY=ok ${avail}kB available (want >= ${SITE_PREREQ_MIN_AVAIL_KB}kB)"
      else
        echo "SITE_DEPLOY_PREREQ_MEMORY=LOW ${avail}kB available, want >= ${SITE_PREREQ_MIN_AVAIL_KB}kB — one build slot peaks at MemoryMax=1500M and a box with less headroom swap-thrashes into DBConnection 500s"
        [ "$rc" = 0 ] && rc=34
      fi ;;
  esac
  return "$rc"
}

MODE=deploy
case "${1:-}" in
  --rollback)            MODE=rollback ;;
  --rollback-preflight)  MODE=preflight ;;
  --site-deploy-preflight) MODE=site-preflight ;;
  "") ;;
  *) log "unknown flag '${1}' (supported: --rollback, --rollback-preflight, --site-deploy-preflight)"; exit 2 ;;
esac

# Read-only and LOCK-FREE on purpose: this answers a question about the box, not
# about a deploy, and an operator deciding whether to consent must not be told
# "already_running" because CD happens to be mid-run.
if [ "$MODE" = "site-preflight" ]; then
  if site_deploy_consent; then
    echo "SITE_DEPLOY_CONSENT=granted"
  else
    echo "SITE_DEPLOY_CONSENT=absent this box has not opted in to running third-party site build code; the site-deploy door answers 503 until its owner decides otherwise"
  fi
  site_deploy_prereqs
  site_prereq_rc=$?
  if [ "$site_prereq_rc" = 0 ]; then echo "SITE_DEPLOY_PREREQ=ok"; else echo "SITE_DEPLOY_PREREQ=unmet"; fi
  exit "$site_prereq_rc"
fi

# ---- Serialize: overlapping runs (back-to-back merges, manual + CD) queue
# here. Each run pulls AFTER taking the lock, so a queued run deploys the
# latest HEAD; if its commits were already shipped by the run ahead of it,
# the coalesce check below turns it into a no-op. Rollback modes NEVER queue:
# racing a deploy would flip to a slot mid-rebuild, so a held lock is a typed
# refusal (23 = already_running) the caller surfaces honestly.
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
# ---- WHO HOLDS THE LOCK (task-e0e4fa0b709c093e) ----------------------------
# A lock is correct. Two concurrent deploys onto one box would be worse than any
# stall. What was wrong until this block existed is that the contention path was
# MUTE: a queued run printed "another deploy holds the lock" and then, thirty
# minutes later, "gave up waiting", and NOTHING in between or afterwards said
# WHO held it. Every queued run rediscovered the same nothing, so no agent and
# no human could act on the log they were given.
#
# MEASURED, 2026-09-22 (deploy.yml `instance` jobs, the whole failure set):
#   35698504994  07:14:06Z -> 12:33:49Z  319.7 min, exit 14  <- took the lock
#   35699709131  07:29:41Z -> 08:00:02Z   30.4 min, exit 15  <- first to queue
#   ...thirteen more, every one 30.2-30.4 min, every one exit 15...
#   35724457145  11:59:34Z -> 12:29:49Z   30.2 min, exit 15  <- last to queue
# FIFTEEN runs burned 30 minutes each discovering a lock they could not name.
# (The row that filed this said "eleven of twelve" over 09:27-12:51Z; the runs
# say FIFTEEN of sixteen over 07:29-12:29Z. Both numbers describe the same
# episode; the run list is the one that was counted.)
#
# THE CAUSE OF THAT EPISODE IS UNKNOWN AND IS NOT WHAT THIS BLOCK FIXES.
# Nobody established how the lock cleared. Run 35698504994 held it, went silent
# after 07:20:17Z, and ended exit 14 at 12:33:49Z, minutes before the queue
# drained — but whether it exited on its own or an owner ended it was never
# determined, and this block does not determine it either. Do not read the code
# below as a remedy for a diagnosed root cause. It is a remedy for the fact that
# the log could not answer the question.
LOCK_HOLDER_RECORD="${LOCK}.holder"

# N = 45 MINUTES, and it is not a round number (see the stale policy below).
# TWO independent measurements put a legitimate holder far under it:
#   * The longest SUCCESSFUL `instance` job in 195 jobs over 2026-09-17..23 ran
#     752 s = 12.5 min (run 35287987631); the median ran 343 s = 5.7 min. That
#     job clock is already an OVER-estimate of the hold: it also covers
#     checkout, the served-sha probe, scp, and the smoke + ancestry steps that
#     run AFTER the lock is released. 45 min is 3.6x the worst of those.
#   * 45 min is exactly the runner's own tolerance for a silent remote:
#     deploy.yml sets ServerAliveInterval=30 x ServerAliveCountMax=90 = 2700 s
#     on the ssh session that STARTS a holder. Past 45 min that session is gone
#     by construction, so a holder older than N has already lost the channel it
#     would report success on. There is no legitimate deploy on the far side.
DEPLOY_LOCK_STALE_SECS="${BARKPARK_DEPLOY_LOCK_STALE_SECS:-2700}"
case "$DEPLOY_LOCK_STALE_SECS" in ''|*[!0-9]*) DEPLOY_LOCK_STALE_SECS=2700 ;; esac
# The liveness SAMPLE WINDOW. Two samples this far apart; see holder_is_live.
DEPLOY_LOCK_LIVENESS_SECS="${BARKPARK_DEPLOY_LOCK_LIVENESS_SECS:-30}"
case "$DEPLOY_LOCK_LIVENESS_SECS" in ''|*[!0-9]*) DEPLOY_LOCK_LIVENESS_SECS=30 ;; esac
# The DELIBERATE break: off unless a caller sets it to exactly 1. deploy.yml
# passes it from the `break_deploy_lock` workflow_dispatch input, which is a
# boolean defaulting to false. Anything that is not the literal 1 is off.
DEPLOY_LOCK_BREAK="${BARKPARK_DEPLOY_LOCK_BREAK:-0}"
[ "$DEPLOY_LOCK_BREAK" = 1 ] || DEPLOY_LOCK_BREAK=0

# Every pid holding the lock file open, OURS EXCLUDED. `exec 9>"$LOCK"` below
# opens the file before flock, so this process is always in the raw list and
# would otherwise be reported as its own holder.
# fuser(1) first (util-linux, present on the box), lsof(1) as the fallback. If
# NEITHER exists this prints nothing, and every caller below treats "no
# identifiable holder" as a refusal to break — never as permission.
# fd 9 CLOSED IN THE ENUMERATOR, and this is not a nicety. `exec 9>"$LOCK"`
# leaves fd 9 open across every fork, so the very subshell that runs fuser
# INHERITS it — fuser then reports itself, its pipeline partner, and any other
# child of ours as holders of the lock we are waiting for. Measured while
# writing this: a single probe answered "88238 88240 88241 88242" where only
# 88238 held anything; the rest were the probe. Unfixed, the automatic break
# below would have SIGKILLed its own pipeline and reported the lock unbreakable.
deploy_lock_holder_pids() {
  local raw="" p tmpf
  tmpf="${TMPDIR:-/tmp}/bp-deploy-lockpids.$$"
  # THE ENUMERATOR WRITES TO A FILE, NOT INTO `$( )`, AND THAT IS THE WHOLE
  # POINT. A command substitution forks a subshell of its own, and THAT subshell
  # still holds fd 9 — so `raw="$( ( exec 9>&-; fuser ... ) | tr ... )"` still
  # lists the substitution shell and the `tr` beside it. Measured while writing
  # this: one probe answered "22329 22387 22388 22390" where only 22329 held
  # anything, the liveness sampler then saw a set that "changed between samples"
  # (it was reading its own transient pids), and every holder was judged LIVE
  # forever. Redirecting to a file means the ONLY process alive at enumeration
  # time is the subshell below, which has closed fd 9.
  ( exec 9>&-
    if command -v fuser >/dev/null 2>&1; then
      fuser "$LOCK" 2>/dev/null
    elif command -v lsof >/dev/null 2>&1; then
      lsof -t -- "$LOCK" 2>/dev/null
    fi
  ) > "$tmpf" 2>/dev/null
  raw="$(tr -s ' \t' '\n\n' < "$tmpf" 2>/dev/null)"
  rm -f "$tmpf" 2>/dev/null || true
  if [ -z "$raw" ] && command -v fuser >/dev/null 2>&1 && command -v lsof >/dev/null 2>&1; then
    # fuser exists but answered nothing; lsof is the second opinion.
    ( exec 9>&-; lsof -t -- "$LOCK" 2>/dev/null ) > "$tmpf" 2>/dev/null
    raw="$(tr -s ' \t' '\n\n' < "$tmpf" 2>/dev/null)"
    rm -f "$tmpf" 2>/dev/null || true
  fi
  # OUR OWN PROCESS TREE IS NOT THE HOLDER. Closing fd 9 in the enumerator is
  # not enough on its own: callers capture this function with `$( )`, and THAT
  # substitution shell holds fd 9 for as long as the function runs, so fuser
  # lists it too. Two filters, because each catches what the other cannot:
  #   * pids that are GONE by now (the transient shells of the enumeration
  #     itself) — a process that has exited cannot be holding a flock, so this
  #     is sound independently of what produced it; and
  #   * pids that are $$ or a DESCENDANT of $$ — the live substitution shell.
  #     A real holder is never a descendant of this script.
  local mine own
  # If the process table cannot be read we cannot tell OUR OWN substitution
  # shell from the holder — and the manual break would then SIGKILL the shell it
  # is running inside. Answer "no identifiable holder" instead, which every
  # caller already treats as a refusal to break.
  if ! own="$(proc_descendants "$$")"; then
    log "lock holder: the process table could not be read, so this run cannot tell its own subshells from the holder — reporting NO identifiable holder rather than risk breaking itself"
    return 0
  fi
  mine=" $$ $(printf '%s' "$own" | tr '\n' ' ') "
  for p in $raw; do
    # BSD fuser suffixes an access-mode letter to each pid ("1234c"); GNU fuser
    # does not. Strip a trailing non-digit run rather than dropping the entry,
    # or every holder is invisible on a BSD box.
    p="${p%%[!0-9]*}"
    case "$p" in ''|*[!0-9]*) continue ;; esac
    case "$mine" in *" $p "*) continue ;; esac
    ps -p "$p" >/dev/null 2>&1 || continue
    printf '%s\n' "$p"
  done
}

# Elapsed seconds for a pid. `ps -o etimes=` is GNU-only; the BSD/macOS ps this
# harness also runs on has only the formatted `etime` ([[dd-]hh:]mm:ss), so the
# fallback parses it rather than printing "?" on half the machines that read
# this code. Prints nothing when the pid is gone.
proc_elapsed_secs() {
  local pid="$1" e d rest h m s
  e="$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ')"
  case "$e" in ''|*[!0-9]*) e="" ;; esac
  if [ -n "$e" ]; then printf '%s\n' "$e"; return 0; fi
  e="$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')"
  [ -n "$e" ] || return 1
  d=0; rest="$e"
  case "$rest" in *-*) d="${rest%%-*}"; rest="${rest#*-}" ;; esac
  h=0
  case "$rest" in
    *:*:*) h="${rest%%:*}"; rest="${rest#*:}" ;;
  esac
  m="${rest%%:*}"; s="${rest#*:}"
  case "$d$h$m$s" in *[!0-9]*) return 1 ;; esac
  printf '%s\n' $(( 10#$d * 86400 + 10#$h * 3600 + 10#$m * 60 + 10#$s ))
}

# Total CPU seconds consumed by a pid and every descendant of it. The second
# half of the liveness test: a deploy that is working burns CPU even when it
# happens to have no child at the instant we look.
proc_tree_cputime() {
  local pid="$1" total=0 t
  for t in $(ps -eo pid=,ppid=,time= 2>/dev/null | awk -v root="$pid" '
    { pid[$1]=$1; ppid[$1]=$2; tm[$1]=$3 }
    END {
      # mark root and everything reachable downward from it
      for (i = 0; i < 64; i++) { mark[root]=1
        for (p in pid) if (ppid[p] in mark) mark[p]=1 }
      for (p in mark) if (p in tm) print tm[p]
    }'); do
    # [[dd-]hh:]mm:ss -> seconds
    local dd=0 hh=0 mm ss r="$t"
    case "$r" in *-*) dd="${r%%-*}"; r="${r#*-}" ;; esac
    case "$r" in *:*:*) hh="${r%%:*}"; r="${r#*:}" ;; esac
    mm="${r%%:*}"; ss="${r#*:}"; ss="${ss%%.*}"
    case "$dd$hh$mm$ss" in ''|*[!0-9]*) continue ;; esac
    total=$(( total + 10#$dd * 86400 + 10#$hh * 3600 + 10#$mm * 60 + 10#$ss ))
  done
  printf '%s\n' "$total"
}

# Direct + transitive children of a pid, one per line.
#
# RETURNS NON-ZERO WHEN IT CANNOT LOOK, and that distinction is load-bearing:
# "this holder has no children" and "I could not read the process table" are
# the same empty stdout, and the liveness test must treat only the FIRST as
# evidence. An unreadable table that silently read as "childless" would be a
# direct route to SIGKILLing a working deploy.
#
# VERIFIED ON BOTH PLATFORMS, because an empty answer with a benign explanation
# is exactly where a blind enumerator hides. Ubuntu 24.04 / bash 5.2 / mawk
# 1.3.4 / procps-ng 4.0.4: a direct child is found, and a GRANDCHILD is found
# too (holder 468 -> 472 -> 473 all reported). macOS / bash 3.2 / BSD awk:
# the same. See the fixture's own precondition check in
# deploy/instance-deploy_test.sh, which now refuses to draw a conclusion from a
# specimen that has no child.
proc_descendants() {
  local table
  table="$(ps -eo pid=,ppid= 2>/dev/null)"
  [ -n "$table" ] || return 1
  printf '%s\n' "$table" | awk -v root="$1" '
    { pid[$1]=$1; ppid[$1]=$2 }
    END {
      for (i = 0; i < 64; i++) { mark[root]=1
        for (p in pid) if (ppid[p] in mark) mark[p]=1 }
      for (p in mark) if (p != root && p in pid) print p
    }'
}

# ---- THE LIVENESS TEST, which is the load-bearing part ---------------------
# Returns 0 (LIVE, never break) / 1 (no sign of deploy work over the window).
#
# WHAT IT IS AND IS NOT DETECTING. A process that has EXITED cannot hold a
# flock — the kernel closes its fds — so "the holder is dead" is not the state
# we can find. What we can find is a holder that is doing NO DEPLOY WORK: an
# instance-deploy.sh that is wedged, or a stray shell that inherited fd 9 and
# is sitting in a read. The test is therefore "is this holder DOING anything",
# sampled over a window, never a single instant.
#
# It is deliberately asymmetric. Every one of these is enough to declare LIVE:
#   * the holder set could not be enumerated at all (no fuser/lsof)
#   * the holder set CHANGED between samples (it is forking)
#   * a holder has ANY descendant process in EITHER sample — this is the arm
#     that protects a real deploy, because mix/git/curl/systemctl/npm/sleep are
#     all children, and a health-poll loop sleeping between probes still has a
#     `sleep` child
#   * total CPU across the holder trees ADVANCED between the samples
# DEAD requires ALL of: enumerable, unchanged set, zero descendants in BOTH
# samples, and zero CPU advance across the full window. A single instant with
# no children proves nothing and is not sufficient on its own.
deploy_lock_holder_is_live() {
  local pids1 pids2 p kids cpu1=0 cpu2=0 c
  pids1="$(deploy_lock_holder_pids)"
  if [ -z "$pids1" ]; then
    log "lock liveness: the holder set could not be enumerated — treating the holder as LIVE (refusing to break what cannot be named)"
    return 0
  fi
  log "lock liveness: sample 1 holder set = [$(printf '%s' "$pids1" | tr '\n' ' ')]"
  for p in $pids1; do
    if ! kids="$(proc_descendants "$p")"; then
      log "lock liveness: the process table could not be read — treating the holder as LIVE (an unreadable table is not evidence of a dead holder)"
      return 0
    fi
    log "lock liveness: sample 1 pid=$p descendants = [$(printf '%s' "$kids" | tr '\n' ' ')] cputree=$(proc_tree_cputime "$p")s"
    if [ -n "$kids" ]; then
      log "lock liveness: holder pid=$p has running child process(es) [$(printf '%s' "$kids" | tr '\n' ' ')] — LIVE, not breaking"
      return 0
    fi
    c="$(proc_tree_cputime "$p")"; cpu1=$(( cpu1 + c ))
  done
  log "lock liveness: no child process under any holder in sample 1 (cpu=${cpu1}s); re-sampling in ${DEPLOY_LOCK_LIVENESS_SECS}s before judging"
  sleep "$DEPLOY_LOCK_LIVENESS_SECS"
  pids2="$(deploy_lock_holder_pids)"
  if [ -z "$pids2" ]; then
    log "lock liveness: the holder set could not be enumerated on the second sample — treating the holder as LIVE"
    return 0
  fi
  if [ "$pids1" != "$pids2" ]; then
    log "lock liveness: the holder set changed between samples ($(printf '%s' "$pids1" | tr '\n' ' ')-> $(printf '%s' "$pids2" | tr '\n' ' ')) — it is forking, LIVE, not breaking"
    return 0
  fi
  log "lock liveness: sample 2 holder set = [$(printf '%s' "$pids2" | tr '\n' ' ')]"
  for p in $pids2; do
    if ! kids="$(proc_descendants "$p")"; then
      log "lock liveness: the process table could not be read on the second sample — treating the holder as LIVE"
      return 0
    fi
    log "lock liveness: sample 2 pid=$p descendants = [$(printf '%s' "$kids" | tr '\n' ' ')] cputree=$(proc_tree_cputime "$p")s"
    if [ -n "$kids" ]; then
      log "lock liveness: holder pid=$p has running child process(es) [$(printf '%s' "$kids" | tr '\n' ' ')] on the second sample — LIVE, not breaking"
      return 0
    fi
    c="$(proc_tree_cputime "$p")"; cpu2=$(( cpu2 + c ))
  done
  if [ "$cpu2" -gt "$cpu1" ]; then
    log "lock liveness: holder CPU advanced ${cpu1}s -> ${cpu2}s across ${DEPLOY_LOCK_LIVENESS_SECS}s — LIVE, not breaking"
    return 0
  fi
  log "lock liveness: NO SIGN OF WORK — over ${DEPLOY_LOCK_LIVENESS_SECS}s the holder set was unchanged, had zero child processes in both samples, and burned zero CPU (${cpu1}s -> ${cpu2}s)"
  return 1
}

# How long the CURRENT holder has held the lock, and on what basis. The record
# is the truth when it is there and names a pid that really holds the file;
# otherwise the holder process's own elapsed time, which is an UPPER BOUND on
# the hold (the process is at least as old as its hold). The basis is printed,
# because the two answers differ and a reader deciding whether a break was
# justified needs to know which one was used.
deploy_lock_holder_age() { # echoes "<secs> <basis>", or nothing
  local rec_pid rec_epoch now pids p
  pids="$(deploy_lock_holder_pids)"
  [ -n "$pids" ] || return 1
  if [ -r "$LOCK_HOLDER_RECORD" ]; then
    rec_pid="$(sed -n 's/^pid=//p' "$LOCK_HOLDER_RECORD" | head -1)"
    rec_epoch="$(sed -n 's/^acquired_epoch=//p' "$LOCK_HOLDER_RECORD" | head -1)"
    case "$rec_epoch" in ''|*[!0-9]*) rec_epoch="" ;; esac
    if [ -n "$rec_epoch" ]; then
      for p in $pids; do
        if [ "$p" = "$rec_pid" ]; then
          now="$(date -u +%s)"
          printf '%s holder-record\n' $(( now - rec_epoch ))
          return 0
        fi
      done
    fi
  fi
  for p in $pids; do
    now="$(proc_elapsed_secs "$p")" || continue
    printf '%s process-elapsed(upper-bound)\n' "$now"
    return 0
  done
  return 1
}

# CRITERION 1: this is what eleven-to-fifteen runs could not print.
log_deploy_lock_holder() {
  local pids p elapsed cmd age
  pids="$(deploy_lock_holder_pids)"
  if [ -n "$pids" ]; then
    for p in $pids; do
      if elapsed="$(proc_elapsed_secs "$p")"; then elapsed="${elapsed}s"; else elapsed="unknown"; fi
      cmd="$(ps -o args= -p "$p" 2>/dev/null | tr '\n' ' ')"
      log "lock holder: pid=$p elapsed=$elapsed cmd=${cmd:-<exited between the listing and the read>}"
    done
  else
    log "lock holder: NO pid could be identified as holding $LOCK — fuser(1) and lsof(1) are both absent or answered nothing. Install util-linux/lsof on this box; until then the holder cannot be named and will never be broken automatically."
  fi
  if [ -r "$LOCK_HOLDER_RECORD" ]; then
    log "lock holder record ($LOCK_HOLDER_RECORD): $(tr '\n' ' ' < "$LOCK_HOLDER_RECORD")"
  else
    log "lock holder record: absent ($LOCK_HOLDER_RECORD) — the holder started before this script recorded holders, or could not write it"
  fi
  if age="$(deploy_lock_holder_age)"; then
    log "lock holder age: ${age% *}s (basis: ${age#* }); the stale-holder threshold is ${DEPLOY_LOCK_STALE_SECS}s"
  fi
}

# The holder writes itself down the moment it wins, so the NEXT contender does
# not depend on fuser/lsof to learn who to blame. Written to a SIDECAR, never
# into $LOCK: `exec 9>"$LOCK"` truncates that file at open, so every queued run
# would wipe the holder's own record before it ever read it.
record_deploy_lock_holder() {
  {
    printf 'pid=%s\n' "$$"
    printf 'acquired_epoch=%s\n' "$(date -u +%s)"
    printf 'acquired_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'mode=%s\n' "$MODE"
    printf 'github_run_id=%s\n' "${GITHUB_RUN_ID:-<none>}"
    printf 'cmd=%s\n' "$(ps -o args= -p $$ 2>/dev/null | tr '\n' ' ')"
  } > "$LOCK_HOLDER_RECORD" 2>/dev/null \
    || log "could not write $LOCK_HOLDER_RECORD — the next contender falls back to fuser/lsof"
  # Held while the trap runs (fds close after traps), so this can never delete a
  # successor's record.
  trap 'rm -f "$LOCK_HOLDER_RECORD" 2>/dev/null || true' EXIT
}

# Break the lock by ending its holders, then retry. NEVER called on its own
# judgement — both call sites below decide first and say which decision fired.
# $1 is the reason, printed verbatim, because "it broke the lock" without
# "and here is why it judged it broken" is the same mute log this block exists
# to end.
break_deploy_lock() { # <reason>
  local pids p
  pids="$(deploy_lock_holder_pids)"
  if [ -z "$pids" ]; then
    log "lock break: refusing — no holder pid could be identified, so there is nothing to end and a blind break would only race the real holder"
    return 1
  fi
  log "lock break: ending holder pid(s) [$(printf '%s' "$pids" | tr '\n' ' ')] — $1"
  for p in $pids; do kill -TERM "$p" 2>/dev/null || true; done
  sleep 5
  for p in $pids; do
    if kill -0 "$p" 2>/dev/null; then
      log "lock break: pid=$p ignored SIGTERM — SIGKILL"
      kill -KILL "$p" 2>/dev/null || true
    fi
  done
  sleep 2
  rm -f "$LOCK_HOLDER_RECORD" 2>/dev/null || true
  if flock -n 9; then
    log "lock break: SUCCEEDED — this run now holds the deploy lock"
    return 0
  fi
  log "lock break: the lock is STILL held after ending those pids — not proceeding; the deploy stays refused rather than running unserialised"
  return 1
}

queue_for_deploy_lock() {
  local budget="$1" label="${2:-the deploy lock}" beat waited=0 step holder_pids
  beat="${BARKPARK_LOCK_HEARTBEAT_SECS:-60}"
  case "$beat" in ''|*[!0-9]*) beat=60 ;; esac
  [ "$beat" -lt 1 ] && beat=60
  while [ "$waited" -lt "$budget" ]; do
    step=$(( budget - waited ))
    [ "$step" -gt "$beat" ] && step="$beat"
    flock -w "$step" 9 && return 0
    waited=$(( waited + step ))
    # The heartbeat carries the HOLDER, not just the clock. A reader who joins
    # the log mid-queue should never have to scroll back to the first contention
    # line to learn which pid to look at, and the pid can change under them:
    # runs queued behind one holder are inherited by the next one that wins.
    holder_pids="$(deploy_lock_holder_pids | tr '\n' ' ')"
    log "still queued for $label — ${waited}s waited of ${budget}s max (holder pid(s): ${holder_pids:-<unidentifiable>})"
  done
  return 1
}

exec 9>"$LOCK"
if ! flock -n 9; then
  # THE MUTE PATH ENDS HERE. Whatever we do next, the log first says who holds
  # it — this runs before the refusal, before the queue, and before any break.
  log_deploy_lock_holder
  if [ "$MODE" != "deploy" ]; then
    log "deploy lock held — refusing to $MODE while a deploy runs (already_running)"
    exit 23
  fi
  # CRITERION 3: the DELIBERATE break. Off unless deploy.yml's
  # `break_deploy_lock` workflow_dispatch input was set, and it does NOT consult
  # the age or the liveness test — that is the point of it: it is the path for a
  # human who already knows the holder is gone and is taking responsibility for
  # that judgement. The wording below is deliberately distinct from the
  # automatic path's, so an operator reading the run afterwards can tell which
  # one fired without reading this file.
  if [ "$DEPLOY_LOCK_BREAK" = 1 ]; then
    log "lock break: MANUAL — requested by the break_deploy_lock workflow_dispatch input (BARKPARK_DEPLOY_LOCK_BREAK=1). The age and liveness tests are NOT consulted on this path; a human asserted the holder is gone."
    if break_deploy_lock "MANUAL break requested by an operator via the break_deploy_lock dispatch input"; then
      record_deploy_lock_holder
    else
      log "gave up: the MANUAL break did not obtain the deploy lock"
      exit 15
    fi
  else
    # The BUDGET, 30 min, unchanged. The env var exists ONLY so
    # deploy/instance-deploy_test.sh can drive the exhaustion path in seconds --
    # exactly like BARKPARK_LOCK_HEARTBEAT_SECS above; nothing on a box sets it.
    queue_budget="${BARKPARK_DEPLOY_LOCK_QUEUE_SECS:-1800}"
    case "$queue_budget" in ''|*[!0-9]*) queue_budget=1800 ;; esac
    log "another deploy holds the lock — queueing (max ${queue_budget}s)"
    if ! queue_for_deploy_lock "$queue_budget"; then
      # CRITERION 2: the STALE-HOLDER POLICY, evaluated only here — after the
      # full 30-minute budget is already spent, so it can never shorten a wait
      # that would have succeeded. Its preconditions are ALL of:
      #   (a) the holder is identifiable (fuser/lsof named a pid), and
      #   (b) its age exceeds N = $DEPLOY_LOCK_STALE_SECS, and
      #   (c) deploy_lock_holder_is_live says there is no sign of deploy work.
      # Any one of them missing leaves the lock alone and this run exits 15 as
      # it always did. A policy that can break a LIVE deploy is worse than the
      # stall it replaces, so (c) is the load-bearing gate and every ambiguous
      # answer inside it resolves to LIVE.
      log_deploy_lock_holder
      stale_age=""
      if stale_age="$(deploy_lock_holder_age)"; then :; else stale_age=""; fi
      if [ -z "$stale_age" ]; then
        log "stale-holder policy: NOT APPLIED — the holder could not be identified, so its age is unknown. Exiting 15 with the lock untouched."
        log "gave up waiting for the deploy lock"
        exit 15
      fi
      stale_secs="${stale_age% *}"
      stale_basis="${stale_age#* }"
      if [ "$stale_secs" -lt "$DEPLOY_LOCK_STALE_SECS" ]; then
        log "stale-holder policy: NOT APPLIED — the holder is ${stale_secs}s old (basis: $stale_basis), under the ${DEPLOY_LOCK_STALE_SECS}s threshold. A holder inside the threshold is a slow deploy, not a stuck one."
        log "gave up waiting for the deploy lock"
        exit 15
      fi
      log "stale-holder policy: the holder is ${stale_secs}s old (basis: $stale_basis), over the ${DEPLOY_LOCK_STALE_SECS}s threshold. Testing whether it is still doing deploy work before judging it."
      if deploy_lock_holder_is_live; then
        log "stale-holder policy: NOT APPLIED — the holder is over the age threshold but is STILL WORKING. An old deploy is not a broken one. Exiting 15 with the lock untouched."
        log "gave up waiting for the deploy lock"
        exit 15
      fi
      log "stale-holder policy: APPLIED — AUTOMATIC. Judged broken because it held the lock for ${stale_secs}s (basis: $stale_basis, over the ${DEPLOY_LOCK_STALE_SECS}s threshold) AND showed no child process and no CPU advance over a ${DEPLOY_LOCK_LIVENESS_SECS}s window. This is the automatic path, not an operator request."
      if break_deploy_lock "AUTOMATIC stale-holder policy: ${stale_secs}s old (basis: $stale_basis) with no live child deploy process over ${DEPLOY_LOCK_LIVENESS_SECS}s"; then
        record_deploy_lock_holder
      else
        log "gave up waiting for the deploy lock"
        exit 15
      fi
    else
      record_deploy_lock_holder
    fi
  fi
else
  record_deploy_lock_holder
fi

export PATH="$HOME/.asdf/shims:/usr/local/go/bin:$PATH"
[ -f "$HOME/.asdf/asdf.sh" ] && . "$HOME/.asdf/asdf.sh"

cd "$APP" || { log "no $APP"; exit 10; }
STATE="$APP/.instance-deploy-last"   # commit of the last HEALTHY deploy
OLD="$(git rev-parse HEAD)"
log "current=$OLD"

# ---- Rollback modes (W6). Flip+reset, never flip-only: both slots share ONE
# checkout, so a bare Caddy flip + slot restart would `mix phx.server`-recompile
# NEW source into the old slot's stale build root (proven by the mix-staleness
# probe). `git reset --hard <stamp>` — this script's own failure-path idiom —
# restores the old code byte-identically. Schema stays FORWARD: rolling back
# code does NOT undo the schema; write a compensating migration (PROD_OPS law).
# The health gate proves boot + a shallow endpoint, NOT schema compatibility.
if [ "$MODE" != "deploy" ]; then
  # Preflight checks (shared by both modes; --rollback-preflight is read-only).
  if [ ! -d "$APP/.slots" ]; then
    log "no $APP/.slots — this box predates per-slot stamps (not_supported)"
    exit 22
  fi
  # Slot ports ONLY (never 40[0-9]{2}): the Caddyfile also carries the /mcp
  # route's localhost:4010 and the /connectors route's localhost:4020, which a
  # loose grep + head -1 would misread as the active slot.
  ACTIVE_PORT="$(grep -oE "localhost:(${BLUE_PORT}|${GREEN_PORT})" "$CADDYFILE" 2>/dev/null | head -1 | cut -d: -f2)"
  ACTIVE_PORT="${ACTIVE_PORT:-$BLUE_PORT}"
  if [ "$ACTIVE_PORT" = "$BLUE_PORT" ]; then
    LIVE=blue; TARGET_SLOT=green; TARGET_PORT="$GREEN_PORT"
  else
    LIVE=green; TARGET_SLOT=blue; TARGET_PORT="$BLUE_PORT"
  fi
  TARGET_SHA="$(cat "$APP/.slots/$TARGET_SLOT.sha" 2>/dev/null || true)"
  if [ -z "$TARGET_SHA" ]; then
    log "idle slot '$TARGET_SLOT' has no recorded sha (.slots/$TARGET_SLOT.sha) — no_previous_slot"
    exit 21
  fi
  if [ ! -d "$APP/api/_build_$TARGET_SLOT/prod" ]; then
    log "idle slot '$TARGET_SLOT' has no complete build root (api/_build_$TARGET_SLOT/prod) — no_previous_slot"
    exit 21
  fi
  if [ "$MODE" = "preflight" ]; then
    log "rollback possible: would flip :$ACTIVE_PORT ($LIVE) -> :$TARGET_PORT ($TARGET_SLOT) at $TARGET_SHA"
    echo "TARGET_SLOT=$TARGET_SLOT"
    echo "TARGET_SHA=$TARGET_SHA"
    exit 0
  fi

  # --rollback: mutate. $OLD (the live checkout's HEAD) is what every failure
  # path resets back to, keeping sources in step with the still-serving slot.
  log "ROLLBACK: flip :$ACTIVE_PORT ($LIVE) -> :$TARGET_PORT ($TARGET_SLOT) at $TARGET_SHA"
  if ! git reset --hard "$TARGET_SHA"; then
    log "git reset --hard $TARGET_SHA failed — checkout unchanged, Caddy untouched, no flip"
    exit 24
  fi

  # Rebuild the pdrender wasm at the OLD sha (same non-fatal contract as the
  # forward path: a failed build only degrades the reader's TUI view to its
  # fallback). priv/static is ONE shared dir, so this is healing, not snapshot.
  log "building pdrender wasm at rolled-back sha (non-fatal)"
  if command -v go >/dev/null 2>&1; then
    if make wasm; then log "pdrender wasm built"; else log "WARN: pdrender wasm build failed — reader TUI view degrades to its fallback"; fi
  else
    log "go not found — skipping pdrender wasm build"
  fi

  log "boot barkpark-slot@$TARGET_SLOT on :$TARGET_PORT"
  systemctl restart "barkpark-slot@$TARGET_SLOT"
  ok=0
  for _ in $(seq 1 40); do
    code="$(bp_curl_code -s -o /dev/null --max-time 5 "http://localhost:${TARGET_PORT}${HEALTH_PATH}" || echo 000)"
    if [ "$code" = "200" ]; then ok=1; log "slot $TARGET_SLOT healthy ($code)"; break; fi
    sleep 5
  done
  if [ "$ok" != "1" ]; then
    log "slot $TARGET_SLOT UNHEALTHY at $TARGET_SHA — fail closed: slot re-disabled, Caddy untouched, checkout back to live sha"
    systemctl disable --now "barkpark-slot@$TARGET_SLOT" 2>/dev/null || true
    git reset --hard "$OLD"
    exit 24
  fi

  # Hot swap back (mirrors the forward flip; the post-flip public curl below
  # is LOG-ONLY and must never gate — the pre-flip own-port loop above is the gate).
  # UNDER THE SHARED CADDYFILE LOCK (fd 8, D27): site-deploy.sh rewrites this same
  # file. Bracketed inline rather than wrapped in a function because every failure
  # path below EXITS — and an exit releases fd 8 with the process.
  exec 8>"$CADDY_LOCK"
  if ! flock -w 120 8; then
    log "gave up waiting for the Caddyfile lock ($CADDY_LOCK) — no flip, fail closed"
    systemctl disable --now "barkpark-slot@$TARGET_SLOT" 2>/dev/null || true
    git reset --hard "$OLD"; exit 24
  fi
  # Re-read the live upstream INSIDE the lock: ACTIVE_PORT was read before the
  # slot reboot + health gate, and the flip must rewrite what is in the file NOW
  # (that read was the time-of-check half of the race).
  FLIP_FROM="$(grep -oE "localhost:(${BLUE_PORT}|${GREEN_PORT})" "$CADDYFILE" 2>/dev/null | head -1 | cut -d: -f2)"
  FLIP_FROM="${FLIP_FROM:-$ACTIVE_PORT}"
  cp -a "$CADDYFILE" "$CADDYFILE.pre-rollback"
  sed -i "s/localhost:${FLIP_FROM}/localhost:${TARGET_PORT}/g" "$CADDYFILE"
  # Same landed-check as the forward flip, and MORE load-bearing here: this
  # path's post-flip curl is deliberately log-only, so without this a rollback
  # whose sed matched nothing would log "ROLLED BACK", rewrite STATE, exit 0 —
  # and then disable the slot Caddy is still pointing at.
  if grep -q "localhost:${FLIP_FROM}" "$CADDYFILE" || ! grep -q "localhost:${TARGET_PORT}" "$CADDYFILE"; then
    log "FLIP DID NOT LAND: after the rollback rewrite $CADDYFILE still carries :$FLIP_FROM (or never gained :$TARGET_PORT) — restoring, no flip, fail closed"
    cp -a "$CADDYFILE.pre-rollback" "$CADDYFILE"
    systemctl disable --now "barkpark-slot@$TARGET_SLOT" 2>/dev/null || true
    git reset --hard "$OLD"; exit 24
  fi
  if ! caddy validate --config "$CADDYFILE" >/dev/null 2>&1; then
    log "Caddyfile invalid after rollback flip — restoring, fail closed"
    cp -a "$CADDYFILE.pre-rollback" "$CADDYFILE"
    systemctl disable --now "barkpark-slot@$TARGET_SLOT" 2>/dev/null || true
    git reset --hard "$OLD"; exit 24
  fi
  if ! systemctl reload caddy; then
    log "caddy reload failed during rollback — restoring, fail closed"
    cp -a "$CADDYFILE.pre-rollback" "$CADDYFILE"; systemctl reload caddy || true
    systemctl disable --now "barkpark-slot@$TARGET_SLOT" 2>/dev/null || true
    git reset --hard "$OLD"; exit 24
  fi
  exec 8>&-   # leaf lock: released the moment the file is written + reloaded
  code="$(bp_curl_code -sk -o /dev/null --max-time 10 --resolve "${HEALTH_HOST}:443:127.0.0.1" "https://${HEALTH_HOST}${HEALTH_PATH}" || echo 000)"
  log "Caddy now -> :$TARGET_PORT (https://${HEALTH_HOST}${HEALTH_PATH} = $code)"

  # Drain, retire the rolled-away slot, and rewrite STATE to the rolled-back
  # sha (W6 D21) — keeps coalesce, the agent's git_commit, and the next
  # deploy's OLD baseline truthful. The retired slot's stamp + build root stay:
  # a second --rollback legitimately flips forward again.
  sleep 5
  systemctl enable "barkpark-slot@$TARGET_SLOT" >/dev/null 2>&1 || true
  systemctl disable --now "barkpark-slot@$LIVE" >/dev/null 2>&1 || true
  echo "$TARGET_SHA" > "$STATE"
  log "ROLLED BACK — slot $TARGET_SLOT live at $TARGET_SHA"
  exit 0
fi

# ---- Channel-gated git step (see header). Fail-closed on the $APP/.staging
# marker: absent => production (strict ff-only main, non-main ref REFUSED);
# present => staging (fetch + hard-reset ANY ref, incl. a PR pull/<n>/head).
DEPLOY_REF="${DEPLOY_REF:-main}"
DEPLOY_REMOTE="${DEPLOY_REMOTE:-origin}"
if [ -f "$APP/.staging" ]; then
  log "staging channel: deploying ref '$DEPLOY_REF' from '$DEPLOY_REMOTE' (post-merge hook suppressed)"
  git -c core.hooksPath=/dev/null fetch "$DEPLOY_REMOTE" "$DEPLOY_REF" || { log "fetch $DEPLOY_REMOTE $DEPLOY_REF failed"; exit 11; }
  # Hard reset to the fetched ref — also discards committed build artifacts,
  # subsuming the prod path's `git checkout -- .`.
  git -c core.hooksPath=/dev/null reset --hard FETCH_HEAD || { log "reset --hard FETCH_HEAD failed"; exit 11; }
else
  if [ "$DEPLOY_REF" != "main" ]; then
    log "refusing DEPLOY_REF '$DEPLOY_REF' on a production box (no $APP/.staging marker) — prod only mirrors origin/main"
    exit 11
  fi
  if [ "$DEPLOY_REMOTE" != "origin" ]; then
    log "refusing DEPLOY_REMOTE '$DEPLOY_REMOTE' on a production box (no $APP/.staging marker) — prod only pulls origin; ignoring it silently would deploy the wrong remote"
    exit 11
  fi
  # A content box is a MIRROR of origin/main — never a source of truth. Fetch +
  # hard-reset (the same idiom the staging path uses, origin/main-locked) instead
  # of `pull --ff-only`: a divergent HEAD (a stray commit made directly on the box,
  # or origin/main rewritten under it) makes --ff-only ABORT ("Not possible to
  # fast-forward") → exit 11 → the box silently stops auto-deploying while every
  # run reports "failure". Reset always converges to origin/main; any local commit
  # is drift to discard, and this also subsumes the old `git checkout -- .` for
  # committed build artifacts. Divergence is surfaced (logged), not swallowed.
  log "git fetch origin main + reset --hard (post-merge hook suppressed — this script IS the deploy)"
  # GIT_TERMINAL_PROMPT=0: this runs over ssh with no tty, so a git that decides
  # it needs a username would otherwise BLOCK on the prompt instead of failing.
  # The failure arm names the git version because "could not read Username" is
  # the symptom BOTH of a credential problem and of the protocol-v2 refusal seen
  # on git 2.34.x boxes (deploy/cp-deploy.sh, PR #15634) — the message must say
  # which reading is even possible, not leave the operator to guess.
  GIT_TERMINAL_PROMPT=0 git -c core.hooksPath=/dev/null fetch origin main || {
    log "fetch origin main failed — git $(git --version 2>&1 | awk '{print $3}'), protocol.version=$(git config --get protocol.version 2>/dev/null || echo 'unset/default'); a 'could not read Username' here can be the WIRE protocol, not credentials — retry with: git -c protocol.version=0 fetch origin main"
    exit 11
  }
  if ! git merge-base --is-ancestor HEAD FETCH_HEAD 2>/dev/null; then
    log "WARNING: box HEAD $(git rev-parse --short HEAD) has DIVERGED from origin/main (a commit was made on the box, or main was rewritten) — discarding local divergence and converging to origin/main"
  fi
  git -c core.hooksPath=/dev/null reset --hard FETCH_HEAD || { log "reset --hard FETCH_HEAD failed"; exit 11; }
fi
NEW="$(git rev-parse HEAD)"
log "target=$NEW"

# Coalesce: the run ahead of us already deployed this exact commit healthily.
if [ "$NEW" = "$OLD" ] && [ "$(cat "$STATE" 2>/dev/null)" = "$NEW" ]; then
  log "HEAD $NEW already deployed healthy — nothing to do"
  exit 0
fi

# ---- The prod-required secret keys (each RAISES at boot) -------------------
# An ABSENT line is not the only broken state. A line that is PRESENT but empty
# (`BARKPARK_KEK=`) matches `grep '^VAR='` exactly as a good one does, so the
# absence-only backfill this loop used to be skipped it — and after the boot
# refusals such a box fails EVERY deploy until a human edits .env by hand
# (fail-closed: the old slot keeps serving, but nobody is coming). The KEK has a
# third broken state on top of that: a non-empty value the app REFUSES.
#
# So: absent, empty, and (for the KEK) structurally invalid are ONE case here —
# mint a fresh secret and APPEND-OR-REPLACE it, naming which case fired. Scope is
# the four variables this loop already names; nothing else in .env is touched.
# A non-empty value that is REJECTED is never destroyed: it is parked in .env
# under a name nothing reads (see env_park_rejected) BEFORE the mint is written.

# HOW THE CURRENT VALUE IS READ (task-0fdde2a930463e93). The CONSUMERS of .env
# are the SHELL: this very script sources it a few hundred lines down
# (`set -a; . ./.env; set +a`) and api/start.sh does `source ../.env` at every
# boot. So the value the app actually holds is whatever the shell ASSIGNS —
# which accepts `VAR="…"`, `VAR='…'`, `export VAR=…`, a leading-whitespace
# line, and strips trailing blanks as token separators. An awk of the raw text
# after '=' sees the QUOTES, the `export`, the indentation and the blanks, and
# calls a WORKING KEK invalid — and the arm below would then REPLACE the key
# every existing ciphertext on that box is sealed under (there is no
# BARKPARK_KEK_PREVIOUS handoff yet). Irreversible data loss on a healthy box.
# So read it the way the consumers do: source .env in a subshell and print the
# expanded value. This is NOT a new trust boundary — the same file is sourced
# by this script and by start.sh anyway; reading it 150 lines earlier changes
# nothing about what can execute.
env_shell_read() { # $1=var; stdout = the value the shell would see, "" when unset
  # The subshell is made immune to this script's `set -u`/pipefail: a .env that
  # expands an unset variable must not abort the read (it does not abort the
  # real `. ./.env` later either, which runs with -u off for the same reason).
  ( set +u +o pipefail; unset "$1"; . ./.env >/dev/null 2>&1 || true; printf '%s' "${!1-}" )
}
env_shell_is_set() { # $1=var; 0 when the shell sees an ASSIGNMENT (even an empty one)
  ( set +u +o pipefail; unset "$1"; . ./.env >/dev/null 2>&1 || true; [ -n "${!1+set}" ] )
}

env_assign_line() { # $1=var; stdout = the LAST raw line that assigns it, "" if none
  awk -v k="$1" '{ l = $0; sub(/^[ \t]+/, "", l); sub(/^export[ \t]+/, "", l)
                   if (index(l, k "=") == 1) last = $0 } END { print last }' .env 2>/dev/null || true
}

# Park a REJECTED but non-empty value before a fresh mint overwrites it. The
# parked name is one NOTHING reads (runtime.exs reads BARKPARK_KEK and
# BARKPARK_KEK_PREVIOUS, never *_REJECTED_*), so the box boots on the mint while
# the operator keeps the bytes needed to recover ciphertext sealed under the old
# key. Single-quoted (with the '\'' escape) so a value with spaces or quotes
# cannot break the sourcing of .env it now rides in.
env_park_rejected() { # $1=var $2=value the shell saw
  local v="$1" val="$2" ts esc raw
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  esc="${val//\'/\'\\\'\'}"
  raw="$(env_assign_line "$v")"
  { printf '# %s was REJECTED by the deploy at %s and a fresh secret minted; original line: %s\n' "$v" "$ts" "$raw"
    printf "%s_REJECTED_%s='%s'\n" "$v" "$ts" "$esc"; } >> .env || return 1
  log "PRESERVED the rejected ${v} in .env as ${v}_REJECTED_${ts} — nothing reads that name; recover any ciphertext sealed under it BEFORE deleting the line"
}

secret_value_ok() { # $1=var $2=current value — 1 ⇒ the deploy must mint a fresh one
  [ -n "$2" ] || return 1
  if [ "$1" = BARKPARK_KEK ]; then
    # api/config/runtime.exs (the `case System.get_env("BARKPARK_KEK")` block)
    # demands Base.decode64/1 yield EXACTLY 32 raw bytes and RAISES otherwise.
    # Base64 of 32 bytes is exactly 43 standard-alphabet characters plus one
    # '=' — so this pattern IS that decode, in the shell, with no openssl
    # round-trip. The shell gate and the app therefore agree on "valid" by
    # construction; anything the app would refuse, this refuses too.
    [[ "$2" =~ ^[A-Za-z0-9+/]{43}=$ ]] || return 1
  fi
  return 0
}

env_replace_line() { # $1=var $2=value — drop every line that ASSIGNS var, append the new one
  local v="$1" val="$2" tmp
  tmp="$(mktemp)" || return 1
  # Written back THROUGH the existing .env (`cat > .env`, never `mv`) so the
  # file's mode 0600 and its ownership survive the repair — a mktemp file mv'd
  # into place would carry the deploy user's, not the box's.
  # The drop matches what the SHELL calls an assignment (optional indentation,
  # optional `export `), not `^VAR=`: an `export VAR=…` line left behind would
  # otherwise survive the replace and, being sourced after nothing, leave TWO
  # assignments in the file whose order decides which key the app boots on.
  { awk -v k="$v" '{ l = $0; sub(/^[ \t]+/, "", l); sub(/^export[ \t]+/, "", l)
                     if (index(l, k "=") != 1) print }' .env > "$tmp" &&
    printf '%s=%s\n' "$v" "$val" >> "$tmp" &&
    cat "$tmp" > .env; } || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
}

for v in BARKPARK_KEK BARKPARK_CLOAK_KEY PREVIEW_JWT_SECRET BARKPARK_RELEASE_CAPTURE_HMAC_SECRET; do
  # "Absent" means the SHELL sees no assignment — not that `grep '^VAR='` misses.
  # The old grep missed `export VAR=…` and indented lines and appended a SECOND
  # assignment; last-wins then booted the box on the fresh mint while the real
  # key sat two lines above.
  if ! env_shell_is_set "$v"; then
    echo "${v}=$(openssl rand -base64 32)" >> .env
    log "added missing ${v} to .env"
    continue
  fi
  cur="$(env_shell_read "$v")"
  # A value the shell and the app both accept is LEFT ALONE — byte for byte. The
  # line is never normalised, re-quoted or rewritten: there is nothing to fix.
  secret_value_ok "$v" "$cur" && continue
  # A value whose ONLY defect is a stray line terminator (a .env edited on
  # Windows: `VAR=<key>\r`) is a REAL key — the bytes before the CR are the
  # secret the box's ciphertext is sealed under. runtime.exs still RAISES on it
  # (Base.decode64 refuses the \r), so it cannot be left untouched either. Drop
  # the terminator, KEEP the key: the only edit is the artifact.
  trimmed="$cur"
  while [ -n "$trimmed" ] && [ "${trimmed: -1}" = $'\r' ]; do trimmed="${trimmed%$'\r'}"; done
  if [ -n "$trimmed" ] && [ "$trimmed" != "$cur" ] && secret_value_ok "$v" "$trimmed"; then
    if env_replace_line "$v" "$trimmed"; then
      log "normalised ${v} in .env — the value carried trailing whitespace/CR (runtime.exs would RAISE); the KEY ITSELF is unchanged, only the stray terminator was dropped"
    else
      log "WARN: ${v} in .env carries a trailing CR and the in-place normalise FAILED — boot will refuse; strip the CR by hand, do NOT re-mint (that destroys the key)"
    fi
    continue
  fi
  if [ -z "$cur" ]; then
    reason="the line is PRESENT but EMPTY"
  else
    reason="the value is not base64 of 32 bytes (runtime.exs would RAISE at boot)"
    # NEVER silently destroy a non-empty secret: park it first, then mint.
    env_park_rejected "$v" "$cur" || log "WARN: could not preserve the rejected ${v} before replacing it"
  fi
  if env_replace_line "$v" "$(openssl rand -base64 32)"; then
    log "repaired ${v} in .env — ${reason}; a fresh secret REPLACED it"
  else
    log "WARN: ${v} in .env is unusable (${reason}) and the in-place repair FAILED — boot will refuse"
  fi
done

# This instance is managed by the barkpark.cloud control plane — the pointer
# puts "Log in with Barkpark Cloud" on /login (login-brand-ux). Not a secret.
if ! grep -q '^BARKPARK_CLOUD_URL=' .env 2>/dev/null; then
  echo 'BARKPARK_CLOUD_URL=https://barkpark.cloud' >> .env
  log "added BARKPARK_CLOUD_URL to .env"
fi

# ---- The x-forwarded-for trust boundary (BARKPARK_TRUSTED_PROXIES) ----------
# Barkpark.RateLimiter.client_ip believes x-forwarded-for ONLY from loopback or a
# peer LISTED here, and walks the chain right-to-left skipping listed hops. On a
# cloud-managed box the chain on a proxied revoke is "<phone>, <control plane
# egress>" — so until the control plane's egress address is listed, the rightmost
# non-listed hop IS that egress address and every proxied revoke keys on ONE
# bucket (the whole team shares 10/minute). Not a forgery and not a 5xx: a SILENT
# loss of the per-phone bucketing.
#
# The address is CONFIGURATION, never a literal in this script: it comes from
# $BARKPARK_CLOUD_EGRESS_IPS, which the CD workflow fills from the SAME `CP_HOST`
# secret it SSHes the control plane with (deploy/README.md), and which the
# provisioner reads from its own worker env for freshly-provisioned boxes. One
# authored value, two readers.
#
# NEVER overwrites an existing line: provisioning already wrote the right value on
# a managed box, and a self-hosted operator may legitimately trust a different
# front. Absent value + absent line ⇒ a commented placeholder + a LOUD log, so the
# gap is visible on the box instead of silently costing per-caller buckets.
#
# The shape is VALIDATED before writing, because runtime.exs RAISES on a malformed
# entry — writing an unvalidated value here would not degrade a bucket key, it
# would refuse to boot the app at the slot restart later in this very run.
#
# PURE BASH, NO awk (task-0d0f4563784fa12f). This used to be an awk regex whose
# IPv4 arm needed the ERE interval `(\.[0-9]+){3}`, so its verdict was the HOST
# AWK's: mawk 1.3.4 20200120 (Ubuntu 22.04, Debian 12), mawk 1.3.4 20240123
# (Ubuntu 24.04) and original-awk 20180827 REFUSED every IPv4 address while
# accepting IPv6 (whose regex has no interval) — the list was never written and
# the refusal looked like a skip. gawk, BSD/one-true-awk 20200816+, busybox and
# mawk 20250131+ accepted. Character classes below are spelled out (no ranges),
# so no locale collation can widen them either.
#
# egress_ip_ok: true only if $1 is a bare IPv4 literal (four dot-separated
# decimal parts, each <= 255) or an IPv6-shaped literal (hex digits and colons
# only, at least one colon, no ':::').
egress_ip_ok() {
  local s="$1" dots o
  case "$s" in
    '' ) return 1 ;;
    *[!0123456789.]*) ;;                           # not v4-shaped: try v6 below
    *)
      case "$s" in .*|*.|*..*) return 1 ;; esac
      dots="${s//[!.]/}"
      [ "${#dots}" = 3 ] || return 1
      local IFS=.
      # shellcheck disable=SC2086  # $s holds only digits and dots (checked above): no glob can fire
      set -- $s
      for o in "$@"; do
        o="${o#"${o%%[!0]*}"}"                     # strip leading zeros (010 -> 10, like awk's +0)
        [ "${#o}" -le 3 ] || return 1
        [ "${o:-0}" -le 255 ] || return 1
      done
      return 0 ;;
  esac
  case "$s" in
    *[!0123456789abcdefABCDEF:]*) return 1 ;;
    *:::*) return 1 ;;
    *:*) return 0 ;;
  esac
  return 1
}
# egress_ips_check: $1=comma-separated candidate. Entries are trimmed of spaces
# and tabs; empty entries are skipped. Three outcomes, three exit codes:
#   0  every entry is a bare IP literal and there is at least one
#   1  refused — the FIRST offending entry is printed on stdout
#   2  empty — the value holds no entries at all (only separators/whitespace)
egress_ips_check() {
  local rest="$1" entry n=0 more
  while :; do
    case "$rest" in
      *,*) entry="${rest%%,*}"; rest="${rest#*,}"; more=1 ;;
      *)   entry="$rest"; more=0 ;;
    esac
    entry="${entry#"${entry%%[!	 ]*}"}"
    entry="${entry%"${entry##*[!	 ]}"}"
    if [ -n "$entry" ]; then
      if ! egress_ip_ok "$entry"; then printf '%s' "$entry"; return 1; fi
      n=$((n + 1))
    fi
    [ "$more" = 1 ] || break
  done
  [ "$n" -gt 0 ] || return 2
  return 0
}
if grep -q '^BARKPARK_TRUSTED_PROXIES=' .env 2>/dev/null; then
  log "BARKPARK_TRUSTED_PROXIES already set in .env — left untouched"
else
  # Three outcomes, three DIFFERENT log lines, so a deploy log tells "nothing was
  # supplied" apart from "the validator refused what was supplied" — the second
  # names the entry it refused.
  egress_rc=2; egress_bad=""
  if [ -n "${BARKPARK_CLOUD_EGRESS_IPS:-}" ]; then
    egress_bad="$(egress_ips_check "${BARKPARK_CLOUD_EGRESS_IPS}")"; egress_rc=$?
  fi
  if [ "$egress_rc" = 0 ]; then
    echo "BARKPARK_TRUSTED_PROXIES=${BARKPARK_CLOUD_EGRESS_IPS}" >> .env
    log "added BARKPARK_TRUSTED_PROXIES=${BARKPARK_CLOUD_EGRESS_IPS} to .env (the control plane's relayed caller address is now believed)"
  elif [ "$egress_rc" = 1 ]; then
    log "WARN: BARKPARK_CLOUD_EGRESS_IPS REFUSED by the validator: entry '${egress_bad}' is not a bare IP address (CIDR ranges are REFUSED — trusting a range lets any host in it forge every client's bucket key) — the whole list '${BARKPARK_CLOUD_EGRESS_IPS}' was NOT written; runtime.exs would raise at boot on it"
  else
    # The placeholder is written ONCE (guarded on its own commented marker) — an
    # unguarded append would grow .env by five lines on every single deploy. The WARN
    # fires either way: the gap must stay visible in every deploy log, not only the
    # first one.
    if ! grep -q '^# BARKPARK_TRUSTED_PROXIES=' .env 2>/dev/null; then
      {
        echo '# BARKPARK_TRUSTED_PROXIES: individual IPs of every front whose x-forwarded-for'
        echo '# this box should believe (comma-separated, NO CIDR ranges). On a barkpark.cloud-'
        echo '# managed instance this is the control plane EGRESS address; unset, proxied'
        echo '# requests all share ONE rate-limit bucket per team instead of one per caller.'
        echo '# BARKPARK_TRUSTED_PROXIES=203.0.113.7'
      } >> .env
    fi
    if [ -n "${BARKPARK_CLOUD_EGRESS_IPS:-}" ]; then
      egress_supplied="BARKPARK_CLOUD_EGRESS_IPS is set but holds no entries ('${BARKPARK_CLOUD_EGRESS_IPS}')"
    else
      egress_supplied="BARKPARK_CLOUD_EGRESS_IPS is unset or empty"
    fi
    log "WARN: no BARKPARK_CLOUD_EGRESS_IPS supplied (${egress_supplied}; nothing was refused) and no BARKPARK_TRUSTED_PROXIES in .env — see the commented placeholder in .env; proxied requests will key on ONE bucket per team until an operator fills it in (deploy/README.md)"
  fi
fi

# The Connectors bridge ciphers each install's per-workspace credentials with
# this key (the KEK — every row is sealed under an HKDF-derived per-workspace
# subkey, never the KEK directly). It is backfilled ONCE into .env and only
# COPIED into /etc/barkpark/connectors.env on each deploy, so it stays STABLE
# across deploys rather than being regenerated under live installs.
#
# KEY CUSTODY — where it lives, how to rotate, what breaks if lost:
#   · BACKED UP: /opt/barkpark/.env (mode 0600), the box's durable secret store,
#     the SAME mechanism as BARKPARK_KEK above. It is NOT escrowed off-box by
#     this script — an operator who wants disaster recovery must copy this line
#     out of .env to a secret manager. Losing the box loses the key.
#   · ROTATE DELIBERATELY (this is safe, NOT a flag day): put the OLD key in
#     CONNECTORS_CREDENTIAL_KEY_PREVIOUS and a fresh one in
#     CONNECTORS_CREDENTIAL_KEY, deploy, then run `npm run rewrap` in
#     /opt/barkpark/connectors (re-seals every row under the new key). Once it
#     reports raced=0 / no unopenable rows, delete the _PREVIOUS line — the old
#     key is now retired. The cipher opens rows under EITHER key in the meantime,
#     so nothing goes dark during the window. See docs/ops/connectors-deploy.md.
#   · IF THE KEY IS LOST with no _PREVIOUS and no backup: stored blobs can no
#     longer be opened, so every install must be RE-CONNECTED (re-paste the
#     provider token). That is the ONLY thing a lost key breaks — routing rows
#     survive; the secrets they point at do not.
if ! grep -q '^CONNECTORS_CREDENTIAL_KEY=' .env 2>/dev/null; then
  echo "CONNECTORS_CREDENTIAL_KEY=$(openssl rand -base64 32)" >> .env
  log "added CONNECTORS_CREDENTIAL_KEY to .env (connectors bridge credential cipher)"
fi

# The CONNECT seam's shared HMAC secret (connectors D50). BOTH sides read it:
# the BEAM (Barkpark.Connectors, via runtime.exs) signs a connect ticket, and the
# bridge verifies it — same value, same box, loopback only. Backfilled ONCE (a
# regenerated secret would 401 every connect until both processes restart) and
# COPIED into /etc/barkpark/connectors.env below.
#
# ABSENT is a supported state, not an error: no secret ⇒ the bridge does not
# mount its connect routes and Studio's Connectors catalog renders read-only with
# a banner. That is what removes the merge-order hazard between the bridge slice
# and this step.
if ! grep -q '^CONNECTORS_CONNECT_SECRET=' .env 2>/dev/null; then
  echo "CONNECTORS_CONNECT_SECRET=$(openssl rand -base64 32)" >> .env
  log "added CONNECTORS_CONNECT_SECRET to .env (Studio -> bridge connect tickets)"
fi
set -a; . ./.env; set +a

# ---- Arm the Caddy maintenance page (branded 503 + Retry-After) so ANY window
# where the app is unreachable — a crash/restart outside deploys; blue/green
# deploys themselves don't drop the upstream — shows "back in a moment", not a
# raw 502. Idempotent, backed up, `caddy validate`d, auto-reverting; NEVER fails
# the deploy. Reconciled with the blue/green machinery: the injected block
# contains no slot-port token, so the ACTIVE_PORT grep below still hits
# the site upstream first and the port-flip sed passes over it untouched. The
# renderers in internal/caddyfile + internal/cli/setup bake the same block into
# every provisioned instance; this arms an already-running box on deploy.
# Reference copy: deploy/caddy/barkpark-maintenance.caddy.
arm_caddy_maintenance() {
  command -v caddy >/dev/null 2>&1 || { log "caddy not installed — skipping maintenance page"; return 0; }
  [ -f "$CADDYFILE" ] || { log "no $CADDYFILE — skipping maintenance page"; return 0; }
  if grep -q 'BARKPARK_MAINTENANCE' "$CADDYFILE"; then
    # ALREADY ARMED — but possibly in the PRE-SCOPING shape. A bare
    # `handle_errors {` catches EVERY error the site raises, and a `file_server`
    # miss inside an armed `handle_path /sites/<slug>/*` raises 404 as an ERROR.
    # Measured on guerrilla: every miss on a spawned static site answered 503
    # "Back in a moment" instead of 404 — the maintenance page swallowed the
    # whole 4xx surface of every static site on the box. The block's own header
    # comment asserted the opposite ("fires ONLY on errors Caddy itself raises
    # (dial failure / gateway timeout)"); a file_server 404 IS such an error.
    # Re-arming is not an option (the marker guard exists for a reason), so
    # UPGRADE in place: scope the existing handler to the gateway statuses it was
    # always meant to cover. Same backup + validate + revert contract as the arm.
    if grep -qE '^[[:space:]]*handle_errors[[:space:]]*\{[[:space:]]*$' "$CADDYFILE"; then
      local ubak; ubak="${CADDYFILE}.bak.maint-scope.$(date -u +%Y%m%d%H%M%S)"
      cp -a "$CADDYFILE" "$ubak"
      local utmp; utmp="$(mktemp)"
      sed -E 's/^([[:space:]]*)handle_errors[[:space:]]*\{[[:space:]]*$/\1handle_errors 502 503 504 {/' "$CADDYFILE" > "$utmp" \
        && mv "$utmp" "$CADDYFILE" || { rm -f "$utmp"; mv "$ubak" "$CADDYFILE"; log "could not rewrite $CADDYFILE to scope the maintenance handler — Caddy untouched"; return 0; }
      chmod --reference="$ubak" "$CADDYFILE" 2>/dev/null || chmod 644 "$CADDYFILE"
      chown --reference="$ubak" "$CADDYFILE" 2>/dev/null || true
      if caddy validate --adapter caddyfile --config "$CADDYFILE" >/dev/null 2>&1; then
        rm -f "$ubak"
        systemctl reload caddy 2>/dev/null || true
        log "scoped the already-armed maintenance handler to 502/503/504 (a static-site miss now 404s instead of 503)"
      else
        mv "$ubak" "$CADDYFILE"
        log "caddy validate rejected the maintenance-handler scoping — reverted, Caddy untouched"
      fi
    fi
    # ALREADY ARMED, SECOND DEFECT — the block emits an HTML document but sets
    # no Content-Type, and Caddy's `respond` then defaults the response to
    # `text/plain; charset=utf-8`. MEASURED against real Caddy 2.11.4: during a
    # backend gap the branded "Back in a moment" page is delivered as PLAIN
    # TEXT, so a browser paints the raw `<!doctype html>…` source — markup,
    # inline <style> and all — instead of the page. The STATUS was always
    # honest (503 + Retry-After, on every path incl. /assets/*.css); it is the
    # RENDERING that was broken. Upgrade in place on the same
    # backup/validate/auto-revert contract as the scoping upgrade above, so
    # boxes armed before this change are fixed on their next deploy rather than
    # waiting for a re-arm that the marker guard will never allow.
    if ! grep -qE '^[[:space:]]*header[[:space:]]+Content-Type[[:space:]]+"text/html' "$CADDYFILE"; then
      local cbak; cbak="${CADDYFILE}.bak.maint-ctype.$(date -u +%Y%m%d%H%M%S)"
      cp -a "$CADDYFILE" "$cbak"
      local ctmp; ctmp="$(mktemp)"
      # Anchored on the maintenance handler's OWN Retry-After line. `header
      # Retry-After "15"` appears nowhere else in any config this script arms.
      sed -E 's|^([[:space:]]*)header[[:space:]]+Retry-After[[:space:]]+"15"[[:space:]]*$|\1header Retry-After "15"\n\1header Content-Type "text/html; charset=utf-8"|' "$CADDYFILE" > "$ctmp" \
        && mv "$ctmp" "$CADDYFILE" || { rm -f "$ctmp"; mv "$cbak" "$CADDYFILE"; log "could not rewrite $CADDYFILE to set the maintenance Content-Type — Caddy untouched"; return 0; }
      chmod --reference="$cbak" "$CADDYFILE" 2>/dev/null || chmod 644 "$CADDYFILE"
      chown --reference="$cbak" "$CADDYFILE" 2>/dev/null || true
      if caddy validate --adapter caddyfile --config "$CADDYFILE" >/dev/null 2>&1; then
        rm -f "$cbak"
        systemctl reload caddy 2>/dev/null || true
        log "set Content-Type: text/html on the already-armed maintenance handler (the 503 page rendered as plain text)"
      else
        mv "$cbak" "$CADDYFILE"
        log "caddy validate rejected the maintenance Content-Type upgrade — reverted, Caddy untouched"
      fi
      return 0
    fi
    log "caddy maintenance page already armed"; return 0
  fi
  # Slot ports ONLY: the /mcp route (if armed first) carries its own
  # `reverse_proxy localhost:4010` line, which must never become the
  # insertion anchor.
  if ! grep -qE "reverse_proxy[[:space:]]+localhost:(${BLUE_PORT}|${GREEN_PORT})([[:space:]]|\$)" "$CADDYFILE"; then
    log "no slot 'reverse_proxy localhost:...' site in $CADDYFILE — leaving Caddy untouched (arm manually: deploy/caddy/barkpark-maintenance.caddy)"
    return 0
  fi
  local block; block="$(cat <<'MAINT'
	handle_errors 502 503 504 {
		header Retry-After "15"
		header Content-Type "text/html; charset=utf-8"
		respond 503 {
			body <<BARKPARK_MAINTENANCE
<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Back in a moment</title>
<style>body{font-family:system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;background:#0f1115;color:#e7e9ee;display:grid;place-items:center;min-height:100vh;margin:0}.card{max-width:32rem;padding:2.5rem;text-align:center}h1{font-size:1.5rem;margin:0 0 .5rem}p{opacity:.7;line-height:1.5}.spinner{width:2rem;height:2rem;border:3px solid #2a2f3a;border-top-color:#6ea8fe;border-radius:50%;margin:0 auto 1.5rem;animation:spin 1s linear infinite}@keyframes spin{to{transform:rotate(360deg)}}</style>
</head><body><div class="card"><div class="spinner"></div><h1>Back in a moment</h1>
<p>Barkpark is deploying an update and will be right back. This page refreshes automatically.</p></div>
<script>setTimeout(function(){location.reload()},15000)</script></body></html>
BARKPARK_MAINTENANCE
			close
		}
	}
MAINT
)"
  local bak; bak="${CADDYFILE}.bak.$(date -u +%Y%m%d%H%M%S)"
  cp -a "$CADDYFILE" "$bak"
  local tmp; tmp="$(mktemp)"
  # Insert the block right after the FIRST slot `reverse_proxy localhost:<port>`
  # line (whichever slot port is live), so it lands inside that site block.
  # Slot ports only — never the /mcp route's :4010 line.
  BP_BLOCK="$block" BP_SLOT_RE="reverse_proxy[[:blank:]]+localhost:(${BLUE_PORT}|${GREEN_PORT})([[:blank:]]|\$)" awk '
    BEGIN { blk=ENVIRON["BP_BLOCK"]; re=ENVIRON["BP_SLOT_RE"] }
    { print }
    !ins && $0 ~ re { print blk; ins=1 }
  ' "$CADDYFILE" > "$tmp" && mv "$tmp" "$CADDYFILE"
  # mktemp files are 0600 and mv preserves that — the caddy user must still be
  # able to read its own config or `systemctl reload caddy` fails with
  # "permission denied" (bit the first live blue/green flip on guerrilla).
  chmod --reference="$bak" "$CADDYFILE" 2>/dev/null || chmod 644 "$CADDYFILE"
  chown --reference="$bak" "$CADDYFILE" 2>/dev/null || true
  if caddy validate --adapter caddyfile --config "$CADDYFILE" >/dev/null 2>&1; then
    if systemctl reload caddy 2>/dev/null; then log "armed Caddy maintenance page"; else log "caddy reload failed (config valid) — armed on next reload"; fi
    rm -f "$bak"
  else
    log "caddy validate rejected the injected block — reverting, Caddy untouched"
    mv "$bak" "$CADDYFILE"
  fi
}
with_caddy_lock arm_caddy_maintenance

# ---- Arm the /mcp Caddy route for the remote MCP endpoint (viable-everywhere
# charter D19): path-based on the EXISTING public site — never a new subdomain —
# proxying to 127.0.0.1:$MCP_PORT where barkpark-mcp.service listens
# (`bp mcp serve --http`, guarded install below). :4010 sits OUTSIDE the
# blue/green slot ports {4000,4001} ON PURPOSE: the ACTIVE_PORT greps and the
# port-flip sed match slot ports exactly, so they pass over this route
# untouched. Same contract as the maintenance arming: idempotent (marker),
# backed up, `caddy validate`d, auto-reverting, NEVER fails the deploy. Until
# the unit is enabled, /mcp requests hit a dead upstream and land on the
# maintenance 503 — never a raw 502.
arm_caddy_mcp_route() {
  command -v caddy >/dev/null 2>&1 || { log "caddy not installed — skipping /mcp route"; return 0; }
  [ -f "$CADDYFILE" ] || { log "no $CADDYFILE — skipping /mcp route"; return 0; }
  if grep -q 'BARKPARK_MCP_ROUTE' "$CADDYFILE"; then log "caddy /mcp route already armed"; return 0; fi
  if [ "$MCP_PORT" = "$BLUE_PORT" ] || [ "$MCP_PORT" = "$GREEN_PORT" ]; then
    log "refusing /mcp route on a blue/green slot port (:$MCP_PORT) — the port-flip sed would rewrite it"
    return 0
  fi
  if ! grep -qE "reverse_proxy[[:space:]]+localhost:(${BLUE_PORT}|${GREEN_PORT})([[:space:]]|\$)" "$CADDYFILE"; then
    log "no slot 'reverse_proxy localhost:...' site in $CADDYFILE — leaving Caddy untouched (/mcp route not armed)"
    return 0
  fi
  local block; block="$(cat <<MCPROUTE
	# BARKPARK_MCP_ROUTE — remote MCP endpoint (barkpark-mcp.service,
	# bp mcp serve --http). Matcher covers the bare /mcp AND /mcp/* —
	# Streamable-HTTP clients POST the bare path.
	@barkpark_mcp path /mcp /mcp/*
	handle @barkpark_mcp {
		reverse_proxy localhost:${MCP_PORT}
	}
MCPROUTE
)"
  local bak; bak="${CADDYFILE}.bak.mcp.$(date -u +%Y%m%d%H%M%S)"
  cp -a "$CADDYFILE" "$bak"
  local tmp; tmp="$(mktemp)"
  # Insert the block right BEFORE the first slot `reverse_proxy localhost:<port>`
  # line, so the handle sits inside that site block ahead of the bare fallback
  # proxy (requests matching /mcp terminate in the handle; everything else
  # falls through to the site upstream). Slot ports only — a re-run must never
  # anchor on this block's own :4010 line (the marker guard above already
  # prevents that; the tight regex is belt-and-braces).
  BP_BLOCK="$block" BP_SLOT_RE="reverse_proxy[[:blank:]]+localhost:(${BLUE_PORT}|${GREEN_PORT})([[:blank:]]|\$)" awk '
    BEGIN { blk=ENVIRON["BP_BLOCK"]; re=ENVIRON["BP_SLOT_RE"] }
    !ins && $0 ~ re { print blk; ins=1 }
    { print }
  ' "$CADDYFILE" > "$tmp" && mv "$tmp" "$CADDYFILE"
  # mktemp files are 0600 and mv preserves that — keep the file readable for
  # the caddy user (same lesson as the maintenance arming).
  chmod --reference="$bak" "$CADDYFILE" 2>/dev/null || chmod 644 "$CADDYFILE"
  chown --reference="$bak" "$CADDYFILE" 2>/dev/null || true
  if caddy validate --adapter caddyfile --config "$CADDYFILE" >/dev/null 2>&1; then
    if systemctl reload caddy 2>/dev/null; then log "armed caddy /mcp route -> localhost:$MCP_PORT"; else log "caddy reload failed (config valid) — /mcp route live on next reload"; fi
    rm -f "$bak"
  else
    log "caddy validate rejected the /mcp route — reverting, Caddy untouched"
    mv "$bak" "$CADDYFILE"
  fi
}
with_caddy_lock arm_caddy_mcp_route

# ---- Arm the /connectors Caddy route for the Connectors bridge (connectors
# charter D34/D46): path-based on the EXISTING public site — never a new
# subdomain (barkpark.cloud has NO wildcard DNS; a subdomain would re-arm the
# separate Hetzner DNS-token human gate for nothing) — proxying to
# 127.0.0.1:$CONNECTORS_PORT where barkpark-connectors.service listens (guarded
# install below). :4020, like the MCP route's :4010, sits OUTSIDE the blue/green
# slot ports {4000,4001} ON PURPOSE: the ACTIVE_PORT greps and the port-flip sed
# match slot ports exactly, so they pass over this route untouched. Same contract
# as the maintenance + /mcp arming: idempotent (marker), backed up, `caddy
# validate`d, auto-reverting, NEVER fails the deploy. Until the unit is up,
# /connectors requests hit a dead upstream and land on the maintenance 503 —
# never a raw 502. THAT is the ordering hazard docs/ops/connectors-deploy.md
# names: bring the unit UP before registering a provider webhook URL, because a
# provider disables a webhook after repeated non-2xx.
arm_caddy_connectors_route() {
  command -v caddy >/dev/null 2>&1 || { log "caddy not installed — skipping $CONNECTORS_PATH_PREFIX route"; return 0; }
  [ -f "$CADDYFILE" ] || { log "no $CADDYFILE — skipping $CONNECTORS_PATH_PREFIX route"; return 0; }
  if grep -q 'BARKPARK_CONNECTORS_ROUTE' "$CADDYFILE"; then log "caddy $CONNECTORS_PATH_PREFIX route already armed"; return 0; fi
  if [ "$CONNECTORS_PORT" = "$BLUE_PORT" ] || [ "$CONNECTORS_PORT" = "$GREEN_PORT" ]; then
    log "refusing $CONNECTORS_PATH_PREFIX route on a blue/green slot port (:$CONNECTORS_PORT) — the port-flip sed would rewrite it"
    return 0
  fi
  if [ "$CONNECTORS_PORT" = "$MCP_PORT" ]; then
    log "refusing $CONNECTORS_PATH_PREFIX route on the MCP port (:$CONNECTORS_PORT) — two units cannot bind one port"
    return 0
  fi
  if ! grep -qE "reverse_proxy[[:space:]]+localhost:(${BLUE_PORT}|${GREEN_PORT})([[:space:]]|\$)" "$CADDYFILE"; then
    log "no slot 'reverse_proxy localhost:...' site in $CADDYFILE — leaving Caddy untouched ($CONNECTORS_PATH_PREFIX route not armed)"
    return 0
  fi
  local block; block="$(cat <<CONNROUTE
	# BARKPARK_CONNECTORS_ROUTE — the Connectors bridge
	# (barkpark-connectors.service). Matcher covers the bare prefix AND its
	# subtree — provider webhooks POST ${CONNECTORS_PATH_PREFIX}/<provider>.
	@barkpark_connectors path ${CONNECTORS_PATH_PREFIX} ${CONNECTORS_PATH_PREFIX}/*
	handle @barkpark_connectors {
		reverse_proxy localhost:${CONNECTORS_PORT}
	}
CONNROUTE
)"
  local bak; bak="${CADDYFILE}.bak.connectors.$(date -u +%Y%m%d%H%M%S)"
  cp -a "$CADDYFILE" "$bak"
  local tmp; tmp="$(mktemp)"
  # Insert right BEFORE the first slot `reverse_proxy localhost:<port>` line, so
  # the handle sits inside that site block ahead of the bare fallback proxy.
  # SLOT PORTS ONLY: the anchor regex must never match the /mcp block's own
  # `localhost:4010` line (nor this block's :4020 on a re-run) — that trap is
  # documented on arm_caddy_mcp_route. The marker guard above is the first line
  # of defence; the tight regex is belt-and-braces.
  BP_BLOCK="$block" BP_SLOT_RE="reverse_proxy[[:blank:]]+localhost:(${BLUE_PORT}|${GREEN_PORT})([[:blank:]]|\$)" awk '
    BEGIN { blk=ENVIRON["BP_BLOCK"]; re=ENVIRON["BP_SLOT_RE"] }
    !ins && $0 ~ re { print blk; ins=1 }
    { print }
  ' "$CADDYFILE" > "$tmp" && mv "$tmp" "$CADDYFILE"
  # mktemp files are 0600 and mv preserves that — keep the file readable for the
  # caddy user (same lesson as the maintenance + /mcp arming).
  chmod --reference="$bak" "$CADDYFILE" 2>/dev/null || chmod 644 "$CADDYFILE"
  chown --reference="$bak" "$CADDYFILE" 2>/dev/null || true
  if caddy validate --adapter caddyfile --config "$CADDYFILE" >/dev/null 2>&1; then
    if systemctl reload caddy 2>/dev/null; then log "armed caddy $CONNECTORS_PATH_PREFIX route -> localhost:$CONNECTORS_PORT"; else log "caddy reload failed (config valid) — $CONNECTORS_PATH_PREFIX route live on next reload"; fi
    rm -f "$bak"
  else
    log "caddy validate rejected the $CONNECTORS_PATH_PREFIX route — reverting, Caddy untouched"
    mv "$bak" "$CADDYFILE"
  fi
}
with_caddy_lock arm_caddy_connectors_route

# ---- Which slot serves now? Caddy's upstream port is the source of truth
# (on the pre-blue/green layout it reads 4000, which maps to legacy-as-blue).
# Slot ports ONLY (never 40[0-9]{2}): the /mcp and /connectors routes above put
# localhost:4010 / localhost:4020 lines in the Caddyfile ahead of the site
# upstream — a loose grep + head -1 would misread one as the active slot and the
# flip sed would then destroy the route.
ACTIVE_PORT="$(grep -oE "localhost:(${BLUE_PORT}|${GREEN_PORT})" "$CADDYFILE" | head -1 | cut -d: -f2)"
ACTIVE_PORT="${ACTIVE_PORT:-$BLUE_PORT}"
if [ "$ACTIVE_PORT" = "$BLUE_PORT" ]; then
  TARGET=green; TARGET_PORT="$GREEN_PORT"; OTHER=blue
else
  TARGET=blue; TARGET_PORT="$BLUE_PORT"; OTHER=green
fi
log "active upstream :$ACTIVE_PORT -> deploying slot '$TARGET' on :$TARGET_PORT"

# ---- Install/refresh the slot units + per-slot env (idempotent). The env files
# are truncate-regenerated every deploy, so any operator-set
# BARKPARK_SITE_DEPLOY_APPLY=1 — the site-deploy seam-enable flag, read at BEAM
# boot from .slots/%i.env via the unit's EnvironmentFile — must be CARRIED
# FORWARD or a redeploy silently drops it and the site-deploy admin route
# reverts to 503, re-breaking the finish line (D38). Mirror the backfill
# discipline used for the $APP/.env durable flags above: preserve what the prior
# file held, never hardcode the flag on (absent stays absent — fail-closed).
install -m 0644 "$APP/deploy/systemd/barkpark-slot@.service" /etc/systemd/system/barkpark-slot@.service
# The node-slot SSR template unit (site-spawner W7): site-deploy-node.sh drives
# `systemctl start barkpark-site@<slug>__<slot>` for container-framework (kind=node)
# sites, but that unit template must be INSTALLED on the box first — without it a
# node deploy dies at HEALTH ("the node process would not boot"). Install it here
# alongside barkpark-slot@ so every box that can deploy can serve a node site.
[ -f "$APP/deploy/systemd/barkpark-site@.service" ] && \
  install -m 0644 "$APP/deploy/systemd/barkpark-site@.service" /etc/systemd/system/barkpark-site@.service
mkdir -p "$APP/.slots"
# Indx durable state lives OUTSIDE the build roots (task-527b519e47669559):
# priv/indx_state is a per-version copy under a release and a source-tree
# symlink under mix, so a version bump or a slot flip abandons every key_map.
# config/runtime.exs points Barkpark.Plugins.Indx.Persistence here when
# BARKPARK_INDX_STATE_DIR is set in .env or, in :prod, when this PARENT exists —
# so creating it is what turns the persistent default on. Owner = the slot
# unit's User (root; deploy/systemd/barkpark-slot@.service). Idempotent.
install -d -m 0750 -o root -g root "${BARKPARK_INDX_STATE_DIR:-/var/lib/barkpark/indx-state}"
write_slot_env() { # $1=slot  $2=port  $3=build_root
  local f="$APP/.slots/$1.env" apply=""
  [ -f "$f" ] && apply="$(grep -E '^BARKPARK_SITE_DEPLOY_APPLY=' "$f" 2>/dev/null | tail -1)"
  {
    printf 'BARKPARK_PORT_OVERRIDE=%s\nMIX_BUILD_ROOT=%s\n' "$2" "$3"
    [ -n "$apply" ] && printf '%s\n' "$apply"
  } > "$f"
}
write_slot_env blue  "$BLUE_PORT"  "$APP/api/_build_blue"
write_slot_env green "$GREEN_PORT" "$APP/api/_build_green"
# Consent stays the box owner's (see the D593 block at the top of this script).
# What a deploy owes a box that HAS consented is a check that it can still
# HONOUR that consent — a prerequisite silently rots the moment an image is
# rebuilt without util-linux or python3. ADVISORY: a CONTENT deploy never dies
# because a SITE prerequisite is missing. A box with no consent recorded gets one
# line and no checks — there is nothing yet to be able to honour.
if site_deploy_consent; then
  log "site deploys: consent RECORDED on this box — checking the four per-box prerequisites"
  prereq_out="$(site_deploy_prereqs)"; prereq_rc=$?
  while IFS= read -r prereq_line; do
    [ -n "$prereq_line" ] && log "site-deploy prereq: $prereq_line"
  done <<PREREQ
$prereq_out
PREREQ
  if [ "$prereq_rc" != 0 ]; then
    log "WARN: this box has CONSENTED to site deploys but a prerequisite is unmet (typed exit $prereq_rc) — its next site deploy will fail; re-run 'deploy/instance-deploy.sh --site-deploy-preflight' after fixing"
  fi
else
  log "site deploys: consent ABSENT — this box has not opted in to running third-party site build code, so the site-deploy door stays fail-closed (D38/D593); 'deploy/instance-deploy.sh --site-deploy-preflight' reports what it would need"
fi
# Per-slot version stamp (W6 D12): record what THIS deploy puts into the target
# slot, so --rollback knows what the idle slot holds after the next flip. STATE
# is one global sha and the env files carry only port+build-root — without the
# stamp a box has slot amnesia and rollback would flip to an unknown build.
#
# ORDERING (D291): the stamp is DEFINED here but WRITTEN only after the health
# gate. It used to be written right here — before deps.get/deps.compile/compile/
# ecto.migrate — and no exit-12/13 path reverted it, so a deploy that never
# built left `.slots/<slot>.sha` claiming a build the slot does not hold, and
# `--rollback` reads exactly that file (see the preflight above) to pick its
# target. Same discipline as $STATE, which is written only after health + flip.
SLOT_SHA_FILE="$APP/.slots/$TARGET.sha"
PREV_SLOT_SHA="$(cat "$SLOT_SHA_FILE" 2>/dev/null || true)"
stamp_slot_sha() { echo "$NEW" > "$SLOT_SHA_FILE"; }
restore_slot_sha() { # any post-stamp failure path: the slot is being retired
  if [ -n "$PREV_SLOT_SHA" ]; then printf '%s\n' "$PREV_SLOT_SHA" > "$SLOT_SHA_FILE"
  else rm -f "$SLOT_SHA_FILE"; fi
}
systemctl daemon-reload

# ---- DECISION (task-f94dc334001ec8d0, 2026-09-16): a SLOT box COMPILES ON-BOX.
# It does NOT consume the prebuilt api/_build artifact that
# .github/workflows/release-artifact.yml mints per api-touching merge. That
# artifact's only consumer is scripts/fetch-prebuilt.sh (via
# scripts/apply-update.sh) on SINGLE-CHECKOUT boxes; fetch-prebuilt.sh exits 3
# on a checkout with a .slots dir, and nothing here fetches it. pds wave-49 left
# that asymmetry undecided. It is decided now: DECLINED, on three measured
# grounds, none of which is "it would be hard".
#
# 1. THE ARTIFACT IS NOT ORDERED BEFORE THIS SCRIPT. release-artifact.yml and
#    deploy.yml both fire on the same push and run CONCURRENTLY; neither waits
#    for the other. Measured over the 22 main-branch pushes (2026-09-13..15)
#    that produced BOTH a successful release-artifact run and a successful
#    deploy run for the same sha, the artifact was published AFTER the
#    "Deploy content instance over SSH" step had already STARTED in 14 of 22;
#    in the remaining 8 the artifact led by at most 158s, which is inside the
#    window this script spends on git/env/caddy before it reaches `mix`. So the
#    fetch would take its fallback path on essentially every deploy — a new
#    network dependency on the zero-downtime critical path, bought for a saving
#    that is usually not there. Making it reliable means BLOCKING the deploy on
#    a CI job, which trades guaranteed latency for occasional latency.
#
# 2. THE ARTIFACT BUNDLES `deps`, WHICH IS NOT PER-SLOT. build-prebuilt.sh tars
#    `_build/prod` AND `deps`, and `api/_build_<slot>/prod/lib/<dep>/priv` is a
#    relative symlink four levels up into the SHARED `api/deps/<dep>/priv` (28
#    such symlinks in a prod build tree). Applying the artifact whole therefore
#    writes state the ACTIVE slot is serving through — the one invariant this
#    whole script exists to hold ("only the idle root is touched"). Extracting
#    `_build/prod` alone dodges that, but then deps.get/deps.compile must still
#    run on-box, which is the expensive half of the build anyway.
#
# 3. THE SHA IS CHOSEN BY THE BOX, NOT BY THE RUN. Both channels land on
#    `reset --hard FETCH_HEAD` — production takes whatever origin/main is at
#    fetch time (deliberately: burst merges coalesce, see deploy/README.md), and
#    the staging channel deploys ANY ref, including `pull/<n>/head`, for which
#    release-artifact.yml (`on: push: branches: [main]`) never mints anything.
#    A per-sha artifact cache cannot serve a deployer that picks its own sha.
#
# REVISIT IF any one of these stops being true: release-artifact.yml becomes a
# `needs:` of the instance-deploy job (fixes 1 and 3), or build-prebuilt.sh
# starts publishing a deps-free, build-root-relocatable `_build/prod` (fixes 2).
# Until then the prebuilt lane stays single-checkout-only and the mint is NOT
# wasted — the control-plane/freshen path does consume it.
#
# GUARDED, not merely written: deploy/instance-deploy_test.sh, Case "the slot
# deployer COMPILES ON-BOX and fetches no prebuilt artifact" — a happy deploy's
# recorded curl argv carries no `releases/download` / `api-build.tar.zst` /
# `stamp.json` (with a non-empty-log control so the absence is not vacuous), and
# the upstream refusal is exercised both ways (a .slots fixture exits 3, the
# same script without .slots does not). Add a fetch here and those arms red.
#
# ---- Clean-build the idle slot's root while the active slot keeps serving
# its own untouched root. A build failure = zero downtime. The golden rules
# still hold: from-scratch build (fresh HEEx), deps.compile --force.
cd "$APP/api" || { log "no $APP/api"; exit 10; }
# BUILD ASIDE, SWAP ON SUCCESS (pds-bl-failed-build-wipes-rollback-root). This
# used to `rm -rf _build_$TARGET` and compile straight into it, which destroyed
# the idle slot's PREVIOUS good build root before knowing whether a replacement
# would ever exist. `--rollback-preflight` reads exactly that directory (the
# `no complete build root` refusal above), so any exit-12/13 failure took the
# rollback option away at the one moment the owner needs it — a typed,
# fail-closed refusal, but an availability loss all the same. The wipe is what
# had to move: the previous root is now untouched until a COMPLETE build exists
# to replace it. Costs one build root of disk transiently; a build root is the
# cheap half of a box.
NEW_ROOT="_build_$TARGET.new"
PREV_ROOT="_build_$TARGET.prev"
build() { MIX_ENV=prod MIX_BUILD_ROOT="$NEW_ROOT" mix "$@"; }
log "clean build into $NEW_ROOT (deps.get; deps.compile --force; compile) — _build_$TARGET stays intact until the swap"
# A run killed mid-build (or mid-swap) leaves these behind; a stale .new would
# make the next build incremental against foreign artifacts, and a stale .prev
# would pin disk forever. Both are scratch by construction — never a rollback
# target, which only ever reads _build_$TARGET.
rm -rf "$NEW_ROOT" "$PREV_ROOT"
if ! build deps.get;             then log "deps.get failed (_build_$TARGET kept — rollback still possible)";     git -C "$APP" reset --hard "$OLD"; exit 12; fi
if ! build deps.compile --force; then log "deps.compile failed (_build_$TARGET kept — rollback still possible)"; git -C "$APP" reset --hard "$OLD"; exit 12; fi
if ! build compile;              then log "compile failed (_build_$TARGET kept — rollback still possible)";      git -C "$APP" reset --hard "$OLD"; exit 12; fi
if [ ! -d "$NEW_ROOT/prod" ]; then log "build produced no $NEW_ROOT/prod — abort, live slot untouched, _build_$TARGET kept"; git -C "$APP" reset --hard "$OLD"; exit 12; fi
log "migrate (new code, active slot still serving)"
# BARKPARK_DB_STATEMENT_TIMEOUT=0 — `mix ecto.migrate` boots the repo with the
# runtime config, so every migration connection would otherwise inherit the
# per-statement wall config/runtime.exs sets for request traffic (30 s, #15005;
# 60 s on the role). A backfill or a CREATE INDEX CONCURRENTLY on a big table
# is an operator-supervised, offline-shaped step and must be allowed to run to
# completion; the per-migration guard in Barkpark.Release is the seatbelt, this
# is the belt-and-braces (lead-cli-2's handoff, task-e2f5ecca0be9a6d1).
if ! BARKPARK_DB_STATEMENT_TIMEOUT=0 build ecto.migrate; then log "migrate failed (_build_$TARGET kept — rollback still possible)"; rm -rf "$NEW_ROOT"; git -C "$APP" reset --hard "$OLD"; exit 13; fi

# ---- Swap the completed build in. This is the LAST point at which the previous
# root can be preserved: barkpark-slot@$TARGET boots with
# MIX_BUILD_ROOT=$APP/api/_build_$TARGET baked into .slots/$TARGET.env (see
# write_slot_env above), so the new build must live at that exact path before
# the slot is started and health-gated — "swap on health" is not reachable
# without repointing the unit's env, and the health gate has the slot-sha stamp
# (D291) as its guard already. Two renames on one filesystem: the window in
# which _build_$TARGET does not exist is a single mv.
rm -rf "$PREV_ROOT"
if [ -d "_build_$TARGET" ] && ! mv "_build_$TARGET" "$PREV_ROOT"; then
  log "could not move the old _build_$TARGET aside — abort before touching it, live slot untouched"
  rm -rf "$NEW_ROOT"; git -C "$APP" reset --hard "$OLD"; exit 12
fi
if ! mv "$NEW_ROOT" "_build_$TARGET"; then
  log "could not swap $NEW_ROOT into place — restoring the previous root, live slot untouched"
  [ -d "$PREV_ROOT" ] && mv "$PREV_ROOT" "_build_$TARGET"
  git -C "$APP" reset --hard "$OLD"; exit 12
fi
rm -rf "$PREV_ROOT"
log "swapped the fresh build into _build_$TARGET"

# ---- Boot the idle slot and gate on it. The active slot is never touched;
# every failure path from here on is zero-downtime.
cd "$APP" || { log "no $APP"; exit 10; }

# ---- pdrender→TUI wasm the reader lazy-loads (api/priv/static/assets/
# bp-pdrender.wasm.gz, served by Plug.Static). This build path is SEPARATE from
# scripts/deploy-rebuild.sh (which builds the wasm and REFUSES slot boxes), so
# the slot deployer must build it itself. BEFORE the slot boots + health-gates +
# Caddy swaps, so the new slot serves the freshly-built blob — never a blob-less
# cutover. #1361 dropped the committed blob, so build-at-deploy is what keeps the
# reader whole. priv/static is shared source symlinked into both slots, so one
# build serves whichever slot is live. Non-fatal (mirrors deploy-rebuild): a
# failed build only degrades the reader's TUI view to its fallback, never aborts
# a zero-downtime deploy. `make wasm` runs from the repo root ($APP) and pins its
# own Go toolchain via GOTOOLCHAIN.
log "building pdrender wasm (non-fatal)"
if command -v go >/dev/null 2>&1; then
  if make wasm; then log "pdrender wasm built"; else log "WARN: pdrender wasm build failed — reader TUI view degrades to its fallback"; fi
else
  log "go not found — skipping pdrender wasm build"
fi

log "boot barkpark-slot@$TARGET on :$TARGET_PORT"
systemctl restart "barkpark-slot@$TARGET"

ok=0
for _ in $(seq 1 40); do
  code="$(bp_curl_code -s -o /dev/null --max-time 5 "http://localhost:${TARGET_PORT}${HEALTH_PATH}" || echo 000)"
  if [ "$code" = "200" ]; then ok=1; log "slot $TARGET healthy ($code)"; break; fi
  sleep 5
done
if [ "$ok" != "1" ]; then
  log "slot $TARGET UNHEALTHY — stopping it; :$ACTIVE_PORT was never touched (no downtime)"
  systemctl disable --now "barkpark-slot@$TARGET" 2>/dev/null || true
  git reset --hard "$OLD"   # keep sources in step with the still-serving old build
  exit 14
fi
# The slot booted and answered — only NOW may it claim this sha as a rollback
# target (D291). Every earlier failure (exit 12/13) leaves the previous stamp,
# and the flip failures below restore it.
stamp_slot_sha

# ---- Hot swap: point Caddy at the new slot (graceful reload, no drops).
# UNDER THE SHARED CADDYFILE LOCK (fd 8, D27): site-deploy.sh rewrites this same
# file, and a concurrent arm-vs-flip interleave DISCARDS this flip while Caddy is
# reloaded onto the slot we retire below (a reproduced hard 502 — and `caddy
# validate` passes in BOTH processes, because a lost update is valid config).
# Bracketed inline, not wrapped in a function: every failure path below EXITS,
# and an exit releases fd 8 with the process.
exec 8>"$CADDY_LOCK"
if ! flock -w 120 8; then
  log "gave up waiting for the Caddyfile lock ($CADDY_LOCK) — no swap; slot $TARGET stopped, :$ACTIVE_PORT still serving (no downtime)"
  systemctl disable --now "barkpark-slot@$TARGET" 2>/dev/null || true
  restore_slot_sha
  git reset --hard "$OLD"; exit 14
fi
# Re-read the live upstream INSIDE the lock. ACTIVE_PORT was read BEFORE a
# multi-minute build — that read was the time-of-check half of the race, and the
# flip must rewrite whatever the file actually holds now.
FLIP_FROM="$(grep -oE "localhost:(${BLUE_PORT}|${GREEN_PORT})" "$CADDYFILE" 2>/dev/null | head -1 | cut -d: -f2)"
FLIP_FROM="${FLIP_FROM:-$ACTIVE_PORT}"
cp -a "$CADDYFILE" "$CADDYFILE.pre-deploy"
sed -i "s/localhost:${FLIP_FROM}/localhost:${TARGET_PORT}/g" "$CADDYFILE"
# Did the rewrite actually MOVE the upstream? The post-flip PUBLIC gate below
# claims to catch "a sed that missed the live upstream line". It cannot: BOTH
# slots serve the health path, so when the flip is a no-op the OLD slot answers
# that probe 200 through the UNCHANGED Caddyfile, the gate passes, and the
# script then disables the old slot — leaving Caddy proxying a dead port, exit
# 0, "healthy" in every log line. A Caddyfile whose upstream is written some
# other way (127.0.0.1:<port>, a hand-edit) is invisible to the ACTIVE_PORT
# grep, to the FLIP_FROM re-read above AND to this sed, so all three fall back
# in agreement and nothing downstream can tell. Only the file can. Fail closed
# here, while the old slot is still serving and still enabled.
if grep -q "localhost:${FLIP_FROM}" "$CADDYFILE" || ! grep -q "localhost:${TARGET_PORT}" "$CADDYFILE"; then
  log "FLIP DID NOT LAND: after the rewrite $CADDYFILE still carries :$FLIP_FROM (or never gained :$TARGET_PORT) — the upstream is not written as 'localhost:<slot port>'; restoring, no swap, :$FLIP_FROM still serving"
  cp -a "$CADDYFILE.pre-deploy" "$CADDYFILE"
  systemctl disable --now "barkpark-slot@$TARGET" 2>/dev/null || true
  restore_slot_sha
  git reset --hard "$OLD"; exit 14
fi
if ! caddy validate --config "$CADDYFILE" >/dev/null 2>&1; then
  log "Caddyfile invalid after port flip — restoring, no swap"
  cp -a "$CADDYFILE.pre-deploy" "$CADDYFILE"
  systemctl disable --now "barkpark-slot@$TARGET" 2>/dev/null || true
  restore_slot_sha
  git reset --hard "$OLD"; exit 14
fi
if ! systemctl reload caddy; then
  log "caddy reload failed — restoring, no swap"
  cp -a "$CADDYFILE.pre-deploy" "$CADDYFILE"; systemctl reload caddy || true
  systemctl disable --now "barkpark-slot@$TARGET" 2>/dev/null || true
  restore_slot_sha
  git reset --hard "$OLD"; exit 14
fi
exec 8>&-   # leaf lock: released the moment the flip is written + reloaded, so
            # the long non-Caddy tail below (go builds, npm ci) never holds it
code="$(bp_curl_code -sk -o /dev/null --max-time 10 --resolve "${HEALTH_HOST}:443:127.0.0.1" "https://${HEALTH_HOST}${HEALTH_PATH}" || echo 000)"
log "Caddy now -> :$TARGET_PORT (https://${HEALTH_HOST}${HEALTH_PATH} = $code)"
# GATE, not just log (pds-bl-w49): the pre-flip loop above only proves the app
# boots on its OWN port (localhost:$TARGET_PORT) — it cannot catch a flip that
# landed wrong (a sed that missed the live upstream line, a Caddy reload that
# "succeeded" onto a stale worker, TLS/SNI misrouting on the PUBLIC host). This
# curl is the first proof the public hostname actually reaches the new slot,
# and it used to be captured into $code, logged, and then ignored — a broken
# flip still exited 0 and the deploy reported success. The old slot is still
# running and NOT yet retired (that happens below), so failing here can still
# flip Caddy back and walk away clean instead of shipping a silently-broken
# deploy.
if [ "$code" != "200" ]; then
  log "post-flip public health check FAILED (https://${HEALTH_HOST}${HEALTH_PATH} = $code) — flipping back to :$ACTIVE_PORT; it was never retired"
  revert_post_flip_health_fail() {
    cp -a "$CADDYFILE.pre-deploy" "$CADDYFILE"
    if ! caddy validate --config "$CADDYFILE" >/dev/null 2>&1; then
      log "WARN: pre-deploy Caddyfile backup failed to validate on revert — Caddy left as-is, fix by hand"
      return 1
    fi
    systemctl reload caddy || log "WARN: caddy reload failed while reverting the flip — Caddyfile restored on disk, reload manually"
  }
  with_caddy_lock revert_post_flip_health_fail
  systemctl disable --now "barkpark-slot@$TARGET" 2>/dev/null || true
  restore_slot_sha
  git reset --hard "$OLD"
  exit 14
fi

# ---- Drain, then retire the old slot AND the pre-blue/green legacy unit.
# Exactly one slot stays enabled (survives reboot). Rollback is NOT a bare
# Caddyfile flip — a slot restart recompiles NEW source from the ONE shared
# checkout into the old slot's stale build root. Run `instance-deploy.sh
# --rollback`: it resets the checkout to the idle slot's recorded sha
# (.slots/<slot>.sha), health-gates that slot on its own port, and flips
# Caddy only on green (see the rollback block above).
sleep 5
systemctl enable "barkpark-slot@$TARGET" >/dev/null 2>&1 || true
systemctl disable --now "barkpark-slot@$OTHER" >/dev/null 2>&1 || true
systemctl disable --now barkpark >/dev/null 2>&1 || true

# ---- Refresh the on-box monitoring agent (charter Decision 33), best-effort.
# Only touch boxes the provisioner ARMED with the agent (its token file exists);
# a plain/legacy box is left untouched. Rebuild barkpark-agent from the just-
# deployed code, re-install the COMMITTED unit, and enable + RESTART it so a
# self-update never drops the beat and never strands the old binary. The
# control/health URLs persist in /etc/barkpark/agent.env
# (written at provision time), so this step needs no knowledge of them. NON-FATAL:
# a monitoring hiccup must never fail a zero-downtime deploy — the app is already
# live on the new slot at this point.
if [ -f /etc/barkpark/agent.token ]; then
  log "refreshing barkpark-agent (monitoring beat)"
  # Build to a tmpdir and `install` (not `go build -o` straight onto the live
  # path): install(1) unlinks first, so a RUNNING barkpark-agent never
  # ETXTBSY-blocks its own refresh — the same idiom the barkpark-mcp block below
  # already uses and explains (dr-w4-bl-agent-build-in-place-can-etxtbsy).
  AGENT_TMPD="$(mktemp -d)"
  if command -v go >/dev/null 2>&1 && go build -o "$AGENT_TMPD/barkpark-agent" ./cmd/barkpark-agent \
     && install -m 0755 "$AGENT_TMPD/barkpark-agent" /usr/local/bin/barkpark-agent; then
    rm -rf "$AGENT_TMPD"
    install -m 0644 "$APP/deploy/systemd/barkpark-agent.service" /etc/systemd/system/barkpark-agent.service
    systemctl daemon-reload
    # restart (not just enable --now): `--now` is `start`, a NO-OP on an
    # already-active unit, so systemd never re-execs it and the running agent
    # keeps serving the deleted inode of the previous binary (measured: 29h
    # stale on guerrilla). Same shape as barkpark-mcp below.
    if systemctl enable barkpark-agent >/dev/null 2>&1 && systemctl restart barkpark-agent; then
      log "barkpark-agent enabled + restarted"
    else
      log "WARN: barkpark-agent enable/restart failed — beat down until next deploy"
    fi
    # SAY whether this box is metered. The unit now names
    # --health-token-file /etc/barkpark/agent.health.token; the file is written at
    # PROVISION time (internal/cli/cloud.agentInstallStep) and a self-update has no
    # admin bearer to mint one with, so a box provisioned before that step exists
    # keeps reporting -1 for req_per_s / p95_ms / err_5xx_per_s. That is survivable
    # — but it must not be SILENT, which is exactly how the whole fleet stayed
    # unmetered while one hand-patched box looked fine.
    if [ -s /etc/barkpark/agent.health.token ]; then
      log "barkpark-agent health token present — req/s, p95 and 5xx are metered"
    else
      log "WARN: no /etc/barkpark/agent.health.token — req/s, p95 and 5xx stay UNMETERED on this box (written at provision time; see deploy/systemd/README.md to backfill)"
    fi
  else
    rm -rf "$AGENT_TMPD"
    log "WARN: barkpark-agent rebuild skipped/failed — keeping the running agent"
  fi
fi

# ---- Refresh the remote MCP endpoint (viable-everywhere D18/D19), best-effort
# + GUARDED. barkpark-mcp.service runs the just-built bp binary as
# `mcp serve --http 127.0.0.1:$MCP_PORT` behind the /mcp Caddy route armed
# above. FORWARD-THROUGH design (D18): the unit and its env file hold NO API
# token — each caller's own bearer rides through to the downstream API; a
# missing/bogus bearer fails closed with the downstream 401. The downstream URL
# is the STABLE public front (https://$HEALTH_HOST), never a raw slot port —
# the blue/green flip would strand a pinned port (cp-deploy control-url
# precedent). GUARD: install+enable ONLY when the built binary advertises
# --http in its `mcp serve --help`, so this deploy step ships independently of
# the bearer transport slice without crash-looping the box on an unknown flag.
# NON-FATAL throughout — the app is already live on the new slot.
if command -v go >/dev/null 2>&1; then
  MCP_TMPD="$(mktemp -d)"
  if CGO_ENABLED=0 go build -o "$MCP_TMPD/bp" ./cmd/barkpark \
     && "$MCP_TMPD/bp" mcp serve --help 2>/dev/null | grep -q -- '--http'; then
    log "refreshing barkpark-mcp (remote MCP endpoint on 127.0.0.1:$MCP_PORT)"
    # `install` (not cp) — it unlinks first, so a running barkpark-mcp never
    # ETXTBSY-blocks its own refresh.
    install -m 0755 "$MCP_TMPD/bp" /usr/local/bin/barkpark-mcp
    mkdir -p "$(dirname "$MCP_ENV_FILE")"
    printf 'BARKPARK_API_URL=https://%s\nBARKPARK_MCP_HTTP_ADDR=127.0.0.1:%s\n' "$HEALTH_HOST" "$MCP_PORT" > "$MCP_ENV_FILE"
    install -m 0644 "$APP/deploy/systemd/barkpark-mcp.service" /etc/systemd/system/barkpark-mcp.service
    systemctl daemon-reload
    # restart (not just enable --now): an already-running unit must pick up the
    # freshly-installed binary.
    if systemctl enable barkpark-mcp >/dev/null 2>&1 && systemctl restart barkpark-mcp; then
      # `systemctl restart` of a Type=simple unit returns the moment the process
      # is forked — it says NOTHING about whether the serve survived its startup
      # manifest fetch. task-1a641b21d19595d3: this line read "enabled" on
      # guerrilla while the unit crash-looped 2,464 times (anonymous manifest,
      # no task noun, default --tools tasks fails fast). Settle, then read the
      # unit's OWN state and say what it is; a dead endpoint is named in the
      # deploy log, still non-fatal (the app slot is already live).
      sleep "${MCP_SETTLE_SECS:-15}"
      MCP_STATE="$(systemctl is-active barkpark-mcp 2>/dev/null || true)"
      MCP_RESTARTS="$(systemctl show barkpark-mcp -p NRestarts --value 2>/dev/null || true)"
      if [ "$MCP_STATE" = "active" ]; then
        log "barkpark-mcp active after ${MCP_SETTLE_SECS:-15}s (restarts=${MCP_RESTARTS:-?}; https://$HEALTH_HOST/mcp -> 127.0.0.1:$MCP_PORT)"
      else
        log "WARN: barkpark-mcp is NOT active after ${MCP_SETTLE_SECS:-15}s (state=${MCP_STATE:-unknown} restarts=${MCP_RESTARTS:-?}) — remote MCP /mcp is DOWN; journal tail:"
        journalctl -u barkpark-mcp -n 5 --no-pager 2>/dev/null | sed 's/^/    /' || true
      fi
    else
      log "WARN: barkpark-mcp enable/restart failed — remote MCP down until next deploy"
    fi
  else
    log "bp binary does not advertise 'mcp serve --http' — skipping barkpark-mcp install (bearer transport slice not merged yet)"
  fi
  rm -rf "$MCP_TMPD"
fi

# ---- Refresh the Connectors bridge (connectors charter D34/D46), best-effort
# + GUARDED. barkpark-connectors.service runs the standalone Node/TS bridge in
# $APP/connectors behind the /connectors Caddy route armed above, on the
# loopback :$CONNECTORS_PORT. NON-FATAL throughout — the app is already live on
# the new slot, and a bridge hiccup must never brick a good deploy.
#
# node is NOT on this box's PATH (bare `node -v` => command not found): asdf
# manages it, and systemd cannot expand a variable in the ExecStart executable
# position. So resolve node HERE and point a stable /usr/local/bin/barkpark-node
# symlink at it (same shape as /usr/local/bin/barkpark-mcp) — the committed unit
# never carries a version.
resolve_node_bin() {
  local d b
  if command -v asdf >/dev/null 2>&1; then
    d="$(asdf where nodejs 2>/dev/null || true)"
    if [ -n "$d" ] && [ -x "$d/bin/node" ]; then printf '%s\n' "$d/bin/node"; return 0; fi
  fi
  # Newest asdf install, for a box where no version is pinned for this dir.
  b="$(ls -1d "$HOME"/.asdf/installs/nodejs/*/bin/node 2>/dev/null | sort -V | tail -1)"
  if [ -n "$b" ] && [ -x "$b" ]; then printf '%s\n' "$b"; return 0; fi
  # A REAL node on PATH — never a bare shim: an asdf shim with no version set
  # exits non-zero, and installing a unit that points at it would crash-loop.
  b="$(command -v node 2>/dev/null || true)"
  if [ -n "$b" ] && "$b" -v >/dev/null 2>&1; then printf '%s\n' "$b"; return 0; fi
  return 1
}

CONNECTORS_DIR="$APP/connectors"
if [ ! -d "$CONNECTORS_DIR" ]; then
  log "no $CONNECTORS_DIR in this checkout — skipping barkpark-connectors"
elif ! NODE_BIN="$(resolve_node_bin)"; then
  log "WARN: no usable node (asdf nodejs not installed and none on PATH) — barkpark-connectors NOT installed; $CONNECTORS_PATH_PREFIX stays on the maintenance 503"
elif [ -z "${DATABASE_URL:-}" ]; then
  log "WARN: no DATABASE_URL in $APP/.env — barkpark-connectors NOT installed (the bridge owns the chat_bridge schema and cannot boot without it)"
else
  NODE_DIR="$(dirname "$NODE_BIN")"
  log "refreshing barkpark-connectors (node $("$NODE_BIN" -v 2>/dev/null || echo '?') at $NODE_BIN)"
  # COPY, never symlink (the #3374 place_node recipe): asdf's node lives under
  # /root, and every barkpark-site@ slot unit runs ProtectHome=yes — a symlink
  # into /root 203/EXECs those slots on their next restart. This line was the
  # SECOND writer of $NODE_LINK and kept silently re-breaking the fix on every
  # instance deploy (live-caught twice on 2026-07-16: capstone crashloop x74).
  # Copy only when content differs; atomic tmp+mv so a reader never sees a
  # half-written binary.
  if ! cmp -s "$NODE_BIN" "$NODE_LINK" 2>/dev/null; then
    cp "$NODE_BIN" "$NODE_LINK.new" && chmod 755 "$NODE_LINK.new" && mv "$NODE_LINK.new" "$NODE_LINK"
    log "placed node COPY at $NODE_LINK (ProtectHome-safe)"
  fi
  # FULL install (not --omit=dev) ON PURPOSE: the bridge has no build step yet —
  # its entrypoint is `tsx src/index.ts`, and tsx is a devDependency. When
  # connectors/ grows a real `build` (tsc -> dist/), switch this to
  # `npm ci --omit=dev` and point the unit at `node dist/index.js`.
  # npm's own shebang is `#!/usr/bin/env node`, which cannot work on a box with
  # no node on PATH — so prepend the resolved node dir for this call only.
  if ( cd "$CONNECTORS_DIR" && PATH="$NODE_DIR:$PATH" "$NODE_DIR/npm" ci --no-audit --no-fund ); then
    if [ ! -f "$CONNECTORS_DIR/node_modules/tsx/dist/cli.mjs" ]; then
      log "WARN: connectors deps installed but no tsx runner (node_modules/tsx/dist/cli.mjs) — barkpark-connectors NOT enabled"
    else
      # 0600 — this file holds DATABASE_URL and the credential cipher key. (mcp.env
      # is 0644 because it deliberately holds NO secret; that is the exception.)
      # There is deliberately NO BARKPARK_CHAT_TOKEN line: one ambient operator
      # token would serve EVERY tenant — the exact multi-tenant hole this wave
      # closes. Each install authenticates with its own workspace-bound token,
      # ciphered at rest under CONNECTORS_CREDENTIAL_KEY.
      # ROTATION, NOT A FLAG DAY. The cipher opens a sealed row under the
      # CURRENT key or any key in CONNECTORS_CREDENTIAL_KEY_PREVIOUS
      # (connectors/src/config.ts `splitKeys` → crypto/credential-cipher.ts), and
      # the unit reads ONLY this file (EnvironmentFile=/etc/barkpark/connectors.env).
      # Until this writer emitted the key, setting _PREVIOUS in /opt/barkpark/.env
      # reached nothing and the rotation documented directly above had to be
      # completed by hand-editing the box's connectors.env.
      #
      # UNSET IS NOT EMPTY. `splitKeys` reads an absent value and an empty string
      # the same way (an empty list either way), so emitting an empty line would
      # not MISLEAD the bridge — but it would stop this file from being able to
      # say "no rotation is in flight", and, once the operator deletes the line
      # from .env after `npm run rewrap`, the line must DISAPPEAR here on the next
      # deploy rather than linger as an empty claim. So: emitted only when there
      # is a key to carry. Whitespace-only counts as unset, for the same reason
      # loadConfig() trims CONNECTORS_CONNECT_SECRET before deciding.
      CONNECTORS_PREV_KEY="${CONNECTORS_CREDENTIAL_KEY_PREVIOUS:-}"
      case "$CONNECTORS_PREV_KEY" in
        *[![:space:]]*) ;;
        *) CONNECTORS_PREV_KEY="" ;;
      esac
      mkdir -p "$(dirname "$CONNECTORS_ENV_FILE")"
      ( umask 077; : > "$CONNECTORS_ENV_FILE" )
      chmod 0600 "$CONNECTORS_ENV_FILE"
      {
        printf 'DATABASE_URL=%s\n' "$DATABASE_URL"
        printf 'BARKPARK_API_URL=https://%s\n' "$HEALTH_HOST"
        printf 'CONNECTORS_HTTP_ADDR=127.0.0.1:%s\n' "$CONNECTORS_PORT"
        printf 'CONNECTORS_PATH_PREFIX=%s\n' "$CONNECTORS_PATH_PREFIX"
        printf 'CONNECTORS_CREDENTIAL_KEY=%s\n' "${CONNECTORS_CREDENTIAL_KEY:-}"
        # The SAME value Barkpark.Connectors signs tickets with (D50). If these
        # two ever disagree, every connect 401s and nothing else would catch it.
        printf 'CONNECTORS_CONNECT_SECRET=%s\n' "${CONNECTORS_CONNECT_SECRET:-}"
        # Present ONLY during a rotation window — see the UNSET-IS-NOT-EMPTY note above.
        if [ -n "$CONNECTORS_PREV_KEY" ]; then
          printf 'CONNECTORS_CREDENTIAL_KEY_PREVIOUS=%s\n' "$CONNECTORS_PREV_KEY"
        fi
      } > "$CONNECTORS_ENV_FILE"
      if [ -n "$CONNECTORS_PREV_KEY" ]; then
        log "connectors.env carries CONNECTORS_CREDENTIAL_KEY_PREVIOUS — a rotation window is OPEN; run \`npm run rewrap\` then delete the line from /opt/barkpark/.env"
      fi
      install -m 0644 "$APP/deploy/systemd/barkpark-connectors.service" /etc/systemd/system/barkpark-connectors.service
      systemctl daemon-reload
      if systemctl enable barkpark-connectors >/dev/null 2>&1 && systemctl restart barkpark-connectors; then
        # Health gate: a bridge that cannot boot (missing config, bad DB) exits
        # and Restart=on-failure would crash-loop it forever. Give it a moment,
        # then demand systemd still calls it active; otherwise DISABLE it again
        # and say so. Fail closed, stay non-fatal.
        sleep 5
        if [ "$(systemctl is-active barkpark-connectors 2>/dev/null)" = "active" ]; then
          log "barkpark-connectors up (https://$HEALTH_HOST$CONNECTORS_PATH_PREFIX -> 127.0.0.1:$CONNECTORS_PORT)"
          # LOG-ONLY probe (never a gate — a polling-only bridge legitimately
          # serves no HTTP): does the path route actually reach the bridge?
          code="$(bp_curl_code -s -o /dev/null --max-time 5 "http://127.0.0.1:${CONNECTORS_PORT}${CONNECTORS_PATH_PREFIX}/health" || echo 000)"
          log "connectors health probe: 127.0.0.1:${CONNECTORS_PORT}${CONNECTORS_PATH_PREFIX}/health = ${code:-000} (000 = no HTTP surface yet; provider webhooks would land on the maintenance 503 — see docs/ops/connectors-deploy.md)"

          # INSURANCE, NOT A GATE (connectors D54). The BRIDGE creates chat_bridge
          # at its own boot, so whoever it connects as OWNS the schema — and on
          # every path we actually run (prod, CI, local) that is the same role the
          # BEAM reads with, which makes this a strict no-op. It exists for the day
          # a second, non-owning Postgres role appears: without USAGE+SELECT, the
          # Studio Connectors catalog dies on `permission denied for schema
          # chat_bridge`. It runs AFTER the health gate (the schema does not exist
          # until the bridge has booted at least once) and it is GUARDED and
          # NON-FATAL — a missing psql, a role we cannot name, or a permission error
          # logs a warning and the deploy continues. A GRANT must never take an
          # instance down.
          if command -v psql >/dev/null 2>&1 && [ -n "${DATABASE_URL:-}" ]; then
            db_role="$(psql "$DATABASE_URL" -tAc 'SELECT current_user' 2>/dev/null || true)"
            if [ -n "$db_role" ]; then
              if psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q \
                   -c "GRANT USAGE ON SCHEMA chat_bridge TO \"$db_role\"" \
                   -c "GRANT SELECT ON chat_bridge.connector_installs TO \"$db_role\"" >/dev/null 2>&1; then
                log "connectors: GRANT USAGE/SELECT on chat_bridge to $db_role (no-op for the schema owner)"
              else
                log "WARN: could not GRANT on chat_bridge to $db_role (schema may not exist yet, or we are not its owner) — continuing"
              fi
            fi
          fi
        else
          log "WARN: barkpark-connectors did not stay active — disabling it (no crash-loop); $CONNECTORS_PATH_PREFIX stays on the maintenance 503. Check: journalctl -u barkpark-connectors"
          systemctl disable --now barkpark-connectors >/dev/null 2>&1 || true
        fi
      else
        log "WARN: barkpark-connectors enable/restart failed — bridge down until next deploy"
      fi
    fi
  else
    log "WARN: npm ci failed in $CONNECTORS_DIR — barkpark-connectors NOT (re)installed; the running unit (if any) keeps its old deps"
  fi
fi

# ---- Install the bp CLI so every Studio chat session can wield Barkpark tasks
# (chat-task-hands W1). /usr/local/bin is already on the LIVE BEAM process PATH
# (/proc-proven on guerrilla), so a Port.open child resolves `bp` with zero PATH
# injection — no reliance on the stray, off-PATH /opt/barkpark/bp manual build.
# Build ONCE per deploy (this main flow runs once under flock, not per slot), for
# the NATIVE arch of whichever box runs this script — no GOARCH/GOOS is set
# anywhere in this file, so `go build` targets the host and nothing here depends
# on knowing which arch that is. Do NOT re-add an arch claim: this line used to
# read "guerrilla is ARM64" with nothing behind it, and the pds wave-49 filer
# measured the opposite — `ssh root@157.180.90.121 uname -m` -> `x86_64`
# (2026-09, the filer's measurement, not re-run here; this campaign has no ssh).
# CGO off to match the barkpark-agent precedent above. Install ATOMICALLY:
# build to a tmpfile on the SAME filesystem, then
# rename over the live binary, so an in-flight `bp` invocation never sees a half-
# written file. LOUD on failure — a silent skip is exactly the silent-failure bug
# this epic exists to kill — but NON-FATAL: the app is already live on the new
# slot, and bricking a good deploy over a transient toolchain hiccup is worse than
# a logged miss that self-heals on the next deploy.
log "installing bp CLI -> /usr/local/bin/bp"
if command -v go >/dev/null 2>&1; then
  bp_tmp="$(mktemp /usr/local/bin/.bp.XXXXXX)"
  if CGO_ENABLED=0 go build -o "$bp_tmp" ./cmd/barkpark; then
    chmod 0755 "$bp_tmp"
    mv -f "$bp_tmp" /usr/local/bin/bp
    log "bp CLI installed -> /usr/local/bin/bp ($(command -v bp))"
  else
    rm -f "$bp_tmp"
    log "WARN: bp CLI build FAILED (go build ./cmd/barkpark) — Studio chat task hands unavailable until next deploy"
  fi
else
  log "WARN: go not found — bp CLI NOT installed; Studio chat task hands unavailable until next deploy"
fi

# ---- Install the Cloud sandbox runner onto PATH (connectors charter D265).
# ClaudeChat picks a provider turn by resolving the BARE executable name
# "cloud-sandbox-runner" with System.find_executable on the LIVE BEAM PATH
# (/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:… — /proc-proven
# on guerrilla, with NO node resolvable and NO Environment= override). So the
# runner's own `#!/usr/bin/env node` shebang ships as a SILENT NO-OP: the moment
# a :cloud turn starts, ClaudeChat returns {:stop, :binary_not_found}. Two files,
# re-copied EVERY deploy so they track the checkout (#3374 copy idiom):
#   (1) the runner .mjs  -> $SANDBOX_RUNNER_MJS
#   (2) a 2-line POSIX wrapper -> $SANDBOX_RUNNER_BIN whose basename matches the
#       bare name ClaudeChat defaults to, execing the already-deployed,
#       dependency-free /usr/local/bin/barkpark-node (v26.5.0 ELF, argv passthrough
#       proven) against the installed .mjs — NEVER the env-node shebang. Because
#       the basename IS the default, ClaudeChat's :sandbox_runner config stays UNSET.
# Same LOUD-but-NON-FATAL contract as the bp/connectors blocks above: the app is
# already live on the new slot, so a missing runner source or an unwritable target
# logs a WARN and the deploy continues — a :cloud turn simply stays
# :binary_not_found until the next deploy heals it. Writes are atomic (tmp on the
# SAME target dir, then rename) so a concurrent reader never sees a half-written file.
RUNNER_SRC="$APP/scripts/connectors/cloud-sandbox-runner.mjs"
log "installing cloud-sandbox-runner -> $SANDBOX_RUNNER_BIN (wrapper) + $SANDBOX_RUNNER_MJS (.mjs)"
install_sandbox_runner() { # returns non-zero (LOUD) on any failure; caller stays non-fatal
  if [ ! -f "$RUNNER_SRC" ]; then
    log "WARN: no $RUNNER_SRC in this checkout — cloud-sandbox-runner NOT installed; a :cloud turn stays :binary_not_found until next deploy"
    return 1
  fi
  # (1) the .mjs, atomic (tmp on the SAME target dir, then rename), 0644.
  if ! cp "$RUNNER_SRC" "$SANDBOX_RUNNER_MJS.new" 2>/dev/null \
     || ! chmod 0644 "$SANDBOX_RUNNER_MJS.new" \
     || ! mv -f "$SANDBOX_RUNNER_MJS.new" "$SANDBOX_RUNNER_MJS"; then
    rm -f "$SANDBOX_RUNNER_MJS.new" 2>/dev/null || true
    log "WARN: could not install $SANDBOX_RUNNER_MJS (unwritable target?) — cloud-sandbox-runner NOT installed this deploy"
    return 1
  fi
  # (2) the wrapper, atomic, 0755. FIXED production paths on purpose — the wrapper
  # runs on the box where both live under /usr/local/bin, and hardcoding
  # barkpark-node here is the whole point: never trust the .mjs env-node shebang on
  # the node-less BEAM PATH.
  {
    printf '#!/bin/sh\n'
    printf 'exec /usr/local/bin/barkpark-node /usr/local/bin/cloud-sandbox-runner.mjs "$@"\n'
  } > "$SANDBOX_RUNNER_BIN.new" 2>/dev/null || true
  if [ ! -s "$SANDBOX_RUNNER_BIN.new" ] \
     || ! chmod 0755 "$SANDBOX_RUNNER_BIN.new" \
     || ! mv -f "$SANDBOX_RUNNER_BIN.new" "$SANDBOX_RUNNER_BIN"; then
    rm -f "$SANDBOX_RUNNER_BIN.new" 2>/dev/null || true
    log "WARN: could not install the $SANDBOX_RUNNER_BIN wrapper (unwritable target?) — cloud-sandbox-runner NOT installed this deploy"
    return 1
  fi
  log "cloud-sandbox-runner installed -> $SANDBOX_RUNNER_BIN (exec barkpark-node cloud-sandbox-runner.mjs), .mjs versioned from the checkout"
  return 0
}
install_sandbox_runner || true

# ---- Post-deploy LIVE reachability smoke for the public /mcp matrix
# (connectors-mcp-live-reachability-smoke). ADVISORY, NEVER A GATE.
#
# WHAT IT ADDS. The auth fail-closed contract and the Caddy arming are already
# proven hermetically (internal/cli/mcp_http_test.go, instance-deploy_test.sh).
# Neither can prove the four PUBLIC paths answer correctly on a real box — a CI
# runner reaches no host and holds no bearer — so that proof lives here, on the
# box, after every unit above has been refreshed. Four legs, each printing the
# code it saw: POST /mcp initialize (200 + serverInfo.name=barkpark-tasks),
# GET /mcp (405), GET /connectors/mcp (404 by design), GET /connectors/health (200).
#
# WHY THE EXIT CODE IS SWALLOWED. We are past the flip: the app slot is live and
# Caddy already points at it. A stopped barkpark-mcp or a silent bridge is a real
# problem, but failing HERE would mark a healthy app deploy as failed and invite a
# rollback of code that is serving fine. The WARN + the per-leg lines above it are
# the signal; the deploy log is where an operator reads them.
#
# Against the STABLE public front ($HEALTH_HOST), never a slot port — the blue/green
# flip would strand a pinned port (the cp-deploy control-url precedent), and a slot
# port would bypass Caddy, which is exactly the hop these legs exist to prove.
MCP_SMOKE="$APP/deploy/mcp-reachability-smoke.sh"
if [ -f "$MCP_SMOKE" ]; then
  log "post-deploy /mcp reachability smoke -> https://$HEALTH_HOST (advisory, non-fatal)"
  bash "$MCP_SMOKE" "$HEALTH_HOST" || log "WARN: /mcp reachability smoke has RED leg(s) (advisory — the app deploy stands); read the mcp-smoke LEG lines above for the code each leg saw"
else
  log "WARN: no $MCP_SMOKE in this checkout — /mcp reachability smoke skipped"
fi

echo "$NEW" > "$STATE"
log "HEALTHY — slot $TARGET live at $(git rev-parse --short HEAD)"
exit 0
