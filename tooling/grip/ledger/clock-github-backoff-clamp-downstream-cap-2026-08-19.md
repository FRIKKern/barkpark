# github backoff clamp — downstream-cap trace (clock-semantics wave)

Verifier: github-backoff-clamp. All reads via `git show origin/main:<path>`; Oban
semantics read from `api/deps/oban` (the resolved dependency actually compiled).

## Re-derivation

    git show origin/main:api/lib/barkpark/plugins/github/client.ex | sed -n '334,344p'
    git show origin/main:api/lib/barkpark/plugins/github/mirror_job.ex | sed -n '469,472p;759,761p'
    git show origin/main:api/lib/barkpark/plugins/github/mirror_job.ex | sed -n '78,86p'
    git show origin/main:api/lib/barkpark/plugins/github/drain_worker.ex | sed -n '75,76p;102,110p'
    git show origin/main:api/lib/barkpark/webhooks/dispatcher.ex | sed -n '71,77p;956,968p'
    git show origin/main:api/lib/barkpark/plugins/onixedit/bokbasen/client.ex | sed -n '89p;255,262p'
    git show origin/main:api/config/config.exs | sed -n '304,317p'
    grep -rn -A6 'def snooze_job' api/deps/oban/lib/oban/engines/basic.ex
    grep -n 'defguard is_seconds\|defguard is_valid_period' -A6 api/deps/oban/lib/oban/period.ex
    grep -n 'Periodically delete' api/deps/oban/lib/oban/plugins/pruner.ex
    grep -n 'timestamp: :inserted_at' api/deps/oban/lib/oban/job.ex
    git grep -n 'x-ratelimit-reset' origin/main -- api/test api/lib
    cd api && MIX_ENV=test mix test test/barkpark/plugins/github/   # 387 tests, 0 failures

## Verdict rows

| question | answer | evidence |
|---|---|---|
| downstream cap on the snooze? | NO — none anywhere | Oban `snooze_job` does `inc: [max_attempts: 1]`, so a snooze never consumes an attempt; `max_attempts: 5` cannot bound it |
| snooze period upper bound in Oban? | NO | `is_valid_period` accepts any `is_integer and >= 0` |
| Pruner reclaims the parked row? | NO | Pruner deletes `completed`/`cancelled`/`discarded` only; a snoozed job is `scheduled` |
| queue config ceiling? | NO | `github_mirror: 2` is concurrency only |
| unique clause parks the task forever? | NO | `period: 60` with default `timestamp: :inserted_at` — after 60s a fresh job inserts and converges |
| sibling asymmetry | 3-of-4 clamp; the 1 that does not is the only clock reader | dispatcher `min(secs*1000, retry_after_max_ms())` @300_000; bokbasen refuses above @rate_limit_budget_seconds 5; github drain_worker `min(@cap_ms 30_000, ...)` |
| reset branch test coverage | ZERO | `x-ratelimit-reset` appears only in lib, never in api/test |
| caller-influenced timing? | NO — operator/app-env only | `base_url/1` resolves opt → `:github_api_base` → `:api_base` → api.github.com; no request or workspace input |
