defmodule BarkparkWeb.RequireAdminRouteCensusTest do
  @moduledoc """
  `arpss-w8-require-admin-workspace-blind-program` criteria 0/1/2 (and
  `task-ea8cae3258ea4bd3` criterion 4): THE CENSUS of every route whose only
  *pipeline* authorization is `BarkparkWeb.Plugs.RequireAdmin`, i.e.
  `Auth.has_permission?(token, "admin")` — a flat membership test over
  `token.permissions` that reads no workspace at all.

  `RequireAdmin` answers "is this bearer an admin SOMEWHERE", never "an admin
  OF WHAT". So for every route it gates, SOMETHING ELSE must supply the
  tenancy — or the route is cross-tenant reachable. This module enumerates
  those routes from the router source, cross-checks the enumeration against
  the compiled `BarkparkWeb.Router.__routes__/0`, and holds a per-route
  verdict. An unclassified route (someone added one) and a stale entry
  (someone moved or deleted one) each RED this file.

  ## The two gated pipelines

    * `[:api, :require_admin]` — `pipeline :api` + `RequireToken` +
      `RequireAdmin`.
    * `:flat_admin_api` — the explicit, order-pinned flat admin mount.

  Both mount `Plugs.RequireAdmin` (router.ex, `pipeline :require_admin` and
  `pipeline :flat_admin_api`); a `grep -n RequireAdmin` over
  `api/lib`+`cloud/lib` finds the plug at no third callsite. `:scoped_admin`
  is deliberately OUT of scope: it runs `RequireWorkspaceRole`, which is a
  per-grant role lookup against the resolved workspace, not a global bit.

  ## THE PREMISE THAT DIED, and why it must be re-stated not re-cited

  This program was filed on the claim that `pipeline :api` ran
  `AssignDefaultScope` with NO derivation ahead of it, so
  `conn.assigns.current_workspace` was the seeded Default Workspace for
  EVERY caller on every `[:api, :require_admin]` route, making a
  workspace-B-bound admin and a self-hosted host token indistinguishable
  downstream.

  That stopped being true on 2026-08-24. `8dd6600f99` (#13886) put
  `Plugs.DeriveWorkspaceFromToken` INTO `pipeline :api` itself, AHEAD of
  `AssignDefaultScope` (router.ex `pipeline :api`). `DeriveWorkspaceFromToken`
  is no-op-if-set, so ORDER is the whole fix: `current_workspace` is now the
  TOKEN's workspace, and falls back to Default only for a token carrying no
  `workspace_id` at all (a pre-tenancy / instance-operator token). Every
  route below that reads `current_workspace` therefore attributes
  per-workspace today. `pipeline :flat_admin_api` carries the same order as
  an explicit contract rather than by convergence.

  A stale prose comment describing the OLD order is what produced the two
  cross-tenant defect rows that this census retires (see WHAT THE FILINGS GOT
  WRONG below). Read the pipeline body, never the comment above it.

  ## Verdicts

    * `:tenant_bound` — something downstream re-derives the target workspace
      and refuses a stranger. The reason NAMES that function, and
      `guard_symbol_present/1` reads the controller's own source to assert
      the symbol is still there (a cheap tripwire against the guard being
      deleted later).
    * `:instance_global` — legitimately instance-wide. See THE RULING.
    * `:exploitable` — a client-supplied selector (`:workspace_slug`,
      `:dataset`, a bare row id) reaches TENANT rows with no re-derivation.

  ON TODAY'S main THE `:exploitable` SET IS EMPTY, and that is an assertion
  in this file (`@expected_exploitable`), not a footnote — so the first route
  that re-opens the class must classify itself and reds this test. The
  probes in the second half do not merely trace the fences; they RUN them:
  two workspaces, an admin-permissioned token that is admin ONLY in A, a
  request naming B's resource, and an assertion on the real status and body.

  ## THE RULING — which routes are legitimately instance-global (criterion 2)

  A later confinement sweep must NOT workspace-scope these. Each is
  instance-global for a stated structural reason, not for convenience:

    1. `POST /v1/admin/self-update`, `GET /v1/admin/self-update`,
       `POST /v1/admin/rollback`, `POST /v1/admin/site-deploy`,
       `GET /v1/admin/site-deploy` — OPERATOR PRIMITIVES. They apply, roll
       back and deploy the BEAM release and the marketing site the whole
       instance runs on. There is no tenant target to bind them to; a
       per-workspace variant is not a narrower version of this capability,
       it is a different (nonexistent) capability. These are the canonical
       "do not confine" rows the program was told to name.
    2. `GET /v1/plugins` — the installed-plugin ROSTER. Instance-level
       inventory; no workspace param, no tenant rows.
    3. `GET|PUT|DELETE /v1/plugins/settings/:plugin_name` — instance-level
       plugin config. `Barkpark.Plugins.SettingsRecord` is
       `@primary_key {:plugin_name, :string, ...}` with NO `workspace_id`
       column at all, so there is no per-tenant row to confine to. `show`
       masks; `update` writes the one instance-wide record.
    4. `GET /v1/secrets`, `GET /v1/secrets/:name`, `GET /v1/secrets/:name/audit`,
       `PUT /v1/secrets/:name`, `DELETE /v1/secrets/:name` — the GLOBAL tier
       of a deliberately two-tier store. `SecretController.resolve_scope/1`
       keys off the ROUTE (presence of a `workspace_slug` path param), never
       the assigns, and pins the flat route to `:global`
       (`workspace_id IS NULL`). The PER-WORKSPACE twin already exists on
       `:scoped_admin` at `/w/:ws/p/:proj/v1/secrets`. Confining the flat
       route would not add a boundary; it would delete the global tier.
    5. `POST /v1/status/incidents`, `POST /v1/status/incidents/:id/resolve` —
       the instance STATUS PAGE. `Barkpark.Status.create_incident/1` takes no
       workspace and `Status.Incident` carries no `workspace_id`.
    6. `POST /api/playground` — a CREATION primitive. It mints a brand-new
       workspace, owner and quota; the admin gate answers "who may
       provision", and there is no pre-existing tenant it can reach.
    7. `POST /api/workspaces/:workspace_slug/import` — a RESTORE whose target
       comes from the BUNDLE MANIFEST, not from the URL (the `:workspace_slug`
       segment is read and ignored). `clean` mode fails closed on a
       slug/PK collision with a live workspace; `merge` mode (the only arm
       that can write into an existing workspace) is refused unless the
       server operator sets `:allow_bundle_import`. There is no
       victim-selecting parameter to bind.

  THE STANDING COST OF THIS RULING, stated so nobody reads it as an all-clear:
  rows 3, 4 and 1 mean a token that is an admin of ONE workspace and a
  stranger everywhere else can still read instance secrets in cleartext
  (`SecretController.show/2` reveals, by design), rewrite instance plugin
  config, and roll the whole instance forward or back. That is not a
  cross-TENANT hole — no tenant rows are reachable — but it is the reason the
  `admin` permission must stay an OPERATOR-minted bit. The correct follow-on
  is a separate operator/instance-admin tier, not a workspace filter on these
  seven surfaces. Filed as `task-c7e2b87f1bbca815` (p0), whose two probes below
  (RULING rows 3 and 4) are the evidence it quotes.

  ## FOLLOW-ON SLICES FILED (criterion 3)

    * `task-c7e2b87f1bbca815` (p0, RULING) — the instance-global tier. Run-proved
      by the two RULING probes below.
    * `task-62d9364937b538e5` (p2, RULING) — `put_blob/2`'s `member?/2` role
      floor against its two `workspace_admin?/2` siblings on the same slug.

  No per-controller cross-tenant fix slice is filed, because there is no
  `:exploitable` row to fix. Filing one anyway would have been the same
  mistake the two rows below made.

  ## WHAT THE FILINGS GOT WRONG

    * `task-ee099124abc578ef` ("/v1/plugins/tickets/keys collapses every admin
      to Default") — OVERTAKEN. Fenced since #13886, which predates the
      filing. Run-proved below: admin-of-A's `GET /v1/plugins/tickets/keys`
      does not contain B's key.
    * `task-16eaa5da69f2acc1` ("GET /v1/shares enumerates every tenant's
      shares") — OVERTAKEN by #14335 (`fdb04d57d5`), which put
      `visible_stored_shares/1` in front of `Sharing.list_stored/0`.
      Run-proved below.
    * The parent row's "roughly forty routes" and "fifteen router scope
      blocks" are both low: 19 blocks, 70 routes (7 of them contributed by
      plugins through `plugin_routes(scope: :api)`, which no router grep
      finds).
    * The parent row lists `SchemaController, StructureController,
      MediaController` (among others) as "controllers with ZERO workspace
      references anywhere in the module" and treats that as a proxy for no
      re-derivation. The proxy is wrong: those three reach tenancy through
      `BarkparkWeb.ScopeHelpers.scope_opts/1` and `TenancyAuth.member?/2`,
      neither of which contains the substring `workspace`. A
      name-keyed grep cannot find a shape-keyed fence.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.RateLimiterSandbox
  import Barkpark.TenancyFixtures

  alias Barkpark.Auth

  @dataset "production"

  # ── The gated pipelines ────────────────────────────────────────────────
  # Both mount `BarkparkWeb.Plugs.RequireAdmin`. Adding a third pipeline that
  # mounts it without adding it here would silently shrink this census, so
  # `the plug is mounted by exactly these pipelines` asserts the set.
  @gated_pipelines ["pipe_through([:api, :require_admin])", "pipe_through(:flat_admin_api)"]

  # Where plugin-contributed `auth: :api` routes are mounted (router.ex,
  # `scope "/v1/plugins" do  pipe_through([:api, :require_admin])`).
  @plugin_api_prefix "/v1/plugins"

  # ── THE TABLE ──────────────────────────────────────────────────────────
  # {verb, path} => {verdict, guard_symbol_or_nil, reason}
  #
  # `guard_symbol` is asserted to still appear in the ROUTE'S OWN controller
  # source (resolved through `module_info(:compile)[:source]`, so a file move
  # cannot make the tripwire vacuous). nil for :instance_global rows, which
  # have no guard to lose.
  @census %{
    # ── plugin bucket: `plugin_routes(scope: :api)` inside
    #    `scope "/v1/plugins" do pipe_through([:api, :require_admin])` ──
    {:post, "/v1/plugins/tickets/keys"} =>
      {:tenant_bound, "current_workspace_id(conn)",
       "TicketKeysController.current_workspace_id/1 reads :current_workspace, which " <>
         "Plugs.DeriveWorkspaceFromToken (pipeline :api, AHEAD of AssignDefaultScope since " <>
         "#13886) set to the TOKEN's workspace; Keys.mint/1 stamps that workspace_id."},
    {:get, "/v1/plugins/tickets/keys"} =>
      {:tenant_bound, "current_workspace_id(conn)",
       "Keys.list/1 filters through scope_workspace/2 on the derived workspace id."},
    {:post, "/v1/plugins/tickets/keys/:id/rotate"} =>
      {:tenant_bound, "current_workspace_id(conn)",
       "Keys.rotate/2 takes (id, ws_id) and its stamp/3 matches BOTH, so a foreign id misses."},
    {:post, "/v1/plugins/tickets/keys/:id/pause"} =>
      {:tenant_bound, "current_workspace_id(conn)",
       "Keys.pause/2 -> stamp/3, matched on (id, derived workspace id)."},
    {:post, "/v1/plugins/tickets/keys/:id/unpause"} =>
      {:tenant_bound, "current_workspace_id(conn)",
       "Keys.unpause/2 -> stamp/3, matched on (id, derived workspace id)."},
    {:delete, "/v1/plugins/tickets/keys/:id"} =>
      {:tenant_bound, "current_workspace_id(conn)",
       "Keys.revoke/2 -> stamp/3, matched on (id, derived workspace id)."},
    {:get, "/v1/plugins/onixedit/export/:dataset/:id"} =>
      {:tenant_bound, "scope_opts(conn)",
       "OnixEdit.Web.ExportController.load_doc/4 probes both the draft and the published id " <>
         "through Content.get_document/4 with ScopeHelpers.scope_opts/1, so the workspace " <>
         "envelope applies to a bare :id as well as to :dataset."},

    # ── /v1/status ──
    {:post, "/v1/status/incidents"} =>
      {:instance_global, nil,
       "Instance status page. Status.create_incident/1 takes no workspace and Status.Incident " <>
         "has no workspace_id column. RULING row 5."},
    {:post, "/v1/status/incidents/:id/resolve"} =>
      {:instance_global, nil, "Same instance status page incident. RULING row 5."},

    # ── /v1/plugins roster + settings ──
    {:get, "/v1/plugins"} =>
      {:instance_global, nil, "Installed-plugin roster; no workspace param. RULING row 2."},
    {:get, "/v1/plugins/settings/:plugin_name"} =>
      {:instance_global, nil,
       "Plugins.SettingsRecord is @primary_key {:plugin_name, :string} with NO workspace_id " <>
         "column, so there is no per-tenant row. RULING row 3."},
    {:put, "/v1/plugins/settings/:plugin_name"} =>
      {:instance_global, nil, "Writes the one instance-wide settings record. RULING row 3."},
    {:delete, "/v1/plugins/settings/:plugin_name"} =>
      {:instance_global, nil, "Deletes the one instance-wide settings record. RULING row 3."},

    # ── /v1/secrets (GLOBAL tier of a two-tier store) ──
    {:get, "/v1/secrets"} =>
      {:instance_global, nil,
       "SecretController.resolve_scope/1 keys off the ROUTE (no :workspace_slug path param) " <>
         "and pins the flat surface to :global (workspace_id IS NULL), NEVER the " <>
         ":current_workspace assign. RULING row 4."},
    {:get, "/v1/secrets/:name/audit"} =>
      {:instance_global, nil, "scope_audit/2 :global arm is an explicit IS NULL. RULING row 4."},
    {:get, "/v1/secrets/:name"} =>
      {:instance_global, nil,
       "Reveals the global-tier value by design (the scoped twin serves per-workspace " <>
         "secrets). RULING row 4."},
    {:put, "/v1/secrets/:name"} =>
      {:instance_global, nil, "Writes the global tier. RULING row 4."},
    {:delete, "/v1/secrets/:name"} =>
      {:instance_global, nil, "Deletes from the global tier. RULING row 4."},

    # ── /v1/admin — operator primitives ──
    {:post, "/v1/admin/self-update"} =>
      {:instance_global, nil, "Operator: applies a release to the whole instance. RULING row 1."},
    {:get, "/v1/admin/self-update"} =>
      {:instance_global, nil, "Operator: instance self-update status. RULING row 1."},
    {:post, "/v1/admin/rollback"} =>
      {:instance_global, nil, "Operator: rolls the whole instance back. RULING row 1."},
    {:post, "/v1/admin/site-deploy"} =>
      {:instance_global, nil, "Operator: deploys the marketing site. RULING row 1."},
    {:get, "/v1/admin/site-deploy"} =>
      {:instance_global, nil, "Operator: site-deploy status. RULING row 1."},

    # ── /v1/instance — operator reads moved onto :require_admin by #14793 ──
    # (task-d7ac954aa57aa522). The census merged the same hour without them,
    # so "every gated route carries a verdict" has been red on main since.
    {:get, "/v1/instance/site-deploy"} =>
      {:instance_global, nil,
       "Operator: the whole instance's marketing-site deploy status; no tenant selector, " <>
         "the twin of GET /v1/admin/site-deploy. RULING row 1."},
    {:get, "/v1/instance/metrics"} =>
      {:instance_global, nil,
       "Prometheus text exposition of this BEAM's own telemetry aggregates. workspace_id " <>
         "appears only as a series LABEL the handler stamps, never as a request selector; " <>
         "the payload names tenants, which is why it is admin-gated at all. RULING row 1."},

    # ── /v1/shares ──
    {:get, "/v1/shares"} =>
      {:tenant_bound, "visible_stored_shares",
       "ShareController.index/2 passes Sharing.list_stored/0 through " <>
         "visible_stored_shares/1, which keeps a stored row only when " <>
         "workspace_admin?/2 (Tenancy.Auth.workspace_admin?/2) holds for its workspace. " <>
         "The `env` half is instance CONFIG read from the server's own environment, not " <>
         "tenant rows, and carries no client-supplied selector."},
    {:post, "/v1/shares"} =>
      {:tenant_bound, "workspace_admin?(conn",
       "create/2 resolves the target workspace from the request, THEN " <>
         "Tenancy.Auth.workspace_admin?/2 (never authorize/3, whose api_token arm would pass " <>
         "a global-admin token holding a plain member row in B)."},
    {:delete, "/v1/shares"} =>
      {:tenant_bound, "workspace_admin?(conn",
       "delete/2, same resolve-then-workspace_admin?/2 shape as create/2."},
    {:get, "/v1/shares/tokens"} =>
      {:tenant_bound, "workspace_admin?(conn",
       "list_tokens/2 filters the row set through workspace_admin?/2 per row."},
    {:post, "/v1/shares/tokens"} =>
      {:tenant_bound, "workspace_admin?(conn",
       "mint_token/2 resolves the share's workspace THEN workspace_admin?/2."},
    {:delete, "/v1/shares/tokens/:token_id"} =>
      {:tenant_bound, "workspace_admin?(conn",
       "revoke_token/2 reads the row's workspace THEN workspace_admin?/2."},
    {:get, "/v1/shares/links"} =>
      {:tenant_bound, "ensure_workspace_admin",
       "ShareLinkController.list/2 resolves the workspace THEN " <>
         "ensure_workspace_admin/2 -> Sharing.Links.workspace_admin?/2."},
    {:post, "/v1/shares/links"} =>
      {:tenant_bound, "ensure_workspace_admin", "ShareLinkController.mint/2, same shape."},
    {:delete, "/v1/shares/links/:id"} =>
      {:tenant_bound, "ensure_workspace_admin",
       "ShareLinkController.revoke/2 reads the row's workspace THEN the same predicate."},

    # ── /api/workspaces/:workspace_slug/media ──
    {:put, "/api/workspaces/:workspace_slug/media/blob/*path"} =>
      {:tenant_bound, "TenancyAuth.member?",
       "put_blob/2 resolves the workspace from the URL slug THEN Tenancy.Auth.member?/2, a " <>
         "pure membership lookup with NO global-admin bypass; an unknown slug and a " <>
         "non-member both fold into the same 404. NOTE the predicate is member?/2, not " <>
         "workspace_admin?/2 — deliberately weaker than its two sibling routes on the same " <>
         "workspace, so a `viewer` member of B may push blobs into B. That role-floor " <>
         "asymmetry is a RULING, filed as task-62d9364937b538e5; this entry's guard symbol " <>
         "must be re-pointed if that ruling swaps the predicate."},

    # ── /api workspace lifecycle ──
    {:delete, "/api/workspaces/:workspace_slug"} =>
      {:tenant_bound, "TenancyAuth.workspace_admin?",
       "WorkspaceController.delete/2 resolves the slug THEN Tenancy.Auth.workspace_admin?/2 " <>
         "against the RESOLVED target before the cascade teardown."},
    {:post, "/api/playground"} =>
      {:instance_global, nil,
       "Provisioning primitive: mints a NEW workspace + owner + quota. RULING row 6."},
    {:get, "/api/workspaces/:workspace_slug/export"} =>
      {:tenant_bound, "TenancyAuth.workspace_admin?",
       "WorkspaceController.export/2 resolves the slug THEN Tenancy.Auth.workspace_admin?/2 " <>
         "before any byte of the bundle is streamed."},
    {:post, "/api/workspaces/:workspace_slug/import"} =>
      {:instance_global, nil,
       "The :workspace_slug segment is read and IGNORED; the restore target comes from the " <>
         "bundle manifest. clean mode fails closed on a slug/PK collision, merge mode is " <>
         "refused unless the operator sets :allow_bundle_import. RULING row 7."},

    # ── :flat_admin_api — /v1/data search ──
    {:get, "/v1/data/search/:dataset/settings"} =>
      {:tenant_bound, "workspace_id(conn)",
       "SearchController reads :current_workspace via workspace_id/1; SurfaceConfigs.get/3 " <>
         "keys on (workspace_id, surface, scope), so :dataset alone cannot cross a tenant."},
    {:put, "/v1/data/search/:dataset/settings"} =>
      {:tenant_bound, "token_workspace_id",
       "update_search_settings/2 additionally reads the RAW pre-mask token workspace_id " <>
         "(token_workspace_id/1) and refuses when nil, so an unbound token cannot write into " <>
         "the Default tier (D58/D71 fail-closed)."},
    {:get, "/v1/data/search/:dataset/insights"} =>
      {:tenant_bound, "workspace_id(conn)", "Insights read is scoped by the derived workspace."},
    {:get, "/v1/data/search/:dataset/synonyms"} =>
      {:tenant_bound, "workspace_id(conn)", "Synonyms.list/3 takes the derived workspace id."},
    {:get, "/v1/data/search/:dataset/synonyms/preview"} =>
      {:tenant_bound, "workspace_id(conn)", "Synonyms.preview/5 takes the derived workspace id."},
    {:post, "/v1/data/search/:dataset/synonyms"} =>
      {:tenant_bound, "token_workspace_id", "D58/D71 fail-closed before Synonyms.create/4."},
    {:post, "/v1/data/search/:dataset/synonyms/promote"} =>
      {:tenant_bound, "token_workspace_id", "D58/D71 fail-closed before Synonyms.promote/4."},
    {:delete, "/v1/data/search/:dataset/synonyms/:id"} =>
      {:tenant_bound, "token_workspace_id",
       "Synonyms.delete/4 additionally refuses a row whose workspace_id is a DIFFERENT " <>
         "workspace, so a bare :id cannot reach a sibling tenant's synonym."},

    # ── :flat_admin_api — structure + schemas ──
    {:get, "/v1/structure/:dataset"} =>
      {:tenant_bound, "scope_opts(conn)",
       "Structure.build/2 receives ScopeHelpers.scope_opts/1, the shared workspace/project " <>
         "envelope."},
    {:get, "/v1/schemas/:dataset"} =>
      {:tenant_bound, "scope_opts(conn)", "Content.list_schemas_for_sdk/2 under scope_opts/1."},
    {:get, "/v1/schemas/:dataset/:name"} =>
      {:tenant_bound, "scope_opts(conn)", "Content.get_schema/3 under scope_opts/1."},
    {:post, "/v1/schemas/:dataset"} =>
      {:tenant_bound, "scope_opts(conn)", "Content.upsert_schema/3 stamps the scope."},
    {:delete, "/v1/schemas/:dataset/:name"} =>
      {:tenant_bound, "scope_opts(conn)", "Content.delete_schema under scope_opts/1."},

    # ── :flat_admin_api — fleet support tokens ──
    {:post, "/v1/fleet/support-tokens"} =>
      {:tenant_bound, "conn.assigns[:current_workspace]",
       "create/2 binds the minted token to the DERIVED workspace; it cannot mint into a " <>
         "workspace named by the caller because no parameter names one."},
    {:delete, "/v1/fleet/support-tokens/:token_id"} =>
      {:tenant_bound, "TenancyAuth.workspace_admin?",
       "delete/2 reads the TARGET row's workspace_id THEN workspace_admin?/2 — deliberately " <>
         "not `target.workspace_id == caller_workspace_id`, which would deny an admin " <>
         "legitimately seated in several workspaces."},

    # ── :flat_admin_api — webhooks ──
    {:get, "/v1/webhooks/:dataset"} =>
      {:tenant_bound, "ScopeHelpers.scope_opts(conn)",
       "Webhooks.list_webhooks/2 under scope_opts/1."},
    {:get, "/v1/webhooks/:dataset/:id"} =>
      {:tenant_bound, "ScopeHelpers.scope_opts(conn)",
       "Webhooks.get_webhook/2 pipes the id query through scope/1 with scope_opts/1, so a " <>
         "bare foreign id is {:error, :not_found}, never a row."},
    {:get, "/v1/webhooks/:dataset/:id/deliveries"} =>
      {:tenant_bound, "ScopeHelpers.scope_opts(conn)",
       "The delivery read re-fetches the webhook through the same scoped get_webhook/2."},
    {:post, "/v1/webhooks/:dataset"} =>
      {:tenant_bound, "ScopeHelpers.scope_opts(conn)",
       "Webhooks.create_webhook/2 stamps the scope."},
    {:post, "/v1/webhooks/:dataset/:id/deliveries/:event_id/replay"} =>
      {:tenant_bound, "ScopeHelpers.scope_opts(conn)",
       "Scoped get_webhook/2 first; the event is additionally matched on the webhook's own " <>
         "workspace_id."},
    {:post, "/v1/webhooks/:dataset/:id/rotate"} =>
      {:tenant_bound, "ScopeHelpers.scope_opts(conn)", "Scoped get_webhook/2 first."},
    {:post, "/v1/webhooks/:dataset/:id/reenable"} =>
      {:tenant_bound, "ScopeHelpers.scope_opts(conn)", "Scoped get_webhook/2 first."},
    {:post, "/v1/webhooks/:dataset/:id/test-send"} =>
      {:tenant_bound, "ScopeHelpers.scope_opts(conn)", "Scoped get_webhook/2 first."},
    {:put, "/v1/webhooks/:dataset/:id"} =>
      {:tenant_bound, "ScopeHelpers.scope_opts(conn)", "Scoped get_webhook/2 first."},
    {:delete, "/v1/webhooks/:dataset/:id"} =>
      {:tenant_bound, "ScopeHelpers.scope_opts(conn)", "Scoped get_webhook/2 first."},

    # ── :flat_admin_api — /v1/media search ──
    {:get, "/v1/media/:dataset/search/settings"} =>
      {:tenant_bound, "workspace_id(conn)",
       "V1.MediaController mirrors SearchController on the \"media\" surface; " <>
         "SurfaceConfigs.get/3 keys on the derived workspace id."},
    {:put, "/v1/media/:dataset/search/settings"} =>
      {:tenant_bound, "token_workspace_id", "D58/D71 fail-closed before SurfaceConfigs.upsert/4."},
    {:get, "/v1/media/:dataset/search/insights"} =>
      {:tenant_bound, "workspace_id(conn)", "Insights read scoped by the derived workspace."},
    {:get, "/v1/media/:dataset/search/synonyms"} =>
      {:tenant_bound, "workspace_id(conn)", "Synonyms.list/3 on the derived workspace id."},
    {:get, "/v1/media/:dataset/search/synonyms/preview"} =>
      {:tenant_bound, "workspace_id(conn)", "Synonyms.preview/5 on the derived workspace id."},
    {:post, "/v1/media/:dataset/search/synonyms"} =>
      {:tenant_bound, "token_workspace_id", "D58/D71 fail-closed before Synonyms.create/4."},
    {:post, "/v1/media/:dataset/search/synonyms/promote"} =>
      {:tenant_bound, "token_workspace_id", "D58/D71 fail-closed before Synonyms.promote/4."},
    {:delete, "/v1/media/:dataset/search/synonyms/:id"} =>
      {:tenant_bound, "token_workspace_id",
       "Synonyms.delete/4 refuses a row belonging to a different workspace."}
  }

  # The live workspace-blind set. Empty on main as of this commit; a new
  # :exploitable row must be added here deliberately, with a filed task id.
  @expected_exploitable []

  # ── Enumeration ────────────────────────────────────────────────────────

  # Router source, read at RUNTIME so a new route lands in the census the
  # moment it is declared — not when someone remembers to update a list.
  defp router_source_path, do: Path.join([File.cwd!(), "lib", "barkpark_web", "router.ex"])

  @doc false
  # Walk router.ex. Every `scope "<prefix>"` at indent 2 opens a block; a
  # `pipe_through` at indent 4 naming one of @gated_pipelines marks that block
  # gated; every route macro at indent 4 AFTER it (Phoenix's own
  # "applies to routes declared after it in the same scope" rule) is a census
  # row. `plugin_routes(scope: :api)` expands through the SAME registry call
  # the macro makes at compile time.
  def enumerate_gated_routes do
    router_source_path()
    |> File.read!()
    |> String.split("\n")
    |> Enum.reduce({nil, false, []}, fn line, {prefix, gated?, acc} ->
      trimmed = String.trim(line)
      indent = String.length(line) - String.length(String.trim_leading(line))

      cond do
        indent == 2 and String.starts_with?(trimmed, "scope ") ->
          {scope_prefix(trimmed), false, acc}

        indent == 2 and trimmed != "" ->
          {nil, false, acc}

        indent == 4 and trimmed in @gated_pipelines ->
          {prefix, true, acc}

        gated? and indent == 4 and trimmed == "plugin_routes(scope: :api)" ->
          {prefix, gated?, acc ++ plugin_api_routes()}

        gated? and indent == 4 ->
          case route_macro(trimmed) do
            nil -> {prefix, gated?, acc}
            {verb, path} -> {prefix, gated?, acc ++ [{verb, join_path(prefix, path)}]}
          end

        true ->
          {prefix, gated?, acc}
      end
    end)
    |> elem(2)
  end

  defp scope_prefix(line) do
    case Regex.run(~r/^scope\s+"([^"]*)"/, line) do
      [_, p] -> p
      _ -> nil
    end
  end

  @verbs ~w(get post put patch delete options head)
  defp route_macro(trimmed) do
    case Regex.run(~r/^([a-z]+)\(\s*"([^"]*)"\s*,/, trimmed) do
      [_, verb, path] when verb in @verbs -> {String.to_existing_atom(verb), path}
      _ -> nil
    end
  end

  defp join_path(prefix, path) do
    joined = String.replace(to_string(prefix) <> path, ~r{/+}, "/")

    case String.trim_trailing(joined, "/") do
      "" -> "/"
      p -> p
    end
  end

  # The plugin `auth: :api` bucket, resolved the way `plugin_routes/1` does.
  defp plugin_api_routes do
    %{scope: :api, phase: :runtime}
    |> Barkpark.Plugins.Registry.collect_routes()
    |> Enum.filter(fn
      {_kind, _path, _mod, _action, opts} when is_list(opts) ->
        Keyword.get(opts, :auth, :admin) == :api

      _ ->
        false
    end)
    |> Enum.map(fn {kind, path, _mod, _action, _opts} ->
      {kind, join_path(@plugin_api_prefix, path)}
    end)
  end

  defp compiled_routes do
    BarkparkWeb.Router.__routes__()
    |> Enum.map(&{&1.verb, &1.path})
    |> MapSet.new()
  end

  defp plug_for({verb, path}) do
    BarkparkWeb.Router.__routes__()
    |> Enum.find(&(&1.verb == verb and &1.path == path))
    |> case do
      nil -> nil
      r -> r.plug
    end
  end

  # ── The census itself ──────────────────────────────────────────────────

  describe "enumeration" do
    test "the RequireAdmin plug is mounted by exactly the pipelines this census walks" do
      source = File.read!(router_source_path())

      mounts =
        source
        |> String.split("\n")
        |> Enum.filter(&(String.trim(&1) == "plug(BarkparkWeb.Plugs.RequireAdmin)"))

      assert length(mounts) == 2,
             "BarkparkWeb.Plugs.RequireAdmin is mounted #{length(mounts)} times in router.ex, " <>
               "but this census walks #{length(@gated_pipelines)} pipelines " <>
               "(#{inspect(@gated_pipelines)}). A new mount means a new set of routes gated " <>
               "by a global role bit — classify them here."
    end

    test "the parse is not vacuous and is faithful to the compiled router" do
      routes = enumerate_gated_routes()

      # NON-VACUITY: a parser that silently stops matching would otherwise
      # make every completeness assertion below trivially true.
      assert length(routes) >= 60,
             "enumerate_gated_routes/0 found only #{length(routes)} routes; the parser has " <>
               "probably gone blind on a reformat of router.ex."

      assert routes == Enum.uniq(routes), "the enumeration produced duplicate {verb, path} pairs"

      compiled = compiled_routes()

      missing = Enum.reject(routes, &MapSet.member?(compiled, &1))

      assert missing == [],
             "these parsed routes are not in BarkparkWeb.Router.__routes__/0, so the parse " <>
               "(scope prefix joining, most likely) no longer matches reality: " <>
               inspect(missing)
    end
  end

  describe "the table" do
    test "every gated route carries a verdict, and every verdict names a live route" do
      routes = MapSet.new(enumerate_gated_routes())
      classified = @census |> Map.keys() |> MapSet.new()

      unclassified = MapSet.difference(routes, classified) |> Enum.sort()

      assert unclassified == [],
             "UNCLASSIFIED: these routes are gated only by Auth.has_permission?(token, " <>
               "\"admin\") and carry no verdict. Add each to @census as :tenant_bound " <>
               "(naming the guard), :instance_global (saying why, and extend THE RULING), " <>
               "or :exploitable (and file a fix slice):\n" <>
               Enum.map_join(unclassified, "\n", &inspect/1)

      stale = MapSet.difference(classified, routes) |> Enum.sort()

      assert stale == [],
             "STALE: these @census entries name routes that are no longer gated by " <>
               "RequireAdmin (moved pipeline, renamed path, or deleted). Remove or " <>
               "re-point them:\n" <> Enum.map_join(stale, "\n", &inspect/1)
    end

    test "verdicts are drawn from the closed vocabulary" do
      Enum.each(@census, fn {route, {verdict, guard, reason}} ->
        assert verdict in [:tenant_bound, :instance_global, :exploitable],
               "#{inspect(route)} carries an unknown verdict #{inspect(verdict)}"

        assert is_binary(reason) and String.length(reason) > 20,
               "#{inspect(route)} carries no usable reason"

        case verdict do
          :tenant_bound ->
            assert is_binary(guard),
                   "#{inspect(route)} is :tenant_bound but names no guard symbol"

          _ ->
            assert is_nil(guard),
                   "#{inspect(route)} is #{inspect(verdict)} but names a guard symbol"
        end
      end)
    end

    test "the live :exploitable set is exactly @expected_exploitable" do
      exploitable =
        @census
        |> Enum.filter(fn {_r, {v, _g, _reason}} -> v == :exploitable end)
        |> Enum.map(&elem(&1, 0))
        |> Enum.sort()

      assert exploitable == Enum.sort(@expected_exploitable),
             "the workspace-blind set changed. Every :exploitable row needs a run-proved " <>
               "cross-tenant probe below and a filed fix slice."
    end

    test "TRIPWIRE: every named guard symbol is still present in that route's controller" do
      @census
      |> Enum.filter(fn {_r, {v, _g, _reason}} -> v == :tenant_bound end)
      |> Enum.each(fn {route, {_v, guard, _reason}} ->
        mod = plug_for(route)

        assert mod,
               "#{inspect(route)} has no compiled route (the table test should have caught this)"

        src = mod.module_info(:compile)[:source] |> List.to_string()

        assert File.exists?(src),
               "cannot read #{inspect(mod)}'s source at #{src} to check the guard tripwire"

        assert String.contains?(File.read!(src), guard),
               "GUARD GONE: #{inspect(route)} is classified :tenant_bound because of `#{guard}` " <>
                 "in #{inspect(mod)} (#{src}), and that symbol is no longer there. Either the " <>
                 "fence was renamed (re-point this entry) or it was deleted (this route is now " <>
                 ":exploitable — prove it and file a fix slice)."
      end)
    end
  end

  # ── RUN-PROVED probes (criterion 1) ────────────────────────────────────
  #
  # Fixture shape for every probe: TWO workspaces; `admin_a` is an
  # admin-permissioned token seated in A and a stranger to B; the request
  # names B's resource. `Auth.create_token/5` writes the principal's
  # membership in the bound workspace with a role derived from permissions,
  # so admin_a is an ADMIN MEMBER of exactly one workspace.
  #
  # A same-workspace fixture would pass whether or not the boundary exists —
  # which is exactly how the census this replaces got two verdicts wrong.

  setup :reset_rate_limiter!

  setup do
    ws_a = create_workspace!()
    ws_b = create_workspace!()

    admin_a = uniq("adm-a")
    admin_b = uniq("adm-b")

    {:ok, tok_a} =
      Auth.create_token(admin_a, uniq("lbl-a"), @dataset, ["read", "write", "admin"], ws_a.id)

    {:ok, tok_b} =
      Auth.create_token(admin_b, uniq("lbl-b"), @dataset, ["read", "write", "admin"], ws_b.id)

    %{
      ws_a: ws_a,
      ws_b: ws_b,
      admin_a: admin_a,
      admin_b: admin_b,
      tok_a: tok_a,
      tok_b: tok_b
    }
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp as(bearer) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{bearer}")
    |> put_req_header("content-type", "application/json")
  end

  # Criterion 1 wants the row's evidence to quote an ACTUAL status and body,
  # not a chain of reads. `CENSUS_EVIDENCE=1 mix test <this file>` prints
  # exactly that for every probe, so the quote in a task row is reproducible
  # by one command instead of being retyped from a transcript.
  defp evidence(label, conn) do
    if System.get_env("CENSUS_EVIDENCE") do
      IO.puts(
        "\nCENSUS-EVIDENCE #{label}\n  status: #{conn.status}\n  body: " <>
          String.slice(conn.resp_body || "", 0, 400)
      )
    end

    conn
  end

  describe "PROBE: the :workspace_slug routes — the URL names the victim" do
    test "DELETE /api/workspaces/:slug (B) by an admin of A is refused and B survives",
         %{ws_b: ws_b, admin_a: admin_a} do
      conn =
        evidence(
          "DELETE /api/workspaces/:slug (B) as admin-of-A",
          delete(as(admin_a), "/api/workspaces/#{ws_b.slug}")
        )

      assert conn.status in [403, 404],
             "an admin of A reached the cascade delete of B (status #{conn.status})"

      assert Barkpark.Tenancy.get_workspace_by_slug(ws_b.slug)
    end

    test "GET /api/workspaces/:slug/export (B) by an admin of A streams nothing",
         %{ws_b: ws_b, admin_a: admin_a} do
      conn =
        evidence(
          "GET /api/workspaces/:slug/export (B) as admin-of-A",
          get(as(admin_a), "/api/workspaces/#{ws_b.slug}/export")
        )

      assert conn.status in [403, 404]
    end

    test "PUT /api/workspaces/:slug/media/blob/*path (B) by a NON-MEMBER admin of A is a 404",
         %{ws_b: ws_b, admin_a: admin_a} do
      conn =
        as(admin_a)
        |> put_req_header("content-type", "application/octet-stream")
        |> put("/api/workspaces/#{ws_b.slug}/media/blob/#{uniq("probe")}.txt", "payload")
        |> then(&evidence("PUT /api/workspaces/:slug/media/blob/*path (B) as admin-of-A", &1))

      assert conn.status == 404
      # Never confirm the workspace exists to a non-member.
      assert conn.resp_body =~ "workspace not found"
    end

    test "THE LEGITIMATE ARM: the same three routes work against the caller's OWN workspace",
         %{ws_a: ws_a, admin_a: admin_a} do
      # Export is the read-only one, so it is the safe positive control: if
      # this 403s too, the probes above are proving nothing.
      conn =
        evidence(
          "POSITIVE CONTROL: GET /api/workspaces/:slug/export (A) as admin-of-A",
          get(as(admin_a), "/api/workspaces/#{ws_a.slug}/export")
        )

      assert conn.status == 200
    end
  end

  describe "PROBE: task-16eaa5da69f2acc1 — GET /v1/shares no longer enumerates every tenant" do
    test "a stored share created by B's admin is absent from A's admin's listing",
         %{ws_b: ws_b, admin_a: admin_a, admin_b: admin_b} do
      created =
        as(admin_b)
        |> post("/v1/shares", Jason.encode!(%{scope: ws_b.slug, surfaces: "docs"}))
        |> then(&evidence("SETUP: POST /v1/shares (scope = B) as admin-of-B", &1))

      assert created.status == 201,
             "the setup share was never stored (#{created.status}: #{created.resp_body}), so " <>
               "the listing probe below would be VACUOUS"

      # NON-VACUITY CONTROL: the row exists and B's own admin CAN see it. Only
      # then does A's admin not seeing it mean anything.
      mine =
        as(admin_b)
        |> get("/v1/shares")
        |> then(&evidence("CONTROL: GET /v1/shares as admin-of-B (owner)", &1))
        |> json_response(200)

      assert Enum.any?(mine["shares"] || [], &(&1["workspace"] == ws_b.slug)),
             "B's own admin cannot see B's stored share, so the probe proves nothing: " <>
               inspect(mine)

      listing =
        as(admin_a)
        |> get("/v1/shares")
        |> then(&evidence("GET /v1/shares as admin-of-A after B stored a share", &1))
        |> json_response(200)

      refute Enum.any?(listing["shares"] || [], &(&1["workspace"] == ws_b.slug)),
             "A's admin saw B's stored share: #{inspect(listing)}"
    end
  end

  describe "PROBE: task-ee099124abc578ef — /v1/plugins/tickets/keys attributes per-workspace" do
    test "a key minted by B's admin is absent from A's admin's index",
         %{admin_a: admin_a, admin_b: admin_b} do
      minted =
        as(admin_b)
        |> post("/v1/plugins/tickets/keys", Jason.encode!(%{name: uniq("k")}))
        |> then(&evidence("SETUP: POST /v1/plugins/tickets/keys as admin-of-B", &1))

      assert minted.status == 201,
             "the setup key was never minted (#{minted.status}: #{minted.resp_body}), so the " <>
               "index probe below would be VACUOUS. A 404 here means the tickets plugin's " <>
               "runtime kill-switch is off in this environment — fix the environment rather " <>
               "than letting the probe pass on an empty list."

      id = minted.resp_body |> Jason.decode!() |> get_in(["key", "id"])
      assert is_binary(id)

      # NON-VACUITY CONTROL: B's own admin sees the key it just minted.
      mine =
        as(admin_b)
        |> get("/v1/plugins/tickets/keys")
        |> then(&evidence("CONTROL: GET /v1/plugins/tickets/keys as admin-of-B (owner)", &1))
        |> json_response(200)

      assert Enum.any?(mine["keys"] || [], &(&1["id"] == id)),
             "B's own admin cannot see B's key, so the probe proves nothing: #{inspect(mine)}"

      index =
        as(admin_a)
        |> get("/v1/plugins/tickets/keys")
        |> then(&evidence("GET /v1/plugins/tickets/keys as admin-of-A after B minted", &1))
        |> json_response(200)

      refute Enum.any?(index["keys"] || [], &(&1["id"] == id)),
             "A's admin saw B's ticket key #{id}: #{inspect(index)}"
    end
  end

  describe "PROBE: the flat :dataset routes — a shared dataset slug is not a shared tenant" do
    test "GET /v1/schemas/:dataset does not serve B's schema to A's admin",
         %{admin_a: admin_a, admin_b: admin_b} do
      name = uniq("probe_type")

      created =
        post(
          as(admin_b),
          "/v1/schemas/#{@dataset}",
          Jason.encode!(%{
            name: name,
            title: name,
            fields: [%{name: "title", type: "string"}]
          })
        )

      assert created.status in [200, 201], "schema upsert failed: #{created.resp_body}"

      shown =
        evidence(
          "GET /v1/schemas/:dataset/:name (B's schema) as admin-of-A",
          get(as(admin_a), "/v1/schemas/#{@dataset}/#{name}")
        )

      assert shown.status in [403, 404],
             "A's admin read B's schema #{name} (status #{shown.status}): #{shown.resp_body}"
    end

    test "GET /v1/webhooks/:dataset/:id does not serve B's webhook to A's admin by bare id",
         %{admin_a: admin_a, admin_b: admin_b} do
      created =
        post(
          as(admin_b),
          "/v1/webhooks/#{@dataset}",
          Jason.encode!(%{
            name: uniq("hook"),
            url: "https://example.test/#{uniq("hook")}",
            events: ["publish"]
          })
        )

      assert created.status in [200, 201], "webhook create failed: #{created.resp_body}"

      id =
        created.resp_body
        |> Jason.decode!()
        |> then(&(&1["webhook"]["id"] || &1["id"] || get_in(&1, ["data", "id"])))

      assert is_binary(id), "could not read the created webhook id from #{created.resp_body}"

      shown =
        evidence(
          "GET /v1/webhooks/:dataset/:id (B's webhook id) as admin-of-A",
          get(as(admin_a), "/v1/webhooks/#{@dataset}/#{id}")
        )

      assert shown.status in [403, 404],
             "A's admin read B's webhook #{id} (status #{shown.status}): #{shown.resp_body}"
    end

    test "GET /v1/data/search/:dataset/synonyms does not list B's synonym to A's admin",
         %{admin_a: admin_a, admin_b: admin_b} do
      term = uniq("syn")

      created =
        as(admin_b)
        |> post(
          "/v1/data/search/#{@dataset}/synonyms",
          Jason.encode!(%{from: term, to: "#{term}-alt"})
        )
        |> then(&evidence("SETUP: POST /v1/data/search/:dataset/synonyms as admin-of-B", &1))

      assert created.status in [200, 201],
             "the setup synonym was never created (#{created.status}: #{created.resp_body}), " <>
               "so the listing probe below would be VACUOUS"

      # NON-VACUITY CONTROL: B's own admin lists the synonym it just created.
      mine =
        as(admin_b)
        |> get("/v1/data/search/#{@dataset}/synonyms")
        |> then(&evidence("CONTROL: GET .../synonyms as admin-of-B (owner)", &1))

      assert mine.resp_body =~ term,
             "B's own admin cannot list B's synonym, so the probe proves nothing: " <>
               mine.resp_body

      listed =
        evidence(
          "GET /v1/data/search/:dataset/synonyms as admin-of-A after B created one",
          get(as(admin_a), "/v1/data/search/#{@dataset}/synonyms")
        )

      refute listed.resp_body =~ term, "A's admin saw B's synonym: #{listed.resp_body}"
    end
  end

  describe "PROBE: the RULING — the instance-global routes really are instance-global" do
    test "/v1/secrets is ONE global tier both admins share (RULING row 4)",
         %{admin_a: admin_a, admin_b: admin_b} do
      name = uniq("probe_secret")
      value = uniq("v")

      put_resp = put(as(admin_a), "/v1/secrets/#{name}", Jason.encode!(%{value: value}))
      assert put_resp.status == 200, "secret write failed: #{put_resp.resp_body}"

      read =
        as(admin_b)
        |> get("/v1/secrets/#{name}")
        |> then(
          &evidence("RULING row 4: GET /v1/secrets/:name as admin-of-B after A wrote it", &1)
        )
        |> json_response(200)

      # This is the ruling, RUN: it is not a tenant leak (there is no tenant
      # row), it is the global tier behaving as designed — and it is exactly
      # why `admin` must stay an operator-minted permission.
      assert read["value"] == value

      delete(as(admin_a), "/v1/secrets/#{name}")
    end

    test "/v1/plugins/settings/:plugin_name is ONE instance-wide record (RULING row 3)",
         %{admin_a: admin_a, admin_b: admin_b} do
      # A UNIQUE probe plugin name: `plugin_settings` is keyed by plugin_name
      # alone, so writing a shared name would collide with a concurrent agent
      # on the shared test database.
      plugin = uniq("census-probe")

      written =
        put(
          as(admin_a),
          "/v1/plugins/settings/#{plugin}",
          # A non-string leaf: `show/2` masks string values, so a boolean is
          # the marker that survives the round trip unmangled.
          Jason.encode!(%{settings: %{"census_probe_flag" => true}})
        )

      assert written.status == 200, "settings write failed: #{written.resp_body}"

      # B's admin — a stranger to A's workspace — reads back the record A
      # wrote. There is no per-tenant row to confine to (SettingsRecord's
      # primary key IS the plugin name), so this is the ruling, RUN.
      read =
        evidence(
          "RULING row 3: GET /v1/plugins/settings/:plugin_name as admin-of-B after A wrote it",
          get(as(admin_b), "/v1/plugins/settings/#{plugin}")
        )

      assert read.status == 200, "B's admin could not read A's write: #{read.resp_body}"
      assert read.resp_body =~ "census_probe_flag"

      delete(as(admin_b), "/v1/plugins/settings/#{plugin}")
    end
  end
end
