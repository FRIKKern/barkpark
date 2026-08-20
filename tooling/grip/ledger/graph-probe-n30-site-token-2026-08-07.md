# graph-probe-n30 — /v1/graph with a REAL site deploy token (2026-08-07 00:58–01:03Z)

Re-derivation recipes for the deploy-reliability wave-8 verifier finding `[graph-probe-n30]`.
Everything below was run live against guerrilla (157.180.90.121) and cloud-db-1 (178.105.92.191).

## 0. Get the real site build credential (READ ONLY — no mint)

    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 \
      'docker exec cloud-control_plane_green-1 /app/bin/barkpark_cloud rpc "
         s = BarkparkCloud.Repo.get(BarkparkCloud.Registry.Site, \"31060916-8b2e-40e2-8b5a-3b5c10b0c6c9\")
         {:ok, t} = BarkparkCloud.Registry.reveal_site_read_token(s)
         IO.puts(\"TOKENIS \" <> t)"'

NOTE: the serving CP container is `cloud-control_plane_green-1`, NOT `..._blue-1`.

Confirm the class (must print `{public-read}`):

    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
      "su - postgres -c \"psql -d barkpark_prod -tAc \\\"select label, permissions::text, revoked_at from api_tokens where token_hash = encode(digest('<RAW>','sha256'),'hex')\\\"\""

## 1. The n=30 probe

    for i in $(seq 1 30); do
      curl -s -o /dev/null -m 60 -w "$i %{http_code} %{time_total}\n" \
        -H "Authorization: Bearer $TOK" \
        "https://guerrilla.barkpark.cloud/v1/graph?dataset=production"
    done

Stamp load context BEFORE and AFTER: `ssh … 'uptime; free -m'`.

## 2. Corpus-scope comparison (site token vs admin token)

Fetch both bodies, then count nodes/edges/types per body. Site 1875/964/6 vs admin 1884/967/8.

## 3. DB round-trips per derivation

pg_stat_statements is NOT installed on barkpark_prod (`select extname from pg_extension`
→ plpgsql, pgcrypto, pg_trgm, citext). Use an `xact_commit` delta instead:

    Q='su - postgres -c "psql -d barkpark_prod -tAc \"select xact_commit from pg_stat_database where datname='"'"'barkpark_prod'"'"'\""'
    a=$(ssh … "$Q"); curl … /v1/graph; b=$(ssh … "$Q"); echo $((b-a))

Baseline (no graph call, ~8 s window): +86 … +140.
With exactly one call: +1484 / +1318 / +2332.

## 4. Long-query sample (refutes "slow SQL")

    scp q.sql root@157.180.90.121:/tmp/q.sql
    ssh … 'for i in $(seq 1 8); do su - postgres -c "psql -d barkpark_prod -tAf /tmp/q.sql"; sleep 3; done'

where q.sql selects active backends ordered by `now()-query_start`.
