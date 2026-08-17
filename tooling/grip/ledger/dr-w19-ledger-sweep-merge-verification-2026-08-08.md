# dr-w19 ledger sweep — re-derivation recipes (2026-08-08)

Verifier v9-ledger-sweep. Every number below re-derives from these commands. No mutations were made.

## 1. The epic's partial rows

    bp task get task-fb4fb869490b4213 -o json > epic.json
    python3 -c "import json;d=json.load(open('epic.json'));ch=d['children'];print(len(ch));import collections;print(collections.Counter(c['lifecycle_status'] for c in ch));print(sum(1 for c in ch if c.get('criteria_progress') and 0<c['criteria_progress']['met']<c['criteria_progress']['total']))"

2026-08-08: 334 children, 317 open / 13 done / 4 cancelled, 76 partial, 7 with zero criteria.

## 2. Per-row branch extraction

Branch names live in the row's claim note ("committed <sha> on loop-epic/<slug>") and in criterion evidence.
The regex MUST strip a trailing "." — prose sentences end right after the branch and an unstripped dot
makes `gh pr list --search head:<branch>` return `[]`, which reads as NOT MERGED. That bug alone
manufactured 23 false "not merged" rows in the first pass.

    bp task get <row> -o json | grep -o 'loop-epic/[A-Za-z0-9._/-]*' | sed 's/\.$//'

## 3. The merge proof (must be run from inside the repo — gh shells out to git)

    gh pr list --search "head:<branch>" --state all --json number,state,mergedAt,mergeCommit,headRefName

`head:` is a PREFIX match, not exact: the merged PR usually lives on `<branch>-r` (the reviewer's
rebase branch), so match with `headRefName.startswith(branch)`, never `==`.

## 4. Ancestry — the merge commit must actually be on origin/main

    git fetch origin main && git merge-base --is-ancestor <mergeCommit> origin/main; echo $?

68 of 68 matched merge commits returned 0.

## 5. Required contexts green on the merge commit

    gh api repos/FRIKKern/barkpark/commits/<sha>/check-runs \
      --jq '[.check_runs[]|select(.conclusion!="success" and .conclusion!="skipped" and .conclusion!="neutral")]|length'

Spot-checked 3de49fb10, 8ae30b34b, 97d6d41e1 -> 0 non-success each.

## 6. The live webhook rows (the repair the wave was going to run)

    bp webhook ls -d production

2026-08-08: all five `site-autodeploy-*` rows read `types: ["paper"]`.
updated_at: 4634a19c 03:43:23.234Z, 3c072b7d 03:43:23.553Z, 4a12e07f 03:43:23.894Z,
6f2fb572 03:43:24.567Z, 9121449d 03:46:27.036Z (2026-08-07).

## 7. WHO ran it

    bp task get dr-w9-s4-webhook-doctype-filter-reaches-live-rows -o json

Criterion 5 is stamped met by worker `epic-builder-the-doc-type-filter-reaches-the-five-liv`,
claim note "committed 9abb5f0bb on loop-epic/the-doc-type-filter-reaches-the-five-liv-3" at
2026-08-07T03:48:50Z. Its evidence also explains the 03:43 / 03:46 split: the first (buggy)
dry-run wrote 4 of 5 rows before the global-flag fix; 9121449d was reset with
`bp cloud webhook edit --types ""` and re-repaired by the fixed binary. PR #10082, merged
2026-08-07T04:09:13Z, merge commit 8ae30b34bfc858184f6f1702a2dce57843903987.
