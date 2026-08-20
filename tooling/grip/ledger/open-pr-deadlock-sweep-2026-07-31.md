# open-pr-deadlock-sweep — 2026-07-31 (cch wave 12, verify phase)

Re-derivation recipes for the wave-12 merge-path verdict. Every row is a single
command that reproduces the claim from scratch. Run them from a checkout, but
read the SPEC AND THE SCRIPT FROM origin/main — the primary checkout at the time
of this sweep was `ahead 48, behind 163` and its `.github/required-checks.json`
still said `enforced=false` with 2 contexts, which silently changes the answer.

## 0. Materialise origin/main's toolchain (do this FIRST — see the trap below)

    SD=$(mktemp -d); git archive origin/main scripts .github | tar -x -C "$SD"
    jq -r '.enforced, ([.protection.required_status_checks.checks[].context]|join(","))' "$SD/.github/required-checks.json"
    # expected: true / Cloud gate,Console gate,Elixir gate,PR references an active task

TRAP (cost me a whole sweep): running `scripts/required-checks-verify.sh` from
the working tree used a 163-commit-stale spec (2 contexts, enforced=false) and
reported a DIFFERENT missing-set for the same heads. The verdict was directionally
the same; the evidence was not.

## 1. Deadlock sweep over every open PR head

    for sha in $(gh pr list --repo FRIKKern/barkpark --json headRefOid -q '.[].headRefOid'); do
      out=$(bash "$SD/scripts/required-checks-verify.sh" --deadlock --sha "$sha" 2>&1); rc=$?
      echo "$sha rc=$rc :: $(echo "$out" | tr '\n' '|')"
    done

Never `| tail` inside the loop: `$?` then reports tail's status and every head
reads rc=0 (the rotating-charter-slot trap, recurred here).

## 2. Live protection vs the committed spec

    gh api repos/FRIKKern/barkpark/branches/main/protection \
      --jq '{contexts:[.required_status_checks.checks[]|.context],enforce_admins:.enforce_admins.enabled}'

## 3. Main's gate state by DECIDING STEP, not job rollup

    MAIN=$(git rev-parse origin/main)
    gh api "repos/FRIKKern/barkpark/commits/$MAIN/check-runs?per_page=100" \
      --jq '.check_runs[]|select(.conclusion!="success")|[.id,.name,.status,.conclusion]|@tsv'
    # then, per non-success id:
    gh api repos/FRIKKern/barkpark/actions/jobs/<id> --jq '.steps[]|[.number,.name,.conclusion]|@tsv'

## 4. Is a PR's Elixir-gate red its own, or main's?

    gh api repos/FRIKKern/barkpark/actions/jobs/<test job id>/logs \
      | grep -nE "^\s*[0-9]+\) test|tests,.*failure|##\[error"

A red whose failing file is the PR's own new test file is PR-local and says
nothing about the merge path.
