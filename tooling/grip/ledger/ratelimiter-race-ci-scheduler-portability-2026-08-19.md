# Re-derivation recipe: the RateLimiter RMW race is NOT scheduler-portable

Verifier `ci-shaped-schedulers`, wave rate-limit-quota-atomicity-wave-2026-08-19, 2026-08-19.

Headline: the verbatim `check/2` body over-admits 20/20 rounds at `+S 4`, 17-18/20 at
`+S 2`, and **0/220 rounds at `+S 1`** — at a single scheduler it admits EXACTLY the
capacity every time. A twin guard that asserts "the unfixed body over-admits" is
therefore permanently red on a 1-vCPU runner; a guard that only asserts "the fixed
limiter admits exactly cap" is VACUOUS there, because the unfixed body passes it too.

One `:erlang.yield()` at the read→write seam of the twin (arithmetic untouched) makes
the demonstration deterministic and total at EVERY scheduler count: all N callers
admitted, 20/20 rounds, at `+S 1`, `+S 2`, `+S 4`.

CAS (`:ets.select_replace/2` pinning the literal tuple just read + `:ets.insert_new/2`
for the empty branch, 16-retry bound) admitted EXACTLY cap with zero over- and zero
under-admission in 400 rounds at `+S 4` and `+S 10` on a host at load average ~32.

## Rerun

    cd /Volumes/SATECHI/dev-caches/tmp/claude-code/claude-501/-Volumes-SATECHI-github-barkpark/ba5f66f9-9370-4639-ae79-5f38bb0e7fe1/scratchpad

    # per-round admitted counts, legacy body, scheduler matrix
    for S in 1 2 3 4; do elixir --erl "+S $S" race4.exs; done

    # legacy vs seam-widened twin vs CAS, same matrix
    for S in 1 2 4; do elixir --erl "+S $S" race7.exs; done

    # CAS retry distribution + exhaustion rate
    for S in 1 4 10; do elixir --erl "+S $S" cas_retries.exs; done

    # CAS over/under-admission, 100 rounds per config
    for S in 4 10; do elixir --erl "+S $S" cas_under.exs; done

    # the same per-round assertion INSIDE ExUnit
    for S in 1 2 4; do elixir --erl "+S $S" exunit_race.exs; done

    # CI has no scheduler flags — the runner's vCPU count decides
    git show origin/main:.github/workflows/elixir.yml | grep -n "ERL_\|max-cases\|runs-on"

## Numbers to inherit

| scheduler | legacy N=500 cap=200 | legacy N=200 cap=50 | legacy N=200 cap=10 | yield-twin | CAS |
|---|---|---|---|---|---|
| +S 1 | 0/100 over (always 200) | 0/100 over | 0/20 over | 20/20 over, all N admitted | exactly cap |
| +S 2 | 91/100 over, max 277 | 79/100 over, max 55 | 8/20 over | 20/20 over, all N admitted | exactly cap |
| +S 3 | 100/100 over, max 498 | — | — | — | — |
| +S 4 | 20/20 over, all 500 admitted | 98/100 over, max 117 | 20/20 over, max 29 | 20/20 over | exactly cap |

CAS retries at N=500/cap=200: mean 0.73-0.84, max 10, 0 exhausted at `+S 4`;
mean ~3.0, 21-31 of 500 exhausted the 16-retry bound at `+S 10` — those callers were
denied, but admitted stayed exactly 200, so no token went unspent.

## Recommendation for the guard

Assert on the seam-widened twin (deterministic everywhere), and report the verbatim
twin's per-round distribution as measured evidence rather than asserting it. If the
verbatim twin is asserted at all, assert over the AGGREGATE of >= 20 rounds at
N=500/cap=200 AND skip loudly when `:erlang.system_info(:schedulers_online) < 2`.
