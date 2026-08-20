# Re-derivation recipe — gyldendal.barkpark.cloud url/custom_host collision is CROSS-TENANT (2026-08-08)

Verdict: NOT a display bug. The FQDN held in team `yo`'s `barkparks.url` is served by
team `Gyldendal`'s box, and the control plane sends `yo`'s decrypted admin bearer to it
every ~15 minutes.

## 1. The three rows (prod control-plane DB)

```sh
ssh -i ~/.ssh/barkpark_indx root@barkpark.cloud \
  "docker exec -i cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -A -F'|'" <<'SQL'
select b.id, b.slug, t.name as team, b.url, b.custom_host, b.host
from barkparks b left join teams t on t.id=b.team_id where b.slug='gyldendal';
SQL
```

Expected: b1259514 (team `yo`, url `https://gyldendal.barkpark.cloud`, host 167.233.194.23,
custom_host NULL) · f5e1392e (team `Gyldendal`, custom_host `gyldendal.barkpark.cloud`,
host 116.203.98.0) · a9863194 (team `Guerrilla`, host 5.75.169.183).

## 2. The FQDN answers from the OTHER team's box

```sh
dig +short gyldendal.barkpark.cloud                     # -> 116.203.98.0
curl -s -m10 -o /dev/null -w "%{http_code} %{remote_ip}\n" https://gyldendal.barkpark.cloud/api/schemas
# -> 200 116.203.98.0   (f5e1392e's host, not b1259514's 167.233.194.23)
```

## 3. The sampler's exact request lands there and is evaluated

```sh
curl -s -m10 -o /dev/null -w "%{http_code} %{remote_ip}\n" \
  -H "Authorization: Bearer FAKE-TOKEN-PROBE" -H "Accept: application/json" \
  https://gyldendal.barkpark.cloud/api/workspaces/default/projects/default/datasets
# -> 401 116.203.98.0
```

Never send the real token by hand — it is already being sent by the platform (step 4).

## 4. Proof the platform makes that call on a 15-minute cadence

```sh
ssh -i ~/.ssh/barkpark_indx root@barkpark.cloud \
  "docker exec -i cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -A -F'|'" <<'SQL'
select barkpark_id, measured_at, envelope#>>'{meters,datasets,unavailable_reason}'
from usage_samples where barkpark_id='b1259514-9e7f-4e28-81d9-c7c5ddbc1cbd'
order by measured_at desc limit 3;
SQL
# -> rows every 15 min, unavailable_reason = "unreachable" (the foreign box 401s yo's token)
```

## 5. Code path (origin/main)

```sh
git show origin/main:cloud/lib/barkpark_cloud/usage.ex          | sed -n '885,913p'  # instance_base_url = bp.url; headers = Bearer <admin token>
git show origin/main:cloud/lib/barkpark_cloud/registry.ex       | sed -n '3136,3195p' # mint_studio_link posts admin token to bp.url
git show origin/main:cloud/lib/barkpark_cloud/registry.ex       | sed -n '5211,5250p' # custom_host_taken? checks custom_host + Site domains, NEVER another row's url
git show origin/main:cloud/lib/barkpark_cloud/workers/usage_sampler_worker.ex        # crontab 7,22,37,52 over every checkable barkpark
```

## 6. Fleet-wide generalisation (exactly one collision today)

```sh
ssh -i ~/.ssh/barkpark_indx root@barkpark.cloud \
  "docker exec -i cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -A -F'|'" <<'SQL'
select a.id, a.team_id, c.id, c.team_id, c.custom_host from barkparks a join barkparks c
  on replace(replace(a.url,'https://',''),'http://','') = c.custom_host where a.id <> c.id;
SQL
# -> 1 row (b1259514 / f5e1392e). No duplicate url values fleet-wide.
```

## 7. Who sees a duplicate slug

```sh
... join team_memberships ... where b.slug='gyldendal';
# frikk@guerrilla.no is a member of BOTH Guerrilla and Gyldendal -> two boxes named "gyldendal"
```
