defmodule Barkpark.Plugins.Registry.ResolverChain do
  @moduledoc """
  The resolver-chain core for `Barkpark.Plugins.Registry`.

  Extracted (Goal modularity-registry) as a behavior-preserving facade split.
  `reduce_resolvers/3` is the single internal driver every collector funnels
  through: it picks plugins via the documented source-of-truth order, then
  threads `prev` through each plugin's resolver call. Module location only,
  NO logic change to resolution semantics or plugin iteration order.

  ## Plugin iteration source of truth

  `reduce_resolvers/3` iterates plugins via this precedence:

    1. `Application.get_env(:barkpark, :plugins, [])` — the explicit
       load-order list per plan §0 Q2, when configured.
    2. Otherwise the GenServer-backed `Registry.all/0`, sorted alphabetically
       by plugin name — the legacy behaviour, preserved so dev/test plugins
       that register without an Application config entry continue to work.

  Whichever source provides the names, each name is resolved to its
  registered entry via `Registry.lookup/1`; plugins listed in config but
  never registered are silently skipped (with a debug log line).
  """

  require Logger

  alias Barkpark.Plugins.Registry

  # Resolver-callback ↔ additive-callback metadata. Used by `reduce_resolvers/3`
  # to know how to lift the additive form when a plugin only exports it, and by
  # `warn_duplicate_forms/0` to flag plugins that define both.
  #
  # Shape: %{resolver_name => {additive_name, additive_arity, additive_default, lift_kind}}
  #   * lift_kind :: :list_concat | :map_merge | :none (no additive lift, identity default)
  @resolver_callbacks %{
    resolve_checkers: {:checkers, 0, [], :list_concat},
    resolve_action_handlers: {:action_handlers, 0, %{}, :map_merge},
    resolve_external_sync_entries: {:external_sync_entries, 0, %{}, :map_merge},
    resolve_codelist_seeders: {:codelist_seeders, 0, [], :list_concat},
    resolve_settings_schema: {:settings_schema, 0, [], :list_concat},
    resolve_top_menu_entries: {:top_menu_entries, 0, [], :list_concat},
    resolve_desk_items: {:desk_items, 1, [], :list_concat},
    resolve_doc_actions: {nil, nil, nil, :none},
    # {nil, nil, nil, :none} — the resolve_doc_actions precedent: NO additive
    # lift. The `__using__` default `resolve_extract_edges/2` provides the lift
    # `prev ++ extract_edges(ctx.doc, ctx)` itself, so the registry threads ONLY
    # the resolver form. The nil additive makes `apply_resolver/8`'s additive
    # branch (guarded `is_atom(additive) and not is_nil(additive)`) and
    # `warn_duplicate_forms/0` (same guard) both skip this entry — so
    # `resolver_is_default_lift?/4` (whose Map.fetch! case has clauses ONLY for
    # :map_merge/[] defaults) is NEVER reached for it.
    resolve_extract_edges: {nil, nil, nil, :none},
    resolve_api_tests: {:api_tests, 0, [], :list_concat},
    resolve_cli_commands: {:cli_commands, 0, [], :list_concat}
  }

  # ─── Resolver chain core ────────────────────────────────────────────────
  #
  # `reduce_resolvers/3` is the single internal driver every collector funnels
  # through. It picks plugins via the documented source-of-truth order, then
  # threads `prev` through each plugin's resolver call.

  @doc false
  @spec reduce_resolvers(atom(), term(), map()) :: term()
  def reduce_resolvers(callback_name, baseline, ctx) when is_atom(callback_name) do
    {additive, additive_arity, default, lift_kind} =
      Map.fetch!(@resolver_callbacks, callback_name)

    Enum.reduce(load_ordered_plugins(), baseline, fn entry, prev ->
      apply_resolver(
        entry,
        callback_name,
        additive,
        additive_arity,
        default,
        lift_kind,
        prev,
        ctx
      )
    end)
  end

  # Resolve the in-order list of registered plugin entries, source of truth
  # documented in the moduledoc. Application config wins when set; otherwise
  # fall back to alphabetical-by-name over the GenServer state (legacy).
  @doc false
  def load_ordered_plugins do
    case Application.get_env(:barkpark, :plugins, []) do
      [] ->
        Registry.all() |> Enum.sort_by(& &1.name)

      configured when is_list(configured) ->
        configured
        |> Enum.map(&plugin_name_of/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.flat_map(fn name ->
          case Registry.lookup(name) do
            {:ok, entry} ->
              [entry]

            :error ->
              Logger.debug(
                "Barkpark.Plugins.Registry: plugin #{inspect(name)} listed in " <>
                  ":barkpark, :plugins but not registered — skipping"
              )

              []
          end
        end)
    end
  end

  # The Application config entry can be a bare module atom, a `{name, module}`
  # tuple, or a string plugin name. We only need the name to look up the
  # registered entry — module form gets reverse-mapped via `Registry.all/0`.
  defp plugin_name_of(name) when is_binary(name), do: name

  defp plugin_name_of({name, _module}) when is_binary(name), do: name

  defp plugin_name_of(module) when is_atom(module) do
    Enum.find_value(Registry.all(), fn entry ->
      if entry.module == module, do: entry.name
    end)
  end

  defp plugin_name_of(_), do: nil

  # Per-plugin resolver dispatch. Three paths:
  #
  #   1. Plugin overrode `resolve_X/2`  →  call it directly.
  #   2. Plugin only exports the additive form  →  call it and lift into the
  #      resolver shape (concat for lists, Map.merge for maps).
  #   3. Plugin exports neither  →  return prev unchanged.
  #
  # Path 1 covers `use Barkpark.Plugin` plugins (whose `__using__` ships a
  # default `resolve_X/2` that already does the additive lift internally) AND
  # plugins that explicitly override the resolver to mutate.
  #
  # Path 2 covers bare test fakes that define just `top_menu_entries/0`
  # without `use Barkpark.Plugin`. These never hit path 1 because the
  # `__using__` macro is the only thing that exports `resolve_X/2` by default.
  defp apply_resolver(
         entry,
         resolver,
         additive,
         additive_arity,
         default,
         lift_kind,
         prev,
         ctx
       ) do
    mod = entry.module

    cond do
      not Code.ensure_loaded?(mod) ->
        prev

      function_exported?(mod, resolver, 2) ->
        safe_resolver_call(mod, resolver, prev, ctx)

      is_atom(additive) and not is_nil(additive) and is_integer(additive_arity) and
          function_exported?(mod, additive, additive_arity) ->
        result =
          if additive_arity == 0 do
            safe_call(mod, additive, [], default)
          else
            # Only `desk_items/1` has arity 1 today; the arg is dataset.
            dataset = Map.get(ctx, :dataset, "production")
            safe_call(mod, additive, [dataset], default)
          end

        lift(prev, result, lift_kind)

      true ->
        prev
    end
  end

  defp safe_resolver_call(module, resolver, prev, ctx) do
    try do
      apply(module, resolver, [prev, ctx])
    rescue
      e ->
        Logger.warning(
          "Barkpark.Plugins.Registry: #{inspect(module)}.#{resolver}/2 raised — " <>
            Exception.message(e)
        )

        prev
    catch
      kind, reason ->
        Logger.warning(
          "Barkpark.Plugins.Registry: #{inspect(module)}.#{resolver}/2 threw " <>
            "#{kind} #{inspect(reason)}"
        )

        prev
    end
  end

  defp lift(prev, result, :list_concat) when is_list(prev) and is_list(result),
    do: prev ++ result

  defp lift(prev, result, :map_merge) when is_map(prev) and is_map(result),
    do: Map.merge(prev, result)

  # Defensive: a misbehaving additive return falls through to prev so a
  # malformed plugin can't corrupt the accumulator.
  defp lift(prev, _result, _lift_kind), do: prev

  # ─── Top-menu compute ───────────────────────────────────────────────────

  # Top-menu collection adds normalisation + sort on top of the bare chain
  # so plugin-supplied entries get a stable `:order` default and the final
  # output is sorted by `{order, label}` regardless of registration order.
  @doc false
  def compute_top_menu_entries(baseline, ctx) do
    :resolve_top_menu_entries
    |> reduce_resolvers(baseline, ctx)
    |> Enum.map(&normalize_top_menu_entry/1)
    |> Enum.sort_by(fn e -> {e.order, e.label} end)
  end

  defp normalize_top_menu_entry(entry) when is_map(entry) do
    %{
      label: to_string(entry[:label] || entry["label"] || ""),
      path: to_string(entry[:path] || entry["path"] || "/"),
      icon: entry[:icon] || entry["icon"],
      order: entry[:order] || entry["order"] || 100,
      active_when: entry[:active_when] || entry["active_when"]
    }
  end

  # ─── Duplicate-form warning ─────────────────────────────────────────────

  @doc """
  Iterate registered plugins; for each (plugin, resolver-callback) pair
  where the plugin exports BOTH the resolver and the additive form, log
  one `Logger.warning` line naming the plugin and callback. The resolver
  always wins — this warning exists to nudge plugin authors toward
  removing the dead additive code.

  Idempotent and cheap (read-only loop). Called from `Registry.init/1` after
  the first discovery sweep, and again on every `register/2` so a runtime
  addition gets flagged.
  """
  @spec warn_duplicate_forms() :: :ok
  def warn_duplicate_forms do
    for entry <- Registry.all() do
      mod = entry.module

      if Code.ensure_loaded?(mod) do
        for {resolver, {additive, additive_arity, _default, _lift}} <- @resolver_callbacks,
            is_atom(additive) and not is_nil(additive) and is_integer(additive_arity),
            function_exported?(mod, resolver, 2),
            function_exported?(mod, additive, additive_arity) do
          # Only flag when the plugin has OVERRIDDEN the resolver — the
          # `use Barkpark.Plugin` default exports `resolve_X/2` for every
          # plugin, so a bare `function_exported?` check would warn on every
          # plugin that uses the additive form. Compare bytecode equality
          # against the additive lift: if the resolver is the synthesised
          # default, skip the warning.
          unless resolver_is_default_lift?(mod, resolver, additive, additive_arity) do
            Logger.warning(
              "Barkpark.Plugins.Registry: plugin #{entry.name} defines both " <>
                "#{resolver}/2 and #{additive}/#{additive_arity} — preferring resolver"
            )
          end
        end
      end
    end

    :ok
  end

  # Check whether the plugin's `resolve_X/2` is the macro-injected default
  # lift supplied by `Barkpark.Plugin.__using__/1`. This is deliberately a
  # BEHAVIORAL fingerprint, not a static check: `__using__/1` injects a
  # default `resolve_X/2` for EVERY plugin, so `function_exported?` cannot
  # distinguish an author override from the injected default — they're both
  # exported functions. There is no AST at runtime to inspect either. The
  # only signal left is to RUN the callbacks and compare results: call the
  # additive form and the resolver with a known empty `prev` + ctx, then test
  # whether the resolver returned exactly `prev ++ additive_result` (lists) or
  # `Map.merge(prev, additive_result)` (maps). Equal → it's the default lift,
  # no warning. Different → the author overrode it, warn.
  #
  # This runs ONCE per plugin at registration (from `warn_duplicate_forms/0`),
  # not on any hot path. It relies on the additive callbacks being
  # side-effect-free pure data returns — which the plugin contract requires —
  # since invoking them here for the fingerprint must be safe to repeat.
  #
  # Avoids false positives on the wide ecosystem of plugins that legitimately
  # use only the additive form.
  defp resolver_is_default_lift?(module, resolver, additive, additive_arity) do
    {empty_prev, ctx} =
      case Map.fetch!(@resolver_callbacks, resolver) do
        {_, _, %{} = empty, :map_merge} -> {empty, %{dataset: "production"}}
        {_, _, [], _} -> {[], %{dataset: "production"}}
      end

    try do
      additive_result =
        if additive_arity == 0 do
          apply(module, additive, [])
        else
          apply(module, additive, ["production"])
        end

      resolver_result = apply(module, resolver, [empty_prev, ctx])

      cond do
        is_list(empty_prev) and is_list(additive_result) ->
          resolver_result == empty_prev ++ additive_result

        is_map(empty_prev) and is_map(additive_result) ->
          resolver_result == Map.merge(empty_prev, additive_result)

        true ->
          false
      end
    rescue
      _ -> false
    catch
      _, _ -> false
    end
  end

  # Invoke `module.function(args)` only when exported. Errors / non-export
  # fall back to the supplied default. Centralised so all collectors share
  # the same defensive shape.
  @doc false
  def safe_call(module, fun, args, default) do
    try do
      if Code.ensure_loaded?(module) and function_exported?(module, fun, length(args)) do
        apply(module, fun, args)
      else
        default
      end
    rescue
      e ->
        Logger.warning(
          "Barkpark.Plugins.Registry: #{inspect(module)}.#{fun}/#{length(args)} raised — " <>
            Exception.message(e)
        )

        default
    end
  end
end
