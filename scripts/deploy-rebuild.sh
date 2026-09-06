#!/usr/bin/env bash
#
# deploy-rebuild.sh — THE legacy single-box rebuild engine (build-aside-and-swap).
#
# Called by all three deploy writers so they can never race each other:
#   .githooks/post-merge      (git-pull deploy)
#   make rebuild              (manual)
#   scripts/self-update.sh    (admin endpoint POST /v1/admin/self-update)
# Blue/green slot boxes never get here — deploy/instance-deploy.sh owns those
# (each caller guards on .slots; the guard below is defense in depth).
#
# Sequence: repo-local flock (ONE builder; all callers share api/_build_next)
# → full from-scratch build ASIDE (Golden Rules 1-2 hold: fresh HEEx, forced
# deps.compile — we nuke and rebuild the entire aside root, just not the live
# one) → ecto.migrate on the NEW code (old build still serving; a failure
# ABORTS the swap — fail closed, exit 13, mirroring instance-deploy.sh's
# migrate arm) → swap into api/_build/prod → non-fatal Go TUI build →
# non-fatal barkpark-agent rebuild+restart → restart LAST.
#
# Restart-last is deliberate: in the endpoint flow this script is a child of
# barkpark.service, and systemd SIGTERMs the whole cgroup on stop — including
# this script. The queued restart still completes under PID 1 and the box
# comes back on the new code, but NOTHING meaningful may run after the
# restart line (this is why the TUI build moved BEFORE it; it is if-guarded,
# so a Go failure cannot abort the restart — the past half-deploy incident
# stays fixed).
#
# THE ONE THING THAT DOES FOLLOW THE RESTART is the health probe, and it is
# allowed to because it makes no claim it has not measured. `systemctl restart`
# returning 0 means systemd ACCEPTED the unit — never that the app serves; the
# old "Done. Service restarted." descended from nothing but that acceptance.
# The probe is the shape already proven in deploy/instance-deploy.sh (a bounded
# `curl -w %{http_code}` == 200 loop with a typed refusal). In the endpoint flow
# the cgroup SIGTERM may kill the probe mid-loop — that prints NO receipt at
# all, which is silence, not a false claim, and is the correct failure mode.
#
# Exit codes: 0 deployed (or service simply not running) · 1 build failed
# (api/_build/prod untouched, still restartable, NO restart) · 13 migrate
# failed (same guarantee: swap aborted, old code keeps serving, NO restart —
# instance-deploy.sh's exit-13 convention) · 15 RESTART UNVERIFIED (the swap
# and the migrate SUCCEEDED and the new build IS installed; systemd accepted
# the restart and the app never answered 200 — do not report this as a build
# failure) · 3 slot box.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="$PWD"

if [ -d "$REPO/.slots" ]; then
  echo "[deploy-rebuild] blue/green slot layout detected — use deploy/instance-deploy.sh"
  exit 3
fi

# Source ASDF (Hetzner needs the shims) + .env, exactly like the hook did.
# The prefix is overridable ONLY so the hermetic harness
# (scripts/deploy-receipt-failure.test.sh) can keep a real Go/Elixir toolchain
# from reaching around its stub PATH. Prod never sets it — the default is the
# byte-identical prod prefix.
export PATH="${BP_DEPLOY_PATH_PREFIX:-/root/.asdf/bin:/root/.asdf/shims:/usr/local/go/bin}:$PATH"
if [ -f /root/.asdf/asdf.sh ]; then . /root/.asdf/asdf.sh; fi
if [ -f .env ]; then set -a; source .env; set +a; fi
export MIX_ENV=prod

# ONE builder at a time (blocking). Repo-local lock file — NOT /tmp, where
# any local user could pre-create and squat the predictable path forever.
exec 8>"$REPO/.deploy-build.lock"
flock 8

# ── Machine-readable apply record (flight recorder) ──────────────────────────
# The final `systemctl restart` SIGTERMs this script's own cgroup (see header),
# so the process can never report an apply that dies AT or AFTER the restart
# line — the dooodo 0.2.26 crashloop (171+ boot loops, 42703 at boot) was
# invisible everywhere for exactly this reason. This file is rewritten at every
# phase TRANSITION, so whatever survives on disk names the last phase entered
# and its outcome. `phase=restart outcome=applied` — written immediately before
# the restart line — means "new code swapped + migrated, restart queued": a box
# later found down or crashlooping with that record died post-restart. Wiring a
# consumer (agent beat / check endpoint) is follow-up work; the record is the
# contract. Never fatal: telemetry must not be able to abort a deploy.
# Under the flock on purpose — one builder, one writer.
STATUS_FILE="$REPO/.deploy-status.json"
DEPLOY_SHA="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
write_status() { # $1 = phase (build|migrate|restart), $2 = outcome (running|failed|applied)
  printf '{"engine":"deploy-rebuild","phase":"%s","outcome":"%s","sha":"%s","ts":"%s","pid":%d}\n' \
    "$1" "$2" "$DEPLOY_SHA" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$$" \
    > "$STATUS_FILE.tmp" 2>/dev/null && mv -f "$STATUS_FILE.tmp" "$STATUS_FILE" 2>/dev/null || true
}

