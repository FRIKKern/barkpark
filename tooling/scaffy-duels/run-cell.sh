#!/usr/bin/env bash
# run-cell.sh <chore> <arm> <rep>
#
# Run ONE duel cell serially and write results/<chore>--<arm>--<rep>.json.
#
# Arms (D65 / the published prereg — the paper's letters are the law):
#   C   — the raw engine, no agent: `bp scaffy run <cmd> --var ... -o json`. Scored
#         end-to-end here (run -> parse assert statuses -> force TIER-ci gates ->
#         sha256(git diff) -> remove -> git diff --exit-code). Meter = 0 (no LLM).
#   A   — agent armed with the catalog, INSTRUCTED catalog-first.
#   Ap  — A-prime: scaffy present on disk but NOT mentioned in the brief — the
#         doctrine-gap arm (does the agent reach for the catalog unprompted? L2/D71).
#   B   — bare agent hand-editing, told NOT to use scaffy.
# A/Ap/B spawn the pinned claude CLI (see spawn_agent). The smoke path is arm C only;
# the agent path is wired + documented but not exercised by the harness gate.
#
# Meter law (D66): LLM spend comes from the claude CLI's own --output-format json
# envelope (total_cost_usd + usage). Naive JSONL summation is BANNED.
# Gates law (D67): green/red is decided by PARSED ASSERT STATUSES on a pre-warmed
# tree — NEVER the process exit code (exit 5 conflates validation + assert failure).
# Consistency (D68): sha256(git diff) across reps. Reversibility: remove -> diff clean.
#
# SERIAL ONLY. Never run two cells concurrently — the shared pin + RUNLOG assume it.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

CHORE="${1:?usage: run-cell.sh <chore> <arm> <rep>}"
ARM="${2:?usage: run-cell.sh <chore> <arm> <rep>}"
REP="${3:?usage: run-cell.sh <chore> <arm> <rep>}"
CELL="${CHORE}--${ARM}--${REP}"

mkdir -p "$SCAFFY_DUELS_RESULTS"

# --- chore config from matrix.json -------------------------------------------
COMMAND="$(matrix_get "chores.${CHORE}.command")"
NEEDS_WARM="$(matrix_get "chores.${CHORE}.needs_elixir_warm")"
CAP="$(python3 - "$SCAFFY_DUELS_MATRIX" "$CHORE" "$ARM" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); chore,arm=sys.argv[2],sys.argv[3]
caps=d["caps_usd"]
# boundary chore uses the boundary cap for both arms
cap = caps["boundary"] if chore=="boundary" else caps.get(arm, caps.get("C",0.0))
print(cap)
PY
)"

# --- warm the cell worktree (NOT part of the measured wall-clock) --------------
WARM_START="$(date +%s)"
WARM_ARGS=()
[[ "$NEEDS_WARM" == "true" || "$NEEDS_WARM" == "True" ]] && WARM_ARGS+=(--with-elixir)
# bash 3.2 + set -u: expanding an EMPTY array as "${WARM_ARGS[@]}" is an
# "unbound variable" error — use the ${arr[@]+...} guard so a no-warm chore
# (needs_elixir_warm=false, e.g. ensure-cli-noun) passes zero args cleanly.
WT="$("${SCAFFY_DUELS_DIR}/warm-worktree.sh" "$CELL" ${WARM_ARGS[@]+"${WARM_ARGS[@]}"} | tail -n1)"
[[ -d "$WT" ]] || die "warm-worktree returned no worktree ($WT)"

# --- boundary chore staging ---------------------------------------------------
if [[ "$CHORE" == "boundary" ]]; then
  "${SCAFFY_DUELS_DIR}/boundary-setup.sh" "$WT"
fi

# The measured window starts AFTER warm + staging: a cell measures WORK, not
# cold-build noise (D67). warm_ms is recorded separately for transparency.
START_TS="$(date +%s)"
WARM_MS="$(( (START_TS - WARM_START) * 1000 ))"

# --- helpers ------------------------------------------------------------------

# Populate the global array VF with --var flag tokens from a JSON {name:value}.
# One token per line (D33: --var values are single-line, so no token spans lines).
# bash 3.2 safe — no `mapfile -d` / NUL `read -a`.
_load_var_flags() { # $1 = json object
  VF=()
  local line
  while IFS= read -r line; do VF+=("$line"); done < <(
    python3 - "$1" <<'PY'
import json,sys
for k,v in json.loads(sys.argv[1]).items():
    print("--var"); print(f"{k}={v}")
PY
  )
}

