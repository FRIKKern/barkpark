# Re-derivation recipe — Tenancy.Auth.authorize/3 run matrix (share-token confinement wave)

Probe file (scratchpad, not committed):
`/Volumes/SATECHI/dev-caches/tmp/claude-code/claude-501/-Volumes-SATECHI-github-barkpark/ba5f66f9-9370-4639-ae79-5f38bb0e7fe1/scratchpad/probe_authorize_matrix_test.exs`

Run:

    cd /Volumes/SATECHI/github/barkpark/api && MIX_ENV=test mix test <probe_path>

Base: origin/main cd75286b72. All rows printed by `IO.puts("PROBE …")`, every call wrapped in try/rescue.

| id | shape | authorize/3 result |
|---|---|---|
| a1 | fixture admin (`Auth.create_token/4`) vs its own workspace (Default `da076f64-9549-4ad3-9fa8-86eba2a6efdc`) | `:ok` — membership_role `"admin"`, workspace_admin? true |
| a2 | same token vs the fresh `tok-ws` the suite mints into | `{:error, :forbidden}` — membership_role nil (also `:read` forbidden) |
| b | share-edit token (`Auth.create_share_token/5`, ws_id non-nil, NO membership) vs its own scope workspace | `{:error, :forbidden}` for :admin/:write/:read; `membership/2` → nil |
| c1 | `%ApiToken{id: nil, workspace_id: nil}` | raises `FunctionClauseError` — "no function clause matching in Barkpark.Tenancy.Auth.membership/2" |
| c2 | `%ApiToken{id: <uuid>, workspace_id: nil}` vs a real ws | `{:error, :forbidden}` |
| c3 | same token, `workspace_id` argument = nil | `{:error, :forbidden}` (catch-all arm) |
| d1–d4 | non-UUID workspace_id / non-UUID principal id / both / empty-string ws id | raises `Ecto.Query.CastError` at `lib/barkpark/tenancy/auth.ex:145` |
| e1 | plain map principal `%{permissions: ["admin"], id: …}` | `{:error, :forbidden}` |
| e2 | nil principal | `{:error, :forbidden}` |
| f | global-admin-perms token added to a FOREIGN ws with role `"member"` | `authorize(:admin)` → `:ok` (bypass); `workspace_admin?/2` → `false` |

Cross-checks (grep on the same base):
- `lib/barkpark_web/router.ex:2099-2112` — `/v1/shares/tokens` sits on `[:api, :require_admin]`; `RequireAdmin` needs the global `"admin"` permission, so a share-edit token can never reach mint/list/revoke.
- `conn.assigns[:api_token]` is a DB-loaded `%ApiToken{}` (require_token.ex:40), so shapes c1/e1 are not reachable from HTTP.
- `Barkpark.Repo.uuid_or_nil/1` (repo.ex:21-28) is the existing remedy for the d-row CastError.
