<!-- doc-tier: cold | canonical-for: pds-wave-24-parked-adjudication-rederivation | budget: 4000tok -->

# PDS wave 24 — parked-row adjudication: re-derivation recipe

> HISTORICAL RECORD (2026-07-30) — the commands below were run on that date. Re-run them to re-derive; never quote the recorded output as current.

Verifier lane `parked-adjudication`. Every number below is re-derivable from the commands here.
The dispositions themselves live on the Barkpark ledger, not in this file.

## Instant

Task corpus paged at **2026-07-30T14:10:35Z**; 3791 `type:task` documents.

## Lens (do NOT crawl with `bp task get`)

A recursive `bp task get` crawl of the epic 429s under concurrent wave load — 117 of 178
first-level children failed on one run and a second run reached exactly 1 node. Page the query
API instead: 8 calls, ~15 s, no rate limiting.

```bash
S=https://guerrilla.barkpark.cloud; T=$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.config/barkpark/config.json')))['token'])")
for off in 0 500 1000 1500 2000 2500 3000 3500; do
  curl -s -H "Authorization: Bearer $T" "$S/v1/data/query/production/task?limit=500&offset=$off" -o pages/p$off.json
done
```

Then build the `parent_id` closure from `task-2ac1f95237c4a8e5` (root excluded) locally.

## Counts at that instant

| Lens | rows | `OPEN` | `open` | absent | `parked` |
|---|---|---|---|---|---|
| direct children, live | 110 | 46 | 32 absent | 24 | 8 |
| full closure, live | 167 | 56 | 37 absent | 47 | 27 |

Closure descendants 284 — open 135, done 91, considering 31, cancelled 26, blocked 1.
57 live rows are BURIED (invisible to a one-level `.children` read).

## The parked population splits 8 / 19, and the split is by DEPTH

- **19 rows** carry `disposition_reason` md5 `4f556ba7…`, exactly 644 B — the wave-22 generic
  evaporation notice. **All 8 direct-child parks are in this set.**
- **8 rows** carry row-specific reasons, 343–543 B, 8 distinct md5s. **All 8 are BURIED** —
  7 under `pds-w1-crown-proof` (done), 1 under `pds-bl-streaming-workspace-export` (open).

`27 parked` = `19 + 8`; 0 parked rows have an empty reason; all 27 contain the string
`REACTIVATE`.

## Rulings

1. **PDS-D322 is factually CORRECT on its stated population** and its rows were NOT repaired.
   All 8 direct-child parks still hold the identical 644 B boilerplate.
2. Its sub-claim "**0 of 8** carries a reopen trigger" is literally false — the boilerplate
   ends `REACTIVATE: re-adjudicate this row by content against origin/main before any work`.
   Generic, not row-specific; the spirit of the finding stands, the literal count does not.
3. Any "refutation" of D322 built on `pds-w20-crown-fire`, `pds-w12-measure`,
   `pds-w11-paired-control-measure`, `pds-w20-crown-collect-and-seal` is a **population error**:
   none of those four is a direct child.
4. **Repair set = 19 rows**, not 8 and not 0.

## The boilerplate asserts a falsehood about itself — 19/19

The 644 B text says "the original adjudication text is **NOT** recoverable". It is recoverable
for **every one of the 19**, via published revisions that snapshot `content.engagement.note`
before the 15-minute TTL sweep deleted it.

```bash
bp doc history task <row> --limit 100        # newest first
bp doc revision <rev_id>                     # .content.engagement.note
```

Each of the 19 has exactly **one** distinct recoverable note. 16 are dated
`2026-07-27T21:04–21:28Z` — the wave-22 adjudications themselves, written ~1 h before the
boilerplate overwrote them; 3 are older `2026-07-22T20:3x–20:4x` notes.

| property | count |
|---|---|
| rows with a recoverable note | 19 / 19 |
| notes already carrying `REACTIVATE` | 16 / 19 |
| notes ≤ 900 B (PDS-D308 bound) | 18 / 19 |
| longest / shortest | 1058 B (`pds-bl-tag-schema-frozen-in-stamped-slot`) / 120 B |

Worked example — `pds-bl-w13-stale-worktree-prune`, 22 revisions:
`2026-07-22T20:35:15.452419Z publish` carries the 120 B note
"Fresh reviewed ownership/activity evidence is required before destructive cleanup on the
1,442-worktree shared checkout." The 644 B boilerplate lands at `2026-07-27T22:28:42Z`.

The wave-22 ledger (`pds-w22-remaining-rows-triage-2026-07-27.md`) does **not** hold these
texts — it says so explicitly. The revision archive is the only recovery route, and it works.

## Template ruling

The four-part shape found in the 8 buried crown-family parks SURVIVES as the wave's template:
provenance (`PARKED by PDS wave 22 (charter PDS-D296)`) / row-specific `BLOCKER:` / an explicit
negative naming what would NOT unblock it (`The D100 thaw does not unblock it`) / one
`REACTIVATE:`. The 16 recovered notes already match it.

A **shared family trigger is legitimate**: all 8 buried parks end
`REACTIVATE: reopen when a crown fire is licensed` — one trigger, 8 distinct reason hashes.
Hash the reason, never the trigger.

**Caveat on the acceptance bar.** No trigger on this board is SCRIPT-evaluable; "when a crown
fire is licensed" is a human licence. A gate demanding a machine-evaluable trigger fails all 27
rows including the 8 best specimens in the epic. The honest bar is: a named, checkable
condition, one per row.
