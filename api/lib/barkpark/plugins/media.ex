defmodule Barkpark.Plugins.Media do
  @moduledoc """
  Native media library plugin — one `mediaAsset` document per uploaded file.

  Binary bytes stay in `media_files` + `/media/files/*`; rich metadata
  (alt text, collections, rights, tags) lives on plugin documents queried
  via the standard `/v1/data/query` API.

  Upload side-effect: `after_media_upload/1` creates a draft `mediaAsset`
  linked by `content.mediaFileId`. Delete side-effect: `after_media_delete/1`
  removes linked asset documents.
  """

  use Barkpark.Plugin,
    manifest_path: "../../../priv/plugins/media/plugin.json"

  # Media lives in the top menu, not the desk tree — visible in Structure
  # only when a workspace override promotes it to `:main`.
  @impl Barkpark.Plugin
  def structure_placement, do: :top_menu

  alias Barkpark.Content.SchemaDefinition
  alias Barkpark.Content.Document
  alias Barkpark.Media.Delivery.Events
  alias Barkpark.Plugins.Media.{Assets, Codelists}

  @plugin_name "media"
  # Resolved at RUNTIME, deliberately not frozen into an attribute.
  # `Application.app_dir/2` finds priv under BOTH deploy models: the source-tree
  # one (Barkpark compiles + runs in place under /opt/barkpark, where Mix
  # symlinks _build/<env>/lib/barkpark/priv at ./priv) and an OTP release, where
  # priv lives at lib/barkpark-<vsn>/priv. The previous
  # `Path.expand("../../../priv/...", __DIR__)` attribute served only the first:
  # it froze the BUILD machine's absolute path, so every released build raised
  # File.Error enoent here and this plugin's schemas never registered.
  # Precedent: the plugin loader already resolves priv this way — see
  # registry/discovery.ex default_paths/0.
  @schemas_subdir "priv/plugins/media/schemas"
  defp schemas_dir, do: Application.app_dir(:barkpark, @schemas_subdir)

  @doc "Plugin discriminator name (D20)."
  @spec plugin_name() :: String.t()
  def plugin_name, do: @plugin_name

  @impl Barkpark.Plugin
  def register_schemas(_opts) do
    [
      load_schema!("media_asset.json"),
      load_schema!("media_collection.json")
    ]
  end

  @impl Barkpark.Plugin
  def codelist_seeders do
    [&Codelists.seed_all/0]
  end

  @doc """
  Oban Cron entries contributed by the media plugin (Path B).

  A single per-minute reconciliation sweep,
  `Barkpark.Plugins.Media.StuckProcessingSweeper`, that re-drives (or terminally fails)
  `mediaAsset` rows stranded at `bp_processing_status == "processing"` by a
  crashed post-upload pipeline. Folded into the host `Oban.Plugins.Cron`
  `:crontab` at boot by `Barkpark.Plugins.Registry.collect_oban_crontab/0`
  (C4-1). Binds the EXISTING `:default` queue — a plugin may contribute crontab
  entries but not new queues — so there is no `config.exs` edit.
  """
  @impl Barkpark.Plugin
  def oban_crontab do
    [{"* * * * *", Barkpark.Plugins.Media.StuckProcessingSweeper}]
  end

  @impl Barkpark.Plugin
  def api_tests do
    Barkpark.Plugins.Media.ApiTests.specs()
  end

  @doc """
  Called by `Barkpark.Plugins.Registry.run_after_media_upload/1` after a
  blob lands in `media_files`. Creates the companion metadata document.
  """
  @spec after_media_upload(map()) :: :ok
  def after_media_upload(%{media_file: media_file}) do
    case Assets.ensure_for_upload(media_file) do
      {:ok, doc} ->
        Events.dispatch(media_file.dataset, "media.uploaded", media_file, doc)
        Barkpark.Media.Processing.process(media_file)
        :ok

      {:error, reason} ->
        log_hook_failure("after_media_upload", reason)
    end
  end

  @doc """
  Called by `Barkpark.Plugins.Registry.run_after_media_delete/1` when a
  blob row is removed.
  """
  @spec after_media_delete(map()) :: :ok
  def after_media_delete(%{media_file_id: id, dataset: dataset}) do
    Assets.delete_for_blob(id, dataset)
    :ok
  end

  @doc """
  Optional Registry hook — resolve the `mediaAsset` doc id for a blob row.
  """
  @spec asset_doc_id_for_file(String.t(), String.t()) :: String.t() | nil
  def asset_doc_id_for_file(media_file_id, dataset) do
    case Assets.find_by_media_file_id(media_file_id, dataset) do
      %Document{doc_id: doc_id} -> doc_id
      _ -> nil
    end
  end

  # Reachability: the only path read is the runtime-resolved `schemas_dir()` joined
  # with one of two literal filenames passed by `register_schemas/1` — no
  # runtime input reaches `File.read!/1`. Same shape (and same waiver) as
  # `Barkpark.Plugins.Bulldocs.register_schemas/1`. This replaces the
  # line-numbered `.sobelow-skips` row for this call site: a fingerprint
  # baseline entry is pinned to a LINE, so any edit above the call (here:
  # adding `oban_crontab/0`) silently kills the waiver and the finding returns
  # as new. The annotation binds by AST adjacency to the def below and survives
  # line moves.
  # sobelow_skip ["Traversal.FileModule"]
  @spec load_schema!(String.t()) :: SchemaDefinition.t()
  defp load_schema!(filename) do
    path = Path.join(schemas_dir(), filename)

    raw =
      path
      |> File.read!()
      |> Jason.decode!()

    case SchemaDefinition.parse(raw, plugin: @plugin_name) do
      {:ok, parsed} ->
        %SchemaDefinition{
          name: parsed.name,
          title: parsed.title,
          icon: Map.get(raw, "icon"),
          visibility: Map.get(raw, "visibility", "private"),
          fields: Map.get(raw, "fields", []),
          groups: Map.get(raw, "groups", []),
          desk_groups: Map.get(raw, "deskGroups", []),
          initial_values: Map.get(raw, "initial_values", %{}),
          cross_validations: Map.get(raw, "cross_validations", []),
          dataset: "production"
        }

      {:error, reason} ->
        raise "Media plugin schema #{filename} failed to parse: #{inspect(reason)}"
    end
  end

  defp log_hook_failure(hook, reason) do
    require Logger

    Logger.warning("Barkpark.Plugins.Media.#{hook} failed: #{inspect(reason)}")

    :ok
  end
end
