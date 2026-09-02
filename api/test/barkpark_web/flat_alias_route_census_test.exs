defmodule BarkparkWeb.FlatAliasRouteCensusTest do
  @moduledoc """
  THE CENSUS of the flat `/v1/*` + `/api/*` alias — the last open criterion on
  task-28c3f7f0987d6e85 (criterion 3) and task-a87a3346b8ff736a (criterion 2).

  ## What was already closed, and what was not

  `Plugs.DeriveWorkspaceFromToken` now runs in pipeline `:api` ahead of
  `AssignDefaultScope` (PR #13886), so every flat route is workspace-derived BY
  CONSTRUCTION and `flat_alias_tenancy_test.exs` pins that as a repo-wide
  pipeline invariant. `Plugs.RequireWriteForMutation` closes the mutating half
  (`:token_root` mount + the `:require_token` pipeline), pinned by
  `token_root_write_gate_test.exs`.

  Neither answers the question BOTH rows still had open: which flat routes are
  GENUINELY GLOBAL — a controller that legitimately ignores tenant scope
  (instance metrics, the capabilities manifest, the self-update executor) —
  versus workspace-derived, WITH THE REASON. Without that list the next reader
  cannot tell "correctly scope-free" from "forgot to scope".

  ## Why a map and not a table in a doc

  `@census` IS the census, and the assertions are what keep it honest:

    * a flat route missing from the map FAILS, naming the route — a new flat
      route must be classified, it cannot arrive unexamined;
    * a map entry naming a route that no longer exists FAILS — the census cannot
      rot into a list of ghosts;
    * every `:global` entry is checked AGAINST THE CONTROLLER'S OWN SOURCE: if
      the module mentions `scope_opts(` / `current_workspace` / `workspace_id`
      at all, the reason must NAME the marker it holds and say why the route is
      still global. A reason that claims "carries no scope marker at all" is
      checked to be TRUE.

  `Router.__routes__/0` alone cannot answer this — in this Phoenix version it
  carries `[:verb, :path, :plug, :plug_opts, :helper, :metadata]` and NO
  `:pipe_through` (phoenix/lib/phoenix/router.ex takes exactly those six keys).
  `Phoenix.Router.route_info/4` DOES carry `:pipe_through`, so this file probes
  each declared path with a placeholder segment and reads the pipeline back off
  the real matcher. `probe_pipelines/2` flunks if the probe lands on a DIFFERENT
  route than the one declared, so the census can never be silently narrowed by a
  shadowed path.

  ## The second half: real requests, not inspection

  `describe "read-only token probes"` issues REAL conn requests with a freshly
  minted `permissions: ["read"]` token against the tickets, fleet, task-write
  and workspace routes both rows name, and asserts 403 + the canonical
  `forbidden` envelope. That is the "post-fix status code from a real request
  with the read-only token" criterion 2 of task-a87a3346b8ff736a asks for.
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Tasks, TenancyFixtures}
  alias BarkparkWeb.Plugs.RequireWriteForMutation

  @dataset "production"

  # A path segment no real id or slug can collide with, substituted for every
  # `:param` / `*glob` so `route_info/4` can be asked about a declared path.
  @probe_segment "zzcensusprobezz"

  # The markers that mean "this module reads the request's tenant scope". A
  # `:global` classification has to survive them.
  @scope_markers ~w(scope_opts( current_workspace workspace_id)

  # ── THE CENSUS ────────────────────────────────────────────────────────────
  #
  # Every route mounted on the flat `/v1` or `/api` surface whose pipeline
  # includes `:api` — the pipeline the defect lived on — classified
  # `:workspace_derived` (the route's tenant comes from the caller's credential:
  # the pipeline's `:current_workspace`, an explicitly authorized param, or the
  # row's own binding) or `:global` (the controller legitimately reads no tenant
  # rows), with the reason.
  @census %{
    # LegacyController.index
    {"GET", "/api/documents/:type"} =>
      {:workspace_derived,
       "threads ScopeHelpers.scope_opts/1 into every store call, so the rows are the " <>
         "pipeline-derived :current_workspace's — which DeriveWorkspaceFromToken now fills " <>
         "from the token before AssignDefaultScope can stamp Default."},
    # LegacyController.create
    {"POST", "/api/documents/:type"} =>
      {:workspace_derived,
       "threads ScopeHelpers.scope_opts/1 into every store call, so the rows are the " <>
         "pipeline-derived :current_workspace's — which DeriveWorkspaceFromToken now fills " <>
         "from the token before AssignDefaultScope can stamp Default."},
    # LegacyController.delete
    {"DELETE", "/api/documents/:type/:id"} =>
      {:workspace_derived,
       "threads ScopeHelpers.scope_opts/1 into every store call, so the rows are the " <>
         "pipeline-derived :current_workspace's — which DeriveWorkspaceFromToken now fills " <>
         "from the token before AssignDefaultScope can stamp Default."},
    # LegacyController.show
    {"GET", "/api/documents/:type/:id"} =>
      {:workspace_derived,
       "threads ScopeHelpers.scope_opts/1 into every store call, so the rows are the " <>
         "pipeline-derived :current_workspace's — which DeriveWorkspaceFromToken now fills " <>
         "from the token before AssignDefaultScope can stamp Default."},
    # PlaygroundController.provision
    {"POST", "/api/playground"} =>
      {:global,
       "instance-level provisioning, reads no existing tenant row: " <>
         "Tenancy.create_workspace_with_owner/2 CREATES a brand-new disposable workspace and " <>
         "Auth.create_token/5 mints a token bound to it. Every `workspace_id` and `scope_opts` " <>
         "occurrence in this source names the workspace it just created (the showcase-paper " <>
         "seed), so the pipeline-derived scope is irrelevant here. Admin-gated by " <>
         ":require_admin."},
    # LegacyController.schemas
    {"GET", "/api/schemas"} =>
      {:workspace_derived,
       "threads ScopeHelpers.scope_opts/1 into every store call, so the rows are the " <>
         "pipeline-derived :current_workspace's — which DeriveWorkspaceFromToken now fills " <>
         "from the token before AssignDefaultScope can stamp Default."},
    # WorkspaceController.index
    {"GET", "/api/workspaces"} =>
      {:workspace_derived,
       "membership-derived: Tenancy.list_workspaces_for/1 takes the bearer, so the caller " <>
         "sees only the workspaces it is a member of. :current_workspace is never read."},
    # WorkspaceController.create
    {"POST", "/api/workspaces"} =>
      {:global,
       "creates a NEW workspace owned by the bearer and reads no existing tenant row — the " <>
         "derived scope has nothing to govern. The `workspace_id` occurrences in this source " <>
         "belong to sibling slug-derived actions and to render_workspace/1. Named in " <>
         "task-a87a3346b8ff736a as writable by a read-only token; now write-gated by " <>
         "RequireWriteForMutation on :require_token, probed live below."},
    # WorkspaceController.delete
    {"DELETE", "/api/workspaces/:workspace_slug"} =>
      {:workspace_derived,
       "slug-derived + membership-checked: the workspace comes from the URL slug through " <>
         "Tenancy.get_workspace_by_slug/1 and the caller must clear TenancyAuth.member?/2, " <>
         "authorize/3 or workspace_admin?/2 against THAT row. :current_workspace is never " <>
         "read."},
    # WorkspaceController.export
    {"GET", "/api/workspaces/:workspace_slug/export"} =>
      {:workspace_derived,
       "slug-derived + membership-checked: the workspace comes from the URL slug through " <>
         "Tenancy.get_workspace_by_slug/1 and the caller must clear TenancyAuth.member?/2, " <>
         "authorize/3 or workspace_admin?/2 against THAT row. :current_workspace is never " <>
         "read."},
    # WorkspaceController.import
    {"POST", "/api/workspaces/:workspace_slug/import"} =>
      {:workspace_derived,
       "slug-derived + membership-checked: the workspace comes from the URL slug through " <>
         "Tenancy.get_workspace_by_slug/1 and the caller must clear TenancyAuth.member?/2, " <>
         "authorize/3 or workspace_admin?/2 against THAT row. :current_workspace is never " <>
         "read."},
    # MediaController.put_blob
    {"PUT", "/api/workspaces/:workspace_slug/media/blob/*path"} =>
      {:workspace_derived,
       "slug-derived + membership-checked (TenancyAuth.member?/2 against the URL's " <>
         "workspace, BEFORE the body is buffered) and the key is re-bound by Media.put_blob/3, " <>
         "so an admin of B naming B still cannot address a key A owns."},
    # WorkspaceController.projects
    {"GET", "/api/workspaces/:workspace_slug/projects"} =>
      {:workspace_derived,
       "slug-derived + membership-checked: the workspace comes from the URL slug through " <>
         "Tenancy.get_workspace_by_slug/1 and the caller must clear TenancyAuth.member?/2, " <>
         "authorize/3 or workspace_admin?/2 against THAT row. :current_workspace is never " <>
         "read."},
    # WorkspaceController.create_project
    {"POST", "/api/workspaces/:workspace_slug/projects"} =>
      {:workspace_derived,
       "slug-derived + membership-checked: the workspace comes from the URL slug through " <>
         "Tenancy.get_workspace_by_slug/1 and the caller must clear TenancyAuth.member?/2, " <>
         "authorize/3 or workspace_admin?/2 against THAT row. :current_workspace is never " <>
         "read."},
    # WorkspaceController.datasets
    {"GET", "/api/workspaces/:workspace_slug/projects/:project_slug/datasets"} =>
      {:workspace_derived,
       "slug-derived + membership-checked: the workspace comes from the URL slug through " <>
         "Tenancy.get_workspace_by_slug/1 and the caller must clear TenancyAuth.member?/2, " <>
         "authorize/3 or workspace_admin?/2 against THAT row. :current_workspace is never " <>
         "read."},
    # AccessController.index
    {"GET", "/v1/access"} =>
      {:workspace_derived,
       "param/row-derived: the workspace comes from `?workspace_id=` or from the grant row, " <>
         "and Auth.authorize/3 must pass against THAT id before any row is read or written. " <>
         ":current_workspace is never consulted, so the Default-stamping defect could not " <>
         "reach these routes."},
    # AccessController.mint
    {"POST", "/v1/access"} =>
      {:workspace_derived,
       "param/row-derived: the workspace comes from `?workspace_id=` or from the grant row, " <>
         "and Auth.authorize/3 must pass against THAT id before any row is read or written. " <>
         ":current_workspace is never consulted, so the Default-stamping defect could not " <>
         "reach these routes."},
    # AccessController.revoke
    {"DELETE", "/v1/access/:id"} =>
      {:workspace_derived,
       "param/row-derived: the workspace comes from `?workspace_id=` or from the grant row, " <>
         "and Auth.authorize/3 must pass against THAT id before any row is read or written. " <>
         ":current_workspace is never consulted, so the Default-stamping defect could not " <>
         "reach these routes."},
    # AccessController.show
    {"GET", "/v1/access/:id"} =>
      {:workspace_derived,
       "param/row-derived: the workspace comes from `?workspace_id=` or from the grant row, " <>
         "and Auth.authorize/3 must pass against THAT id before any row is read or written. " <>
         ":current_workspace is never consulted, so the Default-stamping defect could not " <>
         "reach these routes."},
    # SelfUpdateController.rollback
    {"POST", "/v1/admin/rollback"} =>
      {:global,
       "instance-operational, no tenant rows: drives Barkpark.SelfUpdate.Runner — this box's " <>
         "own update and rollback executor. Source carries no scope marker at all."},
    # SelfUpdateController.status
    {"GET", "/v1/admin/self-update"} =>
      {:global,
       "instance-operational, no tenant rows: drives Barkpark.SelfUpdate.Runner — this box's " <>
         "own update and rollback executor. Source carries no scope marker at all."},
    # SelfUpdateController.trigger
    {"POST", "/v1/admin/self-update"} =>
      {:global,
       "instance-operational, no tenant rows: drives Barkpark.SelfUpdate.Runner — this box's " <>
         "own update and rollback executor. Source carries no scope marker at all."},
    # SiteDeployController.status
    {"GET", "/v1/admin/site-deploy"} =>
      {:global,
       "instance-operational, no tenant rows: drives Barkpark.Sites.DeployRunner for one " <>
         "SITE SLUG on this box; a slug is a deploy target, not a tenant. Source carries no " <>
         "scope marker at all."},
    # SiteDeployController.trigger
    {"POST", "/v1/admin/site-deploy"} =>
      {:global,
       "instance-operational, no tenant rows: drives Barkpark.Sites.DeployRunner for one " <>
         "SITE SLUG on this box; a slug is a deploy target, not a tenant. Source carries no " <>
         "scope marker at all."},
    # AppTokenController.delete
    {"DELETE", "/v1/auth/app-tokens"} =>
      {:workspace_derived,
       "credential-derived: Auth.list_app_tokens/2, revoke_app_token_by_id/2 and " <>
         "revoke_app_tokens_for_email/2 take the BEARER as the selector and confine to the " <>
         "workspaces it administers (task-ea8cae3258ea4bd3); delete_current is self-revoke, " <>
         "where possession is the authorization."},
    # AppTokenController.index
    {"GET", "/v1/auth/app-tokens"} =>
      {:workspace_derived,
       "credential-derived: Auth.list_app_tokens/2, revoke_app_token_by_id/2 and " <>
         "revoke_app_tokens_for_email/2 take the BEARER as the selector and confine to the " <>
         "workspaces it administers (task-ea8cae3258ea4bd3); delete_current is self-revoke, " <>
         "where possession is the authorization."},
    # AppTokenController.create
    {"POST", "/v1/auth/app-tokens"} =>
      {:workspace_derived,
       "param-derived + global-admin-gated: the `workspace` body field (slug or id) is " <>
         "resolved explicitly and DEFAULTS to the Default Workspace; " <>
         "Auth.has_permission?(token, \"admin\") must pass first. :current_workspace is never " <>
         "read. Stated plainly because the default has the same SHAPE as the defect this " <>
         "census follows — it is admin-only, and admin is instance-wide in this codebase."},
    # AppTokenController.delete_by_id
    {"DELETE", "/v1/auth/app-tokens/:id"} =>
      {:workspace_derived,
       "credential-derived: Auth.list_app_tokens/2, revoke_app_token_by_id/2 and " <>
         "revoke_app_tokens_for_email/2 take the BEARER as the selector and confine to the " <>
         "workspaces it administers (task-ea8cae3258ea4bd3); delete_current is self-revoke, " <>
         "where possession is the authorization."},
    # AppTokenController.delete_current
    {"DELETE", "/v1/auth/app-tokens/current"} =>
      {:workspace_derived,
       "credential-derived: Auth.list_app_tokens/2, revoke_app_token_by_id/2 and " <>
         "revoke_app_tokens_for_email/2 take the BEARER as the selector and confine to the " <>
         "workspaces it administers (task-ea8cae3258ea4bd3); delete_current is self-revoke, " <>
         "where possession is the authorization."},
    # LoginTicketController.create
    {"POST", "/v1/auth/login-tickets"} =>
      {:global,
       "no tenant rows: Auth.mint_login_ticket/2 binds a single-use ticket to the caller's " <>
         "OWN raw bearer, so consuming it yields exactly the tenancy the caller already " <>
         "presented. Source carries no scope marker at all."},
    # CapabilitiesController.index
    {"GET", "/v1/capabilities"} =>
      {:global,
       "instance manifest, not tenant rows: Capabilities.tier_for_token/1 maps the optional " <>
         "bearer to one of six tiers and the body enumerates COMMANDS and NOUNS. Source " <>
         "carries no scope marker at all."},
    # ChatHostController.enroll
    {"POST", "/v1/chat-host/enroll"} =>
      {:workspace_derived,
       "enrollment-token-derived: the route is anonymous by design (pipeline :api alone) and " <>
         "ChatHosts.enroll/2 resolves a single-use enrollment token that CARRIES its workspace " <>
         "binding. The current_workspace/workspace_id occurrences in this module belong to its " <>
         "sibling scoped actions, which do not ride this pipeline."},
    # ChatController.fleet_events
    {"GET", "/v1/chat/events"} =>
      {:workspace_derived,
       "chat_scope-derived: Plugs.RequireChatAccess resolves conn.assigns.chat_scope from " <>
         "the token (:global for a global-admin token, {:workspace, ws} for a workspace-bound " <>
         "chat token) and the StudioChat store confines every read to it — a foreign session " <>
         "is a 404, never a 403 oracle."},
    # ChatController.rollup
    {"GET", "/v1/chat/rollup"} =>
      {:workspace_derived,
       "chat_scope-derived: Plugs.RequireChatAccess resolves conn.assigns.chat_scope from " <>
         "the token (:global for a global-admin token, {:workspace, ws} for a workspace-bound " <>
         "chat token) and the StudioChat store confines every read to it — a foreign session " <>
         "is a 404, never a 403 oracle."},
    # ChatController.index
    {"GET", "/v1/chat/sessions"} =>
      {:workspace_derived,
       "chat_scope-derived: Plugs.RequireChatAccess resolves conn.assigns.chat_scope from " <>
         "the token (:global for a global-admin token, {:workspace, ws} for a workspace-bound " <>
         "chat token) and the StudioChat store confines every read to it — a foreign session " <>
         "is a 404, never a 403 oracle."},
    # ChatController.create
    {"POST", "/v1/chat/sessions"} =>
      {:workspace_derived,
       "chat_scope-derived: Plugs.RequireChatAccess resolves conn.assigns.chat_scope from " <>
         "the token (:global for a global-admin token, {:workspace, ws} for a workspace-bound " <>
         "chat token) and the StudioChat store confines every read to it — a foreign session " <>
         "is a 404, never a 403 oracle."},
    # ChatController.show
    {"GET", "/v1/chat/sessions/:id"} =>
      {:workspace_derived,
       "chat_scope-derived: Plugs.RequireChatAccess resolves conn.assigns.chat_scope from " <>
         "the token (:global for a global-admin token, {:workspace, ws} for a workspace-bound " <>
         "chat token) and the StudioChat store confines every read to it — a foreign session " <>
         "is a 404, never a 403 oracle."},
    # ChatController.update
    {"PATCH", "/v1/chat/sessions/:id"} =>
      {:workspace_derived,
       "chat_scope-derived: Plugs.RequireChatAccess resolves conn.assigns.chat_scope from " <>
         "the token (:global for a global-admin token, {:workspace, ws} for a workspace-bound " <>
         "chat token) and the StudioChat store confines every read to it — a foreign session " <>
         "is a 404, never a 403 oracle."},
    # ChatController.approval
    {"POST", "/v1/chat/sessions/:id/approval"} =>
      {:workspace_derived,
       "chat_scope-derived: Plugs.RequireChatAccess resolves conn.assigns.chat_scope from " <>
         "the token (:global for a global-admin token, {:workspace, ws} for a workspace-bound " <>
         "chat token) and the StudioChat store confines every read to it — a foreign session " <>
         "is a 404, never a 403 oracle."},
    # ChatController.archive
    {"POST", "/v1/chat/sessions/:id/archive"} =>
      {:workspace_derived,
       "chat_scope-derived: Plugs.RequireChatAccess resolves conn.assigns.chat_scope from " <>
         "the token (:global for a global-admin token, {:workspace, ws} for a workspace-bound " <>
         "chat token) and the StudioChat store confines every read to it — a foreign session " <>
         "is a 404, never a 403 oracle."},
    # ChatController.events
    {"GET", "/v1/chat/sessions/:id/events"} =>
      {:workspace_derived,
       "chat_scope-derived: Plugs.RequireChatAccess resolves conn.assigns.chat_scope from " <>
         "the token (:global for a global-admin token, {:workspace, ws} for a workspace-bound " <>
         "chat token) and the StudioChat store confines every read to it — a foreign session " <>
         "is a 404, never a 403 oracle."},
    # ChatController.interrupt
    {"POST", "/v1/chat/sessions/:id/interrupt"} =>
      {:workspace_derived,
       "chat_scope-derived: Plugs.RequireChatAccess resolves conn.assigns.chat_scope from " <>
         "the token (:global for a global-admin token, {:workspace, ws} for a workspace-bound " <>
         "chat token) and the StudioChat store confines every read to it — a foreign session " <>
         "is a 404, never a 403 oracle."},
    # ChatController.create_message
    {"POST", "/v1/chat/sessions/:id/messages"} =>
      {:workspace_derived,
       "chat_scope-derived: Plugs.RequireChatAccess resolves conn.assigns.chat_scope from " <>
         "the token (:global for a global-admin token, {:workspace, ws} for a workspace-bound " <>
         "chat token) and the StudioChat store confines every read to it — a foreign session " <>
         "is a 404, never a 403 oracle."},
    # ChatController.unarchive
    {"POST", "/v1/chat/sessions/:id/unarchive"} =>
      {:workspace_derived,
       "chat_scope-derived: Plugs.RequireChatAccess resolves conn.assigns.chat_scope from " <>
         "the token (:global for a global-admin token, {:workspace, ws} for a workspace-bound " <>
         "chat token) and the StudioChat store confines every read to it — a foreign session " <>
         "is a 404, never a 403 oracle."},
    # AnalyticsController.index
    {"GET", "/v1/data/analytics/:dataset"} =>
      {:workspace_derived,
       "threads ScopeHelpers.scope_opts/1 into every store call, so the rows are the " <>
         "pipeline-derived :current_workspace's — which DeriveWorkspaceFromToken now fills " <>
         "from the token before AssignDefaultScope can stamp Default."},
    # QueryController.backlinks
    {"GET", "/v1/data/backlinks/:dataset/:id"} =>
      {:workspace_derived,
       "threads ScopeHelpers.scope_opts/1 into every store call, so the rows are the " <>
         "pipeline-derived :current_workspace's — which DeriveWorkspaceFromToken now fills " <>
         "from the token before AssignDefaultScope can stamp Default."},
    # QueryController.counts
    {"GET", "/v1/data/counts/:dataset"} =>
      {:workspace_derived,
       "the ORIGINAL leak in task-28c3f7f0987d6e85: GET /v1/data/counts/:dataset answered a " <>
         "workspace-B token with the Default Workspace's whole census. counts/2 threads " <>
         "ScopeHelpers.scope_opts/1; the fix was upstream, in the pipeline. Pinned by " <>
         "flat_alias_tenancy_test.exs."},
    # QueryController.show
    {"GET", "/v1/data/doc/:dataset/:type/:doc_id"} =>
      {:workspace_derived,
       "threads ScopeHelpers.scope_opts/1 into every store call, so the rows are the " <>
         "pipeline-derived :current_workspace's — which DeriveWorkspaceFromToken now fills " <>
         "from the token before AssignDefaultScope can stamp Default."},
    # ExportController.export
    {"GET", "/v1/data/export/:dataset"} =>
      {:workspace_derived,
       "threads ScopeHelpers.scope_opts/1 into every store call, so the rows are the " <>
         "pipeline-derived :current_workspace's — which DeriveWorkspaceFromToken now fills " <>
         "from the token before AssignDefaultScope can stamp Default."},
    # HistoryController.index
    {"GET", "/v1/data/history/:dataset/:type/:doc_id"} =>
      {:workspace_derived,
       "threads ScopeHelpers.scope_opts/1 into every store call, so the rows are the " <>
         "pipeline-derived :current_workspace's — which DeriveWorkspaceFromToken now fills " <>
         "from the token before AssignDefaultScope can stamp Default."},
    # ListenController.listen
    {"GET", "/v1/data/listen/:dataset"} =>
      {:workspace_derived,
       "threads ScopeHelpers.scope_opts/1 AND filters the live SSE stream with " <>
         "forward_event?/2 on the resolved workspace_id, so a broadcast from another tenant is " <>
         "dropped before it reaches the socket."},
    # MutateController.mutate
    {"POST", "/v1/data/mutate/:dataset"} =>
      {:workspace_derived,
       "threads ScopeHelpers.scope_opts/1 into every store call, so the rows are the " <>
         "pipeline-derived :current_workspace's — which DeriveWorkspaceFromToken now fills " <>
         "from the token before AssignDefaultScope can stamp Default."},
    # QueryController.index
    {"GET", "/v1/data/query/:dataset/:type"} =>
      {:workspace_derived,
       "threads ScopeHelpers.scope_opts/1 into every store call, so the rows are the " <>
         "pipeline-derived :current_workspace's — which DeriveWorkspaceFromToken now fills " <>
         "from the token before AssignDefaultScope can stamp Default."},
    # QueryController.related
    {"GET", "/v1/data/related/:dataset/:id"} =>
      {:workspace_derived,
       "threads ScopeHelpers.scope_opts/1 into every store call, so the rows are the " <>
         "pipeline-derived :current_workspace's — which DeriveWorkspaceFromToken now fills " <>
         "from the token before AssignDefaultScope can stamp Default."},
    # HistoryController.show
    {"GET", "/v1/data/revision/:dataset/:id"} =>
      {:workspace_derived,
       "threads ScopeHelpers.scope_opts/1 into every store call, so the rows are the " <>
         "pipeline-derived :current_workspace's — which DeriveWorkspaceFromToken now fills " <>
         "from the token before AssignDefaultScope can stamp Default."},
    # HistoryController.restore
    {"POST", "/v1/data/revision/:dataset/:id/restore"} =>
      {:workspace_derived,
       "threads ScopeHelpers.scope_opts/1 into every store call, so the rows are the " <>
         "pipeline-derived :current_workspace's — which DeriveWorkspaceFromToken now fills " <>
         "from the token before AssignDefaultScope can stamp Default."},
    # SearchController.search
    {"GET", "/v1/data/search/:dataset"} =>
      {:workspace_derived,
       "threads ScopeHelpers.scope_opts/1 into every store call, so the rows are the " <>
         "pipeline-derived :current_workspace's — which DeriveWorkspaceFromToken now fills " <>
         "from the token before AssignDefaultScope can stamp Default."},
    # SearchController.correction
    {"POST", "/v1/data/search/:dataset/correction"} =>
      {:workspace_derived,
       "threads ScopeHelpers.scope_opts/1 into every store call, so the rows are the " <>
         "pipeline-derived :current_workspace's — which DeriveWorkspaceFromToken now fills " <>
         "from the token before AssignDefaultScope can stamp Default."},
    # SearchController.search_interaction
    {"POST", "/v1/data/search/:dataset/interaction"} =>
      {:workspace_derived,
       "threads ScopeHelpers.scope_opts/1 into every store call, so the rows are the " <>
         "pipeline-derived :current_workspace's — which DeriveWorkspaceFromToken now fills " <>
         "from the token before AssignDefaultScope can stamp Default."},
    # SearchController.reindex
    {"POST", "/v1/data/search/:dataset/reindex"} =>
      {:workspace_derived,
       "threads ScopeHelpers.scope_opts/1 into every store call, so the rows are the " <>
         "pipeline-derived :current_workspace's — which DeriveWorkspaceFromToken now fills " <>
         "from the token before AssignDefaultScope can stamp Default."},
    # SearchController.search_suggestions
    {"GET", "/v1/data/search/:dataset/suggestions"} =>
      {:workspace_derived,
       "threads ScopeHelpers.scope_opts/1 into every store call, so the rows are the " <>
         "pipeline-derived :current_workspace's — which DeriveWorkspaceFromToken now fills " <>
         "from the token before AssignDefaultScope can stamp Default."},
    # QueryController.tag_browse
    {"GET", "/v1/data/tags/:dataset"} =>
      {:workspace_derived,
       "threads ScopeHelpers.scope_opts/1 into every store call, so the rows are the " <>
         "pipeline-derived :current_workspace's — which DeriveWorkspaceFromToken now fills " <>
         "from the token before AssignDefaultScope can stamp Default."},
    # QueryController.tag_docs
    {"GET", "/v1/data/tags/:dataset/:tag"} =>
      {:workspace_derived,
       "threads ScopeHelpers.scope_opts/1 into every store call, so the rows are the " <>
         "pipeline-derived :current_workspace's — which DeriveWorkspaceFromToken now fills " <>
         "from the token before AssignDefaultScope can stamp Default."},
    # TasksController.fleet_beat
    {"POST", "/v1/fleet/beat"} =>
      {:workspace_derived,
       "threads ScopeHelpers.scope_opts/1 into every store call, so the rows are the " <>
         "pipeline-derived :current_workspace's — which DeriveWorkspaceFromToken now fills " <>
         "from the token before AssignDefaultScope can stamp Default."},
    # TasksController.fleet_roster
    {"GET", "/v1/fleet/roster"} =>
      {:workspace_derived,
       "PIPELINE-DERIVED BUT CONTROLLER IGNORES IT — filed as task-4e2986e8609670d7. " <>
         "fleet_roster/2 calls Fleet.roster/2 with the DATASET only; Fleet.load_listeners/1 " <>
         "and Fleet.current_tasks_by_worker/1 query Document by type+dataset with NO workspace " <>
         "clause, so every workspace's listener rows and in-progress task ids come back to any " <>
         "bearer. Fleet.beat/3 on the same controller DOES pass scope_opts/1 — the asymmetry " <>
         "is the tell. The pipeline fix cannot reach this: the controller never reads " <>
         ":current_workspace."},
    # TasksController.graph_corpus
    {"GET", "/v1/graph"} =>
      {:workspace_derived,
       "threads ScopeHelpers.scope_opts/1 into every store call, so the rows are the " <>
         "pipeline-derived :current_workspace's — which DeriveWorkspaceFromToken now fills " <>
         "from the token before AssignDefaultScope can stamp Default."},
    # TasksController.graph_show
    {"GET", "/v1/graph/:id"} =>
      {:workspace_derived,
       "threads ScopeHelpers.scope_opts/1 into every store call, so the rows are the " <>
         "pipeline-derived :current_workspace's — which DeriveWorkspaceFromToken now fills " <>
         "from the token before AssignDefaultScope can stamp Default."},
    # TasksController.graph_tasks
    {"GET", "/v1/graph/:id/tasks"} =>
      {:workspace_derived,
       "threads ScopeHelpers.scope_opts/1 into every store call, so the rows are the " <>
         "pipeline-derived :current_workspace's — which DeriveWorkspaceFromToken now fills " <>
         "from the token before AssignDefaultScope can stamp Default."},
    # TasksController.graph_dangling
    {"GET", "/v1/graph/dangling"} =>
      {:workspace_derived,
       "threads ScopeHelpers.scope_opts/1 into every store call, so the rows are the " <>
         "pipeline-derived :current_workspace's — which DeriveWorkspaceFromToken now fills " <>
         "from the token before AssignDefaultScope can stamp Default."},
    # TasksController.graph_orphans
    {"GET", "/v1/graph/orphans"} =>
      {:workspace_derived,
       "threads ScopeHelpers.scope_opts/1 into every store call, so the rows are the " <>
         "pipeline-derived :current_workspace's — which DeriveWorkspaceFromToken now fills " <>
         "from the token before AssignDefaultScope can stamp Default."},
    # MetricsController.scrape
    {"GET", "/v1/instance/metrics"} =>
      {:global,
       "instance-operational, no tenant rows: Prometheus text exposition of this BEAM's own " <>
         "telemetry aggregates out of ETS. The CONTROLLER PATH is tenant-blind — it calls no " <>
         "scope_opts/1 and reads no :current_workspace — so :global still holds for the " <>
         "route's own scope handling. The `workspace_id` this source carries is MODULEDOC, " <>
         "not a read: it names the four series that carry a :workspace_id Prometheus LABEL " <>
         "(content.mutate.stop.duration, search.query.stop.duration, " <>
         "content.lifecycle.stop.duration, media.mutate.count), so ONE scrape enumerates the " <>
         "box's workspace roster plus each tenant's write/search/publish volume. Tenant " <>
         "identifiers ride the LABEL SET even though no tenant row rides the body — which is " <>
         "why PR #14793 moved this route onto [:api, :require_admin]. The route is global; " <>
         "the PAYLOAD is not, and the gate for that is admission, not scope. Operator-tier " <>
         "home: task-c7e2b87f1bbca815."},
    # RequestStatsController.show
    {"GET", "/v1/instance/request-stats"} =>
      {:global,
       "instance-operational, no tenant rows: the rolling request throughput/latency/5xx " <>
         "window from BarkparkWeb.RequestStats. Source carries no scope marker at all."},
    # InstanceSiteDeployController.show
    {"GET", "/v1/instance/site-deploy"} =>
      {:global,
       "admin-gated since PR #14793 ([:api, :require_admin]) because door.in_flight_slugs " <>
         "names OTHER tenants' sites — the payload crosses tenants even though the read does " <>
         "not, same shape as /v1/instance/metrics above; operator-tier home " <>
         "task-c7e2b87f1bbca815. Still :global on the route's own scope handling: " <>
         "instance-operational, no tenant rows: a capability probe over " <>
         "DeployRunner.enabled?/0, Process.whereis/1, door_census/0 and ServingMemory.read/1. " <>
         "Source carries no scope marker at all."},
    # V1.MediaController.index
    {"GET", "/v1/media/:dataset"} =>
      {:workspace_derived,
       "threads ScopeHelpers.scope_opts/1 into every store call, so the rows are the " <>
         "pipeline-derived :current_workspace's — which DeriveWorkspaceFromToken now fills " <>
         "from the token before AssignDefaultScope can stamp Default."},
    # V1.MediaController.show
    {"GET", "/v1/media/:dataset/:id"} =>
      {:workspace_derived,
       "threads ScopeHelpers.scope_opts/1 into every store call, so the rows are the " <>
         "pipeline-derived :current_workspace's — which DeriveWorkspaceFromToken now fills " <>
         "from the token before AssignDefaultScope can stamp Default."},
    # V1.MediaController.relations
    {"GET", "/v1/media/:dataset/:id/relations"} =>
      {:workspace_derived,
       "threads ScopeHelpers.scope_opts/1 into every store call, so the rows are the " <>
         "pipeline-derived :current_workspace's — which DeriveWorkspaceFromToken now fills " <>
         "from the token before AssignDefaultScope can stamp Default."},
    # V1.MediaCollectionsController.index
    {"GET", "/v1/media/:dataset/collections"} =>
      {:workspace_derived,
       "threads ScopeHelpers.scope_opts/1 into every store call, so the rows are the " <>
         "pipeline-derived :current_workspace's — which DeriveWorkspaceFromToken now fills " <>
         "from the token before AssignDefaultScope can stamp Default."},
    # V1.MediaCollectionsController.show
    {"GET", "/v1/media/:dataset/collections/:id"} =>
      {:workspace_derived,
       "threads ScopeHelpers.scope_opts/1 into every store call, so the rows are the " <>
         "pipeline-derived :current_workspace's — which DeriveWorkspaceFromToken now fills " <>
         "from the token before AssignDefaultScope can stamp Default."},
    # V1.MediaCollectionsController.assets
    {"GET", "/v1/media/:dataset/collections/:id/assets"} =>
      {:workspace_derived,
       "threads ScopeHelpers.scope_opts/1 into every store call, so the rows are the " <>
         "pipeline-derived :current_workspace's — which DeriveWorkspaceFromToken now fills " <>
         "from the token before AssignDefaultScope can stamp Default."},
    # V1.MediaController.search
    {"GET", "/v1/media/:dataset/search"} =>
      {:workspace_derived,
       "threads ScopeHelpers.scope_opts/1 into every store call, so the rows are the " <>
         "pipeline-derived :current_workspace's — which DeriveWorkspaceFromToken now fills " <>
         "from the token before AssignDefaultScope can stamp Default."},
    # V1.MediaController.search_interaction
    {"POST", "/v1/media/:dataset/search/interaction"} =>
      {:workspace_derived,
       "threads ScopeHelpers.scope_opts/1 into every store call, so the rows are the " <>
         "pipeline-derived :current_workspace's — which DeriveWorkspaceFromToken now fills " <>
         "from the token before AssignDefaultScope can stamp Default."},
    # V1.MediaController.search_suggestions
    {"GET", "/v1/media/:dataset/search/suggestions"} =>
      {:workspace_derived,
       "threads ScopeHelpers.scope_opts/1 into every store call, so the rows are the " <>
         "pipeline-derived :current_workspace's — which DeriveWorkspaceFromToken now fills " <>
         "from the token before AssignDefaultScope can stamp Default."},
    # V1.MediaCollectionsController.share_view
    {"GET", "/v1/media/:dataset/share/:token"} =>
      {:workspace_derived,
       "share-token-derived, deliberately NOT scope_opts(conn): the collection is resolved " <>
         "from the opaque share token and share_scope_opts/1 takes the tenant from the " <>
         "COLLECTION ROW's own workspace_id/project_id, falling back to a :shared_only " <>
         "sentinel."},
    # PluginsController.index
    {"GET", "/v1/plugins"} =>
      {:global,
       "instance roster, no tenant rows: Plugins.Registry.all/0 lists INSTALLED CODE. Source " <>
         "carries no scope marker at all."},
    # GithubAdoptController.adopt
    {"POST", "/v1/plugins/github/adopt/:id"} =>
      {:workspace_derived,
       "threads ScopeHelpers.scope_opts/1 into every store call, so the rows are the " <>
         "pipeline-derived :current_workspace's — which DeriveWorkspaceFromToken now fills " <>
         "from the token before AssignDefaultScope can stamp Default."},
    # GithubStatusController.status
    {"GET", "/v1/plugins/github/status"} =>
      {:workspace_derived,
       "DATASET-derived, not workspace-derived, and deliberately so: effective_dataset/2 " <>
         "pins the health snapshot to the bearer's OWN api_token.dataset because — the " <>
         "moduledoc says it outright — a scope helper here would read the " <>
         "AssignDefaultScope-seeded Default. KNOWN RESIDUAL: two workspaces sharing the " <>
         "`production` dataset share this read; true per-workspace isolation needs a " <>
         "workspace_id column and is tracked as github-bridge-w9-health-workspace-isolation."},
    # OnixEdit.Web.ExportController.show
    {"GET", "/v1/plugins/onixedit/export/:dataset/:id"} =>
      {:workspace_derived,
       "threads ScopeHelpers.scope_opts/1 into every store call, so the rows are the " <>
         "pipeline-derived :current_workspace's — which DeriveWorkspaceFromToken now fills " <>
         "from the token before AssignDefaultScope can stamp Default."},
    # PluginSettingsController.delete
    {"DELETE", "/v1/plugins/settings/:plugin_name"} =>
      {:global,
       "instance settings keyed on the ADMIN TOKEN's own id (Settings.get/put/delete take " <>
         "user_id:); the plugin_settings table has no workspace column. Source carries no " <>
         "scope marker at all."},
    # PluginSettingsController.show
    {"GET", "/v1/plugins/settings/:plugin_name"} =>
      {:global,
       "instance settings keyed on the ADMIN TOKEN's own id (Settings.get/put/delete take " <>
         "user_id:); the plugin_settings table has no workspace column. Source carries no " <>
         "scope marker at all."},
    # PluginSettingsController.update
    {"PUT", "/v1/plugins/settings/:plugin_name"} =>
      {:global,
       "instance settings keyed on the ADMIN TOKEN's own id (Settings.get/put/delete take " <>
         "user_id:); the plugin_settings table has no workspace column. Source carries no " <>
         "scope marker at all."},
    # TicketKeysController.index
    {"GET", "/v1/plugins/tickets/keys"} =>
      {:workspace_derived,
       "workspace-derived through current_workspace_id/1, which reads " <>
         "conn.assigns[:current_workspace] — exactly the assign DeriveWorkspaceFromToken now " <>
         "fills from the token."},
    # TicketKeysController.create
    {"POST", "/v1/plugins/tickets/keys"} =>
      {:workspace_derived,
       "workspace-derived through current_workspace_id/1, which reads " <>
         "conn.assigns[:current_workspace] — exactly the assign DeriveWorkspaceFromToken now " <>
         "fills from the token."},
    # TicketKeysController.delete
    {"DELETE", "/v1/plugins/tickets/keys/:id"} =>
      {:workspace_derived,
       "workspace-derived through current_workspace_id/1, which reads " <>
         "conn.assigns[:current_workspace] — exactly the assign DeriveWorkspaceFromToken now " <>
         "fills from the token."},
    # TicketKeysController.pause
    {"POST", "/v1/plugins/tickets/keys/:id/pause"} =>
      {:workspace_derived,
       "workspace-derived through current_workspace_id/1, which reads " <>
         "conn.assigns[:current_workspace] — exactly the assign DeriveWorkspaceFromToken now " <>
         "fills from the token."},
    # TicketKeysController.rotate
    {"POST", "/v1/plugins/tickets/keys/:id/rotate"} =>
      {:workspace_derived,
       "workspace-derived through current_workspace_id/1, which reads " <>
         "conn.assigns[:current_workspace] — exactly the assign DeriveWorkspaceFromToken now " <>
         "fills from the token."},
    # TicketKeysController.unpause
    {"POST", "/v1/plugins/tickets/keys/:id/unpause"} =>
      {:workspace_derived,
       "workspace-derived through current_workspace_id/1, which reads " <>
         "conn.assigns[:current_workspace] — exactly the assign DeriveWorkspaceFromToken now " <>
         "fills from the token."},
    # FederatedSearchController.search
    {"GET", "/v1/search/:dataset"} =>
      {:workspace_derived,
       "threads ScopeHelpers.scope_opts/1 into every store call, so the rows are the " <>
         "pipeline-derived :current_workspace's — which DeriveWorkspaceFromToken now fills " <>
         "from the token before AssignDefaultScope can stamp Default."},
    # SecretController.index
    {"GET", "/v1/secrets"} =>
      {:global,
       "the FLAT tier IS the global tier, by construction and on purpose. secret_scope/1 " <>
         "pins a request with no :workspace_slug path param to :global — an explicit " <>
         "`workspace_id IS NULL` arm, never all-rows — and DELIBERATELY does not read " <>
         ":current_workspace, which AssignDefaultScope would have seeded with the Default " <>
         "workspace. The per-workspace tier is the scoped /w/:ws/p/:proj twin on " <>
         ":scoped_admin. That is why `current_workspace` and `workspace_id` appear in this " <>
         "source: `current_workspace` only inside the path-param-guarded scoped branch of " <>
         "secret_scope/1, and `workspace_id` in the audit query's explicit IS-NULL and " <>
         "equality arms plus the masked audit projection."},
    # SecretController.delete
    {"DELETE", "/v1/secrets/:name"} =>
      {:global,
       "the FLAT tier IS the global tier, by construction and on purpose. secret_scope/1 " <>
         "pins a request with no :workspace_slug path param to :global — an explicit " <>
         "`workspace_id IS NULL` arm, never all-rows — and DELIBERATELY does not read " <>
         ":current_workspace, which AssignDefaultScope would have seeded with the Default " <>
         "workspace. The per-workspace tier is the scoped /w/:ws/p/:proj twin on " <>
         ":scoped_admin. That is why `current_workspace` and `workspace_id` appear in this " <>
         "source: `current_workspace` only inside the path-param-guarded scoped branch of " <>
         "secret_scope/1, and `workspace_id` in the audit query's explicit IS-NULL and " <>
         "equality arms plus the masked audit projection."},
    # SecretController.show
    {"GET", "/v1/secrets/:name"} =>
      {:global,
       "the FLAT tier IS the global tier, by construction and on purpose. secret_scope/1 " <>
         "pins a request with no :workspace_slug path param to :global — an explicit " <>
         "`workspace_id IS NULL` arm, never all-rows — and DELIBERATELY does not read " <>
         ":current_workspace, which AssignDefaultScope would have seeded with the Default " <>
         "workspace. The per-workspace tier is the scoped /w/:ws/p/:proj twin on " <>
         ":scoped_admin. That is why `current_workspace` and `workspace_id` appear in this " <>
         "source: `current_workspace` only inside the path-param-guarded scoped branch of " <>
         "secret_scope/1, and `workspace_id` in the audit query's explicit IS-NULL and " <>
         "equality arms plus the masked audit projection."},
    # SecretController.update
    {"PUT", "/v1/secrets/:name"} =>
      {:global,
       "the FLAT tier IS the global tier, by construction and on purpose. secret_scope/1 " <>
         "pins a request with no :workspace_slug path param to :global — an explicit " <>
         "`workspace_id IS NULL` arm, never all-rows — and DELIBERATELY does not read " <>
         ":current_workspace, which AssignDefaultScope would have seeded with the Default " <>
         "workspace. The per-workspace tier is the scoped /w/:ws/p/:proj twin on " <>
         ":scoped_admin. That is why `current_workspace` and `workspace_id` appear in this " <>
         "source: `current_workspace` only inside the path-param-guarded scoped branch of " <>
         "secret_scope/1, and `workspace_id` in the audit query's explicit IS-NULL and " <>
         "equality arms plus the masked audit projection."},
    # SecretController.audit
    {"GET", "/v1/secrets/:name/audit"} =>
      {:global,
       "the FLAT tier IS the global tier, by construction and on purpose. secret_scope/1 " <>
         "pins a request with no :workspace_slug path param to :global — an explicit " <>
         "`workspace_id IS NULL` arm, never all-rows — and DELIBERATELY does not read " <>
         ":current_workspace, which AssignDefaultScope would have seeded with the Default " <>
         "workspace. The per-workspace tier is the scoped /w/:ws/p/:proj twin on " <>
         ":scoped_admin. That is why `current_workspace` and `workspace_id` appear in this " <>
         "source: `current_workspace` only inside the path-param-guarded scoped branch of " <>
         "secret_scope/1, and `workspace_id` in the audit query's explicit IS-NULL and " <>
         "equality arms plus the masked audit projection."},
    # ShareController.delete
    {"DELETE", "/v1/shares"} =>
      {:workspace_derived,
       "workspace_admin?-confined: index/2 and list_tokens/2 filter rows to the workspaces " <>
         "the bearer administers (one membership lookup per DISTINCT workspace) and " <>
         "create/delete/mint_token/revoke_token resolve the target workspace first. Foreign " <>
         "rows are ABSENT, never 403. DOCUMENTED RESIDUAL: the `env` half of index/2 is left " <>
         "unclamped pending the owner ruling arpss-stored-share-registry-ruling."},
    # ShareController.index
    {"GET", "/v1/shares"} =>
      {:workspace_derived,
       "workspace_admin?-confined: index/2 and list_tokens/2 filter rows to the workspaces " <>
         "the bearer administers (one membership lookup per DISTINCT workspace) and " <>
         "create/delete/mint_token/revoke_token resolve the target workspace first. Foreign " <>
         "rows are ABSENT, never 403. DOCUMENTED RESIDUAL: the `env` half of index/2 is left " <>
         "unclamped pending the owner ruling arpss-stored-share-registry-ruling."},
    # ShareController.create
    {"POST", "/v1/shares"} =>
      {:workspace_derived,
       "workspace_admin?-confined: index/2 and list_tokens/2 filter rows to the workspaces " <>
         "the bearer administers (one membership lookup per DISTINCT workspace) and " <>
         "create/delete/mint_token/revoke_token resolve the target workspace first. Foreign " <>
         "rows are ABSENT, never 403. DOCUMENTED RESIDUAL: the `env` half of index/2 is left " <>
         "unclamped pending the owner ruling arpss-stored-share-registry-ruling."},
    # ShareLinkController.list
    {"GET", "/v1/shares/links"} =>
      {:workspace_derived,
       "row-derived: every action resolves the link (or the named workspace) first and gates " <>
         "on Links.workspace_admin?/2 against THAT row's workspace_id — never " <>
         ":current_workspace."},
    # ShareLinkController.mint
    {"POST", "/v1/shares/links"} =>
      {:workspace_derived,
       "row-derived: every action resolves the link (or the named workspace) first and gates " <>
         "on Links.workspace_admin?/2 against THAT row's workspace_id — never " <>
         ":current_workspace."},
    # ShareLinkController.revoke
    {"DELETE", "/v1/shares/links/:id"} =>
      {:workspace_derived,
       "row-derived: every action resolves the link (or the named workspace) first and gates " <>
         "on Links.workspace_admin?/2 against THAT row's workspace_id — never " <>
         ":current_workspace."},
    # ShareController.list_tokens
    {"GET", "/v1/shares/tokens"} =>
      {:workspace_derived,
       "workspace_admin?-confined: index/2 and list_tokens/2 filter rows to the workspaces " <>
         "the bearer administers (one membership lookup per DISTINCT workspace) and " <>
         "create/delete/mint_token/revoke_token resolve the target workspace first. Foreign " <>
         "rows are ABSENT, never 403. DOCUMENTED RESIDUAL: the `env` half of index/2 is left " <>
         "unclamped pending the owner ruling arpss-stored-share-registry-ruling."},
    # ShareController.mint_token
    {"POST", "/v1/shares/tokens"} =>
      {:workspace_derived,
       "workspace_admin?-confined: index/2 and list_tokens/2 filter rows to the workspaces " <>
         "the bearer administers (one membership lookup per DISTINCT workspace) and " <>
         "create/delete/mint_token/revoke_token resolve the target workspace first. Foreign " <>
         "rows are ABSENT, never 403. DOCUMENTED RESIDUAL: the `env` half of index/2 is left " <>
         "unclamped pending the owner ruling arpss-stored-share-registry-ruling."},
    # ShareController.revoke_token
    {"DELETE", "/v1/shares/tokens/:token_id"} =>
      {:workspace_derived,
       "workspace_admin?-confined: index/2 and list_tokens/2 filter rows to the workspaces " <>
         "the bearer administers (one membership lookup per DISTINCT workspace) and " <>
         "create/delete/mint_token/revoke_token resolve the target workspace first. Foreign " <>
         "rows are ABSENT, never 403. DOCUMENTED RESIDUAL: the `env` half of index/2 is left " <>
         "unclamped pending the owner ruling arpss-stored-share-registry-ruling."},
    # StatusController.create_incident
    {"POST", "/v1/status/incidents"} =>
      {:global,
       "instance-operational, no tenant rows: status-page incidents for the instance. Source " <>
         "carries no scope marker at all."},
    # StatusController.resolve_incident
    {"POST", "/v1/status/incidents/:id/resolve"} =>
      {:global,
       "instance-operational, no tenant rows: status-page incidents for the instance. Source " <>
         "carries no scope marker at all."},
    # TasksController.index
    {"GET", "/v1/tasks"} =>
      {:workspace_derived,
       "threads ScopeHelpers.scope_opts/1 into every store call, so the rows are the " <>
         "pipeline-derived :current_workspace's — which DeriveWorkspaceFromToken now fills " <>
         "from the token before AssignDefaultScope can stamp Default."},
    # TasksController.show
    {"GET", "/v1/tasks/:doc_id"} =>
      {:workspace_derived,
       "threads ScopeHelpers.scope_opts/1 into every store call, so the rows are the " <>
         "pipeline-derived :current_workspace's — which DeriveWorkspaceFromToken now fills " <>
         "from the token before AssignDefaultScope can stamp Default."},
    # TasksController.claim_by_id
    {"POST", "/v1/tasks/:doc_id/claim"} =>
      {:workspace_derived,
       "threads ScopeHelpers.scope_opts/1 into every store call, so the rows are the " <>
         "pipeline-derived :current_workspace's — which DeriveWorkspaceFromToken now fills " <>
         "from the token before AssignDefaultScope can stamp Default."},
    # TasksController.close
    {"POST", "/v1/tasks/:doc_id/close"} =>
      {:workspace_derived,
       "threads ScopeHelpers.scope_opts/1 into every store call, so the rows are the " <>
         "pipeline-derived :current_workspace's — which DeriveWorkspaceFromToken now fills " <>
         "from the token before AssignDefaultScope can stamp Default."},
    # TasksController.edges
    {"GET", "/v1/tasks/:doc_id/edges"} =>
      {:workspace_derived,
       "threads ScopeHelpers.scope_opts/1 into every store call, so the rows are the " <>
         "pipeline-derived :current_workspace's — which DeriveWorkspaceFromToken now fills " <>
         "from the token before AssignDefaultScope can stamp Default."},
    # TasksController.relabel
    {"POST", "/v1/tasks/:doc_id/labels"} =>
      {:workspace_derived,
       "threads ScopeHelpers.scope_opts/1 into every store call, so the rows are the " <>
         "pipeline-derived :current_workspace's — which DeriveWorkspaceFromToken now fills " <>
         "from the token before AssignDefaultScope can stamp Default."},
    # TasksController.move
    {"POST", "/v1/tasks/:doc_id/move"} =>
      {:workspace_derived,
       "threads ScopeHelpers.scope_opts/1 into every store call, so the rows are the " <>
         "pipeline-derived :current_workspace's — which DeriveWorkspaceFromToken now fills " <>
         "from the token before AssignDefaultScope can stamp Default."},
    # TasksController.papers
    {"POST", "/v1/tasks/:doc_id/papers"} =>
      {:workspace_derived,
       "threads ScopeHelpers.scope_opts/1 into every store call, so the rows are the " <>
         "pipeline-derived :current_workspace's — which DeriveWorkspaceFromToken now fills " <>
         "from the token before AssignDefaultScope can stamp Default."},
    # TasksController.pulse
    {"POST", "/v1/tasks/:doc_id/pulse"} =>
      {:workspace_derived,
       "threads ScopeHelpers.scope_opts/1 into every store call, so the rows are the " <>
         "pipeline-derived :current_workspace's — which DeriveWorkspaceFromToken now fills " <>
         "from the token before AssignDefaultScope can stamp Default."},
    # TasksController.release
    {"POST", "/v1/tasks/:doc_id/release"} =>
      {:workspace_derived,
       "threads ScopeHelpers.scope_opts/1 into every store call, so the rows are the " <>
         "pipeline-derived :current_workspace's — which DeriveWorkspaceFromToken now fills " <>
         "from the token before AssignDefaultScope can stamp Default."},
    # TasksController.sessions
    {"POST", "/v1/tasks/:doc_id/sessions"} =>
      {:workspace_derived,
       "threads ScopeHelpers.scope_opts/1 into every store call, so the rows are the " <>
         "pipeline-derived :current_workspace's — which DeriveWorkspaceFromToken now fills " <>
         "from the token before AssignDefaultScope can stamp Default."},
    # TasksController.stage
    {"POST", "/v1/tasks/:doc_id/stage"} =>
      {:workspace_derived,
       "threads ScopeHelpers.scope_opts/1 into every store call, so the rows are the " <>
         "pipeline-derived :current_workspace's — which DeriveWorkspaceFromToken now fills " <>
         "from the token before AssignDefaultScope can stamp Default."},
    # TasksController.stamp
    {"POST", "/v1/tasks/:doc_id/stamp"} =>
      {:workspace_derived,
       "threads ScopeHelpers.scope_opts/1 into every store call, so the rows are the " <>
         "pipeline-derived :current_workspace's — which DeriveWorkspaceFromToken now fills " <>
         "from the token before AssignDefaultScope can stamp Default."},
    # TasksController.claim
    {"POST", "/v1/tasks/claim"} =>
      {:workspace_derived,
       "threads ScopeHelpers.scope_opts/1 into every store call, so the rows are the " <>
         "pipeline-derived :current_workspace's — which DeriveWorkspaceFromToken now fills " <>
         "from the token before AssignDefaultScope can stamp Default."},
    # TasksController.add_edge
    {"POST", "/v1/tasks/edges"} =>
      {:workspace_derived,
       "threads ScopeHelpers.scope_opts/1 into every store call, so the rows are the " <>
         "pipeline-derived :current_workspace's — which DeriveWorkspaceFromToken now fills " <>
         "from the token before AssignDefaultScope can stamp Default."},
    # TasksController.events
    {"GET", "/v1/tasks/events"} =>
      {:workspace_derived,
       "threads ScopeHelpers.scope_opts/1 into every store call, so the rows are the " <>
         "pipeline-derived :current_workspace's — which DeriveWorkspaceFromToken now fills " <>
         "from the token before AssignDefaultScope can stamp Default."},
    # TasksController.prime
    {"GET", "/v1/tasks/prime"} =>
      {:workspace_derived,
       "threads ScopeHelpers.scope_opts/1 into every store call, so the rows are the " <>
         "pipeline-derived :current_workspace's — which DeriveWorkspaceFromToken now fills " <>
         "from the token before AssignDefaultScope can stamp Default."},
    # TasksController.ready
    {"GET", "/v1/tasks/ready"} =>
      {:workspace_derived,
       "threads ScopeHelpers.scope_opts/1 into every store call, so the rows are the " <>
         "pipeline-derived :current_workspace's — which DeriveWorkspaceFromToken now fills " <>
         "from the token before AssignDefaultScope can stamp Default."},
    # TicketsController.answer
    {"POST", "/v1/tickets/:id/answer"} =>
      {:workspace_derived,
       "threads ScopeHelpers.scope_opts/1 into every store call, so the rows are the " <>
         "pipeline-derived :current_workspace's — which DeriveWorkspaceFromToken now fills " <>
         "from the token before AssignDefaultScope can stamp Default."},
    # TicketsController.close
    {"POST", "/v1/tickets/:id/close"} =>
      {:workspace_derived,
       "threads ScopeHelpers.scope_opts/1 into every store call, so the rows are the " <>
         "pipeline-derived :current_workspace's — which DeriveWorkspaceFromToken now fills " <>
         "from the token before AssignDefaultScope can stamp Default."},
    # TicketsController.inbox
    {"GET", "/v1/tickets/inbox"} =>
      {:workspace_derived,
       "threads ScopeHelpers.scope_opts/1 into every store call, so the rows are the " <>
         "pipeline-derived :current_workspace's — which DeriveWorkspaceFromToken now fills " <>
         "from the token before AssignDefaultScope can stamp Default."},
    # TicketsController.show_operator
    {"GET", "/v1/tickets/inbox/:id"} =>
      {:workspace_derived,
       "threads ScopeHelpers.scope_opts/1 into every store call, so the rows are the " <>
         "pipeline-derived :current_workspace's — which DeriveWorkspaceFromToken now fills " <>
         "from the token before AssignDefaultScope can stamp Default."}
  }

  # Flat `/v1` + `/api` routes that ride a pipeline OTHER than `:api`. They are
  # out of this census's scope by the criterion's own wording, but they must not
  # be able to appear unclassified: a NEW flat pipeline is exactly how this
  # defect class was born. Keyed on the FIRST pipeline in the route's
  # `pipe_through`.
  @non_api_flat_pipelines %{
    api_local: "loopback-only fast path (Plugs.RequireLoopback) — never reachable off-box",
    api_preview: "preview-JWT draft reads; runs AssignDefaultScope with no bearer to derive from",
    api_unlimited:
      "unauthenticated instance metadata (/v1/meta, /v1/openapi.json) — no token, no tenant",
    cycle_api: "already carries DeriveWorkspaceFromToken ahead of AssignDefaultScope (B9)",
    flat_admin_api:
      "already carries DeriveWorkspaceFromToken ahead of AssignDefaultScope (D45/D49)",
    github_webhook: "HMAC-signed GitHub delivery; no bearer and no tenant assign",
    ingest: "ingest-token tier (Plugs.RequireIngestToken); tenancy rides the ingest token",
    media_mutate: "already carries DeriveWorkspaceFromToken ahead of AssignDefaultScope",
    media_processing_callback: "signed callback from the media processing worker",
    public_api: "deliberately public + CORS; no token tier at all",
    registered_chat_host: "chat-host credential tier (Plugs.RequireChatHost)",
    session_token_root:
      "operator session-cookie GET bucket; carries DeriveWorkspaceFromToken like :api",
    sso_browser: "SSO redirect legs (OIDC/SAML/social); no data surface",
    ticket_key: "low-trust ticket-key tier; tenancy is the resolved key's own binding",
    user_auth: "account/session surface, keyed on the USER rather than on a workspace"
  }

  setup do
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]
    register_task_schemas!(scope)

    # Unique raw values + labels: the test database is shared across agents, and
    # a fixed literal would 409 against a peer's row.
    n = System.unique_integer([:positive])
    read_token = "flat-census-read-#{n}"
    write_token = "flat-census-write-#{n}"

    {:ok, _} = Auth.create_token(read_token, "flat-census-read-#{n}", @dataset, ["read"], ws.id)

    {:ok, _} =
      Auth.create_token(write_token, "flat-census-write-#{n}", @dataset, ["write"], ws.id)

    %{scope: scope, ws: ws, project: project, read: read_token, write: write_token}
  end

  # ── The census keeps itself honest ────────────────────────────────────────

  describe "route census — every flat :api route is classified" do
    test "the census is not vacuous" do
      routes = flat_api_routes()

      refute routes == [],
             "the flat-route enumeration returned NOTHING. Either route_info/4 stopped " <>
               "carrying :pipe_through or the flat scopes moved — fix the enumeration, do " <>
               "NOT delete the assertion: an empty census passes every other test here."

      assert {"GET", "/v1/data/counts/:dataset"} in Enum.map(routes, fn {v, p, _, _} -> {v, p} end),
             "GET /v1/data/counts/:dataset — the route task-28c3f7f0987d6e85 measured the " <>
               "leak on — is not in the enumeration, so this census is looking at the " <>
               "wrong surface"

      assert map_size(@census) == length(routes),
             "the census holds #{map_size(@census)} entries for #{length(routes)} routes"
    end

    test "no flat :api route is missing from the census" do
      missing =
        for {verb, path, plug, action} <- flat_api_routes(),
            not Map.has_key?(@census, {verb, path}),
            do: "#{verb} #{path}  (#{inspect(plug)}.#{action})"

      assert missing == [],
             """
             A route is mounted on the flat /v1|/api alias and is NOT in @census.
             Classify it — :workspace_derived when its tenant comes from the caller's
             credential (the pipeline's :current_workspace, an authorized param, or the
             row's own binding), :global ONLY when the controller reads no tenant rows —
             and write the reason for real (task-28c3f7f0987d6e85 criterion 3):

             #{Enum.join(missing, "\n")}
             """
    end

    test "the census names no route that no longer exists" do
      live = MapSet.new(flat_api_routes(), fn {verb, path, _plug, _action} -> {verb, path} end)

      stale =
        for {verb, path} <- Map.keys(@census),
            not MapSet.member?(live, {verb, path}),
            do: "#{verb} #{path}"

      assert stale == [],
             """
             @census names routes that are no longer mounted on the flat /v1|/api alias.
             A census that keeps ghosts stops describing the surface — delete the entries
             (or fix the path if the route was renamed):

             #{Enum.join(Enum.sort(stale), "\n")}
             """
    end

    test "every :global entry survives its own controller's source" do
      offenders =
        for {{verb, path}, {:global, reason}} <- @census,
            {_v, _p, plug, action} = find_route!(verb, path),
            markers = scope_markers_in(plug),
            problem = global_problem(markers, reason),
            problem != nil,
            do: "#{verb} #{path}  (#{inspect(plug)}.#{action}) — #{problem}"

      assert offenders == [],
             """
             A route is classified :global but its controller's SOURCE says otherwise.

             A :global classification means the controller legitimately ignores the
             request's tenant scope. If the module mentions scope_opts( /
             current_workspace / workspace_id at all, the reason must NAME the marker it
             holds and say why the route is still global — that is the whole point of
             writing the reason down. A reason that claims the source "carries no scope
             marker at all" must be TRUE.

             #{Enum.join(Enum.sort(offenders), "\n\n")}
             """
    end

    test "every reason is a reason, not a placeholder" do
      thin =
        for {{verb, path}, {_kind, reason}} <- @census,
            String.length(reason) < 60 or
              String.downcase(reason) in ~w(misc other tbd n/a unknown),
            do: "#{verb} #{path} — #{inspect(reason)}"

      assert thin == [],
             "a census entry carries no real reason. \"instance-operational, no tenant " <>
               "rows\" is a reason; \"misc\" is not:\n#{Enum.join(thin, "\n")}"
    end

    test "no flat route rides an UNCLASSIFIED non-:api pipeline" do
      unknown =
        for {verb, path, pipes} <- flat_routes_off_api(),
            first = List.first(pipes),
            not (is_atom(first) and Map.has_key?(@non_api_flat_pipelines, first)),
            do: "#{verb} #{path}  #{inspect(pipes)}"

      assert unknown == [],
             """
             A flat /v1|/api route rides a pipeline this file has never seen. A NEW flat
             pipeline is exactly how the Default-stamping defect was born
             (task-28c3f7f0987d6e85): classify it in @non_api_flat_pipelines, and if it
             resolves a token and stamps the Default scope, flat_alias_tenancy_test.exs
             will have something to say about it too.

             #{Enum.join(unknown, "\n")}
             """
    end
  end

  # ── The read-only probes: real requests, real status codes ────────────────

  describe "read-only token probes — the routes both rows name" do
    test "every mutating route named by task-a87a3346b8ff736a refuses a `read` token",
         %{conn: conn, scope: scope, ws: ws, read: read, write: write} do
      task = open_task!(scope)
      epoch = claim_over_http!(conn, task.doc_id, "census-legit-worker", write)
      body = %{worker_id: "census-legit-worker", observed_epoch: epoch}

      probes = [
        {"POST", "/v1/tasks/#{task.doc_id}/claim", %{worker_id: "census-readonly-probe"}},
        {"POST", "/v1/tasks/#{task.doc_id}/stamp",
         Map.merge(body, %{criterion: 0, criterion_text: "c1", met: true, evidence: "forged"})},
        {"POST", "/v1/tasks/#{task.doc_id}/close",
         Map.put(body, :criteria_override, "closed by a read-only token")},
        {"POST", "/v1/tasks/#{task.doc_id}/stage",
         Map.put(body, :reason, "staged by a read token")},
        {"POST", "/v1/tasks/#{task.doc_id}/move", Map.put(body, :parent_id, task.doc_id)},
        {"POST", "/v1/tasks/#{task.doc_id}/pulse",
         Map.put(body, :text, "pulsed by a read token")},
        {"POST", "/v1/tasks/claim", %{worker_id: "census-readonly-probe"}},
        {"POST", "/v1/fleet/beat", %{worker: "census-readonly-probe"}},
        # A DELIBERATELY BOGUS ticket id. The gate is METHOD-derived and mounted
        # ahead of the controller, so it must answer 403 BEFORE the controller
        # can 404 the id — if this ever returns 404 the refusal has moved behind
        # the lookup and the census below stops meaning what it says.
        {"POST", "/v1/tickets/#{@probe_segment}/answer", %{message: "answered by a read token"}},
        {"POST", "/v1/tickets/#{@probe_segment}/close", %{}},
        {"POST", "/api/workspaces", %{name: "census probe workspace"}},
        {"POST", "/api/workspaces/#{ws.slug}/projects", %{name: "census probe project"}}
      ]

      results =
        for {verb, path, payload} <- probes do
          resp =
            conn
            |> put_req_header("authorization", "Bearer " <> read)
            |> put_req_header("content-type", "application/json")
            |> post(path, Jason.encode!(payload))

          code =
            case Jason.decode(resp.resp_body) do
              {:ok, %{"error" => %{"code" => c}}} -> c
              _ -> nil
            end

          {verb, path, resp.status, code}
        end

      IO.puts("\n─── read-only token (permissions: [\"read\"]) vs the flat write verbs ───")

      for {verb, path, status, code} <- results do
        IO.puts("  #{String.pad_trailing(verb <> " " <> path, 62)} #{status}  #{code}")
      end

      IO.puts("")

      refused = Enum.filter(results, fn {_v, _p, s, c} -> s == 403 and c == "forbidden" end)

      assert length(refused) == length(results),
             """
             A route named by task-a87a3346b8ff736a did not answer 403 + the canonical
             `forbidden` envelope to a permissions: ["read"] token:

             #{results |> Enum.reject(fn {_v, _p, s, c} -> s == 403 and c == "forbidden" end) |> Enum.map_join("\n", fn {v, p, s, c} -> "  #{v} #{p} -> #{s} #{inspect(c)}" end)}
             """

      # The row must not have moved — a gate that refuses AFTER the controller
      # wrote would pass every status assertion above.
      after_doc = reload!(task.doc_id, scope)
      assert after_doc.content["lifecycle_status"] == "in_progress"
      assert after_doc.content["claim"]["worker"] == "census-legit-worker"
      [criterion | _] = after_doc.content["acceptance_criteria"]
      assert criterion["met"] == false
    end

    test "the same `read` token keeps every flat READ it had", %{conn: conn, read: read} do
      # The control: the gate is a write clamp, not a blanket refusal. If these
      # ever 403 the probes above stop proving anything about permissions.
      for path <- ["/v1/tasks", "/v1/tasks/ready", "/v1/fleet/roster", "/v1/tickets/inbox"] do
        resp =
          conn
          |> put_req_header("authorization", "Bearer " <> read)
          |> get(path)

        assert resp.status == 200,
               "GET #{path} answered #{resp.status} for a read token — safe methods must " <>
                 "pass through RequireWriteForMutation untouched"
      end
    end

    test "safe methods are exactly the ones the gate says they are" do
      assert RequireWriteForMutation.safe_methods() == ~w(GET HEAD OPTIONS)
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp flat?(path), do: String.starts_with?(path, "/v1") or String.starts_with?(path, "/api")

  # `{verb, path, plug, action}` for every flat route whose pipeline runs `:api`.
  defp flat_api_routes do
    for route <- BarkparkWeb.Router.__routes__(),
        flat?(route.path),
        verb = route.verb |> to_string() |> String.upcase(),
        pipes = probe_pipelines(verb, route.path),
        :api in pipes,
        do: {verb, route.path, route.plug, route.plug_opts}
  end

  # `{verb, path, pipelines}` for every flat route that does NOT run `:api`.
  defp flat_routes_off_api do
    for route <- BarkparkWeb.Router.__routes__(),
        flat?(route.path),
        verb = route.verb |> to_string() |> String.upcase(),
        pipes = probe_pipelines(verb, route.path),
        :api not in pipes,
        do: {verb, route.path, pipes}
  end

  # The route's `pipe_through`, read off the REAL matcher. `__routes__/0` in this
  # Phoenix version carries no :pipe_through; `route_info/4` does. Flunks rather
  # than returns `[]` on a miss, so a probe that lands on a different route can
  # never silently shrink the census.
  defp probe_pipelines(verb, path) do
    probe =
      path
      |> String.split("/")
      |> Enum.map(fn
        ":" <> _ -> @probe_segment
        "*" <> _ -> @probe_segment
        segment -> segment
      end)
      |> Enum.join("/")

    case Phoenix.Router.route_info(BarkparkWeb.Router, verb, probe, "localhost") do
      %{pipe_through: pipes, route: ^path} ->
        pipes

      %{route: other} ->
        flunk(
          "census probe for #{verb} #{path} matched #{other} instead — the placeholder " <>
            "segment #{@probe_segment} is being shadowed, so this route's pipeline cannot " <>
            "be read and the census would silently omit it"
        )

      :error ->
        flunk("census probe for #{verb} #{path} matched no route at all")
    end
  end

  defp find_route!(verb, path) do
    case Enum.find(flat_api_routes(), fn {v, p, _, _} -> {v, p} == {verb, path} end) do
      nil -> flunk("@census names #{verb} #{path}, which is not a live flat :api route")
      route -> route
    end
  end

  # The scope markers actually present in a controller module's own source.
  defp scope_markers_in(module) do
    source = module.__info__(:compile)[:source] |> to_string()

    body =
      case File.read(source) do
        {:ok, contents} ->
          contents

        {:error, reason} ->
          flunk(
            "could not read #{inspect(module)} source at #{source} (#{inspect(reason)}) — " <>
              "the :global assertion cannot be evaluated, and a census that cannot check " <>
              "itself is worse than none"
          )
      end

    Enum.filter(@scope_markers, &String.contains?(body, &1))
  end

  # `nil` when the :global classification holds up; a sentence naming the problem
  # otherwise.
  defp global_problem(markers, reason) do
    claims_clean? = String.contains?(reason, "carries no scope marker at all")

    unaddressed =
      Enum.reject(markers, fn marker ->
        String.contains?(reason, String.trim_trailing(marker, "("))
      end)

    cond do
      claims_clean? and markers != [] ->
        "the reason claims the source carries no scope marker, but it holds " <>
          "#{inspect(markers)}"

      unaddressed != [] ->
        "the controller's source mentions #{inspect(unaddressed)} and the reason never " <>
          "names it — say why the route is still global"

      true ->
        nil
    end
  end

  defp register_task_schemas!(scope) do
    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end
  end

  defp open_task!(scope) do
    {:ok, task} =
      Content.create_document(
        "task",
        %{
          "doc_id" => "flat-census-#{System.unique_integer([:positive])}",
          "title" => "flat census probe",
          "content" => %{
            "kind" => "task",
            "lifecycle_status" => "open",
            "acceptance_criteria" => [%{"criterion" => "c1", "met" => false, "evidence" => ""}]
          }
        },
        @dataset,
        scope
      )

    task
  end

  defp reload!(doc_id, scope) do
    {:ok, doc} = Content.get_document(doc_id, "task", @dataset, scope)
    doc
  end

  # Claim over the REAL route with a write token and read the live epoch off the
  # response the server just produced — a stale epoch in a stamp/close body is
  # refused 409 by the claim fence, which would make the 403s above prove
  # nothing about permissions.
  defp claim_over_http!(conn, doc_id, worker_id, write_token) do
    resp =
      conn
      |> put_req_header("authorization", "Bearer " <> write_token)
      |> put_req_header("content-type", "application/json")
      |> post("/v1/tasks/#{doc_id}/claim", Jason.encode!(%{worker_id: worker_id}))

    assert resp.status == 200, "setup claim failed: #{resp.status} #{resp.resp_body}"

    epoch = resp.resp_body |> Jason.decode!() |> get_in(["doc", "claim", "epoch"])
    assert is_integer(epoch), "setup claim returned no epoch: #{resp.resp_body}"
    epoch
  end
end