echo "[deploy-rebuild] Building Phoenix aside (api/_build_next — old build keeps serving)..."
write_status build running
rm -rf api/_build_next
if ! (
  cd api &&
  MIX_ENV=prod MIX_BUILD_ROOT=_build_next mix deps.get &&
  MIX_ENV=prod MIX_BUILD_ROOT=_build_next mix deps.compile --force &&
  MIX_ENV=prod MIX_BUILD_ROOT=_build_next mix compile
); then
  echo "[deploy-rebuild] BUILD FAILED — api/_build/prod is untouched and still restartable. NOT restarting."
  write_status build failed
  exit 1
fi

# Migrate BEFORE the swap, on the NEW code: MIX_BUILD_ROOT=_build_next runs the
# freshly compiled migrations while api/_build/prod (the old build) is untouched
# and the old BEAM keeps serving. Every other deploy lane migrates
# (instance-deploy.sh:722 with hard revert + exit 13, bake-server-image.sh:155,
# setup deploy.sh:279); this engine skipping it is what bricked dooodo on
# 0.2.25→0.2.26 (schema_definitions.singleton shipped, migrate never ran, the
# box crashlooped on 42703 at boot). FAIL CLOSED: a failed migrate aborts the
# swap — no new build, no restart, the old code keeps serving — the closest this
# build-aside engine can get to instance-deploy's revert semantics without a
# slot to fall back to.
echo "[deploy-rebuild] Migrating (new code, old build still serving)..."
write_status migrate running
if ! (cd api && MIX_ENV=prod MIX_BUILD_ROOT=_build_next mix ecto.migrate); then
  echo "[deploy-rebuild] MIGRATE FAILED — swap aborted; api/_build/prod (old code) is untouched and keeps serving. NOT restarting."
  write_status migrate failed
  exit 13
fi

# Residual risk (documented): a crash between this rm and mv loses the old
# build too — a seconds-wide window the slot path doesn't have. The running
# BEAM keeps serving from memory either way.
echo "[deploy-rebuild] Build + migrate OK — swapping into api/_build/prod..."
rm -rf api/_build/prod
mkdir -p api/_build
mv api/_build_next/prod api/_build/prod
rm -rf api/_build_next

# Go TUI client — NON-FATAL by design (the server runs the API, not the TUI).
# Before the restart on purpose: after it we may not exist (cgroup kill).
echo "[deploy-rebuild] Building Go TUI client (non-fatal)..."
if command -v go > /dev/null 2>&1; then
  if go mod tidy && go build -o bin/barkpark-tui ./cmd/barkpark; then
    echo "[deploy-rebuild] Go TUI client built."
  else
    echo "[deploy-rebuild] WARN: Go TUI client build failed — API deploy unaffected."
  fi
else
  echo "[deploy-rebuild] go not found — skipping TUI client build."
fi

# pdrender→TUI wasm the paper reader lazy-loads (/assets/bp-pdrender.wasm.gz).
# NON-FATAL, same discipline as the TUI build above, and BEFORE the restart for
# the same cgroup-kill reason. Build-at-deploy is what lets us drop the committed
# blob from git without ever leaving the live reader without it: every deploy
# regenerates it into api/priv/static/assets/ (served by Plug.Static at /assets/).
# `make wasm` pins its own Go toolchain via GOTOOLCHAIN, independent of the
# system go used for the TUI build.
echo "[deploy-rebuild] Building pdrender wasm (non-fatal)..."
if command -v go > /dev/null 2>&1; then
  if make wasm; then
    echo "[deploy-rebuild] pdrender wasm built."
  else
    echo "[deploy-rebuild] WARN: pdrender wasm build failed — API deploy unaffected (reader TUI view degrades to its fallback)."
  fi
else
  echo "[deploy-rebuild] go not found — skipping pdrender wasm build."
fi

