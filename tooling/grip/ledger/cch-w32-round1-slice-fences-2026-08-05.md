# cch-w32 — round-1 slice fences, re-derived from origin/main (2026-08-05)

Baseline: `origin/main` = `90b5ec4f564cec9e11ba0cf9247fde5566f5fe7b`.
Local `HEAD` = `a31faa52d` (BEHIND main) and the worktree `cloud/priv/static/*`
differs from main by 4612 deletions — **never quote a worktree line number for
this wave**. Every recipe below reads main's bytes.

## Re-derivation recipes

    # app.js is 20,065 lines on main. Both "Email alerts" copies:
    git show origin/main:cloud/priv/static/app.js | grep -n 'Email alerts'
    # -> 3026 (member read-only <dd>), 3043 (admin checkbox label)
    # both inside notifEmailSectionHtml, which spans 3018-3050:
    git show origin/main:cloud/priv/static/app.js | sed -n '3018,3050p'

    # the console event literals (side A of the wave-30 census):
    git show origin/main:cloud/priv/static/app.js | sed -n '2794,2826p'
    # NOTIF_EVENTS 2796-2803 (6 rows); NOTIF_ALWAYS_SEND 2820-2825
    # (test + trial_expiring — trial_expiring ALREADY HAS A ROW)

    # notifications.ex attribute + function map:
    git show origin/main:cloud/lib/barkpark_cloud/notifications.ex \
      | grep -nE '^  defp? |^  @[a-z_]+ '
    # @always_send :59 (test general trial_expiring)
    # @chat_events :67  @chat_default_on :71  @chat_always_send :75
    # dispatch_site_event :465 (else-arm `_ -> :ok` at :470, NOT :468)
    # should_send?/2 :475-477
    # send_test_chat :780-789
    # enqueue_chat false-clause :879 (NOT :878); enqueue_chat/3 :881
    # enqueue_channel :891; the DISCARDED `|> Oban.insert()` is :894 (NOT :891)
    # routed_types :956-961

    # render.ex has NO trial_expiring arm — catch-all at :82 emits :info:
    git show origin/main:cloud/lib/barkpark_cloud/notifications/render.ex \
      | grep -nE 'defp? |"[a-z_]+" ->'

    # the reaper's log-only withhold:
    git show origin/main:cloud/lib/barkpark_cloud/registry.ex | sed -n '6672,6688p'
    # @reap_alert_cap :80; block 6672-6687; Logger.warning 6681-6684 (NOT 6678-6682)

    # router authz truth (refutes hop 5) vs the moduledoc route table:
    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '117,128p'
    for l in 4327 4352 4395 4439 4490 4526; do \
      git show origin/main:cloud/lib/barkpark_cloud/web/router.ex \
        | sed -n "${l},$((l+1))p"; done
    # only GET /settings (:4327) is require_user; the other FIVE are require_team_admin

    # the full tier census (3 lying rows, 41 rows the extractor cannot reach):
    #   python3 over the moduledoc block + `Auth.require_\w+` after each route head
    #   -> LIE: DELETE /v1/github/installation (doc user / guard require_team_admin)
    #   -> LIE: PUT  /v1/notifications/settings
    #   -> LIE: POST /v1/notifications/test

## Running the console suite against MAIN (not the dirty worktree)

    D=$(mktemp -d); git archive origin/main cloud | tar -x -C "$D"
    cd "$D/cloud/priv/static" && node --test __app.test.mjs
    # -> 833 tests, 829 pass, 4 fail; ALL FOUR failures are cross-tree readers
    #    that need internal/ (TUI goldens) and are extraction artefacts, not reds.
    # The wave-30 census arms (tests 758-761) PASS on main.

## The gap the census does NOT cover

`__app.test.mjs` arms (a)/(b) parse `NOTIF_EVENTS` + `NOTIF_ALWAYS_SEND` against
producers walked out of `cloud/lib`. `grep -n 'chat_events' __app.test.mjs`
returns NOTHING — `@chat_events` / `routed_types/3` are uncensused. A third arm
(chat vocabulary vs producers) is new work, not a duplicate.
