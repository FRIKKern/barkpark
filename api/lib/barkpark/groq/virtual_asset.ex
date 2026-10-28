defmodule Barkpark.Groq.VirtualAsset do
  @moduledoc """
  Sanity's asset documents, `sanity.imageAsset` and `sanity.fileAsset`, read
  from a Barkpark media file (task-63d414ef90e9f409).

  The studio stores a picked image as `{asset: {_ref: "asset-<file id>"}}`
  and the asset's `mediaAsset` document is only a draft, so in the published
  perspective `image.asset->url` was null, and in drafts the `mediaAsset` had
  no `url`. A `->` that lands on an asset reference now answers the keys
  Sanity's asset document has, built from the media file and its `mediaAsset`
  document. Nothing is stored.

  An asset reference is `asset-<file id>`, or a Sanity id,
  `image-<sha1>-<w>x<h>-<ext>` or `file-<sha1>-<ext>`, which names the file
  whose own Sanity id it is: its `source_id`, else the id its bytes give
  (`Barkpark.Media.ImageMetadata.sanity_image_id/3`). A Sanity id with another
  size or extension names nothing.

  Keys Barkpark does not hold are left out rather than invented: `uploadId`,
  and in `metadata` whatever processing did not read (`palette`, `blurHash`).
  `url` and `path` use the Sanity image and file routes of the workspace and
  project, so `url` is absent on a read with no workspace and project in scope.
  """

  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @image_id ~r/\Aimage-([0-9a-f]{40})-([1-9][0-9]*)x([1-9][0-9]*)-([a-z0-9]+)\z/
  @file_id ~r/\Afile-([0-9a-f]{40})-([a-z0-9]+)\z/

  @doc """
  What an id names: `{:file_id, uuid}` for `asset-<uuid>`, `{:sanity_id,
  sha1}` for a Sanity image or file id, else nil.
  """
  @spec ref(term()) :: {:file_id, String.t()} | {:sanity_id, String.t()} | nil
  def ref("asset-" <> uuid) do
    if Regex.match?(@uuid, uuid), do: {:file_id, uuid}
  end

  def ref("image-" <> _ = id) do
    case Regex.run(@image_id, id) do
      [_, sha1 | _] -> {:sanity_id, sha1}
      _ -> nil
    end
  end

  def ref("file-" <> _ = id) do
    case Regex.run(@file_id, id) do
      [_, sha1, _] -> {:sanity_id, sha1}
      _ -> nil
    end
  end

  def ref(_id), do: nil

  @doc """
  The Sanity asset document for `file`, whose `mediaAsset` document renders
  as `asset`. `base` is `{url_prefix, project_segment}` for the workspace and
  project, or nil.
  """
  @spec build(map(), map(), String.t(), {String.t(), String.t()} | nil) :: map()
  def build(file, asset, dataset, base) do
    image? = image?(file)
    info = if is_map(asset["fileInfo"]), do: asset["fileInfo"], else: %{}
    metadata = if image?, do: metadata(asset, info)
    id = sanity_id(file, metadata)

    %{
      "_id" => id || "asset-" <> file.id,
      "_type" => if(image?, do: "sanity.imageAsset", else: "sanity.fileAsset"),
      "_rev" => asset["_rev"],
      "_createdAt" => asset["_createdAt"],
      "_updatedAt" => asset["_updatedAt"],
      "mimeType" => file.mime_type,
      "originalFilename" => file.original_name || file.filename,
      "size" => file.size,
      "metadata" => metadata
    }
    |> Map.merge(id_keys(id))
    |> Map.merge(location(id, file, dataset, base))
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp image?(%{mime_type: "image/" <> _}), do: true
  defp image?(_file), do: false

  # Processing stores Sanity's metadata on the asset document; an asset from
  # before that has only `fileInfo`.
  defp metadata(asset, info) do
    stored = if is_map(asset["metadata"]), do: asset["metadata"], else: %{}

    dimensions =
      case {int(info["width"]), int(info["height"])} do
        {w, h} when is_integer(w) and is_integer(h) ->
          %{
            "_type" => "sanity.imageDimensions",
            "width" => w,
            "height" => h,
            "aspectRatio" => w / h
          }

        _ ->
          nil
      end

    %{"_type" => "sanity.imageMetadata"}
    |> Map.merge(Map.reject(stored, fn {_k, v} -> is_nil(v) end))
    |> put_new("dimensions", dimensions)
    |> put_new("lqip", info["lqip"])
  end

  defp put_new(map, _key, nil), do: map
  defp put_new(map, key, value), do: Map.put_new(map, key, value)

  defp sanity_id(file, metadata) do
    stored = file.source_id

    cond do
      is_binary(stored) and Regex.match?(if(metadata, do: @image_id, else: @file_id), stored) ->
        stored

      not (is_binary(file.sha1) and Regex.match?(~r/\A[0-9a-f]{40}\z/, file.sha1)) ->
        nil

      metadata ->
        with %{"width" => w, "height" => h} when is_integer(w) and is_integer(h) <-
               metadata["dimensions"],
             ext when is_binary(ext) <- image_ext(file.mime_type) do
          "image-#{file.sha1}-#{w}x#{h}-#{ext}"
        else
          _ -> nil
        end

      true ->
        case file_ext(file.original_name || file.filename) do
          ext when is_binary(ext) -> "file-#{file.sha1}-#{ext}"
          _ -> nil
        end
    end
  end

  defp id_keys(nil), do: %{}

  defp id_keys(id) do
    {sha1, ext} = id_parts(id)
    %{"assetId" => sha1, "sha1hash" => sha1, "extension" => ext}
  end

  defp id_parts(id) do
    case Regex.run(@image_id, id) do
      [_, sha1, _w, _h, ext] ->
        {sha1, ext}

      _ ->
        [_, sha1, ext] = Regex.run(@file_id, id)
        {sha1, ext}
    end
  end

  # The routes `Barkpark.Media.SanityAsset` resolves; the project segment is
  # ignored there, and the Barkpark project slug stands in for Sanity's id.
  defp location(_id, _file, _dataset, nil), do: %{}

  defp location(nil, file, _dataset, {prefix, _project}),
    do: %{"url" => "#{prefix}/media/files/#{file.path}"}

  defp location(id, _file, dataset, {prefix, project}) do
    path =
      case Regex.run(@image_id, id) do
        [_, sha1, w, h, ext] ->
          "images/#{project}/#{dataset}/#{sha1}-#{w}x#{h}.#{ext}"

        _ ->
          {sha1, ext} = id_parts(id)
          "files/#{project}/#{dataset}/#{sha1}.#{ext}"
      end

    %{"path" => path, "url" => "#{prefix}/#{path}"}
  end

  # Sanity's extension for an image: its mime subtype, "jpg" for JPEG.
  defp image_ext("image/jpeg"), do: "jpg"
  defp image_ext("image/svg+xml"), do: "svg"

  defp image_ext("image/" <> sub),
    do: if(Regex.match?(~r/\A[a-z0-9]+\z/, sub), do: sub)

  defp image_ext(_mime), do: nil

  defp file_ext(name) when is_binary(name) do
    ext = name |> Path.extname() |> String.trim_leading(".") |> String.downcase()
    if Regex.match?(~r/\A[a-z0-9]{1,10}\z/, ext), do: ext
  end

  defp file_ext(_name), do: nil

  defp int(v) when is_integer(v) and v > 0, do: v

  defp int(v) when is_binary(v) do
    case Integer.parse(String.trim(v)) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  defp int(_v), do: nil
end
