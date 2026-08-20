# Re-derivation recipe — the gyldendal packet: rows unchanged, floor moved, publish is BLOCKED (2026-08-09)

Verdict, three parts:
1. The three `barkparks` rows read EXACTLY as the 2026-08-08 recipe declares — criterion 3 is satisfiable.
2. D457's frozen floor of **431** is stale: **460** rows now carry a reason (458 `unreachable` + **2→3
   `unauthorized`**). The reason FLIPPED at 2026-08-09 07:37Z — for the first time the foreign box
   ANSWERED, so the credential is now proved DELIVERED, not merely dialled.
3. The corrected packet CANNOT be published as written: the publish wall's E4 dedup gate scores it at
   Jaccard **0.65 / 13 shared** against the still-published wave-25 gate → hard 409 `duplicate_of`.

## 1. The three rows (control plane, 178.105.92.191)

```sh
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 'docker exec -i cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -A -F"|"' <<'SQL'
select b.id, b.slug, t.name as team, b.url, b.custom_host, b.host, (b.admin_token_encrypted is null) as token_null
from barkparks b left join teams t on t.id=b.team_id where b.slug='gyldendal';
select count(*) as collisions from barkparks a join barkparks c
  on replace(replace(a.url,'https://',''),'http://','') = c.custom_host where a.id <> c.id;
SQL
```

Expected (unchanged from 2026-08-08): `b1259514|gyldendal|yo|https://gyldendal.barkpark.cloud||167.233.194.23|f`
· `f5e1392e|gyldendal|Gyldendal|…|gyldendal.barkpark.cloud|116.203.98.0|f` ·
`a9863194|gyldendal|Guerrilla|…||5.75.169.183|f`; collisions = 1. Criterion 3's `count(*)=3` holds, and
`curl -o /dev/null -w '%{http_code}' 'https://barkpark.cloud/v1/tls/ask?domain=gyldendal.barkpark.cloud'`
→ 200.

## 2. The CURRENT floor — and why the column name in D457 is wrong

`unavailable_reason` is NOT a column. It lives at `envelope#>>'{meters,<meter>,unavailable_reason}'`.
A top-level `envelope ? 'unavailable_reason'` probe returns **0** and is a false negative.

```sh
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 'docker exec -i cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -P pager=off -c "SELECT envelope->'"'"'meters'"'"'->'"'"'documents'"'"'->>'"'"'unavailable_reason'"'"' AS reason, count(*), min(measured_at), max(measured_at) FROM usage_samples WHERE barkpark_id::text LIKE '"'"'b1259514%'"'"' GROUP BY 1 ORDER BY 3;"'
```

2026-08-09 ~08:10Z: `(null) 886` (2026-07-26 03:37 → 2026-08-04 11:07) · `unreachable 458`
(2026-08-04 11:22 → 2026-08-09 07:22) · `unauthorized 3` (2026-08-09 07:37 → 08:07). Total rows 1346.

## 3. The word change is the finding

`cloud/lib/barkpark_cloud/usage.ex` `delivered_failure/1` (~:865) — *"None of these is `unreachable`:
the packets arrived."* `401/403 → :unauthorized`. So every `unreachable` row is an ATTEMPT whose
transport failed; the three `unauthorized` rows are the first PROOF the bearer reached and was
evaluated by another tenant's application. Not a fleet event — a 2-hour fleet scan shows exactly one
box in each non-null bucket, all of them b1259514.

## 4. Why `/v1/data/publish` refuses the corrected packet

There is no `/v1/data/publish` route; publish is `POST /v1/data/mutate/:dataset
{"mutations":[{"publish":{"id":…,"type":"task"}}]}` → `Content.Lifecycle.publish_document/4` →
`AuthoringWall.enforce/5` → spine → tag registry → **DedupWall** (`@refuse 0.55`,
`@min_refuse_shared 3`, tokens = title ∪ tag names, len>2, stopwords dropped).

```sh
python3 - <<'EOF'
import re
stop=set("a an the of to for and or in on at by with from is are be this that these those it its as into per via not no yes we our you your they their can will should must add fix use make build run new when then than also each any all one two both only same onto over under out off up down how".split())
tok=lambda t:set(w for w in re.findall(r'[a-z0-9]+',t.lower()) if len(w)>2 and w not in stop)
A=tok("HUMAN GATE: stop the live cross-tenant credential transmission — token FIRST, url SECOND, one transaction deploy-reliability barkpark-cloud incident guards")
B=tok("HUMAN GATE: stop the live cross-tenant credential transmission on b1259514 incident deploy-reliability barkpark-cloud")
print(len(A&B), round(len(A&B)/len(A|B),4))
EOF
# -> 13 0.65   => sim>=0.55 AND shared>=3 => REFUSE (409)
```

The incumbent `dr-w25-hg-gyldendal-operator-stops-the-transmission` is `status=published`, same type,
same dataset — it IS in the candidate set. The draft is not exemption-ledger material (created
2026-08-09), and no published row exists for the corrected id, so this is a birth with the wall fully
armed. Three unblocks, pick one: unpublish/retitle the w25 incumbent, differentiate the corrected
title, or set `content.dedup_bypass: true` (persists on the doc as the trail).

```sh
bp doc get task dr-w25-hg-gyldendal-operator-stops-the-transmission -o json | head -c 200  # status: published
curl -s -H "Authorization: Bearer $TOK" https://guerrilla.barkpark.cloud/v1/data/doc/production/dr-w26-hg-gyldendal-operator-packet-corrected  # -> not_found (no published row)
bp doc get tag guards -o json    # "_draft":false  -> the 4th weighted tag IS registered; E3 passes
```
