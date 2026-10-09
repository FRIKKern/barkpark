defmodule BarkparkWeb.Studio.StudioLive.Handlers.History do
  @moduledoc """
  History panel + revision restore + profile edit. Behaviour-preserving
  extraction of the StudioLive handler bodies.
  """
  use Gettext, backend: BarkparkWeb.Gettext

  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView

  alias Barkpark.Content
  alias Barkpark.Plugins.Sheets.Session
  alias BarkparkWeb.ScopeHelpers
  alias BarkparkWeb.Studio.SheetGrid.GridData
  alias BarkparkWeb.Studio.StudioLive.Shared
  alias BarkparkWeb.Studio.StudioLive.Shared.Paper

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
      {:noreply, put_flash(socket, :error, gettext("Failed to restore"))}
    end
  end

  def restore_revision(_params, socket),
    do: {:noreply, put_flash(socket, :error, gettext("Failed to restore"))}

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

    case restore_open_doc(socket, rev_id, type) do
      {:ok, _doc} ->
        socket =
          socket
          |> assign(show_history: false, revisions: [])
          |> put_flash(:info, gettext("Restored from history"))
          |> Shared.rebuild_panes()

        # The restore rewrote the draft's blocks and revision behind the open
        # Beta editors (task-494fc7f91abd01bd).
        {:noreply, Paper.push_stored_doc(socket, socket.assigns[:editor_doc], type)}

      {:error, {:halted, reason}} ->
        {:noreply,
         put_flash(socket, :error, gettext("Restore cancelled: %{reason}", reason: reason))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to restore"))}
    end
  end

  # A sheet's cells live in its session, which would overwrite a restored row
  # on its next persist. Session.restore/4 discards it around the write and
  # restarts it from the restored row (task-1eaa2c0dc6e60047).
  defp restore_open_doc(socket, rev_id, "sheet") do
    doc = socket.assigns.editor_doc

    Session.restore(
      Content.published_id(doc.doc_id),
      socket.assigns.dataset,
      GridData.session_scope(%{doc: doc}),
      fn ->
        Content.restore_revision(
          rev_id,
          "sheet",
          socket.assigns.dataset,
          Shared.hook_opts(socket)
        )
      end
    )
  end

  defp restore_open_doc(socket, rev_id, type),
    do: Content.restore_revision(rev_id, type, socket.assigns.dataset, Shared.hook_opts(socket))

  def show_profile(socket) do
    {:noreply, assign(socket, show_profile: true, profile_error: nil)}
  end

  def close_profile(socket) do
    {:noreply, assign(socket, show_profile: false, profile_error: nil)}
  end

  def preview_profile(%{"name" => name, "color" => color}, socket) do
    {:noreply, assign(socket, user_name: name, user_color: color)}
  end

  # A signed-in account saves the name as its display name (task-8d8dabe8b693031d),
  # the same Accounts door PATCH /v1/auth/display-name uses, so it follows the
  # account and names its media checkout locks. The browser keeps a copy either
  # way: it is the name of a session without an account, and the color is
  # per-browser only.
  def save_profile(%{"name" => name, "color" => color}, socket) do
    case save_display_name(socket.assigns[:current_user], name) do
      {:ok, user} ->
        socket =
          socket
          |> assign(user_name: name, user_color: color, show_profile: false, profile_error: nil)
          |> then(fn s -> if user, do: assign(s, current_user: user), else: s end)
          |> push_event("save-identity", %{name: name, color: color})

        {:noreply, Shared.track_presence(socket)}

      {:error, _changeset} ->
        {:noreply,
         assign(socket,
           user_name: name,
           user_color: color,
           profile_error: gettext("Use at most 80 characters.")
         )}
    end
  end

  defp save_display_name(%Barkpark.Accounts.User{} = user, name),
    do: Barkpark.Accounts.update_display_name(user, %{display_name: name})

  defp save_display_name(_no_account, _name), do: {:ok, nil}
end
