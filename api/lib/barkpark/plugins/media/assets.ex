defmodule Barkpark.Plugins.Media.Assets do
  @moduledoc """
  Creates and maintains `mediaAsset` documents for uploaded blobs.

  Each row in `media_files` gets a companion draft document so metadata
  (alt text, collection, rights) lives in Barkpark's native document store.
  """

  import Ecto.Query
  import Barkpark.Content.Scope, only: [scope_to_workspace_or_global: 3]

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Media.MediaFile
  alias Barkpark.Repo

  @asset_type "mediaAsset"

  @doc """
  Ensures a `mediaAsset` draft exists for `media_file`. Idempotent.
  """
  @spec ensure_for_upload(%MediaFile{}) :: {:ok, Document.t()} | {:error, term()}
  def ensure_for_upload(%MediaFile{} = file) do
    case find_by_media_file_id(file.id, file.dataset) do
      %Document{} = doc ->
        {:ok, doc}

      nil ->
        create_draft(file)
    end
  end

  @doc """
  Deletes draft/published `mediaAsset` documents linked to a blob id.

  `opts` may carry tenancy scope (`:workspace_id` / `:project_id`); when present
  the lookup is scoped to that tenant so a delete in workspace B never resolves
  workspace A's asset doc for the same `mediaFileId` (barkpark-5p3y). An absent
  workspace_id is the deliberate global / legacy single-tenant path.
  """
  @spec delete_for_blob(String.t(), String.t(), keyword()) :: :ok
  def delete_for_blob(media_file_id, dataset, opts \\ [])
      when is_binary(media_file_id) and is_binary(dataset) and is_list(opts) do
    Document
    |> asset_doc_scope(media_file_id, dataset, opts)
    |> Repo.all()
    |> Enum.each(fn doc ->
      _ = Content.delete_document(doc.doc_id, @asset_type, dataset, opts)
    end)

    :ok
  end

  @doc """
  Linked `mediaAsset` document for a blob id, if any.

  `opts` may carry tenancy scope (`:workspace_id` / `:project_id`); see
  `delete_for_blob/3`.
  """
  @spec find_by_media_file_id(String.t(), String.t(), keyword()) :: Document.t() | nil
  def find_by_media_file_id(media_file_id, dataset, opts \\ [])
      when is_binary(media_file_id) and is_binary(dataset) and is_list(opts) do
    Document
    |> asset_doc_scope(media_file_id, dataset, opts)
    |> order_by([d], desc: d.updated_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Batch lookup of asset documents by blob id.

  `opts` may carry tenancy scope (`:workspace_id` / `:project_id`); see
  `delete_for_blob/3`.
  """
  @spec find_by_media_file_ids([String.t()], String.t(), keyword()) :: %{
          String.t() => Document.t()
        }
  def find_by_media_file_ids(ids, dataset, opts \\ [])

  def find_by_media_file_ids([], _dataset, _opts), do: %{}

  def find_by_media_file_ids(ids, dataset, opts)
      when is_list(ids) and is_binary(dataset) and is_list(opts) do
    Document
    |> where([d], d.type == ^@asset_type)
    |> scope_asset_dataset(dataset, opts)
    |> scope_to_workspace_or_global(Keyword.get(opts, :workspace_id), Keyword.get(opts, :project_id))
    |> where([d], fragment("?->>? ", d.content, "mediaFileId") in ^ids)
    |> Repo.all()
    |> Map.new(fn doc -> {Map.get(doc.content, "mediaFileId"), doc} end)
  end

  # Shared scope for a single-blob asset-doc lookup: type + tenant-resolved
  # dataset (dataset_id authoritative, dataset STRING fallback) + the
  # workspace/project envelope + the mediaFileId match. The workspace envelope
  # is what closes the cross-tenant leak — two workspaces sharing the dataset
  # STRING no longer resolve each other's asset doc for the same mediaFileId.
  defp asset_doc_scope(query, media_file_id, dataset, opts) do
    query
    |> where([d], d.type == ^@asset_type)
    |> scope_asset_dataset(dataset, opts)
    |> scope_to_workspace_or_global(Keyword.get(opts, :workspace_id), Keyword.get(opts, :project_id))
    |> where([d], fragment("?->>? = ?", d.content, "mediaFileId", ^media_file_id))
  end

  # Resolve the dataset STRING → dataset_id within the read's project scope
  # (opts :project_id, else the seeded Default project) and filter by
  # d.dataset_id — NULL-tolerant: also matches legacy asset docs that media.ex
  # wrote WITHOUT scope (dataset_id NULL, dataset STRING stamped), so the
  # default/untenanted read+delete path still resolves them (never-worse).
  # The dataset STRING ↔ dataset_id is 1:1 within a project, so the OR never
  # crosses datasets. Falls back to the legacy d.dataset STRING filter when no
  # dataset row resolves (back-compat / pre-tenancy fixtures). Mirrors
  # Barkpark.Content scope_schema_to_dataset/3.
  defp scope_asset_dataset(query, dataset, opts) do
    case resolve_dataset_id(dataset, opts) do
      id when is_binary(id) ->
        where(query, [d], d.dataset_id == ^id or (is_nil(d.dataset_id) and d.dataset == ^dataset))

      _ ->
        where(query, [d], d.dataset == ^dataset)
    end
  end

  # Read-only dataset-string → dataset_id resolution. Never creates a dataset on
  # a read/delete path. Returns nil when unresolvable so the caller keeps the
  # legacy STRING filter.
  defp resolve_dataset_id(dataset, opts) when is_binary(dataset) do
    project_id = Keyword.get(opts, :project_id) || default_project_id()

    case project_id && Barkpark.Tenancy.get_dataset(project_id, dataset) do
      %Barkpark.Tenancy.Dataset{id: id} -> id
      _ -> nil
    end
  end

  defp default_project_id do
    case Barkpark.Tenancy.get_default_project() do
      %{id: id} -> id
      _ -> nil
    end
  end

  @spec public_url(%MediaFile{}) :: String.t()
  def public_url(%MediaFile{path: path}), do: "/media/files/#{path}"

  @doc """
  Backfill `mediaAsset` documents for existing blobs without companion docs.

  Returns `{:ok, stats}` with `%{created, skipped, errors}`.
  """
  @spec backfill(String.t(), keyword()) :: {:ok, map()}
  def backfill(dataset, opts \\ []) when is_binary(dataset) do
    dry_run? = Keyword.get(opts, :dry_run, false)

    {created, skipped, errors} =
      dataset
      |> Barkpark.Media.list_files()
      |> Enum.reduce({0, 0, []}, fn file, {c, s, errs} ->
        case find_by_media_file_id(file.id, dataset) do
          %Document{} ->
            {c, s + 1, errs}

          nil ->
            if dry_run? do
              {c + 1, s, errs}
            else
              case ensure_for_upload(file) do
                {:ok, _} -> {c + 1, s, errs}
                {:error, reason} -> {c, s, [{file.id, reason} | errs]}
              end
            end
        end
      end)

    {:ok, %{created: created, skipped: skipped, errors: Enum.reverse(errors)}}
  end

  defp create_draft(%MediaFile{} = file) do
    doc_id = "asset-#{file.id}"

    attrs = %{
      "doc_id" => doc_id,
      "title" => file.original_name || file.filename,
      "status" => "draft",
      "content" => %{
        "mediaFileId" => file.id,
        "bp_asset_kind" => asset_kind(file.mime_type),
        "bp_processing_status" => initial_processing_status(file),
        "fileInfo" => %{
          "url" => public_url(file),
          "path" => file.path,
          "mimeType" => file.mime_type,
          "size" => Integer.to_string(file.size),
          "originalName" => file.original_name,
          "width" => "",
          "height" => ""
        },
        "tags" => []
      }
    }

    Content.create_document(@asset_type, attrs, file.dataset, source: :worker)
  end

  defp asset_kind(nil), do: "other"

  defp asset_kind(mime) when is_binary(mime) do
    cond do
      String.starts_with?(mime, "image/") -> "image"
      String.starts_with?(mime, "video/") -> "video"
      String.starts_with?(mime, "audio/") -> "audio"
      String.starts_with?(mime, "application/") -> "document"
      true -> "other"
    end
  end

  defp initial_processing_status(%MediaFile{mime_type: mime}) when is_binary(mime) do
    if String.starts_with?(mime, "image/"), do: "processing", else: "ready"
  end

  defp initial_processing_status(_), do: "ready"
end
