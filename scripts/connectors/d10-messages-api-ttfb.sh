#!/usr/bin/env bash
#
# d10-messages-api-ttfb.sh — D10 candidate (c) benchmark: plain Anthropic
# Messages-API TTFB (time to first streamed byte).
#
# Connectors epic, Wave 2, P1/D10. D10 is RATIFIED as the Vercel Sandbox
# (Firecracker microVM, snapshot + warm pool). Candidate (c) — the plain
# Anthropic Messages-API tool-loop — is RETAINED as a documented complement, not
# the primary: no shell, no VM, zero cold-start, naturally multi-tenant. It is
# the escape hatch if first-token latency ever blows the ~10s UX target (D10),
# at the cost of discarding claude_chat.ex's subprocess engine.
#
# The decisive number for candidate (c) is TTFB — time_starttransfer, how fast
# the FIRST streamed byte comes back — because there is no VM to boot, so TTFB
# IS the entire cold-start budget. This harness measures it against the EXACT
# endpoint the codebase already calls (judge.ex:27, titles.ex:42):
#
#     https://api.anthropic.com/v1/messages
#
# for two models, with stream:true and the SAME headers judge.ex/titles.ex send:
#
#     claude-3-5-haiku-latest   the floor — cheapest/fastest first token
#     claude-opus-4-8           judge.ex's prod model — the honest upper bound
#
# AUTH NOTE — candidate (a) vs candidate (c), do NOT conflate them:
# this endpoint authenticates with an x-api-key header (ANTHROPIC_API_KEY). The
# `claude` CLI's OAuth token (candidate (a), the subprocess shape D10 keeps as
# primary) is NOT a substitute here — that token authenticates the CLI's own
# session transport, not the raw /v1/messages API. A CLI OAuth token in
# x-api-key will 401. Candidate (c) needs a real Anthropic API key.
#
# KEY-GATED (distrust vacuous green): the curl runs ONLY when ANTHROPIC_API_KEY
# is set. With no key the script prints the EXACT command a human runs once a key
# exists and exits 0 — it never fabricates a TTFB number. No key is present in
# this shell or in guerrilla run-secrets today (bp secret ls = ingest_token
# only), so the honest headless state is "harness in place, number human-gated."
#
# USAGE:
#   scripts/connectors/d10-messages-api-ttfb.sh          # measure (needs ANTHROPIC_API_KEY), else print the key-gated command
#   scripts/connectors/d10-messages-api-ttfb.sh --check  # lint/print the plan, never touch the network
#   scripts/connectors/d10-messages-api-ttfb.sh --help
#
set -euo pipefail

# ── Constants — mirror judge.ex / titles.ex exactly ──────────────────────────
ENDPOINT="https://api.anthropic.com/v1/messages"
ANTHROPIC_VERSION="2023-06-01"   # judge.ex:29, titles.ex:43
MAX_TOKENS=16                    # tiny — TTFB is first-byte, not full completion
PROMPT="Say ok."

# Floor model + judge.ex's prod model (the honest upper bound).
MODELS=(
  "claude-3-5-haiku-latest"
  "claude-opus-4-8"
)

usage() {
  cat <<'EOF'
d10-messages-api-ttfb.sh — D10 candidate (c) TTFB benchmark (Anthropic Messages API)

  (no args)   Measure TTFB for each model. Requires ANTHROPIC_API_KEY; if unset,
              prints the exact key-required command and exits 0 (no fake number).
  --check     Lint and print the benchmark plan without calling the API.
  --help,-h   This help.

Endpoint : https://api.anthropic.com/v1/messages  (judge.ex:27 / titles.ex:42)
Auth     : x-api-key: $ANTHROPIC_API_KEY  (a claude CLI OAuth token will NOT work)
EOF
}

