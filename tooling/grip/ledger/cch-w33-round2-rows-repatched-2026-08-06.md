# cch-w33 verify: round-2 rows re-anchored against origin/main — re-derivation recipes

Assignment `round2-rows-repatched`, wave 33 of the Cloud Console hardening epic.
Baseline: `origin/main = 0792d3347ad23243fee431a3eec91b665475acfc` (2026-08-06).

Every row below is a command that re-derives the fact from scratch. Run them
from a worktree pinned at `origin/main`:

    git -C /Volumes/SATECHI/github/barkpark worktree add --detach /tmp/w33v8 origin/main

## Dependency ancestry (all four PASS)

    cd /tmp/w33v8 && for s in 7eec33f68 3ec60597c 92bf67737 bd6cf848f; do \
      printf "%s " $s; git merge-base --is-ancestor $s origin/main && echo ANCESTOR || echo NOT_ANCESTOR; done

  * `7eec33f68` = #9655 chat rail (cch-w32-s1)
  * `3ec60597c` = #9656 withhold funnel (cch-w32-s2)
  * `92bf67737` = #9659 legacy last_error backfill (cch-w32-s5)  ← the s8 safety dep
  * `bd6cf848f` = cch-w31-s1 DeliveryReason

## Green baseline (the MUST RUN)

    cd /tmp/w33v8/cloud && export CC=clang MIX_TEST_PARTITION=w33v8 && mix deps.get \
      && MIX_ENV=test mix ecto.create --quiet && MIX_ENV=test mix ecto.migrate --quiet \
      && mix test test/barkpark_cloud/notifications test/barkpark_cloud/web/router_notifications_test.exs

→ `112 tests, 0 failures` (0.6s).  Router file alone → `21 tests, 0 failures`.

Note: `CC=cc` is WRONG on this host — `cc` is shadowed by a Claude wrapper. Use `clang`.

## The `validate_required` clause nobody re-derived (W2/W6 consent)

    cd /tmp/w33v8/cloud && grep -n "validate_required" lib/barkpark_cloud/notifications/delivery.ex
    # :78  |> validate_required([:recipient, :event])

    cd /tmp/w33v8/cloud && CC=clang MIX_ENV=test mix run --no-start -e \
      'cs = BarkparkCloud.Notifications.Delivery.changeset(%BarkparkCloud.Notifications.Delivery{}, %{team_id: nil, recipient: nil, event: "reap_alert_cap", kind: "alert", status: "suppressed"}); IO.puts("valid? = #{inspect(cs.valid?)}, errors = #{inspect(cs.errors)}")'
    # valid? = false, errors = [recipient: {"can't be blank", [validation: :required]}]

## Anchor drift table — cch-w32-r2-notifications-withhold-branches

`cloud/lib/barkpark_cloud/notifications.ex` (1111 lines on this main).

    cd /tmp/w33v8/cloud && grep -n "rescue\|team_member_emails\|Oban.insert\|:channel_gone\|:no_admins\|record_delivery\|log_chat_delivery\|enqueue_channel\|deliver_chat\|deliver_fleet_digest" lib/barkpark_cloud/notifications.ex

| branch | brief said | actually |
|---|---|---|
| W1 dispatch_event/3 rescue | ~441-443 | 468-473 (Logger.error :472) |
| W2 for recipient <- team_member_emails | ~423 | 453 (def :449) |
| W4 enqueue_channel Oban.insert | ~894 | defp :966, insert :969, error log :981-984; enqueue_chat accounting :940, fan-out log :950-953 |
| W5 deliver_chat {:cancel, :channel_gone} | ~809 | 863 (def :858) |
| W6 deliver_fleet_digest {:ok, :no_admins} | ~355-360 | Logger.info 384-387, tuple :389 |
| dispatch_site_event else -> :ok (CONSENTED) | ~470 | 499-500 (def :495) |
| record_delivery insert-fail Logger.error | ~674 | :704 (defp :674) |
| log_chat_delivery insert-fail Logger.error | ~947 | :1039 (defp :1012) |
| team_member_emails/1 defp | — | :1096 |

