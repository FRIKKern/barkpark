# pds-bl-large-task-write-500 — RE-MEASURED LIVE, the ~5 KB size cap does not exist (cli-r4-w11, 2026-09-10)

Verdict: **the filing's central premise is REFUTED.** There is no ~5 KB ceiling on a task
description, and payload size does not drive the 4–13 s latency. Both symptoms are real; the
variable the filing named is the wrong one. The *actual* variable is **title similarity to the
published corpus**, i.e. the publish dedup wall's candidate scan. A second, far higher and
entropy-dependent ceiling does exist and still returns a bare 500.

Measured against `https://guerrilla.barkpark.cloud`, commit `f997dc3a3`
(includes #17285 `perf(dedup-wall): bound the publish dedup candidate scan with a KNN trgm index
scan`, merged 2026-09-10), `POST /v1/data/mutate/production`, `createOrReplace` of a `type:task`
with `main_tag: ledger`, three trials per size, control writes of 679 B before and after each size.
Every one of the 95 scratch rows was deleted afterwards (88 deletes, 7 never created).

## 1. Size sweep — no ceiling anywhere near 5 KB (11:20:06–11:20:17 UTC)

| description bytes | body bytes | HTTP | t (3 trials) |
|---|---|---|---|
| 679 | 1113 | 200 ×3 | 0.122 / 0.125 / 0.132 s |
| 1 680 | 2116 | 200 ×3 | 0.159 / 0.170 / 0.116 s |
| 2 680 | 3116 | 200 ×3 | 0.113 / 0.122 / 0.244 s |
| 4 180 | 4616 | 200 ×3 | 0.293 / 0.294 / 0.137 s |
| **6 000** | 6436 | **200 ×3** | 0.125 / 0.125 / 0.121 s |
| 9 000 | 9436 | 200 ×3 | 0.151 / 0.193 / 0.179 s |
| 16 000 | 16438 | 200 ×3 | 0.564 / 0.639 / 0.369 s |

6 000 bytes — the filing's own failing case — returned **200 in 0.12 s, three times**. The ten
679 B controls interleaved through the sweep all returned 200 in 0.11–0.50 s, so the sweep was not
run in a quiet window that flattered the large sizes.

## 2. The latency IS real, and it is title-driven, not size-driven

Later in the same session, after ~75 rows sharing the title stem `scratch probe …` had been
published, the identical sweep re-ran an order of magnitude slower **at every size including
679 B** (11:23:24–11:25:18 UTC): 679 B → 9.85 s / 11.55 s; 6 000 B → 9.02 s / 11.89 s;
16 000 B → 10.07 s / 10.72 s. Size is flat; the corpus changed.

Interleaved four-arm control run, 11:28:08–11:28:44 UTC, three rounds, one arm after another so
fleet load hits all arms equally:

| arm | description | title | `content.dedup_bypass` | t (3 rounds) |
|---|---|---|---|---|
| A | 679 B | shares the corpus stem | — | 9.756 / 8.719 / 5.137 s |
| B | 679 B | shares the corpus stem | `true` | 0.322 / 0.344 / 0.104 s |
| C | 679 B | three random tokens | — | 0.206 / 0.422 / 0.127 s |
| D | **16 000 B** | shares the corpus stem | — | 6.231 / 6.009 / 6.822 s |

A vs D: **24× the payload, same latency** → the write path is not superlinear in payload size.
A vs C: same payload, only the title differs → **~30× the latency**.
A vs B: same payload, same title, dedup wall switched off by the documented escape hatch →
**~30× the latency**. B and C are the two independent controls and they agree.

The stage is therefore `Barkpark.Content.DedupWall` — its candidate scan plus scoring, reached from
the publish/authoring wall — and nothing downstream of it. #17285 bounds the scan to
`@candidate_limit` 500 rows READ; what remains is still ~5–10 s per write on a corpus that carries
many near-identical titles, i.e. above the module's own `@query_timeout_ms` 5 000 ms per-scan budget,
which suggests more than one scan per mutation. Attribution beyond "the dedup wall owns it" was not
made: it needs `EXPLAIN ANALYZE` on the box, not black-box timing.

## 3. There IS a hard ceiling, ~140× higher than filed, and it is entropy-dependent

High-entropy descriptions (random 3–9 char tokens, so every word is a distinct lexeme):

| description bytes | HTTP | t |
|---|---|---|
| 524 288 | 200 | 3.21 s |
| 700 000 | 200 | 3.18 s |
| 800 000 | **500 `internal_error`** | 5.21 s (`GNPxuwR8x4pNXm0AADWS`) |
| 900 000 | 500 | 2.80 s (`GNPxvFadSp9GEZEAADbC`) |
| 950 000 | 500 | 2.36 s (`GNPxvRCxWGaScvcAADbS`) |
| 1 000 000 | 500 | 4.93 s (`GNPxva95fKg2yY0AADcS`) |
| 1 048 576 | 500 | 4.12 s (`GNPxtU1msXX6RW8AAC_y`) |
| 4 194 304 | 500 | 9.81 s (`GNPxtnaM9cSWWdsAADDS`) |

**Control that names the mechanism:** the same sizes with a *low-entropy* description (five words
repeated) all return 200 — 800 000 B in 3.96 s, 900 000 B in 4.95 s, 1 000 000 B in 4.90 s, and
**2 000 000 B in 15.22 s**. A 2 MB body succeeds where a 800 KB body fails, so the limit is not on
bytes transferred. It is `documents.search_vector`, a `GENERATED ALWAYS AS (to_tsvector(...)) STORED`
column (`api/priv/repo/migrations/20260526181000_add_documents_search_vector.exs:10`, extended by
`20260614220000_search_vector_fields.exs`), against PostgreSQL's 1 048 575-byte `tsvector` cap. A
high-entropy payload reaches that cap at ~750–800 KB of input; a low-entropy one never does.

It is NOT the body parser: `api/lib/barkpark_web/endpoint.ex:163` sets `length: 100_000_000` and
`:180` already rescues `Plug.Parsers.RequestTooLargeError` into a typed 413.

The resulting `Postgrex.Error` (`program_limit_exceeded`, SQLSTATE 54000) is unrescued in
`api/lib/barkpark_web/controllers/mutate_controller.ex:12` (`mutate/2` — `with` chain, no
`rescue`), so it reaches `RenderErrors` and emits the generic 500 envelope. This is exactly the
shape #17245 named.

**Nothing here hangs for 60 s.** The worst observed latency in ~130 live writes was 15.2 s, on a
deliberate 2 MB body.

## 4. Relationship to `spd-b47-doc-create-500-large-payload`

**Distinct, not a shared root cause.** That row is bisected to 8 900–9 002 bytes of *percent-encoded
evidence* travelling in the **URL query string** of `POST /v1/tasks/<id>/stamp`, failing as an
HTTP/2 stream reset from the proxy on an oversize request line — no Elixir error, no
`internal_error` envelope. This row's ceiling is ~750 KB of *request body*, ~85× larger, on a
different verb, failing as an application 500 from a Postgres generated column. The only thing they
share is that a client-side symptom made both look like flaky networking.

## Not run

No `EXPLAIN ANALYZE` on the prod box, no server-log correlation for the 500 request_ids, no
reproduction of the filed 60 s hang (it did not occur at any size), no test of the `bp task create`
CLI path itself (only the HTTP path the row's own recipe names), and no attribution of the ~10 s
dedup latency to a specific number of scans per mutation.
