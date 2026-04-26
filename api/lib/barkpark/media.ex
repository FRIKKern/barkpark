defmodule Barkpark.Media do
  @moduledoc "Context for media file upload, storage, and retrieval."

  import Ecto.Query
  alias Barkpark.Repo
  alias Barkpark.Media.MediaFile

  @upload_dir "uploads"

  def upload_dir, do: @upload_dir

  @doc "Save an uploaded file to disk and create a DB record."
  def upload(plug_upload, dataset) when is_binary(dataset) do
    %Plug.Upload{filename: original_name, path: temp_path, content_type: content_type} =
      plug_upload

    # Generate date-based path: uploads/2026/04/filename
    now = DateTime.utc_now()
    date_dir = "#{now.year}/#{String.pad_leading("#{now.month}", 2, "0")}"
    filename = unique_filename(original_name)
    relative_path = "#{date_dir}/#{filename}"
    full_dir = Path.join(@upload_dir, date_dir)
    full_path = Path.join(@upload_dir, relative_path)

    # Ensure directory exists
    File.mkdir_p!(full_dir)

    # Copy uploaded file to storage
    File.cp!(temp_path, full_path)

    # Get file size
    %{size: size} = File.stat!(full_path)

    # Detect MIME type
    mime_type = content_type || MIME.from_path(original_name)

    # Create DB record
    %MediaFile{}
    |> MediaFile.changeset(%{
      filename: filename,
      original_name: original_name,
      path: relative_path,
      mime_type: mime_type,
      size: size,
      dataset: dataset
    })
    |> Repo.insert()
  end

  @doc "List all media files for a dataset."
  def list_files(dataset, opts \\ []) when is_binary(dataset) do
    mime_filter = Keyword.get(opts, :mime_type)

    MediaFile
    |> where([m], m.dataset == ^dataset)
    |> maybe_filter_mime(mime_filter)
    |> order_by([m], desc: m.inserted_at)
    |> Repo.all()
  end

  defp maybe_filter_mime(query, nil), do: query

  defp maybe_filter_mime(query, mime_prefix) do
    pattern = "#{mime_prefix}%"
    where(query, [m], like(m.mime_type, ^pattern))
  end

  @doc "Get a single media file by ID."
  def get_file(id) do
    case Repo.get(MediaFile, id) do
      nil -> {:error, :not_found}
      file -> {:ok, file}
    end
  end

  @doc "Delete a media file from disk and DB."
  def delete_file(id) do
    case get_file(id) do
      {:ok, file} ->
        full_path = Path.join(@upload_dir, file.path)
        File.rm(full_path)
        Repo.delete(file)

      error ->
        error
    end
  end

  @doc "Get the full disk path for serving a file."
  def file_path(relative_path) do
    Path.join(@upload_dir, relative_path)
  end

  defp unique_filename(original_name) do
    ext = Path.extname(original_name)
    base = Path.basename(original_name, ext)
    slug = base |> String.downcase() |> String.replace(~r/[^a-z0-9-]/, "-") |> String.trim("-")
    random = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    "#{slug}-#{random}#{ext}"
  end
end
