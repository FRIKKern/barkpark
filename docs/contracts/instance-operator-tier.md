<!-- doc-tier: agent | canonical-for: instance-operator-tier | budget: 600tok -->
# Instance operator tier (Tier 0)

Owner of the fourth authorization tier that `docs/auth.md` §Hierarchy names and
delegates here. Landed by PR #14990 (`BarkparkWeb.Plugs.RequirePlatformOperator`,
pipeline `:require_platform_operator`); this text is that PR's own contract
statement, kept verbatim so the code and the doc were written by the same hand.

**Tier 0 — instance operator (`RequirePlatformOperator`).** Above the three
tiers above sits a config-backed allowlist for the seven INSTANCE-GLOBAL
routes that have no tenant row to confine them to: `/v1/admin/self-update|
rollback|site-deploy`, `GET /v1/plugins`, `/v1/plugins/settings/:plugin_name`
CRUD, the flat `/v1/secrets` tier, `POST /v1/status/incidents[/:id/resolve]`,
`POST /api/playground`, and `POST /api/workspaces/:slug/import`. They mount
`pipe_through([:api, :require_admin, :require_platform_operator])` — the
`admin` bit stays NECESSARY, the allowlist makes it INSUFFICIENT. Populated
from `BARKPARK_OPERATOR_EMAILS` (comma list, matched against the bearer's
OWNER email: a PAT's `owner_user_id` → user email, or an app token's
`"app:<email>"` label) and `BARKPARK_OPERATOR_TOKEN_IDS` (comma list of
`api_tokens.id`). BOTH unset/blank → the plug is a PASS-THROUGH (legacy: the
`admin` bit alone still opens all seven) and the node logs a boot warning
naming the seven groups; EITHER non-empty → allowlist-only, fail closed, with
a `403 {"code":"forbidden","required":"platform_operator"}`. Workspace-scoped
admin routes (export, workspace delete, blob PUT, the `/w/:ws/…` secrets
twin) are DELIBERATELY not gated by it — they re-bind through
`workspace_admin?/2`, and an instance allowlist there would lock a tenant
admin out of their own workspace. `RequireAdmin` is unchanged and still
answers only "is this bearer an admin SOMEWHERE".

**Operator runbook.** On the instance host set `BARKPARK_OPERATOR_EMAILS` and/or
`BARKPARK_OPERATOR_TOKEN_IDS` in the service env, then restart. Until then the
node keeps legacy behaviour and logs the boot warning — there is no flag day.
The router's `:instance_global` tripwire test enumerates the seven groups and
reds if one leaves the pipeline.
