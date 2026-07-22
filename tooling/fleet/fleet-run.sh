#!/bin/bash
# fleet-run.sh — PROVIDER-NEUTRAL Personal Dev Fleet listener/runner.
# ANY headless AI agent becomes a fleet worker: the ONLY provider-specific thing is the
# one-line exec adapter below. Everything else (listen, claim, fence, stamp, close) is bp.
#
#   FLEET_AGENT=claude  bash fleet-run.sh listen <worker>     # stay-alive loop (Claude Code)
#   FLEET_AGENT=codex   bash fleet-run.sh listen <worker>     # stay-alive loop (OpenAI Codex)
#   FLEET_AGENT=custom  FLEET_AGENT_EXEC='myagent --prompt {{PROMPT}}' bash fleet-run.sh listen <worker>
#   FLEET_AGENT=codex   bash fleet-run.sh once <task-id> <worker>   # run a single dispatched order
#   bash fleet-run.sh capacity                                     # print the MEASURED capacity JSON
#
# Orders are bp tasks routed by `assignee`. Scope (workspace/project/dataset) is whatever
# `bp use` is set to — the same ledger every fleet member shares. No message bus, no local queue.
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
MODE="${1:?mode: listen|once}"; shift
FLEET_AGENT="${FLEET_AGENT:-claude}"
say(){ printf '%s [%s/%s] %s\n' "$(date +%H:%M:%S)" "${WORKER:-?}" "$FLEET_AGENT" "$*"; }

# ---- THE ONE PROVIDER-SPECIFIC SEAM: run a headless agent turn on a prompt ----
# The claude/codex adapters emit structured cost/token telemetry (--output-format json /
# --json) so record_spend can meter the run into the ledger. The turn still runs to completion
# in-turn; the JSON is just the run's receipt, captured to the log and parsed after.
agent_exec(){ # $1 = prompt ; must run to completion IN-TURN and exit
  local P="$1"
  case "$FLEET_AGENT" in
    claude) claude -p "$P" --model "${FLEET_MODEL:-sonnet}" --output-format json --dangerously-skip-permissions ;;
    codex)  codex exec --json --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check "$P" ;;
    custom) eval "${FLEET_AGENT_EXEC:?set FLEET_AGENT_EXEC with {{PROMPT}}}" ;;   # {{PROMPT}} via env below
    *) echo "unknown FLEET_AGENT: $FLEET_AGENT" >&2; return 2 ;;
  esac
}

# ============================ MEASURED CAPACITY (PDF-D36/D37) ============================
# Everything a listener advertises about itself is MEASURED, never vibed: size class from real
# RAM, slots from the loop's own control-flow, budget from an append-only spend ledger. No new
# processes, no sidecars (PDF-D22) — this is arithmetic the foreground loop already runs.
CLASS_COST_light=1; CLASS_COST_standard=4; CLASS_COST_heavy=12; CLASS_COST_xl=30
class_rank(){ case "$1" in light) echo 1;; standard) echo 2;; heavy) echo 3;; xl) echo 4;; *) echo 4;; esac; }
rank_class(){ case "$1" in 1) echo light;; 2) echo standard;; 3) echo heavy;; *) echo xl;; esac; }

# Effective size class = min(observed-from-RAM, FLEET_MAX_CLASS ceiling), clamped AT THE EDGE
# (PDF-D6/D36). TOTAL RAM only — Darwin has no nproc, so branch by uname. Inclusive thresholds:
# light RAM<4, standard 4<=RAM<16, heavy 16<=RAM<64, xl RAM>=64 GiB (a 16.0-GiB box is heavy).
measure_size_class(){
  local bytes=""
  case "$(uname)" in
    Darwin) bytes=$(sysctl -n hw.memsize 2>/dev/null) ;;
    *)      bytes=$(awk '/^MemTotal:/{print $2*1024}' /proc/meminfo 2>/dev/null) ;;
  esac
  local observed="standard"                                    # honest fallback if a probe fails
  case "$bytes" in
    ''|*[!0-9]*) observed="standard" ;;                        # non-numeric → keep the safe default
    *) if   [ "$bytes" -lt 4294967296  ]; then observed="light"     # <  4 GiB
       elif [ "$bytes" -lt 17179869184 ]; then observed="standard"  # 4..<16 GiB
       elif [ "$bytes" -lt 68719476736 ]; then observed="heavy"     # 16..<64 GiB
       else                                    observed="xl"        # >= 64 GiB
       fi ;;
  esac
  local ceil="${FLEET_MAX_CLASS:-xl}" orank crank                # ceiling clamp (min at the edge)
  orank=$(class_rank "$observed"); crank=$(class_rank "$ceil")
  [ "$crank" -lt "$orank" ] && orank="$crank"
  rank_class "$orank"
}

