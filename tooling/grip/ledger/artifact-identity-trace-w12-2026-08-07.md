# Artifact-identity trace — deploy-reliability wave 12 (2026-08-07, 08:46–09:05Z)

Every number below is re-derived by the command beside it. Control plane = `cloud-db-1` on
`178.105.92.191` (DB `now()` read `2026-08-07 08:46:19.972973+00`). Serving box = Guerrilla
`157.180.90.121`. SQL is fed from a FILE on stdin, never inlined.

## 1. Identity coverage: 6 of 30,633 rows

    cat > /tmp/q2.sql <<'EOF'
    select count(*) total, count(artifact_sha256) with_sha, count(content_rev) with_rev,
           count(build_id) with_build,
           count(*) filter (where status='live') live,
           count(*) filter (where status='live' and artifact_sha256 is not null) live_with_sha
    from deployments;
    select source, count(*) n, count(artifact_sha256) sha from deployments group by 1;
    EOF
    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 \
      "docker exec -i cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -A -F'|'" < /tmp/q2.sql

`30633|6|30217|30578|10232|4|10209` and `box-build|30627|0` / `prebuilt|6|6`.

## 2. Clock skew — none

    select min(became_live_at - inserted_at), count(*) filter (where became_live_at < inserted_at),
           count(*) from deployments where became_live_at is not null;

`00:00:06.199704|0|10232`. No negative deltas fleet-wide; a range-seek on
`inserted_at >= received_at` drops nothing to skew.

## 3. The one runnable trace — perfect-demo-2, rev `ad034379ff8b`

    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 \
      "docker exec -i cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -A -F'|' -c \
      \"select id,status,build_id,content_rev,artifact_sha256 from deployments \
        where site_id='3fc3f7d4-69ef-4964-a6db-b6592f8397c3' order by inserted_at\""

    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
      'for d in 5fbe78f50ab5693c 3055d4f51804c3ed 0885f06c06e9ab8d; do \
         printf "%s box_mark=%s\n" "$d" \
           "$(cat /opt/barkpark/sites/perfect-demo-2/releases/$d/.bp-prebuilt-sha256)"; done'

Row `artifact_sha256` == box `.bp-prebuilt-sha256`, all 64 hex, on all three staged releases.
Superseded rev `ad034379ff8b` carries FOUR distinct shas across four attempts (`select content_rev,
count(distinct artifact_sha256) from deployments where artifact_sha256 is not null group by 1`
→ `ad034379ff8b|4|4`).

## 4. Promote reachability

    ssh … -c "select name, kind, prebuilt_enabled, github_repo is not null from sites order by kind,name"

Both `prebuilt_enabled` sites are `kind='static'`; the promote route 422s `static`/`node` before
`promotion_attrs/1` is reached (`git show origin/main:cloud/lib/barkpark_cloud/web/router.ex |
sed -n '11306,11319p'`). The only `container` site is jarl-website — `prebuilt_enabled=f`,
`content_rev` 0 of 55.

    select s.name, d.status, count(*) from deployments d join sites s on s.id=d.site_id
    where d.artifact_url is not null group by 1,2;

`jarl-website|live|23` and `jarl-website|failed|3` — all 26.

## 5. Gotcha that cost a false finding

`find /opt/barkpark/sites -maxdepth 3 -name .bp-prebuilt-sha256` returns EMPTY. The marks live at
depth 4 (`sites/<slug>/releases/<build_id>/.bp-prebuilt-sha256`). Use `-maxdepth 4` or the marks
read as absent.
