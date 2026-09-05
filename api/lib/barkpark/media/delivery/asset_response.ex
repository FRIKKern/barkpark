defmodule Barkpark.Media.Delivery.AssetResponse do
  @moduledoc """
  Unified JSON shape for media API responses — blob row + optional
  `mediaAsset` document metadata in one resource.
  """

  alias Barkpark.Content
  alias Barkpark.Content.CallerContext
  alias Barkpark.Content.Envelope
  alias Barkpark.Content.Document
  alias Barkpark.Media.Storage.Access
  alias Barkpark.Media.Delivery.Cdn
  alias Barkpark.Media.Delivery.Urls
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Plugins.Media.Assets, as: PluginAssets
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
              # Thread scope from the %MediaFile{} row — post-keystone, doc_id
              # collisions across workspaces are legal, so the unscoped read
              # could raise (multi-row) or return the wrong tenant. The file
              # already carries workspace_id/project_id; reuse the canonical
              # helper so this stays in lockstep with collections.ex /
              # checkout.ex / processing.ex.
              case Barkpark.Content.get_document(
                     doc_id,
                     "mediaAsset",
                     dataset,
                     PluginAssets.file_scope_opts(file)
                   ) do
                {:ok, doc} -> doc
                _ -> nil
              end
          end
      end

    # Request-scope URL emission (P4): a conn resolved under /w/:ws/p/:proj
    # prefixes every delivery URL with that scope; flat conns emit "".
    scope_prefix = conn_scope_prefix(conn)

    url_opts = [
      sign_urls: sign_urls?,
      asset_doc: asset_doc,
      scope_prefix: scope_prefix
    ]

    # `cdnUrls` gets the SCOPE PREFIX and nothing else (task-57ee9fff4aae9217
    # #11): it used to call `Cdn.url_map/1`, which emits the flat
    # `/media/files/...` path unconditionally, so `cdnUrls.original` in an
    # upload receipt 404d for every caller outside the default workspace.
    # Signing is deliberately NOT threaded here — `url` / `originalUrl` /
    # `renditions` are the signed surface; cdnUrls is the edge-cacheable one.
    cdn_opts = [scope_prefix: scope_prefix]

    # ONE original-URL build, reused by `url`, `originalUrl` and the absolute
    # field below, so the three can never disagree byte-for-byte.
    original = Urls.original_url(file, url_opts)

    base = %{
      id: file.id,
      # THE BLOB ID, NAMED (task-57ee9fff4aae9217 #11). `id` is the media_files
      # row id and always was — but a receipt that also carries `assetDocId`
      # gives a client no way to tell WHICH id `id` is, and the field the
      # /v1/media write routes take in their `:id` path segment is this one.
      # Gyldendal's importer was REGEXING it back out of a rendition URL
      # (`/media/renditions/<mediaFileId>/thumb`). It is stated now.
      mediaFileId: file.id,
      dataset: file.dataset,
      filename: file.filename,
      originalName: file.original_name,
      path: file.path,
      url: original,
      originalUrl: original,
      # THE ONE FIELD A CLIENT CAN FETCH AS-IS (jf-backlog-media-absolute-url).
      # Every sibling URL here is a relative delivery PATH — documented, read by
      # persisted webhook payloads and the JS SDK, and therefore frozen — so
      # nothing in a receipt said WHICH ORIGIN serves them. `absoluteUrl` is
      # ADDITIVE: `Urls.absolutize/1` prefixes the configured CDN base when one
      # is set (it already is, via Cdn.public_url/1) and otherwise the app's own
      # public origin, over a URL that already carries this request's scope
      # prefix. Nothing above changed value.
      absoluteUrl: Urls.absolutize(original),
      thumbnailUrl: Urls.thumbnail_url(file, url_opts),
      previewUrl: Urls.preview_url(file, url_opts),
      renditions: Urls.rendition_urls(file, url_opts),
      cdnUrls: Cdn.url_map(file, cdn_opts),
      mimeType: file.mime_type,
      size: file.size,
      createdAt: file.inserted_at,
      updatedAt: file.updated_at,
      visibility: Access.visibility(asset_doc),
      permissions: permissions_for(conn, file, asset_doc),
      assetDocId: asset_doc && asset_doc.doc_id,
      asset: asset_payload(asset_doc, dataset, conn)
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

  defp asset_payload(nil, _dataset, _conn), do: nil

  # WS-B HIGH-2: the embedded `mediaAsset` document formerly rendered with a nil
  # caller (full content). Thread the request's CallerContext + the mediaAsset
  # schema through the Envelope redaction boundary so a `private` / `owner_only`
  # / `readable_by` / encrypted field is dropped for a non-authorized caller.
  # A conn-less internal call (relations.ex, processing without a conn) resolves
  # to the anonymous baseline, which — with the fail-closed nil/anonymous default
  # — redacts rather than leaks.
  defp asset_payload(%Document{} = doc, dataset, conn) do
    Envelope.render(doc, asset_schema(doc, dataset), caller_context(conn))
  end

  defp caller_context(%Plug.Conn{} = conn), do: CallerContext.from_conn(conn)
  defp caller_context(_), do: CallerContext.anonymous()

  # Resolve the mediaAsset type schema scoped to the asset doc's own tenant, so
  # the per-field visibility metadata is available to the redaction boundary.
  defp asset_schema(%Document{} = doc, dataset) do
    opts = [workspace_id: Map.get(doc, :workspace_id), project_id: Map.get(doc, :project_id)]

    case Content.Schema.get_schema_for_redaction("mediaAsset", dataset, opts) do
      {:ok, schema} -> schema
      _ -> nil
    end
  end

  # URL-scoped requests carry the slugs in path_params (set only on
  # /w/:ws/p/:proj routes) — assigns can't be the signal here because
  # AssignDefaultScope ALSO sets current_workspace on flat routes, and flat
  # responses must stay byte-identical (persisted-URL consumers).
  defp conn_scope_prefix(%Plug.Conn{
         path_params: %{"workspace_slug" => ws, "project_slug" => proj}
       })
       when is_binary(ws) and is_binary(proj),
       do: "/w/#{ws}/p/#{proj}"

  defp conn_scope_prefix(_), do: ""
end
