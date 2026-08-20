# Unswept out-of-fence harnesses — re-derivation recipes (gate-wiring / spec-generator wave, verify phase)

Base: `origin/main` @ `bf499f54b63135b8ae078305b83f2b5b2c078877`. All commands from a clean
extract of that tree (`git archive origin/main | tar -x -C <tmp>`), never the shared checkout.

## 0. Posture: none of the three harness families can block a merge

```
git show origin/main:.github/required-checks.json | python3 -c "import json,sys;d=json.load(sys.stdin);print([c['context'] for c in d['protection']['required_status_checks']['checks']])"
git show origin/main:.github/required-checks.json | python3 -c "import json,sys;d=json.load(sys.stdin);print([e['context'] for e in d['exclusions']])"
```

Required set is exactly `['Cloud gate','Console gate','Elixir gate','PR references an active task']`.
Neither `Deploy harnesses / offline-deploy-harnesses`, nor any of the 14 `shell-harnesses` job
names, nor `Re-land advisory (already-landed overlap)` appears in required OR in the 25-row
exclusions ledger. Job-level `continue-on-error` in these files: zero in deploy-harnesses.yml,
zero in shell-harnesses.yml (it says so in three comments), `true` in reland-check.yml:41.
No `(blocking)`-shaped job name in any of the three — the naming is honest.

## 1. GAP: instance-deploy_test.sh asserts on `api/start.sh`, which the paths filter misses

```
git show origin/main:.github/workflows/deploy-harnesses.yml | sed -n '4,22p'   # paths: deploy/**, own yml, api/lib/barkpark/sites/deploy_runner.ex
git grep -n 'name-encoding pin' origin/main                                     # only api/start.sh + deploy/instance-deploy_test.sh
```

Plant (in the temp extract):

```
sed -i '' 's/^  export LANG=C\.UTF-8$/  export LANG=C/' api/start.sh
bash deploy/instance-deploy_test.sh; echo "RC=$?"
```

Expected `RC=1` with `FAIL: start.sh guard defaults the name mode to UTF-8`. The harness catches
it; the workflow never runs on that PR, because `api/start.sh` matches no glob in the filter.

## 2. cp-deploy_test.sh: mirrored sed + unanchored grep — the harness cannot see the bug it names

```
bash deploy/cp-deploy_test.sh; echo "RC=$?"       # baseline ALL PASS
python3 - <<'PY'
p='deploy/cp-deploy.sh'; s=open(p).read()
old='    sed -i -E "s#--control-url[= ][^[:space:]\\"\']+#--control-url ${PROV_CONTROL_URL}#g" "$PROV_UNIT"'
new='    sed -i -E "s#--control-url[= ][^[:space:]]+#--control-url http://localhost:4100#g" "$PROV_UNIT"'
assert old in s; open(p,'w').write(s.replace(old,new))
PY
bash deploy/cp-deploy_test.sh; echo "RC=$?"       # still ALL PASS, RC=0
```

Second plant, independent: `sed -i '' '188s/systemctl daemon-reload/: #planted/' deploy/cp-deploy.sh`
also leaves `ALL PASS` (the check is a bare `grep -q 'systemctl daemon-reload'` over the whole
script, and line 217 carries an unrelated second occurrence).

## 3. reland_check.py fetch-verdict precedence is bound by no assertion in 62

```
bash tooling/task-obsession/reland_check.test.sh; echo $?                       # 7 passed
RELAND_REQUIRE_YAML=1 bash tooling/task-obsession/reland_loudfail.test.sh; echo $?  # 55 passed
# disarm:
python3 - <<'PY'
p='tooling/task-obsession/reland_check.py'; s=open(p).read()
s=s.replace('    if meta.get("status") in (STATUS_INFRA, STATUS_SKIPPED):','    if False and meta.get("status") in (STATUS_INFRA, STATUS_SKIPPED):',1)
open(p,'w').write(s)
PY
# both harnesses still exit 0. The disarm IS live:
python3 -c "
import importlib.util
raw={'reland_fetch':{'status':'skipped','note':'token absent'},'documents':[{'id':'task-1','title':'t','type':'task'}]}
spec=importlib.util.spec_from_file_location('rc','tooling/task-obsession/reland_check.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
print(m.classify(raw)[1])"     # pristine -> skipped ; disarmed -> ok
```

## 4. Harnesses that DO red on their subject (safe count = 3 of 5)

```
bash tooling/fleet/fleet-run-verdict-test.sh                     # 32 passed baseline
# plant: insert `printf "verdict=success\ntier=1\nevidence=planted\n"; return 0` as the first
# line of order_verdict() in tooling/fleet/fleet-run.sh  -> 11 passed, 21 failed, RC=1
sed -i '' '56s/GO_ARCH=linux-arm64/GO_ARCH=linux-amd64/' deploy/site-runtime-install.sh
bash deploy/site-runtime-install_test.sh; echo $?                # 2 FAILURE(S), RC=1
```

`deploy/instance-deploy_test.sh` also reds correctly on its own subject (§1) — its defect is
wiring, not blindness.

## 5. Empty-corpus-reports-success census (the generalisation)

```
python3 - <<'PY'
import os,re
roots=['scripts','api/scripts','js/scripts','api/test/scripts','tooling','deploy','.githooks','bin','.github']
tot=0;hits=[]
for r in roots:
  for dp,dn,fn in os.walk(r):
    if '/node_modules' in dp or '/_build' in dp: continue
    for f in fn:
      if not f.endswith(('.sh','.bash')): continue
      p=os.path.join(dp,f); lines=open(p,errors='replace').read().split('\n')
      for i,l in enumerate(lines):
        if l.lstrip().startswith('#'): continue
        if re.search(r'(if\s*\[+|\[\[)\s*!\s+-[dfes]\s', l):
          tot+=1
          if re.search(r'\b(continue|return\s+0|exit\s+0)\b','\n'.join([l]+lines[i+1:i+4])): hits.append((p,i+1))
print(tot, len(hits)); [print(h) for h in hits]
PY
```

98 existence-negation sites; 16 take a success exit within 3 lines; hand-adjudication leaves
exactly **2 genuine fail-open guards**, both already known:

- `js/scripts/check-no-node-imports.sh:14` — proven: move `js/packages/core/src` and
  `js/packages/nextjs/src` aside, run it, get `check-no-node-imports: clean` at exit 0.
- `api/test/scripts/build-plugin-node-matrix.sh:33` — `emit "[]" "true"; exit 0`.

The other 14 are false positives: `docs-anchors-check.sh:119` echoes `FAIL:` into
`/tmp/anchors-out.$$`, which line 140 greps into `FAIL=1`; `workflow-module-smoke.sh:46` sets
`status=1`; `check-bp-graph-drift.sh:66` prints a reason line its `check()` caller treats as
drift (`return 1`); `breakglass-watch.sh:108` returns a state STRING (`UNKNOWN`) the caller
classifies; `deploy/site-deploy.sh:2007` exits 21. **Not a doctrine-level gap — two isolated bugs.**

## 6. Side fact, not a new finding

`bash js/scripts/check-no-node-imports.sh` exits 1 on pristine `origin/main`
(`packages/nextjs/src/draft-mode/index.ts:6` imports `node:crypto`). This is the documented
ADR-002 deferral; `js-tests.yml:119-121` carries `continue-on-error: true` with the reason in a
9-line comment. Honest advisory posture.
