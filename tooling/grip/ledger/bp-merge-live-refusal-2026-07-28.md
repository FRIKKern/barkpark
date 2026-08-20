# bp-merge live refusal — re-derivation recipes (2026-07-28)

Lane: `merge-verb-live-refusal`, Honest Gates wave 5. All commands read-only
except the one marked SAFE-MUTATION, which targets a CONFLICTING PR that the
GitHub API cannot merge.

## R1 — protection is still OFF, so no protection refusal exists to capture

    gh api repos/FRIKKern/barkpark/branches/main/protection

Expect: `{"message":"Branch not protected", ... "status":"404"}`.
Consequence: the six GraphQL refusal arms CANNOT be live-derived on this repo
before the PUT. They only come into existence after it.

## R2 — the harness (captured fixtures only, no network)

    cd /Volumes/SATECHI/github/barkpark && bash scripts/bp-merge.test.sh; echo HARNESS=$?

Expect: `bp-merge harness: 28 passed, 0 failed`, HARNESS=0.

## R3 — the classifier arms, driven directly

    BP_MERGE_LIB=1 bash -c 'source scripts/bp-merge.sh; for s in \
      "Required status check \"Elixir gate\" is failing." \
      "Required status check \"Elixir gate\" is expected." \
      "2 of 2 required status checks are expected." \
      "Pull request is not mergeable"; do echo "[$s] -> $(classify_refusal "$s")"; done'

Expect: RED / DEADLOCK / PLURAL / UNRECOGNISED.

## R4 — SAFE-MUTATION: a REAL live gh refusal from this repo

Pick any PR whose `mergeStateStatus` is `DIRTY` (unmergeable server-side, so the
call cannot land anything):

    gh pr list --repo FRIKKern/barkpark --json number,mergeable,mergeStateStatus \
      -q '.[]|select(.mergeable=="CONFLICTING")|.number'
    gh pr merge <N> --squash --repo FRIKKern/barkpark </dev/null

Measured on #6086:

    X Pull request FRIKKern/barkpark#6086 is not mergeable: the merge commit cannot be cleanly created.
    To have the pull request merged after all the requirements have been met, add the `--auto` flag.

`classify_refusal` on that string returns **UNRECOGNISED**.

## R5 — gh owns the `--admin` teaching line, and it is ungreppable

    strings "$(command -v gh)" | grep -o 'To use administrator privileges to immediately merge the pull request, add the `--admin` flag.'
    strings "$(command -v gh)" | grep -o 'the base branch policy prohibits the mergethe merge commit cannot be cleanly created'
    gh api graphql -f query='{repository(owner:"FRIKKern",name:"barkpark"){viewerCanAdminister}}'

The two reason strings are ADJACENT constants — same client-side
`mergeStateStatus` switch. `viewerCanAdminister: true`, so the `--admin` hint
is printed whenever the blocker is protection.

## R6 — refuse() reprints gh's `--admin` hint verbatim

    BP_MERGE_LIB=1 bash -c 'source scripts/bp-merge.sh
    PR_NUMBER=6086; HEAD_SHA=abc123; PR_URL=https://github.com/FRIKKern/barkpark/pull/6086
    msg="X Pull request FRIKKern/barkpark#6086 is not mergeable: the base branch policy prohibits the merge.
    To use administrator privileges to immediately merge the pull request, add the \`--admin\` flag.
    To have the pull request merged after all the requirements have been met, add the \`--auto\` flag."
    refuse "$(classify_refusal "$msg")" "$msg"'

Exit 1. The rendered block contains, indented under "gh said, verbatim:", the
line teaching `--admin`.

## R7 — merge_loop / resolve_plural / poll / over-budget, executed

    D=$(mktemp -d); mkdir -p $D/bin
    printf '#!/usr/bin/env bash\necho "GraphQL: 2 of 2 required status checks have not succeeded: 1 expected."\nexit 1\n' > $D/bin/gh
    printf '#!/usr/bin/env bash\necho "  ok     every required context rendered"\nexit 0\n' > $D/verify-ok.sh
    chmod +x $D/bin/gh $D/verify-ok.sh
    BP_MERGE_LIB=1 PATH="$D/bin:$PATH" bash -c '
      source scripts/bp-merge.sh
      VERIFY="'$D'/verify-ok.sh"; BUDGET_SECONDS=4; POLL_SECONDS=2
      PR_NUMBER=9999; HEAD_SHA=deadbeef; PR_URL=https://example/9999
      merge_loop'; echo EXIT=$?

Expect EXIT=2, with a "waiting (0s/4s)" line and the detector's line printed
each poll. The fall-through is NOT silent.

## R8 — detector cost per poll

    SHA=$(gh pr view 6551 --repo FRIKKern/barkpark --json headRefOid -q .headRefOid)
    time bash scripts/required-checks-verify.sh --deadlock --sha "$SHA"

Measured: exit 0, 1 line, ~1s. 40 polls at the default budget = 40 extra calls.

## R9 — nothing in prose points at the verb

    git grep -n 'bp-merge' origin/main -- . | grep -v '^origin/main:scripts/bp-merge'

Only `.claude/workflows/bp-honest-gates-charter.md`,
`.github/workflows/shell-harnesses.yml`, and one comment in
`scripts/required-checks-verify.sh:394`.
