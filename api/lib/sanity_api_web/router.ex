defmodule SanityApiWeb.Router do
  use SanityApiWeb, :router
  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :require_token do
    plug SanityApiWeb.Plugs.RequireToken
  end

  pipeline :require_admin do
    plug SanityApiWeb.Plugs.RequireToken
    plug SanityApiWeb.Plugs.RequireAdmin
  end

  # ── Public API — read-only, respects schema visibility ──────────────────
  scope "/v1/data", SanityApiWeb do
    pipe_through :api

    get "/query/:dataset/:type", QueryController, :index
    get "/doc/:dataset/:type/:doc_id", QueryController, :show
  end

  # ── Private API — full CRUD, requires token ─────────────────────────────
  scope "/v1/data", SanityApiWeb do
    pipe_through [:api, :require_token]

    post "/mutate/:dataset", MutateController, :mutate
    get "/listen/:dataset", ListenController, :listen
  end

  # ── Schema management — requires admin token ────────────────────────────
  scope "/v1/schemas", SanityApiWeb do
    pipe_through [:api, :require_admin]

    get "/:dataset", SchemaController, :index
    get "/:dataset/:name", SchemaController, :show
    post "/:dataset", SchemaController, :upsert
    delete "/:dataset/:name", SchemaController, :delete
  end

  # ── Legacy compat — matches Go TUI API (no auth for easy migration) ────
  scope "/api", SanityApiWeb do
    pipe_through :api

    get "/documents/:type", LegacyController, :index
    get "/documents/:type/:id", LegacyController, :show
    post "/documents/:type", LegacyController, :create
    delete "/documents/:type/:id", LegacyController, :delete
    get "/schemas", LegacyController, :schemas
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:sanity_api, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through [:fetch_session, :protect_from_forgery]

      live_dashboard "/dashboard", metrics: SanityApiWeb.Telemetry
    end
  end
end
