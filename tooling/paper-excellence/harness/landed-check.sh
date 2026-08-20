#!/usr/bin/env bash
# landed-check.sh — has a paper slug LANDED on the live server? (D47)
#
#   bash tooling/paper-excellence/harness/landed-check.sh [slug]
#
# The cold run consumes the SERVER-published guide and produces a published
# paper; this check answers "is <slug> present on guerrilla yet?" without a
# read verb, so it can run before the store even has a document to GET.
#
# The probe is the bulldocs sync arm (D47, proven in the wave-7 verify round):
#
#   POST /v1/plugins/bulldocs/papers/<slug>/sync   { "bpml": <valid <paper>>, "baseRev": "1" }
#
# Order of the server's guards, each proven live:
#   * a MARKDOWN / hand-rolled body 500s BEFORE the existence arm, so the body
#     MUST be valid BPML (known tags only: h1, p, …) to reach the verdict;
#   * an ABSENT slug returns  {"error":{"code":"not_found", …}}  — NOT landed;
#   * a PRESENT slug returns  precondition_failed (rev drift) or a success body
#     — either way the string "not_found" is absent — LANDED.
#
# So the verdict is a grep for the code, never an HTTP status (a 200 sync body
# and a 412 both mean the paper exists):
#
#   not_found present  -> exit 1  (NOT landed)
#   not_found absent   -> exit 0  (landed)
#
# The DEFAULT slug is the cold run's product, which is deliberately absent until
# the run publishes it — so a bare invocation exits 1 and the harness gate
# (`landed-check.sh; test $? -eq 1`) proves the not-landed arm fires. Once the
# cold run pushes its paper, the same command flips to exit 0.
set -euo pipefail

SLUG="${1:-${LANDED_SLUG:-pe-w7-cold-run-paper}}"

# Server + token from the bp config (the harness never hard-codes either).
BP_CONFIG="${BARKPARK_CONFIG:-$HOME/.config/barkpark/config.json}"
if [ -n "${BARKPARK_SERVER:-}" ] && [ -n "${BARKPARK_TOKEN:-}" ]; then
  SERVER="$BARKPARK_SERVER"
  TOKEN="$BARKPARK_TOKEN"
elif [ -f "$BP_CONFIG" ]; then
  SERVER="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["server"])' "$BP_CONFIG")"
  TOKEN="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["token"])' "$BP_CONFIG")"
else
  echo "landed-check: FAIL — no bp config at $BP_CONFIG and BARKPARK_SERVER/TOKEN unset" >&2
  exit 2
fi
SERVER="${SERVER%/}"

# A minimal VALID BPML paper — enough to clear the parser and reach the
# existence arm. Never markdown: markdown 500s before the verdict.
PAYLOAD='{"bpml":"<paper><h1>landed-check probe</h1><p>existence probe, not a real edit</p></paper>","baseRev":"1"}'

BODY="$(curl -s -X POST "$SERVER/v1/plugins/bulldocs/papers/$SLUG/sync" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD")"

if printf '%s' "$BODY" | grep -q '"code":"not_found"'; then
  echo "landed-check: NOT landed — $SLUG absent on $SERVER (exit 1)"
  exit 1
fi

echo "landed-check: LANDED — $SLUG present on $SERVER (exit 0)"
exit 0
