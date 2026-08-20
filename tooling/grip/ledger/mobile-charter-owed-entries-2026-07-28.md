# Re-derivation recipes — mobile charter's two owed wave-log entries (2026-07-28)

Every row below re-derives from scratch. No number here may be quoted from a Paper.

| Fact | Command |
|---|---|
| PR #6498 state / mergeability / files | `gh pr view 6498 --json state,mergeable,mergeStateStatus,title,files,headRefName` |
| PR #6498 ALREADY contains the live-doc review entry | `gh pr diff 6498 \| grep -c '^+### Wave 2026-07-28 (2)'` |
| The one red gate on #6498 is a lease lapse on the EPIC ROOT, not a content fault | `gh run view --job 90173005690 --log \| grep 'pr-task-gate: FAIL'` |
| Charter's last blocks-wave entry stops at ROUND 1 (2/2) | `git show origin/main:.claude/workflows/bp-barkpark-tasks-mobile-charter.md \| grep -nE '^### Wave'` |
| Blocks-wave R2 PR numbers appear ZERO times in the charter | `for p in 6293 6294 6295 6296 6297 6310 6329; do printf '%s ' $p; git show origin/main:.claude/workflows/bp-barkpark-tasks-mobile-charter.md \| grep -c $p; done` |
| The five R2 merges + crown seal + follow-up, with dates | `git log origin/main --format='%h %cI %s' --since=2026-07-26 --until=2026-07-28 \| grep -iE 'mob-zb-s\|crown'` |
| Per-PR diffstat for the R2 entry | `git show --stat <sha>` for 8d10ca317 9c795a702 f87f21b20 be7e7ea74 d505293a5 acccaa3f2 2c8fe0da4 |
| Crown seal is 7/7 met and closed | `bp task get task-1c564ef14a679501 -o json \| python3 -c "import json,sys;d=json.load(sys.stdin)['doc'];a=d['content']['acceptance_criteria'];print(d['lifecycle_status'],sum(1 for c in a if c.get('met')),len(a))"` |
| The five R2 slice rows are done at full criteria | `for t in mob-zb-s3-structure-natives mob-zb-s4-navcode-natives mob-zb-s5-dataviz-natives mob-zb-s6-grid-natives mob-zb-s7-tail-media; do bp task get $t -o json; done` |
| D68's two cited slugs do not exist | `bp task get mob-rt-s4-runtime-lane -o json; bp task get mob-rt-s8-progressive-consumer -o json` (both `not_found`) |
| Merge ORDER inverted (consumer before server half) | `git log origin/main --format='%cI %s' \| grep -E 'rich-tail\|stable-emitter'` |
| D34-form census, derived never hand-typed | `bp task get task-c31a4f0a6c5be3ea -o json \| python3 -c "import json,sys;from collections import Counter;d=json.load(sys.stdin);print(d['child_count'],Counter(c['lifecycle_status'] for c in d['children']))"` |
| 66/66 must NOT be quoted: D48 forbids a literal count | `git show origin/main:apps/mobile/__tests__/registryParity.test.ts \| sed -n '26,31p'` |

NOT committed by this phase. Decide commits.
