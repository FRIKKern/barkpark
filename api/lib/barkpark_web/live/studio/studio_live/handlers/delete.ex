defmodule BarkparkWeb.Studio.StudioLive.Handlers.Delete do
  @moduledoc """
  Delete-with-reference-check. Behaviour-preserving extraction of the
  StudioLive handler bodies.
  """
  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView

  alias Barkpark.Content
  alias Barkpark.Plugins.Sheets.Session
  alias BarkparkWeb.ScopeHelpers
  alias BarkparkWeb.Studio.PaneBuilder
  alias BarkparkWeb.Studio.SheetGrid.GridData
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

  # The success sentence. A delete used to answer with nothing but the jump back
  # to the list (stranger walk, 2026-09-30) — the press-answer region was left to
  # narrate it as "Opened “Disconnect references and delete”." Name what went,
  # and how many references the disconnect removed.
  @doc false
  def deleted_sentence(doc, disconnected?, refs) do
    # The desk row's own name for the document (task-5443f7448d259c66): an
    # untitled draft used to be named by its raw `drafts.<type>-<hex>` id.
    title = PaneBuilder.display_title(doc)

    cond do
      disconnected? and refs == 1 -> "Deleted “#{title}” and removed 1 reference to it."
      disconnected? and refs > 1 -> "Deleted “#{title}” and removed #{refs} references to it."
      true -> "Deleted “#{title}”."
    end
  end

  def confirm_delete(params, socket) do
    doc = socket.assigns[:editor_doc]
    type = socket.assigns[:editor_type]

    disconnect =
      if doc && type && params["disconnect"] == "true",
        do:
          Content.disconnect_references(
            doc.doc_id,
            socket.assigns.dataset,
            Shared.disconnect_opts(socket)
          ),
        else: :ok

    case disconnect do
      {:error, {:outside_write_grant, denied}} ->
        {:noreply,
         socket
         |> assign(show_delete: false, delete_refs: [])
         |> put_flash(:error, Shared.outside_grant_disconnect_message(denied, "deleted"))}

      _ ->
        do_confirm_delete(params, socket, doc, type)
    end
  end

  defp do_confirm_delete(params, socket, doc, type) do
    if doc && type do
      case delete_open_doc(socket, doc, type) do
        {:error, {:halted, reason}} ->
          {:noreply,
           socket
           |> assign(show_delete: false, delete_refs: [])
           |> put_flash(:error, "Delete cancelled: #{reason}")}

        {:ok, _} ->
          new_path = Enum.take(socket.assigns.nav_path, length(socket.assigns.nav_path) - 1)
          refs = length(socket.assigns[:delete_refs] || [])

          {:noreply,
           socket
           |> assign(show_delete: false, delete_refs: [])
           |> put_flash(:info, deleted_sentence(doc, params["disconnect"] == "true", refs))
           |> push_patch(to: Shared.studio_path(socket, new_path, socket.assigns.dataset))}

        # A generic failure (not_found, rev_mismatch, …) must NOT be mistaken
        # for success: the doc still exists, so close the modal but stay put
        # and surface the error instead of silently navigating away.
        {:error, _} ->
          {:noreply,
           socket
           |> assign(show_delete: false, delete_refs: [])
           |> put_flash(:error, "Failed to delete")}
      end
    else
      {:noreply, socket}
    end
  end

  # A sheet's live session would persist its unflushed ops after the delete
  # (debounce or terminate) and upsert the sheet back. Discard it on both
  # sides of the delete: before, so nothing is pending; after, in case a
  # collaborator's edit restarted it in between.
  defp delete_open_doc(socket, doc, "sheet") do
    slug = Content.published_id(doc.doc_id)
    scope = GridData.session_scope(%{doc: doc})

    :ok = Session.discard(slug, socket.assigns.dataset, scope)

    result =
      Content.delete_document(
        doc.doc_id,
        "sheet",
        socket.assigns.dataset,
        Shared.hook_opts(socket)
      )

    :ok = Session.discard(slug, socket.assigns.dataset, scope)
    result
  end

  defp delete_open_doc(socket, doc, type) do
    Content.delete_document(doc.doc_id, type, socket.assigns.dataset, Shared.hook_opts(socket))
  end
end
