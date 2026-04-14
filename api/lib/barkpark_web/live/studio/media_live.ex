defmodule BarkparkWeb.Studio.MediaLive do
  use BarkparkWeb, :live_view

  alias Barkpark.Media

  @impl true
  def mount(%{"dataset" => dataset}, _session, socket) do
    files = Media.list_files(dataset)

    socket =
      socket
      |> assign(nav_section: :media, dataset: dataset, files: files, page_title: "Media Library", selected_file: nil)
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
        Media.upload(%Plug.Upload{path: dest, filename: entry.client_name, content_type: entry.client_type}, socket.assigns.dataset)
      end)

    {:noreply, assign(socket, files: Media.list_files(socket.assigns.dataset))}
  end

  def handle_event("select-file", %{"id" => id}, socket) do
    case Media.get_file(id) do
      {:ok, file} -> {:noreply, assign(socket, selected_file: file)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("close-detail", _, socket) do
    {:noreply, assign(socket, selected_file: nil)}
  end

  def handle_event("delete-file", %{"id" => id}, socket) do
    Media.delete_file(id)
    {:noreply, assign(socket, files: Media.list_files(socket.assigns.dataset), selected_file: nil)}
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
          <div class="media-card" phx-click="select-file" phx-value-id={file.id} style="cursor: pointer;">
            <%= if String.starts_with?(file.mime_type || "", "image/") do %>
              <div class="media-thumb">
                <img src={"/media/files/#{file.path}"} alt={file.original_name} />
              </div>
            <% else %>
              <div class="media-thumb"><%= mime_icon(file.mime_type) %></div>
            <% end %>
            <div class="media-info">
              <div class="media-name"><%= file.original_name %></div>
              <div class="media-size"><%= format_size(file.size) %></div>
            </div>
          </div>
        <% end %>
      </div>
    <% end %>

    <!-- Detail modal -->
    <%= if @selected_file do %>
      <div class="media-detail-overlay" phx-click="close-detail"></div>
      <div class="media-detail-modal">
        <div class="media-detail-header">
          <h2 class="h2"><%= @selected_file.original_name %></h2>
          <button type="button" class="btn btn-ghost btn-sm" phx-click="close-detail">x</button>
        </div>

        <div class="media-detail-body">
          <!-- Preview -->
          <div class="media-detail-preview">
            <%= if String.starts_with?(@selected_file.mime_type || "", "image/") do %>
              <img src={"/media/files/#{@selected_file.path}"} alt={@selected_file.original_name} />
            <% else %>
              <div style="font-size: 64px; text-align: center; padding: 40px; color: var(--fg-dim);"><%= mime_icon(@selected_file.mime_type) %></div>
            <% end %>
          </div>

          <!-- Details -->
          <div class="media-detail-info">
            <div class="media-detail-section">
              <h3 class="media-detail-label">File details</h3>
              <table class="media-detail-table">
                <tr>
                  <td class="media-detail-key">Filename</td>
                  <td><%= @selected_file.original_name %></td>
                </tr>
                <tr>
                  <td class="media-detail-key">Size</td>
                  <td><%= format_size(@selected_file.size) %></td>
                </tr>
                <tr>
                  <td class="media-detail-key">Type</td>
                  <td><%= @selected_file.mime_type %></td>
                </tr>
                <tr>
                  <td class="media-detail-key">Uploaded</td>
                  <td><%= format_date(@selected_file.inserted_at) %></td>
                </tr>
                <tr>
                  <td class="media-detail-key">ID</td>
                  <td style="font-family: var(--font-mono); font-size: 12px;"><%= @selected_file.id %></td>
                </tr>
              </table>
            </div>

            <div class="media-detail-section">
              <h3 class="media-detail-label">URL</h3>
              <div class="media-detail-url">
                <code>/media/files/<%= @selected_file.path %></code>
              </div>
            </div>

            <div class="media-detail-section">
              <h3 class="media-detail-label">Direct link</h3>
              <div class="media-detail-url">
                <a href={"/media/files/#{@selected_file.path}"} target="_blank" style="color: var(--primary); font-size: 13px;">
                  Open in new tab
                </a>
              </div>
            </div>

            <div style="margin-top: auto; padding-top: 16px; border-top: 1px solid var(--border-muted);">
              <button
                class="btn btn-destructive btn-sm"
                phx-click="delete-file"
                phx-value-id={@selected_file.id}
                data-confirm="Permanently delete this file?"
              >Delete file</button>
            </div>
          </div>
        </div>
      </div>
    <% end %>
    </div>

    <style>
      .media-detail-overlay { position: fixed; inset: 0; background: rgba(0,0,0,0.6); z-index: 50; }
      .media-detail-modal {
        position: fixed; top: 50%; left: 50%; transform: translate(-50%, -50%);
        width: 800px; max-width: 90vw; max-height: 85vh;
        background: var(--bg-card); border: 1px solid var(--border);
        border-radius: var(--radius-lg); z-index: 51;
        display: flex; flex-direction: column; overflow: hidden;
      }
      .media-detail-header {
        display: flex; align-items: center; justify-content: space-between;
        padding: 16px 20px; border-bottom: 1px solid var(--border-muted);
        min-height: 52px;
      }
      .media-detail-body {
        display: flex; flex: 1; overflow: hidden;
      }
      .media-detail-preview {
        flex: 1; display: flex; align-items: center; justify-content: center;
        background: var(--bg); padding: 20px; overflow: hidden;
        border-right: 1px solid var(--border-muted);
      }
      .media-detail-preview img {
        max-width: 100%; max-height: 60vh; object-fit: contain; border-radius: 4px;
      }
      .media-detail-info {
        width: 280px; min-width: 280px; padding: 20px;
        display: flex; flex-direction: column; overflow-y: auto;
      }
      .media-detail-section { margin-bottom: 20px; }
      .media-detail-label {
        font-size: 11px; font-weight: 600; text-transform: uppercase;
        letter-spacing: 0.05em; color: var(--fg-dim); margin-bottom: 8px;
      }
      .media-detail-table { width: 100%; font-size: 13px; }
      .media-detail-table td { padding: 4px 0; vertical-align: top; }
      .media-detail-key { color: var(--fg-muted); width: 80px; font-size: 12px; }
      .media-detail-url {
        padding: 8px 10px; background: var(--bg); border: 1px solid var(--border-muted);
        border-radius: var(--radius-sm); font-size: 12px; font-family: var(--font-mono);
        word-break: break-all; color: var(--fg-muted);
      }
    </style>
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

  defp format_date(nil), do: ""
  defp format_date(dt) do
    Calendar.strftime(dt, "%b %d, %Y at %H:%M")
  end
end