**W4's narrative was STALE, not just its line number.** s1 (#9655) already accounts for
the `Oban.insert()` result — `enqueue_channel/4` cases on it and logs, `enqueue_chat/3`
counts failures. The residual defect is that the failure is a LOG and not a ROW. A builder
reading the old sentence would find the accounting already present and close the row done.

Funnel shipped by s2: `cloud/lib/barkpark_cloud/notifications/withhold.ex` —
`record/4` :108/:110, `@status "suppressed"` :55, `@reasons [:reap_alert_cap]` :57,
catch-all returning `0` at :153 (adding a reason means adding it to `@reasons`).

Adjacent already-filed row: `cch-w32-bl-receipt-loss-branches-have-no-trace` (open),
carrying the SAME stale ~:674/~:947 pair.

## Anchor drift table — cch-w31-s8-member-self-scoped-delivery-read

    cd /tmp/w33v8/cloud && ls lib/barkpark_cloud/accounts/auth.ex   # No such file
    cd /tmp/w33v8/cloud && grep -n "def require_user\|defp resolve_team\|gate_role\|def require_team_admin" lib/barkpark_cloud/web/auth.ex
    cd /tmp/w33v8/cloud && grep -n 'get "/v1/notifications/deliveries"' lib/barkpark_cloud/web/router.ex
    cd /tmp/w33v8/cloud && grep -n "notifPageHtml\|notifCanManage\|notifMemberAdminNoticeHtml" priv/static/app.js
    cd /tmp/w33v8/cloud && grep -n "admin-gated" test/barkpark_cloud/web/router_notifications_test.exs

| anchor | brief said | actually |
|---|---|---|
| auth.ex | bare `auth.ex` (reads as accounts/auth.ex) | `cloud/lib/barkpark_cloud/web/auth.ex` — **accounts/auth.ex DOES NOT EXIST** |
| require_user/2 | 48-58 | :48 |
| resolve_team/2 | 122-130 | :122-130 (primary_team fallback :128) |
| gate_role nil-team -> forbidden | :472 | :472 (gate_role defp :466) |
| GET /v1/notifications/deliveries | 4526-4527 | :4569 route, :4570 `Auth.require_team_admin` |
| authz "Reads stay at member" | 19-27 | :25 |
| authz `read: ~w(owner admin member)` | 51-59 | :51 |
| alert fan-out loop | `deliver_event_email/3` :422 | **no such function** — inline in `dispatch_event/3` at :453 |
| raw invite recipient | :235 | :266 |
| log_chat_delivery `recipient: type` | 897-908 | defp :1012, field :1024 |
| notifPageHtml / notifCanManage | 3210 / 3217 | :3313 (early return :3315) / :3321; notice :3304; export :20114 |
| the PIN | :189 | **:189, ALIVE VERBATIM** — `test "is admin-gated — a plain member is 403"`, block 189-196 |
| (team_id, inserted_at) index | asserted | `priv/repo/migrations/20260629120300_create_notification_deliveries.exs:32` |

Do not confuse the pin at :189 with the DIFFERENT `PUT settings` admin-gate test at :162.

## The bp write recipe (patch + publish, both landed)

    bp doc mutate --file mut.json --yes    # {"mutations":[{"patch":{"id":"<slug>","type":"task","set":{"description":"…"}}}]}
    bp doc mutate --file pub.json --yes    # {"mutations":[{"publish":{"id":"<slug>","type":"task"}}]}

Verify the draft twin collapsed (the gate reads PUBLISHED):

    bp doc get task drafts.<slug>          # must 404 not_found
    bp task get <slug> -o json             # doc_id bare, status published

Both rows confirmed: `doc_id` bare, `status: published`, `drafts.*` 404.
