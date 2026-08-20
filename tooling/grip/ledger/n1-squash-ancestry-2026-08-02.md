# N-1 ledger rows: why the ancestry check false-negatives (2026-08-02, PDS wave 42 verify)

## The claim under test

"Seven merged-but-open N-1 rows are one lead act from closable; the local ancestry
check false-negatived for a surveyor **because those shas were never in the local
object DB**."

**The premise's stated CAUSE is wrong.** The shas are all present locally. They are
non-ancestors because every one of them was **squash-merged**: the branch commit is
never an ancestor of `origin/main`; only the squash commit is.

## Re-derivation

Object presence (all seven print `commit`):

```
cd /Volumes/SATECHI/github/barkpark && for s in 5a0f29ee4 fb408a4e8 23e990875 a94eeced2 03d27f02f 633262f12 9b899c27c; do printf "%s " $s; git cat-file -t $s; done
```

The naive check (all seven print rc=1 — the false negative):

```
for s in 5a0f29ee4 fb408a4e8 23e990875 a94eeced2 03d27f02f 633262f12 9b899c27c; do git merge-base --is-ancestor $s origin/main; echo "$s rc=$?"; done
```

The CORRECT check — resolve each branch sha to its PR merge commit, then test that:

```
for s in 5a0f29ee4 fb408a4e8 23e990875 a94eeced2 03d27f02f 633262f12 9b899c27c; do gh api "repos/:owner/:repo/commits/$s/pulls" -q '.[]|"\(.number) \(.merged_at) \(.merge_commit_sha)"'; done
for m in 9730f6931 716429bcb 190cadf91 aa81a9b6e 8e1e27d6b 8cb75fa5d 034d5fcd8; do git merge-base --is-ancestor $m origin/main && echo "ANCESTOR $m"; done
```

All seven merge commits are ancestors of `origin/main` @ `5444aa5e1`. Merge halves: SATISFIED.

## Sha -> PR -> row map

| branch sha | PR | merged (UTC) | merge commit | ledger row | criteria |
|---|---|---|---|---|---|
| 5a0f29ee4 | 9112 | 07:58:48 | 9730f6931 | pds-w38-verdict-freshness-arm | 11/12 |
| fb408a4e8 | 9113 | 07:58:56 | 716429bcb | pds-w38-falsifier-promotion | 9/10 |
| 633262f12 | 9114 | 08:08:57 | 8cb75fa5d | pds-bl-status-only-residue-payment | 7/8 |
| 23e990875 | 9115 | 07:59:03 | 190cadf91 | pds-w39-record-parity-shallow-guard | 9/10 |
| a94eeced2 | 9116 | 07:59:11 | aa81a9b6e | pds-w39-charter-ledger-corrections-owed | **0/3** |
| 03d27f02f | 9117 | 07:59:18 | 8e1e27d6b | pds-w34-owning-doc-amendment | 11/12 |
| 9b899c27c | 9166 | 11:19:34 | 034d5fcd8 | pds-w40-scim-groups-list-members | 8/9 |

**SIX are N-1, not seven.** `pds-w39-charter-ledger-corrections-owed` is 0/3 and
unclaimed — its three criteria are human adjudication of nine disagreements, which its
merged PR did not perform. It is not one lead act from closable.

## Claim-lapse audit (wish item 8, as a first-class check)

Every one of the six N-1 rows carries `claim.worker == null` with `claim.expired_at`
in the past — the lease lapsed while the work was done. `previous_worker` survives;
`epoch` survives (5, 6 or 7). The lapse is the reason the rows read `open`.

```
bp task get <row> -o json | python3 -c "import json,sys; d=json.load(sys.stdin)['doc']; print(d['claim'])"
```

Example (`pds-w38-verdict-freshness-arm`): `epoch 6`, `expired_at
2026-08-02T08:11:01Z`, `worker null`, `previous_worker
epic-builder-a-verdict-stops-outliving-the-defect-it-`, and a stale `claim.now.text`
reading **"DONE, unmerged: 5a0f29ee4"** — the same squash false-negative, frozen into
the ledger's own note.

**Audit them by `expired_at`, never by `lifecycle_status`**: `open` here means the
lease died, not that the work is unstarted.

## The residual lead act is NOT just "confirm merged"

Every unmet criterion is merge-gated AND carries a lead re-derivation half:
"...and the lead has re-run / has independently re-derived / has run mutation...".
Proving ancestry closes half a criterion, never a row.
