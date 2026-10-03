defmodule Barkpark.Test.PagedRoutes do
  @moduledoc """
  The ROUTER arm of the pagination population (task-de4df581f611d49a).

  The manifest arm (`paginated: true` commands) is blind BY CONSTRUCTION to any
  list route that is not a manifest command — `GET /v1/secrets/:name/audit` and
  `GET /v1/data/history/...` paged for months with no truncation signal and no
  check could see them. This arm derives its population from the router:
  every `GET` route whose action reads a `"limit"` or `"offset"` string
  literal, followed through the action's same-module local calls (so a
  `page(params)` helper that does the `Map.get(params, "limit")` counts).

  Derivation is STATIC (the controller's own source, parsed with
  `Code.string_to_quoted!/1`), so it needs no fixture and cannot be satisfied by
  a request that never happened. `derive/2` takes the source reader as an
  argument so a test can hand it a MUTATED source and watch a route fall out.

  What it cannot see, stated rather than discovered: an action that delegates
  the whole `params` map to ANOTHER module which then reads `"limit"`. That
  is why the guard carries a positive control naming routes it must find.
  """

  @paging_literals ["limit", "offset"]

  @typedoc "One derived member: the action is the unit; paths are its routes."
  @type member :: %{key: String.t(), plug: module(), action: atom(), paths: [String.t()]}

  @doc "The router-derived population, one entry per controller action."
  @spec derive([map()], (module() -> String.t())) :: [member()]
  def derive(routes \\ BarkparkWeb.Router.__routes__(), source_of \\ &source_of/1) do
    defs_cache = :ets.new(:paged_routes_defs, [:set, :private])

    try do
      routes
      |> Enum.filter(&(&1.verb == :get and is_atom(&1.plug) and is_atom(&1.plug_opts)))
      |> Enum.filter(&Code.ensure_loaded?(&1.plug))
      |> Enum.filter(fn r ->
        reads_paging?(defs_for(defs_cache, r.plug, source_of), r.plug_opts)
      end)
      |> Enum.group_by(&key(&1.plug, &1.plug_opts))
      |> Enum.map(fn {k, [r | _] = rs} ->
        %{
          key: k,
          plug: r.plug,
          action: r.plug_opts,
          paths: rs |> Enum.map(& &1.path) |> Enum.sort()
        }
      end)
      |> Enum.sort_by(& &1.key)
    after
      :ets.delete(defs_cache)
    end
  end

  @doc "The population key for one action: `\"Elixir.Mod.action\"` minus the prefix."
  def key(plug, action), do: "#{inspect(plug)}.#{action}"

  @doc "The controller's source as compiled."
  def source_of(mod), do: mod.module_info(:compile)[:source] |> to_string() |> File.read!()

  defp defs_for(cache, mod, source_of) do
    case :ets.lookup(cache, mod) do
      [{_, defs}] ->
        defs

      [] ->
        defs = mod |> source_of.() |> Code.string_to_quoted!() |> defs()
        :ets.insert(cache, {mod, defs})
        defs
    end
  end

  # name => [{args, body}] for every def/defp in the source (all arities).
  defp defs(ast) do
    {_, acc} =
      Macro.prewalk(ast, %{}, fn
        {kind, _, [head, body]} = node, acc when kind in [:def, :defp] ->
          case head_name(head) do
            {name, args} -> {node, Map.update(acc, name, [{args, body}], &[{args, body} | &1])}
            nil -> {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    acc
  end

  defp head_name({:when, _, [call | _]}), do: head_name(call)
  defp head_name({name, _, args}) when is_atom(name), do: {name, args || []}
  defp head_name(_), do: nil

  defp reads_paging?(defs, action) do
    defs
    |> reach([action], MapSet.new())
    |> Enum.any?(fn name -> defs |> Map.get(name, []) |> Enum.any?(&literal?/1) end)
  end

  # Same-module local calls reachable from the action (any arity).
  defp reach(_defs, [], seen), do: seen

  defp reach(defs, [name | rest], seen) do
    if MapSet.member?(seen, name) or not Map.has_key?(defs, name) do
      reach(defs, rest, seen)
    else
      called =
        defs
        |> Map.fetch!(name)
        |> Enum.flat_map(fn clause ->
          {_, acc} =
            Macro.prewalk(clause, [], fn
              {n, _, args} = node, acc when is_atom(n) and is_list(args) -> {node, [n | acc]}
              node, acc -> {node, acc}
            end)

          acc
        end)

      reach(defs, called ++ rest, MapSet.put(seen, name))
    end
  end

  defp literal?(clause) do
    {_, found} =
      Macro.prewalk(clause, false, fn
        lit, _ when lit in @paging_literals -> {lit, true}
        node, acc -> {node, acc}
      end)

    found
  end
end
