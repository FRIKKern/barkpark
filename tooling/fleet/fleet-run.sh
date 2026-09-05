#!/bin/bash
# fleet-run.sh — PROVIDER-NEUTRAL Personal Dev Fleet listener/runner.
# ANY headless AI agent becomes a fleet worker: the ONLY provider-specific thing is the
# one-line exec adapter below. Everything else (listen, claim, fence, stamp, close) is bp.
#
#   FLEET_AGENT=claude  bash fleet-run.sh listen <worker>     # stay-alive loop (Claude Code)
#   FLEET_AGENT=codex   bash fleet-run.sh listen <worker>     # stay-alive loop (OpenAI Codex)
#   FLEET_AGENT=custom  FLEET_AGENT_EXEC='myagent --prompt "$FLEET_PROMPT"' bash fleet-run.sh listen <worker>
#   FLEET_AGENT=codex   bash fleet-run.sh once <task-id> <worker>   # run a single dispatched order
#   bash fleet-run.sh capacity                                     # print the MEASURED capacity JSON
#
# Orders are bp tasks routed by `assignee`. Scope (workspace/project/dataset) is whatever
# `bp use` is set to — the same ledger every fleet member shares. No message bus, no local queue.
#
# Verdicts are HONEST (PDF-D100 / PDS-D287): stamp evidence is READ from the run (artifact
# stat with an mtime-after-claim control, or the turn's own receipt values) — never canned;
# a failed order is `--miss`-stamped and RELEASED, never closed. The verdict logic is factored
# (order_verdict / run_turn) so `fleet-run-verdict-test.sh` gates it on fixtures, no real turn.
# Shape before content: bp emits ok:false, a typed error.code AND a non-zero
# exit on a refused read; bp_json checks all three so a refusal can never be
# read as an empty result (task-4eb2994a588453d3).
_FLEET_RUN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_FLEET_RUN_DIR/../../scripts/lib/bp-read.sh"

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
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
    # NOTE: no braces in the :? message — bash closes the expansion at the FIRST `}`, so a
    # brace-y message (the old `{{PROMPT}}`) leaked a literal `}}` into every eval'd command.
    custom) eval "${FLEET_AGENT_EXEC:?set FLEET_AGENT_EXEC; it reads \$FLEET_PROMPT}" ;;
    *) echo "unknown FLEET_AGENT: $FLEET_AGENT" >&2; return 2 ;;
  esac
}

# Bounded turn. TRAP B (live-measured): an unreachable ANTHROPIC_BASE_URL hangs past 100s with
# a ZERO-BYTE log — so every turn gets a hard timeout (FLEET_TURN_TIMEOUT, default 1800s), and
# the agent's REAL exit status is returned (124 on timeout) instead of being discarded by the
# old `( cd ... || exit )` subshell. 97 = the workdir itself was unusable.
run_turn(){ # $1 = workdir  $2 = prompt  $3 = log  $4 = timeout seconds
  ( cd "$1" || exit 97; agent_exec "$2" ) > "$3" 2>&1 &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$4" ]; then
      pkill -TERM -P "$pid" 2>/dev/null; kill -TERM "$pid" 2>/dev/null
      sleep 2
      pkill -KILL -P "$pid" 2>/dev/null; kill -KILL "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 2; waited=$((waited + 2))
  done
  wait "$pid"; return $?
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
# (source class-cost-fallback). One row: {ts, order_id, agent, cost_usd|null, tokens|null,
# source, klass, verdict}. The verdict rides the row because of TRAP A (live-measured): a 401
# turn still reports total_cost_usd:0, so without it a failed auth turn is indistinguishable
# from a genuinely cheap success and telemetry counts failures as $0 wins.
record_spend(){ # $1 = order_id  $2 = agent-output log  $3 = verdict (PASS|MISS|empty)
  local LP; LP=$(ledger_path); mkdir -p "$(dirname "$LP")"
  python3 - "$1" "$2" "$FLEET_AGENT" "${KLASS:-standard}" "$LP" "${3:-}" <<'PY'
import sys, json, re, datetime
order_id, log, agent, klass, lp = sys.argv[1:6]
verdict = sys.argv[6] if len(sys.argv) > 6 else ""
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
       "source": source, "klass": klass, "verdict": (verdict or None)}
with open(lp, "a", encoding="utf-8") as fh:
    fh.write(json.dumps(row) + "\n")
PY
}