# Resolve RESOLVE_AT_RUN sentinels from the CELL TREE AT THE PIN (flagship count
# bumps): CountBefore <- toHaveLength(N) in js/packages/react/tests/PortableDoc.test.tsx,
# ParityCountBefore <- EXPECTED_COUNT= in scripts/pd-parity-completeness.sh,
# each *After = its Before + 1 (OPAQUE+SUCCESSOR pairs). Fails LOUD if a sentinel
# survives unresolved — a sentinel passed verbatim would exit-2 the engine and
# must never score.
# Reads HEAD blobs (git show), NEVER the working file: after a run the working
# tree carries the bumped counts, so a working-file re-resolve at REMOVE time
# derived N+1/N+2, hashed a different receipt id, and remove said not_found —
# reversibility false-red (mechanical). HEAD is invariant across run/remove.
_resolve_vars() { # $1 = vars json object -> resolved json on stdout
  python3 - "$1" "$WT" <<'PY'
import json,re,subprocess,sys
vars,wt=json.loads(sys.argv[1]),sys.argv[2]
def grab(path,pat):
    blob=subprocess.run(["git","-C",wt,"show",f"HEAD:{path}"],
                        capture_output=True,text=True,check=True).stdout
    m=re.search(pat,blob)
    if not m: sys.exit(f"resolve: no match for {pat!r} in HEAD:{path}")
    return int(m.group(1))
if any(v=="RESOLVE_AT_RUN" for v in vars.values()):
    n=grab("js/packages/react/tests/PortableDoc.test.tsx",r"toHaveLength\((\d+)\)")
    p=grab("scripts/pd-parity-completeness.sh",r"EXPECTED_COUNT=(\d+)")
    fill={"CountBefore":n,"CountAfter":n+1,"ParityCountBefore":p,"ParityCountAfter":p+1}
    for k,v in vars.items():
        if v=="RESOLVE_AT_RUN":
            if k not in fill: sys.exit(f"resolve: no rule for sentinel var {k}")
            vars[k]=str(fill[k])
print(json.dumps(vars))
PY
}

# Remove LIFO with the same var set(s) (D36), used by arm C and by A/Ap reversal.
# Handles both single-vars chores and var_sequence chores (e.g. add-oban-worker).
_remove_lifo() { # $1 = remove-envelope path
  local seq n i vars
  seq="$(matrix_get "chores.${CHORE}.var_sequence" 2>/dev/null || echo "null")"
  if [[ "$seq" != "null" ]]; then
    n="$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])))' "$seq")"
    for ((i=n-1;i>=0;i--)); do
      _load_var_flags "$(python3 -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1])[int(sys.argv[2])]))' "$seq" "$i")"
      ( cd "$WT" && bp scaffy remove "$COMMAND" "${VF[@]}" -o json ) > "$1" 2>/dev/null || true
    done
  else
    vars="$(_resolve_vars "$(matrix_get "chores.${CHORE}.vars")")"
    _load_var_flags "$vars"
    ( cd "$WT" && bp scaffy remove "$COMMAND" "${VF[@]}" -o json ) > "$1" 2>/dev/null || true
  fi
}

# Run a registered command list (matrix.json chores.<chore>.<list>) in the warmed
# tree via `sh -c` (D38), record rc per command. Prints a JSON array of {cmd, rc}.
# Used for tier_ci_force (deferred TIER-ci asserts) AND agent_gate (the mechanical
# correctness bar for agent arms — an agent cell is never green by trust).
_run_gate_list() { # $1 = list key, e.g. tier_ci_force | agent_gate
  python3 - "$SCAFFY_DUELS_MATRIX" "$CHORE" "$WT" "$1" <<'PY'
import json,subprocess,sys,os
d=json.load(open(sys.argv[1])); chore,wt,key=sys.argv[2],sys.argv[3],sys.argv[4]
cmds=d["chores"][chore].get(key,[]) or []
res=[]
env=dict(os.environ); env["CC"]="/usr/bin/clang"
for c in cmds:
    p=subprocess.run(["sh","-c",c],cwd=wt,env=env,capture_output=True,text=True,timeout=900)
    res.append({"cmd":c,"rc":p.returncode})
print(json.dumps(res))
PY
}
_force_tier_ci() { _run_gate_list tier_ci_force; }

