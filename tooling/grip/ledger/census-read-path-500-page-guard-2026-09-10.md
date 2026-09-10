# The census page guard, and what is still UNPROVEN about the 500 — 2026-09-10

Row: `pds-bl-census-read-path-500-under-load` (P2).

## What was actually built (criteria 1 and 2)

`tooling/grip/ledger/census_walk.py` — one guarded walk over
`GET /v1/data/query/:dataset/:type`. It terminates ONLY on a page that proves it
is the last one, and raises `CensusWalkRefusal` on everything else. It never
breaks on a failure.

| Page shape | Old `< limit: break` walk | Guarded walk |
|---|---|---|
| `hasMore:false` | end of board | end of board (`terminator=hasMore=false`) |
| HTTP 500 / 503 / 401 | swallowed → **end of board** | REFUSE, named, with the body |
| `200 {"ok":false,...}` (parses!) | `documents` missing → **end of board** | REFUSE — "no `result` object" |
| 200, unparseable body | traceback or **end of board** | REFUSE |
| short page + `hasMore:true` | **end of board** | REFUSE — "TRUNCATED STREAM" |
| server capped `limit` | silent under-read | REFUSE — "silently capped" |
| `count != len(documents)` | invisible | REFUSE |
| never terminates | infinite loop | REFUSE after `max_pages` |

`hasMore` is the terminator because it is EXACT server-side: the query reads
`limit + 1` rows (`api/lib/barkpark/content/query.ex:115-118`) and the envelope
surfaces the result (`api/lib/barkpark_web/controllers/query_controller.ex:234-242`).
`count` is this page's length, not the corpus; `total` exists only under
`?count=true` (`query_controller.ex:1187-1199`). When `hasMore` is absent the walk
falls back to the short-page rule and SAYS SO in `terminator`, so a caller can
tell a proof from an assumption.

### The mutation proof lives in the selftest

`python3 tooling/grip/ledger/census_walk.py --selftest` — 20 arms, THREE of them
controls (a clean board must still walk; a guard that refuses everything scores
100% without them). The load-bearing arm is
`RED: legacy '< limit: break' under-reports`: it builds ONE stub whose page 2 is
an HTTP 500, runs the verbatim legacy walk over it (bare `except` → empty list →
`< limit: break`), asserts the legacy walk returns **500 rows instead of 1007 and
exits clean**, then runs `walk_pages` over the SAME stub and requires a refusal.
If the legacy shape ever stops under-reporting, that arm fails and the premise of
this file is gone.

## Sibling set — DERIVED from the code, not from the filing

`grep`ed `tooling/grip/ledger`, `scripts/ledger`, `scripts/pds-*.sh`,
`tooling/pds` for a file carrying `limit` + `offset` + `break`. Nine files
matched; four were real walkers with the defect, three were already hardened,
two matched on prose only.

| Walker | Verdict | Action |
|---|---|---|
| `tooling/grip/ledger/pds-w25-shard-count.py` | retried 5xx then `raise` (safe direction), but no echo assert, no `count` assert, no truncation guard, **no test** | rewritten onto `census_walk`; gained `--selftest` |
| `tooling/grip/ledger/pds-w25-rowdump.py` | guarded with bare `assert` for status AND for the `limit`/`offset` echo AND for `count == len(docs)` — **all no-ops under `python3 -O`**, and the shape asserts are precisely the ones that catch a SILENT under-read. With asserts live a 500 died as an unnamed `AssertionError`/`KeyError`, one `except Exception` from becoming an empty page | rewritten onto `census_walk` |
| `scripts/ledger/claim-shape-census.py` | never checked `bp`'s returncode and never checked `ok:false`; both produce a body with no `page` → `has_more` falsy → **silent break, smaller denominator**. Also `offset += limit` while the server caps a page at 1000 | fail-closed refusals + stride now advances by rows DELIVERED; gained `--selftest` (10 arms, 3 controls) |
| `scripts/pds-charter-ledger-sweep.sh` | echo-asserted already, but `count` was the terminator and was never compared against `len(documents)`, and `hasMore` was ignored | `count`/`documents` agreement asserted; `hasMore` now decides; short+`hasMore:true` is UNCHECKED |
| `scripts/ledger/conditional-criteria-census.py` | already hardened — keyset cursor, returncode checked, `ok:false` checked, `has_more` + `next_cursor` both required | no change |
| `scripts/pds-ledger-census.sh` | the EXEMPLAR — `fetch_page` refuses non-2xx, unparseable, missing `result`, capped limit, wrong offset, `count` mismatch | no change (its clause set is what `census_walk` reimplements for Python callers) |
| `scripts/pds-door-census.sh`, `scripts/pds-pull-proof.sh`, `scripts/pds-ledger-census_test.sh` | matched on PROSE about offsets, no walk of their own | no change |

