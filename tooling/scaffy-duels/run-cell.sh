#!/usr/bin/env bash
# run-cell.sh <chore> <arm> <rep>
#
# Run ONE duel cell serially and write results/<chore>--<arm>--<rep>.json.
#
# Arms (D65):
#   C   — the raw engine, no agent: `bp scaffy run <cmd> --var ... -o json`. Scored
#         end-to-end here (run -> parse assert statuses -> force TIER-ci gates ->
#         sha256(git diff) -> remove -> git diff --exit-code). Meter = 0 (no LLM).
#   A   — agent armed with the catalog, NOT told to reach for it first.
#   Ap  — A-prime: agent INSTRUCTED catalog-first (measures the L2 doctrine, D71).
#   B   — bare agent hand-editing, no scaffy.
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

START_TS="$(date +%s)"

# --- warm the cell worktree ---------------------------------------------------
WARM_ARGS=()
[[ "$NEEDS_WARM" == "true" || "$NEEDS_WARM" == "True" ]] && WARM_ARGS+=(--with-elixir)
WT="$("${SCAFFY_DUELS_DIR}/warm-worktree.sh" "$CELL" "${WARM_ARGS[@]}" | tail -n1)"
[[ -d "$WT" ]] || die "warm-worktree returned no worktree ($WT)"

# --- boundary chore staging ---------------------------------------------------
if [[ "$CHORE" == "boundary" ]]; then
  "${SCAFFY_DUELS_DIR}/boundary-setup.sh" "$WT"
fi

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

# Force-run the TIER-ci gate list for a chore in the warmed tree, record rc.
# Prints a JSON array of {cmd, rc} to stdout.
_force_tier_ci() {
  python3 - "$SCAFFY_DUELS_MATRIX" "$CHORE" "$WT" <<'PY'
import json,subprocess,sys,os
d=json.load(open(sys.argv[1])); chore,wt=sys.argv[2],sys.argv[3]
cmds=d["chores"][chore].get("tier_ci_force",[]) or []
res=[]
env=dict(os.environ); env["CC"]="/usr/bin/clang"
for c in cmds:
    p=subprocess.run(["sh","-c",c],cwd=wt,env=env,capture_output=True,text=True,timeout=900)
    res.append({"cmd":c,"rc":p.returncode})
print(json.dumps(res))
PY
}

