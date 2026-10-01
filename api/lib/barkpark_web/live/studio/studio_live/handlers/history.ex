defmodule BarkparkWeb.Studio.StudioLive.Handlers.History do
  @moduledoc """
  History panel + revision restore + profile edit. Behaviour-preserving
  extraction of the StudioLive handler bodies.
  """
  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView

  alias Barkpark.Content
  alias BarkparkWeb.ScopeHelpers
  alias BarkparkWeb.Studio.StudioLive.Shared

  def show_history(socket) do
    doc = socket.assigns[:editor_doc]
    type = socket.assigns[:editor_type]

    if doc && type do
      revisions =
        Content.list_revisions(
          doc.doc_id,
          type,
          socket.assigns.dataset,
          [limit: 30] ++ ScopeHelpers.scope_opts(socket)
        )

      {:noreply, assign(socket, show_history: true, revisions: revisions)}
    else
      {:noreply, socket}
    end
  end

  def close_history(socket) do
    {:noreply, assign(socket, show_history: false, revisions: [])}
  end

  # The revision must belong to the document OPEN in the editor (r4a LiveView
  # authz sweep). `Content.restore_revision/4` writes `drafts.<rev.doc_id>` —
  # the revision's OWN document — under the open editor's type, while the write
  # checks around this event (`LiveScope.attach_write_gate/2`, the grant
  # target ladder) look only at the open document. Without this check a
  # doc-scoped write grantee could restore ANOTHER document's revision by id,
  # and any member could write a draft under the wrong type.
  def restore_revision(%{"id" => rev_id}, socket) when is_binary(rev_id) do
    if revision_of_open_doc?(rev_id, socket) do
      do_restore_revision(rev_id, socket)
    else
      {:noreply, put_flash(socket, :error, "Failed to restore")}
    end
  end

  def restore_revision(_params, socket),
    do: {:noreply, put_flash(socket, :error, "Failed to restore")}

  defp revision_of_open_doc?(rev_id, socket) do
    with %{doc_id: open_id} when is_binary(open_id) <- socket.assigns[:editor_doc],
         type when is_binary(type) <- socket.assigns[:editor_type],
         {:ok, rev} <-
           Content.get_revision(rev_id, socket.assigns.dataset, ScopeHelpers.scope_opts(socket)) do
      rev.type == type and Content.published_id(rev.doc_id) == Content.published_id(open_id)
    else
      _ -> false
    end
  end

  defp do_restore_revision(rev_id, socket) do
    type = socket.assigns[:editor_type]

    case Content.restore_revision(rev_id, type, socket.assigns.dataset, Shared.hook_opts(socket)) do
      {:ok, _doc} ->
        {:noreply,
         socket
         |> assign(show_history: false, revisions: [])
         |> put_flash(:info, "Restored from history")
         |> Shared.rebuild_panes()}

      {:error, {:halted, reason}} ->
        {:noreply, put_flash(socket, :error, "Restore cancelled: #{reason}")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to restore")}
    end
  end

  def show_profile(socket) do
    {:noreply, assign(socket, show_profile: true)}
  end

  def close_profile(socket) do
    {:noreply, assign(socket, show_profile: false)}
  end

  def preview_profile(%{"name" => name, "color" => color}, socket) do
    {:noreply, assign(socket, user_name: name, user_color: color)}
  end

  def save_profile(%{"name" => name, "color" => color}, socket) do
    socket = assign(socket, user_name: name, user_color: color, show_profile: false)
    socket = push_event(socket, "save-identity", %{name: name, color: color})
    {:noreply, Shared.track_presence(socket)}
  end
end
