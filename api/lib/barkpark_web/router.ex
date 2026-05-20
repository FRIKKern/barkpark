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
  end

  pipeline :require_token do
    plug BarkparkWeb.Plugs.RequireToken
  end

  pipeline :require_admin do
    plug BarkparkWeb.Plugs.RequireToken
    plug BarkparkWeb.Plugs.RequireAdmin
  end

  pipeline :idempotent do
    plug BarkparkWeb.Plugs.Idempotency
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

  # ── Studio admin (LiveView) — admin-gated via on_mount ──────────────────
  scope "/studio", BarkparkWeb.Studio do
    pipe_through :browser

    live_session :admin_studio,
      on_mount: [{BarkparkWeb.LiveAuth, :admin}],
      layout: {BarkparkWeb.Layouts, :studio} do
      live "/settings", SettingsLive
    end
  end

  # ── Operations admin (LiveView) — `ops` or `admin` permission ───────────
  # Phase 8 WI5: dedicated `ops` role lets operators reach the publish-ops
  # console without inheriting full admin (settings-reveal / schema CRUD).
  # Existing admin tokens still pass — see `BarkparkWeb.LiveAuth.:ops`.
  scope "/admin", BarkparkWeb.Admin do
    pipe_through :browser

    live_session :admin_ops,
      on_mount: [{BarkparkWeb.LiveAuth, :ops}],
      layout: {BarkparkWeb.Layouts, :studio} do
      live "/bokbasen", BokbasenLive
      live "/onixedit/staleness", OnixeditStalenessLive, :index
    end
  end

  # ── Back-compat redirects (must come BEFORE the StudioLive catch-all) ───
  # The dedicated OnixEdit BookEditor / BookView LiveViews were removed in
  # Goal barkpark-zdy. `book` documents now open in native StudioLive at
  # `/studio/:dataset/book/:doc_id`. These two redirects keep old deep links
  # working — including the `?tab=…` query string the old editor used.
  scope "/studio/:dataset", BarkparkWeb do
    pipe_through :browser

    get "/onixedit/book/:doc_id", OnixeditRedirectController, :show
    get "/onixedit/book/:doc_id/view", OnixeditRedirectController, :show
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
  # arg that other scopes carry. Plugin modules are fully qualified
  # (e.g. `Barkpark.Plugins.OnixEdit.PingLive`) — passing a host alias
  # here would cause Phoenix's `scope` macro to prepend `BarkparkWeb.`
  # to those names, breaking module resolution (Goal `barkpark-G2`
  # task s4 pilot proof).
  scope "/studio" do
    pipe_through :browser

    live_session :plugin_admin,
      on_mount: [{BarkparkWeb.LiveAuth, :admin}],
      layout: {BarkparkWeb.Layouts, :studio} do
      plugin_routes(scope: :admin)
    end
  end

  # ── Plugin-contributed routes — public (`auth: :none`) ────────────────
  # For plugin-supplied routes that opt out of the admin gate via
  # `auth: :none` in the route spec opts (e.g. OAuth callbacks). No
  # `on_mount` admin hook; plugins handle their own auth inside the LV.
  # Same no-alias rationale as the `:plugin_admin` scope above.
  scope "/studio" do
    pipe_through :browser

    live_session :plugin_public,
      layout: {BarkparkWeb.Layouts, :studio} do
      plugin_routes(scope: :public)
    end
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

  # ── Public API — read-only, respects schema visibility ──────────────────
  scope "/v1/data", BarkparkWeb do
    pipe_through :api

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
    pipe_through [:api, :require_token, :idempotent]

    post "/mutate/:dataset", MutateController, :mutate
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

  # ── OnixEdit ONIX 3.0 export — admin-only file download ────────────────
  scope "/v1/plugins/onixedit", BarkparkWeb do
    pipe_through [:api, :require_admin]

    get "/export/:dataset/:id", OnixeditExportController, :show
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

  # ── Media — upload requires token, serving is public ────────────────────
  scope "/media", BarkparkWeb do
    pipe_through :api

    get "/", MediaController, :index
    get "/:id/meta", MediaController, :show
    get "/files/*path", MediaController, :serve
  end

  scope "/media", BarkparkWeb do
    pipe_through [:api, :require_token]

    post "/upload", MediaController, :upload
    delete "/:id", MediaController, :delete
  end

  # ── Legacy compat ──────────────────────────────────────────────────────
  scope "/api", BarkparkWeb do
    pipe_through [:api, BarkparkWeb.Plugs.LegacyDeprecation]

    get "/documents/:type", LegacyController, :index
    get "/documents/:type/:id", LegacyController, :show
    post "/documents/:type", LegacyController, :create
    delete "/documents/:type/:id", LegacyController, :delete
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
