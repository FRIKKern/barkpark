# ttw20 — fetch-path map + NOW/in-flight denominator drift (2026-08-17)

Verifier: fetch-path-and-now-truth (wave 20, task-tui). Re-derivation recipes for
the board's fetch topology and the live counts-vs-listing drift.

## Claim 1 — ONE fetch path, not two

`FetchSnapshot` (fetch.go:45) is a delegating wrapper over `FetchSnapshotFull`
(detail_data.go:55), which issues BOTH GETs concurrently: `/v1/tasks?limit=1000`
(detail_data.go:67) and `/v1/tasks/prime?limit=100` (fetch.go fetchPrime +
primeReadyLimit=100 at fetch.go:54). The TUI wires `fetch: FetchSnapshotFull`
at program.go:232. The "1000 only in comments" reading of fetch.go was correct
ABOUT fetch.go (its only 1000 literals are comments at :19 and :81) and wrong as
a system claim — the executable literal lives in detail_data.go.

    git show origin/main:internal/taskboard/fetch.go | grep -n 'func FetchSnapshot\|limit=1000\|primeReadyLimit ='
    git show origin/main:internal/taskboard/detail_data.go | grep -n 'limit=1000\|func FetchSnapshotFull'
    git show origin/main:internal/taskboard/program.go | grep -n 'fetch:         FetchSnapshotFull'

## Claim 2 — counts and listing disagree BY CONSTRUCTION (server-side)

`/v1/tasks` index applies `Tasks.Query.collapse_twins` (published-wins;
tasks_controller.ex index, query.ex:132). `Tasks.prime`'s `lifecycle_counts`
(prime.ex:81) groups ALL `type == "task"` document rows — NO collapse_twins, NO
drafts handling — so a twinned task counts TWICE (once per row's own lifecycle)
and the buckets can disagree with every listing-derived population. Live on
2026-08-17: prime said `in_progress: 11`, the listing's in_progress filter
returned 10; the drift row was the twin pair
`cch-w62-bl-friendly-throws-on-the-nested-envelope-it-is-handed`
(published lifecycle=done, draft lifecycle=in_progress). query.ex's own
docstring calls collapse_twins "the ONE owner of the count-a-twinned-task-once
law for every task READ path" — lifecycle_counts violates it.

    git show origin/main:api/lib/barkpark/tasks/prime.ex | sed -n '81,92p'
    git show origin/main:api/lib/barkpark/tasks/query.ex | sed -n '102,158p'
    T=<bearer>; curl -s -H "Authorization: Bearer $T" 'https://guerrilla.barkpark.cloud/v1/tasks?lifecycle_status=in_progress&limit=1000' | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["docs"]))'
    curl -s -H "Authorization: Bearer $T" 'https://guerrilla.barkpark.cloud/v1/tasks/prime?limit=1' | python3 -c 'import json,sys; print(json.load(sys.stdin)["counts"])'

## Claim 3 — NOW completeness today, and the provably-complete shape

All 10 live in_progress rows sat at positions 7–22 of the 1000-row
updated_at-desc window (oldest window row 9 days old). The server-side
`lifecycle_status` filter composes WHERE-before-LIMIT (Ecto single query), so
`GET /v1/tasks?lifecycle_status=in_progress&limit=1000` (74 KB live) is a
provably-complete NOW fetch up to 1000 claims.

    curl -s -H "Authorization: Bearer $T" 'https://guerrilla.barkpark.cloud/v1/tasks?limit=1000' -o /tmp/w.json
    curl -s -H "Authorization: Bearer $T" 'https://guerrilla.barkpark.cloud/v1/tasks?lifecycle_status=in_progress&limit=1000' -o /tmp/ip.json
    python3 -c 'import json; w={d["doc_id"] for d in json.load(open("/tmp/w.json"))["docs"]}; ip=[d["doc_id"] for d in json.load(open("/tmp/ip.json"))["docs"]]; print("outside window:", [i for i in ip if i not in w])'
