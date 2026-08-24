<!-- doc-tier: agent | canonical-for: roster-reading-contract | budget: 1800tok -->

# Reading a task roster without being lied to

Every trap below was re-measured live against `guerrilla.barkpark.cloud` on
**2026-08-24**. None of them errors. Each one returns a plausible answer that is
wrong, so the cost is a confident false report, not a stack trace.

**The one habit:** an empty list is a claim, and it is the claim most likely to be
a lie. Before believing "0 rows", prove you would have seen rows if they existed.

## Which verb answers which question

| Question | Use | Never use |
|---|---|---|
| Who are this epic's children? | `bp task get <epic>` → `.children` | — |
| When did it close? Who holds it? | per-row `bp task get <id>` | `.children` (no such fields) |
| All tasks matching a field | `GET /v1/tasks?filter[<key>]=…` | `bp task ls` (has no `--parent`) |
| Content fields / projections | `bp doc query task --filter …` | anything expecting `doc_id` |

## Trap 1 — one row, two identities

`bp task get gh-8463` returns a row whose `doc_id` is **`drafts.gh-8463`**. You
asked for one id and got another, with `ok: true` and HTTP 200.

Measured: 403 of 403 draft rows in `bp task ls --all` carry the `drafts.` prefix;
0 of 7264 published rows do. The get route resolves **both** `gh-8463` and
`drafts.gh-8463` to the same prefixed row.

So a roster joined to per-row reads on `doc_id` silently drops every draft — the
list says `drafts.gh-8463`, your lookup key says `gh-8463`, and the join yields
nothing with no error. There were **401 drafts with no published twin, 96 of them
open**, when this was written; the count drifts, so re-measure rather than cite it.

> **Fix:** compare `doc.doc_id` against the id you requested. If they differ, you
> were served a draft. Normalise with `id.removeprefix("drafts.")` on both sides.

## Trap 2 — the rows key differs per verb

| Verb | Top-level rows key |
|---|---|
| `bp task ls`, `GET /v1/tasks` | `docs` |
| `bp doc query` | `documents` |

Reading `documents` off a tasks response yields `None`, and `or []` turns that into
an empty list — which reads as *"the query worked, there is nothing"*. It inverts
the answer instead of failing.

> **Fix:** never `.get(key, [])` for a list you require. Assert the key is present,
> and print the top-level key set the first time you touch a new route.

## Trap 3 — three error shapes; `error` appears on only one

| Case | HTTP | Top-level keys |
|---|---|---|
| unknown filter key | 400 | `details`, `message`, `ok`, `reason` |
| unknown route | 404 | `error` |
| unknown task id | 404 | `message`, `ok`, `reason` |

A guard written as `if d.get("error")` misses two of the three. `if not d.get("ok")`
catches all three — an absent `ok` is falsy — but only because success responses
always carry `ok: true`. **The only signal that cannot lie is the HTTP status**;
`bp` hides it, raw HTTP does not.

The 400 is the honest one: it carries `reason: invalid_filter` and
`details.supported`, naming every legal key —
`kind`, `label`, `lifecycle_status`, `parent`, `parent_id`, `phase_id`, `type`.
A mistyped filter is refused loudly, never silently ignored.

## Trap 4 — the same row, two field vocabularies

`bp task get` / `bp task ls` and `bp doc query` describe one row in different words:

| | `task get` / `task ls` | `doc query` |
|---|---|---|
| identity | `doc_id` | `_id`, `_publishedId`, `_draft` |
| timestamps | `updated_at`, `inserted_at` | `_updatedAt`, `_createdAt` |
| `status`, `parent_id` | present | **absent** |
| `acceptance_criteria` | under `content` | at top level |

So `row["status"]` on a `doc query` result is `None` even for a published row — not
because it is unpublished, but because that verb does not project the field.

> **Fix:** pick one verb per audit and stay in its vocabulary. Mixing them is what
> produces "0 published rows" against a fully published roster.

## Trap 5 — `.children` is membership-true and timing-blind

`bp task get <epic>` → `.children` is authoritative for *who belongs* (`child_count`
equalled `len(children)`, 280 = 280, when measured). Each child carries exactly six
keys: `criteria_progress`, `doc_id`, `execution_class`, `inserted_at`,
`lifecycle_status`, `title`.

There is **no `updated_at`, no `closed_at`, no `claim`**. Any audit asking *when did
this close* or *who holds it* must fetch each child individually. Inferring close
time from `.children` is a vacuous green — the field was never there to disagree.

Draft rows are excluded from **both** `.children` and `child_count`, so a roster
built from `.children` is a roster of published children only.

## Trap 6 — `count` is the page, `total` is the answer

`count` is the number of rows in *this page*. `total` is the full match count and
appears **only** when you pass `--count`. Measured with `--limit 1`: `count=1`,
`total=7252`. Reading `count` as the answer reports one task where there are
seven thousand.

`total` and a full page-through disagreed by one under concurrent writes — treat it
as a live approximation, not a fixed number.

## What is NO LONGER true

`GET /v1/tasks?filter[parent_id]=…` **used to be silently ignored**, answering 200
with an unfiltered page. That is fixed. Re-measured 2026-08-24:

- a real parent → 15/15 and 100/100 rows belong, one distinct `parent_id`
- a parent id that cannot exist → **0 rows**
- the same page unfiltered → 15 rows spanning **7** parents

The filter route is now the correct instrument for field-scoped queries. Older
notes saying *never source a roster from this route* are stale, and following them
pushes you onto `bp task ls`, which cannot scope by parent at all.

## The safe recipe

1. Membership → `bp task get <epic>` → `.children`.
2. Anything time-, claim-, or evidence-shaped → per-row `bp task get <id>`.
3. Field-scoped queries → `GET /v1/tasks?filter[<key>]=…`, keys per Trap 3.
4. Check HTTP status first, then `ok`, then the rows key by name.
5. Compare every returned `doc_id` to the id you asked for.
6. Before reporting a zero, run the same probe with a value you know exists.

## Re-proving this document

Do not trust the numbers above; they age. Each claim has a one-line probe:

```bash
# Trap 1 — asked-for id vs served id
bp task get gh-8463 -o json | python3 -c 'import sys,json;print(json.load(sys.stdin)["doc"]["doc_id"])'
# Trap 2 — the rows key, per verb
bp task ls --limit 1 -o json      | python3 -c 'import sys,json;print(sorted(json.load(sys.stdin)))'
bp doc query task --limit 1 -o json | python3 -c 'import sys,json;print(sorted(json.load(sys.stdin)))'
# Trap 5 — the child key set
bp task get cch-instruments-epic -o json | python3 -c 'import sys,json;print(sorted(json.load(sys.stdin)["children"][0]))'
```

For Traps 3, 4 and 6, and the filter-route check, hit the HTTP API directly with the
token from `~/.config/barkpark/config.json` — `bp` has no raw-request verb, and the
status code is the one thing it will not show you.
