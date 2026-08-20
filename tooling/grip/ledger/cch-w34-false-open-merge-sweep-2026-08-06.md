# cch-w34 — false-open merge sweep over the 109 open roster rows (2026-08-06)

Re-derivation recipes for the wave-34 verifier finding: which open children of
`cloud-console-hardening-epic` carry a merge-gated criterion GitHub already satisfies.

## R0 — the open roster (the assignment's own one-liner is BROKEN)

`children` is a TOP-LEVEL key, not a key of `doc`. `d.get('doc', d)` selects `doc`,
which has no `children`, so the given command dies with `KeyError: 'children'` and
writes an EMPTY file — a zero-length sweep indistinguishable from "nothing found".

```sh
bp task get cloud-console-hardening-epic -o json > /tmp/w34epic.json
python3 -c "
import json
d=json.load(open('/tmp/w34epic.json'))
open('/tmp/w34open.txt','w').write('\n'.join(
  c['doc_id'] for c in d['children'] if c.get('lifecycle_status')=='open')+'\n')"
wc -l /tmp/w34open.txt      # => 109
```

## R1 — merge-criterion population

```sh
mkdir -p /tmp/w34tasks
xargs -P8 -I{} sh -c 'bp task get "{}" -o json > /tmp/w34tasks/{}.json' < /tmp/w34open.txt
# NOTE: parallel fetch drops ~15 files EMPTY under load; re-run serially over
# `find /tmp/w34tasks -size -100c` until that set is empty, or the sweep undercounts.
```

45 of 109 rows carry at least one criterion matching `/\bmerg/i`.
50 of those criteria name NO PR number — so criterion text ALONE cannot resolve
the sweep for the overwhelming majority. That is the sweep's central structural fact.

## R2 — detector A: the pr-task-gate trailer (PR *is* the row's build)

Grammar is `scripts/pr-task-gate.sh:extract_task_id` (`^[[:space:]]*task:`, case-insensitive,
first match wins, backticks stripped). Match the row slug with the `drafts.` prefix stripped.

```sh
gh pr list --state merged --limit 1500 \
  --json number,title,body,mergeCommit,mergedAt,headRefName > /tmp/w34merged.json
```

1511 merged PRs carry a `Task:` trailer; exactly **3** name a still-open roster row.

## R3 — detector B: a criterion naming a PR number that is MERGED

Catches what R2 misses: #9356's trailer names `gr-bl-seal-predicate-provenance-gap`
while its criterion-6 payer is `cch-w28-s1-empty-roster-control-asserts-clause-a`.
A trailer-only detector FAILS GREEN on this class.

## R4 — receipts (each confirmed `git merge-base --is-ancestor <sha> origin/main`)

| row | PR | merge sha | state |
|---|---|---|---|
| `cch-w12-s5-successor-split-and-letterbox-fence` | #8500 | `0b425c7e841c7ac55b7cc1f91e266be06571c7c7` | 10/10 payable |
| `cch-w28-s1-empty-roster-control-asserts-clause-a` | #9356 | `0a1b4d2ea53be3cb507834f0663faae998e13de3` | 7/7 payable |
| `drafts.cch-w32-r2-notifications-withhold-branches` | #9685 | `7ad181d1969ec3e26a8e948a9c741d173f035b38` | 9/9 payable |
| `cch-w11-s1-flip-behind-a-generator-that-cannot-lose` | #8394 | `dcd8c9ceff0e4505e5071ce8dbae7ee01aa0ac28` | 2 of 4 open criteria payable |
| `cch-w14-bl-site-open-phone-overflow` | #8743 | `b1c80eda5c0afcd31d532c554d7872024d353b1e` | merge criterion only; C3 genuinely open |

`cch-w12-s5` criterion 6 ("Both charters carry the filing law") is paid by the SAME merge:
`0b425c7e8` is the commit that ADDED `.claude/workflows/bp-cloud-console-instruments-charter.md`,
retiring charter D172's "`git cat-file -e` exits 128" finding.

```sh
git cat-file -e origin/main:.claude/workflows/bp-cloud-console-instruments-charter.md; echo $?   # 0
git log origin/main --oneline --diff-filter=A -1 -- .claude/workflows/bp-cloud-console-instruments-charter.md
```

## R5 — live branch protection (pays `cch-w11-s1` criterion 9, "THE PUT")

```sh
gh api repos/FRIKKern/barkpark/branches/main/protection \
  --jq '.required_status_checks.contexts, .enforce_admins.enabled'
# ["Elixir gate","PR references an active task","Cloud gate","Console gate"] / true
```

## R6 — a criterion that is DEAD, not open

`cch-w11-s1` criterion 10 requires `gh pr view 8222 --json mergeStateStatus`
*immediately after the PUT*. #8222 was CLOSED `2026-07-31T02:45:36Z`; #8394 merged
`2026-07-31T03:22:43Z`. The subject was gone 37 minutes BEFORE the flip, so the
natural experiment can never be run. Amend, do not stamp.

## R7 — no builder collision

```sh
gh pr list --state open --limit 300 --json number,title,body,headRefName
```
8 open PRs; ZERO carry a `Task:` trailer naming any of the 109 open rows.

## Honest limit

This sweep resolves the MERGE-GATED question only. A row whose code shipped under a
neighbour's PR with no slug mention is invisible to all three detectors here — that
class needs source re-derivation against `origin/main`, which is what the survey did
when it found 5 paid of 16.
