defmodule Barkpark.Media.AssetResponse do
  @moduledoc """
  Unified JSON shape for media API responses — blob row + optional
  `mediaAsset` document metadata in one resource.
  """

  alias Barkpark.Content.Envelope
  alias Barkpark.Content.Document
  alias Barkpark.Media.Access
  alias Barkpark.Media.Delivery
  alias Barkpark.Media.MediaFile
  alias Barkpark.Plugins.Registry

  @doc "Render a unified asset map from a blob row and optional linked document."
  @spec render(%MediaFile{}, Document.t() | nil, keyword()) :: map()
  def render(%MediaFile{} = file, asset_doc \\ nil, opts \\ []) do
    dataset = Keyword.get(opts, :dataset, file.dataset)
    conn = Keyword.get(opts, :conn)
    sign_urls? = Keyword.get(opts, :sign_urls, false)

    asset_doc =
      case asset_doc do
        %Document{} = doc ->
          doc

        nil ->
          case Registry.asset_doc_id_for_media_file(file.id, dataset) do
            nil ->
              nil

            doc_id ->
              case Barkpark.Content.get_document(doc_id, "mediaAsset", dataset) do
                {:ok, doc} -> doc
                _ -> nil
              end
          end
      end

    url_opts = [sign_urls: sign_urls?, asset_doc: asset_doc]

    base = %{
      id: file.id,
      dataset: file.dataset,
      filename: file.filename,
      originalName: file.original_name,
      path: file.path,
      url: Delivery.original_url(file, url_opts),
      originalUrl: Delivery.original_url(file, url_opts),
      thumbnailUrl: Delivery.thumbnail_url(file, url_opts),
      previewUrl: Delivery.preview_url(file, url_opts),
      renditions: Delivery.rendition_urls(file, url_opts),
      mimeType: file.mime_type,
      size: file.size,
      createdAt: file.inserted_at,
      updatedAt: file.updated_at,
      visibility: Access.visibility(asset_doc),
      permissions: permissions_for(conn, file, asset_doc),
      assetDocId: asset_doc && asset_doc.doc_id,
      asset: asset_payload(asset_doc)
    }

    # Legacy flat field kept for /media/* backward compatibility.
    if Keyword.get(opts, :legacy, false) do
      base
      |> Map.drop([:dataset, :updatedAt, :asset, :visibility, :permissions])
      |> Map.update!(:createdAt, & &1)
    else
      base
    end
  end

  defp permissions_for(nil, _file, _doc), do: []

  defp permissions_for(conn, file, doc) do
    Access.permissions(conn, file, doc)
  end

  defp asset_payload(nil), do: nil

  defp asset_payload(%Document{} = doc) do
    Envelope.render(doc)
  end
end
