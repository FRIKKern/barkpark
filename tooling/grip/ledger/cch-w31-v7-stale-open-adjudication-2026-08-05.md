# cch wave 31 — V7 stale-open adjudication: re-derivation recipes

Tree of record: `origin/main` **467f7e283**. The primary checkout was **434 commits behind**
at the time of this run (`git rev-list --count HEAD..origin/main` → `434`), so every command
below is written to run in a DETACHED WORKTREE cut from `origin/main`, never in the checkout.

## 0. Build the tree of record

    git worktree add --detach /tmp/wt-main origin/main
    cd /tmp/wt-main/cloud
    export CC=/usr/bin/clang MIX_TEST_PARTITION=v7w31 MIX_ENV=test
    mix deps.get && mix ecto.create && mix ecto.migrate

Migration `20260804123000_drop_producerless_notification_events` MUST appear in the
`ecto.migrate` output. If it does not, the tree is stale and every verdict below is void.

## 1. Elixir notifications suite (the MUST-RUN)

    mix test test/barkpark_cloud/notifications
    # origin/main 467f7e283 → 46 tests, 0 failures
    # primary checkout a31faa52d → 22 tests, 0 failures  (VACUOUS: the tree lacks
    #   deployment_failed_dispatch_test.exs and render_test.exs entirely)

## 2. Console suite + notification census

    cd /tmp/wt-main/cloud/priv/static && node --test __app.test.mjs
    # → 1..826 / pass 826 / fail 0

## 3. Mutation: the notification census can LOSE (re-add a producerless toggle)

    # append ["token_expiring", "API token expiring"] to NOTIF_EVENTS in app.js
    node --test __app.test.mjs
    # → pass 824 / fail 2
    #   not ok 755 - cch-w30-s1: the matrix offers SIX toggles ...
    #   not ok 758 - cch-w30-s1 census ARM (a): every event the console OFFERS has a producer

## 4. Mutation: the deployment_failed dispatch guard can LOSE

    # in cloud/lib/barkpark_cloud/registry.ex collapse the edge guard:
    #   defp maybe_dispatch_deployment_failed("failed", _updated), do: :ok
    # → a clause that dispatches on failed -> failed
    mix test test/barkpark_cloud/notifications/deployment_failed_dispatch_test.exs
    # → 8 tests, 1 failure  (assert_no_email_sent/0 at :202, the re-drive test)

## 5. Ancestry of the three paying commits

    git merge-base --is-ancestor 96a120b71 origin/main   # #9407 deployment_failed dispatch
    git merge-base --is-ancestor 40097d1d2 origin/main   # #9463 chat arm carries its cause
    git merge-base --is-ancestor 9d56c0406 origin/main   # #9517 drop 3 producerless toggles + census

## 6. Ledger census (drafts + criteria-less rows)

    bp task get cloud-console-hardening-epic -o json | python3 -c "
    import sys,json; d=json.load(sys.stdin); ch=d['children']
    op=[c for c in ch if c['lifecycle_status']=='open']
    print('children',len(ch),'open',len(op))
    print('no-criteria open:',[c['doc_id'] for c in op if not (c.get('criteria_progress') or {}).get('total')])
    print('drafts.*:',[c['doc_id'] for c in ch if c['doc_id'].startswith('drafts.')])"
    # 2026-08-05: children 336 · open 88 · no-criteria open = 2
    #   (cch-w24-bl-word-break-alias-has-no-ruling,
    #    cch-w24-bl-account-menu-lines-nowrap-clipped-at-every-width)
    # drafts.* = FOUR, not three: the row names three; drafts.task-c64f2a37d7f97bd8
    #   is a fourth, but BOTH it and its published twin are `cancelled`, so only
    #   three are in the OPEN set.

## 7. The honest arithmetic

−7 is not available. Four rows close with receipts; the three `drafts.*` twins are
DISCARDS worth **ZERO** against standing law 0 (charter D105, D190, D347). Honest
row-shrink against the cch residue: **−4**.