There is no shared helper the walkers already imported — the four sites each
carried their own loop. `census_walk.py` is now that helper for the two
`tooling/grip/ledger` Python walkers (same directory, so a plain import works);
`claim-shape-census.py` speaks to `bp` over subprocess rather than HTTP and gets
the same rule expressed in its own transport, and the charter sweep is bash-hosted
Python with its own `unchecked()` refusal channel.

## Criterion 0 is UNMET, and cannot be met from here

The row asks for the 500 **reproduced under concurrent write load with its
server-side cause named FROM LOGS**. No agent in this campaign can read
guerrilla's journal, and re-running the sweep under deliberate write load would
mean hammering a live shared box. So: named from CODE, honestly labelled as
candidates, and the operator's exact command is given.

Candidate causes, read out of `api/`:

1. **`Postgrex.Error` SQLSTATE 57014 (`canceling statement due to statement
   timeout`)** — the leading candidate. `api/config/runtime.exs:996` sets
   `parameters: [statement_timeout: "30s"]` pool-wide in prod. The controller's
   ONLY rescue is `rescue e in DBConnection.ConnectionError`
   (`query_controller.ex:89-104`), which converts a pool checkout drop into a
   **503**, not a 500. A `Postgrex.Error` is NOT rescued: it crashes the action,
   Phoenix's `RenderErrors` answers 500, and it never reaches
   `FallbackController` — which is exactly the "Sent 500 with no error line"
   shape.
2. **`Postgrex.Error` 40001 / 40P01** (serialization failure, deadlock) — same
   unrescued path, and "concurrent write load" is the condition that produces them.
3. **An unrescued checkout failure in the auth guard**, `Content.schema_public?/3`
   at `query_controller.ex:34` and the token plugs, which run OUTSIDE
   `query_index/4` and therefore outside the only rescue.
4. **Pool starvation making 1-3 far likelier**: `pool_size` defaults to **10**
   (`runtime.exs:994`) and 29 declared Oban queue slots share it with all HTTP
   traffic (`runtime.exs:906-909`). `queue_target`/`queue_interval`/Ecto
   `:timeout` are deliberately unset in prod (`runtime.exs:898-935`), so the
   DBConnection defaults apply (50 / 1000 / 15_000).
5. **Unbounded per-row work on a `limit=1000` page**: the page materialises
   `limit + 1` full `%Document{}` rows (`query.ex:115`); `?expand=` costs roughly
   `3 × (#distinct ref types)` extra queries with an unbounded `id IN (...)`
   (`expand.ex:137-198`, `query.ex:1812-1818`); `?resolve=tasks` issues at least
   one task query per task block per document with NO cross-document memo
   (`query_controller.ex:655-673`, `task_resolver.ex:64-83`). Any of these can
   push one request past the 30s wall.

**What an operator must run on the box** (`89.167.28.206`, `/opt/barkpark`) to
close criterion 0 — the window is 2026-07-30 ~19:22Z:

```bash
journalctl -u barkpark --since '2026-07-30 19:15' --until '2026-07-30 19:35' \
  | grep -nE 'Sent 500|canceling statement due to statement timeout|Postgrex\.Error|57014|40001|40P01|FallbackController: rendering 5|no build/1 clause matched|connection not available and request was dropped from queue'
```

and, for the same window's request ids and paths:

```bash
journalctl -u barkpark --since '2026-07-30 19:15' --until '2026-07-30 19:35' \
  | grep -B4 'Sent 500' | grep -E 'request_id=|GET /v1/data/query'
```

A 500 whose neighbouring line is `canceling statement due to statement timeout`
confirms (1); `connection not available and request was dropped from queue` with
a **503** confirms the rescue worked and points the 500 elsewhere.

## What this ledger note does NOT claim

- It does not claim the 500 is fixed. Nothing server-side was touched; the fence
  was caller-side.
- It does not claim the 500 was reproduced. The 2026-07-31 settling probe in the
  row's own `disposition_reason` did NOT reproduce it, and neither did anything
  here — no load was driven at guerrilla for this build, deliberately.
- The guard changes what a census DOES when the read path fails: it refuses with
  a name instead of printing a smaller board. That is criteria 1 and 2, and it is
  the half that does not need an operator.
