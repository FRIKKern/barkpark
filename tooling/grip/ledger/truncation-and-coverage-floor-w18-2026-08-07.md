# Re-derivation recipes — W18 verifier: 50-site truncation + coalesced_attempts coverage floor

2026-08-07, origin/main 6d80e8344. Prod control plane: 178.105.92.191, container `cloud-db-1`,
db `barkpark_cloud_prod`.

## R1 — Is the 50-site truncation live? (answer at time of writing: NO, latent 4x)

    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 "docker exec cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -Atc \"select count(distinct site_id) from deployments where inserted_at > now() - interval '24 hours'; select count(distinct site_id) from deployments where inserted_at > now() - interval '7 days'; select count(distinct site_id) from deployments; select count(*) from sites;\""

2026-08-07 19:37Z → `7 / 9 / 12 / 13`. `site_limit` default 50
(`cloud/lib/barkpark_cloud/deploy_ledger.ex:658` census, `:946` delivery) cannot bind while
distinct site_id in ANY window is 12 and `sites` is 13.

Headroom clock:

    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 "docker exec cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -Atc \"select date_trunc('week',inserted_at)::date, count(*) from sites group by 1 order by 1\""

→ `2026-07-13|11`, `2026-07-20|1`, `2026-07-27|1`. ~1 site/week after the seed batch, so 50
distinct is ~37 weeks out. The bug is a HARDENING slice, not a correctness fix.

## R2 — Does the coverage floor have to be a REFUSAL, not a zero? (answer: YES, and harder than assumed)

The migration moduledoc (`cloud/priv/repo/migrations/20260807150000_add_deferral_structure_to_deployments.exs:88-90`)
claims the pre-existing rows stay "NULLABLE … honestly unknown". They do not. Postgres applies a
CONSTANT default to existing rows logically (attmissingval), so every pre-migration row reads 0.

    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 "docker exec cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -Atc \"select count(*) filter (where coalesced_attempts is null), count(*) filter (where coalesced_attempts is not null), count(*) from deployments; select count(distinct coalesced_attempts), min(coalesced_attempts), max(coalesced_attempts) from deployments where inserted_at < timestamp '2026-08-07 10:02:23'\""

→ `0|31254|31254` and `1|0|0`. Zero NULLs. Consequence: **no data-derived coverage test is
possible** — NULL-vs-0 carries no information. The floor must be a code constant keyed on the
migration's applied instant.

The instant itself:

    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 "docker exec cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -Atc \"select version, inserted_at from schema_migrations order by version desc limit 3\""

→ `20260807150000|2026-08-07 10:02:23`.

## R3 — The confident zero, reproduced

    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 "docker exec cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -Atc \"select coalesce(sum(coalesced_attempts),0) from deployments where inserted_at >= timestamp '2026-08-06 00:00:00' and inserted_at < timestamp '2026-08-07 00:00:00'; select count(*) from oban_jobs where worker like '%AutoDeployWorker' and inserted_at >= timestamp '2026-08-06 00:00:00' and inserted_at < timestamp '2026-08-07 00:00:00'; select count(*) from deployments where inserted_at >= timestamp '2026-08-06 00:00:00' and inserted_at < timestamp '2026-08-07 00:00:00'\""

→ `0`, `3768`, `2205`. The window SUM dr-w17-s8 is specified to ship
(acceptance criterion 1: "census/3 emits `coalesced_attempts` as a window SUM BESIDE `volume`")
returns **0** for a day whose Oban-minus-rows gap is **1,563**. That is a fresh silent mis-report.

## R4 — Post-migration reconciliation does NOT close (the digest's "reconciles exactly" is wrong)

    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 "docker exec cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -Atc \"select (select count(*) from oban_jobs where worker like '%AutoDeployWorker' and inserted_at >= timestamp '2026-08-07 10:02:23'), (select count(*) from deployments where inserted_at >= timestamp '2026-08-07 10:02:23'), (select coalesce(sum(coalesced_attempts),0) from deployments where inserted_at >= timestamp '2026-08-07 10:02:23')\""

→ `562|566|6`. Oban jobs (562) are FEWER than deployment rows (566): the Oban-gap estimator goes
negative post-migration because rows also arrive from non-AutoDeployWorker triggers. The estimator
and the counter are not two views of one quantity; only the DAILY, busy-day figures are robust —
which is what dr-w17-s8's own fifth criterion already says.

Also: `oban_jobs` retention floor —

    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 "docker exec cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -Atc \"select min(inserted_at) from oban_jobs\""

→ `2026-07-31 19:38:00`. The cross-check itself only reaches back 7 days.
