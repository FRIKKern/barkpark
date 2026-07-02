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
# one) → swap into api/_build/prod → non-fatal Go TUI build → restart LAST.
#
# Restart-last is deliberate: in the endpoint flow this script is a child of
# barkpark.service, and systemd SIGTERMs the whole cgroup on stop — including
# this script. The queued restart still completes under PID 1 and the box
# comes back on the new code, but NOTHING meaningful may run after the
# restart line (this is why the TUI build moved BEFORE it; it is if-guarded,
# so a Go failure cannot abort the restart — the past half-deploy incident
# stays fixed).
#
# Exit codes: 0 deployed (or service simply not running) · 1 build failed
# (api/_build/prod untouched, still restartable, NO restart) · 3 slot box.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="$PWD"

if [ -d "$REPO/.slots" ]; then
  echo "[deploy-rebuild] blue/green slot layout detected — use deploy/instance-deploy.sh"
  exit 3
fi

# Source ASDF (Hetzner needs the shims) + .env, exactly like the hook did.
export PATH="/root/.asdf/bin:/root/.asdf/shims:/usr/local/go/bin:$PATH"
if [ -f /root/.asdf/asdf.sh ]; then . /root/.asdf/asdf.sh; fi
if [ -f .env ]; then set -a; source .env; set +a; fi
export MIX_ENV=prod

# ONE builder at a time (blocking). Repo-local lock file — NOT /tmp, where
# any local user could pre-create and squat the predictable path forever.
exec 8>"$REPO/.deploy-build.lock"
flock 8

echo "[deploy-rebuild] Building Phoenix aside (api/_build_next — old build keeps serving)..."
rm -rf api/_build_next
if (
  cd api &&
  MIX_ENV=prod MIX_BUILD_ROOT=_build_next mix deps.get &&
  MIX_ENV=prod MIX_BUILD_ROOT=_build_next mix deps.compile --force &&
  MIX_ENV=prod MIX_BUILD_ROOT=_build_next mix compile
); then
  # Residual risk (documented): a crash between this rm and mv loses the old
  # build too — a seconds-wide window the slot path doesn't have. The running
  # BEAM keeps serving from memory either way.
  echo "[deploy-rebuild] Build OK — swapping into api/_build/prod..."
  rm -rf api/_build/prod
  mkdir -p api/_build
  mv api/_build_next/prod api/_build/prod
  rm -rf api/_build_next
else
  echo "[deploy-rebuild] BUILD FAILED — api/_build/prod is untouched and still restartable. NOT restarting."
  exit 1
fi

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

# Restart LAST — see the header comment. Nothing may follow this block.
if systemctl is-active barkpark > /dev/null 2>&1; then
  echo "[deploy-rebuild] Restarting service..."
  sudo systemctl restart barkpark
  echo "[deploy-rebuild] Done. Service restarted."
else
  echo "[deploy-rebuild] Service not running. Start with: systemctl start barkpark"
fi
