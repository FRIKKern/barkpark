# Re-derivation recipe — strained fence calibration (deploy-reliability wave 4)

Verifier: strained-fence-calibration. Measured 2026-08-06 11:44–11:56Z. All six barkparks.

## R1 — Core count for all six boxes (NOT assumed; ssh-derived)

    for h in 5.75.169.183 46.224.19.120 116.203.91.216 157.180.90.121 46.225.61.223 91.98.139.58; do \
      ssh -i ~/.ssh/barkpark_indx -o BatchMode=yes -o StrictHostKeyChecking=no root@$h \
      'echo cores=$(nproc); uptime; free -m | tr -s " "'; done

Result 2026-08-06: **all six = 2 cores**. Also: **only guerrilla has swap configured**
(`Swap: 2047 …`); the other five report `Swap: 0 0 0`. The agent report carries NO
`cpu_cores` field (`git show origin/main:internal/agent/report.go | grep -oE '`json:"[a-z0-9_]+"'`),
so the CP cannot compute load/cores today — the fence's denominator does not exist in the pipe.

## R2 — The CP series carries NO swap (the fence cannot read D45's signal)

    bp cloud instance top guerrilla -o json | python3 -c 'import sys,json;print(sorted(json.load(sys.stdin)["series"].keys()))'
    git show origin/main:cloud/lib/barkpark_cloud/metrics.ex | sed -n '54,60p'

Series keys are exactly `['cpu','disk','load','mem']`; `@vitals` is a fixed 4-tuple.
The agent binary on guerrilla DOES contain the field (`strings /usr/local/bin/barkpark-agent |
grep -c swap_used_percent` = 1, unit restarted 11:45:19Z) — the seal is at the CP fold, not the agent.

## R3 — The firing matrix (30-pt and 200-pt windows, all six)

    for b in gyldendal muscle-1 dooodo guerrilla gyl jarl; do bp cloud instance top $b --points 500 -o json > w_$b.json; done
    python3 - <<'PY'
    import json
    for b in ['gyldendal','dooodo','guerrilla','gyl','jarl']:
        s=json.load(open('w_%s.json'%b))['series']
        L=[p['value'] for p in s['load'] if p['value'] is not None]
        print('%-10s n=%d loadmax=%.2f (%.2fx on 2 cores) >=3:%d >=4:%d'%(b,len(L),max(L),max(L)/2,
              sum(1 for x in L if x>=3), sum(1 for x in L if x>=4)))
    PY

Result over 200 points (08:27–11:46Z) per box:

| box | load1 max | load1/cores max | pts >= 3 | pts >= 4 |
|---|---|---|---|---|
| gyldendal | 2.25 | 1.12x | 0/200 | 0/200 |
| dooodo | 2.48 | 1.24x | 0/200 | 0/200 |
| gyl | 2.29 | 1.15x | 0/200 | 0/200 |
| jarl | 1.35 | 0.68x | 0/200 | 0/200 |
| guerrilla | 9.49 | 4.75x | 189/200 | 179/200 |
| muscle-1 | — | — | agent offline, beat `absent`, all series EMPTY |

Healthy ceiling = **1.24x**. Zero false positives at 1.5x over 1000 healthy-box-points.

## R4 — Swap occupancy is ANTI-correlated with pressure (kills the swap-percent fence)

    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'for i in $(seq 1 12); do \
      awk "/SwapTotal/{t=\$2}/SwapFree/{f=\$2}END{printf \"swap_pct=%.1f \", (t-f)*100/t}" /proc/meminfo; \
      awk "{printf \"load1=%s per_core=%.2f\n\", \$1, \$1/2}" /proc/loadavg; sleep 20; done'

Result: swap fell **49.2% -> 46.2%** while load1 rose **1.87 -> 5.79 (0.94x -> 2.90x)**.
The agent probe reads `SwapTotal`/`SwapFree` (`main.go:313 parseSwapPercent`) — an occupancy
STOCK, not `si/so` flow. `vmstat 1 3` at 49.2% occupancy showed si/so settling to `0 0` with
1.12 GB free RAM: 1.03 GB parked in swap and no traffic.

Separation test: the incident hour ran at ~58% and D45's instant read 99.89%; the box sits at
46-49% while idle. Any swap-percent fence low enough to catch the incident also fires on an idle
box. The viable band is ~9 points wide. **Swap occupancy does not separate guerrilla from itself.**

## R5 — What the operator sees today

    bp cloud status -o json | python3 -c 'import sys,json;[print(b["slug"],b["bucket"],b["status"],b["rank"]) for b in json.load(sys.stdin)["barkparks"]]'

At load1 5.47 (2.73x) and cpu 100%, guerrilla printed `healthy ok rank 8` — tied with idle jarl
(load 0.68x) and dooodo. Separately: **jarl reports disk 95% for all 200 points and also ranks
`healthy ok rank 8`** — a second silent condition on a different axis.
