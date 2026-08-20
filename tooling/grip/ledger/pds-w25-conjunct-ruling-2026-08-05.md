# pds-w25 N-1 conjunct ruling — re-derivation recipe (2026-08-05)

Verifier `n1-w25-conjunct-ruling`, wave 48. Ledger row only; no repo behaviour changes.

RULING: criterion 8 of `pds-w25-round-parked` is **DISCHARGEABLE**, not undischargeable.
The "8 unchanged hashes" clause is met by a third party today, independently of the
builder's own evidence, from the revision archive. Nothing needs amending on that row.
The counter buys only the first conjunct ("the 27 rows"); the hash conjunct needs the
archive walk below. Closing on the counter alone WOULD drop a conjunct — the disease —
but the conjunct is payable, so the honest move is to PAY it, not to refuse or amend.

## 0. Pin the artefacts (BOTH briefs' "not on main yet — it rides charter PR #8177" is STALE)

PR #8177 MERGED 2026-07-30T20:46:55Z as `bfd3e50a2`. The pinned artefacts are on origin/main.
The brief's `git fetch origin epic-charter/pds-w25-20260730T182017Z` sends a builder to a dead branch.

```sh
cd <repo> && git fetch origin main
git show origin/main:tooling/grip/ledger/pds-w25-board-manifest-2026-07-30.tsv > /tmp/w25m.tsv
git show origin/main:tooling/grip/ledger/pds-w25-shard-count.py            > /tmp/w25c.py
```

## 1. Conjunct A — "the 27 rows" / "the 103 rows" (the counter buys this, ~9.4 s for both)

```sh
python3 /tmp/w25c.py parked         /tmp/w25m.tsv; echo PARKED_RC=$?
python3 /tmp/w25c.py open-normalise /tmp/w25m.tsv; echo OPEN_RC=$?
```
Measured 2026-08-05: `class=parked pinned=27 COUNTED_OK=27 FAILING=0` rc=0 and
`class=open-normalise pinned=103 COUNTED_OK=103 FAILING=0` rc=0.

The manifest is TWO columns (`awk -F'\t' '{print NF}' /tmp/w25m.tsv | sort -u` -> `2`) and
carries NO hash, so "re-derive from the pinned manifest" can never produce conjunct B.
The counter checks only: disposition in {open,closed,parked}; non-empty `disposition_reason`;
parked => non-empty `reopen_trigger`; open => owner set and != own id. It never hashes anything.

## 2. Conjunct B — "the 8 unchanged hashes" (the archive walk; ~30 s serial)

Envelope shapes, measured, not assumed:
- live doc: `GET /v1/data/doc/production/task/<id>` -> fields FLAT under `.result`
  (NOT under `.result.content` — reading `.content` yields `{}` and every hash comes back
  `d41d8cd9` = md5 of the empty string, which looks exactly like data loss).
- history: `GET /v1/data/history/production/task/<id>?limit=300` -> `{count, revisions:[{id,status,timestamp,title,action,actor_user_id}]}`, no content, NOT sorted by timestamp.
- revision: `GET /v1/data/revision/production/<rev_id>` -> `{revision:{... , content:{...}}}` — here the fields ARE under `content`.

Recipe: for each of the 8 exemplar rows, take the LATEST revision with
`timestamp < 2026-07-30T19:00:00` carrying a non-empty `content.disposition_reason` (that is the
pre-write disposition), md5 it -> BEFORE; md5 `.result.disposition_reason` of the live doc -> AFTER.
Sleep 0.15 s between revision fetches (PDS-D351: `/v1/data/revision` rate-limits hard and a
missed note reads exactly like "no note in the archive").

Measured 2026-08-05, 8/8 BEFORE == AFTER == the hash stamped in criterion 5, six days after
the write, from a checkout that did not perform it:

| row | pre-write rev ts | BEFORE=AFTER | bytes |
|---|---|---|---|
| pds-bl-w13-export-duration-unmeasured | 2026-07-27T21:35:25.279038Z | 56e09551 | 401 |
| pds-bl-w13-spill-dir-full-export-unobserved | 2026-07-27T21:35:25.262138Z | 6f6abf68 | 343 |
| pds-w11-paired-control-measure | 2026-07-27T20:04:24.931282Z | f803bc91 | 412 |
| pds-w12-measure | 2026-07-27T20:04:22.775144Z | 293a527d | 445 |
| pds-w20-crown-collect-and-seal | 2026-07-27T20:02:44.696887Z | 981244b7 | 483 |
| pds-w20-crown-fire | 2026-07-27T20:05:20.178174Z | b007540e | 543 |
| task-328621eadb772c81 | 2026-07-27T20:05:20.668324Z | 5b4c1259 | 408 |
| task-8db002bc83e78718 | 2026-07-27T21:39:03.051868Z | 0c427305 | 358 |

All 8 live rows read `_draft:false` and carry the shared family trigger
`reopen when a crown fire is licensed.` (PDS-D336(a) legitimises the shared trigger).

## 3. `pds-w25-round-open`'s conjunct — "plus every free close by content"

Same half-buy shape, different second conjunct: 13 rows were CLOSED by content against
origin/main, each stamped with a fixing sha. All 12 distinct shas cited in criterion 4 are
ancestors of origin/main today:

```sh
for s in 92553f9a6 7d0846b0d f899ef2e9 63581a76d 645260961 448749cf1 \
         a190984df c4899b4ec c305a1a6e 6f4ca7904 c222a8739 99f713846; do
  printf "%-11s " $s; git merge-base --is-ancestor $s origin/main && echo ON_MAIN || echo NOT
done
```
Dischargeable, but only by a bounded per-row content re-check — the counter cannot buy it
(it accepts `closed` as a well-formed disposition without ever reading the sha or the code).
PDS-D353's warning applies: the two `pds-bl-scratch-pointer-*` rows re-check as "still broken"
if you read their own cited line (`scripts/pds-scratch-target.sh:124`, where the legacy
`POINTER_FILE` survives as a hint) rather than the current implementation.