# --- arm C: the engine alone --------------------------------------------------
run_arm_c() {
  local diff_sha forced reversible
  cd "$WT"

  # Ops may run once (single vars) or twice (var_sequence, e.g. add-oban-worker REANCHOR).
  local seq
  seq="$(matrix_get "chores.${CHORE}.var_sequence" 2>/dev/null || echo "null")"

  # EVERY run's envelope is kept and scored — a red run 1 must never hide behind
  # a green run 2 (distrust vacuous green).
  RUN_JSONS=()
  if [[ "$seq" != "null" ]]; then
    local n i rj
    n="$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])))' "$seq")"
    for ((i=0;i<n;i++)); do
      rj="${SCAFFY_DUELS_RESULTS}/${CELL}.run.$((i+1)).json"
      _load_var_flags "$(python3 -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1])[int(sys.argv[2])]))' "$seq" "$i")"
      bp scaffy run "$COMMAND" "${VF[@]}" -o json > "$rj" || true
      RUN_JSONS+=("$rj")
    done
  else
    local vars rj
    rj="${SCAFFY_DUELS_RESULTS}/${CELL}.run.json"
    vars="$(_resolve_vars "$(matrix_get "chores.${CHORE}.vars")")"
    _load_var_flags "$vars"
    bp scaffy run "$COMMAND" "${VF[@]}" -o json > "$rj" || true
    RUN_JSONS+=("$rj")
  fi

  # Force-run TIER-ci gates (deferred asserts) in the warmed tree.
  forced="$(_force_tier_ci)"

  # sha256 of the working diff (consistency floor, D68).
  diff_sha="$(git -C "$WT" --no-pager diff | sha256_stdin)"

  # Reverse: remove with the SAME vars LIFO (D36), then require a byte-clean tree.
  _remove_lifo "${SCAFFY_DUELS_RESULTS}/${CELL}.remove.json"
  if git -C "$WT" --no-pager diff --exit-code >/dev/null 2>&1; then reversible=true; else reversible=false; fi

  # Assemble the scored result (assert statuses drive gates_green, NOT exit codes).
  END_TS="$(date +%s)"
  python3 - \
    "$forced" "$diff_sha" "$reversible" "$CELL" "$CHORE" "$ARM" "$REP" \
    "$CAP" "$WT" "$START_TS" "$END_TS" "$WARM_MS" "${RUN_JSONS[@]}" \
    > "${SCAFFY_DUELS_RESULTS}/${CELL}.json" <<'PY'
import json,sys
forced=json.loads(sys.argv[1])
diff_sha,reversible=sys.argv[2],sys.argv[3]=="true"
cell,chore,arm,rep=sys.argv[4:8]
cap=float(sys.argv[8]); wt=sys.argv[9]
start,end=int(sys.argv[10]),int(sys.argv[11]); warm_ms=int(sys.argv[12])
asserts=[]
for path in sys.argv[13:]:
    try: run=json.load(open(path))
    except Exception: run={}
    asserts.extend(run.get("asserts",[]) or [])
any_fail=any(a.get("status")=="fail" for a in asserts)
forced_red=any(f.get("rc",1)!=0 for f in forced)
# An empty assert list can NEVER be green: an engine refusal (e.g. a bad --var,
# exit 2) yields no asserts, and silence must not score as success.
gates_green = bool(asserts) and (not any_fail) and (not forced_red)
out={
  "cell":cell,"chore":chore,"arm":arm,"rep":rep,"cap_usd":cap,
  "worktree":wt,"duration_ms":(end-start)*1000,"warm_ms":warm_ms,
  "meter":{"total_cost_usd":0.0,"usage":None,"source":"engine"},
  "score":{
    "gates_green":gates_green,
    "asserts":[{"kind":a.get("kind"),"tier":a.get("tier"),"status":a.get("status"),
                "text":(a.get("text") or a.get("path") or "")[:120]} for a in asserts],
    "tier_ci_forced":forced,
    "agent_gate":[],
    "diff_sha256":diff_sha,
    "reversible":reversible,
  },
}
print(json.dumps(out,indent=2))
PY
}

