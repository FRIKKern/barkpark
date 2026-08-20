# Re-derivation recipes — felix wave 24, [wave23-criteria-closes]

Derived 2026-07-29 against `origin/main` @ `606fefd15`. `api/` in the primary
checkout is byte-identical to `origin/main` (`git diff --stat origin/main HEAD -- api/`
is empty), so local scans of `api/` are authoritative for main.

| Fact | Rerun |
|---|---|
| PRs #6616-#6620 all MERGED; merge commits are ancestors of origin/main | `for n in 6616 6617 6618 6619 6620; do gh pr view $n --json number,state,mergeCommit -q '[.number,.state,.mergeCommit.oid]\|@tsv'; done` |
| Tasks felix-w23-s1..s4 are STILL OPEN, criteria 1-4 stamped met, criterion 5 (merged) unmet | `curl -s -H "Authorization: Bearer $BP_TOKEN" "https://guerrilla.barkpark.cloud/v1/tasks?parent=task-96a908af98698118&limit=300"` |
| The tasks index filters on `parent=`, NOT `parent_id=`; `parent_id=` is silently ignored (returns the unfiltered index) | `curl -s -H "Authorization: Bearer $BP_TOKEN" "https://guerrilla.barkpark.cloud/v1/tasks?parent_id=task-96a908af98698118&limit=300" \| python3 -c "import json,sys;print(len(json.load(sys.stdin)['docs']))"` |
| Three landed scripts pass `--selftest` (exit 0) | `bash api/scripts/sobelow-inline-overlap-check.sh --selftest; bash api/scripts/sobelow-baseline-staleness-check.sh --selftest; bash api/scripts/sobelow-fresh-finding-guard.sh --selftest` |
| The fresh-finding guard lives at `api/scripts/`, not `scripts/` | `git ls-files \| grep sobelow` |
| Live finding set = 32 across 5 files (incl. `media/blobstore/s3.ex` 8) | `cd api && mix sobelow --skip --private --format compact --exit Low` |
| S1's six files carry ZERO unsuppressed findings; 21 findings there unskipped, 19 of them migrated off the baseline, 1 still baselined (`renditions.ex:107`), 1 pre-existing annotation (`deploy_runner` CI.System) | `cd api && mix sobelow --private --format compact --exit Low \| grep -E "deploy_runner\|tenancy.ex\|renditions.ex\|bulldocs.ex\|titles.ex\|tasks/validation.ex"` |
| S1 removed exactly 19 baseline rows and added 0 | `git show 27352d8c1 -- api/.sobelow-skips \| grep -c '^-[^-]'` |
| S1 fence held: no `workspace_bundle/` and no `router.ex` in the diff | `git show --name-only --format= 27352d8c1` |
| Overlap check PASSES on main: 89 baseline entries vs 65 annotation coverings | `bash api/scripts/sobelow-inline-overlap-check.sh` |
| Staleness check REDS on main: 31 STALE of 81 checked (8 skipped, no anchor) | `bash api/scripts/sobelow-baseline-staleness-check.sh; echo $?` |
| The staleness step in the blocking job is itself `continue-on-error: true` — the ratchet is NOT blocking | `git show origin/main:.github/workflows/security.yml \| sed -n '160,185p'` |
| security.yml's flip-condition comment claims "15 of the 31 are the blobstore rows" — blobstore has ZERO baseline rows | `grep -c blobstore api/.sobelow-skips` |
| The workflow cites `task-felix-w23-bl-staleness-blocking-flip`; the real doc_id has no `task-` prefix | `curl -s -H "Authorization: Bearer $BP_TOKEN" https://guerrilla.barkpark.cloud/v1/tasks/felix-w23-bl-staleness-blocking-flip` |
| merge-gates.md §9 (from #6618) claims "main has no branch protection" and `enforced: false`; both are FALSE today | `gh api repos/FRIKKern/barkpark/branches/main/protection --jq '{enforce_admins:.enforce_admins.enabled,contexts:.required_status_checks.contexts}'` and `git show origin/main:.github/required-checks.json \| python3 -c "import json,sys;print(json.load(sys.stdin)['enforced'])"` |
| D145 re-derived: `Janitor.own/1` and `Janitor.disown/1` have ZERO callers in `api/lib` (definitions only), 4 refs in one test file | `git grep -n "Janitor.own\|Janitor.disown" -- api` |
| `felix-w23-bl-dataset-slug-format` is NOT fixed on main (length-only validation) | `grep -n "validate_" api/lib/barkpark/tenancy/dataset.ex` |
| `task-felix-w21-bl-readiness-sobelow-inline` is NOT fixed: the baseline row survives | `grep -n readiness api/.sobelow-skips` |
| `felix-w23-bl-overlap-unbound-annotation` is NOT fixed: no annotation-binding checker exists | `ls api/scripts/sobelow-*` |
