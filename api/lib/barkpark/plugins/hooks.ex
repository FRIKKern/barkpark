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
      case safe_invoke(hook_fn, payload) do
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
      fn hook_fn ->
        start = System.monotonic_time(:millisecond)
        _ = safe_invoke(hook_fn, payload)
        duration = System.monotonic_time(:millisecond) - start

        if duration > @slow_hook_threshold_ms do
          Logger.warning(
            "Barkpark.Plugins.Hooks: slow #{event} hook " <>
              "#{inspect(hook_fn)}: #{duration}ms"
          )
        end

        :telemetry.execute(
          [:barkpark, :hooks, event, :hook],
          %{duration_ms: duration},
          %{event: event, hook: hook_fn}
        )
      end,
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
