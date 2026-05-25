defmodule BarkparkWeb.MediaController do
  use BarkparkWeb, :controller

  alias Barkpark.Content.Errors
  alias Barkpark.Media
  alias Barkpark.Media.{Access, Delivery, Renditions}

  action_fallback BarkparkWeb.FallbackController

  @doc "Upload a file via multipart form data."
  def upload(conn, %{"file" => upload}) do
    dataset = Map.get(conn.params, "dataset", "production")

    case Media.upload(upload, dataset, scope_opts(conn)) do
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
    files = Media.list_files(dataset, [mime_type: mime_filter] ++ scope_opts(conn))

    json(conn, %{
      files: Enum.map(files, &render_file(&1, conn)),
      count: length(files)
    })
  end

  @doc "Get a single media file metadata."
  def show(conn, %{"id" => id}) do
    with {:ok, file} <- Media.get_file(id, scope_opts(conn)) do
      json(conn, render_file(file, conn))
    end
  end

  @doc "Serve a file from disk."
  def serve(conn, %{"path" => path_parts}) do
    relative_path = Enum.join(path_parts, "/")

    with {:ok, file} <- Media.get_file_by_path(relative_path, scope_opts(conn)),
         doc <- Media.asset_doc_for_file(file, file.dataset),
         true <- Access.allowed?(conn, file, doc, :original) do
      full_path = Media.file_path(relative_path)
      mime = MIME.from_path(full_path)

      conn
      |> Delivery.put_file_cache_headers(full_path)
      |> maybe_send_file(full_path, mime)
    else
      {:error, :not_found} ->
        not_found(conn, "file not found")

      false ->
        forbidden(conn)
    end
  end

  @doc "Serve a cached or on-demand rendition preset."
  def serve_rendition(conn, %{"id" => id, "preset" => preset}) do
    with {:ok, file} <- Media.get_file(id),
         doc <- Media.asset_doc_for_file(file, file.dataset),
         true <- Access.allowed?(conn, file, doc, :preview),
         watermark = Access.watermark_profile(doc),
         {:ok, relative} <- Renditions.ensure(file, preset, watermark: watermark) do
      full_path = Media.file_path(relative)
      mime = MIME.from_path(full_path)

      conn
      |> Delivery.put_file_cache_headers(full_path)
      |> maybe_send_file(full_path, mime)
    else
      {:error, :not_found} ->
        not_found(conn, "file not found")

      false ->
        forbidden(conn)

      {:error, :unknown_preset} ->
        not_found(conn, "unknown rendition preset")

      {:error, _} ->
        not_found(conn, "rendition unavailable")
    end
  end

  defp maybe_send_file(%Plug.Conn{state: :sent} = conn, _path, _mime), do: conn

  defp maybe_send_file(conn, full_path, mime) do
    conn
    |> put_resp_content_type(mime)
    |> send_file(200, full_path)
  end

  defp not_found(conn, message) do
    env =
      {:error, :not_found}
      |> Errors.to_envelope(conn)
      |> Map.put(:message, message)

    conn
    |> put_status(:not_found)
    |> json(%{error: Map.delete(env, :status)})
  end

  defp forbidden(conn) do
    env =
      {:error, :forbidden}
      |> Errors.to_envelope(conn)
      |> Map.put(:message, "access denied")

    conn
    |> put_status(:forbidden)
    |> json(%{error: Map.delete(env, :status)})
  end

  @doc "Delete a media file."
  def delete(conn, %{"id" => id}) do
    with {:ok, _} <- Media.delete_file(id, scope_opts(conn)) do
      json(conn, %{deleted: id})
    end
  end

  # Tenancy scope opts pulled from the conn assigns set by ResolveWorkspace /
  # ResolveProject (scoped routes) or AssignDefaultScope (flat back-compat
  # routes). Mirrors BarkparkWeb.QueryController.scope_opts/1. When neither
  # assign is set (a fresh DB before the Default backfill) the opts are empty
  # and the call runs unscoped — Media.Scope helpers no-op on nil.
  defp scope_opts(conn) do
    []
    |> put_scope(:workspace_id, conn.assigns[:current_workspace])
    |> put_scope(:project_id, conn.assigns[:current_project])
  end

  defp put_scope(opts, _key, nil), do: opts
  defp put_scope(opts, key, %{id: id}), do: Keyword.put(opts, key, id)
  defp put_scope(opts, _key, _other), do: opts

  defp render_file(file, conn) do
    dataset = Map.get(conn.params, "dataset", file.dataset)

    base = %{
      id: file.id,
      filename: file.filename,
      originalName: file.original_name,
      path: file.path,
      url: "/media/files/#{file.path}",
      mimeType: file.mime_type,
      size: file.size,
      createdAt: file.inserted_at
    }

    case Barkpark.Plugins.Registry.asset_doc_id_for_media_file(file.id, dataset) do
      nil -> base
      asset_doc_id -> Map.put(base, :assetDocId, asset_doc_id)
    end
  end
end
