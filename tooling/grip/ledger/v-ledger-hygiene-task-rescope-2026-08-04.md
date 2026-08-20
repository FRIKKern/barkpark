# V — ledger hygiene + task re-scope, PDS wave 46 (2026-08-04)

Base for EVERY row below: `origin/main = 683c2f00a5f809851f6f3ee2bdd341158349d525`,
charter blob `bb6796c8294f083b0efcc344096d427339df7996`.
The primary checkout was **408 commits behind** origin/main when this ran
(`HEAD=a31faa52d`), so every fact here was derived from an extracted tree, never
from the working copy:

    mkdir -p /tmp/pdsmain && git -C /Volumes/SATECHI/github/barkpark archive origin/main | tar -x -C /tmp/pdsmain

## Re-derivation recipes

| # | Claim | Command |
|---|---|---|
| 1 | 4 of the 6 "stale-open" rows are ALREADY `done` | `for t in pds-w45-lega-argument-list pds-w44-judgment-coverage-ladder pds-w45-criterion-venue pds-w45-sweep-failopen pds-w45-census-row-check-evidence pds-w44-lv-verdict-unresolved-spec-arm pds-w44-charter-sweep-adjudication; do echo "== $t"; bp task get $t -o json \| python3 -c "import json,sys;d=json.load(sys.stdin)['doc'];print(d['lifecycle_status'], d.get('criteria_progress'), (d.get('claim') or {}))"; done` |
| 2 | `declined_live=0` on main (the '?' arm rule-out holds) | `cd /tmp/pdsmain && elixir scripts/pds-elixir-receipt-census.exs \| grep declined_live` |
| 3 | sweep `--selftest` is 3 of 3 at rc=0 (discharges CSA C5) | `cd /tmp/pdsmain && bash scripts/pds-charter-ledger-sweep.sh --selftest; echo rc=$?` |
| 4 | sweep fail-open GONE on main (discharges CSA C6/C7) | `git show origin/main:scripts/pds-charter-ledger-sweep.sh \| grep -c allow_error` |
| 5 | arrivals are **71**, not 45/59 — count moved a FIFTH time | `cd /tmp/pdsmain && bash scripts/pds-charter-ledger-sweep.sh \| grep 'unresolved-claim arrivals'` |
| 6 | the committed CONTENT-RED row still says "(59 arrivals)" — stale ON MAIN | `git show origin/main:scripts/pds-door-census.sh \| grep -n '59 arrivals'` |
| 7 | door census: rc=0, 4 of 20 THROUGH, 1.31 s wall | `cd /tmp/pdsmain && /usr/bin/time -p bash scripts/pds-door-census.sh \| grep 'THROUGH a required gate'` |
| 8 | hetzner `--selftest-offline` rc=0 (CPU 1.23 s); `--selftest` rc=3 | `cd /tmp/pdsmain && bash scripts/pds-live-hetzner-placement-group.sh --selftest-offline; echo rc=$?` |
| 9 | ZERO Elixir reader of `internal/cli/testdata/**` → an `ELIXIR_TEST_ONLY_PATHS` entry would be unenforceable | `grep -rn 'internal/cli/testdata' /tmp/pdsmain/api/` (empty) |
| 10 | go-tests.yml carves out 3 testdata paths, NOT `internal/cli/testdata/**` | `git show origin/main:.github/workflows/go-tests.yml \| grep -n 'testdata\|fixtures\|templates'` |
| 11 | 12 (not 19) open PDS rows carry zero acceptance criteria; ZERO open PDS rows carry a live claim | page `bp task ls --limit 500 --offset {0,500,…,5000} -o json`, dedupe on `doc_id`, filter `doc_id.startswith('pds-') and lifecycle_status=='open'` |

## Shell traps hit here

* `grep --include=*.exs` is **word-split by zsh into a glob** and dies `no matches found`.
  Quote every `--include='*.exs'`.
* `timeout` is not installed on this host (`command not found`, rc=127).
* The extracted tree's scripts lose the executable bit through `git archive | tar`;
  invoke with `bash scripts/…`, not `./scripts/…` (rc=126 otherwise).
