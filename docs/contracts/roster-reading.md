<!-- doc-tier: agent | canonical-for: roster-reading-contract | budget: 1800tok -->

# Reading a task roster without being lied to

Every trap below was measured live against `guerrilla.barkpark.cloud` on
**2026-08-24** (Trap 5: 2026-09-25). None errors — each returns a plausible answer that is wrong, so the
cost is a confident false report, not a stack trace.

**The one habit:** an empty list is a claim, and the one most likely to be a lie.
Before believing "0 rows", prove you would have seen rows if they existed.

## Which verb answers which question

| Question | Use | Never use |
|---|---|---|
| Who are this epic's children? | `bp task get <epic>` → `.children` | — |
| Who holds it? Its note? | `bp task ls --parent <epic> --all` | `.children` (no `claim`) |
| All tasks matching a field | `GET /v1/tasks?filter[<key>]=…` | — |
| Content fields / projections | `bp doc query task --filter …` | anything expecting `doc_id` |

Two rules for all four: **check the HTTP status before the body**, and **compare every
returned `doc_id` to the id you asked for**. Before reporting a zero, re-run the probe
with a value you know exists.

## Trap 1 — one row, two identities

`bp task get gh-8463` returns a row whose `doc_id` is **`drafts.gh-8463`**. You
asked for one id and got another, with `ok: true` and HTTP 200.

Measured: all 403 draft rows carry the `drafts.` prefix, no published row does, and
the get route resolves **both** spellings to it.

So a roster joined to per-row reads on `doc_id` silently drops every draft: the list
says `drafts.gh-8463`, your key says `gh-8463`, the join yields nothing, no error.
**401 drafts had no published twin, 96 open** — that count drifts; re-measure it.

> **Fix:** compare `doc.doc_id` against the id you requested. If they differ, you
> were served a draft. Normalise with `id.removeprefix("drafts.")` on both sides.

## Trap 2 — the rows key differs per verb

| Verb | Top-level rows key |
|---|---|
| `bp task ls`, `GET /v1/tasks` | `docs` |
| `bp doc query` | `documents` |

Reading `documents` off a tasks response yields `None`, and `or []` turns that into
an empty list — which reads as *"the query worked, there is nothing"*. It inverts the
answer instead of failing.

> **Fix:** never `.get(key, [])` for a list you require. Assert the key, and print the
> top-level key set the first time you touch a new route.

## Trap 3 — three error shapes; `error` appears on only one

| Case | HTTP | Top-level keys |
|---|---|---|
| unknown filter key | 400 | `details`, `message`, `ok`, `reason` |
| unknown route | 404 | `error` |
| unknown task id | 404 | `message`, `ok`, `reason` |

`if d.get("error")` misses two of the three. `if not d.get("ok")` catches all three,
but only because success always carries `ok: true`. **The
only signal that cannot lie is the HTTP status**; `bp` hides it, raw HTTP does not.

The 400 is the honest one: `reason: invalid_filter` plus `details.supported`, naming
every legal key — `kind`, `label`, `lifecycle_status`, `parent`, `parent_id`,
`phase_id`, `type`.

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

> **Fix:** pick one verb per audit and stay in its vocabulary. Mixing them produces
> "0 published rows" against a fully published roster.

## Trap 5 — `.children` has no claim

`.children` is authoritative for *who belongs*: on `dr-backlog-never-started`
(2026-09-25) `child_count` 314 = `len(children)`. Seven keys: `criteria_progress`,
`doc_id`, `execution_class`, `inserted_at`, `lifecycle_status`, `title`,
`updated_at` — `criteria_progress` is **omitted** on a row with no criteria (1 of
314), so read the key union, never `children[0]`.

There is **no `claim` or `assignee`**. Do not fetch per row: `bp task ls --parent
<epic> --all -o json` returns the same 314 with both, plus `content`, in one read
(`criteria_progress` is `null` there, not absent). The screen:
[ledger-notes.md](ledger-notes.md#screening-an-epics-children).

Drafts are excluded from `.children`, `child_count` and the `--parent` read.

## Trap 6 — `count` is the page, `total` is the answer

`count` is the rows in *this page*; `total` is the full match count and appears
**only** with `--count`. Measured at `--limit 1`: `count=1`, `total=7252`. Reading
`count` as the answer reports one task where there are seven thousand. `total` is
approximate under concurrent writes (off by one against a page-through).

## Trap 7 — the claim epoch you read goes stale as you write

`bp task pulse` **increments the claim epoch** — measured 1 → 2 → 3 → 4 across four
pulses. So the obvious loop (claim, pulse while you work, close on the epoch the
*claim* printed) cannot work; it is stale by the time you close.

The refusal:

```
bp: fenced_off
  hint: your claim epoch is stale — most often your own `bp task pulse` bumped it …
```

**Your own heartbeat fenced you.** The hint now names the pulse first; the trap is
unchanged.

> **Fix:** re-read `doc.claim.epoch` before stamping, or carry forward the epoch your
> *most recent* write printed — never the claim's.

## What is NO LONGER true

`GET /v1/tasks?filter[parent_id]=…` **used to be silently ignored**, answering 200
with an unfiltered page. Fixed (2026-08-24): a real parent → 100/100 belong; a
parent that cannot exist → **0 rows**; unfiltered → **7** parents.

The route is now the correct instrument for field-scoped queries; older notes saying
*never source a roster from this route* are stale. `bp task ls` also takes `--parent`
now: an unknown parent → `docs: []`, not an unfiltered page.

## Re-proving this document

Do not trust the numbers above; they age. Each claim has a one-line probe:

```bash
# Trap 1 — asked-for id vs served id
bp task get gh-8463 -o json | python3 -c 'import sys,json;print(json.load(sys.stdin)["doc"]["doc_id"])'
# Trap 2 — the rows key, per verb
bp task ls --limit 1 -o json        | python3 -c 'import sys,json;print(sorted(json.load(sys.stdin)))'
bp doc query task --limit 1 -o json | python3 -c 'import sys,json;print(sorted(json.load(sys.stdin)))'
# Trap 5 — the child key union, then the one-read roster
bp task get <epic> -o json | jq -c '[.children[]|keys[]]|unique'
bp task ls --parent <epic> --all -o json | jq -c '{n:(.docs|length),k:(.docs[0]|keys)}'
```

For Traps 3, 4, 6 and the filter-route check, hit the HTTP API directly with the token
from `~/.config/barkpark/config.json`: `bp` has no raw-request verb, and the status
code is the one thing it will not show you. **Redact by value, not key name** — that
file also holds `cloud_token`, which a filter matching only `"token"` misses.
