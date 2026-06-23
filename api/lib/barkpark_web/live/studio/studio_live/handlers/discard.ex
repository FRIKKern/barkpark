defmodule BarkparkWeb.Studio.StudioLive.Handlers.Discard do
  @moduledoc """
  Discard-draft flow (open/close/confirm). Behaviour-preserving extraction of
  the StudioLive handler bodies.
  """
  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView

  alias Barkpark.Content
  alias BarkparkWeb.Studio.StudioLive.Shared

  def discard_draft(socket) do
    doc = socket.assigns[:editor_doc]
    is_draft = socket.assigns[:editor_is_draft] == true
    has_published = socket.assigns[:editor_has_published] == true

    if doc && is_draft && has_published do
      {:noreply, assign(socket, show_discard: true)}
    else
      {:noreply, socket}
    end
  end

  def close_discard(socket) do
    {:noreply, assign(socket, show_discard: false)}
  end

  def confirm_discard(socket) do
    doc = socket.assigns[:editor_doc]
    type = socket.assigns[:editor_type]
    is_draft = socket.assigns[:editor_is_draft] == true
    has_published = socket.assigns[:editor_has_published] == true

    if doc && type && is_draft && has_published do
      pub_id = Content.published_id(doc.doc_id)

      case Content.discard_draft(pub_id, type, socket.assigns.dataset, Shared.hook_opts(socket)) do
        {:ok, _} ->
          base = Enum.take(socket.assigns.nav_path, length(socket.assigns.nav_path) - 1)
          new_path = base ++ [pub_id]

          {:noreply,
           socket
           |> assign(show_discard: false)
           |> put_flash(:info, "Draft discarded")
           |> push_patch(to: Shared.studio_path(socket, new_path, socket.assigns.dataset))}

        {:error, _} ->
          {:noreply,
           socket
           |> assign(show_discard: false)
           |> put_flash(:error, "Failed to discard draft")}
      end
    else
      {:noreply, assign(socket, show_discard: false)}
    end
  end
end
