defmodule BarkparkWeb.IdempotentRoutesHaveNoStreamingActionTest do
  @moduledoc """
  ROUTE-LEVEL TRIPWIRE for acpc-bl-idempotency-chunked-trap.

  `BarkparkWeb.Plugs.Idempotency` caches the response body from a
  `register_before_send/2` callback. `send_chunked/2` and `send_file/3..5` also
  run that callback, with `resp_body` already nil'd — so a streaming action
  mounted under an Idempotency pipeline would cache an EMPTY body against a
  live key. The plug now REFUSES that (its `:set` allowlist, and
  `test/barkpark_web/plugs/idempotency_body_state_guard_test.exs`), but a
  refusal is a 500 at request time. This test moves the failure earlier: to CI,
  on the PR that adds such a route.

  Everything here is DERIVED, never enumerated:

    * the Idempotency-mounting pipelines are read out of `router.ex`'s AST, so a
      THIRD mount joins the scan automatically;
    * the routes are read out of `BarkparkWeb.Router.routes/0`;
    * the streaming actions are read out of each controller's own AST;
    * a controller that mounts the plug itself for some actions
      (`plug ... when action == :x`, as ChatController does for the chat send,
      because router.ex may not grow) is read out of the controllers' AST too.
      Such a module may stream in OTHER actions, so the check there is per
      action: from each mounted action, follow the module's own local calls,
      and red if any of them reaches `send_chunked/2` or `send_file/3..5`;
    * a call into ANOTHER project module (qualified by full name or through an
      alias, or bare to a name an `import`ed module defines) is followed ONE
      level: the called function and that module's own local calls from it.
      An import's `only:`/`except:` is respected, and a variable is never a
      call.

  Known greens, a streaming call this scan does not see:

    * a helper's own call into a third module (one level only);
    * `apply/3`, or any call whose module or function is a runtime value;
    * a `defdelegate` in a helper: its target is not followed;
    * a function a `use` injects (`use BarkparkWeb, :controller`): only what
      the file itself writes is read.

  Mounts and streaming calls are recognised by `Barkpark.Test.IdempotencyMounts`
  (test/support), shared with the OpenAPI tripwire: a mount by full name or
  through an alias, with or without options; a streaming call bare, piped,
  captured or qualified (`Plug.Conn.send_chunked/2`).

  Only mutating verbs are scanned, because `Idempotency.call/2` returns the conn
  untouched for anything outside `POST/PUT/PATCH/DELETE`.

  Reads `router.ex`; never writes it.
  """

  use ExUnit.Case, async: true

  alias Barkpark.Test.IdempotencyMounts

  @router_source Path.join(__DIR__, "../../lib/barkpark_web/router.ex") |> Path.expand()
  @controllers_dir Path.join(__DIR__, "../../lib/barkpark_web/controllers") |> Path.expand()
  @mutating_verbs ~w(post put patch delete)a
  @api_root Path.expand("../..", __DIR__)

  # ── the scan ────────────────────────────────────────────────────────────

  defp idempotency_pipelines do
    {:ok, ast} = @router_source |> File.read!() |> Code.string_to_quoted()
    aliases = IdempotencyMounts.aliases(ast)

    {_, acc} =
      Macro.prewalk(ast, [], fn
        {:pipeline, _, [name, [do: body]]} = node, acc when is_atom(name) ->
          if IdempotencyMounts.mounts(body, aliases) != [],
            do: {node, [name | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    MapSet.new(acc)
  end

  # MODULE-level, deliberately. An action-body-only walk is structurally blind:
  # `ExportController.export/2` never calls `send_chunked/2` itself — it calls
  # the private `stream_export/3`, which does. Chasing private helpers is a call
  # graph, not a tripwire. So the predicate is "this controller module streams
  # anywhere", which FAILS CLOSED: a module mixing a streaming action with an
  # idempotent mutating one reds here, and the honest remedy (split the
  # streaming action into its own controller, or answer with send_resp/3) is
  # exactly what the plug guard wants anyway.
  defp streaming_module?(module) do
    case module.module_info(:compile)[:source] do
      nil ->
        false

      source ->
        path = to_string(source)

        with true <- File.exists?(path),
             {:ok, ast} <- path |> File.read!() |> Code.string_to_quoted() do
          calls_streaming?(ast) or helpers_stream?([ast], ast, local_defs(ast))
        else
          _ -> false
        end
    end
  end

  defp calls_streaming?(body), do: IdempotencyMounts.streams?(body)

  # ── controller-level mounts ─────────────────────────────────────────────

  # `{module, actions, ast}` for every controller whose own body mounts the
  # plug. `actions` is `:all` for an unguarded mount, else the actions named in
  # its `when action == :x` / `when action in [...]` guard.
  defp controller_mounts do
    for path <- Path.wildcard(Path.join(@controllers_dir, "**/*.ex")),
        {:ok, ast} = path |> File.read!() |> Code.string_to_quoted(),
        actions = mounted_actions(ast),
        actions != [] do
      {module_name(ast), actions, ast}
    end
  end

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
    acc =
      for %{guard: guard} <- IdempotencyMounts.mounts(ast),
          do: if(guard, do: guard_actions(guard), else: :all)

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

  # Does `action` reach a streaming call through the module's own functions,
  # or through a helper module one of them calls?
  defp action_streams?(ast, action) do
    defs = local_defs(ast)
    bodies = reached_bodies([action], defs)
    Enum.any?(bodies, &calls_streaming?/1) or helpers_stream?(bodies, ast, defs)
  end

  # The bodies of `names` and of every local function they reach.
  defp reached_bodies(names, defs) do
    names
    |> reached(defs, MapSet.new())
    |> Enum.flat_map(&Map.fetch!(defs, &1))
  end

  defp reached([], _defs, seen), do: seen

  defp reached([name | rest], defs, seen) do
    if MapSet.member?(seen, name) or not Map.has_key?(defs, name) do
      reached(rest, defs, seen)
    else
      bodies = Map.fetch!(defs, name)
      reached(Enum.flat_map(bodies, &local_calls(&1, defs)) ++ rest, defs, MapSet.put(seen, name))
    end
  end

  # ── one level into helper modules ───────────────────────────────────────

  # Does any call in `bodies` into another project module reach a streaming
  # call there? `ast` is the caller's whole file (for its aliases and imports),
  # `defs` its local functions (a bare call to one of those is not an import).
  defp helpers_stream?(bodies, ast, defs) do
    bodies
    |> helper_targets(ast, defs)
    |> Enum.any?(fn {_module, {helper_ast, names}} ->
      helper_ast
      |> local_defs()
      |> then(&reached_bodies(names, &1))
      |> Enum.any?(&calls_streaming?/1)
    end)
  end

  # `%{module => {its source AST, the names called in it}}`, project modules only.
  defp helper_targets(bodies, ast, defs) do
    aliases = IdempotencyMounts.aliases(ast)
    imports = imports(ast, aliases)

    bodies
    |> Enum.flat_map(&helper_calls(&1, aliases, imports, defs))
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.flat_map(fn {module, names} ->
      case project_ast(module) do
        nil -> []
        helper_ast -> [{module, {helper_ast, names}}]
      end
    end)
    |> Map.new()
  end

  # `{module, admits?}` per `import`: `admits?.(name)` is whether the import
  # brings `name` in, after its `only:` or `except:` list.
  defp imports(ast, aliases) do
    {_, found} =
      Macro.prewalk(ast, [], fn
        {:import, _, [{:__aliases__, _, segments} | opts]} = node, acc ->
          case IdempotencyMounts.module(segments, aliases) do
            nil -> {node, acc}
            module -> {node, [{module, import_filter(opts)} | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp import_filter([opts]) when is_list(opts) do
    case {Keyword.get(opts, :only), Keyword.get(opts, :except)} do
      {only, _} when is_list(only) -> &Keyword.has_key?(only, &1)
      {_, except} when is_list(except) -> &(not Keyword.has_key?(except, &1))
      _ -> fn _name -> true end
    end
  end

  defp import_filter(_opts), do: fn _name -> true end

  # `{module, name}` per qualified call or capture, and per bare CALL or
  # capture (never a variable) of a non-local name an import brings in.
  # Arity is ignored, so a same-named clause of another arity counts.
  defp helper_calls(body, aliases, imports, defs) do
    {_, found} =
      Macro.prewalk(body, [], fn
        {{:., _, [{:__aliases__, _, segments}, name]}, _, args} = node, acc
        when is_atom(name) and is_list(args) ->
          {node, [{IdempotencyMounts.module(segments, aliases), name} | acc]}

        {:&, _, [{:/, _, [{name, _, ctx}, arity]}]} = node, acc
        when is_atom(name) and is_atom(ctx) and is_integer(arity) ->
          {node, imported(name, imports, defs) ++ acc}

        {name, _, args} = node, acc when is_atom(name) and is_list(args) ->
          {node, imported(name, imports, defs) ++ acc}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp imported(name, imports, defs) do
    if Map.has_key?(defs, name),
      do: [],
      else: for({module, admits?} <- imports, admits?.(name), do: {module, name})
  end

  # The source AST of a module compiled from a file in this project (not deps,
  # not Elixir or OTP), else nil.
  defp project_ast(nil), do: nil

  defp project_ast(module) do
    with true <- Code.ensure_loaded?(module),
         source when not is_nil(source) <- module.module_info(:compile)[:source],
         path = to_string(source),
         true <- project_source?(path),
         {:ok, ast} <- path |> File.read!() |> Code.string_to_quoted() do
      ast
    else
      _ -> nil
    end
  end

  defp project_source?(path) do
    relative = Path.relative_to(path, @api_root)

    relative != path and File.exists?(path) and
      not String.starts_with?(relative, ["deps/", "_build/"])
  end

  defp local_defs(ast) do
    {_, defs} =
      Macro.prewalk(ast, %{}, fn
        {kind, _, [head, body]} = node, acc when kind in [:def, :defp] ->
          {node, Map.update(acc, def_name(head), [body], &[body | &1])}

        node, acc ->
          {node, acc}
      end)

    defs
  end

  defp def_name({:when, _, [head | _]}), do: def_name(head)
  defp def_name({name, _, _}), do: name

  # A call `name(...)`, or a capture `&name/n` (whose AST holds `{name, _, nil}`).
  defp local_calls(body, defs) do
    {_, calls} =
      Macro.prewalk(body, [], fn
        {name, _, args} = node, acc when is_atom(name) and (is_list(args) or is_nil(args)) ->
          if Map.has_key?(defs, name), do: {node, [name | acc]}, else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    calls
  end

  # Mutating routes whose controller mounts the plug for that action.
  defp controller_covered_routes do
    mounts = controller_mounts()

    for route <- BarkparkWeb.Router.__routes__(),
        route.verb in @mutating_verbs and is_atom(route.plug_opts),
        {module, actions, ast} <- mounts,
        route.plug == module,
        actions == :all or route.plug_opts in actions do
      {route.verb, route.path, module, route.plug_opts, ast}
    end
  end

  # ── positive controls: prove the scan can SEE ───────────────────────────

  test "CONTROL: the controller scan finds ChatController's mount for the chat send" do
    assert Enum.any?(controller_mounts(), fn {module, actions, _} ->
             module == BarkparkWeb.ChatController and actions == [:create_message]
           end),
           "the controller scan lost sight of ChatController's Idempotency mount. Found: " <>
             inspect(Enum.map(controller_mounts(), fn {m, a, _} -> {m, a} end))

    assert Enum.any?(controller_covered_routes(), fn {verb, _path, _m, action, _} ->
             verb == :post and action == :create_message
           end),
           "POST /v1/chat/sessions/:id/messages is not in the controller-covered set"
  end

  test "CONTROL: the per-action walk sees ChatController's SSE action stream, not the send" do
    {_, _, ast} = Enum.find(controller_mounts(), &(elem(&1, 0) == BarkparkWeb.ChatController))

    assert action_streams?(ast, :events),
           "ChatController.events/2 streams over SSE; a walk that cannot see it measures nothing"

    refute action_streams?(ast, :create_message)
  end

  test "CONTROL: the router scan finds the two known Idempotency pipelines" do
    pipelines = idempotency_pipelines()

    assert MapSet.member?(pipelines, :idempotent),
           "the AST scan lost sight of `pipeline :idempotent` — it is measuring nothing. " <>
             "Found: #{inspect(MapSet.to_list(pipelines))}"

    assert MapSet.member?(pipelines, :scoped_mutate),
           "the AST scan lost sight of `pipeline :scoped_mutate` — it is measuring nothing. " <>
             "Found: #{inspect(MapSet.to_list(pipelines))}"
  end

  test "CONTROL: the scan does NOT flag a pipeline that has no Idempotency plug" do
    refute MapSet.member?(idempotency_pipelines(), :api),
           "`pipeline :api` does not mount Idempotency; a scan that flags it discriminates nothing"
  end

  test "CONTROL: the streaming detector fires on a known chunked controller" do
    assert streaming_module?(BarkparkWeb.ExportController),
           "ExportController streams via send_chunked/2 — a detector that cannot see it " <>
             "would pass the real test vacuously"
  end

  test "CONTROL: the streaming detector does NOT fire on a plain JSON controller" do
    refute streaming_module?(BarkparkWeb.MutateController),
           "MutateController answers with send_resp/3; a detector that flags it " <>
             "would red on every idempotent route"
  end

  test "CONTROL: at least one mutating route actually rides an Idempotency pipeline" do
    covered = covered_mutating_routes()

    assert covered != [],
           "no mutating route rides an Idempotency pipeline — the main assertion below " <>
             "would be vacuously green"

    assert Enum.any?(covered, fn {_verb, _path, module, action} ->
             module == BarkparkWeb.MutateController and action == :mutate
           end),
           "expected POST /v1/data/mutate/:dataset to be in the covered set. " <>
             "Got: #{inspect(covered)}"
  end

  # ── one level into helper modules (task-a98630688d97c311) ───────────────
  #
  # A MUTANT helper, compiled from a file under the test's tmp_dir so its
  # `module_info(:compile)[:source]` is a real project path. `reply/1` streams
  # through a private function; `harmless/1` does not.
  defp compile_mutant_helper!(dir, name) do
    path = Path.join(dir, "#{name}.ex")

    File.write!(path, """
    defmodule Barkpark.Test.#{name} do
      import Plug.Conn
      def reply(conn), do: open_stream(conn)
      def harmless(conn), do: conn
      defp open_stream(conn), do: send_chunked(conn, 200)
    end
    """)

    Code.compile_file(path)
    Module.concat([Barkpark.Test, name])
  end

  # ChatController's real AST, with `call` put in front of `create_message/2`'s
  # body (and `prelude`, an alias or import, inside the module). Both are
  # source text, parsed, so their AST has the shape a real file gives.
  defp chat_controller_with(prelude, call) do
    {_, _, ast} = Enum.find(controller_mounts(), &(elem(&1, 0) == BarkparkWeb.ChatController))
    prelude = Code.string_to_quoted!(prelude)
    call = Code.string_to_quoted!(call)

    Macro.prewalk(ast, fn
      {:def, meta, [{:create_message, _, _} = head, [do: body]]} ->
        {:def, meta, [head, [do: {:__block__, [], [prelude, call, body]}]]}

      node ->
        node
    end)
  end

  test "CONTROL: the helper walk reads create_message's real project helpers, not stdlib" do
    {_, _, ast} = Enum.find(controller_mounts(), &(elem(&1, 0) == BarkparkWeb.ChatController))
    defs = local_defs(ast)
    targets = [:create_message] |> reached_bodies(defs) |> helper_targets(ast, defs)

    assert Map.has_key?(targets, BarkparkWeb.ChatUserTurn),
           "create_message calls ChatUserTurn.resolve/…; a walk that cannot read it " <>
             "passes every helper vacuously. Read: #{inspect(Map.keys(targets))}"

    refute Map.has_key?(targets, Map)
    refute Map.has_key?(targets, Ecto.UUID)
  end

  @tag :tmp_dir
  test "MUTANT: create_message calling an ALIASED helper that streams reds", %{tmp_dir: dir} do
    helper = compile_mutant_helper!(dir, "MutantAliasedStreamHelper")

    ast =
      chat_controller_with(
        "alias #{inspect(helper)}",
        "MutantAliasedStreamHelper.reply(conn)"
      )

    assert action_streams?(ast, :create_message),
           "create_message reaches send_chunked/2 through #{inspect(helper)}.reply/1; " <>
             "a walk that stops at the module boundary passes it"
  end

  @tag :tmp_dir
  test "MUTANT: create_message calling an IMPORTED helper that streams reds", %{tmp_dir: dir} do
    helper = compile_mutant_helper!(dir, "MutantImportedStreamHelper")

    ast =
      chat_controller_with(
        "import #{inspect(helper)}",
        "conn |> reply()"
      )

    assert action_streams?(ast, :create_message)
  end

  @tag :tmp_dir
  test "MUTANT: a helper function that does not stream stays green", %{tmp_dir: dir} do
    helper = compile_mutant_helper!(dir, "MutantHarmlessHelper")

    ast =
      chat_controller_with(
        "alias #{inspect(helper)}",
        "&MutantHarmlessHelper.harmless/1"
      )

    refute action_streams?(ast, :create_message),
           "only the CALLED helper function counts; the module's other functions do not"
  end

  # A false red on someone else's PR: an `import ..., only:` that leaves the
  # streaming function out, and a VARIABLE named like it, are not calls into it.
  @tag :tmp_dir
  test "MUTANT: an import's only:/except: and a same-named variable stay green",
       %{tmp_dir: dir} do
    helper = compile_mutant_helper!(dir, "MutantOnlyHelper")

    for {prelude, call} <- [
          {"import #{inspect(helper)}, only: [harmless: 1]", "reply = harmless(conn)\nreply"},
          {"import #{inspect(helper)}, except: [reply: 1]", "reply(conn)"},
          {"import #{inspect(helper)}", "reply = harmless(conn)\nreply"}
        ] do
      refute action_streams?(chat_controller_with(prelude, call), :create_message),
             "wrongly red: #{prelude} / #{call}"
    end

    assert action_streams?(
             chat_controller_with("import #{inspect(helper)}, only: [reply: 1]", "reply(conn)"),
             :create_message
           ),
           "only: that names the streaming function still reaches it"

    assert action_streams?(
             chat_controller_with("import #{inspect(helper)}", "f = &reply/1\nf.(conn)"),
             :create_message
           ),
           "a capture of an imported streaming function still reaches it"
  end

  # `alias __MODULE__.Inner` resolves to no module the scan can name: it is
  # skipped, never a crash that reds an unrelated PR.
  @tag :tmp_dir
  test "a controller that aliases __MODULE__.Inner scans without crashing", %{tmp_dir: dir} do
    path = Path.join(dir, "mutant_inner_alias_controller.ex")

    File.write!(path, """
    defmodule Barkpark.Test.MutantInnerAliasController do
      defmodule Inner do
        def go(conn), do: conn
      end

      alias __MODULE__.Inner
      def create(conn, _params), do: Inner.go(conn)
    end
    """)

    Code.compile_file(path)
    refute streaming_module?(Barkpark.Test.MutantInnerAliasController)
  end

  @tag :tmp_dir
  test "MUTANT: a router-mounted controller calling a streaming helper reds", %{tmp_dir: dir} do
    helper = compile_mutant_helper!(dir, "MutantRouterStreamHelper")
    # One file each: streaming_module?/1 reads the module's whole source file.
    for {file, source} <- [
          {"mutant_router_controller.ex",
           """
           defmodule Barkpark.Test.MutantRouterController do
             alias #{inspect(helper)}, as: Out
             def create(conn, _params), do: Out.reply(conn)
           end
           """},
          {"mutant_router_harmless_controller.ex",
           """
           defmodule Barkpark.Test.MutantRouterHarmlessController do
             def create(conn, _params), do: #{inspect(helper)}.harmless(conn)
           end
           """}
        ] do
      path = Path.join(dir, file)
      File.write!(path, source)
      Code.compile_file(path)
    end

    assert streaming_module?(Barkpark.Test.MutantRouterController)
    refute streaming_module?(Barkpark.Test.MutantRouterHarmlessController)
  end

  # ── the assertion ───────────────────────────────────────────────────────

  test "no chunked or file-sending controller sits under an Idempotency mount" do
    offenders =
      covered_mutating_routes()
      |> Enum.filter(fn {_verb, _path, module, _action} -> streaming_module?(module) end)

    offenders =
      offenders ++
        for {verb, path, module, action, ast} <- controller_covered_routes(),
            action_streams?(ast, action),
            do: {verb, path, module, action}

    assert offenders == [],
           """
           A streaming action is mounted under BarkparkWeb.Plugs.Idempotency.

           #{Enum.map_join(offenders, "\n", fn {verb, path, m, a} -> "  #{String.upcase(to_string(verb))} #{path} -> #{inspect(m)}.#{a}/2" end)}

           `send_chunked/2` and `send_file/3..5` nil `resp_body` BEFORE running the
           before_send callbacks, so the Idempotency plug has no body to cache. It now
           refuses (releases the claim, logs, raises) rather than caching an empty body
           and replaying an empty 2xx for the key's lifetime — which means this route
           would 500 at runtime.

           Fix: answer this action with send_resp/3, or take it off the Idempotency
           pipeline (a streaming response cannot be replayed from a receipt anyway).
           """
  end

  # `__routes__/0` does NOT retain `pipe_through`, so the mount↔route join is
  # made in the router's own AST: every `scope` block whose `pipe_through` names
  # an Idempotency pipeline contributes its verb calls (and its NESTED scopes',
  # which inherit that pipe_through in Phoenix). The AST gives an unqualified
  # controller alias, so the triple {verb, last alias segment, action} is joined
  # back against `__routes__/0` to recover the fully-qualified module.
  defp covered_mutating_routes do
    pipelines = idempotency_pipelines()
    {:ok, ast} = @router_source |> File.read!() |> Code.string_to_quoted()

    triples =
      Macro.prewalk(ast, [], fn
        {:scope, _, args} = node, acc ->
          case Enum.find(args, &match?([{:do, _}], &1)) do
            [{:do, body}] ->
              if pipes_through_idempotency?(body, pipelines),
                do: {node, verb_calls(body) ++ acc},
                else: {node, acc}

            _ ->
              {node, acc}
          end

        node, acc ->
          {node, acc}
      end)
      |> elem(1)
      |> MapSet.new()

    BarkparkWeb.Router.__routes__()
    |> Enum.filter(fn route ->
      route.verb in @mutating_verbs and is_atom(route.plug_opts) and
        MapSet.member?(
          triples,
          {route.verb, route.plug |> Module.split() |> List.last(), route.plug_opts}
        )
    end)
    |> Enum.map(&{&1.verb, &1.path, &1.plug, &1.plug_opts})
  end

  defp pipes_through_idempotency?(body, pipelines) do
    Macro.prewalk(body, false, fn
      {:pipe_through, _, [names]} = node, acc when is_list(names) ->
        {node, acc or Enum.any?(names, &(is_atom(&1) and MapSet.member?(pipelines, &1)))}

      {:pipe_through, _, [name]} = node, acc when is_atom(name) ->
        {node, acc or MapSet.member?(pipelines, name)}

      node, acc ->
        {node, acc}
    end)
    |> elem(1)
  end

  defp verb_calls(body) do
    Macro.prewalk(body, [], fn
      {verb, _, [_path, {:__aliases__, _, segments}, action | _]} = node, acc
      when verb in @mutating_verbs and is_atom(action) ->
        {node, [{verb, to_string(List.last(segments)), action} | acc]}

      node, acc ->
        {node, acc}
    end)
    |> elem(1)
  end
end
