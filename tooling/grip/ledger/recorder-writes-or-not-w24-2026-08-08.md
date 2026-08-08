# W24 verify [recorder-writes-or-not] — re-derivation recipes (2026-08-08)

VERDICT: the commit-distance recorder is ALIVE and HONEST on prod. The survey's
"all three columns NULL on all 8 barkparks" was a timing artefact: the BEAM
carrying #10756 started 11:55:08Z, the hourly UpdateStatusWorker cron fires at
:17, so the first post-deploy tick was 12:17:01–12:17:08Z. Every one of the 8
rows now carries a fresh `commit_distance_checked_at`. Slice 2 keeps its shape:
the recorder is honest, only the reader is missing.

## R1 — the eight rows, post-tick

```
ssh -i ~/.ssh/barkpark_indx root@barkpark.cloud "cd /opt/barkpark/cloud && docker compose exec -T db psql -U barkpark_cloud -d barkpark_cloud_prod -c 'select name, commit_distance, commit_ancestry, commit_distance_checked_at, update_checked_at, update_state from barkparks order by name;'"
```

8/8 rows have non-NULL `commit_distance_checked_at` (12:17:01–12:17:08Z).
5/8 carry an integer distance (1 / 2493 / 911 / 252 / 617); the 3 NULL-distance
rows are exactly the 3 rows whose `git_commit` IS NULL (Gyldendal-unknown,
gyldendal, muscle-1) — the contractual `unknown`/NULL rung, never 0. Correct.

## R2 — the lie, still live and now provable side by side

Guerrilla: distance 1, ancestry `behind`, `update_state` = `current`.
Gyldendal(2nd row): distance 2493, ancestry `behind`, `update_state` = `current`.
dooodo 911 / gyl 252 / jarl 617 — all `update_state: current`.
So the truthful column and the lying column now sit in the same row, and only
the lying one reaches a human.

## R3 — egress to api.github.com is PROVEN (by data, not by curl)

`curl` is absent from the control_plane_green image, so probe it the strong way:
compare the recorded distances against the local git graph.

```
for s in 2e38228b0048901b166d915d222cfc47f6f470d6 e221e7dd5f1f6ad78216562d48c5f9c8f6e5dca9 f3ee2984dbd3abd5bf08d9807520f31342a69141 952106581dfddea0be47980516b5c92b07437e7d c80168100e1a8a30e31a80cd0d70c7fbb5482794; do printf "%s " "$s"; git rev-list --count $s..origin/main; done
```

Local counts: 2 / 912 / 253 / 618 / 2494. Recorded: 1 / 911 / 252 / 617 / 2493.
Every one is EXACTLY local−1, because origin/main advanced by exactly one commit
(5deae282, committed 12:21Z) after the 12:17Z sweep. Five independent shas
off-by-the-same-one is not reachable by any failure mode — the unauthenticated
`GET https://api.github.com/repos/FRIKKern/barkpark/compare/<sha>...main` call
succeeded from inside the container. This retires the module's own
"EGRESS ... is UNPROVEN by any test" caveat.

## R4 — no rescue-arm errors, worker healthy

```
ssh -i ~/.ssh/barkpark_indx root@barkpark.cloud "cd /opt/barkpark/cloud && docker compose logs --since 4h control_plane_green 2>&1 | grep -iE 'commit distance failed|UpdateStatusWorker'"
```
→ empty. And 165 completed jobs, zero in any other state, exactly one tick per
hour for the last 6 hours. Note the service is `control_plane_green` (blue/green
slot), NOT `control_plane` — the briefed command names a service that is not
running and returns "service ... is not running", which reads as silence.

## R5 — still zero readers

```
git grep -ln 'commit_distance\|commit_ancestry' origin/main
```
→ 7 files: charter, config/test.exs, registry.ex, registry/barkpark.ex,
update_status_worker.ex, the migration, one test. No serializer, route, CLI or
console. Unchanged.

## R6 — cross-tenant corroboration (free, from R1's sibling query)

```
ssh -i ~/.ssh/barkpark_indx root@barkpark.cloud "cd /opt/barkpark/cloud && docker compose exec -T db psql -U barkpark_cloud -d barkpark_cloud_prod -c \"select name, git_commit, health_status, url, custom_host from barkparks order by name;\""
```
`gyldendal.barkpark.cloud` is held by row "Gyldendal" as its `url` AND by row
"gyldendal" as its `custom_host` — two disjoint partial unique indexes, neither
can see the collision. Confirms the digest's contradiction (3).
