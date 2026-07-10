#!/usr/bin/env bash
# Studio Claude-chat real-binary E2E lane (charter D20c). Spawns the ACTUAL
# `claude` CLI to prove the resume premise end-to-end: a session pinned with
# --session-id stamps a codeword, closes, and a --resume of the same uuid recalls
# it. This spends real API budget (~$0.43) and ~40s — it is NEVER in the default
# `mix test` lane or CI. Run it deliberately, from a host with `claude auth login`.
#
#     scripts/claude-chat-e2e.sh
#     CLAUDE_BIN=/abs/path/to/claude scripts/claude-chat-e2e.sh
#
# Mirrors scripts/idp-interop.sh: resolve the binary or REFUSE (no silent skip).
set -uo pipefail
cd "$(dirname "$0")/.."

# ── resolve the claude binary (it is NOT on PATH on the dev host) ────────────
# Precedence: explicit CLAUDE_BIN → PATH → the common local install location.
resolve_claude_bin() {
  if [ -n "${CLAUDE_BIN:-}" ]; then
    if [ -x "$CLAUDE_BIN" ]; then echo "$CLAUDE_BIN"; return 0; fi
    echo "ERROR: CLAUDE_BIN=$CLAUDE_BIN is not an executable file" >&2
    return 1
  fi

  if command -v claude >/dev/null 2>&1; then
    command -v claude
    return 0
  fi

  for cand in "$HOME/.claude/local/claude" "/usr/local/bin/claude" "/opt/homebrew/bin/claude"; do
    if [ -x "$cand" ]; then echo "$cand"; return 0; fi
  done

  return 1
}

CLAUDE_BIN="$(resolve_claude_bin)" || {
  cat >&2 <<'EOF'
ERROR: could not resolve the `claude` binary.

This E2E needs the real Claude Code CLI (with `claude auth login` completed).
Set CLAUDE_BIN to its absolute path and retry, e.g.:

    CLAUDE_BIN="$HOME/.claude/local/claude" scripts/claude-chat-e2e.sh
EOF
  exit 1
}

export CLAUDE_BIN
echo "==> using claude binary: $CLAUDE_BIN"

# ── version pin (charter D67): assert the resolved binary IS the pinned CLI ───
# The pin lives in exactly ONE place — scripts/claude-pinned-version.txt — read
# by this script, claude-chat-nightly.sh, AND the :real_binary suite. We REFUSE
# on mismatch (never silent-skip): PATH decoys are real — the cmux wrapper is
# first on PATH and a stale npm-global 2.1.84 can shadow the intended binary, so
# a green run against the wrong version would be a lie about the wire contract.
PIN_FILE="$(dirname "$0")/claude-pinned-version.txt"
if [ ! -r "$PIN_FILE" ]; then
  echo "ERROR: version-pin file not found: $PIN_FILE" >&2
  exit 1
fi
PINNED_VERSION="$(tr -d '[:space:]' < "$PIN_FILE")"
# `claude --version` prints e.g. "2.1.206 (Claude Code)"; take the leading semver.
RAW_VERSION="$("$CLAUDE_BIN" --version 2>/dev/null)"
ACTUAL_VERSION="$(printf '%s\n' "$RAW_VERSION" | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
if [ "$ACTUAL_VERSION" != "$PINNED_VERSION" ]; then
  cat >&2 <<EOF
ERROR: claude version mismatch — refusing to run the wire harness.

  pinned (scripts/claude-pinned-version.txt): $PINNED_VERSION
  resolved ($CLAUDE_BIN):                     ${ACTUAL_VERSION:-<unparseable: '$RAW_VERSION'>}

The nightly smoke asserts the wire contract of ONE pinned CLI. A different
version could pass green while the frames it emits have quietly changed. PATH
decoys are real (cmux wrapper, stale npm-global 2.1.84) — point CLAUDE_BIN at the
pinned native install, or bump scripts/claude-pinned-version.txt deliberately
(and re-run the smoke) if you are upgrading on purpose.
EOF
  exit 1
fi
echo "==> version OK: $ACTUAL_VERSION (pinned $PINNED_VERSION)"
echo "==> this run spends real API budget (~\$0.43) and ~40s — Ctrl-C to abort"
echo

# --only real_binary flips on exactly the excluded tag (test_helper.exs default-
# excludes it); the single file keeps the run tight.
(cd api && MIX_ENV=test mix test --only real_binary \
  test/barkpark_web/studio/claude_chat_real_binary_test.exs)
