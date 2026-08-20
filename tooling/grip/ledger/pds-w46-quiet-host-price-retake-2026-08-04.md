# PDS wave 46 — quiet-host retake of the six price literals (re-derivation recipe)

Base: `origin/main` = `683c2f00a5f809851f6f3ee2bdd341158349d525`. Host: Darwin 24.5.0, 10 vCPU
(`sysctl -n hw.ncpu` = 10), bash 3.2.57. All figures are OS-meter-around-a-shell CPU (`user + sys`
from `/usr/bin/time -p`), per the charter's own placement law.

## 1. Extract the tree and run the six arms, load-stamped per arm

    D=$(mktemp -d); git -C /Volumes/SATECHI/github/barkpark archive origin/main | tar -x -C $D
    cd $D && uptime && /usr/bin/time -p bash -c '
      for a in "pds-door-census.sh --check" "pds-door-census.sh --selftest" \
               "pds-record-parity.test.sh" "pds-scratch-target_test.sh" "pds-ledger-census_test.sh"; do
        uptime; echo "### $a"
        /usr/bin/time -p bash -c "bash scripts/$a >/dev/null 2>&1; echo rc=\$?"
      done
      uptime
      /usr/bin/time -p bash -c "elixir scripts/pds-status-only-residue.exs --selftest >/dev/null 2>&1; echo rc=\$?"
      :'

The trailing `:` is LOAD-BEARING — see §3.

`git archive origin/main scripts` (scripts-only) gives the same six numbers as the full tree to
within run-to-run noise, even though `--check` greps `api/lib api/test` (`pds-door-census.sh:273`).

## 2. Load-sensitivity control (what a load stamp is worth)

    for i in $(seq 24); do ( while :; do :; done ) & done; sleep 100
    # …re-measure three arms…
    kill $(jobs -p)

load1 3.70 → 30.18 costs +67…+85 % CPU and +190 % wall. `load1` is a LAGGING 1-minute average:
after `kill`, five repeats of `pds-scratch-target_test.sh` at a *printed* load1 of 18.68 all cost
0.49–0.51 s. A load stamp describes the minute before the run, not the run.

## 3. Meter trap — a wrapper around a shell LOOP reports only the LAST arm

    /usr/bin/time -p bash -c 'for a in x y; do /usr/bin/time -p bash -c "…400k…"; done; /usr/bin/time -p bash -c "…200k…"'
    # arms 0.85 + 0.84 + 0.42 → OUTER prints user 0,43   (WRONG, = last arm)
    # append a trailing `:` → OUTER prints user 2,14     (RIGHT, = the sum)

bash execs the final simple command of a `-c` script, discarding its accumulated
`RUSAGE_CHILDREN`. Any `--measure --all` that wraps a loop and quotes the wrapper's total emits a
number ~5x under the truth. Mutation-proven both directions.

## 4. Reproducibility of the six literals (n = 8 passes, load1 2.48 – 9.33)

| arm | ledger literal | quiet CPU range | load1≈30 CPU | verdict |
|---|---|---|---|---|
| `pds-door-census.sh --check` | 3.32 (load1 41.63) | 1.21 – 1.93 | 2.25 | reproduces load-corrected |
| `pds-door-census.sh --selftest` | 0.16 (load1 41.63) | 0.09 – 0.19 | — | reproduces |
| `pds-record-parity.test.sh` | 4.45 (load1 26.44) | 1.73 – 2.82 | 3.35 | reproduces load-corrected |
| `pds-scratch-target_test.sh` | **8.91** (load1 79.23) | **0.49 – 0.69** | **0.90** | **UNREPRODUCIBLE (13–18x)** |
| `pds-ledger-census_test.sh` | 40.33 (load1 24.26) | 19.18 – 22.36 | — | reproduces load-corrected |
| `pds-status-only-residue.exs --selftest` | 0.82 (load1 26.44) | 0.72 – 0.86 | — | reproduces |

`scripts/pds-scratch-target_test.sh` is byte-identical to `6f4ca7904` (2026-07-28), a week BEFORE
the 8.91 stamp — so a content key would have called 8.91 FRESH forever. Verify with
`git log --format='%h %ad' --date=short origin/main -- scripts/pds-scratch-target_test.sh`.
The harness stubs `barkpark` (`:65-70`) and never calls `initdb`/`pg_ctl`; 32 PASS lines, 0 SKIP.
