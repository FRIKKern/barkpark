# CCH wave 52 — the four "N-1" predecessors are MERGED; the block is bookkeeping, not work

Claim under test (wave-52 brief, priority V11): four round-1 predecessors
(`cch-w49-s1`, `cch-w49-s2`, `cch-w50-s1`, `cch-w50-s3`) sit at N-1 with
"no PR ever opened", blocking four owed slices — the built-and-stranded shape.

REFUTED. All four are merged to `origin/main`. On each task the SINGLE unmet
criterion is the terminal merge-gated one ("the lead closes this"), and the
merge it names has already happened. No branch carries unpushed novel work.

## Re-derivation

Single unmet criterion per predecessor:

    for t in cch-w49-s1-money-screen-stops-stating-numerals-it-cannot-support \
             cch-w49-s2-checkout-refuses-before-it-charges-and-the-plane-declares-its-billing-capability \
             cch-w50-s1-sold-capability-manifest-and-the-two-bullets-that-fail-it \
             cch-w50-s3-the-cancel-modal-promise-becomes-true-bounded-and-guarded; do
      echo "== $t"
      bp task get $t -o json | python3 -c "import sys,json;c=json.load(sys.stdin)['doc']['content'];[print('  MET  ' if a['met'] else '  UNMET', a['criterion'][:140]) for a in c['acceptance_criteria']]"
    done

The PRs (search by HEAD ref, not by title — the merged refs carry a `-r` suffix
the task's claim note does not mention):

    gh pr list --state all --limit 400 --json number,state,headRefName,title \
      --jq '.[]|select(.headRefName|test("checkout-refuses|sold-capability|money-screen|cancel-modal|crown-the-sold"))|[.number,.state,.headRefName]|@tsv'

Merge commits are ancestors of `origin/main`:

    for s in e88f1e05c0aaaca53f524f0023b82baa75ea435a \
             2a2b009c27cbc79da72ffa5c0a04a42185ac4937 \
             c61107cc49a5719e107ab6003ff6760a7f08a9ee \
             1e7b85750c6593227aeb94ef34aec4e3f37870b4; do
      printf "%s " $s
      git merge-base --is-ancestor $s origin/main && echo ANCESTOR || echo NOT-ANCESTOR
    done

Artifact-level confirmation on main (not a claim about the worktree):

    git ls-tree origin/main cloud/test/barkpark_cloud/sold_capability_manifest_test.exs
    git ls-tree origin/main cloud/priv/static/__preview__/__plan_features_dump.mjs
    git grep -n "checkout_capability"      origin/main -- cloud/lib
    git grep -n "resume_team_barkparks"    origin/main -- cloud/lib
    git grep -c "No card needed\."         origin/main -- cloud/priv/static/app.js   # 0 hits
    git grep -n  "Daily backups"           origin/main -- cloud/priv/static/app.js   # only the doc comment at :14273

## Two traps this run walked into

1. **The claim note lies about push state by omission.** `cch-w50-s3`'s note
   reads "committed c0d771a7b on loop-epic/the-cancel-modal-promise-becomes-true-bo-2,
   **unpushed**" — yet PR #10560 merged from
   `loop-epic/the-cancel-modal-promise-becomes-true-bo-2-r`. The reviewer's `-r`
   branch is what got pushed. A builder's "unpushed" confession is evidence
   about the builder's own ref only; always re-check for the `-r` sibling.

2. **`git diff --stat origin/main..<branch>` reads as huge stranded work and is
   not.** Every one of these branches shows ~7-12k deletions — that is main
   being AHEAD, not the branch carrying content. The honest scan is per-file
   from the merge-base:

       mb=$(git merge-base origin/main $b)
       for f in $(git diff --name-only $mb..$b); do
         git diff --quiet origin/main:$f $b:$f && echo "SAME-ON-MAIN $f" || echo "DIFFERS $f"
       done

   and even `DIFFERS` is not evidence of stranding once other waves have edited
   the same files — only the artifact-level greps above settle it.

## Residue for Decide

- The four predecessors are `lifecycle_status: open` with expired claims
  (`claim.worker` is `null`; epochs 6 / 8 / 6 / 6). Closing them needs a fresh
  claim, not the stale epoch.
- `cch-w46-s7-member-actor-rendered-state-authority-sweep` is the same shape:
  11/12, note names `78ce673f3` (NOT an ancestor of main), and PR #10561 from
  `…-sw-3-r` is MERGED. Fifth stale-open row.
- Owed slices `cch-w49-s6` (0/12) and `cch-w49-s7` (0/13) are genuinely unbuilt
  — real slices of work, not finishes. `cch-w49-bl-billing-derives-…` is 0/5.
