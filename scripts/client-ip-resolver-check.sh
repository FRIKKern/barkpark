#!/usr/bin/env bash
# client-ip-resolver-check.sh — ONE trust boundary decides who the client is.
#
# THE DEFECT THIS RATCHETS
# ------------------------
# `Barkpark.RateLimiter.client_ip/1` carries the canonical-capability marker for
# `rate-limit-client-ip`, whose aka: list names `client_ip` and `x-forwarded-for`
# precisely so that someone typing `grep client_ip` lands on the right one. (The
# marker string itself is NOT spelled out here: `docs-anchors-check.sh` §8 greps
# the corpus for it and would count this comment as a second, duplicate marker.)
# It
# walks `x-forwarded-for` RIGHT-to-left past trusted hops and falls back to the
# verified peer.
#
# Five modules typed `client_ip` anyway and wrote their own one-liner:
#
#     defp client_ip(conn), do: conn.remote_ip |> :inet.ntoa() |> to_string()
#
# Behind the co-located Caddy (`reverse_proxy localhost:4000`) that is ALWAYS
# the loopback hop, so every `user_sessions.ip_address` row recorded 127.0.0.1
# and the login audit trail could not tell one actor from another. It failed
# SILENTLY and looked correct: populated column, well-formed address, no error.
#
# A marker nobody follows is decoration. This is the tripwire that makes it
# load-bearing.
#
# THE RULE, STATED SO A READER CAN PREDICT IT
# -------------------------------------------
# Inside `api/lib`, executable code may read `remote_ip` off a conn in EXACTLY
# ONE file: `api/lib/barkpark/rate_limiter.ex`. Everywhere else it must go
# through the canonical resolver. Two forms are matched:
#
#     conn.remote_ip                 # the direct read
#     %Plug.Conn{remote_ip: ...}     # the destructuring read
#
# ZERO IS THE BASELINE, NOT A RATCHET FROM A COUNT. Unlike the never-worse
# gates in this tree, the offending sites are all removed by the change that
# introduces this script, so demanding zero cannot red main on day one. If that
# ever stops being true the honest move is to fix the site, not to widen this.
#
# WHY BACKTICKS ARE EXEMPT, AND WHY THAT IS NOT A HOLE
# ----------------------------------------------------
# Half the mentions of `conn.remote_ip` in this tree are PROSE — moduledocs and
# comments explaining exactly why you must not read it (`plugs/rate_limit.ex`,
# `plugs/require_loopback.ex`, `plugs/auth_write_rate_limit.ex`). Those are the
# documentation that routes the next author correctly; deleting them to please a
# grep would be strictly worse. This repo writes code identifiers in prose inside
# backticks, so a mention wrapped in backticks is documentation and a bare one is
# code. Elixir has no backtick operator, so real code can never hide behind that
# exemption — the escape is unreachable rather than merely unlikely. Lines whose
# first non-space character is `#` are skipped for the same reason.
#
# Usage:
#   scripts/client-ip-resolver-check.sh            # check (CI + gate)
#   scripts/client-ip-resolver-check.sh --selftest # prove the gate CAN fail
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Overridable so --selftest drives a synthetic tree in a temp dir and plants
# nothing in the real source.
SCANDIR="${CLIENT_IP_SCANDIR:-$ROOT/api/lib}"
ALLOWED="${CLIENT_IP_ALLOWED:-barkpark/rate_limiter.ex}"

# Emit `path:line:text` for every executable read of a conn's remote_ip outside
# the one file allowed to have it. Prints nothing when the tree is clean.
scan() {
  local dir="$1" allowed="$2"

  [ -d "$dir" ] || {
    echo "client-ip-resolver-check: $dir does not exist — REFUSING." >&2
    echo "  A scanner that reports a clean tree it never read is the failure" >&2
    echo "  this gate exists to prevent." >&2
    exit 3
  }

  # -r over the directory rather than a find|xargs pipeline: under `set -o
  # pipefail` a reader that exits early turns SIGPIPE into exit 141 and the gate
  # lies green under load.
  local hits
  hits="$(grep -rn --include='*.ex' --include='*.exs' -E 'conn\.remote_ip|%Plug\.Conn\{[^}]*remote_ip:' "$dir" || true)"

  [ -n "$hits" ] || return 0

  printf '%s\n' "$hits" | awk -v allowed="$allowed" -F: '
    {
      path = $1
      line = $2
      # Rebuild the source text: it may itself contain colons.
      text = $0
      sub(/^[^:]*:[^:]*:/, "", text)

      if (index(path, allowed) > 0) next          # the canonical resolver

      stripped = text
      sub(/^[ \t]*/, "", stripped)
      if (substr(stripped, 1, 1) == "#") next     # a comment explaining the rule

      # Documentation prose writes identifiers in backticks; Elixir code cannot.
      if (text ~ /`[^`]*remote_ip[^`]*`/) next

      printf "%s:%s:%s\n", path, line, stripped
    }'
}

