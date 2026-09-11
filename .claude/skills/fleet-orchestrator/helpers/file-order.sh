#!/bin/bash
# file-order.sh <id> <title> <assignee> <brief_text> <criterion>
# Files a fleet order as a published bp task routed to <assignee>, with a per-order-unique
# fence (pocfence/<id>), surviving every task-authoring trap the live PoC hit:
#   - priority must be 0..4        - brief must be a blocks map (not a string)
#   - dedup wall at create + publish (retries with the reported duplicate_of)
#   - fence bug: unique fence per id so a dead order never deadlocks a live one
# Requires: bp on PATH, ~/.config/barkpark/config.json with a token, python3, curl.
set -euo pipefail
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
ID="${1:?id}"; TITLE="${2:?title}"; WHO="${3:?assignee}"; BRIEF="${4:?brief}"; CRIT="${5:?criterion}"
# Target resolution: a BP_FLEET_* env var wins when set (points file-order.sh at a
# scratch or secondary instance without touching bp whoami), else fall back to the
# byte-unchanged bp-whoami / config.json path below.
SERVER="${BP_FLEET_SERVER:-$(bp whoami -o json 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin).get('server','https://guerrilla.barkpark.cloud'))")}"
DS="${BP_FLEET_DATASET:-$(bp whoami -o json 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin).get('dataset','production'))")}"
TOK="${BP_FLEET_TOKEN:-$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.config/barkpark/config.json')))['token'])")}"
IDX="${FLEET_ORDER_INDEX:-/tmp/fleet-orders.index}"

# The mutate POST below rides scripts/lib/bp-curl.sh so a 429 from the ledger is
# a bounded, Retry-After-honouring retry instead of a rate-limit envelope parsed
# as if it were a mutation result. The old `curl -sS` was class C: the status was
# discarded before any branch existed, so a 429 body fell through to the
# `"results"` grep and surfaced as CREATE_FAILED.
BP_CURL_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../../scripts/lib/bp-curl.sh"
if [ ! -f "$BP_CURL_LIB" ]; then
  echo "CANNOT RUN: $BP_CURL_LIB is missing — this helper needs the repo's bp-curl library" >&2
  echo "            for its 429 handling, and will not fall back to a bare curl." >&2
  exit 1
fi
# shellcheck source=../../../../scripts/lib/bp-curl.sh disable=SC1091
. "$BP_CURL_LIB"

build() { # $1 = optional extra distinct id to fence off
python3 - "$ID" "$TITLE" "$WHO" "$BRIEF" "$CRIT" "${1:-}" "$IDX" <<'PY'
import sys, json, os
i,t,w,b,c,extra,idx = sys.argv[1:8]
known = []
if os.path.exists(idx): known += [l.strip() for l in open(idx) if l.strip()]
if extra: known.append(extra)
h = sum(ord(ch) for ch in i)
brief = f"FENCE: pocfence/{i}. " + b
doc = {"_id": i, "_type": "task", "title": f"{t} [{i}]", "kind": "task",
       "lifecycle_status": "open", "priority": 4, "assignee": w,
       "distinct_from": list(dict.fromkeys(known)),
       "description": f"Fleet order {i} for {w}. " + b[:130],
       "brief": {"blocks": [{"id": "b1", "type": "paragraph",
                 "content": [{"type": "text", "value": brief}]}]},
       "acceptance_criteria": [{"criterion": c, "met": False, "evidence": ""}],
       "tags": [{"tag": "fleet", "strength": 30 + (h % 40),
                 "rationale": f"Orchestrator-cut fleet order {i} routed to {w}."},
                {"tag": "worker", "strength": 5 + (h % 20),
                 "rationale": f"One slice of a decomposed wish, executed by a fleet listener."}]}
print(json.dumps({"mutations": [{"createOrReplace": doc}]}))
PY
}
# submit: POST the mutation, print the response BODY on stdout, and leave the
# HTTP status in $CODEF for the caller to branch on.
#
# bp_curl_code, NOT bp_curl_body, ON PURPOSE. The dedup wall answers HTTP 409
# (api/lib/barkpark/content/errors.ex: duplicate_task => status: 409) and the
# retry below PARSES THAT 409 BODY to recover the duplicate id. bp_curl_body
# withholds a non-2xx body by contract (empty stdout, exit 22), which would have
# silently killed the dedup retry this helper exists for. bp_curl_code hands us
# the status while `-o` keeps the body for EVERY status — which is exactly
# "the status captured before any branch", with no body lost.
#
# The helper narrates its 429 backoff on STDERR; stdout stays pure body, so the
# greps below never see it. submit() runs inside `$( … )` — a subshell — so the
# status travels through a FILE, not a variable the parent would never see.
CODEF="$(mktemp "${TMPDIR:-/tmp}/fleet-order-code.XXXXXX")"
BODYF="$(mktemp "${TMPDIR:-/tmp}/fleet-order-body.XXXXXX")"
trap 'rm -f "$CODEF" "$BODYF"' EXIT
submit(){
  local code
  code="$(bp_curl_code -sS -o "$BODYF" -X POST "$SERVER/v1/data/mutate/$DS" \
            -H "Authorization: Bearer $TOK" -H "Content-Type: application/json" -d @-)" || code=""
  printf '%s' "${code:-000}" > "$CODEF"
  cat "$BODYF"
}

R=$(build "" | submit)
if echo "$R" | grep -q duplicate_task; then
  DUP=$(echo "$R" | python3 -c "import sys,re;t=sys.stdin.read();m=re.search(r'([a-z0-9]+(?:-[a-z0-9]+){2,})', t.split('duplicate',1)[1] if 'duplicate' in t else '');print(m.group(1) if m else '')" 2>/dev/null || true)
  R=$(build "$DUP" | submit)
fi
CODE="$(cat "$CODEF" 2>/dev/null || true)"
case "$CODE" in
  2??) : ;;
  429) echo "RATE_LIMITED: the ledger is rate limiting this client (HTTP 429 survived bp-curl's bounded retry) — backpressure, not a fault; re-run this order later"; exit 1 ;;
  000|"") echo "CREATE_FAILED: no HTTP response from $SERVER (transport failure)"; exit 1 ;;
  *) echo "CREATE_FAILED: HTTP $CODE: $(echo "$R" | head -c 200)"; exit 1 ;;
esac
echo "$R" | grep -q '"results"' || { echo "CREATE_FAILED: $(echo "$R" | head -c 200)"; exit 1; }
OUT=$(bp doc publish task "$ID" 2>&1 || true)
echo "$OUT" | grep -q "rev:" || { echo "PUBLISH_FAILED: $(echo "$OUT" | head -c 160)"; exit 1; }
echo "$ID" >> "$IDX"
echo "FILED $ID (fence pocfence/$ID -> $WHO)"
