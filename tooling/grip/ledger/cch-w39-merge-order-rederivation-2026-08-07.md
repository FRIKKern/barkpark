# cch-w39 verify [v1-merge-order] — re-derivation recipes

Head this was derived at: `origin/main f4194c51f3294b0880cd11ce83a8f4894c02c99f` (2026-08-07).

## R1 — PR board state (which PRs can merge TODAY)

    cd /Volumes/SATECHI/github/barkpark && git fetch origin main -q && git rev-parse origin/main
    for n in 9955 9922 9920 9960 9917 9918 9956; do echo "== $n"; \
      gh pr view $n --json state,mergeable,mergeStateStatus,headRefOid,title \
        --jq '.state+" "+.mergeable+" "+.mergeStateStatus+" "+.headRefOid+" "+.title'; done

## R2 — hunk anchors per PR (the real band map)

    for n in 9955 9922 9920 9960 9917; do echo "== $n"; gh pr diff $n --patch \
      | awk '/^diff --git/{f=$3} /^@@/{print f": "$0}'; done

## R3 — PAIRWISE conflicts (merge-tree against EACH OTHER, not just main). MUST run under bash:
## zsh does not word-split `$pair`, so the loop silently degrades to "not something we can merge".

    bash -c 'cd /Volumes/SATECHI/github/barkpark
    for n in 9955 9922 9920 9960 9917 9918; do git fetch origin pull/$n/head:refs/tmp/p$n -f -q; done
    for pair in "9955 9922" "9955 9920" "9922 9920" "9955 9917" "9922 9917" "9922 9960" "9955 9960"; do
      set -- $pair; echo "== $1 x $2"
      git merge-tree --write-tree refs/tmp/p$1 refs/tmp/p$2 > /tmp/mt.$1.$2 2>&1; echo "rc=$?"
      grep "^CONFLICT" /tmp/mt.$1.$2
    done'

## R4 — __app.test.mjs TAIL ownership (who appends at EOF)

    for r in origin/main refs/tmp/p9922 refs/tmp/p9955 refs/tmp/p9917; do \
      echo "== $r $(git show $r:cloud/priv/static/__app.test.mjs | wc -l)"; \
      git show $r:cloud/priv/static/__app.test.mjs | tail -3; done

## R5 — the four S1 role reads and their SERVER axis

    git show origin/main:cloud/priv/static/app.js | grep -n 'meCache'
    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex \
      | grep -n 'require_primary_team_admin\|require_team_role\|require_primary_team_owner'
    git show origin/main:cloud/lib/barkpark_cloud/web/auth.ex | sed -n '116,145p;405,460p'

## R6 — #9922's meFault mechanism at scenarios.mjs route()

    gh pr diff 9922 --patch | awk '/^diff --git a\/cloud\/priv\/static\/__preview__\/scenarios.mjs/,/^diff --git a\/cloud\/priv\/static\/__preview__\/smoke/'

## R7 — #9920's census keying (is it inert to S1's predicate rewrites?)

    git show refs/tmp/p9920:cloud/priv/static/__binding_census.mjs | grep -n 'const keyOf'
    git show refs/tmp/p9920:cloud/priv/static/__binding_census.mjs | sed -n '674,701p'

## R8 — retry-idiom population on main (S3 is a GENERALISATION, not greenfield)

    git show origin/main:cloud/priv/static/app.js \
      | grep -n 'retry' | grep -iE 'data-|addEventListener|id="'

## R9 — the backlog row's ACTUAL scope (it is lifecycle-rail only)

    bp task get cch-w38-bl-unknown-authority-has-no-recovery-seam -o json
