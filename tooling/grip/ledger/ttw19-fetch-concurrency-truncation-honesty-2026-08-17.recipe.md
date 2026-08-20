<!-- doc-tier: cold | canonical-for: ttw19-fetch-concurrency-truncation-honesty | budget: 1200tok -->
# ttw19 — fetch-concurrency + truncation-honesty re-derivation

Verifier assignment [fetch-concurrency-and-truncation-honesty], Task-TUI wave 19.
Prove/refute the ~1.8s concurrent-fetch win and the 1000-of-6733 truncation disclosure.

## (a) Concurrent-fetch — code is SEQUENTIAL; win is real but host too loaded to size it

Orchestration is sequential (list THEN prime, no goroutine):

    git show origin/main:internal/taskboard/detail_data.go | sed -n '39,55p'
    # line 40 getJSON("/v1/tasks?limit=1000"); line 48 fetchPrime(c) — serial

No concurrency anywhere in the fetch path:

    grep -rn "go func\|errgroup\|WaitGroup" internal/taskboard/*.go | grep -iv test
    # only spine.go/program.go comments; NONE in fetch/detail_data

Timing (guerrilla, SGR host under swap-thrashing load — 500s appeared mid-run):

    TOKEN=$(python3 -c 'import json;print(json.load(open("$HOME/.config/barkpark/config.json"))["token"])')
    BASE=https://guerrilla.barkpark.cloud
    # per-endpoint (curl -w): both are TTFB/server-compute bound, not transfer bound
    curl -s -o /dev/null -w '%{time_total} %{time_starttransfer} %{size_download}\n' -H "Authorization: Bearer $TOKEN" "$BASE/v1/tasks?limit=1000"
    curl -s -o /dev/null -w '%{time_total} %{time_starttransfer} %{size_download}\n' -H "Authorization: Bearer $TOKEN" "$BASE/v1/tasks/prime?limit=100"

Observed (list=8.32MB, prime=0.77MB):
- list alone: 14.3 / 0.39 / 0.46 / 9.45 / 2.75 s (two 0.4s runs were HTTP 500 DBConnection.ConnectionError, 211 bytes)
- prime alone: 6.33 / 16.78 / 16.13 / 15.02 / 15.93 s
- paired SEQ vs CONC wall (both HTTP 200): 14.1/15.9, 17.8/16.5, 22.7/7.1, 8.9/3.8

Verdict: concurrency HALVES wall time on quieter runs (22.7→7.1, 8.9→3.8) → guerrilla does
process the two in parallel; it does NOT serialize. On thrashing runs (1,2) no win / slight loss
(pool contention). The "~1.8s" figure is NOT reproducible here — the host is so slow the potential
win is ~5-15s, and the absolute numbers are the LOAD not the code (measure-on-a-quiet-host).
Slice is defensible (real, fenced, unimplemented) but its magnitude must be re-measured quiet.

## (b) Truncation honesty — DEFECT: TaskCount is a DEAD honesty hook, "showing N of M" never rendered

Corpus vs clamp (live):

    curl -s -H "Authorization: Bearer $TOKEN" "$BASE/v1/tasks/prime?limit=100" | python3 -c 'import sys,json;c=json.load(sys.stdin)["counts"];print(c,sum(c.values()))'
    # {'blocked':6,'cancelled':335,'considering':167,'done':3273,'in_progress':8,'open':2944} SUM 6733
    curl -s -H "Authorization: Bearer $TOKEN" "$BASE/v1/tasks?limit=1000" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["docs"]))'
    # 1000

The honesty field exists and is populated but is NEVER painted:

    grep -rn "TaskCount" internal/taskboard/*.go | grep -v _test
    # types.go:179 (def) ; board.go:324 TaskCount: len(s.Tasks) ; NO render consumer
    grep -rn 'showing N of M\|"showing"\|of %d\b' internal/taskboard/*.go | grep -v _test
    # ONLY types.go:177 (a comment). No render.go/components.go string.

Charter D40 (line 567) MANDATES it: "Keep the honest `· N stale` and `showing N of M` notes."
The `+` in the survey's "○ 1+ ready" is a DIFFERENT marker — ReadyHeadClamped (prime ready head
hit the 100 clamp), appended in readyCountLabel (render.go:381). It discloses ready-head truncation
ONLY, never the 1000-of-6733 corpus clamp. momentum done=3273/in_flight=8 are honest prime totals,
so a maintainer sees TRUE aggregate counts but a board built from 1000 rows with ZERO disclosure
that 5733 tasks are off-board. Defect = charter-mandated honesty note designed, hooked (TaskCount),
never wired to output. Cheap fenced fix: render "· showing 1000 of 6733" when TaskCount < sum(Counts).