# The Anthropic Messages request body for one model, stream:true.
request_body() {
  local model="$1"
  printf '{"model":"%s","max_tokens":%s,"stream":true,"messages":[{"role":"user","content":"%s"}]}' \
    "$model" "$MAX_TOKENS" "$PROMPT"
}

# The exact, copy-pasteable command a human runs once a key exists. Prints
# $ANTHROPIC_API_KEY literally so the key is never echoed to the terminal.
print_key_gated_command() {
  local model="$1"
  cat <<EOF
curl -sS -N -o /dev/null \\
  -w 'TTFB=%{time_starttransfer}s  http=%{http_code}\\n' \\
  "${ENDPOINT}" \\
  -H "x-api-key: \$ANTHROPIC_API_KEY" \\
  -H "anthropic-version: ${ANTHROPIC_VERSION}" \\
  -H "content-type: application/json" \\
  -d '$(request_body "$model")'
EOF
}

# Measure one model. curl -N (unbuffered) + -w time_starttransfer is the TTFB;
# -o /dev/null discards the streamed body — we only want the first-byte clock.
measure_model() {
  local model="$1" out ttfb http
  if ! out=$(curl -sS -N -o /dev/null \
      -w '%{time_starttransfer} %{http_code}' \
      "${ENDPOINT}" \
      -H "x-api-key: ${ANTHROPIC_API_KEY}" \
      -H "anthropic-version: ${ANTHROPIC_VERSION}" \
      -H "content-type: application/json" \
      -d "$(request_body "$model")"); then
    printf '  %-26s curl FAILED (network/transport)\n' "$model" >&2
    return 1
  fi
  ttfb=${out% *}
  http=${out#* }
  printf '  %-26s TTFB=%ss  http=%s\n' "$model" "$ttfb" "$http"
  if [ "$http" != "200" ]; then
    printf '  %-26s ^ non-200: TTFB above is transport-only, NOT a valid model first-token\n' "" >&2
  fi
}

run_check() {
  echo "== D10 candidate (c) — Messages-API TTFB benchmark plan =="
  echo "endpoint          : ${ENDPOINT}"
  echo "anthropic-version : ${ANTHROPIC_VERSION}"
  echo "metric            : curl -w time_starttransfer (TTFB, stream:true)"
  echo "max_tokens        : ${MAX_TOKENS}  (first-byte, not full completion)"
  echo "models            : ${MODELS[*]}"
  if command -v curl >/dev/null 2>&1; then
    echo "curl              : $(command -v curl)"
  else
    echo "curl              : MISSING — install curl before running the benchmark" >&2
  fi
  if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    echo "ANTHROPIC_API_KEY : set — a plain run will measure real TTFB"
  else
    echo "ANTHROPIC_API_KEY : UNSET — a plain run prints the key-gated command (no fake number)"
  fi
  echo
  echo "-- request bodies --"
  local model
  for model in "${MODELS[@]}"; do
    echo "  ${model}: $(request_body "$model")"
  done
  echo
  echo "auth note: x-api-key only. The claude CLI OAuth token (candidate a) is"
  echo "           NOT accepted by /v1/messages — do not conflate a and c."
}

run_benchmark() {
  if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    echo "ANTHROPIC_API_KEY is not set — cannot measure TTFB without fabricating a number."
    echo "Run this once a real Anthropic API key is exported (NOT a claude CLI OAuth token):"
    echo
    echo "  export ANTHROPIC_API_KEY=sk-ant-..."
    echo
    local model
    for model in "${MODELS[@]}"; do
      echo "# ${model}"
      print_key_gated_command "$model"
      echo
    done
    exit 0
  fi

  echo "== D10 candidate (c) — Messages-API TTFB (${ENDPOINT}) =="
  local model rc=0
  for model in "${MODELS[@]}"; do
    measure_model "$model" || rc=1
  done
  return "$rc"
}

main() {
  case "${1:-}" in
    --check)     run_check ;;
    -h|--help)   usage ;;
    "")          run_benchmark ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
