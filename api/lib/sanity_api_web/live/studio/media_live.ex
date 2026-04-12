defmodule SanityApiWeb.Studio.MediaLive do
  use SanityApiWeb, :live_view

  alias SanityApi.Media

  @impl true
  def mount(_params, _session, socket) do
    files = Media.list_files()

    socket =
      socket
      |> assign(files: files, page_title: "Media Library")
      |> allow_upload(:media, accept: :any, max_entries: 5, max_file_size: 100_000_000)

    {:ok, socket}
  end

  @impl true
  def handle_event("validate", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("upload", _params, socket) do
    _uploaded_files =
      consume_uploaded_entries(socket, :media, fn %{path: path}, entry ->
        # Create a Plug.Upload-compatible struct
        dest = Path.join(System.tmp_dir!(), entry.client_name)
        File.cp!(path, dest)

        upload = %Plug.Upload{
          path: dest,
          filename: entry.client_name,
          content_type: entry.client_type
        }

        case Media.upload(upload) do
          {:ok, file} -> {:ok, file}
          {:error, _} -> {:ok, nil}
        end
      end)

    files = Media.list_files()
    {:noreply, assign(socket, files: files)}
  end

  def handle_event("delete-file", %{"id" => id}, socket) do
    Media.delete_file(id)
    files = Media.list_files()
    {:noreply, assign(socket, files: files)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="page-header">
      <div>
        <h1 class="page-title">Media Library</h1>
        <p class="page-subtitle"><%= length(@files) %> files</p>
      </div>
    </div>

    <div class="card" style="margin-bottom:24px;">
      <form phx-submit="upload" phx-change="validate">
        <div style="display:flex; gap:12px; align-items:center;">
          <.live_file_input upload={@uploads.media} style="flex:1;" />
          <button type="submit" class="btn btn-primary">Upload</button>
        </div>
      </form>

      <%= for entry <- @uploads.media.entries do %>
        <div style="margin-top:8px; font-size:13px; color:var(--text-dim);">
          <%= entry.client_name %> - <%= entry.progress %>%
        </div>
      <% end %>
    </div>

    <div class="media-grid">
      <%= for file <- @files do %>
        <div class="media-card">
          <%= if String.starts_with?(file.mime_type || "", "image/") do %>
            <img src={"/media/files/#{file.path}"} class="media-thumb" />
          <% else %>
            <div class="media-thumb">
              <%= mime_icon(file.mime_type) %>
            </div>
          <% end %>
          <div class="media-info">
            <div style="font-weight:500; overflow:hidden; text-overflow:ellipsis; white-space:nowrap;">
              <%= file.original_name %>
            </div>
            <div style="color:var(--text-dim); display:flex; justify-content:space-between; margin-top:4px;">
              <span><%= format_size(file.size) %></span>
              <button
                phx-click="delete-file"
                phx-value-id={file.id}
                data-confirm="Delete this file?"
                style="color:var(--red); background:none; border:none; cursor:pointer; font-size:12px;"
              >Delete</button>
            </div>
          </div>
        </div>
      <% end %>
      <%= if @files == [] do %>
        <div style="grid-column:1/-1; padding:48px; text-align:center; color:var(--text-dim);">
          No files uploaded yet.
        </div>
      <% end %>
    </div>
    """
  end

  defp mime_icon(nil), do: "📄"
  defp mime_icon(mime) do
    cond do
      String.starts_with?(mime, "image/") -> "🖼"
      String.starts_with?(mime, "video/") -> "🎬"
      String.starts_with?(mime, "audio/") -> "🎵"
      String.contains?(mime, "pdf") -> "📕"
      true -> "📄"
    end
  end

  defp format_size(nil), do: ""
  defp format_size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_size(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_size(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"
end
