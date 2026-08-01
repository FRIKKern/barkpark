# cch wave 17 — ledger claimability + the MERGE-GATED tripwire, re-derived

Driven 2026-08-01 by the wave-17 verifier. Every line below is a command, not a reading.

## 1. Epoch is NOT predictable — it is +1 per transition, claim AND release

    bp task claim cch-w16-bl-theme-picker-select-clipped-at-320 verify-probe -o json
    bp task release cch-w16-bl-theme-picker-select-clipped-at-320 verify-probe <epoch> -o json

Observed: claim -> epoch 1 (`execution_class: foreign_claimed`, `lifecycle_status: in_progress`);
release -> epoch 2 (`executable`, `open`, `claim.worker: null`, `released_by` set); re-claim -> 3;
release -> 4. A RELEASE BUMPS THE EPOCH. Therefore a dispatch brief must NEVER hand a builder a
literal epoch — the builder reads it out of its own claim response.

Rows never claimed carry `claim: null` / `epoch: None` and take epoch 1 on first claim
(proven on cch-w14-bl-status-pill-label-overflows-rail).

## 2. Nothing on the epic is held

    bp task get cloud-console-hardening-epic -o json \
      | python3 -c "import json,sys;print(' '.join(c['doc_id'] for c in json.load(sys.stdin)['children'] if c['lifecycle_status']=='open'))"
    # then, per id:
    bp task get <id> -o json | python3 -c "import json,sys;d=json.load(sys.stdin)['doc'];print(d['execution_class'], (d.get('claim') or {}).get('worker'))"

68 open children (not 66), 68/68 `execution_class: executable`, 68/68 `claim.worker: null`.
Six carry a STALE `content.assignee` string with a lapsed lease — assignee is a display lie,
`claim.worker` is the truth.

Published check must use `bp doc get`, not `bp task get`:

    bp doc get task <id> -o json | python3 -c "import json,sys;d=json.load(sys.stdin);doc=d.get('doc',d);print(doc['_draft'])"

`bp task get` omits `_draft` entirely (reads None) — a `grep -c True` over it returns 0 whether
the corpus is published or not. Vacuous green. 68/68 read `_draft=False` via `bp doc get`.

## 3. The MERGE-GATED tripwire lives on `stamp` only, and keys on a literal string

Implementation: `internal/cli/tasks_stamp_cmd.go:119-128` —
`sa.met && !sa.mergeGated && strings.Contains(upper(text), "MERGE-GATED"|"MERGE GATED")`.
Wired at `internal/cli/cli.go:607` for `noun == "task" && verb == "stamp"` ONLY.

    bp task stamp <id> lead <epoch> --criterion N --met --criterion-text "<text>" --dry-run
    echo $?     # 5 = refused (error code merge_gated_criterion); 0 = allowed

Do NOT read the exit code through a pipe — `cmd | head` reports head's status.

Three drives:

| row / criterion | text carries marker | rc without `--merge-gated` |
|---|---|---|
| cch-w16-s3 #9 "MERGE-GATED (the lead closes this)…" | yes | **5, refused** |
| cch-w15-bl-fleet-support… #3 "MERGE-GATED (lead closes)…" | yes | **5, refused** |
| cch-w14-bl-status-pill-label-overflows-rail #4 "…THE LEAD CLOSES THIS ONE." | no | **0, allowed** |

The third is the finding: a lead-owned criterion worded without the literal token is UNGUARDED.
The guard is a string match on a sentence.

## 4. `bp task close --set criteria:=…` bypasses the tripwire entirely

    bp task close cch-w16-s3-pill-text-bounded-rail-and-fleet lead 11 done "…" \
      --set 'criteria:=[{"index":9,"met":true,"evidence":"<sha>","criterion":"<exact text>"}]' \
      --dry-run --yes
    echo $?     # 0 — request built, MERGE-GATED criterion flipped, no override asked for

So `--merge-gated` is required on the STAMP path and is NOT required (and not accepted) on the
CLOSE path. `--merge-gated` is client-side only — the dry-run POST query string does not carry it.

## 5. The digest fence bites if criteria are edited under a claim

`bp task close` fences on the claim-time work digest over title/description/acceptance_criteria.
Edit criteria after claiming and the close 409s `doc_changed_since_claim`; recovery is
`--set observed_rev=<current_rev>`, not a re-read. Amend criteria BEFORE claiming.
