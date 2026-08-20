# Wave 58 — arrears roster, live epochs, and the lapse mechanism caught in the act (2026-08-09)

Re-derivation recipes. Every number below is point-in-time; the epochs are stale the moment
the next expiry sweep runs (see §3).

## 1. Roster with pagination (the 500-cap is not hit by `--all`)

```
cd /Volumes/SATECHI/github/barkpark && bp task ls --all -o json > /tmp/w58all.json && python3 -c "import json,collections;d=[x for x in json.load(open('/tmp/w58all.json'))['docs'] if x.get('parent_id')=='cloud-console-hardening-epic'];print(len(d),collections.Counter(x['lifecycle_status'] for x in d))"
```

02:53Z: `796 Counter({'open': 403, 'done': 324, 'cancelled': 60, 'in_progress': 8, 'considering': 1})`
02:55Z: `796 {'open': 411, 'cancelled': 60, 'done': 324, 'considering': 1}`

`--all` returns the whole payload (6236 docs); the 796 lifetime figure is complete, not a floor.

## 2. Both denominators

```
python3 -c "
import json,collections
ch=[x for x in json.load(open('/tmp/w58all.json'))['docs'] if x.get('parent_id')=='cloud-console-hardening-epic']
c=collections.Counter(x['lifecycle_status'] for x in ch)
live=[x for x in ch if x['lifecycle_status'] in ('open','in_progress','considering')]
print('HONEST(live)=',len(live))
print('BRIEFED(live non-draft)=',len([x for x in live if not str(x.get('doc_id','')).startswith('drafts.')]))
"
```

HONEST = 412 · BRIEFED = 404 (8 `drafts.*` shadow rows) · live-with-acceptance_criteria = 374.

## 3. The lapse mechanism, observed live

Claims expire 45 minutes after `ts_iso`, applied by a sweeper that runs on the **minute boundary**.
Expiry bumps `claim.epoch` by 1, nulls `claim.worker`, writes `claim.expired_at` +
`claim.previous_worker`, and flips `lifecycle_status` `in_progress -> open`.

```
bp task get cch-w57-s1-terminal-act-residue-register -o json | python3 -c "import sys,json;c=json.load(sys.stdin).get('doc',{}).get('claim',{});print({k:c.get(k) for k in ('epoch','worker','expired_at','previous_worker','ts_iso')})"
```

Claimed 02:08:46.251383Z -> expired 02:54:00.410613Z, epoch 5 -> 6.
Five of eight rows lapsed BETWEEN two of this verifier's own reads (02:53 -> 02:54).

## 4. Merge-gated close does not exist (client or server)

```
bp task close x y 1 done r --merge-gated; echo $?      # -> bp: unknown flag --merge-gated for task close ; 2
bp capabilities -o json | grep -c merge_gated          # -> 0
```

A **plain** close is fully supported (`bp task close <id> <worker> <epoch> [status] [reason]`,
`--dry-run` previews). Five waves of zero-close are therefore NOT tool-blocked.

## 5. Ancestry proof for the close list

```
for s in <merge-sha>; do git merge-base --is-ancestor $s origin/main && echo "ANCESTOR $s"; done
```

origin/main = 989b19577e8fa108146807cdd84a3d48d011d9bc.

## 6. GROUP B close recipe (all 19 candidates are lapsed; there is no GROUP A)

```
bp task claim <doc_id> <worker>          # returns the ONLY epoch a close may quote
bp task close <doc_id> <worker> <epoch_from_claim> done "<PR #N merged <sha>, ancestor of origin/main>"
```

Never quote an epoch read from `bp task ls` / `bp task get` — it is a *pre-lapse* epoch if the
row is `in_progress` and a *post-lapse* epoch that no worker holds if the row is `open`.
Re-claim also refreshes the claim-time work digest, which is what the close fences on.
