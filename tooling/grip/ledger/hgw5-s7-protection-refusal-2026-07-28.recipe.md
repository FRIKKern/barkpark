# The first merge refusal under branch protection — 2026-07-28

Dated record. Branch protection went live on `FRIKKern/barkpark/main` at
`2026-07-28T22:42:10Z` with `enforce_admins: true` and two required contexts
(`Elixir gate`, `PR references an active task`, both `app_id 15368`).

This PR is the throwaway that proves the refusal is real rather than asserted.
It was opened deliberately WITHOUT a task trailer, so the required context
`PR references an active task` renders RED, and then:

1. `gh pr merge --admin` is attempted and must be REFUSED.
2. The refusal is quoted here byte-for-byte.
3. The PR is made green and merged through `scripts/bp-merge.sh` — the merge
   verb's first live exercise.

## The refusal, verbatim

<!-- REFUSAL-VERBATIM-START -->
(pending — captured below once the required context is red)
<!-- REFUSAL-VERBATIM-END -->

## Which arm bp-merge classified

<!-- ARM-START -->
(pending)
<!-- ARM-END -->
