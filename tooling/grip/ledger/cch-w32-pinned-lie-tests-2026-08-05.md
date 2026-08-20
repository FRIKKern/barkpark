# cch-w32 — the three "pinned lie" tests: run, baselined, mutation-proved

Verifier lane `pinned-lie-tests`, wave 32 (cloud-console-hardening). Nothing here
is a reading; every line below was produced by a command that is printed with it.

## 0. THE TRAP THAT ALMOST MANUFACTURED A FALSE FINDING

The assignment's MUST-RUN targets the primary checkout. **That checkout is 447
commits BEHIND origin/main and does not contain one of the three files at all.**

```
git -C /Volumes/SATECHI/github/barkpark rev-parse HEAD          # a31faa52d
git -C /Volumes/SATECHI/github/barkpark rev-parse origin/main   # 90b5ec4f5
git -C /Volumes/SATECHI/github/barkpark log --oneline HEAD..origin/main | wc -l   # 447
git -C /Volumes/SATECHI/github/barkpark diff --stat origin/main -- \
  cloud/test/barkpark_cloud/notifications/deployment_failed_dispatch_test.exs
#  ... | 273 ---------  (the whole file is absent locally)
```

Run the mandated command as written and you test a tree that predates the wave.

## 1. THE SECOND TRAP — A SHARED, POLLUTED TEST DATABASE

First run in a fresh origin/main worktree, against the DEFAULT test DB, reported
`43 tests, 1 failure`: dfd:221 died on `Ecto.ConstraintError` /
`deployments_active_site_env_index`. **That index is created by no migration on
origin/main** — it was left in the shared `barkpark_cloud_test` database by some
other branch's run, and `mix ecto.migrate` said "Migrations already up" because
`schema_migrations` was already full.

```
grep -rn "active_site_env_index" --exclude-dir=_build --exclude-dir=deps \
  --exclude-dir=.git .    # zero hits outside the DB
psql -d barkpark_cloud_test -c '\d deployments' | grep UNIQUE
#   -> deployments_active_site_env_index   (site_id, environment)   POLLUTION
psql -d barkpark_cloud_test_w32ver -c '\d deployments' | grep UNIQUE
#   -> deployments_active_site_ref_index   (site_id, git_ref)       PRISTINE
```

**A notification-suite baseline taken on the default test DB is not a baseline.**
Isolate with `MIX_TEST_PARTITION`, and `ecto.drop` before `ecto.create`.

## 2. RE-DERIVATION RECIPE (the whole lane, from nothing)

```bash
WT=/tmp/w32ver
git -C /Volumes/SATECHI/github/barkpark worktree add --detach "$WT" origin/main
cd "$WT/cloud"
export MIX_ENV=test CC=clang MIX_TEST_PARTITION=_w32ver   # CC: `cc` is the Claude wrapper
mix deps.get && mix compile
mix ecto.drop && mix ecto.create && mix ecto.migrate      # drop is load-bearing, see §1
mix test test/barkpark_cloud/notifications/chat_test.exs \
         test/barkpark_cloud/notifications/deployment_failed_dispatch_test.exs \
         test/barkpark_cloud/web/router_notifications_test.exs
#  -> 43 tests, 0 failures
```

## 3. BASELINE — the whole notification family is GREEN on origin/main 90b5ec4f5

One combined run, same env as above: **141 tests, 0 failures.** Per file:

| file | tests | failures |
|---|---|---|
| notifications_test.exs | 28 | 0 |
| notifications/chat_test.exs | 14 | 0 |
| notifications/render_test.exs | 14 | 0 |
| notifications/delivery_reason_test.exs | 10 | 0 |
| notifications/safe_url_test.exs | 10 | 0 |
| notifications/deployment_failed_dispatch_test.exs | 8 | 0 |
| notifications_platform_admin_env_test.exs | 6 | 0 |
| notifications_transactional_delivery_test.exs | 5 | 0 |
| web/router_notifications_test.exs | 21 | 0 |
| web/router_notifications_chat_test.exs | 5 | 0 |
| workers/chat_notification_worker_test.exs | 8 | 0 |
| workers/daily_digest_worker_test.exs | 6 | 0 |
| workers/trial_expiry_worker_test.exs | 6 | 0 |

Nothing was already failing. Any red a builder sees is theirs.

## 4. ALL THREE PINS EXIST, PASS, AND CAN LOSE (mutation, not reading)

Each mutation was applied in the disposable worktree and reverted with
`git checkout --` immediately; `git status --porcelain` empty afterwards.

| pin | mutation | result |
|---|---|---|
| chat_test.exs:193 | delete `defp enqueue_chat(%EmailSettings{alerts_enabled: false}, …), do: :ok` (notifications.ex:879) | REDS — `refute_enqueued` at :203 |
| dfd_test.exs:221 | `if dropped != [] do` → `if false do` (registry.ex:6680) | REDS — `left: ""`, `right: "2 deployment_failed alerts suppressed"` |
| router_notifications_test.exs:189 | `Auth.require_team_admin` → `Auth.require_user` (router.ex:4527) | REDS — **exactly one test**, `left: 200, right: 403` |

The third reproduces charter D349(a)'s claim verbatim, independently.

## 5. THE LANE'S OWN FINDING — the chat pin is HONEST BUT PARTIAL

chat_test:193 drives `dispatch_event/3`, which routes through `enqueue_chat/3`
and its `alerts_enabled: false` clause. `send_test_chat/2` (notifications.ex:786)
calls `enqueue_channel/4` **directly**, skipping that clause. Probe (run outside
the repo, `mix test <abs path>`, 2 tests 0 failures) asserts BOTH halves:

* `dispatch_event` + `alerts_enabled: false` → `refute_enqueued` PASSES.
* `send_test_chat` + `alerts_enabled: false` → **`assert_enqueued` PASSES.**

The button whose only job is to answer "will I be told?" answers yes when the
answer is no. The pin is not wrong; its coverage stops one caller short.

## 6. FIELD NOTES

* `Delivery.@statuses ~w(pending sent failed)` (delivery.ex:19) — `suppressed`
  is not representable today; pin 2's rewrite depends on it.
* `bp search query …` WORKS as of 2026-08-05 (4582 hits). The digest's note that
  it was down for six surveyors is stale — absence readings taken then are
  tool failures, not evidence.
* Charter lines 578 (D349) and 581 (D352) are byte-identical local vs origin
  (`shasum` per line), so those two are quotable at origin authority even though
  the local charter as a whole DIFFERS from origin.
