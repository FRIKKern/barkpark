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
  plugin's `register_routes/1`, recompile barkpark (`mix compile`) for
  the new routes to appear in `mix phx.routes`. There is no hot-reload
  of plugin routes in v1.

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

  Reads `Barkpark.Plugins.Registry.collect_routes/1` at compile time
  and filters by the requested scope. The caller is responsible for
  wrapping the call in the right `scope` + `live_session` /
  `pipe_through` host-router block — see the moduledoc table.
  """
  defmacro plugin_routes(opts \\ []) do
    scope = Keyword.get(opts, :scope, :admin)

    unless scope in [:admin, :ops, :public, :api] do
      raise ArgumentError,
            "plugin_routes(scope: ...) requires :admin | :ops | :public | :api, got #{inspect(scope)}"
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

  defp emit_route_ast({:live, path, mod, action, opts}) when is_list(opts) do
    phoenix_opts = strip_plugin_opts(opts)

    quote do
      live(unquote(path), unquote(mod), unquote(action), unquote(phoenix_opts))
    end
  end

  # Controller routes — one clause per HTTP verb so the unqualified
  # macro name resolves correctly. `Phoenix.Router` exports `get/4`,
  # `post/4`, etc. as macros in scope inside the host router.
  defp emit_route_ast({verb, path, mod, action}) when verb in [:get, :post, :put, :delete, :patch] do
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

  # Phoenix doesn't recognise our `:auth` key — strip it before forwarding
  # the opts to the underlying router macro so we don't trip a compile
  # warning on unknown route options.
  defp strip_plugin_opts(opts), do: Keyword.drop(opts, [:auth])
end
