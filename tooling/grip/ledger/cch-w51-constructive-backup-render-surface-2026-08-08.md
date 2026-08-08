# cch-w51 · constructive backup render surface — re-derivation recipes (2026-08-08)

Verifier lane `constructive-backup-render-surface`, Cloud Console hardening wave 51.
Every row below is a literal command that re-derives one fact from scratch.
All measured inside a full-tree `git archive origin/main` extraction, never a worktree:

```sh
cd $(mktemp -d) && git -C /Volumes/SATECHI/github/barkpark archive origin/main | tar -x
export TREE=$PWD
```

## R1 — the Timeline empty state, rendered (not read)

```sh
node - "$TREE/cloud/priv/static/app.js" <<'EOF'
const vm=require('vm'),fs=require('fs');
const noop=()=>{},st={getItem:()=>null,setItem:noop,removeItem:noop};
const el={addEventListener:noop,removeEventListener:noop,setAttribute:noop,removeAttribute:noop,
 classList:{add:noop,remove:noop,toggle:noop,contains:()=>false},style:{},hidden:false,value:"",
 innerHTML:"",textContent:"",querySelector:()=>null,querySelectorAll:()=>[]};
const hooks={},sb={__bpTestHook:h=>Object.assign(hooks,h),
 document:{readyState:"loading",addEventListener:noop,removeEventListener:noop,querySelector:()=>null,
  querySelectorAll:()=>[],getElementById:()=>null,createElement:()=>({...el}),
  documentElement:{...el,getAttribute:()=>null},body:{...el,appendChild:noop}},
 window:{addEventListener:noop,removeEventListener:noop,open:()=>null,
  matchMedia:()=>({matches:false,addEventListener:noop})},
 location:{hash:"",pathname:"/",search:"",origin:"http://localhost"},
 localStorage:st,sessionStorage:st,navigator:{},URL,URLSearchParams,
 fetch:()=>Promise.resolve({ok:true,status:200,json:()=>Promise.resolve({})}),
 EventSource:function(){return{addEventListener:noop,close:noop}},
 setTimeout:noop,clearTimeout:noop,setInterval:()=>1,clearInterval:noop,console};
sb.globalThis=sb; vm.createContext(sb);
vm.runInContext(fs.readFileSync(process.argv[1],'utf8'),sb);
console.log(hooks.timelineFeedHtml([],{}));
EOF
```

NOTE: the bare 4-key sandbox in the assignment's MUST-RUN dies with `VM_ERR localStorage is not
defined`. The IIFE touches `localStorage` at eval time; the harness sandbox above
(`cloud/priv/static/__app.test.mjs:30-78`) is the minimum that boots it.

## R2 — the agent sentinel, and that nothing wires the probe

```sh
grep -n 'no backup probe wired' "$TREE/internal/agent/report.go"
grep -rn 'BackupProbe' "$TREE/internal" "$TREE/cmd" --include='*.go' | grep -v '_test.go'
grep -n 'backup_ok\|backup_detail' "$TREE/cloud/test/support/real_agent_beats.ex"
```

## R3 — CONSOLE_PATHS ratchet, mutation-proved both ways

```sh
# baseline: OK, exit 0
bash "$TREE/scripts/console-path-escape-check.sh"
# BREAK: an undeclared internal/** read from the harness
printf '\nconst X=path.join(REPO_ROOT,"internal/agent/report.go");\ntest("p",()=>{fs.readFileSync(X,"utf8")});\n' \
  >> "$TREE/cloud/priv/static/__app.test.mjs"
bash "$TREE/scripts/console-path-escape-check.sh"   # ::error:: UNCOVERED repo-root read
# FIX: declare it in CONSOLE_PATHS (scripts/console-path-escape-check.sh:142-155) -> OK again
```

## R4 — the three-arm cross-fence pin prototype

Prototype lives nowhere in the repo; re-create it and mutate:

```sh
# arm A: app.js contains the sentinel        (RED on pristine main — this is the wave's fix)
# arm B: report.go contains the sentinel     (green; reds on a Go reword)
# arm C: zero non-test BackupProbe assigners under internal/ AND cmd/  (green; reds on wiring)
#
# arm C regex MUST be /BackupProbe\s*[:=]\s*\S/ — the struct-literal-only form
# /BackupProbe:\s*\S/ was mutation-proved BLIND to `c.BackupProbe = func(){...}`.
# arm C walk MUST include cmd/ — cmd/barkpark-agent/main.go:94-127 is where the
# other 12 probes are wired, so an internal/-only walk cannot see the day it changes.
```

## R5 — the surface-choice facts

```sh
sed -n '199,216p' "$TREE/cloud/lib/barkpark_cloud/metrics.ex"          # latest/1 drops backup
grep -n 'function metricsSeries' -A 45 "$TREE/cloud/priv/static/app.js" # drops payload.latest whole
grep -n 'latest' "$TREE/cloud/priv/static/app.js"                      # 21 hits, ZERO read payload.latest
grep -n 'METRIC_STUBS' -A 5 "$TREE/cloud/priv/static/app.js"           # the only non-numeric row precedent
sed -n '15550,15568p' "$TREE/cloud/priv/static/app.js"                 # Activity early-returns its OWN empty state
grep -rn 'Nothing here yet' "$TREE/cloud"                              # 1 hit: app.js only — no test pins it
```

## R6 — the only blocking host

```sh
python3 -c "import json;print([c['context'] for c in json.load(open('$TREE/.github/required-checks.json'))['protection']['required_status_checks']['checks']])"
sed -n '18,22p' "$TREE/.github/workflows/go-tests.yml"   # workflow-level paths: -> structurally unrequireable
```