ledger_path(){ echo "${FLEET_HOME:-$HOME/.barkpark-fleet}/${WORKER}/spend.jsonl"; }

# budget field = FLEET_SPEND_CAP - sum(ledger cost_usd), re-read every beat. Uncapped or no worker
# ⇒ empty (route.py then treats budget as unbounded). A MALFORMED ledger line is a loud abort
# (exit 3) — never coerce a corrupt ledger to a number, because that silently lies about spend.
measure_budget(){
  { [ -n "${FLEET_SPEND_CAP:-}" ] && [ -n "${WORKER:-}" ]; } || { echo ""; return 0; }
  local f; f=$(ledger_path)
  python3 - "$f" "$FLEET_SPEND_CAP" <<'PY'
import sys, json, os
f, cap = sys.argv[1], float(sys.argv[2])
tot = 0.0
if os.path.exists(f):
    with open(f, encoding="utf-8") as fh:
        for i, line in enumerate(fh, 1):
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except Exception:
                sys.stderr.write("fleet: FATAL malformed spend-ledger line %d in %s — budget aborted, refusing to coerce\n" % (i, f))
                sys.exit(3)
            c = row.get("cost_usd")
            if c is None:
                continue
            try:
                tot += float(c)
            except Exception:
                sys.stderr.write("fleet: FATAL non-numeric cost_usd on line %d in %s\n" % (i, f))
                sys.exit(3)
# Budget FLOORS at 0 (the protocol's documented behavior): overspend past the cap
# would otherwise emit a NEGATIVE budget, which the server's capacity contract
# (budget >= 0, PDF-D34) refuses with 422 — and the `|| true` on the beat would
# swallow that, flipping the listener OFFLINE silently at the exact moment the
# cap trips. 0 and negative route identically (route.py refuses budget < cost),
# so the floor loses nothing and keeps presence alive through a tripped cap.
print(round(max(cap - tot, 0.0), 6))
PY
}

# The advertised capacity envelope. $1 = slots_free (0 mid-order, 1 idle). size_class + slots are
# always present; budget appears only when a cap is set. Malformed ledger propagates exit 3.
capacity_json(){
  local sf="${1:-1}" sc bud
  sc=$(measure_size_class)
  bud=$(measure_budget) || return 3
  if [ -n "$bud" ]; then
    printf '{"size_class":"%s","slots_total":1,"slots_free":%s,"budget":%s}\n' "$sc" "$sf" "$bud"
  else
    printf '{"size_class":"%s","slots_total":1,"slots_free":%s}\n' "$sc" "$sf"
  fi
}

# One beat with measured capacity threaded in. On a corrupt ledger, scream and still beat (presence
# must survive) but WITHOUT capacity — never emit a coerced budget.
fleet_beat(){ # $1 = status (idle|working|blocked)  $2 = slots_free (0|1)
  local cap
  if cap=$(capacity_json "$2"); then
    bp fleet beat "$WORKER" --status "$1" --ttl 30 --agent "$FLEET_AGENT" --capacity "$cap" -o json >/dev/null 2>&1 || true
  else
    say "⚠ spend-ledger malformed — beating $1 WITHOUT capacity (fix $(ledger_path))"
    bp fleet beat "$WORKER" --status "$1" --ttl 30 --agent "$FLEET_AGENT" -o json >/dev/null 2>&1 || true
  fi
}

