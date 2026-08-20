# cch wave 51 — Law-0 roster, seal-predicate truncation, and merge-SHA corroboration (2026-08-08)

Baseline: `origin/main` @ `ca5bc5429` (unchanged from the digest's measurement tree — re-fetched this phase).

## R1 — the TRUE roster (paginate; never a single fetch)

```
BP_TOKEN=<token from ~/.config/barkpark/>
node - <<'EOF'
import { execFileSync } from 'node:child_process';
const S='https://guerrilla.barkpark.cloud', T=process.env.BP_TOKEN;
const q=p=>{const a=['-sG',`${S}/v1/data/query/production/task`];
  for(const[k,v]of p)a.push('--data-urlencode',`${k}=${v}`);
  a.push('-H',`Authorization: Bearer ${T}`);
  return JSON.parse(execFileSync('curl',a,{encoding:'utf8',maxBuffer:1<<28}));};
let all=[],o=0;
for(;;){const d=q([['filter[parent_id]','cloud-console-hardening-epic'],['limit','200'],['offset',String(o)]]).result.documents;
  all.push(...d); if(d.length<200) break; o+=200;}
const c={}; for(const d of all) c[d.lifecycle_status]=(c[d.lifecycle_status]||0)+1;
console.log(all.length, JSON.stringify(c));
EOF
```

Measured 2026-08-08T00:1x UTC — pages 200/200/200/51:
`651 {"open":315,"cancelled":45,"done":290,"considering":1}`
Sole considering row: `cloud-console-operator-audit-log`. Zero `drafts.*` ids in the PUBLISHED
perspective (they are drafts; the published query cannot see them by construction).

`bp task get cloud-console-hardening-epic -o json` reports `child_count: 666`, children array
length 666, census `{done:290, considering:1, open:317, cancelled:58}`, of which exactly 15 ids
start with `drafts.`. DELTA = 666 − 651 = 15 drafts rows, split open +2 / cancelled +13.
So: `bp task get` counts drafts, the published query does not. Both are right about different
sets; only the published set is what a gate or board reads.

## R2 — proving the seal predicate's single fetch truncates

```
node cloud/priv/static/__preview__/seal-predicate.mjs --successor TERMINAL 2>&1 | tail -8
```

It refuses (correctly, TERMINAL is refuted) and QUOTES its own census while doing so:
`287 live row(s) [...] and 0 considering row(s) []`.

Isolating the same fetch it makes (`seal-predicate.mjs:231`, `limit=500`, no offset loop):
`SINGLE limit=500 FETCH rows: 500 census: {"open":287,"cancelled":27,"done":186}` — sum 500,
i.e. the page cap, silently. 651 − 500 = **151 rows lost, 28 of them open**, and the ONE
`considering` row is lost entirely, so the predicate's clause-(a) considering check is
structurally blind on this epic today.

Fixing line 231 will make the live count JUMP 287 → 315. That is the FIX landing, not a
regression. Both numbers are on the record here.

## R3 — corroborating "merged" by SHA, never by lifecycle

```
for n in 10508 10509 10510 10511 10512 10557 10559 10560 10561; do
  gh pr view $n --json state,mergeCommit --jq '.state+" "+(.mergeCommit.oid // "none")'; done
git fetch origin main -q
git merge-base --is-ancestor <sha> origin/main   # per merged sha
git diff-tree --no-commit-id --name-only -r <sha> | wc -l   # an EMPTY merge is a real outcome
```

All eight MERGED shas are ancestors of `origin/main`. `10509` is OPEN (`mergeCommit: none`).

Two traps this recipe exists to catch:

1. **`criteria_progress` cannot see a merge.** `cch-w49-s2` reads 11/12 — the same N−1 shape as
   every genuinely-shipped row — while its PR #10509 is still OPEN. Only the SHA separates them.
2. **A MERGED PR can carry an empty tree.** `b4a356946` (#10512) has
   `tree == parent tree == daf241423`, 0 files changed. Its content had already landed via the
   wave-49 charter PR #10471 (`bf309b27d`), which is what actually added
   `tooling/grip/ledger/cch-w49-false-open-close-sweep-2026-08-07.md`. So the row's deliverable IS
   on main — but "PR merged" was not the thing that proved it. Check the artefact, not the merge.

## R4 — PR ↔ row mapping (by title/body, corroborated by SHA)

| row | PR | sha | on main | verdict |
|---|---|---|---|---|
| cch-w49-s1 | 10508 | e88f1e05c | yes (3 files) | shipped-unstamped |
| cch-w49-s2 | 10509 | — OPEN | no | NOT shipped |
| cch-w49-s3 | 10510 | b22145665 | yes (4 files) | shipped-unstamped |
| cch-w49-s4 | 10511 | 6dfe16bac | yes (2 files) | shipped-unstamped |
| cch-w49-s5 | 10512 | b4a356946 | yes, but 0 files; artefact via #10471 | shipped-unstamped |
| cch-w49-s1-followup | — none exists | — | no | NOT shipped (0/2) |
| cch-w50-s1 | 10557 | c61107cc4 | yes (4 files) | shipped-unstamped |
| cch-w50-s2 | 10559 | ca5bc5429 (= main HEAD) | yes (4 files) | shipped-unstamped |
| cch-w50-s3 | 10560 | 1e7b85750 | yes (4 files) | shipped-unstamped |
| cch-w46-s7 | 10561 | 7499fe85a | yes (4 files) | shipped-unstamped (NOT s1-followup) |

The assignment paired nine rows with nine PRs; the ninth PR (10561) is
`cch-w46-s7-member-actor-rendered-state-authority-sweep`, not `cch-w49-s1-followup`. There is no
PR anywhere (open, merged, or closed) for `cch-w49-s1-followup-retire-orphaned-price-css`; it is
honestly open at 0/2.

## R5 — what the close budget actually is

8 rows are closable on SHA (7 of the named nine + `cch-w46-s7`); 2 of the named nine are not
(`cch-w49-s2`, `cch-w49-s1-followup`). The "~25-row lever named by cch-w49-s5" is **already
spent** — that sweep executed and its record is on main; done went 265 → 290 across w49. A wave
filing N new rows nets positive on live rows only if N < 8.
