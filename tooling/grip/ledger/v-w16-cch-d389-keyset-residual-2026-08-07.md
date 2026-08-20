# CCH D389's keyset slice in deploy_ledger.ex — merged, not a live backlog row (dr wave 16, v10-fence-residuals)

Question: is CCH D389's keyset-cursor slice (naming `deploy_ledger.ex:552`) still an
unbuilt backlog row a future CCH wave could dispatch into leg 1's file — and is a CCH
wave 48 running unpushed anywhere?

Answer: NO on both. Re-derivation recipe:

```sh
# 1. The slice landed. One commit, one PR, three call sites.
git log origin/main --oneline -20 -- cloud/lib/barkpark_cloud/deploy_ledger.ex
#   -> 20c623f15 perf(cloud): keyset cursors seek — a ROW comparator at three call sites, no migration (#9741)
gh pr view 9741 --json number,title,mergedAt,state,files
#   -> MERGED 2026-08-06T03:56:36Z; files include cloud/lib/barkpark_cloud/deploy_ledger.ex

# 2. The mandated spelling is present verbatim on origin/main.
git show origin/main:cloud/lib/barkpark_cloud/deploy_ledger.ex | grep -n 'fragment("(?,?) < (?,?)"'
#   -> 1097:    where(query, [d], fragment("(?,?) < (?,?)", d.inserted_at, d.id, ^ts, type(^id, Ecto.UUID)))

# 3. The CCH charter's own wave log marks it shipped.
grep -n "9741" .claude/workflows/bp-cloud-console-hardening-charter.md
#   -> 3090:| Keyset cursors seek … | cch-w34-s4-delivery-log-cursor-seeks | … | #9741 | committed the SQL-shape guard |

# 4. The line number in D389 is STALE and now points nowhere near the cursor.
git show origin/main:cloud/lib/barkpark_cloud/deploy_ledger.ex | sed -n '552p'
#   -> @corpus_403 ~r/fetch failed:\s*403\b/     (the cursor now lives at :1010-1128)

# 5. No CCH wave 48 exists anywhere.
git for-each-ref --sort=-committerdate --format='%(committerdate:short) %(refname:short)' \
  refs/remotes/origin | grep -i 'cch\|console-hardening' | head -3
#   -> highest is origin/epic-charter/cloud-console-hardening-w47-20260807T143511Z
git branch -a | grep -i w48        # -> only `charter-w48`, which is PDS wave 48 (bp-pds-charter.md), not CCH
bp task ready -o json | grep -i 'cch-w48'   # -> no rows
gh pr list --state open --limit 60 ... | select(headRefName test cch)  # -> only w45 (#10256) and w40 (#10054) charters
```

Cross-check for concurrent openers of our file: of all open PRs, exactly two touch
`deploy_ledger.ex` — #10400 and #10129, both this epic's own. No CCH PR does.

Residual risk (not a refutation): CCH waves 40-47 all landed on 2026-08-07 at roughly
2-hour intervals, so a wave 48 can START during our build window. It would have no D389
mandate to enter `deploy_ledger.ex`, and the CCH fence cedes deploy/ to this epic — but
"no w48 now" is a fact with a short shelf life. Re-run step 5 before the build phase.
