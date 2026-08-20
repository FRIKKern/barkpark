# cch-w30 — the three producerless notification events: re-derivation recipes (2026-08-04)

Verifier lane `token-expiring-remedy`. Every row below re-derives from `origin/main`
(`49345a98c`), never the primary checkout, which is **behind 421 / ahead 48** and whose
`cloud/lib/barkpark_cloud/registry.ex` does not even contain `maybe_dispatch_deployment_failed`.

## 0. The stale-tree trap (run this FIRST or every number below is wrong)

    git -C /Volumes/SATECHI/github/barkpark rev-list --count HEAD..origin/main   # 421
    git -C /Volumes/SATECHI/github/barkpark worktree add --detach <wt> origin/main
    cd <wt>/cloud && CC=/usr/bin/clang MIX_ENV=test mix compile   # bare `cc` is the Claude wrapper → bcrypt_elixir fails
    CC=/usr/bin/clang mix test test/barkpark_cloud/notifications_test.exs   # 28 tests at origin/main; 26 on the stale checkout

## 1. The producer census (all THREE dispatch helpers)

    git grep -n "dispatch_event(\|dispatch_site_event(\|dispatch_barkpark_event(" origin/main -- cloud/lib

Six events have producers: provision_succeeded/provision_failed/agent_reachable/agent_unreachable
(router `dispatch_barkpark_event`), subscription_past_due (router:5100), deployment_failed
(registry:6667). `trial_expiring` (trial_expiry_worker:127) has a producer but NO column.
`deployment_succeeded`, `member_invited`, `token_expiring` have zero.

    for e in deployment_succeeded member_invited token_expiring; do git grep -n ":$e" origin/main -- cloud/lib; done
    # each returns exactly 2 lines: the email_settings column and the event_email render head

## 2. Two-arm producer probe (the negative is only worth its control)

Probe files (scratchpad, not committed): `orphan_producer_probe_test.exs`, `orphan_verdict_probe_test.exs`.
Run from `<wt>/cloud` with `CC=/usr/bin/clang mix test <path>`.

* ARM 1 — deployment walked to `live` via `transition_deployment_with_site_update/5` with
  `deployment_succeeded` toggled ON → `Repo.all(Delivery) == []`.
* ARM 2 (control) — same harness walked to `failed` → exactly one Delivery row, `event ==
  "deployment_failed"`. Run ARM 2 on the stale checkout and it returns `[]` — that is how the
  stale tree was caught.

## 3. The seam correction

    git show origin/main:cloud/lib/barkpark_cloud/sites/deploy.ex | sed -n '941,960p'   # settle_live → with_site_update
    git grep -n "transition_deployment_with_site_update" origin/main -- cloud/lib       # deploy.ex:950, router.ex:7348
    git show origin/main:cloud/lib/barkpark_cloud/registry/deployment.ex | grep -n "def legal_transition?"
    # `to == from or to in @transitions[from]` → live→live is LEGAL, proved by probe test at L#44

## 4. member_invited already has a transactional twin

    git show origin/main:cloud/lib/barkpark_cloud/notifications/transactional.ex | sed -n '20,40p'
    git grep -n "send_invite_email" origin/main -- cloud/lib/barkpark_cloud/web/router.ex   # :4436 call, :8296 def
    # probe: Notifications.deliver_invite/1 writes Delivery{kind:"transactional", event:"invite"}

## 5. token_expiring recipient rule

    git show origin/main:cloud/lib/barkpark_cloud/notifications.ex | sed -n '405,430p'  # "Recipients are ALWAYS team members"
    git show origin/main:cloud/lib/barkpark_cloud/accounts/user_token.ex | grep -n "belongs_to"  # :user AND :team
    git grep -n 'expires " + fmtTokenDate' origin/main -- cloud/priv/static/app.js       # :3480 — the console ALREADY shows expiry
    # probe: dispatch_event(team, :token_expiring, …) on a 3-member team → 3 Delivery rows
    # probe: EventEmail.build(%EmailSettings{}, :token_expiring, %{name: …}, …).text_body == ""
