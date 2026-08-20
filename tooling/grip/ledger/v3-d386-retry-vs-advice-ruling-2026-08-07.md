# v3 — D386/D332 vs a retry control on an unknown arm (wave 39, S3)

Re-derivation recipes. All against `origin/main` (do not trust a worktree).

```sh
cd /Volumes/SATECHI/github/barkpark
git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md > /tmp/v3charter.md
git show origin/main:cloud/priv/static/app.js > /tmp/v3app.js
git show origin/main:cloud/priv/static/__app.test.mjs > /tmp/v3test.mjs

# D386's own line citations are STALE (it cites :604 and :1976)
sed -n '604p;676p;1976p' /tmp/v3charter.md | cut -c1-120
grep -n '^| D332 \|^| D386 \|^| D316 ' /tmp/v3charter.md | cut -c1-90
grep -n ':nxdomain` IS AN ANSWER' /tmp/v3charter.md          # -> 2693, not 1976

# the three shipped unknown/failed arms
sed -n '3930,3950p;13851,13863p;17922,17933p;18297,18320p;1714,1722p' /tmp/v3app.js

# advice without a mechanism, today
grep -n 'data-life-retry\|data-members-retry\|data-env-retry' /tmp/v3app.js
grep -n 'Retry in a moment' /tmp/v3app.js

# the copy pins S3 must not break
sed -n '15252,15272p' /tmp/v3test.mjs
sed -n '2470,2476p' /tmp/v3test.mjs

# D386 predates the shipped advice-bearing arm
git merge-base --is-ancestor d75714137 bf97452bb && echo "D386 -> #9850"

# the epic's own prescription of a retry affordance
bp task get cch-w38-bl-unknown-authority-has-no-recovery-seam -o json
```
