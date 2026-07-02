#!/usr/bin/env bash
#
# self-update.sh — apply an instance self-update, triggered by the admin
# endpoint POST /v1/admin/self-update (Barkpark.SelfUpdate.Runner).
#
#   fetch → fast-forward to origin/$BARKPARK_UPSTREAM_BRANCH (default main)
#   → scripts/deploy-rebuild.sh (build-aside, swap, restart)
#
# The merge is deliberately --ff-only: a diverged local checkout REFUSES the
# update (exit 2) rather than rewriting anything — resolve by hand.
#
# The post-merge hook is SUPPRESSED and the rebuild invoked EXPLICITLY:
# relying on the merge to fire the hook wedges the endpoint after a failed
# build (HEAD already advanced → the retry merge is "Already up to date" →
# no hook → no rebuild, ever). Calling deploy-rebuild.sh directly makes a
# re-trigger always rebuild, and its exit code (0 ok / 1 build failed /
# 3 slot box) flows back to the Runner, so the endpoint reports the TRUE
# outcome instead of "merge succeeded".
#
# NOTE: this applies from the LOCAL `origin` remote. Keep origin pointed at
# the same repo the Checker polls (BARKPARK_UPSTREAM_REPO) or the banner and
# the applied update can disagree.
#
# Single-flight: the Runner GenServer serializes endpoint triggers; the
# repo-local flock inside deploy-rebuild.sh serializes against manual
# `git pull` / `make rebuild` builders. (No /tmp lock — a predictable /tmp
# path could be squatted by any local user to block updates forever.)
set -euo pipefail

cd "$(dirname "$0")/.."

echo "[self-update] fetching..."
git fetch origin --tags --prune

BRANCH="${BARKPARK_UPSTREAM_BRANCH:-main}"
echo "[self-update] fast-forwarding to origin/$BRANCH..."
git -c core.hooksPath=/dev/null merge --ff-only "origin/$BRANCH" || {
  echo "[self-update] REFUSED: local checkout has diverged from origin/$BRANCH — resolve manually"
  exit 2
}

echo "[self-update] merge done — rebuilding..."
exec bash scripts/deploy-rebuild.sh
