# dr-w31 ledger reconciliation — adopt vs. file, re-derivation recipes (2026-08-09)

Verifier lane `ledger-reconciliation`, deploy-reliability wave 31. Every row below is
re-derivable by the literal command beside it. `bp` talks to guerrilla.barkpark.cloud.

## 0. The MUST-RUN command in the brief is the WRONG merge test on this repo

    git merge-base --is-ancestor origin/loop-epic/the-graced-sha-gets-re-read-and-the-crow-0 origin/main; echo rc=$?

returns `rc=1` for ALL six wave-30 builder branches, yet all six PRs are MERGED.
The repo squash-merges: `git cat-file -p 7c6f7aa9f | grep -c '^parent'` = 1.
The correct test reads the PR's own merge commit:

    gh pr view 11318 --json mergedAt,mergeCommit -q '[.mergedAt,.mergeCommit.oid]|@tsv'
    git merge-base --is-ancestor 7c6f7aa9f origin/main; echo rc=$?   # rc=0

Branch-ancestry as written would have reported every landed slice as unlanded.

## 1. Six epic-builder claims held over landed work (not four)

    bp task get dr-w30-s1-graced-sha-gets-a-re-read -o json | python3 -c 'import json,sys;d=json.load(sys.stdin)["doc"];print(d["assignee"],d["claim"]["expired_at"],d["criteria_progress"])'

| row | PR | merge commit | claim |
|---|---|---|---|
| dr-w30-s1-graced-sha-gets-a-re-read | 11318 | 7c6f7aa9f | epic-builder-…-crow, expired 16:04:01Z, 8/9 |
| dr-w30-s2-transport-silence-gets-its-own-code | 11319 | 917521fbe | expired 16:04:01Z, 8/9 |
| dr-w30-s3-11209-stops-inventing-a-code-word | 11209 | c382d7ea3 | expired 15:40:00Z, 6/8 |
| dr-w30-s4-orphan-harnesses-reach-ci | 11320 | 2f583ea1e | expired 15:46:01Z, 7/9 |
| dr-w30-s5-refusal-names-the-window | 11321 | c6733c467 | expired 16:04:01Z, 8/9 |
| dr-w30-s6-push-dedupe-claim-gets-its-pin | 11322 | e5323fb44 | expired 16:04:01Z, 7/8 |

All six appear in `bp task ready -o json --all` (claims lapsed), so a wave-31 builder
can silently re-claim landed work.

    bp task ready -o json --all | grep -o 'dr-w30-s[0-9][a-z-]*'

## 2. Falsely open — cured on origin/main, close with this evidence

    # dr-transport-silence-still-exits-zero  (cured by #11319)
    git show origin/main:scripts/stale-verdict-watch.sh | grep -n 'return 6\|return 7'
    git show origin/main:.github/workflows/stale-verdict-watch.yml | grep -n '^ *[67])'

    # dr-seal-run-harness-runs-in-no-ci  (cured by #11320)
    git grep -ln seal-run origin/main -- .github
    git show origin/main:.github/workflows/shell-harnesses.yml | grep -n 'seal-run.test.sh'

    # the three draft twins (both defects cured; DISCARD, do not close — status:draft)
    git show origin/main:.github/workflows/crown-reconcile.yml | grep -n 'GITHUB_TOKEN'
    git show origin/main:scripts/crown-reconcile.sh | sed -n '255,280p'   # --now ISO guard, exit 3

## 3. Arm-A rows: charter-banned, already rewritten in place

    grep -n 'D196 — THE LARGEST SURVIVING CLASS' .claude/workflows/bp-deploy-reliability-charter.md   # :3795
    bp task get dr-bl-w6-site-deploy-apply-unset-costs-16pct-of-failures -o json | python3 -c 'import json,sys;print(json.load(sys.stdin)["doc"]["title"])'

`dr-bl-w7-capacity-is-noise-next-to-two-unset-flags` (p0, 0/4) still carries the
D196-disproven title in the present tense and is the one Arm-A row NOT yet rewritten.

## 4. Arm-B seam and its invariant, on origin/main

    git show origin/main:api/lib/barkpark_web/controllers/error_json.ex | sed -n '35,45p'
    git show origin/main:api/lib/barkpark/content/errors.ex | sed -n '640,645p'
    git show origin/main:cloud/lib/barkpark_cloud/sites/deploy.ex | sed -n '1645,1656p'
    git ls-tree origin/main --name-only cloud/lib/barkpark_cloud/sites/   # NO deploy_ledger.ex

## 5. Arm-D residue still real on main

    git grep -n CROWN_API_TOKEN origin/main -- .github ; echo rc=$?   # rc=1, absent
    gh secret list                                                    # 6 secrets, no CROWN_API_TOKEN
    git show origin/main:.github/workflows/crown-reconcile.yml | sed -n '120,125p'  # :123 rc=2 -> exit 0
    git show origin/main:scripts/crown-reconcile.sh | sed -n '309,310p'             # wiped == intact-empty
