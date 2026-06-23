defmodule BarkparkWeb.Studio.StudioLive.Handlers.Delete do
  @moduledoc """
  Delete-with-reference-check. Behaviour-preserving extraction of the
  StudioLive handler bodies.
  """
  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView

  alias Barkpark.Content
  alias BarkparkWeb.ScopeHelpers
  alias BarkparkWeb.Studio.StudioLive.Shared

  def delete_doc(socket) do
    doc = socket.assigns[:editor_doc]
    type = socket.assigns[:editor_type]

    if doc && type do
      refs =
        Content.find_referencing_docs(
          doc.doc_id,
          socket.assigns.dataset,
          ScopeHelpers.scope_opts(socket)
        )

      {:noreply, assign(socket, show_delete: true, delete_refs: refs)}
    else
      {:noreply, socket}
    end
  end

  def close_delete(socket) do
    {:noreply, assign(socket, show_delete: false, delete_refs: [])}
  end

  def confirm_delete(params, socket) do
    doc = socket.assigns[:editor_doc]
    type = socket.assigns[:editor_type]

    if doc && type do
      if params["disconnect"] == "true" do
        Content.disconnect_references(
          doc.doc_id,
          socket.assigns.dataset,
          ScopeHelpers.scope_opts(socket)
        )
      end

      case Content.delete_document(
             doc.doc_id,
             type,
             socket.assigns.dataset,
             Shared.hook_opts(socket)
           ) do
        {:error, {:halted, reason}} ->
          {:noreply,
           socket
           |> assign(show_delete: false, delete_refs: [])
           |> put_flash(:error, "Delete cancelled: #{reason}")}

        _ ->
          new_path = Enum.take(socket.assigns.nav_path, length(socket.assigns.nav_path) - 1)

          {:noreply,
           socket
           |> assign(show_delete: false, delete_refs: [])
           |> push_patch(to: Shared.studio_path(socket, new_path, socket.assigns.dataset))}
      end
    else
      {:noreply, socket}
    end
  end
end
