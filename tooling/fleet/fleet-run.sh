#!/bin/bash
# fleet-run.sh — PROVIDER-NEUTRAL Personal Dev Fleet listener/runner.
# ANY headless AI agent becomes a fleet worker: the ONLY provider-specific thing is the
# one-line exec adapter below. Everything else (listen, claim, fence, stamp, close) is bp.
#
#   FLEET_AGENT=claude  bash fleet-run.sh listen <worker>     # stay-alive loop (Claude Code)
#   FLEET_AGENT=codex   bash fleet-run.sh listen <worker>     # stay-alive loop (OpenAI Codex)
#   FLEET_AGENT=custom  FLEET_AGENT_EXEC='myagent --prompt {{PROMPT}}' bash fleet-run.sh listen <worker>
#   FLEET_AGENT=codex   bash fleet-run.sh once <task-id> <worker>   # run a single dispatched order
#
# Orders are bp tasks routed by `assignee`. Scope (workspace/project/dataset) is whatever
# `bp use` is set to — the same ledger every fleet member shares. No message bus, no local queue.
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
MODE="${1:?mode: listen|once}"; shift
FLEET_AGENT="${FLEET_AGENT:-claude}"
say(){ printf '%s [%s/%s] %s\n' "$(date +%H:%M:%S)" "${WORKER:-?}" "$FLEET_AGENT" "$*"; }

# ---- THE ONE PROVIDER-SPECIFIC SEAM: run a headless agent turn on a prompt ----
agent_exec(){ # $1 = prompt ; must run to completion IN-TURN and exit
  local P="$1"
  case "$FLEET_AGENT" in
    claude) claude -p "$P" --model "${FLEET_MODEL:-sonnet}" --dangerously-skip-permissions ;;
    codex)  codex exec --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check "$P" ;;
    custom) eval "${FLEET_AGENT_EXEC:?set FLEET_AGENT_EXEC with {{PROMPT}}}" ;;   # {{PROMPT}} via env below
    *) echo "unknown FLEET_AGENT: $FLEET_AGENT" >&2; return 2 ;;
  esac
}

field(){ bp task get "$1" -o json 2>/dev/null | python3 -c "
import sys,json,re
d=json.load(sys.stdin).get('doc') or {}; c=d.get('claim') or {}; ct=d.get('content') or {}
ac=ct.get('acceptance_criteria') or []
brief=''.join(n.get('value','') for bl in (ct.get('brief') or {}).get('blocks',[]) for n in (bl.get('content') or []))
m=re.search(r'FENCE:\s*([^\s.,]+)', brief)
print({'life':d.get('lifecycle_status'),'holder':c.get('worker') or '','epoch':c.get('epoch'),
 'fence':(m.group(1) if m else 'fleet/'+'$1'),'brief':brief,'ctext':(ac[0].get('criterion') if ac else '')}.get('$2',''))"; }

do_order(){ # $1 = task id
  local ID="$1"
  local LIFE HOLDER FENCE BRIEF CTEXT
  LIFE=$(field "$ID" life); HOLDER=$(field "$ID" holder); FENCE=$(field "$ID" fence)
  BRIEF=$(field "$ID" brief); CTEXT=$(field "$ID" ctext)
  { [ "$LIFE" != "open" ] || [ -n "$HOLDER" ]; } && { say "skip $ID (life=$LIFE holder=$HOLDER)"; return 0; }
  local R; R=$(bp task claim "$ID" "$WORKER" --resources "$FENCE" --yes -o json 2>&1)
  echo "$R" | grep -q resource_conflict && { say "⛔ REFUSED $ID (fence $FENCE held) — stand down"; return 0; }
  echo "$R" | grep -q '"error"' && { say "claim error $ID: $(echo "$R"|head -c 100)"; return 0; }
  say "✅ CLAIMED $ID (fence $FENCE) — running $FLEET_AGENT on the brief"
  bp task pulse "$ID" "$WORKER" --now "executing $ID via $FLEET_AGENT" --yes >/dev/null 2>&1
  bp fleet beat "$WORKER" --status working --ttl 30 --agent "$FLEET_AGENT" -o json >/dev/null 2>&1 || true
  local D="/tmp/fleet-run/$ID-$WORKER"; rm -rf "$D"; mkdir -p "$D"; ( cd "$D" || exit
    export FLEET_PROMPT
    FLEET_PROMPT="You are fleet worker '$WORKER' (agent: $FLEET_AGENT). Execute this ORDER exactly and completely IN THIS TURN. Create any file it names at the EXACT absolute path given. Do NOT background the work or spawn anything that outlives this turn. Be correct and rigorous. ORDER: $BRIEF"
    agent_exec "$FLEET_PROMPT" > claude.log 2>&1 )
  local E; E=$(field "$ID" epoch)
  bp task stamp "$ID" "$WORKER" "$E" --criterion 0 --met --evidence "worker $WORKER executed the order via $FLEET_AGENT (headless); artifact at the path named in the brief" --criterion-text "$CTEXT" --yes >/dev/null 2>&1
  E=$(field "$ID" epoch)
  bp task close "$ID" "$WORKER" "$E" --yes >/dev/null 2>&1
  bp fleet beat "$WORKER" --status idle --ttl 30 --agent "$FLEET_AGENT" -o json >/dev/null 2>&1 || true
  say "🏁 CLOSED $ID (fence released) — done"
}

case "$MODE" in
  once)  ID="${1:?task-id}"; WORKER="${2:?worker}"; do_order "$ID" ;;
  listen)
    WORKER="${1:?worker}"
    say "listener online in $(bp use 2>/dev/null | python3 -c "import sys,json;a=json.load(sys.stdin)['active'];print(a['workspace']+'/'+a['project']+'/'+a['dataset'])" 2>/dev/null) — waiting for orders"
    # Native presence: register + declare idle (ttl_s 30 — the bash runner beats every ~6s tick,
    # so a stale row means the loop itself died, PDF-D22). NEVER '--worker' (exits 2, swallowed by
    # || true = a beat into the void). The beat shares fate with this foreground loop — no sidecar.
    bp fleet beat "$WORKER" --status idle --ttl 30 --agent "$FLEET_AGENT" -o json >/dev/null 2>&1 || true
    declare -A seen
    while true; do
      for ID in $(bp task ready -o json 2>/dev/null | python3 -c "import sys,json;[print(d['doc_id']) for d in json.load(sys.stdin).get('docs',[]) if d.get('assignee')=='$WORKER']" 2>/dev/null); do
        [ -n "${seen[$ID]:-}" ] && continue; seen[$ID]=1; do_order "$ID"
      done
      # idle beat every poll cycle — keeps the row ONLINE while parked, dies with the loop.
      bp fleet beat "$WORKER" --status idle --ttl 30 --agent "$FLEET_AGENT" -o json >/dev/null 2>&1 || true
      sleep 6
    done ;;
  *) echo "usage: fleet-run.sh listen <worker> | once <task-id> <worker>" >&2; exit 2 ;;
esac
