# PDS w42 — gate + fence health at DECIDE time (re-derivation recipe)

Measured 2026-08-02 against `origin/main` = `5444aa5e1ea8bc643ba8c7a100f9173413c688a4`.
Every number below was re-derived, not inherited from the wave-42 survey.

## 0. THE CHECKOUT IS NOT origin/main — measure from an archive, never from the tree

    git -C /Volumes/SATECHI/github/barkpark rev-list --left-right --count origin/main...HEAD
    #   356   48        <- 356 behind / 48 ahead; local branch `main` has DIVERGED
    git -C /Volumes/SATECHI/github/barkpark status --porcelain | wc -l
    #   216
    ls /Volumes/SATECHI/github/barkpark/scripts/pds-status-only-residue.exs
    #   No such file or directory   <- present on origin/main, ABSENT in the tree

This is the true cause of the survey's two `not_found`s. They were not grep errors.
Clean-room command used for every measurement below:

    git -C /Volumes/SATECHI/github/barkpark archive origin/main | tar -x -C <scratch>/m42

## 1. THE FENCE IS UNOCCUPIED — re-measured, not inherited

    gh pr list --state open --limit 50 --json number,files \
      --jq '.[] | "\(.number) github=\([.files[].path]|map(select(startswith(".github/")))|length)"'
    #   9237 github=0 / 8500 0 / 8465 0 / 6086 0 / 6057 0 / 6028 0 / 2907 0   (7 open PRs, ZERO)

    for b in $(git for-each-ref --sort=-committerdate --format='%(refname:short)' --count=25 refs/remotes/origin | grep -v '^origin/main$'); do
      echo "$(git diff --name-only origin/main...$b | grep -c '^\.github/') $b"; done | sort -rn | head -3
    #   0 origin/pds-scim-audit-41 ... all 24 branches: 0

## 2. BRANCH PROTECTION — LIVE 2, COMMITTED 4 (the phantom pair)

    gh api repos/:owner/:repo/branches/main/protection --jq '.required_status_checks.contexts'
    #   ["Elixir gate","PR references an active task"]

    git show origin/main:.github/required-checks.json | python3 -c "import json,sys;d=json.load(sys.stdin);print([c['context'] for c in d['protection']['required_status_checks']['checks']])"
    #   ['Cloud gate', 'Console gate', 'Elixir gate', 'PR references an active task']

`Test (Elixir 1.18.1 / OTP 27.0)` is an EXPLICIT entry in the spec's `exclusions`
list — it is deliberately NOT requirable. An api/test case rides `Elixir gate`,
which aggregates it (`elixir.yml:646 needs: [changes, mix-test, …]`) and is
fail-closed: a `skipped` mix-test greens ONLY when `changes.outputs.test == 'false'`.

## 3. MAIN'S TWO ADVISORY REDS ARE INHERITED, NOT WAVE-CAUSED

    sha=$(git rev-parse origin/main)
    gh api "repos/:owner/:repo/commits/$sha/check-runs?per_page=100" \
      --jq '.check_runs[] | "\(.conclusion // .status)\t\(.name)\tstarted=\(.started_at)"' | sort
    #   failure  Sobelow static analysis (regression gate, baseline .sobelow-skips) (27.0, 1.18.1)  started=2026-08-02T14:05:01Z
    #   failure  Required-check spec drift (advisory)                                               started=2026-08-02T14:03:18Z
    #   (30 other rows: success/skipped)

    for sha in $(git rev-list -6 origin/main); do gh api "repos/:owner/:repo/commits/$sha/check-runs?per_page=100" \
      --jq '.check_runs[]|select(.conclusion=="failure")|"  FAIL \(.name)"'; done
    #   the SAME two on 5 of the last 6 heads; ebc034dfa carries ZERO check runs (NO-RUN, not green)

NO name on main's head carries both a green and a red run — no stale-green/fresh-red pair.
`Sobelow` is the one `continue-on-error: true` job in security.yml (line 227), which is why
`Security gate` concludes success beside it.

## 4. THE SOBELOW BASELINE IS 24, WITH ITS HISTOGRAM — deciding scan only

