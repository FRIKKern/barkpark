# Re-derivation recipe — match-spec SHAPE decides keyed-lookup vs FULL SCAN (rate-limiter CAS)

Verifier assignment `matchspec-scan-trap`, wave `rate-limit-quota-atomicity-wave-2026-08-19`.
Every number below is re-derivable with the commands in this file. Host was under agent-fleet
load; absolute ns are inflated, RATIOS are the finding.

## 0. The code the trap applies to (origin/main, never a worktree)

    git show origin/main:api/lib/barkpark/rate_limiter.ex | sed -n '69,93p'   # check/2 lookup-then-insert
    git show origin/main:api/lib/barkpark/rate_limiter.ex | sed -n '205,212p' # maybe_prune/1
    git grep -n "select_replace" origin/main -- .                             # ZERO hits: no in-tree prior art

## 1. Scan-vs-keyed cost, at the limiter's own ceiling and beyond

    elixir <scratchpad>/ms_scale.exs

Table filled with `{:auth_write, :register, "10.a.b.c"}` rows, limiter's exact ETS options
(`:set, :public, read_concurrency: true, write_concurrency: true`). ns/call, single process:

| rows | lookup+insert (today) | literal-key CAS | `$1`-key+guard CAS | scan/lit |
|---|---|---|---|---|
| 1 000 | 157.5 | 444.0 | 15 805 | 36x |
| 10 000 (`@max_entries`) | 161.0 | 432.0 | 239 425 | 554x |
| 50 000 | 169.0 | 630.0 | 2 480 220 | 3 937x |
| 200 000 | 176.5 | 932.0 | 20 957 640 | 22 487x |

Contended (64 procs x 200 CAS, 10 000 rows, 10 schedulers): literal 218.5 ms, `$1`+guard 2087.8 ms.

## 2. `@max_entries` does NOT cap the table (so 200k is reachable)

`maybe_prune/1` runs ONLY on the empty-bucket branch and deletes only rows older than
`@stale_after_ms`. All-fresh growth is uncapped:

    # inside ms_scale.exs, last block
    size before prune=25000  rows deleted=0  size after=25000

## 3. Body form x key shape matrix

    elixir <scratchpad>/ms_keyshapes.exs

BARE key in the replacement body `[{{key, tok, ms}}]`:
- tuple keys (`{:token, "burst-test"}`, `{:auth_write, class, ip}`, `{:pulse, ip, chan}`,
  `{:bulldocs_form, ip}`) -> **ArgumentError "not a valid match specification"**
- binary keys (`"token:<hash>:<class>:<scope>"`, `"ip:…"`) and bare atoms -> works, 1 replaced

`{:const, key}` inside the constructed tuple, and whole-object `{:const, {key, tok, ms}}`:
-> works for ALL seven shapes.

Corollary: the raise is key-SHAPE dependent, not data dependent, and
`api/test/barkpark/rate_limiter_test.exs` already uses `{:token, _}` tuple keys, so existing
coverage catches the bare-tuple form on the first assertion. It is NOT an uncovered-shape
prod-500 risk. Verify with `:ets.match_spec_compile/1` (raises without touching a table):

    elixir <scratchpad>/ms_ceiling.exs   # section E

## 4. `insert_new` closes the empty-bucket branch; body may not change the key

    first insert_new: true / second insert_new (expect false): false / row untouched by the loser
    D70 body changes the key: {:RAISED, "not a valid match specification"}

## 5. The recommended guard (structural, zero timing)

    elixir <scratchpad>/ms_guard.exs

Expose the spec builder and assert the head's key element is the literal key, never `:"$N"`/`:_`:

    tuple key: keyed?(cas_spec)=true   keyed?(scan_spec)=false
    string key: keyed?(cas_spec)=true  keyed?(scan_spec)=false

Timing is the SECONDARY smoke only, and only because the separation is ~3 500x:
200 literal CAS calls on a 50 000-row table = 0.083 ms; the same 200 scanning calls
extrapolate to 289 ms. A `< 20 ms` bound has 240x headroom over the literal form.

## 6. Honest hot-path cost of the fix and semantics equivalence

    == full check/2 hot-path cost, uncontended, 10_000-row table ==
    today (lookup+insert) : 100.4 ns/call
    CAS  (lookup+replace) : 127.4 ns/call

Scripted 12-step timeline, capacity 5 / refill 1.0/s, today vs CAS: `identical: true`,
final bucket state `{[{:a, 1.0, 5000}], [{:a, 1.0, 5000}]}`.
