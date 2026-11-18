defmodule Barkpark.Test.IdempotencyMounts do
  @moduledoc """
  The one reader the Idempotency tripwires share: where is
  `BarkparkWeb.Plugs.Idempotency` mounted, and does code stream
  (task-ccf7bc7003c505c9). Reads source ASTs; never compiles or writes.

  A mount is a `plug` call whose module, once the file's own `alias`es are
  applied, is `BarkparkWeb.Plugs.Idempotency`: by full name or through an
  alias (`alias …Idempotency`, `as:`, `alias BarkparkWeb.Plugs.{…}`), with or
  without options, with or without a `when` guard.

  A streaming call is `send_chunked` or `send_file` called bare, piped,
  captured, or by a qualified name (`Plug.Conn.send_chunked(conn, 200)`).

  Which ROUTES the plug covers is derived here too, for both tripwires
  (task-7f9b31e4cc83419e, task-d909ad1c50dd5a1a):

    * through a pipeline: each mutating route's pipelines come from
      `Phoenix.Router.route_info/4` on the compiled router, so a route a macro
      emits (`plugin_routes(scope: ...)`) counts with the pipelines of the
      scope it lands in, and a scope that pipes through the plug module itself
      counts too (`pipeline_routes/1`);
    * through a controller's own `plug` (`controller_routes/2`): every file
      under `lib/` that names the plug is read, so a plugin's controller under
      `lib/barkpark/plugins/*/web/` counts like one under
      `lib/barkpark_web/controllers/`.
  """

  @plug [:BarkparkWeb, :Plugs, :Idempotency]
  @plug_module BarkparkWeb.Plugs.Idempotency
  @streaming [:send_chunked, :send_file]
  @mutating_verbs ~w(post put patch delete)a

  # ── routes the plug covers ──────────────────────────────────────────────

  @doc "The names of the router's pipelines that mount the plug, read from its source."
  @spec pipelines(module()) :: MapSet.t(atom())
  def pipelines(router) do
    ast = router |> router_source() |> File.read!() |> Code.string_to_quoted!()
    aliases = aliases(ast)

    {_, acc} =
      Macro.prewalk(ast, [], fn
        {:pipeline, _, [name, [do: body]]} = node, acc when is_atom(name) ->
          if mounts(body, aliases) != [], do: {node, [name | acc]}, else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    MapSet.new(acc)
  end

  @doc """
  `{verb, path, controller, action}` for every mutating route whose pipelines
  run the plug: a mounting pipeline, or the plug module piped directly.
  """
  @spec pipeline_routes(module()) :: [{atom(), String.t(), module(), atom()}]
  def pipeline_routes(router) do
    pipelines = pipelines(router)

    for route <- mutating_routes(router),
        %{pipe_through: pipes} <- [route_info(router, route)],
        Enum.any?(pipes, &(&1 == @plug_module or MapSet.member?(pipelines, &1))) do
      {route.verb, route.path, route.plug, route.plug_opts}
    end
  end

  @doc """
  `{verb, path, controller, action, controller_ast}` for every mutating route
  whose controller, found under `lib_root`, mounts the plug for that action.
  """
  @spec controller_routes(module(), Path.t()) :: [tuple()]
  def controller_routes(router, lib_root) do
    mounts = controller_mounts(lib_root, router)

    for route <- mutating_routes(router),
        {module, actions, ast} <- mounts,
        route.plug == module,
        actions == :all or route.plug_opts in actions do
      {route.verb, route.path, module, route.plug_opts, ast}
    end
  end

  @doc "The router's mutating routes with an action atom (Idempotency passes other verbs)."
  @spec mutating_routes(module()) :: [map()]
  def mutating_routes(router) do
    for route <- router.__routes__(),
        route.verb in @mutating_verbs and is_atom(route.plug_opts),
        do: route
  end

  @doc """
  `{module, actions, ast}` for every file under `lib_root` (the router
  excepted) whose own body mounts the plug. `actions` is `:all` for an
  unguarded mount, else the actions its `when action == :x` /
  `when action in [...]` guards name.
  """
  @spec controller_mounts(Path.t(), module()) :: [{module(), :all | [atom()], Macro.t()}]
  def controller_mounts(lib_root, router) do
    router_path = router_source(router)

    for path <- Path.wildcard(Path.join(lib_root, "**/*.ex")),
        path != router_path,
        File.read!(path) =~ "Idempotency",
        {:ok, ast} = path |> File.read!() |> Code.string_to_quoted(),
        actions = mounted_actions(ast),
        actions != [] do
      {module_name(ast), actions, ast}
    end
  end

  @doc """
  The `route_info/4` of `route`, asked at a path made from its own pattern, or
  nil when that path resolves to another route.
  """
  @spec route_info(module(), map()) :: map() | nil
  def route_info(router, route) do
    method = route.verb |> to_string() |> String.upcase()

    case Phoenix.Router.route_info(router, method, concrete_path(route.path), "localhost") do
      %{route: path, plug: plug, plug_opts: opts} = info
      when path == route.path and plug == route.plug and opts == route.plug_opts ->
        info

      _other ->
        nil
    end
  end

  defp concrete_path(pattern) do
    pattern
    |> String.split("/")
    |> Enum.map_join("/", fn
      ":" <> _ -> "p1"
      "*" <> _ -> "g1"
      segment -> segment
    end)
  end

  defp router_source(router), do: router.module_info(:compile)[:source] |> to_string()

  defp module_name(ast) do
    {_, name} =
      Macro.prewalk(ast, nil, fn
        {:defmodule, _, [{:__aliases__, _, segments} | _]} = node, nil ->
          {node, Module.concat(segments)}

        node, acc ->
          {node, acc}
      end)

    name
  end

  defp mounted_actions(ast) do
    acc = for %{guard: guard} <- mounts(ast), do: if(guard, do: guard_actions(guard), else: :all)

    cond do
      acc == [] -> []
      :all in acc -> :all
      true -> List.flatten(acc)
    end
  end

  defp guard_actions(guard) do
    {_, found} =
      Macro.prewalk(guard, [], fn
        {:==, _, [{:action, _, _}, action]} = node, acc when is_atom(action) ->
          {node, [action | acc]}

        {:in, _, [{:action, _, _}, actions]} = node, acc when is_list(actions) ->
          {node, actions ++ acc}

        node, acc ->
          {node, acc}
      end)

    found
  end

  # ── a plugin-shaped fixture both tripwires drive ────────────────────────

  @doc """
  Compiles a MUTANT router and its controllers from files under `dir`, every
  module named `Barkpark.Test.<prefix>…` so two test files never redefine
  each other's. Its `plugin_routes/1` is a stand-in macro that emits two
  routes, as the real one emits a plugin's specs, into a scope piping
  `:idempotent`; another scope pipes the plug module itself; and a plugin
  controller under `barkpark/plugins/mutant/web/` mounts the plug for itself.

      POST /v1/plugins/stream  stream     (plugin route, :idempotent scope)
      POST /v1/plugins/calm    calm       (plugin route, :idempotent scope)
      POST /v1/direct/stream   stream     (scope pipes the plug module)
      POST /v1/open/stream     stream     (no mount)
      POST /v1/open/self       self_mount (its controller mounts the plug)

  Returns the modules and the lib root to scan.
  """
  @spec compile_plugin_fixture!(Path.t(), String.t()) :: map()
  def compile_plugin_fixture!(dir, prefix) do
    m = fn name -> "Barkpark.Test.#{prefix}#{name}" end

    files = [
      {"routes.ex",
       """
       defmodule #{m.("Routes")} do
         defmacro plugin_routes(_opts) do
           quote do
             post "/stream", #{m.("StreamController")}, :create
             post "/calm", #{m.("CalmController")}, :create
           end
         end
       end
       """},
      {"stream_controller.ex",
       """
       defmodule #{m.("StreamController")} do
         use Plug.Builder
         def create(conn, _params), do: send_chunked(conn, 200)
       end
       """},
      {"calm_controller.ex",
       """
       defmodule #{m.("CalmController")} do
         use Plug.Builder
         def create(conn, _params), do: send_resp(conn, 200, "ok")
       end
       """},
      {"barkpark/plugins/mutant/web/self_mount_controller.ex",
       """
       defmodule #{m.("SelfMountController")} do
         use Plug.Builder
         plug BarkparkWeb.Plugs.Idempotency, bind_request: true
         def create(conn, _params), do: send_chunked(conn, 200)
       end
       """},
      {"router.ex",
       """
       defmodule #{m.("Router")} do
         use Phoenix.Router
         import #{m.("Routes")}

         pipeline :idempotent do
           plug(BarkparkWeb.Plugs.Idempotency, bind_request: true)
         end

         scope "/v1/plugins" do
           pipe_through(:idempotent)
           plugin_routes(scope: :token)
         end

         scope "/v1/direct" do
           pipe_through(BarkparkWeb.Plugs.Idempotency)
           post "/stream", #{m.("StreamController")}, :create
         end

         scope "/v1/open" do
           post "/stream", #{m.("StreamController")}, :create
           post "/self", #{m.("SelfMountController")}, :create
         end
       end
       """}
    ]

    for {file, source} <- files do
      path = Path.join(dir, file)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, source)
      Code.compile_file(path)
    end

    mod = &Module.concat([m.(&1)])

    %{
      router: mod.("Router"),
      stream: mod.("StreamController"),
      calm: mod.("CalmController"),
      self_mount: mod.("SelfMountController"),
      lib_root: dir
    }
  end

  # ── the AST readers ─────────────────────────────────────────────────────

  @typedoc "One mount: its options (nil when none) and its `when` guard (nil when unguarded)."
  @type mount :: %{opts: Macro.t() | nil, guard: Macro.t() | nil}

  @doc """
  Every Idempotency mount in `ast`. `aliases` defaults to the aliases declared
  in `ast` itself; pass the enclosing module's (from `aliases/1`) when `ast` is
  a fragment such as one pipeline's body.
  """
  @spec mounts(Macro.t(), %{atom() => [atom()]} | nil) :: [mount()]
  def mounts(ast, aliases \\ nil) do
    aliases = aliases || aliases(ast)

    {_, found} =
      Macro.prewalk(ast, [], fn
        {:plug, _, args} = node, acc when is_list(args) ->
          case mount(args, aliases) do
            nil -> {node, acc}
            mount -> {node, [mount | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(found)
  end

  # `plug M`, `plug M, opts`, `plug M when g`, `plug M, opts when g`.
  defp mount([{:when, _, [module, guard]}], aliases), do: mount_of(module, nil, guard, aliases)
  defp mount([module], aliases), do: mount_of(module, nil, nil, aliases)

  defp mount([module, {:when, _, [opts, guard]}], aliases),
    do: mount_of(module, opts, guard, aliases)

  defp mount([module, opts], aliases), do: mount_of(module, opts, nil, aliases)
  defp mount(_args, _aliases), do: nil

  defp mount_of({:__aliases__, _, segments}, opts, guard, aliases) do
    if expand(segments, aliases) == @plug, do: %{opts: opts, guard: guard}
  end

  defp mount_of(_module, _opts, _guard, _aliases), do: nil

  @doc "Does `ast` call `send_chunked` or `send_file` in any form?"
  @spec streams?(Macro.t()) :: boolean()
  def streams?(ast) do
    {_, found} =
      Macro.prewalk(ast, false, fn
        {call, _, _} = node, _acc when call in @streaming -> {node, true}
        {:., _, [_module, call]} = node, _acc when call in @streaming -> {node, true}
        node, acc -> {node, acc}
      end)

    found
  end

  @doc "The short name → full segments map of every `alias` in `ast`."
  @spec aliases(Macro.t()) :: %{atom() => [atom()]}
  def aliases(ast) do
    {_, acc} =
      Macro.prewalk(ast, %{}, fn
        {:alias, _, [{:__aliases__, _, segments}]} = node, acc ->
          {node, put_alias(acc, segments, nil)}

        {:alias, _, [{:__aliases__, _, segments}, opts]} = node, acc when is_list(opts) ->
          {node, put_alias(acc, segments, Keyword.get(opts, :as))}

        {:alias, _, [{{:., _, [{:__aliases__, _, base}, :{}]}, _, children} | _]} = node, acc ->
          {node,
           Enum.reduce(children, acc, fn
             {:__aliases__, _, segments}, acc -> put_alias(acc, base ++ segments, nil)
             _other, acc -> acc
           end)}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  defp put_alias(acc, segments, {:__aliases__, _, [as]}) when is_atom(as),
    do: Map.put(acc, as, segments)

  defp put_alias(acc, segments, _as) do
    case List.last(segments) do
      name when is_atom(name) -> Map.put(acc, name, segments)
      _ -> acc
    end
  end

  @doc """
  The module a written name (`__aliases__` segments) means under `aliases`, or
  nil when the name, or the alias it goes through, is built from `__MODULE__`
  or another expression (`alias __MODULE__.Inner`, then `Inner.go/1`).
  """
  @spec module(list(), %{atom() => list()}) :: module() | nil
  def module(segments, aliases) do
    expanded = expand(segments, aliases)
    if Enum.all?(expanded, &is_atom/1), do: Module.concat(expanded)
  end

  # Elixir expands only the FIRST segment of a module name through an alias.
  defp expand([head | tail] = segments, aliases) do
    case Map.fetch(aliases, head) do
      {:ok, full} -> full ++ tail
      :error -> segments
    end
  end

  defp expand(segments, _aliases), do: segments
end
