defmodule BarkparkWeb.Studio.StudioLive.Handlers.Media do
  @moduledoc """
  Image field events — picker open/close, media select, clear, upload.
  Behaviour-preserving extraction of the StudioLive handler bodies.
  """
  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView

  alias Barkpark.Media
  alias Barkpark.Media.Storage.Access
  alias BarkparkWeb.ScopeHelpers

  def open_image_picker(%{"field" => field_name}, socket) do
    files =
      Media.list_files(
        socket.assigns.dataset,
        [mime_type: "image/"] ++ ScopeHelpers.scope_opts(socket)
      )
      |> clamp_to_public_unless_authenticated(socket)

    {:noreply, assign(socket, image_picker_field: field_name, media_files: files)}
  end

  # THE UNAUTHENTICATED READ CEILING (task-f71cab067a90a89d).
  #
  # `Media.list_files/2` carries no `Access` predicate of its own (it is a
  # flat query, deliberately — see its own moduledoc), so this door enumerated
  # every image asset in the dataset to ANY visitor, including one admitted
  # only through the Default-workspace public-demo allowance
  # (`public_demo_studio`, off by default in prod — see `BarkparkWeb.
  # LiveScope`). `Access.authenticated?/1` is the SAME principal question a
  # sibling in-flight clamp on the `/v1/media` read doors (media-anon-read-
  # clamp) also gates on — reused here rather than re-derived, so the two
  # never drift into two answers to "is there a principal". It is a plain
  # `.assigns` read, so it works unmodified on this LiveView socket.
  #
  # A no-op for a real Studio member — `authenticated?/1` is true for any
  # membership/token principal, so this filter never runs for them.
  defp clamp_to_public_unless_authenticated(files, socket) do
    if Access.authenticated?(socket) do
      files
    else
      docs =
        Media.asset_docs_for_files(files, socket.assigns.dataset, ScopeHelpers.scope_opts(socket))

      Enum.filter(files, fn file ->
        Access.visibility(Map.get(docs, file.id)) == "public"
      end)
    end
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