# `bp task get` is CAPTURED, never piped. The old line was
#     bp task get "$1" -o json 2>/dev/null | python3 -c "..."
# which is the "bp-into-a-pipe" pattern: 2>/dev/null discards the message and,
# with no `set -o pipefail` in this file, the pipeline's status is python3's,
# never bp's. A `usage`/`not_found` refusal (exit 2/4) therefore arrived as an
# error envelope with no `doc` key, `or {}` collapsed it, and field() printed
# an empty string — indistinguishable from a row that genuinely has no holder.
field(){
  local _body _rc
  _body="$(bp_json task get "$1" -o json)"; _rc=$?
  if [ "$_rc" -ne 0 ]; then
    # bp's own status is PROPAGATED, not flattened to 1: the caller can still
    # tell `usage` (2) from `not_found` (4).
    printf 'fleet-run: field(%s,%s) ABORTED — bp refused the read (see above); ' "$1" "$2" >&2
    printf 'this is NOT an empty field.\n' >&2
    return "$_rc"
  fi
  printf '%s' "$_body" | python3 -c "
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
 'fence':(m.group(1) if m else 'fleet/'+'$1'),'brief':brief,'klass':klass,'ctext':(ac[0].get('criterion') if ac else ''),
 'met0':(ac[0].get('met') if ac else '')}.get('$2',''))"
}

