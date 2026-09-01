defmodule BarkparkWeb.Plugs.PluginRouteGuard do
  @moduledoc """
  Makes the `BARKPARK_PLUGINS` kill switch effective at REQUEST time.

  ## The hole this closes

  Plugin routes are emitted by the `BarkparkWeb.Router.Plugins.plugin_routes/1`
  macro, which reads `Barkpark.Plugins.Registry.collect_routes/1` at ROUTER
  MACRO-EXPANSION (compile) time. `:barkpark, :plugins` — the kill switch —
  is set in exactly one place, `config/runtime.exs`, which evaluates at BOOT.
  So at compile time `Application.fetch_env(:barkpark, :plugins)` always
  returns `:error`, `plugin_modules_sync/0` always takes its disk-walk branch,
  and EVERY build bakes routes for EVERY bundled plugin — regardless of what
  `BARKPARK_PLUGINS` says at boot.

  The boot collectors (`collect_workers/1`, `collect_oban_crontab/0`) run
  after `runtime.exs` and DO honour the switch. Routes did not. With the
  switch fully off you got zero registered plugins, zero workers and zero
  schemas — and every plugin route still mounted and answering, including the
  anonymous `:public_api` bucket (an unauthenticated, persisted write on a
  surface the operator believed disabled), `:ingest`, `:ticket_key` and
  `:github_webhook`.

  Note that this is NOT fixable by having `config/config.exs` read
  `System.get_env("BARKPARK_PLUGINS")`: that only helps a build that already
  knows its plugin set, and does nothing for an image configured at DEPLOY
  time — the docker/compose case, and the case the switch exists for.

  ## What this plug does

  The routes stay compiled in. `plugin_routes/1` wraps each callsite's routes
  in a nested `scope` that pipes through this plug, and stamps every emitted
  route with its own compile-time spec key under
  `conn.private[:barkpark_plugin_route]` (route `private` is merged by the
  router's `prepare` step, which runs BEFORE the pipeline — so the key is
  already there when this plug runs).

  At request time the plug recomputes the ENABLED route-key set and raises
  `Phoenix.Router.NoRouteError` — a plain 404 through the endpoint's own error
  view, for whatever format the request negotiated — when this route's key is
  not in it. A registered plugin's routes are untouched.

  ## Why it agrees with the boot collectors

  The enabled set is built from `Barkpark.Plugins.Registry.collect_routes/1`
  itself — the SAME function the macro consults, which delegates to
  `Barkpark.Plugins.Registry.BootCollectors` and therefore to the SAME
  `plugin_modules_sync/0` that `collect_workers/1` and `collect_oban_crontab/0`
  honour at boot. Calling it here, AFTER `runtime.exs` has run, is the whole
  fix: identical source of truth, evaluated at a stage where the switch is
  actually visible. Route availability and worker/schema availability can no
  longer disagree.

  `Registry.lookup/1` was the other candidate. It is worse on two counts: a
  route spec carries no plugin identity (`collect_routes/1` flat-maps the
  per-plugin callback results, so attribution is gone by the time the macro
  sees a spec), and `lookup/1` reads the Registry GenServer, which is
  populated by the ASYNCHRONOUS post-boot `discover_and_register/0` Task — a
  request arriving before that Task finishes would see an empty registry and
  404 a route that is perfectly enabled. `collect_routes/1` is pure and
  synchronous and has no such window.

  ## Cost

  The enabled set is memoised in `:persistent_term`, keyed on the raw
  `Application.fetch_env(:barkpark, :plugins)` result. It is recomputed only
  when that value CHANGES — once per boot in production, and on demand in
  tests that flip the switch. A miss walks `priv/plugins` once (via
  `Barkpark.Plugins.Registry.Discovery.default_paths/0`, which uses
  `Application.app_dir/2` and is therefore release-safe); a hit is one
  `:persistent_term.get/2` plus a `MapSet` membership test.

  The set is the UNION over every auth bucket, collected with the same ctx
  shape the macro passes at each callsite. That is deliberate: it is by
  construction exactly what the twelve `plugin_routes/1` callsites would have
  emitted under the current plugin set, so a plugin whose `register_routes/1`
  ever branched on `ctx.scope` could not desynchronise the guard from the
  router.

  ## Not the enablement layer

  This is the INSTALLED layer (the boot whitelist), not the per-workspace
  SURFACED layer — see `Barkpark.Plugins.Enablement`. A workspace that has
  toggled a plugin off still reaches its routes; only an operator-level
  `BARKPARK_PLUGINS` exclusion 404s them.
  """

  @behaviour Plug

  alias Barkpark.Plugins.Registry

  # Every `scope:` tag `BarkparkWeb.Router.Plugins.plugin_routes/1` accepts.
  # Kept in lockstep with the macro's own validation list.
  @scopes [
    :admin,
    :ops,
    :public,
    :api,
    :token,
    :token_root,
    :session_token_root,
    :ticket_key,
    :ingest,
    :public_root,
    :public_api,
    :github_webhook
  ]

  @private_key :barkpark_plugin_route
  @cache_key {__MODULE__, :enabled_route_keys}

  @typedoc """
  The normalised identity of one plugin route spec: verb/kind, path, target
  module, action, and resolved `auth:` bucket. Derived identically at compile
  time (baked into the route's `private`) and at request time (from the
  currently-enabled plugin set), so the two are directly comparable.
  """
  @type route_key :: {atom(), String.t(), module(), atom() | nil, atom()}

  @doc """
  The `conn.private` key under which `plugin_routes/1` stamps a route's
  `route_key/1`. Public so the macro and this plug cannot drift apart.
  """
  @spec private_key() :: atom()
  def private_key, do: @private_key

  @doc """
  Normalises one `Barkpark.Plugin.route_spec()` into its comparable identity.

  A 4-tuple carries no opts and so takes the default `auth: :admin`; a 5-tuple
  reads `:auth` from its opts keyword list. Mirrors
  `BarkparkWeb.Router.Plugins.route_in_scope?/2`'s reading of the same field.
  """
  @spec route_key(tuple()) :: route_key()
  def route_key({kind, path, mod, action}), do: {kind, path, mod, action, :admin}

  def route_key({kind, path, mod, action, opts}) when is_list(opts),
    do: {kind, path, mod, action, Keyword.get(opts, :auth, :admin)}

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{} = conn, _opts) do
    case Map.fetch(conn.private, @private_key) do
      # Not a route this macro stamped — nothing to say about it.
      :error ->
        conn

      {:ok, key} ->
        if MapSet.member?(enabled_route_keys(), key) do
          conn
        else
          raise Phoenix.Router.NoRouteError,
            conn: conn,
            router: Map.get(conn.private, :phoenix_router, __MODULE__)
        end
    end
  end

  # ── The enabled set ─────────────────────────────────────────────────
  #
  # Keyed on the raw fetch_env result rather than a normalised list so that
  # UNSET (`:error`, the fresh-install / production default that means
  # "discover everything on disk") and an explicit `{:ok, []}` (the kill
  # switch) can never collide in the cache — the same unset-vs-empty
  # distinction `plugin_modules_sync/0` draws.

  defp enabled_route_keys do
    snapshot = Application.fetch_env(:barkpark, :plugins)

    case :persistent_term.get(@cache_key, nil) do
      {^snapshot, keys} ->
        keys

      _ ->
        keys = compute_enabled_route_keys()
        :persistent_term.put(@cache_key, {snapshot, keys})
        keys
    end
  end

  defp compute_enabled_route_keys do
    for scope <- @scopes,
        spec <- Registry.collect_routes(%{scope: scope, phase: :compile}),
        into: MapSet.new(),
        do: route_key(spec)
  end
end
