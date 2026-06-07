defmodule BarkparkWeb.Router do
  use BarkparkWeb, :router

  # Compile-time macro that folds plugin-contributed routes into the host
  # router. See `BarkparkWeb.Router.Plugins` and Goal barkpark-G2.
  import BarkparkWeb.Router.Plugins

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {BarkparkWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug BarkparkWeb.Plugs.AcceptBarkparkVendor
    plug :accepts, ["json"]
    plug BarkparkWeb.Plugs.ErrorEnvelopeNegotiation
    plug BarkparkWeb.Plugs.RateLimit
    plug BarkparkWeb.Plugs.OptionalToken
    # Back-compat tenancy shim: flat routes (no /w/:ws/p/:project slugs in the
    # path) infer the seeded Default Workspace/Project so downstream code always
    # has a scope. No-op once a resolver has already set the assigns.
    plug BarkparkWeb.Plugs.AssignDefaultScope
  end

  # Tenancy-aware variant of :api for the path-scoped
  # /w/:workspace_slug/p/:project_slug routes. Same base plugs as :api
  # (sans AssignDefaultScope — the resolvers set the real scope), then
  # resolves + membership-gates the workspace and resolves the project.
  pipeline :scoped_api do
    plug BarkparkWeb.Plugs.AcceptBarkparkVendor
    plug :accepts, ["json"]
    plug BarkparkWeb.Plugs.ErrorEnvelopeNegotiation
    plug BarkparkWeb.Plugs.RateLimit
    plug BarkparkWeb.Plugs.OptionalToken
    plug BarkparkWeb.Plugs.ResolveWorkspace
    plug BarkparkWeb.Plugs.ResolveProject
  end

  # Tenancy-aware variant of :browser for the path-scoped plugin LiveView
  # mounts at /w/:workspace_slug/p/:project_slug/{studio,admin}. The base
  # :browser plugs (session, flash, CSRF, secure headers, root layout), then
  # the two resolver plugs so the plugin LiveViews participate in the hard
  # tenant boundary — `current_workspace` / `current_project` land in the
  # conn assigns, threaded into the LV session for ScopeHelpers.scope_opts/1.
  # OptionalSessionToken runs first so ResolveWorkspace's membership gate
  # sees a token from EITHER a Bearer header OR the signed-in browser's
  # session cookie (`session["api_token"]`) — a real member with only the
  # cookie resolves their token and clears the gate instead of 403'ing
  # before mount. The LV's own on_mount admin/ops hook is the UI auth gate.
  pipeline :scoped_browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {BarkparkWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug BarkparkWeb.Plugs.OptionalSessionToken
    plug BarkparkWeb.Plugs.ResolveWorkspace
    plug BarkparkWeb.Plugs.ResolveProject
  end

  pipeline :api_unlimited do
    plug :accepts, ["json"]
    plug BarkparkWeb.Plugs.ErrorEnvelopeNegotiation
  end

  pipeline :api_preview do
    plug BarkparkWeb.Plugs.AcceptBarkparkVendor
    plug :accepts, ["json"]
    plug BarkparkWeb.Plugs.ErrorEnvelopeNegotiation
    plug BarkparkWeb.Plugs.RateLimit
    plug BarkparkWeb.Plugs.PreviewToken
    # Tenancy shim: the flat /v1/preview/* routes carry no /w/:ws/p/:project
    # slugs, so without this the preview-JWT draft reads ran UNSCOPED across
    # every workspace (B9/barkpark-6xd9). Mirror :api — infer the seeded
    # Default workspace/project. A path-scoped preview route (under
    # /w/:ws/p/:project) sets the real scope via the resolvers, and
    # AssignDefaultScope no-ops once an assign is already present.
    plug BarkparkWeb.Plugs.AssignDefaultScope
  end

  pipeline :require_token do
    plug BarkparkWeb.Plugs.RequireToken
  end

  # Browser Studio uploads send `credentials: same-origin` with the session
  # cookie; API clients still use Bearer. Requires `:fetch_session` upstream.
  pipeline :media_mutate do
    plug :fetch_session
    plug BarkparkWeb.Plugs.AcceptBarkparkVendor
    plug :accepts, ["json"]
    plug BarkparkWeb.Plugs.ErrorEnvelopeNegotiation
    plug BarkparkWeb.Plugs.RateLimit
    plug BarkparkWeb.Plugs.RequireBearerOrSessionToken
    plug BarkparkWeb.Plugs.AssignDefaultScope
  end

  # Ingest endpoints: JSON in, shared-secret bearer auth (NOT the api_tokens
  # table). Used by the Bulldocs paper-ingest API and any plugin that ships an
  # `auth: :ingest` route via the plugin highway. (Convergence MVP — masterplan
  # Figure 6 — originally `:paperflow_ingest`.)
  pipeline :ingest do
    plug :accepts, ["json"]
    plug BarkparkWeb.Plugs.RequireIngestToken
  end

  pipeline :require_admin do
    plug BarkparkWeb.Plugs.RequireToken
    plug BarkparkWeb.Plugs.RequireAdmin
  end

  # Scoped admin gate (barkpark-23yi / barkpark-fsko P0 fix). For the
  # /w/:ws/p/:project admin routes: require a token AND a membership ROLE of
  # owner/admin in the resolved `current_workspace`. RequireToken sets
  # :api_token; ResolveWorkspace (in :scoped_api) sets :current_workspace and
  # already gates :read membership; RequireWorkspaceRole reads the per-grant
  # role — so a `member` of B with global admin perms is 403'd on admin ops.
  # The FLAT admin routes keep :require_admin (global-perm gate) — the Default
  # workspace + the dev token's owner/admin Default membership keep them green.
  pipeline :scoped_admin do
    plug BarkparkWeb.Plugs.RequireToken
    plug BarkparkWeb.Plugs.RequireWorkspaceRole
  end

  pipeline :idempotent do
    plug BarkparkWeb.Plugs.Idempotency
  end

  # Write-gate: rejects tokens lacking "write"/"admin" with 403 before the
  # mutation reaches the controller. Must run after :require_token.
  pipeline :require_write do
    plug BarkparkWeb.Plugs.RequireWritePermission
  end

  # Bare /studio and / redirect to the default dataset.
  scope "/", BarkparkWeb do
    pipe_through :browser
    get "/", PageController, :redirect_to_studio
    get "/studio", PageController, :redirect_to_studio
  end

  # ── Session login (paste API token) ─────────────────────────────────
  scope "/", BarkparkWeb do
    pipe_through :browser

    get "/login", SessionController, :new
    post "/login", SessionController, :create
    post "/logout", SessionController, :delete
  end

  # ── Bulldocs paper reader (LiveView) ────────────────────────────────────
  # The public reader at `/papers/:slug` is now contributed by the Bulldocs
  # plugin via the `:public_root` route bucket — see
  # `Barkpark.Plugins.Bulldocs.register_routes/1` and the
  # `scope "/" … plugin_routes(scope: :public_root)` block below. It mounts
  # `BarkparkWeb.BulldocsLive` in its own live_session with the full-document
  # `:bulldocs` root layout: byte-identical URL + layout to the former hardcoded
  # `scope "/papers"`, just sourced from the plugin. (The route template still
  # matches `BARKPARK_LIVEVIEW_PATH_TEMPLATE` = "/papers/{slug}" in paperflow's
  # event-on-save.sh.)

  # ── Bulldocs paper ingest (JSON POST) — back-compat alias ───────────────
  # The CANONICAL ingest API is now the Bulldocs plugin's `/v1/plugins/bulldocs/*`
  # (the `:ingest` route bucket — see `Barkpark.Plugins.Bulldocs.register_routes/1`).
  # These flat `/v1/paperflow/*` routes are kept as a back-compat alias so
  # existing producers (paperflow's event-on-save.sh) keep working until
  # repointed — same controllers, same `:ingest` (RequireIngestToken) pipeline.
  # Remove once every producer posts to the plugin URL.
  scope "/v1/paperflow", BarkparkWeb do
    pipe_through :ingest

    post "/papers", BulldocsIngestController, :ingest
    # Wave 4 block-ingest: POST a single DocPatchOp for a slug. Same bearer
    # auth; applies via Content.apply_paper_block_op, broadcasts a delta frame.
    post "/papers/:slug/ops", BulldocsIngestController, :apply_op
    # P6.U6a loop-closer (barkpark-jwai): the paperflow-side reader loop (U6b)
    # drains pending action:*/simplify-* intents here, then marks each done.
    get "/intents", BulldocsIntentsController, :index
    post "/intents/:id/processed", BulldocsIntentsController, :mark_processed
  end

  # ── Studio admin (LiveView) — admin-gated via on_mount ──────────────────
  scope "/studio", BarkparkWeb.Studio do
    pipe_through :browser

    live_session :admin_studio,
      on_mount: [{BarkparkWeb.LiveAuth, :admin}],
      layout: {BarkparkWeb.Layouts, :studio} do
      live "/settings", SettingsLive
    end
  end

  # ── Back-compat redirects: legacy host-namespaced admin URLs ──────────
  # When a plugin admin LV migrates from host namespace into a plugin's
  # own namespace via `plugin_routes(scope: :ops)`, its URL prefix
  # changes from `/admin/<lv>` to `/admin/<plugin>/<lv>`. The redirect
  # controller below preserves old deep links via 301. New legacy paths
  # only get an entry when the URL prefix genuinely changes — when the
  # original URL already includes the plugin slug, no redirect is needed.
  scope "/admin", BarkparkWeb do
    pipe_through :browser

    get "/bokbasen", LegacyRedirectController, :bokbasen
  end

  # ── Back-compat redirects (must come BEFORE the StudioLive catch-all) ───
  # The dedicated OnixEdit BookEditor / BookView LiveViews were removed in
  # Goal barkpark-zdy. `book` documents now open in native StudioLive at
  # `/studio/:dataset/book/:doc_id`. These two redirects keep old deep links
  # working — including the `?tab=…` query string the old editor used.
  scope "/studio/:dataset", BarkparkWeb do
    pipe_through :browser

    get "/onixedit/book/:doc_id", LegacyRedirectController, :onixedit_book
    get "/onixedit/book/:doc_id/view", LegacyRedirectController, :onixedit_book
  end

  # ── Plugin-contributed routes — admin-gated (Goal barkpark-G2 s3) ─────
  # `plugin_routes(scope: :admin)` expands at compile time to one
  # Phoenix.Router AST node per `{:live, …}` / `{:get, …}` / etc. tuple
  # returned by each plugin's `register_routes/1` callback whose `:auth`
  # opt resolves to `:admin` (the default when omitted). Plugin paths
  # include the slug — the plugin returns `"/onixedit/ping"` and the
  # `scope "/studio"` here contributes the `/studio` prefix → final
  # `/studio/onixedit/ping`. MUST come before the `/studio/:dataset`
  # catch-all scope below.
  #
  # NOTE: this scope intentionally omits the second `BarkparkWeb` alias
  # arg that other scopes carry. Plugin modules are fully qualified by
  # the route specs returned from each plugin's `register_routes/1`
  # callback — passing a host alias here would cause Phoenix's `scope`
  # macro to prepend `BarkparkWeb.` to those names, breaking module
  # resolution.
  scope "/studio" do
    pipe_through :browser

    live_session :plugin_admin,
      on_mount: [{BarkparkWeb.LiveAuth, :admin}],
      layout: {BarkparkWeb.Layouts, :studio} do
      plugin_routes(scope: :admin)
    end
  end

  # ── Plugin-contributed routes — public (`auth: :public`) ──────────────
  # For plugin-supplied routes that opt out of the admin gate via
  # `auth: :public` (or the legacy `auth: :none`) in the route spec opts
  # (e.g. OAuth callbacks). No `on_mount` admin hook; plugins handle
  # their own auth inside the LV. Same no-alias rationale as the
  # `:plugin_admin` scope above.
  scope "/studio" do
    pipe_through :browser

    live_session :plugin_public,
      layout: {BarkparkWeb.Layouts, :studio} do
      plugin_routes(scope: :public)
    end
  end

  # ── Plugin-contributed routes — ops-gated (`auth: :ops`) ──────────────
  # Goal barkpark-G3 s3. Mirrors the host's `:admin_ops` scope at
  # `/admin` — same `:browser` pipeline, same `BarkparkWeb.LiveAuth.:ops`
  # on_mount hook. Plugins that contribute an ops route write paths
  # relative to `/admin/<plugin-slug>/` (e.g.
  # `"/onixedit/staleness"` → `/admin/onixedit/staleness`).
  # No-op until a plugin contributes a spec with `auth: :ops` (G3 s4
  # migrates Bokbasen + onixedit staleness; until then this expands to
  # an empty live_session, which Phoenix accepts cleanly).
  # Same no-alias rationale as the `:plugin_admin` scope above —
  # plugin LV modules are fully qualified.
  scope "/admin" do
    pipe_through :browser

    live_session :plugin_ops,
      on_mount: [{BarkparkWeb.LiveAuth, :ops}],
      layout: {BarkparkWeb.Layouts, :studio} do
      plugin_routes(scope: :ops)
    end
  end

  # ── Plugin-contributed routes — API (`auth: :api`) ────────────────────
  # Goal barkpark-G3 s3. Mirrors the host's `/v1/plugins/onixedit`
  # scope — `[:api, :require_admin]` pipeline, controller routes only
  # (no live_session). Plugins that contribute an API route write paths
  # relative to `/v1/plugins/<plugin-slug>/` (e.g.
  # `"/onixedit/export/:dataset/:id"` → `/v1/plugins/onixedit/export/...`).
  # No-op until a plugin contributes a spec with `auth: :api` (G3 s5
  # migrates the OnixEdit export controller).
  # Same no-alias rationale as the `:plugin_admin` scope — plugin
  # controller modules are fully qualified.
  scope "/v1/plugins" do
    pipe_through [:api, :require_admin]

    plugin_routes(scope: :api)
  end

  # ── Plugin-contributed routes — public root-layout (`auth: :public_root`) ──
  # For plugin LiveViews that own a FULL-document root layout and mount at the
  # top level WITHOUT the studio chrome — e.g. the Bulldocs paper reader at
  # `/papers/:slug`. The plugin declares `root_layout:` in the route spec opts;
  # the `plugin_routes/1` macro wraps each such route in its OWN live_session
  # applying that layout (a per-route root layout the `:public` bucket can't
  # express, since that one is pinned to `/studio` + the studio layout). No
  # on_mount gate — these are public read surfaces and the plugin scopes its
  # own data. Same no-alias rationale as the other plugin scopes — plugin LV
  # modules are fully qualified. Expands to nothing until a plugin contributes
  # a `:public_root` route.
  scope "/" do
    pipe_through :browser

    plugin_routes(scope: :public_root)
  end

  # ── Plugin-contributed routes — ingest-token (`auth: :ingest`) ────────
  # For plugin CONTROLLER routes authenticated by the shared-secret ingest
  # token (`RequireIngestToken`) rather than an `api_tokens` bearer — e.g. the
  # Bulldocs paper-ingest API. Mounts under `/v1/plugins/<slug>/…` via the
  # `:ingest` pipeline (json + RequireIngestToken). Controller routes only, no
  # live_session. Expands to nothing until a plugin contributes an `:ingest`
  # route.
  scope "/v1/plugins" do
    pipe_through :ingest

    plugin_routes(scope: :ingest)
  end

  # ── Plugin-contributed routes — workspace/project-scoped mirrors ──────
  # Task barkpark-4tuu (Goal barkpark-G… W1). The four flat plugin mounts
  # above keep working as the Default-scoped back-compat alias (mirroring
  # how the rest of W1 left the flat `/v1/data`, `/media`, etc. in place);
  # these mirrors mount the SAME plugin routes under the path-based tenant
  # prefix `/w/:workspace_slug/p/:project_slug/{studio,admin,v1/plugins}` so
  # plugin routes participate in the hard tenant boundary.
  #
  # Pipelines:
  #   * browser scopes (admin/public/ops) use :scoped_browser — base
  #     :browser plugs + ResolveWorkspace/ResolveProject so the workspace +
  #     project land in conn assigns (ScopeHelpers.scope_opts/1 then reads
  #     them in the plugin LVs). The LV's own on_mount admin/ops hook stays
  #     the UI auth gate; ResolveWorkspace's membership gate enforces tenant
  #     isolation (tokenless scoped browser access → 403; the flat /studio,
  #     /admin paths remain the cookie-only back-compat surface).
  #   * the :api scope uses :scoped_api + :require_admin — identical to the
  #     flat /v1/plugins mount but with the resolvers replacing
  #     AssignDefaultScope, so the export controller is workspace-scoped.
  #
  # live_session names MUST be unique across the router, hence the
  # `scoped_plugin_*` prefix. Same no-alias rationale as the flat plugin
  # scopes — plugin modules are fully qualified by their route specs.
  scope "/w/:workspace_slug/p/:project_slug/studio" do
    pipe_through :scoped_browser

    live_session :scoped_plugin_admin,
      on_mount: [{BarkparkWeb.LiveAuth, :admin}, {BarkparkWeb.PluginScopeSession, :scope}],
      session: {BarkparkWeb.PluginScopeSession, :build, []},
      layout: {BarkparkWeb.Layouts, :studio} do
      plugin_routes(scope: :admin)
    end
  end

  scope "/w/:workspace_slug/p/:project_slug/studio" do
    pipe_through :scoped_browser

    live_session :scoped_plugin_public,
      on_mount: [{BarkparkWeb.PluginScopeSession, :scope}],
      session: {BarkparkWeb.PluginScopeSession, :build, []},
      layout: {BarkparkWeb.Layouts, :studio} do
      plugin_routes(scope: :public)
    end
  end

  scope "/w/:workspace_slug/p/:project_slug/admin" do
    pipe_through :scoped_browser

    live_session :scoped_plugin_ops,
      on_mount: [{BarkparkWeb.LiveAuth, :ops}, {BarkparkWeb.PluginScopeSession, :scope}],
      session: {BarkparkWeb.PluginScopeSession, :build, []},
      layout: {BarkparkWeb.Layouts, :studio} do
      plugin_routes(scope: :ops)
    end
  end

  scope "/w/:workspace_slug/p/:project_slug/v1/plugins" do
    pipe_through [:scoped_api, :scoped_admin]

    plugin_routes(scope: :api)
  end

  # ── Studio admin LV — dataset-scoped, admin-gated ─────────────────────
  # Task barkpark-otv: plugin admin LV at `/studio/:dataset/_plugins`.
  # MUST come before the studio_public scope below — the catch-all
  # `live "/*path", StudioLive` inside `:studio_public` would otherwise
  # swallow the `_plugins` path. The leading underscore is a convention
  # signalling "admin / system route" (mirrors `_/` patterns in many
  # CMSes) and keeps the namespace clear of any future schema-named
  # path collisions.
  scope "/studio/:dataset", BarkparkWeb.Admin do
    pipe_through :browser

    live_session :admin_studio_dataset,
      on_mount: [{BarkparkWeb.LiveAuth, :admin}],
      layout: {BarkparkWeb.Layouts, :studio} do
      live "/_plugins", PluginsLive
      live "/_plugins/:plugin/settings", PluginSettingsLive
    end
  end

  # ── Studio (LiveView) ─────────────────────────────────────────────────────
  scope "/studio/:dataset", BarkparkWeb.Studio do
    pipe_through :browser

    live_session :studio_public,
      on_mount: [{BarkparkWeb.LiveAuth, :fetch_api_token}],
      layout: {BarkparkWeb.Layouts, :studio} do
      live "/", StudioLive
      live "/media", MediaLive
      # Task barkpark-7xne — restored after the misjudged route-removal
      # in commit f1e5a21. The legacy ApiTesterLive is the rich endpoint
      # docs + form-driven playground; plugin-contributed api_tests/0
      # specs ride this same UI via Endpoints.all/1's "Plugins" category.
      live "/api-tester", ApiTesterLive

      live "/*path", StudioLive
    end
  end

  # ── Meta (SDK handshake) — no auth, no rate limit ───────────────────────
  scope "/v1", BarkparkWeb do
    pipe_through :api_unlimited

    get "/meta", MetaController, :index
  end

  # ── Capabilities manifest (CLI/MCP/SDK contract) — optional token ───────
  # The `:api` pipeline runs `OptionalToken`, so the controller resolves the
  # caller's tier (none when anonymous) and projects the manifest through the
  # existence-hiding allow-list keyed on it.
  scope "/v1", BarkparkWeb do
    pipe_through :api

    get "/capabilities", CapabilitiesController, :index
  end

  # ── Federated discovery ─────────────────────────────────────────────────
  scope "/v1", BarkparkWeb do
    pipe_through :api

    get "/search/:dataset", FederatedSearchController, :search
  end

  # ── Public API — read-only, respects schema visibility ──────────────────
  scope "/v1/data", BarkparkWeb do
    pipe_through :api

    get "/search/:dataset/suggestions", SearchController, :search_suggestions
    post "/search/:dataset/interaction", SearchController, :search_interaction
    get "/search/:dataset", SearchController, :search
    get "/query/:dataset/:type", QueryController, :index
    get "/doc/:dataset/:type/:doc_id", QueryController, :show
  end

  # ── Preview — same reads, forces perspective=drafts via preview JWT ─────
  scope "/v1/preview", BarkparkWeb do
    pipe_through :api_preview

    get "/query/:dataset/:type", QueryController, :index
    get "/doc/:dataset/:type/:doc_id", QueryController, :show
  end

  # ── Private API — full CRUD, requires token ─────────────────────────────
  scope "/v1/data", BarkparkWeb do
    pipe_through [:api, :require_token]

    get "/listen/:dataset", ListenController, :listen
    get "/export/:dataset", ExportController, :export

    get "/analytics/:dataset", AnalyticsController, :index

    get "/history/:dataset/:type/:doc_id", HistoryController, :index
    get "/revision/:dataset/:id", HistoryController, :show
    post "/revision/:dataset/:id/restore", HistoryController, :restore
  end

  # ── Mutations — token + idempotency dedup ──────────────────────────────
  scope "/v1/data", BarkparkWeb do
    pipe_through [:api, :require_token, :require_write, :idempotent]

    post "/mutate/:dataset", MutateController, :mutate
  end

  # ── Tasks API — paperflow bd-shim surface (W7b step 1 / paperflow-rx0) ──
  # Five endpoints the `bin/bd-shim` translator hits to wrap `Tasks.*`. Auth
  # is bearer-only (the shim runs out-of-band as a CLI helper, never a
  # browser session). No `:require_write` gate — claim/close are workflow
  # ops, not document mutations; their atomicity lives in `Tasks.claim/2` +
  # `Tasks.close/3` (advisory lock + CAS + fencing epoch).
  scope "/v1/tasks", BarkparkWeb do
    pipe_through [:api, :require_token]

    # w7-08c: list-all (the natural `GET /v1/tasks` root). Declared BEFORE
    # the `/:doc_id` catchall so an empty path doesn't get matched as
    # `:doc_id = ""` (Phoenix would actually 404 on that, but the order is
    # the documented Phoenix idiom for static/dynamic disambiguation).
    get "/", TasksController, :index
    get "/ready", TasksController, :ready
    # w7-08: epic aggregator — declared BEFORE the `/:doc_id` catchall so
    # "/epic/close-eligible" doesn't get matched as `:doc_id = "epic"`.
    get "/epic/close-eligible", TasksController, :epic_close_eligible
    post "/claim", TasksController, :claim
    post "/edges", TasksController, :add_edge
    get "/:doc_id", TasksController, :show
    get "/:doc_id/edges", TasksController, :edges
    post "/:doc_id/claim", TasksController, :claim_by_id
    post "/:doc_id/close", TasksController, :close
    # tt5: add/remove content.labels (file-claim:* support for the bd-shim).
    post "/:doc_id/labels", TasksController, :relabel
  end

  scope "/v1/data", BarkparkWeb do
    pipe_through [:api, :require_admin]

    get "/search/:dataset/insights", SearchController, :search_insights
    get "/search/:dataset/settings", SearchController, :search_settings
    put "/search/:dataset/settings", SearchController, :update_search_settings
    get "/search/:dataset/synonyms", SearchController, :search_synonyms
    get "/search/:dataset/synonyms/preview", SearchController, :preview_search_synonym
    post "/search/:dataset/synonyms", SearchController, :create_search_synonym
    post "/search/:dataset/synonyms/promote", SearchController, :promote_search_synonym
    delete "/search/:dataset/synonyms/:id", SearchController, :delete_search_synonym
  end

  # ── Goal-path rail — W7c step 3 (w7-11 / paperflow-158) ─────────────────
  # Three read endpoints powering the paperflow daemon's rail proxy.
  # Bearer-only via :api + :require_token — same surface contract as
  # /v1/tasks (rail is a sibling read of the task substrate, both consumed
  # by paperflow when PAPERFLOW_MIRROR_GOALS=1). See RailController moduledoc
  # for the mutation_events-vs-event-doc data-source decision.
  scope "/v1/rail", BarkparkWeb do
    pipe_through [:api, :require_token]

    get "/goal-path", RailController, :goal_path
    get "/diff", RailController, :diff
    get "/event/:event_id", RailController, :event
  end

  # ── Schema management — requires admin token ────────────────────────────
  scope "/v1/schemas", BarkparkWeb do
    pipe_through [:api, :require_admin]

    get "/:dataset", SchemaController, :index
    get "/:dataset/:name", SchemaController, :show
    post "/:dataset", SchemaController, :upsert
    delete "/:dataset/:name", SchemaController, :delete
  end

  # ── Plugin settings — admin-only encrypted-JSON CRUD ───────────────────
  scope "/v1/plugins/settings", BarkparkWeb do
    pipe_through [:api, :require_admin]

    get "/:plugin_name", PluginSettingsController, :show
    put "/:plugin_name", PluginSettingsController, :update
    delete "/:plugin_name", PluginSettingsController, :delete
  end

  # ── Webhooks — requires admin token ────────────────────────────────────
  scope "/v1/webhooks", BarkparkWeb do
    pipe_through [:api, :require_admin]

    get "/:dataset", WebhookController, :index
    get "/:dataset/:id", WebhookController, :show
    post "/:dataset", WebhookController, :create
    put "/:dataset/:id", WebhookController, :update
    delete "/:dataset/:id", WebhookController, :delete
  end

  pipeline :media_processing_callback do
    plug :accepts, ["json"]
    plug BarkparkWeb.Plugs.ErrorEnvelopeNegotiation
    plug BarkparkWeb.Plugs.RequireMediaProcessingCallbackToken
  end

  # ── Media — upload requires token, serving is public ────────────────────
  scope "/media", BarkparkWeb do
    pipe_through :api

    get "/renditions/:id/:preset", MediaController, :serve_rendition
    get "/", MediaController, :index
    get "/:id/meta", MediaController, :show
    get "/files/*path", MediaController, :serve
  end

  scope "/media", BarkparkWeb do
    pipe_through :media_mutate

    post "/upload", MediaController, :upload
    delete "/:id", MediaController, :delete
  end

  # ── v1 Media — unified blob + mediaAsset metadata ───────────────────────
  scope "/v1/media", BarkparkWeb do
    pipe_through [:api, :require_admin]

    get "/:dataset/search/insights", V1.MediaController, :search_insights
    get "/:dataset/search/settings", V1.MediaController, :search_settings
    put "/:dataset/search/settings", V1.MediaController, :update_search_settings
    get "/:dataset/search/synonyms", V1.MediaController, :search_synonyms
    get "/:dataset/search/synonyms/preview", V1.MediaController, :preview_search_synonym
    post "/:dataset/search/synonyms", V1.MediaController, :create_search_synonym
    post "/:dataset/search/synonyms/promote", V1.MediaController, :promote_search_synonym
    delete "/:dataset/search/synonyms/:id", V1.MediaController, :delete_search_synonym
  end

  scope "/v1/media", BarkparkWeb do
    pipe_through :api

    get "/:dataset/search/suggestions", V1.MediaController, :search_suggestions
    post "/:dataset/search/interaction", V1.MediaController, :search_interaction
    get "/:dataset/search", V1.MediaController, :search
    get "/:dataset/share/:token", V1.MediaCollectionsController, :share_view
    get "/:dataset/collections", V1.MediaCollectionsController, :index
    get "/:dataset/collections/:id/assets", V1.MediaCollectionsController, :assets
    get "/:dataset/collections/:id", V1.MediaCollectionsController, :show
    get "/:dataset/:id/relations", V1.MediaController, :relations
    get "/:dataset", V1.MediaController, :index
    get "/:dataset/:id", V1.MediaController, :show
  end

  scope "/v1/media", BarkparkWeb do
    pipe_through :media_processing_callback

    post "/:dataset/processing/:id/callback", V1.MediaProcessingController, :callback
  end

  scope "/v1/media", BarkparkWeb do
    pipe_through :media_mutate

    post "/:dataset/collections/:id/share", V1.MediaCollectionsController, :share
    delete "/:dataset/collections/:id/share", V1.MediaCollectionsController, :revoke_share
    post "/:dataset/collections/:id/members", V1.MediaCollectionsController, :add_member
    delete "/:dataset/collections/:id/members/:asset_id", V1.MediaCollectionsController, :remove_member
    post "/:dataset/upload", V1.MediaController, :upload
    post "/:dataset/:id/checkout", V1.MediaController, :checkout
    post "/:dataset/:id/undo-checkout", V1.MediaController, :undo_checkout
    patch "/:dataset/:id", V1.MediaController, :update
    delete "/:dataset/:id", V1.MediaController, :delete
  end

  # ── Scoped tenancy routes ───────────────────────────────────────────────
  # Path-based tenancy: /w/:workspace_slug/p/:project_slug/… mirrors the flat
  # content data routes above. The `:scoped_api` pipeline resolves + membership-
  # gates the workspace (403 cross-dataset read-leak fix) and resolves the
  # project before routing. The `:dataset` segment stays the leaf — dataset is
  # still a string in Wave 1; WHERE-clause scoping by workspace_id is a sibling
  # CONTEXT task. The flat routes below remain the back-compat alias.
  scope "/w/:workspace_slug/p/:project_slug", BarkparkWeb do
    pipe_through :scoped_api

    # Public reads (mirror of /v1/data public scope)
    get "/v1/data/search/:dataset/suggestions", SearchController, :search_suggestions
    post "/v1/data/search/:dataset/interaction", SearchController, :search_interaction
    get "/v1/data/search/:dataset", SearchController, :search
    get "/v1/search/:dataset", FederatedSearchController, :search
    get "/v1/data/query/:dataset/:type", QueryController, :index
    get "/v1/data/doc/:dataset/:type/:doc_id", QueryController, :show

    # Preview reads
    get "/v1/preview/query/:dataset/:type", QueryController, :index
    get "/v1/preview/doc/:dataset/:type/:doc_id", QueryController, :show
  end

  # Token-required scoped reads (listen/export/analytics/history/revision).
  scope "/w/:workspace_slug/p/:project_slug", BarkparkWeb do
    pipe_through [:scoped_api, :require_token]

    get "/v1/data/listen/:dataset", ListenController, :listen
    get "/v1/data/export/:dataset", ExportController, :export
    get "/v1/data/analytics/:dataset", AnalyticsController, :index
    get "/v1/data/history/:dataset/:type/:doc_id", HistoryController, :index
    get "/v1/data/revision/:dataset/:id", HistoryController, :show
    post "/v1/data/revision/:dataset/:id/restore", HistoryController, :restore
  end

  # Scoped mutations — keep the :require_write gate (write-gate slice).
  scope "/w/:workspace_slug/p/:project_slug", BarkparkWeb do
    pipe_through [:scoped_api, :require_token, :require_write, :idempotent]

    post "/v1/data/mutate/:dataset", MutateController, :mutate
  end

  # Scoped admin reads (search insights/synonyms).
  scope "/w/:workspace_slug/p/:project_slug", BarkparkWeb do
    pipe_through [:scoped_api, :scoped_admin]

    get "/v1/data/search/:dataset/insights", SearchController, :search_insights
    get "/v1/data/search/:dataset/synonyms", SearchController, :search_synonyms
    post "/v1/data/search/:dataset/synonyms", SearchController, :create_search_synonym
    delete "/v1/data/search/:dataset/synonyms/:id", SearchController, :delete_search_synonym
  end

  # Scoped schema management (admin).
  scope "/w/:workspace_slug/p/:project_slug", BarkparkWeb do
    pipe_through [:scoped_api, :scoped_admin]

    get "/v1/schemas/:dataset", SchemaController, :index
    get "/v1/schemas/:dataset/:name", SchemaController, :show
    post "/v1/schemas/:dataset", SchemaController, :upsert
    delete "/v1/schemas/:dataset/:name", SchemaController, :delete
  end

  # Scoped webhooks (admin).
  scope "/w/:workspace_slug/p/:project_slug", BarkparkWeb do
    pipe_through [:scoped_api, :scoped_admin]

    get "/v1/webhooks/:dataset", WebhookController, :index
    get "/v1/webhooks/:dataset/:id", WebhookController, :show
    post "/v1/webhooks/:dataset", WebhookController, :create
    put "/v1/webhooks/:dataset/:id", WebhookController, :update
    delete "/v1/webhooks/:dataset/:id", WebhookController, :delete
  end

  # Scoped v1 media — admin search ops.
  scope "/w/:workspace_slug/p/:project_slug", BarkparkWeb do
    pipe_through [:scoped_api, :scoped_admin]

    get "/v1/media/:dataset/search/insights", V1.MediaController, :search_insights
    get "/v1/media/:dataset/search/synonyms", V1.MediaController, :search_synonyms
    post "/v1/media/:dataset/search/synonyms", V1.MediaController, :create_search_synonym
    delete "/v1/media/:dataset/search/synonyms/:id", V1.MediaController, :delete_search_synonym
  end

  # Scoped v1 media — public reads.
  scope "/w/:workspace_slug/p/:project_slug", BarkparkWeb do
    pipe_through :scoped_api

    get "/v1/media/:dataset/search/suggestions", V1.MediaController, :search_suggestions
    post "/v1/media/:dataset/search/interaction", V1.MediaController, :search_interaction
    get "/v1/media/:dataset/search", V1.MediaController, :search
    get "/v1/media/:dataset/share/:token", V1.MediaCollectionsController, :share_view
    get "/v1/media/:dataset/collections", V1.MediaCollectionsController, :index
    get "/v1/media/:dataset/collections/:id/assets", V1.MediaCollectionsController, :assets
    get "/v1/media/:dataset/collections/:id", V1.MediaCollectionsController, :show
    get "/v1/media/:dataset/:id/relations", V1.MediaController, :relations
    get "/v1/media/:dataset", V1.MediaController, :index
    get "/v1/media/:dataset/:id", V1.MediaController, :show
  end

  # Scoped v1 media — mutating (bearer-or-session).
  scope "/w/:workspace_slug/p/:project_slug", BarkparkWeb do
    pipe_through [:scoped_api, :media_mutate]

    post "/v1/media/:dataset/collections/:id/share", V1.MediaCollectionsController, :share
    delete "/v1/media/:dataset/collections/:id/share", V1.MediaCollectionsController, :revoke_share
    post "/v1/media/:dataset/collections/:id/members", V1.MediaCollectionsController, :add_member

    delete "/v1/media/:dataset/collections/:id/members/:asset_id",
           V1.MediaCollectionsController,
           :remove_member

    post "/v1/media/:dataset/upload", V1.MediaController, :upload
    post "/v1/media/:dataset/:id/checkout", V1.MediaController, :checkout
    post "/v1/media/:dataset/:id/undo-checkout", V1.MediaController, :undo_checkout
    patch "/v1/media/:dataset/:id", V1.MediaController, :update
    delete "/v1/media/:dataset/:id", V1.MediaController, :delete
  end

  # ── Workspace / project switcher — membership-scoped LIST ───────────────
  # The web switcher's read surface: which workspaces (and their projects) the
  # bearer token's principal can reach. Membership-scoped in the context layer
  # (`Tenancy.list_workspaces_for/1` INNER-JOINs `workspace_memberships`), so a
  # non-member workspace never appears; the :projects action returns 404 for a
  # non-member to avoid leaking existence. Token-gated only — NOT the path
  # tenancy macro / scoped plugin mounts (those live under /w/:ws/p/:project).
  scope "/api", BarkparkWeb do
    pipe_through [:api, :require_token]

    get "/workspaces", WorkspaceController, :index
    get "/workspaces/:workspace_slug/projects", WorkspaceController, :projects

    # Create surface: any authenticated token may create a workspace (becomes
    # its owner-member, + Default project + production dataset); project
    # creation is member-gated (non-member → 404, no existence leak).
    post "/workspaces", WorkspaceController, :create
    post "/workspaces/:workspace_slug/projects", WorkspaceController, :create_project
  end

  # ── Legacy compat ──────────────────────────────────────────────────────
  # Deprecated back-compat for the Go TUI's original endpoints — the TUI
  # migrated OFF these (Goal barkpark-qprk, B14). Now token-gated (`:require_token`)
  # and Default-scoped: the `:api` pipeline's `AssignDefaultScope` seeds the
  # Default workspace/project, and `LegacyController` threads `scope_opts(conn)`
  # into the Content reads/writes — closing the unauthenticated + unscoped
  # tenancy hole while mirroring the flat `/v1/data` Default-scope contract.
  scope "/api", BarkparkWeb do
    pipe_through [:api, :require_token, BarkparkWeb.Plugs.LegacyDeprecation]

    get "/documents/:type", LegacyController, :index
    get "/documents/:type/:id", LegacyController, :show
    post "/documents/:type", LegacyController, :create
    delete "/documents/:type/:id", LegacyController, :delete
  end

  # Legacy public schema discovery — intentionally NOT token-gated. w15-E
  # over-gated this when it closed the B14 unauth hole on /api/documents/*;
  # /api/schemas is public read, already Default-scoped via AssignDefaultScope
  # in the :api pipeline. Kept :LegacyDeprecation so the deprecation headers
  # still ride along.
  scope "/api", BarkparkWeb do
    pipe_through [:api, BarkparkWeb.Plugs.LegacyDeprecation]

    get "/schemas", LegacyController, :schemas
  end

  if Application.compile_env(:barkpark, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through [:fetch_session, :protect_from_forgery]
      live_dashboard "/dashboard", metrics: BarkparkWeb.Telemetry
    end
  end
end
