# Re-derivation recipes — nonadmin-write-mint (jarl flagship wave 1, 2026-07-31)

Verifier lane: settle whether a **non-admin WRITE credential is mintable on jarl today**.
The digest's premise ("everything writes as admin — no author tier exists, no non-admin
write mint path via CLI") is **WRONG on the substance**: `POST /v1/auth/app-tokens` mints a
member-shaped `[read,write]` token, and it was minted, proven to write AND publish against
`https://jarl.barkpark.cloud`, proven rejected by an admin route, and revoked. The premise
is only right about *ergonomics*: the mint is admin-BEARER-gated (you need the admin token
to mint the non-admin one) and there is no `bp` verb for it.

All curl rows need `JARL_TOKEN` = the jarl admin bearer. Load it WITHOUT printing it:

```sh
export JARL_TOKEN=$(python3 -c "import json;c=json.load(open('$HOME/.config/barkpark/config.json'));print([s for s in c['known_servers'] if s['name']=='jarl'][0]['token'])")
```

NOTE: `config.json`'s TOP-LEVEL `token`/`server` point at **guerrilla**, not jarl. Using the
top-level token against jarl yields a misleading `401 unauthorized`. Always select the
`known_servers` entry by name.

| # | Claim | Command |
|---|---|---|
| 1 | The mint route exists and is admin-bearer-gated in the controller (`mint_login_ticket` idiom — a lesser bearer gets a generic 401, never a tier oracle) | `sed -n '810,833p' api/lib/barkpark_web/router.ex` · `sed -n '74,86p' api/lib/barkpark_web/controllers/app_token_controller.ex` |
| 2 | The mintable permission set is a hard allowlist `~w(read write chat)`; `admin` is unmintable by construction | `grep -n '@app_token_permissions' api/lib/barkpark_web/controllers/app_token_controller.ex` |
| 3 | LIVE: a `[read,write]` non-admin token mints — `HTTP 201`, `token` prefix `bpapp_` (49 chars), `permissions:["read","write"]`, `expires_at:null` | `curl -s -X POST https://jarl.barkpark.cloud/v1/auth/app-tokens -H "Authorization: Bearer $JARL_TOKEN" -H 'Content-Type: application/json' -d '{"email":"scaffy@jarl.no","workspace":"default","permissions":["read","write"],"label":"app:scaffy@jarl.no"}'` |
| 4 | LIVE: `admin` in the body is a **422**, not a policy decision | same as row 3 with `-d '{"email":"scaffy@jarl.no","permissions":["admin"]}'` → `permissions must be a non-empty subset of ["read", "write", "chat"]` |
| 5 | LIVE: the minted non-admin token WRITES — `POST /v1/data/mutate/production` create → `operation:"create"`, id `drafts.<id>` | `curl -s -X POST https://jarl.barkpark.cloud/v1/data/mutate/production -H "Authorization: Bearer $APP" -H 'Content-Type: application/json' -d '{"mutations":[{"create":{"_id":"scratch-x","_type":"note","title":"probe"}}]}'` |
| 6 | LIVE: it PATCHES and DELETES too — but `patch`/`delete` REQUIRE `"type"`; omitting it is a bare `400 malformed` with no field named | `sed -n '288,300p' api/lib/barkpark/content/mutations.ex` · patch: `-d '{"mutations":[{"patch":{"id":"drafts.scratch-x","type":"note","set":{"title":"y"}}}]}'` |
| 7 | LIVE: it PUBLISHES — a `publish` mutation with the same token returns `operation:"publish"`, `_draft:false`. Publishing is NOT an admin-tier act | `-d '{"mutations":[{"createOrReplace":{"_id":"scratch-p","_type":"note","title":"t"}},{"publish":{"id":"scratch-p","type":"note"}}]}'` |
| 8 | LIVE: rejected by an admin-only route — `GET /v1/shares` → `403 forbidden` `token lacks required permission` | `curl -s -w '\n%{http_code}\n' https://jarl.barkpark.cloud/v1/shares -H "Authorization: Bearer $APP"` |
| 9 | LIVE: no self-escalation — the minted token cannot use the mint route itself (`401`, the generic no-oracle refusal) | `curl -s -w '\n%{http_code}\n' -X POST https://jarl.barkpark.cloud/v1/auth/app-tokens -H "Authorization: Bearer $APP" -H 'Content-Type: application/json' -d '{"email":"scaffy@jarl.no","permissions":["read","write"]}'` |
| 10 | LIVE: self-revoke works and is fail-closed on WRITE — `DELETE /v1/auth/app-tokens/current` → `{"revoked":true}`, then the same bearer's mutate is `401` and a second self-revoke is `401` | `curl -s -X DELETE https://jarl.barkpark.cloud/v1/auth/app-tokens/current -H "Authorization: Bearer $APP"` then re-run row 5 |
| 11 | A post-revoke **read** still returns 200 — this is NOT a revocation leak: jarl's production reads are anonymous. A garbage bearer and NO bearer both return 200 with real documents | `curl -s -o /dev/null -w '%{http_code}\n' 'https://jarl.barkpark.cloud/v1/data/query/production/paper?limit=1'` (no auth header) |
| 12 | …and yet the share registry is EMPTY and inactive (`{"active":false,"shares":[]}`) — so the public read surface on jarl is NOT share-backed; whatever opens it is elsewhere (unresolved) | `curl -s https://jarl.barkpark.cloud/v1/shares -H "Authorization: Bearer $JARL_TOKEN"` |
| 13 | Anonymous WRITE is closed — no-bearer mutate is `401` | `curl -s -w '\n%{http_code}\n' -X POST https://jarl.barkpark.cloud/v1/data/mutate/production -H 'Content-Type: application/json' -d '{"mutations":[{"create":{"_id":"anon","_type":"note"}}]}'` |
| 14 | REVOCATION GAP: `revoke_app_tokens_for_email/1` matches `label == "app:" <> email` EXACTLY, and a custom `label` in the mint body replaces that default. There is no admin list-or-revoke-by-id route for app tokens. So an app token minted with a custom label is unrevokable unless you still hold the raw string | `sed -n '272,290p' api/lib/barkpark/auth.ex` · `sed -n '306,310p' api/lib/barkpark_web/controllers/app_token_controller.ex` · `grep -n 'AppTokenController, :' api/lib/barkpark_web/router.ex` |
| 15 | …the escape hatch (used here to clean up a stray token): the `email` param is not validated as an email, so passing the custom label's suffix reconstructs the exact label — `{"email":"wave-verify-nonadmin"}` → `{"revoked_count":1}` | `curl -s -X DELETE https://jarl.barkpark.cloud/v1/auth/app-tokens -H "Authorization: Bearer $JARL_TOKEN" -H 'Content-Type: application/json' -d '{"email":"<label-suffix>"}'` |
| 16 | The P5 scoped edit-token grant is a DEAD PATH on jarl: `POST /v1/shares/tokens` requires the scope to already be edit-shared, and jarl's share registry is empty → `422 the scope is not edit-shared` | `curl -s -X POST https://jarl.barkpark.cloud/v1/shares/tokens -H "Authorization: Bearer $JARL_TOKEN" -H 'Content-Type: application/json' -d '{"scope":"default/default/production","surfaces":"docs,media"}'` |
| 17 | P5 mint is itself admin-only (`pipe_through([:api, :require_admin])`) and validates `scope`+`surfaces` before `create_share_token/5` | `sed -n '2014,2027p' api/lib/barkpark_web/router.ex` · `sed -n '100,124p' api/lib/barkpark_web/controllers/share_controller.ex` |
| 18 | A THIRD, genuinely non-admin mint exists but is **session-gated, not bearer-gated**: `POST /v1/auth/tokens` self-mints a PAT hard-bound to `current_user.id` (no escalation). Unreachable from a CLI holding only a bearer — needs a browser/Studio session | `sed -n '1547,1553p' api/lib/barkpark_web/router.ex` |
| 19 | Scoped mutate accepts BOTH a member write-gate and the P5 edit-token grant on the same pipeline | `sed -n '2317,2324p' api/lib/barkpark_web/router.ex` |
| 20 | Flat `/v1/data/query/production?query=…` is NOT a route (GROQ-style querying 404s); the real read shape is typed: `/v1/data/query/:dataset/:type` | `grep -n 'QueryController, :index' api/lib/barkpark_web/router.ex` |

## What Decide has to choose

The reachability obligation does **not** have to be recorded as an unavoidable
"runs as admin" exception — a non-admin `[read,write]` token that can create, patch,
publish and delete on jarl is one `curl` away. But minting one still requires the admin
bearer, so the honest options are:

1. **Scope a mint step into the wave** (one command, plus a revoke at wave end) and run
   every wave write under `bpapp_` — costs ~2 minutes, buys a real premise-smoke pass.
2. **Record "runs as admin" as a deliberate exception** — now evidenced, not an oversight:
   the mint exists, was exercised, and was declined for ergonomics.

Either way, if a token IS minted, use the DEFAULT label (`app:<email>`) so the
`{"email": …}` revoke can kill it (row 14).
