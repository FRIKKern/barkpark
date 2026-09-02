<!-- doc-tier: cold | canonical-for: w33-count-and-landed-truth | budget: 5000tok -->
# w33 — the epic's count, re-derived lease-independently, and the landed set re-verified

> HISTORICAL RECORD (2026-08-09) — the commands below were run on that date. Re-run them to re-derive; never quote the recorded output as current.

`task-fb4fb869490b4213` · origin/main `4ca033f502f4` · 2026-08-09T20:20–20:25Z

## 1. The count, four reads, timestamped

```
bp task get task-fb4fb869490b4213 -o json | python3 -c "import json,sys,collections,datetime;d=json.load(sys.stdin,strict=False);print(datetime.datetime.utcnow().isoformat()+'Z',d['child_count'],collections.Counter(x['lifecycle_status'] for x in d['children']))"
```

| read | UTC | child_count | open | done | cancelled | in_progress |
|---|---|---|---|---|---|---|
| 1 | 20:20:03 | 300 | 160 | 125 | 12 | 3 |
| 2 | 20:22:11 | 300 | 160 | 125 | 12 | 3 |
| 3 | 20:24:14 | 300 | 160 | 125 | 12 | 3 |
| 4 | 20:25:08 | 300 | 160 | 125 | 12 | 3 |

**The split is stable over 5 minutes — and it is still not safe to quote.** All three
`in_progress` rows carry a claim whose `expired_at` is **19:49Z**, already 35 minutes in the
past at read 1. Lifecycle does not flip on read; it flips when a sweeper runs. So
`in_progress`/`open` is a function of when the sweep last ran, never of work state.

## 2. GENUINE-OPEN, computed so the lease cannot move it

`genuine_open = (open ∪ in_progress) − rows at 100% criteria − rows with no criteria`

| term | rows |
|---|---|
| open ∪ in_progress | 163 |
| − at 100% criteria (`dr-w28-s4-followup-payload-key-census-deferral-wait` 3/3, `dr-w32-s7-reclaim-the-ledger-in-one-act` 7/7) | 2 |
| − null-criteria rows (`dr-w25-followup-reader-blind-to-transition`, `dr-w27-s8-f1-seven-day-door-refuses-until-boundary-ages-out`, `dr-w32-s4-followup-prove-the-first-run-path-live`, `task-e2acb66e9ed0da09`, `task-6d1bb2843f0c91fb`, `task-a02741ad13bbf010`) | 6 |
| **GENUINE-OPEN** | **155** |

Identical at all four reads. Of the 163, **100 sit at 0/N** and 6 more carry no criteria at
all — 106 of 163 have never had a criterion stamped.

## 3. D546 re-run over the 24 rows w32-s7 deliberately left open

```
git log origin/main --format='%B' > /tmp/mainmsgs.txt
while read s; do echo "$(grep -c "^Task: $s\$" /tmp/mainmsgs.txt) $s"; done < rows.txt
```

15 of 24 return ≥1. **9 return 0.** One of those 9 (`dr-w30-s1-followup-carry-the-reask-list`)
is the absorbed/cancelled row, which never had a `Task:` line anywhere. The other **8 rest on
the PR body alone** — each verified `state=MERGED`, mergeCommit an ancestor of origin/main,
exactly **one** standalone `Task:` line in the body, and **zero** occurrences in main's own
commit messages:

| row | PR | mergeCommit | ancestor |
|---|---|---|---|
| `dr-w13-s5-cli-reads-columns-and-names-its-window` | #10350 | `a554ed967fd5` | yes |
| `dr-w19-s6-ledger-pays-its-debt` | #10565 | `ebfab89e3cd8` | yes |
| `dr-w2-s1-recorder-build-id-keyed-log` | #9727 | `9edfd15a649e` | yes |
| `dr-w24-s1-crown-schema-stops-losing-rows` | #10942 | `531cb6502a72` | yes |
| `dr-w24-s6-roster-buys-back-seal-headroom` | #10949 | `4a48161881ca` | yes |
| `dr-w28-s4-the-deferral-wait-becomes-a-number` | #11207 | `5f381365913e` | yes |
| `dr-w8-s4-census-reaches-a-human` | #10017 | `16d47c7bfa12` | yes |
| `dr-w26-s3-deliveries-reader-stops-lying-about-carried` | #11080 | `fd20408b4a1a` | yes |

D546's "scan main's own commit messages as a second, independent source" therefore does not
corroborate a third of the set: for these 8 the PR body is the only witness.

### Known false-negative mode, re-confirmed

| row | PR | mergeCommit | ancestor | standalone `Task:` in body | slug mentioned in body | `Task:` on main |
|---|---|---|---|---|---|---|
| `dr-seal-run-harness-runs-in-no-ci` | #11320 | `2f583ea1e223` | yes | 0 | 1 (`Refs:` line) | 0 |
| `dr-transport-silence-still-exits-zero` | #11319 | `917521fbe878` | yes | 0 | **0** | 0 |

#11319 is worse than D546 records: its body never names the slug at all, so no slug-keyed
scan of any strictness can find it. `Refs:` is a recoverable miss; #11319 is not.

## 4. The 52 closes verify

76 landed rows in the partition table; 52 read `done` now, and the 24 that do not are
**exactly** the by-design left-open set (23 open + `dr-w30-s1-followup` cancelled). Zero
unexpected reversions.

## 5. `done 126` was never independently derived

It appears in exactly two places, both authored by the reclaim builder: its own claim note
(`"gate run (300 children, open 149, done 126, cancelled 12)"`, ts 19:15:19Z) and criterion 7's
evidence quoting the same single run. Charter line 11171 (origin/main) copies it forward. No
second derivation exists anywhere.

It also fails the builder's own arithmetic: the claim records `done 73` before the act and
the execution record records **52 closes**. 73 + 52 = **125**, which is what the server
returns. 126 is one row unaccounted for by any act the record describes.

`bp task close`/`cancel` moved 4 rows to cancelled: 8 + 4 = 12 ✓ — the cancelled arm reconciles
exactly, which is why the `done` arm's off-by-one is a real discrepancy and not read noise.

## 6. The published count is already gone

w32-s7 criterion 6 claims the before/after counts were "published on the epic task's
`wave_status`". `wave_status` is one mutable string: it now reads
`"wave: verifying — gauge reproduces D537 exactly …"`. The publication survived roughly one
hour. Any count that must be re-readable belongs in a committed file, not in `wave_status`.

## rerun

```
bp task get task-fb4fb869490b4213 -o json | python3 -c "import json,sys,collections,datetime;d=json.load(sys.stdin,strict=False);print(datetime.datetime.utcnow().isoformat()+'Z',d['child_count'],collections.Counter(x['lifecycle_status'] for x in d['children']))"
git log origin/main --format='%B' | grep -c '^Task: dr-w8-s4-census-reaches-a-human$'   # 0
gh pr view 10017 --json body,mergeCommit,state
git show origin/main:.claude/workflows/bp-deploy-reliability-charter.md | sed -n 11171p
```
