# Re-derivation recipes — register-gate enforceability (DR wave 23, priority 3)

All commands assume `cd /Volumes/SATECHI/github/barkpark`. The local checkout was
**664 commits behind origin/main** at measurement time, so every recipe below reads
`origin/main`, never the worktree.

## R0 — materialize origin/main into a throwaway git repo (prerequisite)

    D=/tmp/rcmain; rm -rf $D; mkdir -p $D
    git archive origin/main | tar -x -C $D
    cd $D && git init -q . && git add -A && git -c user.email=a@b -c user.name=a commit -qm base

`scripts/required-checks.test.sh` §13 runs `git ls-files` from the repo root; without
the index it produces a spurious FAIL.

## R1 — the three path-escape matchers, against the synthetic changed-file list

    for s in console cloud; do for p in internal/cli/foo.go internal/agent/other.go \
      internal/agent/report.go cloud/lib/x.ex api/lib/y.ex; do
        printf '%s %s -> ' $s $p; echo $p | bash /tmp/rcmain/scripts/$s-path-escape-check.sh --match $s; done; done
    # elixir takes compile|test, NOT "elixir":
    for t in compile test; do for p in …; do echo $p | bash /tmp/rcmain/scripts/elixir-path-escape-check.sh --match $t; done; done

## R2 — the declared sets, printed rather than transcribed

    bash /tmp/rcmain/scripts/console-path-escape-check.sh --print-set console
    bash /tmp/rcmain/scripts/cloud-path-escape-check.sh    --print-set cloud
    bash /tmp/rcmain/scripts/elixir-path-escape-check.sh   --print-set test
    bash /tmp/rcmain/scripts/elixir-path-escape-check.sh   --print-set compile

## R3 — baseline, then the leaf-job mutation (does required-checks-drift red?)

    cd /tmp/rcmain && bash scripts/required-checks.test.sh --hermetic | tail -3   # 166 passed, 0 failed (~2m48s)
    # add a leaf job `dr-register-gate` and append it to console-gate's `needs:`
    python3 -c "…exact-string replace on .github/workflows/console-harness.yml…"
    bash scripts/required-checks.test.sh --hermetic | tail -3                     # 166 passed, 0 failed — UNCHANGED
    bash scripts/absent-context-census.test.sh | tail -3                          # 35 passed, 0 failed

Do NOT use `perl -pi -e` for workflow mutations (charter D368 method trap).

## R4 — the laundering proof: extract console-gate's decide body and run it

    cd /tmp/rcmain
    awk 'NR>940{ if ($0=="") {print ""; next} if (match($0,/^ +/)==0) exit; ind=RLENGTH; \
      if (ind<=8) exit; print substr($0,11)}' .github/workflows/console-harness.yml > /tmp/cgate.sh
    R_CHANGES=success R_UNIT=success R_CSSOM=success R_TIER=success R_OVERFLOW=success \
      R_ESCAPE=success O_CONSOLE=true R_DR_REGISTER=failure bash /tmp/cgate.sh; echo "EXIT=$?"
    # -> "Console gate: every upstream job either succeeded…" EXIT=0 while the new leaf FAILED.

`NR>940` is the line of console-gate's `run: |`; re-derive it with
`grep -n 'run: |' .github/workflows/console-harness.yml | tail -1`.

## R5 — the exclusion-row question, answered from the committed file

    git show origin/main:.github/required-checks.json | jq -r '.exclusions[].context' | grep -iE 'tier|overflow'
    # -> empty. `tier-floor-render` / `overflow-guard` ARE console-gate `needs:` and carry NO S3 row.

## R6 — the required set and the disqualified harness workflows

    gh api repos/:owner/:repo/branches/main/protection --jq '.required_status_checks.contexts'
    git show origin/main:.github/workflows/deploy-harnesses.yml | sed -n '1,12p'   # workflow-level on: paths:
    git show origin/main:.github/workflows/shell-harnesses.yml  | sed -n '50,78p'  # workflow-level on: paths:
