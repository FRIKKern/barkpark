#!/usr/bin/env bash
#
# self-update.sh — apply an instance self-update, triggered by the admin
# endpoint POST /v1/admin/self-update (Barkpark.SelfUpdate.Runner).
#
#   fetch → fast-forward to origin/$BARKPARK_UPSTREAM_BRANCH (default main)
#   → scripts/deploy-rebuild.sh (simple boxes: build-aside, swap, restart)
#     OR deploy/instance-deploy.sh (blue/green slot boxes with a .slots marker)
#
# The merge is deliberately --ff-only: a diverged local checkout REFUSES the
# update (exit 2) rather than rewriting anything — resolve by hand.
#
# The post-merge hook is SUPPRESSED and the rebuild invoked EXPLICITLY:
# relying on the merge to fire the hook wedges the endpoint after a failed
# build (HEAD already advanced → the retry merge is "Already up to date" →
# no hook → no rebuild, ever). Calling deploy-rebuild.sh directly makes a
# re-trigger always rebuild, and its exit code (0 ok / 1 build failed /
# 13 migrate failed, old code still serving / 3 slot box) flows back to the
# Runner, so the endpoint reports the TRUE outcome instead of "merge
# succeeded".
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
# Branch refs are the update itself — a fetch failure here is fatal. Tags are
# fetched SEPARATELY, forced and non-fatal: a stale local tag that diverged
# from the remote (seen live 2026-07-06: the box's old v0.0.83 differed and
# `--tags` refused to clobber it, aborting the whole update under set -e)
# must never block applying code. --force adopts the remote's tags as truth —
# release tags are immutable by rule, and BuildInfo's describe needs them
# current for the rebuilt version stamp.
git fetch origin --prune
git fetch origin --tags --force ||
  echo "[self-update] WARN: tag fetch failed — continuing (version stamp may lag)"

BRANCH="${BARKPARK_UPSTREAM_BRANCH:-main}"
echo "[self-update] fast-forwarding to origin/$BRANCH..."
git -c core.hooksPath=/dev/null merge --ff-only "origin/$BRANCH" || {
  echo "[self-update] REFUSED: local checkout has diverged from origin/$BRANCH — resolve manually"
  exit 2
}

echo "[self-update] merge done — rebuilding..."
# Blue/green slot boxes (an api-root `.slots` marker — guerrilla-style) are
# owned by deploy/instance-deploy.sh; deploy-rebuild.sh REFUSES them (exit 3,
# "each caller guards on .slots"). self-update.sh is that caller: route slot
# boxes to their zero-downtime deployer so the admin Update button actually
# applies instead of dead-ending. instance-deploy.sh does its own locked pull
# + idle-slot build + health-gated Caddy flip; the ff-merge and forced tag
# fetch above already advanced HEAD and refreshed BuildInfo's tags, so its
# pull coalesces to a no-op and the rebuilt slot carries the right version.
if [ -d .slots ]; then
  echo "[self-update] blue/green slot box — delegating to deploy/instance-deploy.sh"
  exec bash deploy/instance-deploy.sh
fi

exec bash scripts/deploy-rebuild.sh
