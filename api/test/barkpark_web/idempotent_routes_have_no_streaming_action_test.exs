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
      and red if any of them reaches `send_chunked/2` or `send_file/3..5`.

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
          calls_streaming?(ast)
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

  # Does `action` reach a streaming call through the module's own functions?
  # Local calls only: a helper in ANOTHER module is not followed.
  defp action_streams?(ast, action) do
    defs = local_defs(ast)
    reaches_streaming?([action], defs, MapSet.new())
  end

  defp reaches_streaming?([], _defs, _seen), do: false

  defp reaches_streaming?([name | rest], defs, seen) do
    if MapSet.member?(seen, name) do
      reaches_streaming?(rest, defs, seen)
    else
      bodies = Map.get(defs, name, [])

      Enum.any?(bodies, &calls_streaming?/1) or
        reaches_streaming?(
          Enum.flat_map(bodies, &local_calls(&1, defs)) ++ rest,
          defs,
          MapSet.put(seen, name)
        )
    end
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
