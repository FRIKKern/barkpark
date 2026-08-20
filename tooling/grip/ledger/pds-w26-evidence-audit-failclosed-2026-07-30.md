# PDS wave 26 — evidence audit, fail-closed (re-derivation recipe)

Verifier lane `evidence-audit-failclosed`. Measured 2026-07-30 22:0x–22:2x UTC against
`https://guerrilla.barkpark.cloud`. Every number below is reproduced by the command
printed with it. No paginated `len(docs) < limit` walk is trusted for a count.

`TOK` = the admin token in `~/.config/barkpark/config.json`.

## R1 — the epic rail (authoritative row set)

    curl -s -H "Authorization: Bearer $TOK" \
      https://guerrilla.barkpark.cloud/v1/tasks/task-2ac1f95237c4a8e5 \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["child_count"], len(d["children"]))'

→ `205 205`. Eight of those 205 are NOT `pds-`-prefixed
(`pdf-provider-neutral-fleet-tooling`, `task-015fb9866bc2cc59`, `task-018754b481a901df`,
`task-1e76a21eb8a17d43`, `task-5c4f2673778d5ff0`, `task-6fc6820c62e9b646`,
`task-a0e37c21f73f8e26`, `task-fff1116564723b60`). One is `drafts.`-prefixed
(`drafts.pds-bl-tagregistry-guard-no-rung`).

## R2 — per-doc reads, never a page

For each id: `GET /v1/data/doc/production/task/<id>`, assert HTTP 200, assert
`result._id == <id>`, assert `result._draft is False`. 205/205 → 200.
204/205 `_draft:false`; the exception is `drafts.pds-bl-tagregistry-guard-no-rung`
(`_draft:true`).

TRAP MEASURED HERE: `while read -r id` over a file with no trailing newline
silently drops the last id (204 fetched, 205 expected). Always
`printf '\n' >> ids.txt` and assert `wc -l` against the expected count.

## R3 — fail-closed enumeration of the whole task corpus

Paginate with `count=true` and assert `collected == result.total`:

    limit=200, offset walked, fields=_id,parent_id, order=_id asc, perspective=raw
    → pages 22  total_reported 4203  collected 4203  unique 4203   (assert passes)

Without `count=true` the response carries **no `total` field at all** — measured:
a `limit=1000` walk terminated on `len(docs)<1000` returns `total_field=None` on
every page, so it has nothing to assert against. That is the residual fail-open in
`scripts/pds-ledger-census.sh` (`fetch_page`, line 314: `query = "limit=%d&offset=%d"`).
Adding `&count=true` + a `collected == total` assertion closes it.

## R4 — hollow-evidence audit (the headline)

Population = every `pds`-prefixed row in the store (raw perspective), not the rail:

    299 rows (298 published + 1 draft)
    1448 acceptance_criteria
     787 met:true
       0 met:true with empty evidence
       0 met:true with evidence < 40 bytes

Restricted to the 205 rail children: 964 criteria, 503 met:true, 0 hollow, 0 short.
(The digest's 960/503 is the same figure with the 4 zero-evidence draft criteria
excluded.) The zero-hollow result STANDS under a read that cannot truncate silently.

## R5 — draft-twin diff (the second-door in-ledger test)

`drafts.<id>` is directly addressable on `/v1/data/doc/...`. Probing all 205 rail
twins (and again with `?perspective=raw` — identical answers):

    2 × 200, 203 × 404
    200: drafts.pds-bl-tagregistry-guard-no-rung
    200: pds-bl-tagregistry-guard-no-rung

Confirmed against the fail-closed R3 walk: exactly **one** `drafts.pds*` row exists
store-wide, and **zero** pds rows are draft-only.

THE PAIR, live:

| | published | draft |
|---|---|---|
| `_createdAt` | 2026-07-20T09:59:05Z | 2026-07-30T19:29:55Z |
| `_updatedAt` | 2026-07-30T19:36:24Z | 2026-07-30T20:14:40Z |
| `lifecycle_status` | `done` | `open` |
| criteria met | 3 / 4 | 0 / 4 |
| evidence bytes | **1113** | **0** |

`acceptance_criteria` differ. `bp doc publish task pds-bl-tagregistry-guard-no-rung`
right now replaces the published row wholesale from that draft and destroys 1113
bytes of stamped evidence, reverting done → open. Armed, live, today.

## R6 — the two lenses have opposite blind spots on that one row

* `/v1/tasks/<epic>` children: lists `drafts.pds-bl-tagregistry-guard-no-rung`
  (0/4, open) and does NOT list the published `pds-bl-tagregistry-guard-no-rung`,
  though both carry `parent_id: task-2ac1f95237c4a8e5`.
* `scripts/pds-ledger-census.sh` sends no `perspective` param → published only
  (`corpus_size: 3870` vs raw `total: 4203-4205`). It sees the done row and is
  blind to the draft entirely.

Neither lens can see the hazard. A third read — `perspective=raw`, `drafts.` prefix —
is required, and it is one query param away.

## R7 — the census does not silently undercount today

Three consecutive census-shape walks (`limit=1000`, stop on short page):
`pages=5 collected=4205 err=None` ×3, ~12–14 s each. No mid-walk 500 reproduced.
`scripts/pds-ledger-census.sh --json` → `rc=0`, `VERDICT: census complete and coherent`,
`closure_size: 310`, `corpus_size: 3870`, 16.4 s. `--assert-round-done` → `rc=1` with
`off-vocabulary dispositions == 0  15  FAIL` and
`live rows carrying a disposition  157/172  FAIL`.

NOTE ON `--perspective raw` — `GET /v1/data/doc/production/task/<published-id>?perspective=raw`
returns the PUBLISHED row and does not surface the draft twin. Raw only reveals a twin
when the `drafts.` prefix is addressed explicitly, or on the `/v1/data/query` list route.
