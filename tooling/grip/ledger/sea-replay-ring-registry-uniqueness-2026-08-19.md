# Re-derivation recipe — ReplayRing lookup-then-insert is a real RMW, fenced by a proven-airtight unique Registry

Wave: sibling-ets-atomicity-wave-2026-08-19 · verifier lane `replay-ring-registry`
Baseline: origin/main @ d99cb95d0f · Elixir 1.19.5 / OTP 28

## Claim 1 — the RMW is real (the fence is load-bearing on CORRECTNESS, not perf)

    git show origin/main:api/lib/barkpark/plugins/sheets/session/replay_ring.ex | sed -n '76,106p'

`put/3` = `safe_lookup(key)` (`:ets.lookup`) → reject/prepend/take → `safe_insert(key, list)`
(unconditional `:ets.insert`). Exactly #12579's shape.

Behavioural proof that concurrent writers lose entries (32 barrier-released writers, one key,
200 rounds) — scratch script, not committed:

    cd api && CC=/usr/bin/clang MIX_ENV=test mix run <script>
    # writers=32 rounds=200 rounds_with_LOST_UPDATES=200/200 max_lost_in_a_round=13 total_lost=2249

A lost `put` is not cosmetic: the next retry of that `request_id` reads `:miss` and RE-APPLIES a
non-idempotent `insert_rows`.

## Claim 2 — SessionRegistry uniqueness IS airtight (so production has exactly one writer per key)

    git show origin/main:api/lib/barkpark/plugins/sheets/supervisor.ex | grep -n 'keys: :unique'
    git show origin/main:api/lib/barkpark/plugins/sheets/session.ex | sed -n '398,404p;408p;431,446p;515,517p'

Three legs, each run-proven (scratch scripts, Elixir 1.19.5/OTP 28):

1. duplicate start while the registry is healthy → `{:error, {:already_started, #PID<...>}}`;
   `ensure_session/2` funnels that back to the SAME pid.
2. `Registry` LINKS each registrant to its partition process:
   `Process.info(pid, :links)` contains `Elixir.<Reg>.PIDPartition0` → a partition crash KILLS every
   registered session, so "alive but unregistered" (the only overlap window that would admit a second
   writer) cannot occur.
3. killing the partition: `sup alive?=true, p1 alive?=false, lookup=[]` — the old session is gone
   before any replacement can register. Killing the registry supervisor takes the whole subtree down.

## Claim 3 — the moduledoc/state "drift" is a MISNOMER, not a key mismatch

    git show origin/main:api/lib/barkpark/plugins/sheets/session.ex | sed -n '408p;472p;516p'
    git show origin/main:api/lib/barkpark/content/draft_id.ex | sed -n '27,29p'

`key/2` = `{dataset, Content.published_id(slug)}`; `init/1` binds `slug: pubid`; `handle_call` builds
`{state.dataset, state.slug}`. Same tuple. `published_id/1` is `String.replace_prefix("drafts.")` —
idempotent, so the second application at `topic/3` is a no-op too. Only the FIELD NAME lies.

## Baselines (byte-unchanged, green)

    cd api && CC=/usr/bin/clang mix test test/barkpark/plugins/sheets/   # 5 doctests, 309 tests, 0 failures
    cd api && CC=/usr/bin/clang mix test test/barkpark/sheets/           # 13 doctests, 960 tests, 0 failures

Coverage gap for whoever files it: `api/test/barkpark/sheets/session_idempotency_test.exs` has 5 tests,
none concurrent and none exercising a registry restart — the single-writer invariant the SAFE verdict
rests on is untested in-tree.