# --- arm A/Ap/B: spawn the pinned claude CLI ----------------------------------
# NOT exercised by the harness gate (smoke = arm C). Wired + documented so the
# run-duels slice (round 2) drives it. Requires an UN-SANDBOXED shell (bp needs
# network; a sandboxed spawn SIGKILLs bp, exit 137).
spawn_agent() {
  local brief agent_json
  brief="$(_agent_brief)"
  agent_json="${SCAFFY_DUELS_RESULTS}/${CELL}.agent.json"
  ( cd "$WT" && claude -p "$brief" \
      --model sonnet \
      --output-format json \
      --permission-mode bypassPermissions \
      --no-session-persistence \
      --max-budget-usd "$CAP" ) > "$agent_json" || true

  # Meter straight from the claude JSON envelope (D66) — never a JSONL re-sum.
  # Correctness: the harness re-runs the chore's registered mechanical gates
  # (agent_gate + tier_ci_force) itself — an agent cell is NEVER green by trust.
  local forced agent_gate diff_sha reversible
  forced="$(_force_tier_ci)"
  agent_gate="$(_run_gate_list agent_gate)"
  diff_sha="$(git -C "$WT" --no-pager diff | sha256_stdin)"
  reversible=false
  if [[ "$ARM" != "B" && "$COMMAND" != "null" ]]; then
    # A/Ap reversal: receipt replay with the registered vars (LIFO for sequences).
    # An agent that hand-edited instead of running scaffy leaves no receipt —
    # remove exits 4 and the dirty diff scores reversible=false, honestly.
    _remove_lifo "${SCAFFY_DUELS_RESULTS}/${CELL}.remove.json"
    git -C "$WT" --no-pager diff --exit-code >/dev/null 2>&1 && reversible=true
  fi
  END_TS="$(date +%s)"
  python3 - "$agent_json" "$forced" "$agent_gate" "$diff_sha" "$reversible" "$CELL" \
    "$CHORE" "$ARM" "$REP" "$CAP" "$WT" "$START_TS" "$END_TS" "$WARM_MS" \
    > "${SCAFFY_DUELS_RESULTS}/${CELL}.json" <<'PY'
import json,sys
try: agent=json.load(open(sys.argv[1]))
except Exception: agent={}
forced=json.loads(sys.argv[2]); gate=json.loads(sys.argv[3])
diff_sha,reversible=sys.argv[4],sys.argv[5]=="true"
cell,chore,arm,rep=sys.argv[6:10]; cap=float(sys.argv[10]); wt=sys.argv[11]
start,end=int(sys.argv[12]),int(sys.argv[13]); warm_ms=int(sys.argv[14])
cost=agent.get("total_cost_usd", agent.get("cost_usd"))
usage=agent.get("usage")
checks=forced+gate
red=any(c.get("rc",1)!=0 for c in checks)
# No mechanical check at all can NEVER be green — every registered chore carries
# a non-empty tier_ci_force or agent_gate list (distrust vacuous green).
gates_green=bool(checks) and (not red)
out={
 "cell":cell,"chore":chore,"arm":arm,"rep":rep,"cap_usd":cap,"worktree":wt,
 "duration_ms":(end-start)*1000,"warm_ms":warm_ms,
 "meter":{"total_cost_usd":cost,"usage":usage,"source":"claude-cli-json"},
 "score":{"gates_green":gates_green,"asserts":[],"tier_ci_forced":forced,
          "agent_gate":gate,"diff_sha256":diff_sha,"reversible":reversible},
}
print(json.dumps(out,indent=2))
PY
}

# The brief = the chore's registered task statement (matrix.json chores.<chore>.brief
# — states the CONCRETE task incl. the registered var values, so every arm attempts
# the SAME chore instance) + the arm doctrine. Letters per the published prereg:
# A instructed catalog-first; Ap scaffy UNMENTIONED (doctrine gap); B no scaffy.
_agent_brief() {
  local base doctrine
  base="$(matrix_get "chores.${CHORE}.brief")"
  [[ -n "$base" && "$base" != "null" ]] || die "chore ${CHORE} has no registered brief in matrix.json"
  case "$ARM" in
    A)  doctrine=" FIRST check the local Scaffy catalog (scaffy/commands/) and prefer \`bp scaffy run\` if a command fits — reach for the catalog before hand-editing." ;;
    Ap) doctrine="" ;;
    B)  doctrine=" Hand-edit the files directly. Do NOT use scaffy." ;;
    *)  doctrine="" ;;
  esac
  printf '%s Work only in this checkout.%s' "$base" "$doctrine"
}

# --- dispatch -----------------------------------------------------------------
case "$ARM" in
  C)          run_arm_c ;;
  A|Ap|B)     spawn_agent ;;
  *)          die "unknown arm '$ARM' (expect A|Ap|B|C)" ;;
esac

# --- serial log (validate_results checks non-overlap) -------------------------
python3 - "${SCAFFY_DUELS_RESULTS}/RUNLOG.jsonl" "$CELL" "$START_TS" "$(date +%s)" <<'PY'
import json,sys
path,cell,start,end=sys.argv[1],sys.argv[2],int(sys.argv[3]),int(sys.argv[4])
with open(path,"a") as f:
    f.write(json.dumps({"cell":cell,"start":start,"end":end})+"\n")
PY

# --- human summary ------------------------------------------------------------
python3 - "${SCAFFY_DUELS_RESULTS}/${CELL}.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))
s=r["score"]; m=r["meter"]
print(f"\n=== cell {r['cell']} ===")
print(f"  gates_green : {s['gates_green']}")
print(f"  meter       : ${m['total_cost_usd']} ({m['source']})")
print(f"  diff_sha256 : {s['diff_sha256'][:16]}…")
print(f"  reversible  : {s['reversible']}")
if s['asserts']:
    for a in s['asserts']:
        print(f"    assert {a['status']:9} {a['kind']:14} {a['text']}")
if s['tier_ci_forced']:
    for f in s['tier_ci_forced']:
        print(f"    tier-ci rc={f['rc']}  {f['cmd']}")
if s.get('agent_gate'):
    for f in s['agent_gate']:
        print(f"    agent-gate rc={f['rc']}  {f['cmd']}")
print()
PY
