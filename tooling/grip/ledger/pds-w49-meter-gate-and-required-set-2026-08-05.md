# PDS wave 49 — meter.py mutation matrix, the twin/corpus fail-opens, and the required-check set

Re-derivation recipes. Every row is one literal command; nothing here is a claim
about a tree other than `origin/main` at the time of the run (2026-08-05).

## 0. Build the two probe trees

    # TWIN-ONLY tree (three files, NO results/ corpus)
    S=$(mktemp -d); cd /Volumes/SATECHI/github/barkpark
    for f in meter.py tally_wf.py METER.md; do git show origin/main:tooling/scaffy-duels/$f > $S/$f; done

    # FULL tree (with the 34-envelope corpus)
    F=$(mktemp -d); git archive origin/main tooling/scaffy-duels | tar -x -C $F
    cd $F/tooling/scaffy-duels

Baseline, both trees: `python3 meter.py --self-test; echo rc=$?` → rc=0.

## 1. MUT_A — tally_wf.py RATES drift reds BOTH halves

    cd $F/tooling/scaffy-duels
    sed -i '' 's/"claude-opus-5": (5.00, 25.00),/"claude-opus-5": (5.01, 25.00),/' tally_wf.py
    python3 meter.py   --self-test >/dev/null 2>&1; echo meter=$?    # 1
    python3 tally_wf.py --self-test >/dev/null 2>&1; echo tally=$?   # 1

## 2. MUT_B — meter.py multiplier drift reds tally_wf.py (symmetry)

    sed -i '' 's/^CACHE_READ = 0.10/CACHE_READ = 0.11/' meter.py
    python3 tally_wf.py --self-test >/dev/null 2>&1; echo tally=$?   # 1

## 3. MUT_C — METER.md population drift. TAKE rc WITHOUT A PIPE.

    # C1: marker only (doc self-inconsistent)
    sed -i '' 's/<!-- meter:population 34 -->/<!-- meter:population 35 -->/' METER.md
    python3 meter.py --self-test >/dev/null 2>/dev/null; echo rc=$?  # 1

    # C2: marker AND prose (doc self-consistent, wrong vs corpus)
    sed -i '' 's|34/34\*\*|35/35**|' METER.md
    python3 meter.py --self-test >/dev/null 2>/dev/null; echo rc=$?  # 1  (FULL tree)

    # C2b: THE SAME MUTATION IN THE TWIN-ONLY TREE
    cp METER.md $S/METER.md; cd $S
    python3 meter.py --self-test 2>/dev/null; echo rc=$?             # 0  <-- FAIL-OPEN

## 4. MUT_D — twin absent is indistinguishable from twin correct

    cd $F/tooling/scaffy-duels && rm tally_wf.py
    python3 meter.py --self-test; echo rc=$?                          # 0, "parity unasserted"

## 5. MUT_E — the corpus grows, the §3 DOLLARS stay frozen, nothing reds

    cp $(ls results/*.agent.json | head -1) results/zz-probe.agent.json
    sed -i '' 's/<!-- meter:population 34 -->/<!-- meter:population 35 -->/; s|34/34\*\*|35/35**|' METER.md
    python3 meter.py --self-test >/dev/null 2>/dev/null; echo rc=$?   # 0
    python3 meter.py verify results                                   # 35 exact, population 35 matches
    grep -n '66.40' METER.md                                          # still "n=34 ($66.40)"

## 6. Are the §3 dollars re-derivable BY meter.py? No — but they are TRUE.

meter.py has exactly two verbs (`verify`, `--self-test`); neither emits a corpus
total or a component share. The figures reproduce only via an ad-hoc script:

    cd $F/tooling/scaffy-duels && python3 - <<'EOF'
    import json,glob,statistics,importlib.util
    spec=importlib.util.spec_from_file_location("m","meter.py")
    m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    tot=0;costs=[];comp={'w':0,'r':0,'o':0,'i':0}
    for f in sorted(glob.glob('results/**/*.agent.json',recursive=True)):
        e=json.load(open(f)); tot+=e['total_cost_usd']; costs.append(e['total_cost_usd'])
        u=e['usage']; ip,op=m.rate_for(list(e['modelUsage'])[0])
        cc=u.get('cache_creation',{}) or {}
        comp['w']+=(cc.get('ephemeral_5m_input_tokens',0)*ip*m.CACHE_WRITE_5M+cc.get('ephemeral_1h_input_tokens',0)*ip*m.CACHE_WRITE_1H)/1e6
        comp['r']+=u.get('cache_read_input_tokens',0)*ip*m.CACHE_READ/1e6
        comp['o']+=u.get('output_tokens',0)*op/1e6
        comp['i']+=u.get('input_tokens',0)*ip/1e6
    s=sum(comp.values()); print(len(costs),"%.4f"%tot,"%.4f"%statistics.median(costs),
          {k:"%.1f%%"%(100*v/s) for k,v in comp.items()})
    EOF
    # 34 66.4049 0.5857 {'w':'24.2%','r':'66.4%','o':'9.3%','i':'0.1%'}

Every published §3 n=34 figure reproduces to the digit. The disease is not a
wrong number — it is that NOTHING RE-TAKES IT (see MUT_E).

## 7. The required-check set — L1, from the running system

    gh api repos/FRIKKern/barkpark/branches/main/protection \
      --jq '.required_status_checks.checks[] | "\(.context) [\(.app_id)]"'
    # Elixir gate / PR references an active task / Cloud gate / Console gate — FOUR.

Do NOT use `grep -c context .github/required-checks.json` (=34): it counts the
exclusion rows too.

    # shell-harnesses.yml renders NO name in that file, required or excluded:
    git show origin/main:.github/required-checks.json | grep -i 'doctor\|merge-verb\|release-scan\|Shell harness'   # empty

    # zero workflows name any of these:
    for f in $(git ls-tree -r --name-only origin/main .github/workflows); do \
      git show origin/main:$f | grep -l 'scaffy-duels\|meter\.py\|tally_wf\|tooling/pds' >/dev/null && echo $f; done   # empty

## 8. Price, with the host band stamped

Host: darwin, cpus=10 (physical==logical), load1 4.24–4.30.

    meter.py --self-test   real 0.03–0.04s   user 0.02s   (n=3)
    meter.py verify results real 0.02s       user 0.01s   (n=3)
    tally_wf.py --self-test real 0.02s       user 0.01s
