# brief-card headroom — re-derivation recipe (PDS wave 27 verify, 2026-07-31)

Question: how many bytes are actually free under the two brief-card tripwires,
and does the adjudication triple (`disposition`, `disposition_reason`,
`reopen_trigger`) fit?

## 1. Read the printed byte counts (nobody had, since 2026-07-19)

    cd /Volumes/SATECHI/github/barkpark/api && CC=clang MIX_ENV=test \
      mix test test/barkpark_web/controllers/tasks_controller_test.exs 2>&1 \
      | grep -E 'probe:|tests,'

Measured 2026-07-31: realistic **11055 B** / 15360 cap → **4305 B free** (86.1 B/card ×50);
hostile **28640 B** / 30720 cap → **2080 B free** (41.6 B/card ×50). 113 tests, 0 failures.
`.claude/workflows/bp-axi-brief-views-charter.md:98` still quotes 11,005 / 28,594 — stale by 50 B / 46 B.

## 2. Measure the marginal cost from REAL adjudicated rows, not from arithmetic

    cd <scratch> && for o in 0 1000 2000 3000; do \
      bp doc query task --limit 1000 --offset $o -o json > p$o.json; done
    jq -s '[.[].documents[]] | map(select(.disposition != null)) |
      map({d: ((",\"disposition\":" + (.disposition|tojson))|length),
           t: (if .reopen_trigger==null then 0 else ((",\"reopen_trigger\":" + (.reopen_trigger|tojson))|length) end),
           r: (if .disposition_reason==null then 0 else ((",\"disposition_reason\":" + (.disposition_reason|tojson))|length) end)}) |
      {n: length,
       worst50_term: ((map(.d)|sort|reverse|.[0:50])|add),
       worst50_termtrig: ((map(.d+.t)|sort|reverse|.[0:50])|add),
       worst50_full: ((map(.d+.t+.r)|sort|reverse|.[0:50])|add)}' p0.json p1000.json p2000.json p3000.json

Measured over n=214 adjudicated rows: worst-50 term **2419 B**, term+trigger **6983 B**,
full triple **72232 B**. Compare against the 2080 B hostile headroom.

## 3. The structural facts

    git show origin/main:api/lib/barkpark_web/controllers/tasks_controller/params.ex | sed -n '236,290p;328,345p;383,402p'
    git show origin/main:api/lib/barkpark/tasks/stage.ex | grep -n 'limit\|String.slice\|max_'

`brief_truncated?/1` (params.ex:399-401) inspects ONLY `title` and `claim.now.text`.
`stage.ex` applies NO length cap to `reopen_trigger` / `disposition_reason` (only trim/downcase,
and only on the 3-term `disposition` vocabulary).
