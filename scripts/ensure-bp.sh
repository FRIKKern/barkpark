#!/usr/bin/env bash
#
# ensure-bp.sh — SessionStart hook: make sure the `bp` CLI exists on PATH.
#
# Cloud agent sessions (Claude Code on the web, fresh containers) boot without
# `bp`, so the committed .mcp.json has no binary to launch. This hook installs
# the prebuilt release binary via scripts/install-cli.sh when `bp` is missing.
#
# FAIL-SOFT BY CONTRACT: this script ALWAYS exits 0. A session-start hook that
# fails wedges the whole session — a missing bp never should. When the install
# can't complete (network egress blocks GitHub releases, no writable bin dir),
# it prints a one-line hint and gets out of the way.
set -u

if command -v bp >/dev/null 2>&1; then
  exit 0
fi

cd "$(dirname "$0")/.."

# ~/.local/bin is the installer's fallback dir and often absent from a fresh
# container's PATH — check it before reinstalling on every session.
if [ -x "$HOME/.local/bin/bp" ]; then
  echo "[ensure-bp] bp is at ~/.local/bin/bp but not on PATH — add: export PATH=\"\$HOME/.local/bin:\$PATH\""
  exit 0
fi

if sh scripts/install-cli.sh >/dev/null 2>&1; then
  echo "[ensure-bp] installed bp ($(command -v bp || echo "$HOME/.local/bin/bp"))"
else
  echo "[ensure-bp] bp not installed (network egress may block github.com releases) — barkpark MCP tools unavailable this session; see docs/setup/CLAUDE-CODE.md"
fi

exit 0
