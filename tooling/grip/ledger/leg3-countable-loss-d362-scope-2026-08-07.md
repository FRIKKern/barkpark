# Re-derivation recipes — leg 3 (countable zero-recipient loss) vs charter D362

Wave 18 verifier `leg3-countable-loss-design`, 2026-08-07. Every row re-derives from
`origin/main` (the primary checkout was 620 commits behind at the time of writing —
`git rev-list --count HEAD..origin/main` = 620 — so NEVER read these files from the worktree).

## 1. D362's verbatim holding (does it authorize what the code cites it for?)

    git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md \
      | grep -n 'D362' | head

Row 650 is the decision. The load-bearing clause:

    NOT representable: the zero-member team and the no-platform-admins digest —
    there IS no recipient by construction. Those two are NAMED CONSENTED with that
    reason, never given a synthetic recipient

## 2. The code comment that cites it

    git show origin/main:cloud/lib/barkpark_cloud/notifications.ex | sed -n '336,392p'

## 3. The Delivery-row route is FUTILE, not merely forbidden

`fleet_digest` rows carry `team_id: nil`; their only reader is operator-gated.

    git show origin/main:cloud/lib/barkpark_cloud/notifications.ex \
      | grep -n 'list_fleet_deliveries' -A 8
    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex \
      | grep -n 'list_fleet_deliveries' -B 14

## 4. The digest payload carries no deploy data (leg 3 is half a fix)

    git show origin/main:cloud/lib/barkpark_cloud/notifications/digest_email.ex \
      | grep -nE 'deploy|failure|census|live_rate'   # expect: no matches

## 5. The single pin leg 3 must widen deliberately

    grep -rn 'no_admins' cloud/lib cloud/test

## 6. The existing rail that already returns a COUNT for a zero-recipient case

    git show origin/main:cloud/lib/barkpark_cloud/notifications/withhold.ex | sed -n '1,50p;125,200p'
    git show origin/main:cloud/lib/barkpark_cloud/notifications.ex | grep -n 'Withhold'

## 7. Gates (run from the repo, files under test are byte-identical to origin/main —
verify with `git diff --stat HEAD origin/main -- <path>` before trusting a local run)

    cd cloud && CC=clang mix test test/barkpark_cloud/workers/daily_digest_worker_test.exs
    cd cloud && CC=clang mix test test/barkpark_cloud/notifications_platform_admin_env_test.exs

## 8. Prior art for the countable-loss SHAPE (no Delivery row, mutation-proved)

    bp task get dr-w12-s3-zero-delivery-publish-countable
    bp task get dr-w10-bl-digest-email-calls-a-sick-fleet-healthy
