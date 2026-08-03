# cch w29 — re-derivation recipes: three stale-open person rows (ledger vs bytes)

All measurement at `origin/main` = `92f91f043`. The primary checkout reads
`[ahead 48, behind 402]` and MUST NOT be used to judge these rows.

## 0. Build the measurement tree (deps are borrowed; `mix deps.get` in a fresh
##    worktree fails offline)

    git worktree add --detach /tmp/wt-om origin/main
    cp -R cloud/deps /tmp/wt-om/cloud/deps
    cp -R cloud/_build /tmp/wt-om/cloud/_build

## 1. cch-w27-bl-connection-refused-classified-as-timeout — PARTIALLY PAID

    cd /tmp/wt-om/cloud && CC=clang mix test test/barkpark_cloud/failure_copy_test.exs
    # => 83 tests, 0 failures  (arms + no-retry-advice + idempotence + both-tokens)
    git -C /tmp/wt-om log --oneline -1 -- cloud/lib/barkpark_cloud/failure_copy.ex
    # => 9b4e76d5c … (#9406), ancestor of origin/main

Remainder = criterion 1 only ("every arm judged against the condition it
actually matches"): `failure_copy.ex:475-478` still answers ANY reason
containing `quota` / `server_limit_exceeded` / `resource_unavailable` with
"Hetzner ran out of server capacity for this size" — provider-blind and
resource-blind.

    git show origin/main:cloud/lib/barkpark_cloud/failure_copy.ex | sed -n '473,479p'
    grep -rin quota internal/cli/cloud/azure/ | wc -l      # => 0 (Azure half NOT derivable)

## 2. cch-w27-bl-deployment-failed-toggle-fires-nothing — PARTIALLY PAID

    cd /tmp/wt-om/cloud && CC=clang mix test test/barkpark_cloud/notifications/deployment_failed_dispatch_test.exs
    # => 8 tests, 0 failures

MUTATION (the guard can lose) — collapse the fenced-writer leg to a catch-all:

    perl -0pi -e 's/  defp maybe_dispatch_deployment_failed\("failed", _updated\), do: :ok/  defp maybe_dispatch_deployment_failed(_any, _updated), do: :ok\n  defp __dead("failed", _u), do: :ok/' \
      /tmp/wt-om/cloud/lib/barkpark_cloud/registry.ex
    # re-run => 8 tests, 2 failures  (":87 assert_email_sent" and ":192")
    git -C /tmp/wt-om checkout -- cloud/lib/barkpark_cloud/registry.ex

Remainder = criterion 2 (the OTHER dead toggles). Census over origin/main:

    for ev in provision_succeeded provision_failed deployment_succeeded deployment_failed \
              agent_reachable agent_unreachable subscription_past_due member_invited token_expiring; do
      printf '%-22s ' $ev
      grep -rEn "dispatch[a-z_]*\(([^)]*)?:$ev\b|dispatch[a-z_]*\([^)]*, *:$ev\b" cloud/lib | wc -l
    done
    # token_expiring 0 (default TRUE), member_invited 0 (false), deployment_succeeded 0 (false)

`token_expiring` is the surviving instance of the row's own defect class: a
default-ON toggle with zero producers anywhere in `cloud/lib`.

## 3. cch-w14-bl-site-open-phone-overflow — PARTIALLY PAID (second emit site)

    git show origin/main:cloud/priv/static/app.js | grep -n 'site-open'
    # 7539 / 10105 = "Visit ↗" chips (nowrap is correct)
    # 10099        = FULL URL inside .fleet-url      → paid by W15-S5 (b1c80eda5)
    # 10969        = FULL URL inside .deploy-rail-live → NOT reached by the fix

The W15-S5 remedy is scoped `.fleet-url .site-open` (app.css:1796). The rail's
own rule (app.css:5118) sets `word-break: break-all; min-width: 0` but never
unsets the base `white-space: nowrap` (app.css:1772) — `word-break` is inert
under `nowrap`. Browser proof (real Chrome, app.css from origin/main):

    # 320px container, same anchor text, two containers:
    # .deploy-rail-live → whiteSpace "nowrap", lineBoxes 1, box.scrollWidth 532 (+212 past 320)
    # .fleet-url        → whiteSpace "normal", lineBoxes 3, box.scrollWidth 320 (+0)
    # inside .detail-grid > .detail-main at body width 320:
    # anchor box 254px, anchor scrollWidth 532, document.body.scrollWidth 551

Fixture: `scratchpad/rail-overflow-fixture.html` (markup transcribed verbatim
from `app.js:10958-10975`).