# Append one spend row per CLOSED order to the ledger (outside /tmp/fleet-run's per-order rm -rf).
# claude → real total_cost_usd (source claude-cli-json); codex → real turn.completed.usage tokens
# with a CLASS_COST dollar estimate (source codex-turn-usage); custom → CLASS_COST estimate
# (source class-cost-fallback). One row: {ts, order_id, agent, cost_usd|null, tokens|null, source, klass}.
record_spend(){ # $1 = order_id  $2 = agent-output log
  local LP; LP=$(ledger_path); mkdir -p "$(dirname "$LP")"
  python3 - "$1" "$2" "$FLEET_AGENT" "${KLASS:-standard}" "$LP" <<'PY'
import sys, json, re, datetime
order_id, log, agent, klass, lp = sys.argv[1:6]
CLASS_COST = {"light": 1, "standard": 4, "heavy": 12, "xl": 30}
cost = tokens = None
source = "class-cost-fallback"
try:
    data = open(log, encoding="utf-8", errors="replace").read()
except Exception:
    data = ""
if agent == "claude":
    source = "claude-cli-json"
    obj = None
    try:
        obj = json.loads(data.strip())
    except Exception:
        for line in reversed(data.splitlines()):
            line = line.strip()
            if line.startswith("{"):
                try:
                    obj = json.loads(line); break
                except Exception:
                    pass
    if isinstance(obj, dict) and obj.get("total_cost_usd") is not None:
        try:
            cost = float(obj["total_cost_usd"])
        except Exception:
            cost = None
    if cost is None:
        m = re.search(r'"total_cost_usd"\s*:\s*([0-9]+(?:\.[0-9]+)?)', data)
        if m:
            cost = float(m.group(1))
elif agent == "codex":
    source = "codex-turn-usage"
    tot = 0; seen = False
    for line in data.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except Exception:
            continue
        u = None
        if ev.get("type") == "turn.completed":
            u = ev.get("usage") or (ev.get("turn") or {}).get("usage")
        if u is None and isinstance(ev.get("turn.completed"), dict):
            u = ev["turn.completed"].get("usage")
        if isinstance(u, dict):
            seen = True
            if isinstance(u.get("total_tokens"), int):
                tot = u["total_tokens"]
            else:
                for k in ("input_tokens", "output_tokens", "cached_input_tokens", "reasoning_tokens"):
                    if isinstance(u.get(k), int):
                        tot += u[k]
    if seen:
        tokens = tot
    cost = float(CLASS_COST.get(klass, 4))          # dollars via class-cost fallback
else:
    cost = float(CLASS_COST.get(klass, 4))
row = {"ts": datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z"),
       "order_id": order_id, "agent": agent, "cost_usd": cost, "tokens": tokens,
       "source": source, "klass": klass}
with open(lp, "a", encoding="utf-8") as fh:
    fh.write(json.dumps(row) + "\n")
PY
}

