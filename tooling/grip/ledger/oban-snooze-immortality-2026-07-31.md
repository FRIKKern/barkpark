# Re-derivation recipes — oban-snooze-immortality (platform follow-ups wave, 2026-07-31)

Verifier lane: settle, from the SHIPPED vendored source (not documented semantics), whether
`{:snooze, n}` consumes an attempt. The "immortal loop" claim underpins the error-not-snooze
lever for the board lane (`guerrilla-task-mutate-pool-saturation`). Verdict: CLAIM HOLDS —
snooze increments `max_attempts` by exactly the one attempt the fetch consumed, so a job that
only ever snoozes never reaches `attempt >= max_attempts` and never discards.

| # | Claim | Command |
|---|---|---|
| 1 | Vendored Oban is 2.21.1 on origin/main (not just the worktree) | `git show origin/main:api/mix.lock \| grep '"oban"' \| cut -c1-70` |
| 2 | No Oban Pro / Web / Met — the OSS `Basic` engine is the only Postgres engine in play | `grep -n 'oban_pro\|oban_web\|oban_met' api/mix.lock api/mix.exs` (no output = absent) |
| 3 | No `engine:` override configured, so `Oban.Engines.Basic` is the runtime engine | `grep -rn 'engine:' api/config/*.exs api/lib/barkpark/application.ex` (no Oban hit) |
| 4 | Executor maps `{:snooze, period}` to `state: :snoozed` — never `:failure`/`:exhausted` | `sed -n '160,168p' api/deps/oban/lib/oban/queue/executor.ex` |
| 5 | `:snoozed` acks through `Engine.snooze_job/3`, NOT `discard_job` (which only sees `:discard`/`:exhausted`) | `sed -n '243,260p' api/deps/oban/lib/oban/queue/executor.ex` |
| 6 | **Decisive**: `snooze_job/3` does `inc: [max_attempts: 1]` — the attempt budget is refunded | `sed -n '262,272p' api/deps/oban/lib/oban/engines/basic.ex` |
| 7 | Fetch consumes exactly one attempt (`inc: [attempt: 1]`) gated on `attempt < max_attempts` — so #6 is an exact refund, net-zero | `sed -n '116,124p' api/deps/oban/lib/oban/engines/basic.ex` |
| 8 | Lite + Dolphin engines delegate snooze to Basic (same arithmetic if the engine ever changes) | `grep -n 'defdelegate snooze_job' api/deps/oban/lib/oban/engines/*.ex` |
| 9 | Inline (test) engine also treats snooze as reschedule, never discard | `sed -n '137,139p' api/deps/oban/lib/oban/engines/inline.ex` |
| 10 | Rescue/stager cannot reap a snoozed job: it targets `state == "executing"`; snooze sets `state: "scheduled"` | `sed -n '186,194p' api/deps/oban/lib/oban/engines/basic.ex` |
| 11 | ProjectorWorker declares `max_attempts: 5` and a FLAT `@snooze_seconds 60` (no backoff growth) on origin/main | `git show origin/main:api/lib/barkpark/edge_projector/projector_worker.ex \| sed -n '77p;91p'` |
| 12 | All three ProjectorWorker snooze sites are `rescue` clauses — an exception (incl. DBConnection pool/timeout errors) becomes a snooze, not a failure, so the pool-saturation path is exactly the immortal path | `grep -n -B6 '{:snooze, @snooze_seconds}' api/lib/barkpark/edge_projector/projector_worker.ex` |
| 13 | The rebuild's `{:error, reason}` branch (projector returned an error tuple) DOES consume an attempt — only the raise path is immortal | `sed -n '235,250p' api/lib/barkpark/edge_projector/projector_worker.ex` |
| 14 | Prior art: only the incident task itself covers this ground; no paper rules on snooze arithmetic | `bp search query "oban snooze max_attempts EdgeProjector loop" -o json \| head -c 400` |
