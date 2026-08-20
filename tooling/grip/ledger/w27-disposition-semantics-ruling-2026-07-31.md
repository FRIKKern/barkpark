# Re-derivation recipes — disposition semantics ruling (PDS wave 27, 2026-07-31)

Verifier lane `disposition-semantics-ruling`. Question: is `disposition=closed`
on a lifecycle-claimable row a DEFECT the round repairs, or deliberate
orthogonality? Plus: re-derive the authoritative contradiction population
(strategist said 15, a surveyor said 16) and determine overlap with the 45.

**No bp mutation of any kind was made by this lane.** Only `bp task get`,
`bp doc query`, `bp task ready`, `bp search query` — all reads. The census was
run from a `git show origin/main:` copy in `/tmp`, never from the primary
checkout (which does not carry `scripts/pds-ledger-census.sh` at all).

## 1. The contradiction population — 16, stable across two independent passes

```bash
bp task ready --all -o json > /tmp/ready.json
for o in 0 1000 2000 3000; do
  bp doc query task --fields doc_id,disposition,lifecycle_status,reopen_trigger \
    --limit 1000 --offset $o -o json > /tmp/pg$o.json
done
python3 -c "
import json
d={}
for o in (0,1000,2000,3000):
    for x in json.load(open('/tmp/pg%d.json'%o))['documents']: d[x['_id']]=x
r=[x['doc_id'] for x in json.load(open('/tmp/ready.json'))['docs']]
bad=sorted((i,d[i].get('disposition')) for i in r if i in d and d[i].get('disposition') in ('closed','parked'))
print(len(bad)); [print(*x) for x in bad]"
```

Two full passes 00:55Z and 00:58Z: **16 both times**, identical id sets.
13 `closed` + 3 `parked`. Manifest 3901 unique ids over 4 pages, zero
duplicates. `ready` = 1261 rows, of which **28 ids are absent from the manifest**
(the orphan-draft population). **Zero ready rows carry a `disposition` key.**

## 2. Overlap with the 45 — ZERO, fully additive

```bash
# census from origin/main, patched IN A SCRATCH COPY ONLY to emit ids
git show origin/main:scripts/pds-ledger-census.sh > /tmp/census.sh
sed 's/^        "live_adjudicated": len(live_adjudicated),/        "live_adjudicated_ids": sorted(r["_id"] for r in live_adjudicated),\n&/' \
  /tmp/census.sh > /tmp/census_dbg.sh
bash /tmp/census_dbg.sh --json --anchor-from-paper pds-wave-27-2026-07-31 > /tmp/cend.json
```

- 15 of the 16 are INSIDE the PDS closure and appear in `live_adjudicated_ids`
  (156 rows) — i.e. they are counted in clause 4(a)'s **numerator as SATISFIED**.
- `task-32ce52edfd7af367` is outside the closure (a neighbour epic's row).
- Intersection with the 30 `live_bare` + `live_bare_residue` = **empty**.
- Intersection with the terminal 15 = **empty** by construction: all 15
  off-vocabulary rows are `lifecycle=done`, all 16 contradictions are
  `lifecycle=open`.

Structural cause, read on `origin/main`:
`api/lib/barkpark/tasks/queue.ex` — `disposition` occurs **0 times**;
census `pds-ledger-census.sh` — `live_adjudicated = [r for r in live if
disposition_of(r)]`, so a `closed` disposition on a live row is *evidence of
compliance*. **Neither instrument can see this population.**

## 3. The charter is NOT silent — PDS-D298 binds disposition to lifecycle

```bash
git show origin/main:.claude/workflows/bp-pds-charter.md | sed -n '4318,4326p'
```

> - **CLOSED** → `bp task close <id> <worker> <epoch> done "<reason>"` → `content.close_reason` …
> - **PARKED** → `bp task stage <id> considering --object research --worker <w> --disposition parked …`
> - **OPEN** → the same verb with `--disposition open …`

Each of the three classes prescribes a LIFECYCLE ACT. `closed` is a
`bp task close` (terminal lifecycle + `close_reason`); `parked` moves lifecycle
to `considering` (non-claimable). Corroborated in code:

```bash
git show origin/main:api/lib/barkpark/tasks/validation.ex | sed -n '19,31p'
```

> `"OPEN MEANS READY" is held by construction — only open|blocked is claimable`
> `@claimable_statuses ~w(open blocked)`

## 4. All 16 are half-executed recipes, none is a genuinely-live row

```bash
python3 - <<'EOF'   # per-row: disposition, criteria met, trigger, claim, close_reason
# bp task get <id> -o json | .doc.content
EOF
for s in 448749cf1 63581a76d 645260961 92553f9a6 7d0846b0d a190984df 6f4ca7904 f899ef2e9; do
  git merge-base --is-ancestor $s origin/main && echo "$s ANCESTOR"; done
```

- 13 `closed`: every reason opens `CLOSED …`; 11 cite a fixing sha, **all 8
  distinct shas are ancestors of `origin/main`**; 2 assert the row's stated
  defect is false against main. `close_reason` is **absent on every one** and
  `content.claim` is **null on every one** — `bp task close` was never called.
- 3 `parked`: every one carries a structured `reopen_trigger`.
- **0 rows are genuinely live.**
- Acceptance criteria are unmet on all 13 (0/3 … 6/8), so repair needs
  `:criteria_override` per `api/lib/barkpark/tasks/close.ex` (recorded as
  `close_override.criteria`) plus a claim or `:holder_override`.

## 5. A stamped criterion on the epic's own round row is FALSE today

`pds-w25-round-bare` criterion 1 (`met: true`) evidence ends:

> "All 8 verified lifecycle=done AND disposition=closed by re-read."

Its evidence names `scripts/pds-scratch-target.sh` `registry_add/remove/live`
and `arm_floor_record` in `scripts/pds-crown-launch.sh`. Those artifacts are the
subject of `pds-bl-scratch-pointer-concurrency`,
`pds-bl-scratch-pointer-explicit-default` and
`pds-bl-w16-arm-never-records-its-own-floor`, which today read
`lifecycle=open, disposition=closed, claim=null`. No `drafts.` twin exists for
any of the three (`bp task get drafts.<id>` → `not_found`), so this is not a
twin artefact.

## 6. The tgw trap for any queue rule

```bash
# store-wide off-vocabulary dispositions
python3 -c "...disposition not in ('open','closed','parked')..."   # → 41
```

26 of the 41 are `tgw*` rows whose disposition literal is
`'open — demoted child of truth-grip-epic (charter D117)'`. A gate phrased
`disposition IS NOT NULL AND disposition != 'open'` deletes all 26 from a
neighbour epic's queue. Any rule must match on the NORMALISED vocabulary and
treat unrecognised terms as live.