# On-box monitoring agent — rebuilt from the just-deployed code, NON-FATAL, and
# BEFORE the restart for the same cgroup-kill reason as the two builds above.
# Lifted from deploy/instance-deploy.sh:806-830, which is the ONLY lane that has
# ever built barkpark-agent — so on every box that self-updates instead of being
# re-provisioned, the agent binary is frozen at warm-pool arm time and any new
# vital it learns to report stays dark forever (measured: `cpu_cores` present in
# 1 of 6 fleet binaries, with `load1` present in 6 of 6 as the non-vacuous
# control). Blessing a fresher release tag cannot fix that: no self-update path
# builds the agent at all.
#
# Only touches boxes the provisioner ARMED with the agent (its token file
# exists); a plain/legacy box is left alone. The control/health URLs live in
# /etc/barkpark/agent.env from provision time, so this needs no knowledge of
# them. The whole sequence is an `if` condition, so under `set -e` a monitoring
# hiccup still cannot fail the deploy.
if [ -f /etc/barkpark/agent.token ]; then
  echo "[deploy-rebuild] Refreshing barkpark-agent (monitoring beat, non-fatal)..."
  # RESTART, never `enable --now`: `--now` is `start`, a NO-OP on an already-
  # active unit, so systemd never re-execs and the running agent keeps serving
  # the DELETED inode of the binary we just replaced (measured 29h stale on
  # guerrilla — the bug #9823 fixed for the slot path).
  # Build to a tmpdir and `install` (not `go build -o` straight onto the live
  # path): install(1) unlinks first, so a RUNNING barkpark-agent never
  # ETXTBSY-blocks its own refresh — the idiom instance-deploy.sh's barkpark-mcp
  # block established (dr-w4-bl-agent-build-in-place-can-etxtbsy).
  AGENT_TMPD="$(mktemp -d)"
  if command -v go > /dev/null 2>&1 &&
    go build -o "$AGENT_TMPD/barkpark-agent" ./cmd/barkpark-agent &&
    install -m 0755 "$AGENT_TMPD/barkpark-agent" /usr/local/bin/barkpark-agent &&
    rm -rf "$AGENT_TMPD" &&
    install -m 0644 deploy/systemd/barkpark-agent.service /etc/systemd/system/barkpark-agent.service &&
    systemctl daemon-reload &&
    systemctl enable barkpark-agent > /dev/null 2>&1 &&
    systemctl restart barkpark-agent; then
    echo "[deploy-rebuild] barkpark-agent rebuilt, enabled + restarted."
  else
    echo "[deploy-rebuild] WARN: barkpark-agent refresh failed — the old agent keeps beating until the next deploy."
  fi
fi

# Restart LAST — see the header comment. Nothing may follow this block.
# The record goes down BEFORE the restart because nothing after it may run:
# outcome=applied here means "swapped + migrated, restart queued", not "boot
# verified" — post-restart death is exactly what a consumer of this file
# detects (applied record + box not serving the recorded sha).
write_status restart applied

# The probe target and its bound. Defaults are the prod values; the harness
# shrinks the loop so the refusal arm is provable in ~0s.
BP_HEALTH_URL="${BP_HEALTH_URL:-http://localhost:4000/api/schemas}"
BP_HEALTH_ATTEMPTS="${BP_HEALTH_ATTEMPTS:-40}"
BP_HEALTH_SLEEP="${BP_HEALTH_SLEEP:-3}"

if systemctl is-active barkpark > /dev/null 2>&1; then
  echo "[deploy-rebuild] Restarting service..."
  sudo systemctl restart barkpark
  # Ported from deploy/instance-deploy.sh's post-flip probe: bounded
  # http_code==200 loop, ok flag, typed refusal. Until this loop answers 200
  # NOTHING here may say the service is up.
  echo "[deploy-rebuild] Restarted — probing $BP_HEALTH_URL for HTTP 200 (up to $BP_HEALTH_ATTEMPTS attempts)..."
  probe_code=000
  probe_i=0
  while [ "$probe_i" -lt "$BP_HEALTH_ATTEMPTS" ]; do
    probe_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$BP_HEALTH_URL" 2>/dev/null || echo 000)"
    if [ "$probe_code" = "200" ]; then break; fi
    probe_i=$((probe_i + 1))
    sleep "$BP_HEALTH_SLEEP"
  done
  if [ "$probe_code" = "200" ]; then
    echo "[deploy-rebuild] Done. Service restarted and answering ($BP_HEALTH_URL -> HTTP 200)."
  else
    write_status restart unverified
    echo "[deploy-rebuild] RESTART UNVERIFIED — systemd accepted the restart but $BP_HEALTH_URL never answered 200 in $BP_HEALTH_ATTEMPTS attempts (last: '$probe_code'). The new build IS installed; the app is NOT known to be serving. Check: make logs"
    exit 15
  fi
else
  echo "[deploy-rebuild] Service not running. Start with: systemctl start barkpark"
fi
