defmodule Barkpark.Plugins.Media.Assets do
  @moduledoc """
  Creates and maintains `mediaAsset` documents for uploaded blobs.

  Each row in `media_files` gets a companion draft document so metadata
  (alt text, collection, rights) lives in Barkpark's native document store.
  """

  import Ecto.Query

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
  """
  @spec delete_for_blob(String.t(), String.t()) :: :ok
  def delete_for_blob(media_file_id, dataset)
      when is_binary(media_file_id) and is_binary(dataset) do
    Document
    |> where([d], d.type == ^@asset_type and d.dataset == ^dataset)
    |> where(
      [d],
      fragment("?->>? = ?", d.content, "mediaFileId", ^media_file_id)
    )
    |> Repo.all()
    |> Enum.each(fn doc ->
      _ = Content.delete_document(doc.doc_id, @asset_type, dataset)
    end)

    :ok
  end

  @spec find_by_media_file_id(String.t(), String.t()) :: Document.t() | nil
  def find_by_media_file_id(media_file_id, dataset)
      when is_binary(media_file_id) and is_binary(dataset) do
    Document
    |> where([d], d.type == ^@asset_type and d.dataset == ^dataset)
    |> where(
      [d],
      fragment("?->>? = ?", d.content, "mediaFileId", ^media_file_id)
    )
    |> order_by([d], desc: d.updated_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc "Batch lookup of asset documents by blob id."
  @spec find_by_media_file_ids([String.t()], String.t()) :: %{String.t() => Document.t()}
  def find_by_media_file_ids([], _dataset), do: %{}

  def find_by_media_file_ids(ids, dataset) when is_list(ids) and is_binary(dataset) do
    Document
    |> where([d], d.type == ^@asset_type and d.dataset == ^dataset)
    |> where([d], fragment("?->>? ", d.content, "mediaFileId") in ^ids)
    |> Repo.all()
    |> Map.new(fn doc -> {Map.get(doc.content, "mediaFileId"), doc} end)
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
