defmodule BarkparkWeb.Studio.StudioLive.Handlers.Media do
  @moduledoc """
  Image field events — picker open/close, media select, clear, upload.
  Behaviour-preserving extraction of the StudioLive handler bodies.
  """
  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView

  alias Barkpark.Media
  alias BarkparkWeb.ScopeHelpers

  def open_image_picker(%{"field" => field_name}, socket) do
    files =
      Media.list_files(
        socket.assigns.dataset,
        [mime_type: "image/"] ++ ScopeHelpers.scope_opts(socket)
      )

    {:noreply, assign(socket, image_picker_field: field_name, media_files: files)}
  end

  def close_image_picker(socket) do
    {:noreply, assign(socket, image_picker_field: nil, media_files: [])}
  end

  def select_media(%{"url" => url, "field" => field_name}, socket) do
    form = Map.put(socket.assigns.editor_form, field_name, url)
    socket = assign(socket, editor_form: form, image_picker_field: nil, media_files: [])
    send(self(), {:autosave_form, form})
    {:noreply, socket}
  end

  def clear_image(%{"field" => field_name}, socket) do
    form = Map.put(socket.assigns.editor_form, field_name, "")
    socket = assign(socket, editor_form: form)
    send(self(), {:autosave_form, form})
    {:noreply, socket}
  end

  def validate_upload(socket) do
    {:noreply, socket}
  end

  def upload_image(%{"field" => field_name}, socket) do
    uploaded_files =
      consume_uploaded_entries(socket, :image, fn %{path: path}, entry ->
        plug_upload = %Plug.Upload{
          path: path,
          filename: entry.client_name,
          content_type: entry.client_type
        }

        case Media.upload(plug_upload, socket.assigns.dataset, ScopeHelpers.scope_opts(socket)) do
          {:ok, file} -> {:ok, "/media/files/#{file.path}"}
          {:error, _} -> {:error, "upload failed"}
        end
      end)

    case uploaded_files do
      [url | _] ->
        form = Map.put(socket.assigns.editor_form, field_name, url)
        socket = assign(socket, editor_form: form, image_picker_field: nil, media_files: [])
        send(self(), {:autosave_form, form})
        {:noreply, socket}

      _ ->
        {:noreply,
         put_flash(socket, :error, "Image upload failed. Please try again with a supported file.")}
    end
  end
end
