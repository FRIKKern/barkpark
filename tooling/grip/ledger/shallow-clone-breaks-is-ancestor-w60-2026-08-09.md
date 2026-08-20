# The main checkout is a SHALLOW clone, so `git merge-base --is-ancestor` silently lies

Date: 2026-08-09 · wave 60 verify · epic cloud-console-hardening

## The trap

`/Volumes/SATECHI/github/barkpark` is a shallow clone. `git rev-parse --is-shallow-repository`
returns `true`, `.git/shallow` holds ONE graft SHA, and `git rev-list --count origin/main` = 204.
Any commit merged before the graft boundary is unreachable locally, so

    git merge-base --is-ancestor <merged-sha> origin/main

exits **1** for a commit that IS on main. 539 of 743 MERGED PRs report a false NOT-ON-MAIN.

Worse, the boundary MOVES: a plain `git fetch origin main -q` re-grafts at the new tip, so the
same command can answer ON-MAIN and then NOT-ON-MAIN minutes apart in one session. That is
exactly what happened to `64a1f59690ee` (PR #10007) here.

## Re-derivation

    cd /Volumes/SATECHI/github/barkpark
    git rev-parse --is-shallow-repository            # true
    cat .git/shallow                                 # graft SHA
    git log -1 --format='%h %ci %s' $(cat .git/shallow)   # the boundary DATE
    git rev-list --count origin/main                 # 204, not thousands

## The sound test (server-side, boundary-immune)

    gh api repos/FRIKKern/barkpark/compare/<sha>...main --jq '.status'

    ahead      -> main is ahead of <sha>  => <sha> IS an ancestor of main
    identical  -> <sha> IS main's tip
    behind     -> main is behind <sha>    => NOT on main (a branch head past main)
    diverged   -> NOT on main

Positive control (the method must be able to say no):

    gh pr view 11102 --json headRefOid --jq .headRefOid   # 40f99f9e8720 -> "behind"
    gh pr view 10154 --json headRefOid --jq .headRefOid   #             -> "diverged"

## Content cross-check when you want L1, not L2

    gh api repos/FRIKKern/barkpark/commits/<sha> --jq '.files[].filename'
    git show origin/main:<that-file> | grep -c '<a line the commit ADDED>'

For 64a1f59690ee: `git show origin/main:scripts/registration-deadlock-sweep.sh |
grep -c "A CANDIDATE THAT PROPOSES NOTHING NEW IS THE SAME FAILURE"` -> 1. It landed.

## Second trap, same family

A task's `claim.now` cites its **branch-tip** SHA. This repo squash-merges, so a branch tip is
NEVER an ancestor of main even when the work landed. Resolve branch -> PR -> mergeCommit:

    gh pr list --state all --limit 800 --json number,state,mergeCommit,headRefName,mergeStateStatus

Branch names are also re-pushed with a `-r` suffix at review, so an exact `headRefName` lookup
misses the PR. Match on the branch stem, not the full name.
