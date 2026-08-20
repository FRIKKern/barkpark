<!-- doc-tier: cold | canonical-for: stw-w12-reverse-done-audit-recipe | budget: 1500tok -->

# Search-Template epic — reverse audit of all 67 done rows (W12)

Re-derivation recipe. Verdict: **0 harmful false-done**. 66/67 done rows are backed by a
merged PR whose GitHub merge commit is an ancestor of `origin/main`; the 67th
(`task-2e8da7ff6bd0b7c2`) is an investigation-only closure with no code (legitimate no-SHA).

## Re-derive the census

    bp task get search-template-epic-goal -o json    # child_count 109; 67 lifecycle=done
    # per-row detail carries content.close_reason + content.acceptance_criteria[].evidence + claim
    bp task get <doc_id> -o json

## Re-derive ancestry (the decisive check)

origin/main head at audit time: `86cfe70a6f8815edb44087d4c2678c23077f821c` (2026-08-18 06:09).

For every done row, extract the cited PR number from `close_reason`, then:

    gh pr view <PR> --json state,mergeCommit -q '.state+" "+.mergeCommit.oid'
    git merge-base --is-ancestor <mergeCommit> origin/main && echo ANC || echo NOTANC

All cited PRs are MERGED and every merge commit is ANC. Confirmed PRs:
3493-3552 (W1-2), 3600-3665/3746-3989 (W4-5), 3804-4119 (W5-8), 4195, 6114-6284 (W9-10), 6940 (W11 a11y).

## The benign branch-SHA / build-ID pattern (do NOT flag as false-done)

Row evidence text frequently names SHAs that are NOT ancestors of origin/main. Two benign causes:

1. **branch-SHA-squashed** — e.g. a11y row `stw11-a11y-invariants` cites branch commits
   271a09b35 / ba7e66d09; PR #6940 squash-merged as `32f2bea48` (ANC). Branch commits vanish on squash.
2. **build IDs, not git commits** — W9 rows cite Astro/Next build hashes (`a7352b9caa0d3f55`,
   `6f700dc0`, `620101417de8d3b3`, `6e34f6e5`). These are `git cat-file` UNKNOWN because they are
   deploy build fingerprints, never git objects. Not evidence of unlanded work.

Neither is harmful. The audit's ancestor test on the PR **merge commit** is authoritative;
the branch/build hashes in prose are decoration.

## No harmful false-done found

Every `criteria_progress` is met==total (65 rows) or None/None-but-PR-merged (task-90266ebb,
task-8cea4ccd — both PRs ancestor). No row closes on refuted or never-landed evidence.
