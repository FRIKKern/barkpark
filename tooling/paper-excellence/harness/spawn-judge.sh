#!/usr/bin/env bash
# spawn-judge.sh — launch a bare grading agent to score a captured cold-run
# transcript against the FROZEN RUBRIC.md. It is the sibling of spawn-cold.sh
# and exists for ONE reason: the model+effort pin must not DRIFT.
#
#   ANTHROPIC_API_KEY=sk-... \
#     bash tooling/paper-excellence/harness/spawn-judge.sh <prompt-file> [transcript-out]
#
# RUBRIC L190 freezes opus@medium for the author AND both judges. spawn-cold.sh
# pins that as two flags (--model opus / --effort medium) because the CLI carries
# effort SEPARATELY from --model (--model opus@medium is not a valid token — it
# emits unrecognized_model and silently falls back). A judge that re-typed the
# pin could drift out of freeze, so this script does NOT re-declare it: it
# SOURCES the SAME COLD_MODEL/COLD_EFFORT default lines straight out of
# spawn-cold.sh — one pin source, drift-proof by construction.
#
# Unlike spawn-cold.sh this is minimal: no env -i / scratch-HOME hermetic
# machinery. Per ruling R7 on pe-bl-cold-agent-run judges are in-session-
# permitted; the coldness protocol guards the AUTHOR, not the grader. All this
# script guarantees is the frozen two-flag pin, a prompt read from a file, and a
# stream-json transcript written to a caller-named path.
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROMPT_FILE="${1:?usage: spawn-judge.sh <prompt-file> [transcript-out]}"
[ -f "$PROMPT_FILE" ] || { echo "spawn-judge: no prompt file at $PROMPT_FILE" >&2; exit 2; }
TRANSCRIPT="${2:-${JUDGE_TRANSCRIPT:-${TMPDIR:-/tmp}/pe-judge/transcript.jsonl}}"

if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  echo "spawn-judge: FAIL — ANTHROPIC_API_KEY is not set (the grader needs a key)." >&2
  exit 3
fi

CLAUDE_BIN="${CLAUDE_BIN:-/Users/pelle/.local/bin/claude}"
[ -x "$CLAUDE_BIN" ] || { echo "spawn-judge: no claude binary at $CLAUDE_BIN (set CLAUDE_BIN)" >&2; exit 2; }

# --- The one pin source: inherit spawn-cold.sh's COLD_MODEL/COLD_EFFORT --------
# eval only the two `COLD_MODEL=`/`COLD_EFFORT=` default lines from the sibling
# script — never re-typed here, so the frozen opus@medium pin cannot drift. Both
# lines honor env overrides (${COLD_MODEL:-opus} / ${COLD_EFFORT:-medium}).
COLD_SOURCE="$HARNESS_DIR/spawn-cold.sh"
[ -f "$COLD_SOURCE" ] || { echo "spawn-judge: no pin source at $COLD_SOURCE" >&2; exit 2; }
eval "$(grep -E '^COLD_(MODEL|EFFORT)=' "$COLD_SOURCE")"
# Fail LOUD if the pin lines moved: a refactor that indents or renames them in
# spawn-cold.sh must break this script here, with a named cause — never later
# as a bare `unbound variable`, and never a silent fallback.
[ -n "${COLD_MODEL:-}" ] && [ -n "${COLD_EFFORT:-}" ] || {
  echo "spawn-judge: FAIL — could not extract the COLD_MODEL/COLD_EFFORT pin lines from $COLD_SOURCE (did a refactor move or rename them?)" >&2
  exit 2
}

mkdir -p "$(dirname "$TRANSCRIPT")"
PROMPT="$(cat "$PROMPT_FILE")"

echo "spawn-judge: model=$COLD_MODEL  effort=$COLD_EFFORT  transcript=$TRANSCRIPT" >&2

set +e
"$CLAUDE_BIN" --bare --setting-sources '' --model "$COLD_MODEL" --effort "$COLD_EFFORT" \
  -p "$PROMPT" --output-format stream-json --verbose > "$TRANSCRIPT" 2>"$TRANSCRIPT.err"
RC=$?
set -e

echo "spawn-judge: claude exited $RC — transcript at $TRANSCRIPT ($(wc -l <"$TRANSCRIPT" | tr -d ' ') lines)" >&2
exit "$RC"
