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
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("upload", _params, socket) do
    _uploaded =
      consume_uploaded_entries(socket, :media, fn %{path: path}, entry ->
        dest = Path.join(System.tmp_dir!(), entry.client_name)
        File.cp!(path, dest)
        Media.upload(%Plug.Upload{path: dest, filename: entry.client_name, content_type: entry.client_type})
      end)

    {:noreply, assign(socket, files: Media.list_files())}
  end

  def handle_event("delete-file", %{"id" => id}, socket) do
    Media.delete_file(id)
    {:noreply, assign(socket, files: Media.list_files())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div style="padding: 24px; overflow-y: auto; flex: 1;">
    <div style="margin-bottom: 20px;">
      <h1 class="h1">Media Library</h1>
      <span class="text-sm text-muted"><%= length(@files) %> files</span>
    </div>

    <div class="card" style="margin-bottom: 20px;">
      <form phx-submit="upload" phx-change="validate" style="padding: 20px;">
        <div class="upload-zone">
          <.live_file_input upload={@uploads.media} />
          <p class="text-sm text-muted" style="margin-top: 8px;">Select files to upload (max 100MB each)</p>
          <%= if @uploads.media.entries != [] do %>
            <div style="margin-top: 12px;">
              <%= for entry <- @uploads.media.entries do %>
                <div class="text-sm" style="color: var(--fg-muted); margin-top: 4px;">
                  <%= entry.client_name %> &middot; <%= entry.progress %>%
                </div>
              <% end %>
              <button type="submit" class="btn btn-primary btn-sm" style="margin-top: 12px;">Upload</button>
            </div>
          <% end %>
        </div>
      </form>
    </div>

    <%= if @files == [] do %>
      <div class="empty-state">
        <div class="empty-state-icon">&#128193;</div>
        <div class="empty-state-text">No files uploaded yet</div>
      </div>
    <% else %>
      <div class="media-grid">
        <%= for file <- @files do %>
          <div class="media-card">
            <%= if String.starts_with?(file.mime_type || "", "image/") do %>
              <div class="media-thumb">
                <img src={"/media/files/#{file.path}"} alt={file.original_name} />
              </div>
            <% else %>
              <div class="media-thumb"><%= mime_icon(file.mime_type) %></div>
            <% end %>
            <div class="media-info">
              <div class="media-name"><%= file.original_name %></div>
              <div style="display: flex; justify-content: space-between; align-items: center; margin-top: 4px;">
                <span class="media-size"><%= format_size(file.size) %></span>
                <button
                  phx-click="delete-file" phx-value-id={file.id}
                  data-confirm="Delete this file?"
                  class="btn btn-ghost btn-sm"
                  style="height: 20px; padding: 0 4px; color: var(--destructive); font-size: 11px;"
                >Delete</button>
              </div>
            </div>
          </div>
        <% end %>
      </div>
    <% end %>
    </div>
    """
  end

  defp mime_icon(nil), do: "&#128196;"
  defp mime_icon(mime) do
    cond do
      String.starts_with?(mime, "image/") -> "&#128248;"
      String.starts_with?(mime, "video/") -> "&#127916;"
      String.starts_with?(mime, "audio/") -> "&#127925;"
      String.contains?(mime, "pdf") -> "&#128213;"
      true -> "&#128196;"
    end
  end

  defp format_size(nil), do: ""
  defp format_size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_size(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_size(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"
end
