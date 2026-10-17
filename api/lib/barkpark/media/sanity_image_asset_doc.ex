defmodule Barkpark.Media.SanityImageAssetDoc do
  @moduledoc """
  Creates the `sanityImageAsset` document a Sanity-shaped image value points
  at, when a Studio save stores a ref that has none yet
  (task-b3e57f301bd502d8).

  ## Why

  A site moved from Sanity keeps Sanity's image value,
  `{_type: "image", asset: {_ref: "image-<sha1>-<w>x<h>-<ext>"}}`, and reads
  `asset->url` and `asset->metadata` through GROQ. An importer creates one
  `sanityImageAsset` document per Sanity asset under that id (the gyldendal.no
  twin's decision 0008). A Studio upload, or a library pick of a file that came
  from no Sanity import, saves a new `image-<sha1>-<w>x<h>-<ext>` id
  (`Barkpark.Media.ImageMetadata`). No document had that id, so `asset->` was
  null and the site showed no image.

  ## What it writes

  One published `sanityImageAsset` document per missing id, with the keys an
  imported one carries that Barkpark can state from the media file:
  `originalFilename`, `mimeType`, `extension`, `size`, `sha1hash`,
  `metadata.dimensions`, `metadata.lqip` when the `lqip` rendition can be made,
  `url` (Barkpark's Sanity-compatible image route), `mediaFileId` and
  `barkparkUrl`. Keys only Sanity computed (`palette`, `blurHash`,
  `thumbHash`, `hasAlpha`, `isOpaque`) and keys about Sanity itself
  (`sanityUrl`, `source`) are left out rather than invented.

  ## When it writes nothing

  - The id already has a document in the dataset. An existing document is
    never rewritten, so a library pick of an imported image changes nothing.
  - The workspace has no `sanityImageAsset` schema in the dataset. Only a
    workspace that adopted the convention gets these documents.
  - The caller has no workspace and project in scope.
  - No media file in this workspace and dataset maps to the id. The file must
    belong to the caller's workspace (not the shared layer), live in the same
    dataset, and its own Sanity id must equal the ref: its `source_id`, or
    `image-<sha1>-<w>x<h>-<ext>` from its bytes. A ref with a made-up size or
    extension creates nothing.

  Nothing here raises into the save path. The caller decides whether the
  editor may write at all; see `BarkparkWeb.StudioLive.Shared`.
  """

  alias Barkpark.Content
  alias Barkpark.Media.{ImageMetadata, SanityAsset}
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Tenancy

  require Logger

  @type_name "sanityImageAsset"
  @sanity_image_id ~r/\Aimage-[0-9a-f]{40}-[1-9][0-9]*x[1-9][0-9]*-[a-z0-9]+\z/

  @doc "The document type this module writes."
  def type_name, do: @type_name

  @doc """
  Create the missing `sanityImageAsset` documents for `ids`. `opts` carries
  the save's scope (`:workspace_id`, `:project_id`) and its write opts
  (`:source`, `:user_id`). Returns the ids it created. Never raises.
  """
  @spec ensure([String.t()], String.t(), keyword()) :: [String.t()]
  def ensure([], _dataset, _opts), do: []

  def ensure(ids, dataset, opts) when is_list(ids) and is_binary(dataset) do
    do_ensure(ids, dataset, opts)
  rescue
    e ->
      Logger.warning("SanityImageAssetDoc: #{Exception.message(e)}; no asset document written")
      []
  end

  def ensure(_ids, _dataset, _opts), do: []

  defp do_ensure(ids, dataset, opts) do
    scope = Keyword.take(opts, [:workspace_id, :project_id])

    with ws when is_binary(ws) <- scope[:workspace_id],
         proj when is_binary(proj) <- scope[:project_id],
         {:ok, _schema} <- Content.get_schema(@type_name, dataset, scope) do
      existing = Content.resolvable_doc_ids(ids, @type_name, dataset, scope)

      ids
      |> Enum.reject(&MapSet.member?(existing, &1))
      |> Enum.flat_map(&create(&1, dataset, scope, opts))
    else
      _ -> []
    end
  end

  @doc "The distinct Sanity image ids `asset._ref` names across image `values`."
  @spec sanity_refs([term()]) :: [String.t()]
  def sanity_refs(values) do
    values
    |> Enum.flat_map(fn
      %{"asset" => %{"_ref" => ref}} when is_binary(ref) ->
        if Regex.match?(@sanity_image_id, ref), do: [ref], else: []

      _ ->
        []
    end)
    |> Enum.uniq()
  end

  defp create(id, dataset, scope, opts) do
    with {:ok, ref} <- parse_id(id),
         {:ok, %MediaFile{} = file} <- SanityAsset.find(ref, dataset, scope),
         true <- file.workspace_id == scope[:workspace_id],
         true <- file.dataset == dataset,
         true <- ImageMetadata.sanity_image_id(file.id, dataset, scope) == id,
         {:ok, doc} <- build(id, ref, file, dataset, scope),
         {:ok, _} <- write(doc, dataset, scope, opts) do
      [id]
    else
      {:error, reason} when reason != :not_found ->
        Logger.warning("SanityImageAssetDoc #{id}: #{inspect(reason)}; not written")
        []

      _ ->
        []
    end
  end

  # `SanityAsset.parse_image/1` reads the URL form, `<sha1>-<w>x<h>.<ext>`.
  defp parse_id("image-" <> rest) do
    case Regex.run(~r/\A([0-9a-f]{40}-[0-9]+x[0-9]+)-([a-z0-9]+)\z/, rest) do
      [_, stem, ext] -> SanityAsset.parse_image("#{stem}.#{ext}")
      _ -> :error
    end
  end

  defp build(id, %{sha1: sha1, ext: ext, size: {w, h}}, file, dataset, scope) do
    with %{slug: ws_slug} when is_binary(ws_slug) <-
           Tenancy.get_workspace_by_id(scope[:workspace_id]),
         %{slug: proj_slug} when is_binary(proj_slug) <-
           Tenancy.get_project_by_id(scope[:project_id]) do
      prefix = BarkparkWeb.Endpoint.url() <> "/w/#{ws_slug}/p/#{proj_slug}"

      dimensions = %{
        "_type" => "sanity.imageDimensions",
        "width" => w,
        "height" => h,
        "aspectRatio" => w / h
      }

      metadata =
        %{"_type" => "sanity.imageMetadata", "dimensions" => dimensions}
        |> put_present("lqip", lqip(file, dataset, scope))

      doc =
        %{
          "_id" => id,
          "_type" => @type_name,
          "originalFilename" => file.original_name || file.filename,
          "mimeType" => file.mime_type,
          "extension" => ext,
          "size" => file.size,
          "sha1hash" => sha1,
          "metadata" => metadata,
          # The Sanity project segment is ignored by the route; the Barkpark
          # project slug stands in for it.
          "url" => "#{prefix}/images/#{proj_slug}/#{dataset}/#{sha1}-#{w}x#{h}.#{ext}",
          "mediaFileId" => file.id,
          "barkparkUrl" => "#{prefix}/media/files/#{file.path}"
        }
        |> Map.reject(fn {_k, v} -> is_nil(v) end)

      {:ok, doc}
    else
      _ -> {:error, :no_scope_slugs}
    end
  end

  # The upload already stored an lqip on the `mediaAsset` document; a file
  # from before that gets the rendition.
  defp lqip(file, dataset, scope) do
    case Barkpark.Media.asset_doc_for_file(file, dataset, scope) do
      %{content: %{"fileInfo" => %{"lqip" => "data:" <> _ = uri}}} -> uri
      _ -> ImageMetadata.lqip_data_uri(file)
    end
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp write(doc, dataset, scope, opts) do
    write_opts = Keyword.take(opts, [:source, :user_id]) ++ scope
    Content.apply_mutations([%{"createOrReplace" => doc, "publish" => true}], dataset, write_opts)
  end
end
