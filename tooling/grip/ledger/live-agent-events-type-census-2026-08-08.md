# Live agent_events type census — cch wave 51 verifier recipe

Question: does the PRODUCTION control-plane `agent_events` table hold any row of
type `backup`, `tls` or `content`, written by an older deploy?

Answer: NO — and the table can only ever answer for a 14-day window.

## Re-derive

Type census (the assigned command):

    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 'docker exec -i cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -A -F"|" -c "select type, count(*), min(inserted_at), max(inserted_at) from agent_events group by 1 order by 2 desc"'

Per-instance breakdown:

    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 'docker exec -i cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -A -F"|" -c "select type, barkpark_id, count(*), min(inserted_at), max(inserted_at) from agent_events group by 1,2 order by 1, 3 desc"'

Explicit zero-check for the three lying types:

    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 'docker exec -i cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -A -F"|" -c "select type, count(*) from agent_events where type in ('"'"'backup'"'"','"'"'tls'"'"','"'"'content'"'"') group by 1"'

Retention floor age (proves the census window, not the beginning of history):

    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 'docker exec -i cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -A -F"|" -c "select now() as db_now, (select min(inserted_at) from agent_events) as floor, now() - (select min(inserted_at) from agent_events) as age"'

Pruner is real and running:

    git show origin/main:cloud/lib/barkpark_cloud/workers/agent_retention_worker.ex | sed -n '45,62p'
    git show origin/main:cloud/config/config.exs | grep -n AgentRetentionWorker
    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 'docker exec -i cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -A -F"|" -c "select worker, state, count(*), max(completed_at) from oban_jobs where worker like '"'"'%AgentRetention%'"'"' group by 1,2"'

History (no producer ever existed on main — every historical hit is a TEST):

    git log --oneline --all -G'record_event\([^,)]+, *"(backup|tls|content)"'
    git merge-base --is-ancestor <sha> origin/main
    git grep -n -E 'record_event\([^,)]+, *"(backup|tls|content)"' 91af94f36 b020dd8f4 -- cloud/

## Load-bearing numbers (2026-08-08 00:11 UTC)

    type   count  min                          max
    health 79348  2026-07-24 03:30:42.578083   2026-08-08 00:10:38.797241
    space  105    2026-08-07 00:55:20.530135   2026-08-07 23:56:33.812497
    verify 7      2026-07-26 10:01:02.34641    2026-08-06 22:22:20.020606
    status 3      2026-08-06 08:06:00.690849   2026-08-06 08:06:01.151148
    (4 rows)  backup/tls/content: (0 rows)

health is FLEET-WIDE across 5 boxes (21399 / 21352 / 20885 / 12106 / 3606), not
one; 8 distinct barkpark_id appear in the table overall. `space` is ONE box
(b2b81e69), first row 2026-08-07 00:55 — the day after its producer merged.

Retention: `@event_retention_days 14`, TYPE-AGNOSTIC, cron `30 3 * * *`, 7
completed Oban runs, last 2026-08-07 03:30:00. Floor 2026-07-24 03:30:42 is 42
seconds past that run's cutoff — the floor IS the prune, so the census is a
14-day window and cannot speak to older history. It does not need to: any
backup/tls/content row that ever existed is already permanently deleted, so no
stored history can be stranded by removing the renderer.
