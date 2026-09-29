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
    * the streaming actions are read out of each controller's own AST.

  Only mutating verbs are scanned, because `Idempotency.call/2` returns the conn
  untouched for anything outside `POST/PUT/PATCH/DELETE`.

  Reads `router.ex`; never writes it.
  """

  use ExUnit.Case, async: true

  @router_source Path.join(__DIR__, "../../lib/barkpark_web/router.ex") |> Path.expand()
  @mutating_verbs ~w(post put patch delete)a
  @streaming_calls [:send_chunked, :send_file]

  # ── the scan ────────────────────────────────────────────────────────────

  defp idempotency_pipelines do
    {:ok, ast} = @router_source |> File.read!() |> Code.string_to_quoted()

    {_, acc} =
      Macro.prewalk(ast, [], fn
        {:pipeline, _, [name, [do: body]]} = node, acc when is_atom(name) ->
          if mounts_idempotency?(body), do: {node, [name | acc]}, else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    MapSet.new(acc)
  end

  defp mounts_idempotency?(body) do
    {_, found} =
      Macro.prewalk(body, false, fn
        {:plug, _, [{:__aliases__, _, segments} | _]} = node, _acc
        when segments != [] ->
          {node, List.last(segments) == :Idempotency and :Plugs in segments}

        node, acc ->
          {node, acc}
      end)

    found
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

  defp calls_streaming?(body) do
    {_, found} =
      Macro.prewalk(body, false, fn
        {call, _, _} = node, _acc when call in @streaming_calls -> {node, true}
        node, acc -> {node, acc}
      end)

    found
  end

  # ── positive controls: prove the scan can SEE ───────────────────────────

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
