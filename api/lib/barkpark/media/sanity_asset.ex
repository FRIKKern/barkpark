defmodule Barkpark.Media.SanityAsset do
  @moduledoc """
  Resolve Sanity CDN image and file URLs to Barkpark media files
  (task-0bc9247eca1bd741).

  A site that moves from Sanity keeps `@sanity/image-url` and points its
  `baseUrl` at a Barkpark workspace. The builder then asks for

      <baseUrl>/images/<projectId>/<dataset>/<sha1>-<w>x<h>.<ext>?rect=...&w=...
      <baseUrl>/files/<projectId>/<dataset>/<sha1>.<ext>

  The last segment is the Sanity asset id in URL form. An image id is
  `image-<sha1>-<w>x<h>-<ext>` and a file id is `file-<sha1>-<ext>`, where
  `sha1` is the SHA-1 of the bytes uploaded to Sanity.

  A file is found by two keys, in order:

    1. `media_files.source_id` equal to the Sanity asset id. An importer sets
       it at upload (`sourceId`) or later (`PATCH /v1/media/:dataset/:id`).
    2. `media_files.sha1` equal to the sha1 in the id.

  The second key alone is not enough. On one production import of 155 files
  and 1,136 images, every file kept Sanity's bytes, but only 72 images kept
  Sanity's byte size, because the importer downloaded them from Sanity's CDN,
  which re-encodes. Those images need the first key.

  That import also capped 17 images at 8192 px on their long side.
  `@sanity/image-url` writes `rect` in the pixel space of the size in the
  asset id, so `rescale_rect/3` moves it into the stored image's pixel space.
  """

  alias Barkpark.Media
  alias Barkpark.Media.Storage.MediaFile

  @type ref :: %{
          kind: :image | :file,
          sha1: String.t(),
          ext: String.t(),
          source_id: String.t(),
          size: {pos_integer(), pos_integer()} | nil
        }

  @image_name ~r/\A([0-9a-fA-F]{40})-([1-9][0-9]{0,5})x([1-9][0-9]{0,5})\.([A-Za-z0-9]{1,10})\z/
  @file_name ~r/\A([0-9a-fA-F]{40})\.([A-Za-z0-9]{1,10})\z/

  @doc """
  Parse the last segment of a Sanity image URL, `<sha1>-<w>x<h>.<ext>`.
  """
  @spec parse_image(String.t()) :: {:ok, ref()} | :error
  def parse_image(name) when is_binary(name) do
    case Regex.run(@image_name, name) do
      [_, sha1, w, h, ext] ->
        sha1 = String.downcase(sha1)
        ext = String.downcase(ext)

        {:ok,
         %{
           kind: :image,
           sha1: sha1,
           ext: ext,
           size: {String.to_integer(w), String.to_integer(h)},
           source_id: "image-#{sha1}-#{w}x#{h}-#{ext}"
         }}

      _ ->
        :error
    end
  end

  def parse_image(_name), do: :error

  @doc """
  Parse the last segment of a Sanity file URL, `<sha1>.<ext>`.
  """
  @spec parse_file(String.t()) :: {:ok, ref()} | :error
  def parse_file(name) when is_binary(name) do
    case Regex.run(@file_name, name) do
      [_, sha1, ext] ->
        sha1 = String.downcase(sha1)
        ext = String.downcase(ext)
        {:ok, %{kind: :file, sha1: sha1, ext: ext, size: nil, source_id: "file-#{sha1}-#{ext}"}}

      _ ->
        :error
    end
  end

  def parse_file(_name), do: :error

  @doc """
  The media file a parsed reference names in `dataset`: by `source_id` first,
  then by `sha1`. `opts` carries the request's tenancy scope, as for
  `Media.get_file_by_path/2`.
  """
  @spec find(ref(), String.t(), keyword()) :: {:ok, MediaFile.t()} | {:error, :not_found}
  def find(%{source_id: source_id, sha1: sha1}, dataset, opts) when is_binary(dataset) do
    case Media.get_file_by_source_id(source_id, dataset, opts) do
      {:ok, file} -> {:ok, file}
      {:error, :not_found} -> Media.get_file_by_sha1(sha1, dataset, opts)
    end
  end

  @doc """
  Move a transform plan's `rect` from the pixel space of `declared` (the size
  in the Sanity asset id) into that of `stored` (the Barkpark original). A plan
  without a rect, or with either size unknown or both equal, is returned as is.
  """
  @spec rescale_rect(
          map(),
          {pos_integer(), pos_integer()} | nil,
          {pos_integer(), pos_integer()} | nil
        ) ::
          map()
  def rescale_rect(%{rect: {l, t, w, h}} = plan, {dw, dh}, {sw, sh})
      when {dw, dh} != {sw, sh} and dw > 0 and dh > 0 do
    sx = sw / dw
    sy = sh / dh

    left = min(round(l * sx), sw - 1)
    top = min(round(t * sy), sh - 1)
    width = w |> Kernel.*(sx) |> round() |> max(1) |> min(sw - left)
    height = h |> Kernel.*(sy) |> round() |> max(1) |> min(sh - top)

    %{plan | rect: {left, top, width, height}}
  end

  def rescale_rect(plan, _declared, _stored), do: plan
end