field(){ bp task get "$1" -o json 2>/dev/null | python3 -c "
import sys,json,re
d=json.load(sys.stdin).get('doc') or {}; c=d.get('claim') or {}; ct=d.get('content') or {}
ac=ct.get('acceptance_criteria') or []
brief=''.join(n.get('value','') for bl in (ct.get('brief') or {}).get('blocks',[]) for n in (bl.get('content') or []))
m=re.search(r'FENCE:\s*([^\s.,]+)', brief)
klass=ct.get('weight_class') or ct.get('klass') or ''
if not klass:
    mk=re.search(r'CLASS:\s*(light|standard|heavy|xl)', brief)
    klass=mk.group(1) if mk else 'standard'
print({'life':d.get('lifecycle_status'),'holder':c.get('worker') or '','epoch':c.get('epoch'),
 'fence':(m.group(1) if m else 'fleet/'+'$1'),'brief':brief,'klass':klass,'ctext':(ac[0].get('criterion') if ac else '')}.get('$2',''))"; }

do_order(){ # $1 = task id
  local ID="$1"
  local LIFE HOLDER FENCE BRIEF CTEXT KLASS
  LIFE=$(field "$ID" life); HOLDER=$(field "$ID" holder); FENCE=$(field "$ID" fence)
  BRIEF=$(field "$ID" brief); CTEXT=$(field "$ID" ctext); KLASS=$(field "$ID" klass)
  { [ "$LIFE" != "open" ] || [ -n "$HOLDER" ]; } && { say "skip $ID (life=$LIFE holder=$HOLDER)"; return 0; }
  local R; R=$(bp task claim "$ID" "$WORKER" --resources "$FENCE" --yes -o json 2>&1)
  echo "$R" | grep -q resource_conflict && { say "⛔ REFUSED $ID (fence $FENCE held) — stand down"; return 0; }
  echo "$R" | grep -q '"error"' && { say "claim error $ID: $(echo "$R"|head -c 100)"; return 0; }
  say "✅ CLAIMED $ID (fence $FENCE, class $KLASS) — running $FLEET_AGENT on the brief"
  bp task pulse "$ID" "$WORKER" --now "executing $ID via $FLEET_AGENT" --yes >/dev/null 2>&1
  fleet_beat working 0                                  # busy: zero free slots (PDF-D36/D40)
  local D="/tmp/fleet-run/$ID-$WORKER"; rm -rf "$D"; mkdir -p "$D"; ( cd "$D" || exit
    export FLEET_PROMPT
    FLEET_PROMPT="You are fleet worker '$WORKER' (agent: $FLEET_AGENT). Execute this ORDER exactly and completely IN THIS TURN. Create any file it names at the EXACT absolute path given. Do NOT background the work or spawn anything that outlives this turn. Be correct and rigorous. ORDER: $BRIEF"
    agent_exec "$FLEET_PROMPT" > claude.log 2>&1 )
  record_spend "$ID" "$D/claude.log"                    # meter this order into the spend ledger
  local E; E=$(field "$ID" epoch)
  bp task stamp "$ID" "$WORKER" "$E" --criterion 0 --met --evidence "worker $WORKER executed the order via $FLEET_AGENT (headless); artifact at the path named in the brief" --criterion-text "$CTEXT" --yes >/dev/null 2>&1
  E=$(field "$ID" epoch)
  bp task close "$ID" "$WORKER" "$E" --yes >/dev/null 2>&1
  fleet_beat idle 1                                     # freed: budget now reflects this order
  say "🏁 CLOSED $ID (fence released) — done"
}

case "$MODE" in
  capacity)  # print the measured capacity envelope (the gate + a human both read this)
    WORKER="${1:-${WORKER:-}}"; capacity_json 1 ;;
  once)  ID="${1:?task-id}"; WORKER="${2:?worker}"; do_order "$ID" ;;
  listen)
    WORKER="${1:?worker}"
    say "listener online in $(bp use 2>/dev/null | python3 -c "import sys,json;a=json.load(sys.stdin)['active'];print(a['workspace']+'/'+a['project']+'/'+a['dataset'])" 2>/dev/null) — waiting for orders"
    # Native presence: register + declare idle (ttl_s 30 — the bash runner beats every ~6s tick,
    # so a stale row means the loop itself died, PDF-D22). NEVER '--worker' (exits 2, swallowed by
    # || true = a beat into the void). The beat shares fate with this foreground loop — no sidecar.
    fleet_beat idle 1                                   # start beat: idle, one free slot, measured
    declare -A seen
    while true; do
      for ID in $(bp task ready -o json 2>/dev/null | python3 -c "import sys,json;[print(d['doc_id']) for d in json.load(sys.stdin).get('docs',[]) if d.get('assignee')=='$WORKER']" 2>/dev/null); do
        [ -n "${seen[$ID]:-}" ] && continue; seen[$ID]=1; do_order "$ID"
      done
      # idle beat every poll cycle — keeps the row ONLINE while parked, dies with the loop.
      fleet_beat idle 1
      sleep 6
    done ;;
  *) echo "usage: fleet-run.sh capacity | listen <worker> | once <task-id> <worker>" >&2; exit 2 ;;
esac
