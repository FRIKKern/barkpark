defmodule BarkparkWeb.Router.Plugins do
  @moduledoc """
  Macro that folds plugin-contributed routes into the host router at
  compile time.

  Imported by `BarkparkWeb.Router` and called inline inside a
  `scope "/studio", BarkparkWeb do … live_session … do plugin_routes(…) end`
  block. At Mix compile time the macro reads
  `Barkpark.Plugins.Registry.collect_routes/1` and emits one Phoenix.Router
  AST node per tuple in the returned list — `live/3`, `live/4`, `get/4`,
  `post/4`, etc. The emitted AST is inlined into the host router as if the
  routes had been written there by hand.

  ## Auth model

  Each plugin route declares its auth via an optional 5th-element opts
  keyword list:

      {:live, "/onixedit/ping", PingLive, :index}                 # default :admin
      {:live, "/onixedit/callback", CallbackLive, :index, auth: :public}
      {:live, "/admin/onixedit/staleness", StalenessLive, :index, auth: :ops}
      {:get, "/onixedit/export/:dataset/:id", ExportController, :show, auth: :api}

  The macro accepts a `scope:` option that selects which subset of routes
  to emit at this callsite:

      plugin_routes(scope: :admin)    # emit routes with auth: :admin (default)
      plugin_routes(scope: :ops)      # emit routes with auth: :ops
      plugin_routes(scope: :public)   # emit routes with auth: :none
      plugin_routes(scope: :api)      # emit routes with auth: :api

  The host router wraps each `plugin_routes/1` call in its own
  `scope` + `live_session` (or `scope` + `pipe_through`) block with the
  appropriate `on_mount` and pipeline — the macro itself does not start
  scopes or sessions, so the caller controls auth gating, root layout,
  and live-session boundaries.

  ## Scope tags (Goal barkpark-G3 s3)

  | tag        | route_spec `auth:` value  | typical host wrapper                                           |
  |------------|---------------------------|----------------------------------------------------------------|
  | `:admin`   | `:admin` (default)        | `pipe_through :browser` + `live_session on_mount: …:admin`     |
  | `:ops`     | `:ops`                    | `pipe_through :browser` + `live_session on_mount: …:ops`       |
  | `:public`  | `:public` (or `:none`)    | `pipe_through :browser` + `live_session` (no on_mount)         |
  | `:api`     | `:api`                    | `pipe_through [:api, :require_admin]` (controller routes only) |
  | `:token`   | `:token`                  | `pipe_through [:api, :require_token]` (controller routes only) |
  | `:token_root` | `:token_root`          | `pipe_through [:api, :require_token]`, mounted at host `/v1` (controller routes only) |
  | `:ingest`  | `:ingest`                 | `pipe_through :ingest` (RequireIngestToken; controller routes) |
  | `:public_root` | `:public_root`        | `pipe_through :browser`; macro emits a per-route `live_session` with the spec's `root_layout:` |

  The `:ingest` bucket gates controller routes with the shared-secret ingest
  token (`RequireIngestToken`) instead of an `api_tokens` bearer — for ingest
  APIs like the Bulldocs paper-ingest endpoint. The `:public_root` bucket mounts
  a public LiveView at the host's top-level scope with its OWN full-document
  root layout (declared via a `root_layout:` opt on the spec) and no studio
  chrome — for reader surfaces like the Bulldocs paper at `/papers/:slug`.

  The `:token_root` bucket is the root-mounted sibling of `:token`: same
  `[:api, :require_token]` pipeline (controller routes only), but mounted at the
  host `/v1` top-level scope instead of under `/v1/plugins`. A spec
  `{:get, "/tasks/ready", Mod, :ready, auth: :token_root}` therefore lands at
  `/v1/tasks/ready` — analogous to how `:public_root` is the root-mounted
  sibling of `:public`.

  The `:ops` bucket gates routes via the loosened admin role used by the
  publish-ops console (see `BarkparkWeb.LiveAuth.on_mount(:ops, …)`).
  The `:api` bucket is for controller routes mounted under `/v1` with
  the `require_admin` token check — no `live_session`.

  Each bucket emits the routes the caller asks for and nothing else;
  with no plugin contributing routes to a given bucket the call expands
  to an empty list and the caller's wrapping scope is a harmless no-op.

  ## Path mounting

  Plugins write paths relative to `/studio/<plugin-slug>/` and include
  the slug in the returned path (e.g. `"/onixedit/ping"`). The macro
  does not prepend the slug — the host scope (`scope "/studio"`)
  contributes the `/studio` prefix.

  ## Compile-time vs runtime

  `collect_routes/1` runs at macro-expansion time. After editing a
  plugin's `register_routes/1`, the host router must RECOMPILE for the
  new routes to appear — and the compiler cannot see this dependency
  (the plugin module is reached dynamically through the Registry), so a
  plain `mix compile` recompiles the plugin but NOT the router, and a
  `touch lib/barkpark_web/router.ex` is defeated by content-digest
  checking. Force it:

      rm _build/dev/lib/barkpark/ebin/Elixir.BarkparkWeb.Router.beam && mix compile

  (or `mix compile --force` / `make rebuild` on the server). Symptom of
  forgetting: the verb shows in `/v1/capabilities` (cli_commands is read
  at runtime) but the route 404s — e.g. `/v1/tasks/prime` returning
  `not_found` while the manifest advertises `task.prime`. There is no
  hot-reload of plugin routes in v1.

  With `:barkpark, :plugins` configured to `[]` (or no bundled plugins
  on disk), `collect_routes/1` returns `[]` and the macro emits no
  routes — preserving the fresh-install invariant.
  """

  @doc """
  Emits Phoenix.Router AST for plugin-contributed routes.

  Accepts a `scope:` option that selects which subset of routes to
  emit at this callsite:

    * `:admin` (default) — routes whose `auth:` resolves to `:admin`
    * `:ops`             — routes that opted in to `auth: :ops`
    * `:public`          — routes that opted in to `auth: :none`
    * `:api`             — routes that opted in to `auth: :api`
    * `:token`           — routes that opted in to `auth: :token`
    * `:token_root`      — routes that opted in to `auth: :token_root`
                           (root-mounted sibling of `:token`, at host `/v1`)
    * `:ingest`          — routes that opted in to `auth: :ingest`
    * `:public_root`     — routes that opted in to `auth: :public_root`
                           (carry a `root_layout:` opt; each is wrapped in its
                           own live_session applying that layout)

  Reads `Barkpark.Plugins.Registry.collect_routes/1` at compile time
  and filters by the requested scope. The caller is responsible for
  wrapping the call in the right `scope` + `live_session` /
  `pipe_through` host-router block — see the moduledoc table.
  """
  defmacro plugin_routes(opts \\ []) do
    scope = Keyword.get(opts, :scope, :admin)

    unless scope in [:admin, :ops, :public, :api, :token, :token_root, :ingest, :public_root] do
      raise ArgumentError,
            "plugin_routes(scope: ...) requires :admin | :ops | :public | :api | :token | :token_root | :ingest | :public_root, got #{inspect(scope)}"
    end

    ctx = %{scope: scope, phase: :compile}

    routes =
      ctx
      |> Barkpark.Plugins.Registry.collect_routes()
      |> Enum.filter(&route_in_scope?(&1, scope))

    Enum.map(routes, &emit_route_ast/1)
  end

  # ── Scope filtering ─────────────────────────────────────────────────

  # A 4-tuple has no opts, so it gets the default `auth: :admin` and
  # appears only at the `:admin` callsite. A 5-tuple reads `:auth` from
  # the opts keyword list — `:admin` by default when the key is absent.
  #
  # The `:public` scope tag matches routes whose `auth:` opt is `:none`
  # — `:public` is the callsite-facing name, `:none` is the spec-side
  # opt value (chosen for ergonomic readability at the plugin author's
  # callsite: `auth: :none` reads as "no auth required"). `:ops` and
  # `:api` use the same atom on both sides.
  defp route_in_scope?({_kind, _path, _mod, _action}, scope), do: scope == :admin

  defp route_in_scope?({_kind, _path, _mod, _action, opts}, scope) when is_list(opts) do
    auth = Keyword.get(opts, :auth, :admin)
    auth_matches_scope?(auth, scope)
  end

  defp route_in_scope?(_, _), do: false

  defp auth_matches_scope?(:none, :public), do: true
  defp auth_matches_scope?(auth, scope), do: auth == scope

  # ── AST emission ────────────────────────────────────────────────────

  # `live/3` and `live/4` come from `Phoenix.LiveView.Router`, which the
  # host router imports via `use BarkparkWeb, :router`. We emit
  # unqualified calls so they resolve against the caller's imports — the
  # resulting AST is identical to a hand-written `live "/foo", Foo` line.
  defp emit_route_ast({:live, path, mod, action}) do
    quote do
      live(unquote(path), unquote(mod), unquote(action))
    end
  end

  # `:public_root` LiveView routes own a full-document root layout and mount at
  # a host-provided top-level scope without the studio/app chrome. The plugin
  # declares `root_layout:` in the spec opts; we wrap the single route in its
  # OWN uniquely-named live_session so Phoenix applies that root layout — the
  # `:public` bucket can't, since it is pinned to the shared `/studio`
  # live_session + studio layout. The LiveView's own `mount/3` returns
  # `layout: false` to drop the app wrapper, mirroring the host's former
  # `:papers` live_session exactly.
  defp emit_route_ast({:live, path, mod, action, opts}) when is_list(opts) do
    phoenix_opts = strip_plugin_opts(opts)

    if Keyword.get(opts, :auth) == :public_root do
      session_name = public_root_session_name(path, mod)
      root_layout = Keyword.fetch!(opts, :root_layout)

      quote do
        live_session unquote(session_name), root_layout: unquote(Macro.escape(root_layout)) do
          live(unquote(path), unquote(mod), unquote(action), unquote(phoenix_opts))
        end
      end
    else
      quote do
        live(unquote(path), unquote(mod), unquote(action), unquote(phoenix_opts))
      end
    end
  end

  # Controller routes — one clause per HTTP verb so the unqualified
  # macro name resolves correctly. `Phoenix.Router` exports `get/4`,
  # `post/4`, etc. as macros in scope inside the host router.
  defp emit_route_ast({verb, path, mod, action})
       when verb in [:get, :post, :put, :delete, :patch] do
    emit_verb_ast(verb, path, mod, action, [])
  end

  defp emit_route_ast({verb, path, mod, action, opts})
       when verb in [:get, :post, :put, :delete, :patch] and is_list(opts) do
    emit_verb_ast(verb, path, mod, action, strip_plugin_opts(opts))
  end

  defp emit_verb_ast(:get, path, mod, action, opts) do
    quote do: get(unquote(path), unquote(mod), unquote(action), unquote(opts))
  end

  defp emit_verb_ast(:post, path, mod, action, opts) do
    quote do: post(unquote(path), unquote(mod), unquote(action), unquote(opts))
  end

  defp emit_verb_ast(:put, path, mod, action, opts) do
    quote do: put(unquote(path), unquote(mod), unquote(action), unquote(opts))
  end

  defp emit_verb_ast(:delete, path, mod, action, opts) do
    quote do: delete(unquote(path), unquote(mod), unquote(action), unquote(opts))
  end

  defp emit_verb_ast(:patch, path, mod, action, opts) do
    quote do: patch(unquote(path), unquote(mod), unquote(action), unquote(opts))
  end

  # A unique, deterministic live_session name for a `:public_root` route.
  # live_session names must be unique across the whole router, so derive one
  # from the route path + module — two plugins (or two routes) never collide,
  # and the name is stable across recompiles.
  defp public_root_session_name(path, mod) do
    slug =
      path
      |> String.replace(~r/[^A-Za-z0-9]+/, "_")
      |> String.trim("_")

    String.to_atom("plugin_root_#{slug}_#{:erlang.phash2(mod)}")
  end

  # Phoenix doesn't recognise our plugin-only opt keys — strip them before
  # forwarding to the underlying router macro so we don't trip a compile
  # warning on unknown route options. `:auth` is the scope selector;
  # `:root_layout` is consumed by the `:public_root` live_session wrapper
  # above and is not a valid `live/4` option.
  defp strip_plugin_opts(opts), do: Keyword.drop(opts, [:auth, :root_layout])
end
