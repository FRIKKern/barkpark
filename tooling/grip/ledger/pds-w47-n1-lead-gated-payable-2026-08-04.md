# PDS W47 — the 17 N-1 open PDS rows, traced to merge (re-derivation recipes)

Verifier lane `n1-lead-gated-payable`, 2026-08-04. origin/main = `49345a98c1dbd9c768f3312185be0f5483878241`.
Nothing here is committed by this lane; Decide commits it.

## 1. Re-derive the population (exactly 17, not 15, not 354)

    bp task ls --all -o json > /tmp/tasks.json
    python3 -c "
    import json
    d=json.load(open('/tmp/tasks.json'))['docs']
    for x in d:
        if x.get('lifecycle_status')!='open': continue
        i=x.get('doc_id') or ''
        if not i.startswith('pds-'): continue
        c=(x.get('content') or {}).get('acceptance_criteria') or []
        u=[a for a in c if not a.get('met')]
        if len(u)==1: print(i, '%d/%d'%(len(c)-1,len(c)), '|', u[0]['criterion'][:120])
    "

Filter is `doc_id.startswith('pds-')` AND `lifecycle_status=='open'` AND exactly one unmet
criterion. `drafts.pds-*` rows are EXCLUDED by the prefix test (`drafts.` sorts first) — do not
widen it or the count drifts.

## 2. Resolve each row to its PR (the issue number is NOT a PR)

`content.github.issue` is the MIRRORED ISSUE and fails `gh pr view` on all 17:

    gh pr view 9420   # GraphQL: Could not resolve to a PullRequest with the number of 9420.

The resolvable path is the charter's task-to-PR tables on origin/main:

    git show origin/main:.claude/workflows/bp-pds-charter.md \
      | grep -nE '\| *`?pds-[a-z0-9-]+`? *\|.*#[0-9]+'

## 3. Verify a row's merge half (all four required contexts + ancestry)

    gh pr view <n> --json number,state,mergedAt,mergeCommit
    git merge-base --is-ancestor <mergeCommit.oid> origin/main && echo ANCESTOR
    gh pr checks <n> | grep -cE '^(Cloud gate|Console gate|Elixir gate|PR references an active task)\tpass'   # must be 4

The required set is authoritative here, never memory:

    git show origin/main:.github/required-checks.json \
      | python3 -c "import json,sys;print([c['context'] for c in json.load(sys.stdin)['protection']['required_status_checks']['checks']])"

## 4. The residue-lens execution proof (the one CI-log discharge)

    gh pr view 9296 --json headRefOid -q .headRefOid            # 59fdf4c9cd90f1f823aeb31e15fb189148a96662
    gh run list --commit 59fdf4c9c... --json databaseId,name    # elixir -> 30759156397
    gh run view 30759156397 --log | grep -E 'Test \(Elixir 1.18.1 / OTP 27.0\).*doctests'
    git show origin/main:api/test/barkpark/pds_residue_lens_test.exs | grep -nE '@tag|@moduletag'  # EMPTY => not excludable

Untagged case + `0 failures` in the 1.18.1/OTP 27 job = the case EXECUTED on the runner.

## 5. The opaque-callers grep criterion (still RED)

    git show origin/main:.claude/workflows/bp-pds-charter.md > /tmp/charter.md
    grep -n OPAQUE_CALLERS /tmp/charter.md

Eight hits (4502, 4530, 4569, 4696, 9117, 10034, 10047, 10355). Only 10355 (PDS-D468b) marks
itself as pre-rename (`OPAQUE_CALLERS` -> `OPAQUE_ACTION_CALLERS`). Seven do not. Criterion UNMET.
