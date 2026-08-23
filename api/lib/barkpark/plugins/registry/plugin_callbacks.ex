defmodule Barkpark.Plugins.Registry.PluginCallbacks do
  @moduledoc """
  Runtime per-plugin callback dispatch for `Barkpark.Plugins.Registry`:
  first-wins resolvers (content renderer, test connection), codelist-seeder
  execution, and media lifecycle hooks.

  Extracted (Goal modularity-registry) as a behavior-preserving facade split.
  These dispatch into individual plugin modules in load order (via
  `ResolverChain.load_ordered_plugins/0`) or by single-plugin lookup (via
  `Registry.lookup/1`), with per-call defensive `try/rescue` so one
  misbehaving plugin never crashes the host. Module location only, NO logic
  change.
  """

  require Logger

  alias Barkpark.Plugins.Registry
  alias Barkpark.Plugins.Registry.ResolverChain

  @doc """
  First-wins resolver for the Studio preview pane (Goal barkpark-G1
  task s3). Walks every registered plugin in load order (Application
  config when set, otherwise alphabetical-by-name — same source of
  truth as the additive resolver chain), calls `content_renderer/3` on
  each, and returns the FIRST `{:ok, iodata}` it gets back. When every
  plugin returns `:skip` (or no plugin implements the callback) the
  function returns `:none` and the StudioLive caller hides the preview
  pane entirely.

  Three reasons this is a simple first-wins instead of an additive
  `reduce_resolvers/3` fold:

    1. Only one preview can render per doc-type at a time — the pane
       holds a single `<pre>`. Two plugins claiming `"book"` would
       fight over the surface.
    2. The host has no built-in baseline to seed (unlike top-menu /
       desk-items / doc-actions). With plugins=[] there is no preview.
    3. The returned iodata flows straight into the rendered pane — no
       merge / sort / dedup step would be meaningful.

  Defensive: a plugin whose `content_renderer/3` raises is treated as
  `:skip` and the chain continues. The host never crashes because a
  preview renderer exploded mid-edit.
  """
  @spec collect_content_renderer(String.t(), map(), map()) :: {:ok, iodata()} | :none
  def collect_content_renderer(doc_type, content, ctx \\ %{})
      when is_binary(doc_type) and is_map(content) and is_map(ctx) do
    ResolverChain.load_ordered_plugins()
    |> Enum.find_value(:none, fn entry ->
      safe_content_renderer_call(entry.module, doc_type, content, ctx)
    end)
  end

  # Returns `{:ok, iodata}` when the plugin contributes one (Enum.find_value
  # treats any non-nil/non-false return as the hit), or `nil` to keep the
  # chain walking. All non-ok returns + every raise / throw collapse to nil.
  defp safe_content_renderer_call(module, doc_type, content, ctx) do
    cond do
      not Code.ensure_loaded?(module) ->
        nil

      function_exported?(module, :content_renderer, 3) ->
        try do
          case module.content_renderer(doc_type, content, ctx) do
            {:ok, iodata} -> {:ok, iodata}
            :skip -> nil
            _ -> nil
          end
        rescue
          e ->
            Logger.warning(
              "Barkpark.Plugins.Registry: #{inspect(module)}.content_renderer/3 raised — " <>
                Exception.message(e)
            )

            nil
        catch
          kind, reason ->
            Logger.warning(
              "Barkpark.Plugins.Registry: #{inspect(module)}.content_renderer/3 threw " <>
                "#{kind} #{inspect(reason)}"
            )

            nil
        end

      true ->
        nil
    end
  end

  @doc """
  First-wins resolver for `Barkpark.Plugin.test_connection/1` (Goal
  barkpark-G3, task s1). Looks up the plugin by name and calls its
  `test_connection/1` callback. Returns the plugin's result verbatim,
  `{:error, :plugin_not_found}` when no plugin matches the name, and
  `{:error, :not_implemented}` when the matched plugin did not override
  the default callback.

  Unlike `collect_content_renderer/3` this is NOT a chain walk — there
  is one plugin per settings page, identified by the `plugin_name`
  URL segment the admin LiveView already routes on. The host (the
  admin Plugin Settings LiveView) calls this with the live form's
  current `settings` map; the plugin sees the same shape its own
  settings reader (`Bokbasen.Settings.get_credentials/0` etc.) would
  produce.

  Defensive: a plugin whose `test_connection/1` raises is collapsed to
  `{:error, {:raised, message}}` so the host never crashes because a
  connection test exploded mid-form-submit.
  """
  @spec collect_test_connection(plugin_name :: String.t() | atom(), settings :: map()) ::
          Barkpark.Plugin.test_connection_result() | {:error, :plugin_not_found}
  def collect_test_connection(plugin_name, settings) when is_map(settings) do
    name = to_string(plugin_name)

    case Registry.lookup(name) do
      {:ok, %{module: module}} -> safe_test_connection(module, settings)
      :error -> {:error, :plugin_not_found}
    end
  end

  defp safe_test_connection(module, settings) do
    cond do
      not Code.ensure_loaded?(module) ->
        {:error, :not_implemented}

      function_exported?(module, :test_connection, 1) ->
        try do
          module.test_connection(settings)
        rescue
          e ->
            Logger.warning(
              "Barkpark.Plugins.Registry: #{inspect(module)}.test_connection/1 raised — " <>
                Exception.message(e)
            )

            {:error, {:raised, Exception.message(e)}}
        catch
          kind, reason ->
            Logger.warning(
              "Barkpark.Plugins.Registry: #{inspect(module)}.test_connection/1 threw " <>
                "#{kind} #{inspect(reason)}"
            )

            {:error, {kind, inspect(reason)}}
        end

      true ->
        {:error, :not_implemented}
    end
  end

  @doc """
  Walks every registered plugin, calls `codelist_seeders/0` to get a
  list of zero-arg functions, and invokes each one in the configured
  `:plugins` load order (the same order `reduce_resolvers/3` and
  `collect_content_renderer/3` use). Falls back to alphabetical-by-name
  when no `:plugins` order is configured.

  Each seeder is wrapped in `try/rescue` so one failing plugin's seeder
  doesn't abort the rest. Failures log a warning. Returns `:ok` always.

  Not cached — seeders are run for side-effects at boot / admin reload,
  not on hot paths.
  """
  @spec run_all_codelist_seeders() :: :ok
  def run_all_codelist_seeders do
    ResolverChain.load_ordered_plugins()
    |> Enum.each(&run_codelist_seeders_for_entry/1)

    :ok
  end

  @doc """
  Looks up a single plugin by name and runs its codelist seeders. Used by
  the plugin admin LV's per-plugin Reload button. Returns `:ok` when the
  plugin was found (per-seeder failures are logged, not raised, matching
  `run_all_codelist_seeders/0`); `{:error, :unknown_plugin}` when not
  registered.

  Records the result into `Barkpark.Plugins.RunStatus` under `:seed`.
  """
  @spec run_codelist_seeders_by_name(String.t()) :: :ok | {:error, :unknown_plugin}
  def run_codelist_seeders_by_name(plugin_name) when is_binary(plugin_name) do
    case Registry.lookup(plugin_name) do
      {:ok, entry} ->
        run_codelist_seeders_for_entry(entry)
        :ok

      :error ->
        {:error, :unknown_plugin}
    end
  end

  defp run_codelist_seeders_for_entry(%{name: name, module: module}) do
    seeders = ResolverChain.safe_call(module, :codelist_seeders, [], [])

    {ok_count, errors} =
      if is_list(seeders) do
        Enum.reduce(seeders, {0, []}, fn seeder, {ok_acc, err_acc} ->
          case invoke_seeder(seeder, name) do
            :ok -> {ok_acc + 1, err_acc}
            {:error, reason} -> {ok_acc, [reason | err_acc]}
          end
        end)
      else
        {0, []}
      end

    result =
      case errors do
        [] -> {:ok, ok_count}
        _ -> {:error, Enum.reverse(errors)}
      end

    Barkpark.Plugins.RunStatus.record(:seed, name, result)
    result
  end

  defp invoke_seeder(seeder, plugin_name) do
    try do
      cond do
        is_function(seeder, 0) ->
          classify_seeder_result(seeder.())

        true ->
          {:error, {:not_a_zero_arity_function, seeder}}
      end
    rescue
      e ->
        Logger.warning(
          "Barkpark.Plugins.Registry: codelist seeder #{inspect(seeder)} from plugin " <>
            "#{plugin_name} raised — #{Exception.message(e)}"
        )

        {:error, {:raised, Exception.message(e)}}
    catch
      kind, reason ->
        Logger.warning(
          "Barkpark.Plugins.Registry: codelist seeder #{inspect(seeder)} from plugin " <>
            "#{plugin_name} threw #{kind} #{inspect(reason)}"
        )

        {:error, {kind, inspect(reason)}}
    end
  end

  # A seeder that reports failure by RETURN VALUE must not be recorded as a
  # success. Both OnixEdit seeders document "Never raises" and hand back
  # `{:error, reason}` — `Barkpark.Codelists.EDItEUR.seed_thema/1` catches its
  # own exceptions and returns `{:error, {:raised, msg}}`. Before this clause
  # `invoke_seeder/2` discarded the return value and answered `:ok` for
  # anything that did not throw, so a boot where the Thema seed died mid-write
  # still recorded `RunStatus{seed: {:ok, 2}}` — the one instrument that
  # reports seed health showed green while the codelist was absent.
  #
  # Only the explicitly-tagged shapes are classified. An unrecognised return
  # (a third-party plugin seeder that answers with its own term) stays a
  # success, so honouring the contract cannot newly fail a plugin that never
  # opted into it.
  defp classify_seeder_result({:error, reason}), do: {:error, reason}
  defp classify_seeder_result(_other), do: :ok

  @doc """
  Notifies registered plugins after a blob upload lands in `media_files`.

  Plugins opt in by exporting `after_media_upload/1`. Failures are logged
  per-plugin; the upload itself is never rolled back.
  """
  @spec run_after_media_upload(map()) :: :ok
  def run_after_media_upload(ctx) when is_map(ctx) do
    ResolverChain.load_ordered_plugins()
    |> Enum.each(fn %{module: module} ->
      if function_exported?(module, :after_media_upload, 1) do
        ResolverChain.safe_call(module, :after_media_upload, [ctx], :ok)
      end
    end)

    :ok
  end

  @doc """
  Notifies registered plugins after a blob row is deleted from `media_files`.

  Plugins opt in by exporting `after_media_delete/1`.
  """
  @spec run_after_media_delete(map()) :: :ok
  def run_after_media_delete(ctx) when is_map(ctx) do
    ResolverChain.load_ordered_plugins()
    |> Enum.each(fn %{module: module} ->
      if function_exported?(module, :after_media_delete, 1) do
        ResolverChain.safe_call(module, :after_media_delete, [ctx], :ok)
      end
    end)

    :ok
  end

  @doc """
  Returns the `mediaAsset` document id linked to a blob, if any plugin
  exports `asset_doc_id_for_file/2`.
  """
  @spec asset_doc_id_for_media_file(String.t(), String.t()) :: String.t() | nil
  def asset_doc_id_for_media_file(media_file_id, dataset)
      when is_binary(media_file_id) and is_binary(dataset) do
    ResolverChain.load_ordered_plugins()
    |> Enum.find_value(fn %{module: module} ->
      if function_exported?(module, :asset_doc_id_for_file, 2) do
        module.asset_doc_id_for_file(media_file_id, dataset)
      end
    end)
  end
end
