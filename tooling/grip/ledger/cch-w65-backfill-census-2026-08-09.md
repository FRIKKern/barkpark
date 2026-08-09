# cch-w65 verify — the S2 backfill is ZERO rows, and the "permanent stale stamp" mechanism is wrong

Re-derivation recipes for the backfill census behind
`cch-w64-bl-control-plane-stamps-a-clock-for-three-checks-it-never-made`.

## R1 — prod census: no row sits at any of the three unclocked rungs

    cat > /tmp/backfill.sql <<'SQL'
    SELECT count(*) AS sanity_total FROM barkparks;
    SELECT update_unavailable_reason, count(*) AS rows, count(update_checked_at) AS clocked,
           count(*) FILTER (WHERE host IS NULL OR host = '') AS hostless
    FROM barkparks GROUP BY 1 ORDER BY 2 DESC;
    SQL
    ssh -i ~/.ssh/barkpark_indx root@barkpark.cloud \
      "docker exec -i cloud-db-1 sh -c 'psql -U \$POSTGRES_USER -d \$POSTGRES_DB -f -'" < /tmp/backfill.sql

8 rows total. 7 reason NULL, 1 `identity_refused`. All 8 clocked, 0 hostless.
`no_admin_token` / `decrypt_failed` / `not_live`: **0 rows each**.
Direct pin: `... WHERE update_unavailable_reason IN ('no_admin_token','decrypt_failed','not_live')
AND update_checked_at IS NOT NULL` → **0**. Sweep-excluded rows
(`host IS NULL OR host='' OR suspended`) → **0**.

DB identity confirmed: `docker exec cloud-db-1 sh -c 'echo $POSTGRES_USER/$POSTGRES_DB'`
→ `barkpark_cloud/barkpark_cloud_prod`, the only non-template DB on the box.

## R2 — the rung is selected by `url`, the sweep filters on `host`

    git show origin/main:cloud/lib/barkpark_cloud/registry.ex | sed -n '3864p;3913p'
    git show origin/main:cloud/lib/barkpark_cloud/registry.ex | grep -n "defp checkable_scope" -A 5

`refresh_update_status/1` head guards `%Barkpark{url: url} when is_binary(url) and url != ""`;
the `:not_live` fallthrough (`:3913`) fires on an empty **url**. `checkable_scope/1`
(`:3813-3817`) filters `host` non-empty + `suspended == false`. A host-NULL row therefore
never reaches the worker at all and never receives a `not_live` stamp from it; a row that
DOES take the rung via the sweep has host set and is re-stamped hourly. The only path that
can strand a stamp on a sweep-excluded row is `kick_update_status_refresh/1`
(`router.ex:12769`), fire-and-forget on a health flip.

## R3 — no operator script outside internal/ parses the clock

    grep -rn update_checked_at scripts/ deploy/
    git grep -n "update_checked_at" origin/main -- tooling .github Makefile js web docs api

`scripts/` hits are three static proof transcripts (`pdf-mvp0-journey-proof-transcript.txt`,
`pdf-p1-refire-transcript.txt`) — captured JSON, not parsers. `deploy/` → none.
Outside those: grip ledger prose and one `evidence-corpus.json` string. No executable reader.

## R4 — Go decodes JSON null into a string as a NO-OP (proved, not assumed)

    cd <scratch> && cat > main.go <<'GO'
    package main
    import ("encoding/json";"fmt")
    type B struct{ UpdateCheckedAt string `json:"update_checked_at"` }
    func main(){ var b B; b.UpdateCheckedAt="PRESET"
      json.Unmarshal([]byte(`{"update_checked_at":null}`), &b); fmt.Printf("%q\n", b.UpdateCheckedAt) }
    GO
    go run main.go   # -> "PRESET"

`null` and absent are indistinguishable to `cloudclient.Barkpark.UpdateCheckedAt`
(`internal/cloudclient/client.go:142`, plain `string`); on a fresh struct both yield `""`,
already asserted by the shipped `TestBarkparkToleratesOlderControlPlane`. So `""` breaks
nothing — but `rankedBarkparkRow` (`internal/cli/cloud_status_cmd.go:502+`) pays for
`*bool AutoupdateEnabled` and `*int CommitDistance` with conditional emission precisely so
"the plane said nothing" cannot read as a zero value. A NULL clock lands in the ambiguity
its neighbours are engineered out of. The clock is emitted ONLY at `:519` (`-o json`);
`bp cloud status`'s table never renders it.

## R5 — deleting UPDATE_REFUSAL_UNCLOCKED is a COPY change, not a deletion

    git show origin/main:cloud/priv/static/app.js | grep -n "function lastCheckedText" -A 8

`:8345` (the map) returns the bare sentence; `:8346` (the honest NULL branch that S2 would
make load-bearing) returns `"Not yet tried — " + sentence`. Same three rungs, different
user-visible string.
