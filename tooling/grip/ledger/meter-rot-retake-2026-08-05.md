# meter-rot-retake — 2026-08-05 (PDS wave 48 verifier, assignment `meter-rot-retake`)

Re-derivation recipes for every figure quoted in the wave-48 verify report on
`tooling/scaffy-duels/METER.md` + `meter.py`. Host: darwin, `origin/main` =
`467f7e283`. `git diff --stat origin/main -- tooling/scaffy-duels/` is EMPTY, so
the working-tree files under `tooling/scaffy-duels/` ARE origin/main's bytes.

## R1 — the instrument runs, is non-vacuous, and is fast

    cd tooling/scaffy-duels
    python3 meter.py verify results/          # "meter.py: 34 envelopes — 34 exact"  rc=0
    python3 meter.py --self-test              # "self-test OK (greens on faithful, reds on 1.25x-trap fixture)" rc=0
    python3 meter.py self-test                # NO SUCH SUBCOMMAND: prints __doc__, rc=2
    /usr/bin/time -p python3 meter.py verify results/    # real ~0,04

## R2 — the population grew 24 -> 34 and METER.md never moved

    git ls-tree -r --name-only 04893e486 -- tooling/scaffy-duels/results | grep -c agent.json   # 24
    git ls-tree -r --name-only origin/main -- tooling/scaffy-duels/results | grep -c agent.json # 34
    git log --oneline -- tooling/scaffy-duels/METER.md    # single commit 04893e486 (#4028)

## R3 — median cost shares, ORIGINAL-24 vs ALL-34 vs the 10 arrivals

Script: `/private/tmp/.../scratchpad/shares.py` (reproduced inline below).
Per envelope, price each component with `meter.rate_for(model)` and the METER §2
formula, express as % of that envelope's `total_cost_usd`, then take the MEDIAN.

    ORIGINAL-24 n=24: writes 58.8%  reads 32.5%  output 7.9%   <- reproduces METER.md §3 exactly
    ALL-34      n=34: writes 55.0%  reads 36.8%  output 9.5%
    NEW-10      n=10: writes 26.0%  reads 62.5%  output 10.4%

Cost-weighted (dollar-share of the whole corpus, not per-envelope median):

    24 ($17.08): writes 46.9%  reads 43.5%  output 9.6%
    34 ($66.40): writes 24.2%  reads 66.4%  output 9.3%   <- the LEVER INVERTS

    python3 - <<'EOF'
    import json,glob,os,sys,statistics,subprocess
    sys.path.insert(0,'tooling/scaffy-duels'); import meter
    old=set(x.split('/')[-1] for x in subprocess.check_output(
      ['git','ls-tree','-r','--name-only','04893e486','--','tooling/scaffy-duels/results']
      ).decode().split() if x.endswith('agent.json'))
    rows=[]
    for f in sorted(glob.glob('tooling/scaffy-duels/results/*.agent.json')):
        e=json.load(open(f)); u=e['usage']; ri,ro=meter.rate_for(next(iter(e['modelUsage'])))
        cc=u.get('cache_creation') or {}; t=e['total_cost_usd']
        rows.append((os.path.basename(f) in old,
          (cc.get('ephemeral_5m_input_tokens',0)*ri*1.25+cc.get('ephemeral_1h_input_tokens',0)*ri*2.0)/1e6/t*100,
          u.get('cache_read_input_tokens',0)*ri*0.1/1e6/t*100,
          u.get('output_tokens',0)*ro/1e6/t*100))
    for lbl,sel in [('24',lambda r:r[0]),('34',lambda r:True),('new10',lambda r:not r[0])]:
        v=[r for r in rows if sel(r)]
        print(lbl,len(v),[round(statistics.median([r[i] for r in v]),1) for i in (1,2,3)])
    EOF

Spawn floor ($0.55) still holds: median `total_cost_usd` over the 24 = $0.5451,
over the 34 = $0.5857.

## R4 — rate_for() probe (fail-closed only on the single-model path)

    cd tooling/scaffy-duels && python3 -c "
    import sys;sys.path.insert(0,'.');import meter
    for m in ['claude-opus-5','claude-opus-4-1-20250805','claude-sonnet-4-5','claude-haiku-5']:
        print(m, meter.rate_for(m))"
    # claude-opus-5 None / claude-opus-4-1-... (5.0,25.0) / claude-sonnet-4-5 None / claude-haiku-5 None

## R5 — the fail-OPEN mutation battery (three silent passes)

Build four mutants from `results/add-error-shape--A--1.agent.json` in a mktemp -d:
1. unknown model, single-model `modelUsage`      -> FAIL "no rate registered", rc=1  (fail-CLOSED)
2. unknown model, TWO models, `total_cost_usd` x3 -> "identity-only", rc=0           (fail-OPEN)
3. `modelUsage` deleted, `total_cost_usd` x10     -> "identity-only", rc=0           (fail-OPEN)
4. faithful envelope nested one dir deeper, cost $999 -> NEVER WALKED (3 envelopes, not 4)

`cmd_verify` globs `os.path.join(p,"*.agent.json")` (meter.py:104-108) — one level only.

## R6 — nothing calls it

    grep -rn "meter" .github/workflows/            # rc=1, no output (41 workflow files)
    grep -rn "meter\.py" Makefile .githooks scripts .github   # rc=1
    grep -n "METER\|meter.py\|scaffy-duels" .claude/workflows/bp-pds-charter.md   # rc=1
    git show origin/main:scripts/pds-door-census.sh | grep -c scaffy   # 0

## R7 — the SECOND rate table, and its silent dollar drop

`tooling/scaffy-duels/tally_wf.py:28-41` mirrors RATES "not imported, to keep this
a single dependency-free file". Unknown model -> `no_rate.add(model); continue`
(:87-90): tokens still counted, DOLLARS DROPPED, rc always 0.

    D=$(mktemp -d); # two jsonl lines, one claude-sonnet-5 + one claude-opus-5-20260401
    python3 tooling/scaffy-duels/tally_wf.py "$D"
    # total_usd_computed 0.345, per_model_usd {claude-sonnet-5: 0.345},
    # unrated_models ["claude-opus-5-20260401"], rc=0

`/papers/epic-cycle-research-program-abcde` names METER.md/tally_wf.py as its cost
axis (`bp paper view epic-cycle-research-program-abcde | grep -n "METER"` -> :42,:145).
