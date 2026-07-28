# CP auth tier — can this Mac fire P1? — 2026-07-28 (wave verifier: v-cp-auth-tier)

**VERDICT: YES. The local `cloud_token` clears the `POST /v1/fleet/supports` provision auth
gate.** A bogus-parent probe returned **HTTP 404 `{"error":"not_found"}`** — the
parent-resolve arm, which the deployed route reaches only AFTER auth, team, and name have all
passed. No row was registered and no job was enqueued (the 404 arm precedes both).

Credential class: **user SESSION token**, not a PAT. 43 chars / 32 raw bytes, no `bpc_pat_`
prefix (`accounts.ex` mints PATs as `"bpc_pat_" <> generate_token()`), so
`require_user_or_pat` takes the session branch → `current_abilities: ["root"]`,
`current_token` nil → the route's cond falls to `team_admin?` → `/v1/me` reports
`role: "owner"` on team `Guerrilla` (`506f035e-…`) → pass. The `deploy`-ability arm is never
reached.

**Expiry horizon:** the current session was inserted `2026-07-23T23:31:58Z`;
`UserToken.@default_validity_days = 30` → hard expiry **~2026-08-22T23:31Z**. P1 must fire
inside that window or the token must be re-minted (`bp` login).

**Bonus gate, also cleared:** the provision arm 409s `no_admin_token` if the parent main has
none. `GET /v1/barkparks/b2b81e69-…/credentials` → **HTTP 200** with a 41-char `admin_token`
present (value not recorded — D94), so the Guerrilla parent will NOT trip that 409.

| Claim | Result | Re-derivation command |
|---|---|---|
| 404 precedes register+enqueue on the deployed sha | confirmed | `git show 78209d8e42b5ca26889841eab712b4b324aa8841:cloud/lib/barkpark_cloud/web/router.ex \| sed -n '1838,1990p'` |
| Local token passes auth → 404 not 403 | HTTP 404 `{"error":"not_found"}` | `TOK=$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.config/barkpark/config.json')))['cloud_token'])"); curl -s -w '\nHTTP %{http_code}\n' -X POST https://api.barkpark.cloud/v1/fleet/supports -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' -d '{"name":"authprobe-x","barkpark_id":"00000000-0000-0000-0000-000000000000","mode":"provision"}'` |
| Control: the 404 is not a route miss | HTTP 401 `{"error":"unauthorized"}` | same curl with `-H "Authorization: Bearer notarealtoken"` |
| Control: auth+team pass before validation | HTTP 422 `{"error":"invalid","details":{"name":["can't be blank"]}}` | same authed curl with `"name":""` |
| Credential is a session, role owner | `role: "owner"`, team `Guerrilla` | `curl -s https://api.barkpark.cloud/v1/me -H "Authorization: Bearer $TOK"` |
| Session expiry horizon | inserted `2026-07-23T23:31:58Z`, +30d | `curl -s https://api.barkpark.cloud/v1/account/sessions -H "Authorization: Bearer $TOK"` |
| Parent has an admin token (no 409) | HTTP 200, `admin_token` present | `curl -s -o /tmp/c.json -w 'HTTP %{http_code}\n' https://api.barkpark.cloud/v1/barkparks/b2b81e69-c79c-4eff-b6d7-84507d15b925/credentials -H "Authorization: Bearer $TOK"` (redact before printing) |

**Blast-radius note for P1:** the real fire differs from this probe only in `barkpark_id`. It
returns **202 `{barkpark, job_id}`** and, per `do_fleet_provision_support/3`, registers the
host-nil support row BEFORE enqueueing — so a red job still leaves a live CP row. Plan the
cleanup leg accordingly.