# ============================ THE VERDICT (PDF-D100) ============================
# order_verdict <log> <agent_exit> <claim_epoch_s> <agent> <ctext> <brief>
# Prints exactly three lines: verdict=PASS|MISS, tier=..., evidence=<one line read from the run>.
# The verdict NEVER reads `subtype` — live-measured (claude 2.1.220): subtype is "success" on
# all four failure shapes (401 key, 401 bearer, not-logged-in, 404 model). Honest fields in
# order: exit code -> is_error -> terminal_reason -> api_error_status (NULL when not logged in,
# so never a sufficient test alone) -> result. The envelope key set is IDENTICAL between
# success and failure, so this reads VALUES, never key presence.
# Tiers: (1) PATH-READ — stat the brief/criterion's absolute artifact path: exists, size>0,
# mtime AFTER the claim (without the mtime control a pre-existing file is a vacuous green,
# PDS-D20). (2) RECEIPT-VERDICT — the turn's own receipt values, evidence names its weakness.
# (3) AGENT-AUTHORED — the result excerpt, labelled as the agent's claim, never alone.
# (4) MISS — honest absence; the caller stamps --miss and RELEASES, never closes.
order_verdict(){
  python3 - "$1" "$2" "$3" "$4" "${5:-}" "${6:-}" <<'PY'
import sys, json, os, re
log, agent_exit, claim_ts, agent = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
ctext = sys.argv[5] if len(sys.argv) > 5 else ""
brief = sys.argv[6] if len(sys.argv) > 6 else ""

def out(verdict, tier, evidence):
    print("verdict=%s" % verdict)
    print("tier=%s" % tier)
    print("evidence=%s" % " ".join(str(evidence).split()))   # one line, whitespace collapsed
    sys.exit(0)

try:
    nbytes = os.path.getsize(log)
except OSError:
    nbytes = 0

# 1) exit code first — the one trustworthy claude signal (1 fail / 0 success; 124 = our timeout)
if agent_exit == 124:
    out("MISS", "timeout", "turn killed at the timeout (exit 124); log %d bytes — an unreachable "
        "base URL hangs with a zero-byte log (TRAP B)" % nbytes)
if agent_exit != 0:
    try:
        tail = open(log, encoding="utf-8", errors="replace").read()[-160:]
    except OSError:
        tail = ""
    out("MISS", "exit", "agent exited %d (non-zero); log %d bytes; tail: %r" % (agent_exit, nbytes, tail))

# 2) the receipt — the exact parse idiom record_spend uses (whole log, else last {...} line)
try:
    data = open(log, encoding="utf-8", errors="replace").read()
except OSError:
    data = ""
obj = None
try:
    o = json.loads(data.strip())
    if isinstance(o, dict):
        obj = o
except Exception:
    for line in reversed(data.splitlines()):
        line = line.strip()
        if line.startswith("{"):
            try:
                o = json.loads(line)
                if isinstance(o, dict):
                    obj = o
                    break
            except Exception:
                pass

result = ""
if agent == "claude":
    if obj is None:
        out("MISS", "no-receipt", "exit 0 but no parseable receipt JSON in the %d-byte log — "
            "nothing to attest" % nbytes)
    is_error = obj.get("is_error")
    result = str(obj.get("result") or "")
    if is_error is not False:
        # is_error true — or absent, which is just as untrustworthy. api_error_status may be
        # null right here (not-logged-in) and subtype still reads "success"; neither is consulted.
        out("MISS", "receipt-verdict",
            "receipt says failure despite exit 0: is_error=%r terminal_reason=%r api_error_status=%r "
            "result=%r" % (is_error, obj.get("terminal_reason"), obj.get("api_error_status"), result[:200]))
    receipt = ("receipt: is_error=false terminal_reason=%r num_turns=%r cost_usd=%r"
               % (obj.get("terminal_reason"), obj.get("num_turns"), obj.get("total_cost_usd")))
else:
    if nbytes == 0:
        out("MISS", "no-receipt", "exit 0 but a zero-byte log for agent %s — nothing to attest" % agent)
    receipt = ("no receipt parser for agent %s; exit 0 + a %d-byte log is all the turn itself attests"
               % (agent, nbytes))

# 3) PATH-READ — the criterion's paths ARE the deliverable; the brief's only as fallback
# (briefs also name inputs to READ, which would false-miss the mtime control).
# `/+` between segments: macOS TMPDIR ends in `/`, so real briefs carry `//` runs — a single-`/`
# pattern silently TRUNCATES the path there and stats the wrong (pre-existing) parent.
PATH_RE = re.compile(r'(?<![\w.:/@~-])(/+[\w.+~@-]+(?:/+[\w.+~@-]+)+)')
def paths_in(s):
    seen = []
    for p in PATH_RE.findall(s or ""):
        p = os.path.normpath(p.rstrip(".,;:)"))
        if p and p not in seen:
            seen.append(p)
    return seen

paths = paths_in(ctext) or paths_in(brief)
if paths:
    good, bad = [], []
    for p in paths:
        try:
            st = os.stat(p)
        except OSError:
            bad.append("%s ABSENT" % p)
            continue
        if not os.path.isfile(p):
            bad.append("%s NOT A REGULAR FILE (a directory's size/mtime prove nothing)" % p)
        elif st.st_size == 0:
            bad.append("%s EMPTY (0 bytes)" % p)
        elif int(st.st_mtime) < claim_ts:
            bad.append("%s STALE (mtime %d predates claim %d — a pre-existing file is a "
                       "vacuous green, PDS-D20)" % (p, int(st.st_mtime), claim_ts))
        else:
            good.append("%s: %d bytes, mtime %d >= claim %d" % (p, st.st_size, int(st.st_mtime), claim_ts))
    if bad:
        out("MISS", "path-read", "artifact read failed — " + "; ".join(bad)
            + ("; read ok: " + "; ".join(good) if good else "") + "; " + receipt)
    out("PASS", "path-read", "read the artifact this run wrote — " + "; ".join(good) + "; " + receipt)

# 4) no path anywhere → receipt tier; the evidence names its own weakness in the same breath,
# with the result excerpt appended as tier-3, explicitly the agent's own claim.
claim = ("; agent's own claim (tier-3, unverified): %r" % result[:200]) if result else ""
out("PASS", "receipt-verdict",
    "no artifact path in the criterion or brief — this attests the turn ran, not the outcome; "
    + receipt + claim)
PY
}

