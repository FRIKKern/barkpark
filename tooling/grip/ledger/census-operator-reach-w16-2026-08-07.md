# Re-derivation recipes — v3-census-reaches-an-operator (wave 16, 2026-08-07)

Verifier assignment: can a real operator get HTTP 200 from
`GET /v1/operator/deploy-ledger/census` today, and does the instrument reproduce
psql's pinned 08-06 numbers (volume 2205 / failed 866 / deferred 773)?

Answer: NO 200 for any account (D165/D211(d) both still hold, re-derived on the
BLUE slot); the instrument reproduces psql EXACTLY on the live release; and the
population of platform operators is exactly ZERO by construction.

## R1 — the route 403s for the correct (cloud) credential

    CT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.config/barkpark/config.json")))["cloud_token"])')
    curl -s -w '\nHTTP %{http_code}\n' -H "Authorization: Bearer $CT" \
      'https://barkpark.cloud/v1/operator/deploy-ledger/census?from=2026-08-06&to=2026-08-07'

Expect: `{"error":"forbidden","scope":"platform","required":"platform_operator"}` / HTTP 403.

NOTE: the assignment's MUST-RUN used `["token"]`, which is the GUERRILLA CONTENT
token (41 chars) and yields **401**, not 403. The control-plane credential is
`["cloud_token"]` (43 chars). A 401 here is the wrong-key artifact, not the gate.

## R2 — the allowlist is empty on the SERVING container (the cause)

    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 \
      "docker exec cloud-control_plane_blue-1 /app/bin/barkpark_cloud rpc \
       'IO.inspect({:config, Application.get_env(:barkpark_cloud, :platform_admin_emails)}); \
        IO.inspect({:resolved, BarkparkCloud.Notifications.platform_admin_emails()})'"

Expect: `{:config, []}` and `{:resolved, []}`. Cross-check the env var itself:

    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 \
      "grep -E 'PLATFORM_ADMIN|OPERATOR' /opt/barkpark/cloud/.env || echo ABSENT; \
       docker exec cloud-control_plane_blue-1 sh -c 'env | grep -i platform_admin' || echo ABSENT-IN-CONTAINER"

Serving slot is now `cloud-control_plane_blue-1` (D165 measured `_green-1`);
the deploy dir is `/opt/barkpark/cloud`, NOT `/opt/barkpark-cloud`.

## R3 — the instrument, run on the live release, reproduces psql

    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 \
      "docker exec cloud-control_plane_blue-1 /app/bin/barkpark_cloud rpc \
       'f = DateTime.from_naive!(~N[2026-08-06 00:00:00], \"Etc/UTC\"); \
        t = DateTime.from_naive!(~N[2026-08-07 00:00:00], \"Etc/UTC\"); \
        c = BarkparkCloud.DeployLedger.census(f, t, []); \
        IO.puts(\"KEYS: \" <> inspect(Enum.sort(Map.keys(c)))); \
        IO.puts(\"volume=\" <> inspect(c.volume) <> \" failed=\" <> inspect(c.failed) \
          <> \" deferred_total=\" <> inspect(Enum.sum(Enum.map(c.deferred, & &1.count))) \
          <> \" live=\" <> inspect(Map.get(c, :live, :ABSENT)))'"

Expect verbatim:

    KEYS: [:classes, :deferred, :failed, :failure_rate, :min_sample, :not_attempted, :sites, :volume, :window]
    volume=2205 failed=866 deferred_total=773 not_attempted=0 live=:ABSENT sites=7

Ground truth to compare against:

    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 \
      "docker exec cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -At -F'|' \
       -c \"select status,count(*) from deployments where inserted_at >= '2026-08-06 00:00:00' \
            and inserted_at < '2026-08-07 00:00:00' group by 1 order by 1\""

Expect `deferred|773`, `failed|866`, `live|566`. 2205 - 866 - 773 = 566 — the
live cohort is an arithmetic residue of the census, named nowhere in it.

## R4 — the CLI reader exists on origin/main but not in the installed bp

    bp cloud deployments --from 2026-08-06 --to 2026-08-07     # installed binary
    # → {"error":{"code":"usage","message":"unknown cloud command \"deployments\""}}

    git archive origin/main | tar -x -C <scratch>/om
    cd <scratch>/om && CC=/usr/bin/clang CGO_ENABLED=0 go build -o <scratch>/bp-om ./cmd/barkpark
    <scratch>/bp-om cloud deployments --from 2026-08-06 --to 2026-08-07 ; echo RC=$?

Expect RC=3 and the named 403 refusal ("Nothing was read: this is NOT a fleet
with zero failures"). `CC=/usr/bin/clang CGO_ENABLED=0` is required — the shell's
`cc` alias is the Claude wrapper and breaks `runtime/cgo`.

## R5 — THE FLEET IS ONE TEAM, AND THE REACHABLE SESSION OWNS IT

    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 \
      "docker exec cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -At -F'|' \
       -c \"select s.team_id, t.slug, count(*) from deployments d join sites s on s.id=d.site_id \
            join teams t on t.id=s.team_id group by 1,2 order by 3 desc\"; \
       docker exec cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -At -F'|' \
       -c \"select t.slug, count(s.id) from teams t left join sites s on s.team_id=t.id group by 1 order by 2 desc limit 5\""

Expect a SINGLE row `506f035e-…|guerrilla|31070` and exactly one team with any
sites (`guerrilla|13`, 26 others at 0). Then:

    CT=…; curl -s -H "Authorization: Bearer $CT" https://barkpark.cloud/v1/me

Expect `"team":{"slug":"guerrilla"}`, `"role":"owner"`, `"platform_operator":false`.

CONSEQUENCE: a TEAM-SCOPED census over team `guerrilla` is the SAME POPULATION as
the "fleet" census, to the row, today. `census/3` takes no scoping opt (only
`:site_limit`, deploy_ledger.ex:591), so the change is a `site_ids:`/team filter
plus a session-gated sibling route — no new renderer, and no prod env change.
