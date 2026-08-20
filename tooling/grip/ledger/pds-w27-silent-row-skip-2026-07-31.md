# Re-derivation recipes — PDS w27 verifier lane `silent-row-skip` (2026-07-31)

Question: does the census's offset-paged read over `/v1/data/query` (server default
`ORDER BY updated_at DESC`) SILENTLY drop rows when the board is written during the
read? Verdict: the SKIP IS REAL, and it is NOT SILENT under DESC — every skipped row
is paid for by exactly one duplicate at the page boundary, and the duplicate detector
dies `EXIT_INCOHERENT` (4). The clause-5 drift detector does NOT fire, because it is
closure-scoped. `order=_createdAt:asc` makes the read immune to writes. Live rows are
guerrilla; a disposable probe row (`task-dca82364a92a4f0d`, `parent_id` null → OUTSIDE
the PDS closure) supplies the write.

| # | Claim | Command |
|---|---|---|
| 1 | The census sends NO order param — the server's `updated_at DESC` default is what it pages | `git show origin/main:scripts/pds-ledger-census.sh \| sed -n '387p'` |
| 2 | It pages by EXPLICIT offset, and a short page ends the read | `git show origin/main:scripts/pds-ledger-census.sh \| sed -n '470,481p'` |
| 3 | Server default order = `desc: updated_at` (catch-all clause) | `git show origin/main:api/lib/barkpark/content/query.ex \| sed -n '704p'` |
| 4 | `?order=` IS parsed by the query controller (`_updatedAt`/`_createdAt`/`<field>:dir`) | `git show origin/main:api/lib/barkpark_web/controllers/query_controller.ex \| sed -n '31p;683,713p'` |
| 5 | A write moves its row to index 0 under the default order; the row it displaces is served TWICE and the written row, if unread, is NEVER served | with the probe at index p≥1 of `task?limit=20&offset=0`: read `limit=1&offset=0`, then `bp task stage task-dca82364a92a4f0d done --disposition closed --note w27 --worker verifier-w27-silentskip --yes`, then read `limit=1&offset=1..p+2`. Observed p=3: offsets 0 and 1 both return `jarl-dogfood-publishing-epic`; the probe is absent from the whole window it occupied |
| 6 | The duplicate detector turns that shift into exit 4 — deterministically, no live write | build `fx/page-{0,1,2}.http` (`HTTP 200` + `{"result":{count,offset,limit,documents}}`) where page 1 re-serves page 0's last row, then `bash scripts/pds-ledger-census.sh --fixture-dir fx --page-limit 2; echo $?` → `4` + `SNAPSHOT INCOHERENT: 1 row(s) were served on more than one page` |
| 7 | The clause-5 drift detector is CLOSURE-scoped: a write to a non-closure row inside the census window leaves `drifted: []` | `git show origin/main:scripts/pds-ledger-census.sh \| sed -n '620p'` · run `bash scripts/pds-ledger-census.sh --json --page-limit 100` and stage the probe (`parent_id` null) ~6 s in, then read `.drifted` |
| 8 | `order=_createdAt:asc` is a TOTAL order here — 3901/3901 rows, zero `_createdAt` ties, globally sorted across four 1000-row pages | full read at `limit=1000&offset=0,1000,2000,3000&order=_createdAt:asc`, then compare `cre == sorted(cre)` and `collections.Counter(cre)` ties |
| 9 | Under `_createdAt:asc` a write does NOT move its row: index 3894 before and after, `_createdAt` byte-identical, relative order of all pre-existing rows preserved | full `_createdAt:asc` read → `bp task stage task-dca82364a92a4f0d done --disposition closed --note w27 --worker verifier-w27-silentskip --yes` → full `_createdAt:asc` read; compare index of the probe and the id sequence |
| 10 | `order=doc_id` (no direction) SILENTLY falls back to `updated_at DESC` — byte-identical to the no-order page, no error | `curl … 'task?limit=5&offset=0'` vs `curl … 'task?limit=5&offset=0&order=doc_id'` |
| 11 | `order=doc_id:asc` parses as a CONTENT field (`jsonb_extract_path(content,'doc_id')` → all NULL) so the result is NOT doc-id ordered and NOT stable — the obvious "fix" is worse than the bug | `curl … 'task?limit=5&offset=0&order=doc_id:asc'` — first ids come back `ppcc-…, gp-…, pds-…, pdf-…, stw11-…` |
| 12 | Keyset paging is expressible today (immune to deletes too): `order=_createdAt:asc` + `filter[_createdAt][gt]=<last seen>` | `curl … 'task?limit=3&order=_createdAt:asc&filter[_createdAt][gt]=2026-07-20T00:00:00Z'` → first row `_createdAt` 2026-07-20T00:33 (corpus min is 2026-07-01) |