The job runs THREE Sobelow scans. Only the FIRST (step
"Sobelow (--skip reads api/.sobelow-skips baseline; --exit Low reds on any NEW finding)")
decides. A whole-log grep reads **128**, which is 3 scans summed and is never the baseline.

    gh run view --job 91505734486 --log > sobelow.log     # job on 5444aa5e1
    grep -n "Running Sobelow\|SCAN COMPLETE" sobelow.log  # deciding block = lines 1408..1603
    sed -n '1408,1603p' sobelow.log | perl -pe 's/^.*?\d{4}-\d{2}-\d{2}T[\d:.]+Z //; s/\e\[[0-9;]*m//g' \
      | grep -oE '^[A-Za-z]+\.[A-Za-z]+: [^-]*- [A-Za-z]+ Confidence' | sort | uniq -c | sort -rn

    #   7 SQL.Query: SQL injection - Low Confidence
    #   3 Traversal.FileModule: Directory Traversal in `File.rm` - Low
    #   3 SQL.Stream: SQL injection - Low
    #   3 Config.CSRF: Missing CSRF Protections - HIGH
    #   2 Traversal.FileModule: `File.rm_rf` - Low
    #   2 CI.System: Command Injection via `System` function - Low
    #   1 each: File.write / File.stream! / File.read / File.read!  - Low
    #   TOTAL 24 = Traversal.FileModule 9 / SQL.Query 7 / SQL.Stream 3 / Config.CSRF 3 / CI.System 2

Confidence split over the same block: **3 High / 21 Low**, and all three Highs are
`Config.CSRF`. THEREFORE the circulating **21**-itemization is 24 minus exactly the three
High-Confidence CSRF rows — it drops the only High-Confidence findings in the scan.
Quote 24 with this histogram or quote no baseline at all.

## 5. THE DRIFT RED'S OWN SHAPE, AND THE CHECK IT SUPPRESSES

    gh api repos/:owner/:repo/actions/runs/30751198103/jobs \
      --jq '.jobs[]|select(.name|startswith("Required-check spec drift"))|.steps[]|"\(.conclusion)\t\(.name)"'
    #   failure  Prove the toolchain against the live API (§10, §11)
    #   skipped  Three-way drift check (spec ↔ live protection ↔ rendered names)
    # log tail: "required-checks: 114 passed, 1 failed"
    #   FAIL full mode reds on the committed spec — hgw2-s7's slice gate cannot pass

The single failure IS the four-vs-two gap of §2. Its consequence is that the three-way
drift check has still never run on main. (Charter D583, re-confirmed by run today.)

## 6. ZERO PDS INSTRUMENTS ARE WIRED TO CI — still true, cleanly

    for t in pds-status-only-residue pds-record-parity pds-elixir-receipt-census pds-ledger-census pds-; do
      git grep -l -- "$t" origin/main -- .github; echo "[$t] rc=$?"; done
    #   every one: rc=1, no files

## 7. THE CI-CROSSING IDEA — priced, with its trap

    cd <scratch>/m42 && /usr/bin/time -p elixir scripts/pds-status-only-residue.exs --selftest
    #   SELFTEST: 15 PASS / 0 FAIL of 15 arms
    #   SELFTEST GREEN — exit 0        RC=0
    #   real 1,06   user 0,52   sys 0,28     (Elixir 1.19.5/OTP 28 local; CI pins 1.18.1/OTP 27)

Precedent exists: `api/test/barkpark/async_global_seam_guard_test.exs:24` already reaches a
`scripts/*.exs` instrument, and `scripts/async_env_seam_scan.exs` is a declared
`ELIXIR_TEST_ONLY_PATHS` entry.

THE TRAP, which is a DISPATCH bug and not merely a ratchet bug:
`scripts/elixir-path-escape-check.sh` only sees string literals matching `"\.\./[^"]*"`
(list_escapes, `grep -Eoh '"\.\./[^"]*"'`). A test that names the script with a `"../…"`
literal is CAUGHT and forces the same-PR `ELIXIR_TEST_ONLY_PATHS` line. A test that
constructs the path any other way is NOT caught — and then a PR touching only
`scripts/pds-status-only-residue.exs` leaves `changes.outputs.test == 'false'`, mix-test is
LEGITIMATELY skipped, `Elixir gate` greens, and the instrument's guard never runs on the very
PR that changes the instrument. The `ELIXIR_TEST_ONLY_PATHS` line is load-bearing for
correctness, not paperwork.
