# cch-w24 Law 0 — orphans re-derivation recipe (2026-08-02)

Verifier lane `v-law0-inventory`. Every number below is re-derivable by the command
beside it. Nothing here is quoted from a prior wave's charter row.

## 0. Precondition — the checkout matters

The primary checkout `/Volumes/SATECHI/github/barkpark` was 340 behind / 48 ahead of
`origin/main` at the time of this run, and its `seal-predicate.mjs` differs from
`origin/main`'s. `--repo` is used by the predicate BOTH for `git` ancestry AND for
`existsSync` on guard/test paths, so a diverged tree flips `b=`. Run it from a tree
that IS `origin/main`:

```
git worktree add --detach <scratch>/mainwt origin/main
```

## 1. orphans, live

```
set -a; . ~/.config/barkpark/env; set +a
node <scratch>/mainwt/cloud/priv/static/__preview__/seal-predicate.mjs \
  --successor cch-instruments-epic --repo <scratch>/mainwt | grep VERDICT-TOKEN
```

2026-08-02T11:37:45.588Z and again at 11:41:05.806Z, byte-identical:

```
VERDICT-TOKEN: SEAL-PREDICATE NO-SEAL a=FAIL b=PASS c=PASS orphans=97 considering=1 successor=cch-instruments-epic epic=cloud-console-hardening-epic mode=live stubbed=0 waived=0
roster: 300 children  {"done":170,"open":99,"cancelled":30,"considering":1}
```

NOT ladder-only. `--ladder-only` prints a different token with no `orphans=` field:

```
VERDICT-TOKEN: SEAL-PREDICATE LADDER-ONLY b-rungs=rung1:2,rung2:4,rung3:0 b-clean=6/6 a=NOT-READ c=NOT-READ epic=cloud-console-hardening-epic mode=live repo=…
```

## 2. Closable inventory (the denominator's other half)

```
curl -sG "$BARKPARK_URL/v1/data/query/production/task" \
  --data-urlencode "filter[parent_id]=cloud-console-hardening-epic" \
  --data-urlencode "limit=500" -H "Authorization: Bearer $BARKPARK_TOKEN"
```

Partition of the 97 orphans by unmet-criterion count:

| bucket | n | note |
|---|---|---|
| exactly ONE unmet AND it is the merge gate | **1** | `cch-w23-s2-account-modal-identity-bounded` ← `80c198415` |
| exactly ONE unmet, not a merge gate | 4 | real work, not stamping |
| all criteria met but row still open | 0 | no stale-open lever this wave |
| 2+ unmet | 87 | |
| `acceptance_criteria` key ABSENT entirely | 5 | structurally unstampable |

The five criteria-less rows (double-read, `bp task get … -o json`, both passes ABSENT
at `.doc.acceptance_criteria` AND `.doc.content.acceptance_criteria`, `criteria_progress`
null): `cch-w23-bl-site-meta-320-line-guard`, `cch-w23-bl-cruel-leg-blind-to-status-pill-detail`,
`task-696a2fcf95e9c4da`, `task-0b23fb7452aa457a`, `cch-bl-cloudflare-identity-echo-no-surface`.

## 3. The five wave-23 slices were closed BEFORE wave 24's first claim

`claim.closed_by = "loop-lead"`, `claim.closed_at`:

| row | closed_at | SHA | ancestor of origin/main |
|---|---|---|---|
| cch-w23-s1 | 2026-08-02T11:18:28.224906Z | 6194262cb | yes |
| cch-w23-s3 | 2026-08-02T11:18:31.356898Z | e141afbf8 | yes |
| cch-w23-s6 | 2026-08-02T11:18:35.594411Z | dc9920b2e | yes |
| cch-w23-s4 | 2026-08-02T11:18:41.501227Z | 9213bad3d | yes |
| cch-w23-s5 | 2026-08-02T11:18:45.524634Z | 928fcdfe3 | yes |
| cch-w23-s2 | STILL OPEN | 80c198415 | yes |

```
for s in 6194262cb e141afbf8 9213bad3d 928fcdfe3 dc9920b2e 80c198415; do
  git merge-base --is-ancestor $s origin/main && echo "$s ANCESTOR"; done
```

All six print ANCESTOR. The five closures are evidence-stamped, not fabricated.

## 4. Forwarding is a structural constant

`seal-predicate.mjs:776-799` (origin/main): `forwarded = fetchRoster(SUCCESSOR)`,
`children = fetchRoster(EPIC)`; both are `filter[parent_id]` reads and a task carries
one `parent_id`. Measured: `parent 300 succ 104 INTERSECTION 0`. `fwd` can never be
non-zero. A re-parent lowers `orphans` by leaving the denominator, never by credit.

Destination gate, still shut:

```
git cat-file -e origin/main:.claude/workflows/bp-cloud-console-instruments-charter.md
# fatal: path … does not exist in 'origin/main'   (rc=128)
```

## 5. Wave 23's own filings

14 rows under the parent (6 slices + 8 `-bl-`), 3 under the successor. The parent 14
is the count that scores against `orphans`.
