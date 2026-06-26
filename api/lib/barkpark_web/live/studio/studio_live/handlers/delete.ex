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
      # Probe via the arrayOf-aware inbound-edge engine over `content_edges`
      # (the same one the unpublish guard uses) — NOT the scalar-only
      # `find_referencing_docs`, which undercounts `arrayOf`-of-`reference`
      # referencers, so the delete modal previewed FEWER affected documents than
      # the disconnect/delete would actually touch. Map each inbound edge to the
      # modal's {doc_id, type, title, field} shape.
      refs =
        doc.doc_id
        |> Content.Graph.reverse_referencers(
          [dataset: socket.assigns.dataset] ++ ScopeHelpers.scope_opts(socket)
        )
        |> Enum.map(fn r ->
          %{doc_id: r.from_doc_id, type: r.type, title: r.title, field: r.via_field}
        end)

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
