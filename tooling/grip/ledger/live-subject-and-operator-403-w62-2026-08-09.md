# Re-derivation recipes — wave 62 verify [live-subject-and-operator-403]

Taken 2026-08-09 ~14:20–14:45Z. Tree pin: `origin/main` @ `839453b70614be46ce84f25cfef0155f9fcbf78c`.
Control plane: `178.105.92.191` (containers: `cloud-control_plane_green-1`, `cloud-db-1`, `cloud-postfix-1`).

## 1. Control-plane census (the wave's only live subject)

    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 "docker exec cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -c \"SELECT count(*) AS total, count(*) FILTER (WHERE update_unavailable_reason IS NOT NULL) AS reasoned, count(*) FILTER (WHERE update_state='unknown' AND update_unavailable_reason IS NULL) AS unknown_null FROM barkparks;\""

Result (run twice, 14:20Z and 14:44Z, identical): `total 8 | reasoned 1 | unknown_null 0`.

## 2. Which row, and who owns it

    # write to /tmp/q.sql, scp, docker cp — shell quoting through ssh+docker+psql eats inline SQL
    SELECT b.id, b.name, b.host, b.update_unavailable_reason, t.slug AS team_slug
    FROM barkparks b LEFT JOIN teams t ON t.id=b.team_id ORDER BY t.slug, b.name;

Subject: `b1259514-9e7f-4e28-81d9-c7c5ddbc1cbd` / Gyldendal / `167.233.194.23` / `identity_refused` / team `yo`.
Team `yo` owner is `frikk@jarl.no` (`SELECT t.slug, u.email, tm.role FROM team_memberships tm JOIN users u ON u.id=tm.user_id JOIN teams t ON t.id=tm.team_id;` — the table is `team_memberships`, NOT `team_members`).
Full row: `suspended=f`, `suspended_reason` empty, `agent_status=offline`, `health_status=unknown`, `unreachable_count=2`, `last_seen_at` NULL.

## 3. PLATFORM_ADMIN_EMAILS on the RUNNING control plane

    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 "docker exec cloud-control_plane_green-1 sh -c 'printenv PLATFORM_ADMIN_EMAILS; echo rc=\$?'"

Result: `rc=1` (variable absent from the process env — not merely empty). `env | grep -ci PLATFORM_ADMIN_EMAILS` → `0`.
Do NOT re-derive with `docker inspect` (compose bare-lists the key; inspect shows the key regardless of whether the host exported it).

## 4. Operator-half 403 at L1, as a PLAIN TEAM OWNER

    TOK=$(python3 -c "import json;print(json.load(open('$HOME/.config/barkpark/config.json'))['cloud_token'])")
    curl -s -w ' HTTP %{http_code}\n' -H "Authorization: Bearer $TOK" https://api.barkpark.cloud/v1/me
    curl -s -w ' HTTP %{http_code}\n' -H "Authorization: Bearer $TOK" https://api.barkpark.cloud/v1/operator/fleet
    curl -s -o /tmp/bps.json -w 'HTTP %{http_code}\n' -H "Authorization: Bearer $TOK" https://api.barkpark.cloud/v1/barkparks

`/v1/me` → `role:"owner"`, `platform_operator:false`, `team_authority.owner:true` (frikk@guerrilla.no, team Guerrilla).
`/v1/operator/fleet` → **HTTP 403** `{"error":"forbidden","scope":"platform","required":"platform_operator"}`.
`/v1/barkparks` → **HTTP 200**, 6 rows (team-scoped).

## 5. The reader gap, measured on the LIVE API (not only by grep)

    python3 -c "import json;d=json.load(open('/tmp/bps.json'));print(sorted(d['barkparks'][0].keys()))"

43 keys. `update_state`, `update_checked_at`, `update_latest_release`, `update_running_release` present;
**`update_unavailable_reason` ABSENT from every row.** Matches the tree:

    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | grep -c 'unavailable_reason'          # 0
    git show origin/main:cloud/priv/static/app.js | grep -c 'update_unavailable_reason'                 # 0
    git show origin/main:cloud/priv/static/app.js | grep -c 'identity_refused'                          # 0
    git show origin/main:cloud/priv/static/app.js | grep -c 'updateRefusalTerminal'                     # 0
    git show origin/main:cloud/priv/static/app.js | sed -n '8359,8364p'                                 # arms: no identity_refused, no suspended
