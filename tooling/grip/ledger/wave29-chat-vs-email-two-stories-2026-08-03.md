# Re-derivation recipe — chat-vs-email channel split (CCH wave 29 verifier)

Tree of record: `origin/main` @ `92f91f043`. The primary checkout is at `a31faa52d`
(ahead 48 / behind 402) and does NOT contain
`cloud/test/barkpark_cloud/notifications/deployment_failed_dispatch_test.exs` —
every leg below MUST run in a detached worktree at `origin/main` (charter D321).

## 0. Setup

    git worktree add --detach /tmp/wt29 origin/main
    cd /tmp/wt29/cloud && CC=clang MIX_ENV=test mix deps.get

## 1. Suite baseline (the assignment's MUST RUN, corrected)

The briefed form `cd <repo-root> && CC=clang mix test cloud/test/...` CANNOT run:
there is no root `mix.exs` (only `cloud/mix.exs` and `api/mix.exs`). It exits with
`** (Mix) Could not find a Mix.Project`. Correct form:

    cd /tmp/wt29/cloud && CC=clang MIX_ENV=test mix test test/barkpark_cloud/notifications/
    # => 30 tests, 0 failures   (stale primary checkout gives 22 — do not quote that)

## 2. The side-by-side split (driven output, not source reading)

Write `split.exs` outside the repo, run with `mix run --no-start` (all three
functions under test are pure; no Repo, no Oban, no app boot needed):

    alias BarkparkCloud.Notifications.{EventEmail, EmailSettings, Render}
    email = EventEmail.build(%EmailSettings{}, :deployment_failed,
              %{name: "acme", detail: "exceeded max deploy claim attempts (stale builder lease)"},
              "who@example.com")
    IO.puts(email.text_body)
    IO.inspect(Render.render("deployment_failed",
              %{"name" => "acme", "detail" => "exceeded max deploy claim attempts (stale builder lease)"}))

    cd /tmp/wt29/cloud && CC=clang MIX_ENV=test mix run --no-start /tmp/split.exs

Expected: the email body carries cause + `What the provider reported:` + capture;
`Render.render/2` returns a single sentence with no cause. Same for
`:provision_failed`. `:agent_unreachable` has no `:detail` at either producer.

## 3. Suppression census

    git grep -n 'alerts suppressed' origin/main -- .
    # exactly 2 hits: registry.ex:6682 (the Logger.warning) and its own test assertion.
    git grep -n -i 'suppress' origin/main -- cloud/lib cloud/priv/static/app.js
    # zero hits relating to a dropped ALERT — no event row, no console banner, no API field.