selftest() {
  local tmp
  tmp="$(mktemp -d)"
  # Expanded at trap-SET time, not at trap-FIRE time: `tmp` is function-local and
  # is already out of scope when EXIT runs, so the deferred form dies on
  # `unbound variable` under `set -u` AFTER printing a pass — an exit code that
  # contradicts the verdict printed above it.
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" EXIT

  mkdir -p "$tmp/barkpark"

  # The canonical resolver: allowed, must NOT be reported.
  cat >"$tmp/barkpark/rate_limiter.ex" <<'CANON'
defmodule Fake.RateLimiter do
  def client_ip(%Plug.Conn{remote_ip: peer} = conn), do: {peer, conn}
end
CANON

  # Prose and comments: must NOT be reported, or the gate's own cost is a tree
  # stripped of the documentation that routes the next author correctly.
  cat >"$tmp/barkpark/prose.ex" <<'PROSE'
defmodule Fake.Prose do
  @moduledoc """
  Resolve through the canonical resolver — never `conn.remote_ip`, which behind
  the co-located Caddy is ALWAYS loopback.
  """
  # Do not read conn.remote_ip here; see the moduledoc.
  def noop, do: :ok
end
PROSE

  local clean
  clean="$(scan "$tmp" "barkpark/rate_limiter.ex")"
  if [ -n "$clean" ]; then
    echo "client-ip-resolver-check --selftest FAILED: a clean tree was reported dirty." >&2
    printf '%s\n' "$clean" >&2
    exit 1
  fi

  # Now plant the exact defect, in the exact words of the code this replaced.
  cat >"$tmp/barkpark/offender.ex" <<'BAD'
defmodule Fake.Offender do
  defp client_ip(conn), do: conn.remote_ip |> :inet.ntoa() |> to_string()
end
BAD

  local dirty
  dirty="$(scan "$tmp" "barkpark/rate_limiter.ex")"
  case "$dirty" in
    *offender.ex*) ;;
    *)
      echo "client-ip-resolver-check --selftest FAILED: the planted defect was NOT caught." >&2
      echo "  A gate that stays green when the defect is put back is not a gate." >&2
      exit 1
      ;;
  esac

  echo "client-ip-resolver-check --selftest: OK (clean tree passes, planted defect reds)."
}

case "${1:-}" in
  --selftest)
    selftest
    exit 0
    ;;
  "") ;;
  *)
    echo "client-ip-resolver-check: unknown argument '$1'." >&2
    exit 2
    ;;
esac

violations="$(scan "$SCANDIR" "$ALLOWED")"

if [ -n "$violations" ]; then
  echo "::error::client-ip-resolver-check: a conn's remote_ip is read outside the canonical resolver." >&2
  echo >&2
  printf '%s\n' "$violations" >&2
  echo >&2
  echo "Behind the co-located Caddy, conn.remote_ip is ALWAYS the loopback hop." >&2
  echo "Reading it directly records the PROXY, not the actor — a value that is" >&2
  echo "populated, well-formed, and identical for every user on the box." >&2
  echo >&2
  echo "Use the canonical resolver instead:" >&2
  echo "    Barkpark.RateLimiter.client_ip/1              # the address" >&2
  echo "    Barkpark.RateLimiter.client_ip_with_source/1  # {address, :forwarded | :peer}" >&2
  echo >&2
  echo "It walks x-forwarded-for right-to-left past trusted hops and falls back" >&2
  echo "to the verified peer, so a direct caller can never forge what gets" >&2
  echo "recorded. Do NOT read the header's leftmost value yourself: that swaps a" >&2
  echo "useless-but-honest value for a forgeable one, which is worse, because it" >&2
  echo "will be believed." >&2
  exit 1
fi

echo "client-ip-resolver-check: OK — no conn.remote_ip read outside $ALLOWED."
