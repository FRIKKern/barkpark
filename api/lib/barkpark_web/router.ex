defmodule BarkparkWeb.Router do
  use BarkparkWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {BarkparkWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug BarkparkWeb.Plugs.RateLimit
  end

  pipeline :require_token do
    plug BarkparkWeb.Plugs.RequireToken
  end

  pipeline :require_admin do
    plug BarkparkWeb.Plugs.RequireToken
    plug BarkparkWeb.Plugs.RequireAdmin
  end

  # Bare /studio and / redirect to the default dataset.
  scope "/", BarkparkWeb do
    pipe_through :browser
    get "/", PageController, :redirect_to_studio
    get "/studio", PageController, :redirect_to_studio
  end

  # ── Studio (LiveView) ─────────────────────────────────────────────────────
  scope "/studio/:dataset", BarkparkWeb.Studio do
    pipe_through :browser

    live "/", StudioLive
    live "/media", MediaLive
    live "/api-tester", ApiTesterLive
    live "/*path", StudioLive
  end

  # ── Public API — read-only, respects schema visibility ──────────────────
  scope "/v1/data", BarkparkWeb do
    pipe_through :api

    get "/query/:dataset/:type", QueryController, :index
    get "/doc/:dataset/:type/:doc_id", QueryController, :show
  end

  # ── Private API — full CRUD, requires token ─────────────────────────────
  scope "/v1/data", BarkparkWeb do
    pipe_through [:api, :require_token]

    post "/mutate/:dataset", MutateController, :mutate
    get "/listen/:dataset", ListenController, :listen
  end

  # ── Schema management — requires admin token ────────────────────────────
  scope "/v1/schemas", BarkparkWeb do
    pipe_through [:api, :require_admin]

    get "/:dataset", SchemaController, :index
    get "/:dataset/:name", SchemaController, :show
    post "/:dataset", SchemaController, :upsert
    delete "/:dataset/:name", SchemaController, :delete
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