# Honest absence (tier 4): stamp --miss with what the read showed, then RELEASE the claim so a
# retry or a human gets it. NEVER a close — fleet-listener SKILL.md: "a failed order is
# closed-with-honest-evidence or released, never silently dropped."
release_order(){ # $1 = task id  $2 = note (what was attempted and what the read showed)
  local E SO RO
  E=$(field "$1" epoch)
  SO=$(bp task stamp "$1" "$WORKER" "$E" --criterion 0 --miss --note "$2" --yes 2>&1) \
    || say "miss-stamp error on $1: $(echo "$SO" | head -c 200)"
  E=$(field "$1" epoch)
  RO=$(bp task release "$1" "$WORKER" "$E" --yes 2>&1) \
    || say "release error on $1: $(echo "$RO" | head -c 200)"
  say "↩ RELEASED $1 — $2"
}

do_order(){ # $1 = task id
  local ID="$1"
  local LIFE HOLDER FENCE BRIEF CTEXT KLASS
  LIFE=$(field "$ID" life); HOLDER=$(field "$ID" holder); FENCE=$(field "$ID" fence)
  BRIEF=$(field "$ID" brief); CTEXT=$(field "$ID" ctext); KLASS=$(field "$ID" klass)
  { [ "$LIFE" != "open" ] || [ -n "$HOLDER" ]; } && { say "skip $ID (life=$LIFE holder=$HOLDER)"; return 0; }
  local R; R=$(bp task claim "$ID" "$WORKER" --resources "$FENCE" --yes -o json 2>&1)
  echo "$R" | grep -q resource_conflict && { say "⛔ REFUSED $ID (fence $FENCE held) — stand down"; return 0; }
  echo "$R" | grep -q '"error"' && { say "claim error $ID: $(echo "$R"|head -c 100)"; return 0; }
  local CLAIM_TS; CLAIM_TS=$(date +%s)                  # artifact mtimes are honest only AFTER this
  say "✅ CLAIMED $ID (fence $FENCE, class $KLASS) — running $FLEET_AGENT on the brief"
  bp task pulse "$ID" "$WORKER" --now "executing $ID via $FLEET_AGENT" --yes >/dev/null 2>&1
  fleet_beat working 0                                  # busy: zero free slots (PDF-D36/D40)
  local D="/tmp/fleet-run/$ID-$WORKER"; rm -rf "$D"; mkdir -p "$D"
  export FLEET_PROMPT
  FLEET_PROMPT="You are fleet worker '$WORKER' (agent: $FLEET_AGENT). Execute this ORDER exactly and completely IN THIS TURN. Create any file it names at the EXACT absolute path given. Do NOT background the work or spawn anything that outlives this turn. Be correct and rigorous. ORDER: $BRIEF"
  run_turn "$D" "$FLEET_PROMPT" "$D/claude.log" "${FLEET_TURN_TIMEOUT:-1800}"
  local AGENT_EXIT=$?                                   # captured, never subshell-discarded
  local VOUT VERDICT TIER EVIDENCE
  VOUT=$(order_verdict "$D/claude.log" "$AGENT_EXIT" "$CLAIM_TS" "$FLEET_AGENT" "$CTEXT" "$BRIEF")
  VERDICT=$(printf '%s\n' "$VOUT" | sed -n 's/^verdict=//p')
  TIER=$(printf '%s\n' "$VOUT" | sed -n 's/^tier=//p')
  EVIDENCE=$(printf '%s\n' "$VOUT" | sed -n 's/^evidence=//p')
  record_spend "$ID" "$D/claude.log" "$VERDICT"         # meter it, verdict on the row (TRAP A)
  if [ "$VERDICT" = "PASS" ] && [ -n "$CTEXT" ]; then
    local E SOUT COUT; E=$(field "$ID" epoch)
    SOUT=$(bp task stamp "$ID" "$WORKER" "$E" --criterion 0 --met --evidence "[$TIER] $EVIDENCE" --criterion-text "$CTEXT" --yes 2>&1) || true
    # Re-GET post-condition (PDF-D33 / pds-bl-stamp-silent-noop): never trust the stamp's exit
    # code — the close is GATED on the criterion having ACTUALLY flipped on the ledger.
    if [ "$(field "$ID" met0)" = "True" ]; then
      E=$(field "$ID" epoch)
      COUT=$(bp task close "$ID" "$WORKER" "$E" --yes 2>&1) || true
      if [ "$(field "$ID" life)" = "done" ]; then       # same doctrine on the close itself
        say "🏁 CLOSED $ID [$TIER] — $EVIDENCE"
      else
        say "⚠ close did not land on $ID (life=$(field "$ID" life); close said: $(echo "$COUT" | head -c 200)) — leaving claimed with the landed stamp for a human"
      fi
    else
      say "⚠ --met stamp did not land on $ID (criterion 0 still unmet; stamp said: $(echo "$SOUT" | head -c 200)) — close refused"
      release_order "$ID" "--met stamp did not land (criterion 0 unmet after stamp); close refused. verdict PASS [$TIER]: $EVIDENCE"
    fi
  elif [ "$VERDICT" = "PASS" ]; then
    # TRAP C: no acceptance criteria ⇒ empty --criterion-text ⇒ every --met stamp 409s. With no
    # evidence surface to land on, closing would be the old blind green — report and release.
    say "⚠ $ID has no acceptance criteria — a --met stamp cannot land (TRAP C); releasing, never closing blind"
    release_order "$ID" "order has no acceptance criteria so no --met stamp can land (TRAP C); verdict PASS [$TIER]: $EVIDENCE"
  else
    say "✗ MISS on $ID [$TIER] — $EVIDENCE"
    release_order "$ID" "[$TIER] $EVIDENCE"
  fi
  fleet_beat idle 1                                     # freed: budget now reflects this order
}

