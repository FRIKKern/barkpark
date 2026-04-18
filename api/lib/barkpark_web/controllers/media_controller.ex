defmodule BarkparkWeb.MediaController do
  use BarkparkWeb, :controller

  alias Barkpark.Content.Errors
  alias Barkpark.Media

  action_fallback BarkparkWeb.FallbackController

  @doc "Upload a file via multipart form data."
  def upload(conn, %{"file" => upload}) do
    dataset = Map.get(conn.params, "dataset", "production")

    case Media.upload(upload, dataset) do
      {:ok, file} ->
        conn
        |> put_status(:created)
        |> json(render_file(file, conn))

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def upload(conn, _params) do
    env =
      {:error, :malformed}
      |> Errors.to_envelope(conn)
      |> Map.put(:message, "missing 'file' field in multipart upload")

    conn
    |> put_status(:bad_request)
    |> json(%{error: Map.delete(env, :status)})
  end

  @doc "List all media files."
  def index(conn, params) do
    dataset = Map.get(params, "dataset", "production")
    mime_filter = Map.get(params, "type")
    files = Media.list_files(dataset, mime_type: mime_filter)

    json(conn, %{
      files: Enum.map(files, &render_file(&1, conn)),
      count: length(files)
    })
  end

  @doc "Get a single media file metadata."
  def show(conn, %{"id" => id}) do
    with {:ok, file} <- Media.get_file(id) do
      json(conn, render_file(file, conn))
    end
  end

  @doc "Serve a file from disk."
  def serve(conn, %{"path" => path_parts}) do
    relative_path = Enum.join(path_parts, "/")
    full_path = Media.file_path(relative_path)

    if File.exists?(full_path) do
      mime = MIME.from_path(full_path)

      conn
      |> put_resp_content_type(mime)
      |> send_file(200, full_path)
    else
      env =
        {:error, :not_found}
        |> Errors.to_envelope(conn)
        |> Map.put(:message, "file not found")

      conn
      |> put_status(:not_found)
      |> json(%{error: Map.delete(env, :status)})
    end
  end

  @doc "Delete a media file."
  def delete(conn, %{"id" => id}) do
    with {:ok, _} <- Media.delete_file(id) do
      json(conn, %{deleted: id})
    end
  end

  defp render_file(file, _conn) do
    %{
      id: file.id,
      filename: file.filename,
      originalName: file.original_name,
      path: file.path,
      url: "/media/files/#{file.path}",
      mimeType: file.mime_type,
      size: file.size,
      createdAt: file.inserted_at
    }
  end
end
