# Wave 54 — arrears check-runs sweep: re-derivation recipes

Verifier `arrears-check-runs-sweep`, 2026-08-08. origin/main @ `5b68852f46b75047908c1947280af1bf3f72e529`.
No bp mutations were made. `claim.now` for all 33 N-1 rows captured BEFORE any re-claim.

## 0. Enumerate the N-1 rows (33, of which 4 are never-claimed 0/1)

    bp task get cloud-console-hardening-epic -o json > epic.json
    jq -r '[.children[]|select(.lifecycle_status=="open" and .criteria_progress.total>0
            and .criteria_progress.met==(.criteria_progress.total-1))]
           |.[]|[.doc_id,"\(.criteria_progress.met)/\(.criteria_progress.total)",.title]|@tsv' epic.json

## 1. Capture claim.now BEFORE re-claiming (a fresh claim WIPES it — D615(d))

Note the shape: `bp task get` returns `{ok,doc,children,child_count}`. The claim is at
`.doc.claim`, NOT `.claim`. Reading `.claim` returns null for every row and looks like
"no builder notes exist" — a silent uniform-zero.

    for s in $(jq -r '.[].doc_id' n1.json); do bp task get "$s" -o json > rows/$s.json; done
    jq -s 'map({slug:.doc.doc_id, worker:.doc.claim.worker, prev:.doc.claim.previous_worker,
                epoch:.doc.claim.epoch, expired_at:.doc.claim.expired_at,
                now_text:.doc.claim.now.text, now_ts:.doc.claim.now.ts})' rows/*.json

## 2. Map row -> carrier PR

Primary key is the `loop-epic/<stem>` branch named inside `claim.now`; the merged PR is
often the reviewer's `-r` sibling of that branch, so match by STEM PREFIX, not equality:

    stem=$(printf '%s' "$now" | grep -o 'loop-epic/[a-z0-9-]*' | head -1 | sed -E 's/-[0-9]+(-r)?$//')
    gh pr list --state all --limit 3000 --json number,title,state,headRefName,headRefOid,mergedAt > allprs.json
    jq -r --arg st "$stem" '.[]|select(.headRefName|startswith($st))' allprs.json

For rows with an empty `claim.now`, the stem is `previous_worker` minus its `epic-builder-`
prefix. `gh pr list --search "<slug>"` returns a uniform zero — do not use it (D615(c)).

## 3. Read check-runs on the PR HEAD (never the merge commit)

    gh api "repos/FRIKKern/barkpark/commits/<headSha>/check-runs" --paginate \
      --jq '.check_runs[]|"\(.name)\t\(.conclusion)"' </dev/null

Three traps, all measured live this run:
- **`:owner/:repo` needs a git cwd.** Run from the scratchpad and every call 422s. Paired
  with `2>/dev/null` it returns a confident `0/4 ABSENT` for all 29 rows. Use the literal
  `FRIKKern/barkpark` and never swallow stderr.
- **`gh api` eats stdin.** Inside `while read ... done < pairs.txt` it consumes the pair
  list. Always `</dev/null`.
- **zsh does not word-split.** `set -- $pair` inside a loop silently empties `$2`/`$3`.
  Use `printf '%s\n' ... | while read a b c`.

## 4. The required set is FOUR, and "Security gate" is NOT one of them

    gh api repos/FRIKKern/barkpark/branches/main/protection \
      --jq '.required_status_checks.contexts'
    => ["Elixir gate","PR references an active task","Cloud gate","Console gate"]

D560 quotes `Cloud/Security/Console/Elixir`. `Security gate` is not required; `PR references
an active task` is. Derive the set, never quote it.

## 5. A shared head sha carries TWO PRs' check runs

`4a99cbcc7`, `0792f2bb6`, `6368d7e14` each return both a `success` and a `failure` for
`PR references an active task` (runs=64/72 instead of 32). The failure belongs to a STALE
OPEN DUPLICATE PR opened after the merge. Disambiguate by the run's own `pull_requests`:

    gh api "repos/FRIKKern/barkpark/commits/<sha>/check-runs" --paginate \
      --jq '.check_runs[]|select(.name=="PR references an active task")
            |"\(.conclusion) \(.started_at) \([.pull_requests[].number])"' </dev/null | sort -u

## 6. Ancestry: head sha is NEVER an ancestor (squash merges)

All carriers merge as single-parent squash commits, so `git merge-base --is-ancestor <headSha>
origin/main` returns NOT-ANCESTOR for all 29 — another uniform zero. Use the merge commit:

    mc=$(gh pr view <pr> --json mergeCommit --jq .mergeCommit.oid </dev/null)
    git merge-base --is-ancestor "$mc" origin/main && echo ON-MAIN

## 7. The cch-w50-s3 / c0d771a7b contradiction

    git log origin/main --oneline | grep c0d771a7b            # no match
    git branch -a --contains c0d771a7b                        # loop-epic/...-bo-2, integration-probe
    gh pr view 10560 --json headRefOid,state,mergeCommit,mergedAt
    git merge-base --is-ancestor c0d771a7b 37530d6356e8d76bde40e3d25aa77fbdaaa2457f

c0d771a7b is the PARENT of #10560's head `37530d635` (branch `...-bo-2-r`), merged
2026-08-07T23:28:01Z as `1e7b85750`, which is on main. The work SHIPPED; the builder's
"unpushed" note simply predates the reviewer's push.
