defmodule Barkpark.Plugins.Hooks do
  @moduledoc """
  Lifecycle-hook dispatcher.

  `fire(event, payload)` runs all plugin-declared hooks for `event`:

  - `before_*` events fire sequentially in plugin load order. Each hook
    returns `:ok` (continue) or `{:halt, reason}` (cancel). The first
    halt short-circuits the chain; subsequent hooks do NOT run.
    Return value: `:ok` or `{:halt, reason}`.

  - `after_*` events fire asynchronously via `Task.async_stream` with
    a 5s per-hook timeout. Return values are discarded. The dispatcher
    returns `:ok` once the supervised stream has drained (per-hook
    timeouts are killed by `on_timeout: :kill_task`).

  Plugin source: `Application.get_env(:barkpark, :plugins, [])` (or
  `Barkpark.Plugins.Registry.all/0` when the application config is
  empty — same source-of-truth as the resolver chain in Registry).
  Decisions per plan §0: hybrid async (Q1), no mutation (Q2), capture
  refs (Q3), hook self-guards on `ctx.source` (Q5), telemetry over
  suppression (Q6).
  """

  require Logger

  @before_events ~w(before_save before_publish before_unpublish before_delete)a
  @after_events ~w(after_save after_publish after_unpublish after_delete)a

  @hook_timeout_ms 5_000
  @slow_hook_threshold_ms 100

  @doc """
  Fire a lifecycle event.

  Returns `:ok` or `{:halt, reason}` for `before_*`. Returns `:ok` for `after_*`.
  Never raises — bad plugin code is logged and treated as `:ok`.
  """
  @spec fire(Barkpark.Plugin.lifecycle_event(), Barkpark.Plugin.hook_payload()) ::
          :ok | {:halt, String.t()}
  def fire(event, %{event: event} = payload) when event in @before_events do
    event
    |> plugins_for()
    |> Enum.reduce_while(:ok, fn hook_fn, _acc ->
      # TIMED: before_* hooks run SYNCHRONOUSLY on the write's stack (the
      # sheets before_save gate does a full Engine recompute here), so a slow
      # one stalls every save. `timed_invoke` emits the same duration event as
      # the after_* chain and warns past @slow_hook_threshold_ms — answering
      # "which plugin hook is slowing our writes?" for the before path too.
      case timed_invoke(event, hook_fn, payload) do
        :ok ->
          {:cont, :ok}

        {:halt, reason} when is_binary(reason) ->
          {:halt, {:halt, reason}}

        other ->
          Logger.warning(
            "Barkpark.Plugins.Hooks: hook #{inspect(hook_fn)} returned " <>
              "#{inspect(other)} on #{event} — treating as :ok " <>
              "(before_* hooks may only return :ok | {:halt, reason})"
          )

          {:cont, :ok}
      end
    end)
  end

  def fire(event, %{event: event} = payload) when event in @after_events do
    hooks = plugins_for(event)

    :telemetry.execute(
      [:barkpark, :hooks, event],
      %{count: length(hooks)},
      %{event: event}
    )

    hooks
    |> Task.async_stream(
      fn hook_fn -> timed_invoke(event, hook_fn, payload) end,
      timeout: @hook_timeout_ms,
      max_concurrency: System.schedulers_online(),
      on_timeout: :kill_task,
      ordered: false
    )
    |> Stream.run()

    :ok
  end

  def fire(event, _payload) do
    Logger.warning("Barkpark.Plugins.Hooks: unknown lifecycle event #{inspect(event)}; ignoring")

    :ok
  end

  # ─── Internals ──────────────────────────────────────────────────────────

  # Return hook functions for an event across all plugins, in plugin load order.
  defp plugins_for(event) do
    for plugin <- load_ordered_plugins(),
        hook <- Map.get(safe_hooks(plugin), event, []),
        is_function(hook, 1) do
      hook
    end
  end

  defp safe_hooks(plugin) do
    cond do
      not is_atom(plugin) ->
        %{}

      not Code.ensure_loaded?(plugin) ->
        %{}

      not function_exported?(plugin, :lifecycle_hooks, 0) ->
        %{}

      true ->
        try do
          case plugin.lifecycle_hooks() do
            %{} = m -> m
            _ -> %{}
          end
        rescue
          e ->
            Logger.warning(
              "Barkpark.Plugins.Hooks: #{inspect(plugin)}.lifecycle_hooks/0 raised — " <>
                "#{Exception.message(e)}; skipping plugin"
            )

            %{}
        catch
          kind, reason ->
            Logger.warning(
              "Barkpark.Plugins.Hooks: #{inspect(plugin)}.lifecycle_hooks/0 threw " <>
                "#{kind} #{inspect(reason)}; skipping plugin"
            )

            %{}
        end
    end
  end

  # Invoke a single hook under a monotonic-clock timer, then emit ONE
  # fixed-name duration event — `[:barkpark, :hooks, :hook, :stop]` — for BOTH
  # the before_* and after_* chains. Fixed name (not the old dynamic
  # `[:barkpark, :hooks, <event>, :hook]`) so `Telemetry.Metrics` can subscribe
  # a single Prometheus histogram to it (a dynamic segment can't be matched by
  # one metric). The `event`/`module` metadata tags let the histogram answer
  # "which plugin hook (module) is slow, and at which lifecycle stage?". Returns
  # the hook's own return value so the before_* chain can still act on :halt.
  defp timed_invoke(event, hook_fn, payload) do
    start = System.monotonic_time()
    result = safe_invoke(hook_fn, payload)
    duration = System.monotonic_time() - start
    duration_ms = System.convert_time_unit(duration, :native, :millisecond)

    if duration_ms > @slow_hook_threshold_ms do
      Logger.warning(
        "Barkpark.Plugins.Hooks: slow #{event} hook " <>
          "#{inspect(hook_fn)}: #{duration_ms}ms"
      )
    end

    :telemetry.execute(
      [:barkpark, :hooks, :hook, :stop],
      %{duration: duration, duration_ms: duration_ms},
      %{event: event, module: hook_module(hook_fn)}
    )

    result
  end

  # Module a captured hook function was defined in — the plugin identity, used
  # as a bounded telemetry tag ("which PLUGIN's hook is slow"). Anonymous fns
  # resolve to their defining module too; anything non-function → :unknown.
  defp hook_module(fun) when is_function(fun) do
    case Function.info(fun, :module) do
      {:module, mod} -> mod
      _ -> :unknown
    end
  end

  defp hook_module(_), do: :unknown

  defp safe_invoke(hook_fn, payload) do
    hook_fn.(payload)
  rescue
    e ->
      Logger.error(
        "Barkpark.Plugins.Hooks: hook #{inspect(hook_fn)} raised on " <>
          "#{inspect(payload[:event])}: #{Exception.message(e)}"
      )

      :ok
  catch
    kind, reason ->
      Logger.error(
        "Barkpark.Plugins.Hooks: hook #{inspect(hook_fn)} threw " <>
          "#{kind} #{inspect(reason)} on #{inspect(payload[:event])}"
      )

      :ok
  end

  # Plugin module source-of-truth. Mirrors `Registry.load_ordered_plugins/0`
  # precedence: explicit config wins; otherwise fall back to Registry.all/0
  # sorted alphabetically by name. Both paths emit module atoms.
  defp load_ordered_plugins do
    case Application.get_env(:barkpark, :plugins) do
      list when is_list(list) and list != [] ->
        Enum.map(list, &module_of/1) |> Enum.reject(&is_nil/1)

      _ ->
        try do
          Barkpark.Plugins.Registry.all()
          |> Enum.sort_by(& &1.name)
          |> Enum.map(& &1.module)
        rescue
          _ -> []
        catch
          _, _ -> []
        end
    end
  end

  # Application config entries can be a bare module atom, a {name, module}
  # tuple, or a plugin-name string. Reduce each to a module atom.
  defp module_of(mod) when is_atom(mod) and not is_nil(mod), do: mod
  defp module_of({_name, mod}) when is_atom(mod), do: mod

  defp module_of(name) when is_binary(name) do
    try do
      case Barkpark.Plugins.Registry.lookup(name) do
        {:ok, %{module: mod}} -> mod
        _ -> nil
      end
    rescue
      _ -> nil
    catch
      _, _ -> nil
    end
  end

  defp module_of(_), do: nil
end
