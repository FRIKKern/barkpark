# cch-w31 · guard wiring re-derivation (v8-guard-wiring)

Question: which BLOCKING required check actually RUNS `cloud/priv/static/__app.test.mjs`
and the cloud `mix test` suite — and would a new census living in either red a merge?

Verdict: BOTH are wired to a blocking required context. Answer is YES for both venues.
Everything below re-derives it from scratch. Local `main` in the primary checkout was
434 commits BEHIND `origin/main` at the time of writing, so every tree-level probe runs
against an extracted `origin/main`, never the worktree.

## 0. Extract origin/main (the worktree is NOT origin/main)

    git -C /Volumes/SATECHI/github/barkpark rev-list --left-right --count HEAD...origin/main   # -> 48  434
    mkdir -p /tmp/om && git -C /Volumes/SATECHI/github/barkpark archive origin/main | tar -x -C /tmp/om

## 1. The four required contexts (LIVE, not the committed file)

    gh api repos/:owner/:repo/branches/main/protection \
      --jq '.required_status_checks.checks[] | "\(.context) | app_id=\(.app_id)"'
    gh api repos/:owner/:repo/branches/main/protection --jq '.enforce_admins.enabled'

## 2. Which job runs each file, and which aggregator carries it

    grep -nE '^  [a-z-]+:|^    name:|^    if:|^    needs:|__app.test.mjs' /tmp/om/.github/workflows/console-harness.yml
    grep -nE '^  [a-z-]+:|^    name:|^    if:|^    needs:|mix test'        /tmp/om/.github/workflows/cloud.yml
    # neither file carries a REAL continue-on-error key (all 5 hits are comments):
    grep -nE '^\s*continue-on-error\s*:' /tmp/om/.github/workflows/cloud.yml /tmp/om/.github/workflows/console-harness.yml

## 3. Dispatch: does an edit that could introduce a withhold reach the job?

    printf 'cloud/lib/barkpark_cloud/notifications/delivery.ex\n' | bash /tmp/om/scripts/console-path-escape-check.sh --match console  # true
    printf 'cloud/lib/barkpark_cloud/notifications/delivery.ex\n' | bash /tmp/om/scripts/cloud-path-escape-check.sh   --match cloud    # true
    printf 'docs/INDEX.md\n'                                      | bash /tmp/om/scripts/console-path-escape-check.sh --match console  # false

## 4. Gate scripts, run

    bash /tmp/om/scripts/console-path-escape-check.sh --selftest   # 151 passed, 0 failed
    bash /tmp/om/scripts/console-path-escape-check.sh              # 15 reads, OK
    cd /tmp/om/cloud/priv/static && node --test __app.test.mjs     # 826 pass, rc 0

## 5. MUTATION PROOF — a cloud/lib-walking census in __app.test.mjs really reds

    cat > /tmp/om/cloud/lib/barkpark_cloud/__fake_withhold_probe.ex <<'EX'
    defmodule BarkparkCloud.FakeWithholdProbe do
      def go(team) do
        dispatch_event(team, :eleventh_withhold, %{})
      end
    end
    EX
    cd /tmp/om/cloud/priv/static && node --test __app.test.mjs; echo $?   # rc 1
    # -> not ok 759 - cch-w30-s1 census ARM (b) ... + 'eleventh_withhold'

## 6. MUTATION PROOF — the cloud mix suite reds on an injected census violation

    # scratchpad file, never written into the repo
    cd /Volumes/SATECHI/github/barkpark/cloud && MIX_ENV=test \
      DATABASE_URL=ecto://postgres:postgres@localhost:5432/barkpark_cloud_test \
      mix test /tmp/fake_census_fail_test.exs; echo $?      # rc 2, "1 test, 1 failure"

## 7. Per-check-run cross-check (never the rollup)

    gh api "repos/:owner/:repo/commits/467f7e2837b0690d45a2c8a573e7242b6d720833/check-runs?per_page=100" \
      --jq '.check_runs[] | "\(.name) | \(.conclusion)"' | sort
    # and on a real PR head, where "PR references an active task" also renders:
    gh api "repos/:owner/:repo/commits/48d960092a65e094de6d0c7fea7f65dd9b322c2a/check-runs?per_page=100" \
      --jq '.check_runs[] | select(.name|test("gate|active task")) | "\(.name) | \(.conclusion)"' | sort

## 8. Vacuity modes a census author must defeat

    node --test ./nope_missing.test.mjs ; echo $?   # rc 1 — a deleted file is LOUD
    printf 'import {test} from "node:test";\n' > /tmp/empty.test.mjs
    node --test /tmp/empty.test.mjs ; echo $?       # rc 0 — a file with NO test bodies is SILENT

## 9. Correction to the wave brief

    git ls-tree origin/main scripts/ --name-only | grep required-checks   # required-checks-floor.sh EXISTS
    git grep -n 'required-checks-floor.sh' origin/main -- scripts/        # called from required-checks-apply.sh:218
