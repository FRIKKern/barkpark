# Re-derivation recipe — unclocked-stamp prod census (cch wave 66, D791 blocker)

Question D791 was blocked on: how many `barkparks` rows on the control plane carry a
non-null `update_checked_at` while `update_unavailable_reason` is one of the three
UNCLOCKED rungs (`no_admin_token` / `decrypt_failed` / `not_live`) — i.e. rows still
carrying the pre-#11487 lie that #11487 stops telling but never un-tells.

## The census (host + creds are the part that cost a surveyor a run)

DB is on the CONTROL PLANE host, not guerrilla. Role is `barkpark_cloud`, DB is
`barkpark_cloud_prod` — NOT `postgres`/`barkpark_cloud` (that combination fails with
`FATAL: role "postgres" does not exist`, which reads like an outage and is not one).

    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 \
      "docker exec cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -Atc \
       \"select coalesce(update_unavailable_reason,'(null)'), \
                count(*) filter (where update_checked_at is not null), \
                count(*) from barkparks group by 1 order by 3 desc\""

Result 2026-08-09 22:53 UTC:

    (null)|7|7
    identity_refused|1|1

Sanity total 8 — the query is NOT silently empty, and the `identity_refused` row proves
the reason column is populated at all. STRANDED = **0**.

## Why 0, and why that does NOT prove the fix un-told anything

Reachability census — the corpus structurally cannot currently produce an unclocked row:

    ... -Atc "select count(*) total, count(*) filter (where admin_token_encrypted is null) no_token,
              count(*) filter (where url is null or url='') no_url,
              count(*) filter (where host is null or host='') no_host,
              count(*) filter (where suspended) susp from barkparks"
    => 8|0|0|0|0

All 8 rows have a token, a url and a host. `no_admin_token` / `decrypt_failed` /
`not_live` have no live producer on this corpus today.

## Before/after #11487 — not yet answerable from data

    git log -1 --format='%H %ad' --date=iso 02ab46d0f8   # 2026-08-10 00:21:35 +0200 = 22:21 UTC
    git merge-base --is-ancestor 02ab46d0f8 45e26115527c875f50769eb7df922b0f97842be8  # deployed sha, YES
    ssh ... "docker inspect -f '{{.Created}}' cloud-control_plane_green-1"  # 2026-08-09T22:26:42Z

Every stamp on prod is `2026-08-09 22:17:0x` — the sweep 4 min BEFORE the fix commit and
9 min before the deploy. The sweep is HOURLY (`UpdateStatusWorker`, oban_jobs confirms
18:17 / 19:17 / 20:17 / 21:17 / 22:17), so at census time NO post-fix sweep had run.
A "second writer outside `persist_update_unknown`" cannot be detected from row data yet;
the first observation window is the 23:17 UTC tick. (And it would not exercise the
unclocked rungs anyway — see reachability above.)

    ssh ... "docker exec cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -c \
      \"select worker,state,attempted_at from oban_jobs where worker like '%UpdateStatus%' order by id desc limit 5\""

## Writers of update_checked_at (code side)

    git grep -n update_checked_at origin/main -- cloud/lib cloud/priv/repo/migrations

Exactly TWO writers, both in `cloud/lib/barkpark_cloud/registry.ex`:
`persist_update_check/2` (:3933, honest clocked mirror) and `update_unknown_attrs/1`
(:3986, `Map.put` on the ELSE branch of the `@unclocked_reasons` guard). Everything else
is a READER (`digest_email.ex:714`, `router.ex:9472`) or a schema declaration
(`registry/barkpark.ex:209,637`). NO migration backfills the column — the two migrations
that mention it only ADD columns, and `20260809040000` explicitly declines a default
("a default of `'instance_error'` would mint a fabricated accusation on six live rows").

## Test coverage — the omit-vs-null discrimination IS pinned

    git show origin/main:cloud/test/barkpark_cloud/registry_update_status_test.exs | sed -n '345,366p'

`"a box that answered honestly and later goes dark KEEPS its historical clock"` sets an
honest clock, drops `url`, refreshes, and asserts `reloaded.update_checked_at ==
honest_clock`. Its own comment names the trap: the three rung tests (:275/:297/:311,
`assert is_nil(...)`) pass under BOTH omit and explicit-nil because a fresh fixture's
clock is NULL to begin with. No test gap here.