# --- arm C: the engine alone --------------------------------------------------
run_arm_c() {
  local run_json remove_json diff_sha forced reversible
  cd "$WT"

  # Ops may run once (single vars) or twice (var_sequence, e.g. add-oban-worker REANCHOR).
  local seq
  seq="$(matrix_get "chores.${CHORE}.var_sequence" 2>/dev/null || echo "null")"

  run_json="${SCAFFY_DUELS_RESULTS}/${CELL}.run.json"
  if [[ "$seq" != "null" ]]; then
    # ×2-per-cell: apply each var set, keep the LAST run envelope as the scored one.
    local n i
    n="$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])))' "$seq")"
    for ((i=0;i<n;i++)); do
      _load_var_flags "$(python3 -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1])[int(sys.argv[2])]))' "$seq" "$i")"
      bp scaffy run "$COMMAND" "${VF[@]}" -o json > "$run_json" || true
    done
  else
    local vars
    vars="$(matrix_get "chores.${CHORE}.vars")"
    _load_var_flags "$vars"
    bp scaffy run "$COMMAND" "${VF[@]}" -o json > "$run_json" || true
  fi

  # Force-run TIER-ci gates (deferred asserts) in the warmed tree.
  forced="$(_force_tier_ci)"

  # sha256 of the working diff (consistency floor, D68).
  diff_sha="$(git -C "$WT" --no-pager diff | sha256_stdin)"

  # Reverse: remove with the SAME vars, then require a byte-clean tree.
  remove_json="${SCAFFY_DUELS_RESULTS}/${CELL}.remove.json"
  if [[ "$seq" != "null" ]]; then
    local n i
    n="$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])))' "$seq")"
    # LIFO: remove in reverse order (D36).
    for ((i=n-1;i>=0;i--)); do
      _load_var_flags "$(python3 -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1])[int(sys.argv[2])]))' "$seq" "$i")"
      bp scaffy remove "$COMMAND" "${VF[@]}" -o json > "$remove_json" || true
    done
  else
    local vars
    vars="$(matrix_get "chores.${CHORE}.vars")"
    _load_var_flags "$vars"
    bp scaffy remove "$COMMAND" "${VF[@]}" -o json > "$remove_json" || true
  fi
  if git -C "$WT" --no-pager diff --exit-code >/dev/null 2>&1; then reversible=true; else reversible=false; fi

  # Assemble the scored result (assert statuses drive gates_green, NOT exit codes).
  END_TS="$(date +%s)"
  python3 - \
    "$run_json" "$forced" "$diff_sha" "$reversible" "$CELL" "$CHORE" "$ARM" "$REP" \
    "$CAP" "$WT" "$START_TS" "$END_TS" \
    > "${SCAFFY_DUELS_RESULTS}/${CELL}.json" <<'PY'
import json,sys
run=json.load(open(sys.argv[1]))
forced=json.loads(sys.argv[2])
diff_sha,reversible=sys.argv[3],sys.argv[4]=="true"
cell,chore,arm,rep=sys.argv[5:9]
cap=float(sys.argv[9]); wt=sys.argv[10]
start,end=int(sys.argv[11]),int(sys.argv[12])
asserts=run.get("asserts",[])
any_fail=any(a.get("status")=="fail" for a in asserts)
forced_red=any(f.get("rc",1)!=0 for f in forced)
gates_green = (not any_fail) and (not forced_red)
out={
  "cell":cell,"chore":chore,"arm":arm,"rep":rep,"cap_usd":cap,
  "worktree":wt,"duration_ms":(end-start)*1000,
  "meter":{"total_cost_usd":0.0,"usage":None,"source":"engine"},
  "score":{
    "gates_green":gates_green,
    "asserts":[{"kind":a.get("kind"),"tier":a.get("tier"),"status":a.get("status"),
                "text":(a.get("text") or a.get("path") or "")[:120]} for a in asserts],
    "tier_ci_forced":forced,
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
  local forced diff_sha reversible
  forced="$(_force_tier_ci)"
  diff_sha="$(git -C "$WT" --no-pager diff | sha256_stdin)"
  reversible=false
  if [[ "$ARM" != "B" && "$COMMAND" != "null" ]]; then
    local vars
    vars="$(matrix_get "chores.${CHORE}.vars")"
    _load_var_flags "$vars"
    ( cd "$WT" && bp scaffy remove "$COMMAND" "${VF[@]}" -o json ) >/dev/null 2>&1 || true
    git -C "$WT" --no-pager diff --exit-code >/dev/null 2>&1 && reversible=true
  fi
  END_TS="$(date +%s)"
  python3 - "$agent_json" "$forced" "$diff_sha" "$reversible" "$CELL" "$CHORE" "$ARM" \
    "$REP" "$CAP" "$WT" "$START_TS" "$END_TS" \
    > "${SCAFFY_DUELS_RESULTS}/${CELL}.json" <<'PY'
import json,sys
try: agent=json.load(open(sys.argv[1]))
except Exception: agent={}
forced=json.loads(sys.argv[2]); diff_sha,reversible=sys.argv[3],sys.argv[4]=="true"
cell,chore,arm,rep=sys.argv[5:9]; cap=float(sys.argv[9]); wt=sys.argv[10]
start,end=int(sys.argv[11]),int(sys.argv[12])
cost=agent.get("total_cost_usd", agent.get("cost_usd"))
usage=agent.get("usage")
forced_red=any(f.get("rc",1)!=0 for f in forced)
out={
 "cell":cell,"chore":chore,"arm":arm,"rep":rep,"cap_usd":cap,"worktree":wt,
 "duration_ms":(end-start)*1000,
 "meter":{"total_cost_usd":cost,"usage":usage,"source":"claude-cli-json"},
 "score":{"gates_green":(not forced_red),"asserts":[],"tier_ci_forced":forced,
          "diff_sha256":diff_sha,"reversible":reversible},
}
print(json.dumps(out,indent=2))
PY
}

_agent_brief() {
  local base doctrine
  base="Complete this Barkpark chore: ${CHORE}. Make the repo's own gates green. Work only in this checkout."
  case "$ARM" in
    Ap) doctrine=" FIRST check the local Scaffy catalog (scaffy/commands/) and prefer \`bp scaffy run\` if a command fits — reach for the catalog before hand-editing." ;;
    A)  doctrine=" The Scaffy catalog is available at scaffy/commands/ if you want it." ;;
    B)  doctrine=" Hand-edit the files directly. Do NOT use scaffy." ;;
    *)  doctrine="" ;;
  esac
  printf '%s%s' "$base" "$doctrine"
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
print()
PY
