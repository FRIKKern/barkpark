# leg2 wire decision — re-derivation recipes (dr wave 18, 2026-08-07)

Verifier `leg2-wire-decision`. Every row re-derives one load-bearing fact from scratch.
Credential used for the live rows: the host's own `cloud_token` from `~/.config/barkpark/config.json`
(team `guerrilla`, a NON-operator token — the operator route 403s it in the same minute).

| Fact | Command |
|---|---|
| D247's actual text (the "per-box join" fence) | `git show origin/main:.claude/workflows/bp-deploy-reliability-charter.md \| grep -n -A 25 '\*\*D247'` |
| `bp cloud status` reads ZERO deploy data on main | `git show origin/main:internal/cli/cloud_status_cmd.go \| grep -ic deploy`  → `0` |
| `cloudclient.Barkpark` carries no deploy field | `git show origin/main:internal/cloudclient/client.go \| sed -n '/^type Barkpark struct/,/^}/p' \| grep -ci deploy` |
| Attention/status tests pass unchanged on main | `CC=clang go test ./internal/cli/ -run 'Attention\|CloudStatus' -v` |
| census `sites[]` is keyed by `site_id` only | `git show origin/main:cloud/lib/barkpark_cloud/deploy_ledger.ex \| grep -n 'defp site_rows' -A 25` |
| the team census route already LOADS full `%Site{}` structs and throws the box key away | `git show origin/main:cloud/lib/barkpark_cloud/web/router.ex \| grep -n 'owned = Enum.map(Registry.list_sites_for_team'` |
| `list_sites_for_team/1` is `Repo.all(Site)` — full structs, incl. `barkpark_id` | `git show origin/main:cloud/lib/barkpark_cloud/registry.ex \| grep -n 'def list_sites_for_team' -A 8` |
| `/v1/sites` serializes `barkpark_id` | `git show origin/main:cloud/lib/barkpark_cloud/web/router.ex \| grep -n 'defp site_json(s, bp)' -A 8` |
| Go `Site` already decodes `BarkparkID` | `git show origin/main:internal/cloudclient/client.go \| sed -n '1094,1098p'` |
| all three routes share ONE gate (`require_user_or_pat` + `read`) | `git show origin/main:cloud/lib/barkpark_cloud/web/router.ex \| grep -n 'Auth.require_user_or_pat(\[\]) \|> Auth.require_ability("read")'` |
| LIVE: team census 200 / operator census 403, same token, same minute | `T=$(python3 -c "import json;print(json.load(open('$HOME/.config/barkpark/config.json'))['cloud_token'])"); curl -s -w '%{http_code}\n' -H "Authorization: Bearer $T" 'https://api.barkpark.cloud/v1/deploy-ledger/census?from=2026-08-06T00:00:00Z&to=2026-08-07T00:00:00Z' -o /dev/null; curl -s -w '%{http_code}\n' -H "Authorization: Bearer $T" 'https://api.barkpark.cloud/v1/operator/deploy-ledger/census?from=2026-08-06T00:00:00Z&to=2026-08-07T00:00:00Z' -o /dev/null` |
| LIVE: the client-side fold attributes 100% of the window to one box | fetch `/v1/deploy-ledger/census?from=…&to=…` + `/v1/sites`, build `site_id → barkpark_id` from `sites[].barkpark_id`, sum census `sites[].volume/failed/deferred` per box; on 2026-08-06→07 it yields `guerrilla {volume 2205, failed 866, deferred 773}` against fleet `volume 2205` |
| LIVE call costs (3 warm samples each) | `for i in 1 2 3; do curl -s -o /dev/null -w '%{time_total}\n' -H "Authorization: Bearer $T" '<url>'; done` → census ~0.12s, sites ~0.28s, barkparks ~0.73s |
| the key-set census floors any new census key must move | `git show origin/main:cloud/test/barkpark_cloud/payload_key_set_census_test.exs \| grep -n '@emitted_floor\|@go_tag_floor'` |
| the installed `bp` is NOT built from origin/main (label any binary output L3) | `bp version` → commit `0789ab90a`; `git merge-base --is-ancestor 0789ab90a origin/main` → non-zero |