# Mode dispatch is source-guarded so fleet-run-verdict-test.sh can source the functions above
# and gate the verdict on fixtures without running a turn or touching a server.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  MODE="${1:?mode: listen|once}"; shift
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
      fleet_beat idle 1                                 # start beat: idle, one free slot, measured
      declare -A seen
      while true; do
        # CAPTURE, do not pipe. The old form was
        #   bp task ready -o json 2>/dev/null | python3 -c "... .get('docs',[]) ..." 2>/dev/null
        # and on a refusal the envelope has no `docs`, so the default [] made a
        # dead ledger look exactly like "no orders for me" — forever, silently.
        _ready="$(bp_json task ready -o json)" || { sleep 6; continue; }
        for ID in $(printf '%s' "$_ready" | python3 -c "import sys,json;[print(d['doc_id']) for d in json.load(sys.stdin)['docs'] if d.get('assignee')=='$WORKER']"); do
          [ -n "${seen[$ID]:-}" ] && continue; seen[$ID]=1; do_order "$ID"
        done
        # idle beat every poll cycle — keeps the row ONLINE while parked, dies with the loop.
        fleet_beat idle 1
        sleep 6
      done ;;
    *) echo "usage: fleet-run.sh capacity | listen <worker> | once <task-id> <worker>" >&2; exit 2 ;;
  esac
fi
