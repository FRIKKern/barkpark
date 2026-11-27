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
  alias BarkparkWeb.Studio.StudioLive.Handlers.RichTextRemote
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
  #
  # The button sends the state it was drawn against (task-5b74471e6a2d6de8):
  # `if_rev`, the rev of the document the page showed, or `if_absent: "true"`,
  # the document was gone. They become `Content.restore_revision/4`'s `:if_rev`
  # and `:if_absent`, the history API's fence, so a press that arrives after the
  # document moved on is refused and writes nothing. A press with neither (a
  # page drawn before this change) restores as before.
  def restore_revision(%{"id" => rev_id} = params, socket) when is_binary(rev_id) do
    with true <- revision_of_open_doc?(rev_id, socket),
         {:ok, fence} <- fence(params) do
      do_restore_revision(rev_id, fence, socket)
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Failed to restore"))}
    end
  end

  def restore_revision(_params, socket),
    do: {:noreply, put_flash(socket, :error, gettext("Failed to restore"))}

  @doc """
  The rev a Restore or Revert button names: that of the document the page shows.

  In paper view that is `paper_doc`. The pane rebuild sets it from
  `editor_doc`'s row (`Shared.Paper.setup_paper_view/2`); after that the page's
  own paper ops and the frames it paints re-read `paper_doc` only
  (`Shared.Paper.sync_paper_edit_doc/1`), and `editor_doc` keeps the row from
  the rebuild. Should the two name different rows, `editor_doc`'s rev is named.
  """
  def seen_rev(%{editor_view: :paper, paper_doc: %{} = paper, editor_doc: %{} = doc}),
    do: shown_paper_rev(paper, doc)

  def seen_rev(%{editor_doc: %{} = doc}), do: Map.get(doc, :rev)
  def seen_rev(_assigns), do: nil

  defp shown_paper_rev(%{doc_id: id, rev: rev}, %{doc_id: id}) when is_binary(id), do: rev
  defp shown_paper_rev(_paper, doc), do: Map.get(doc, :rev)

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

  defp fence(params) do
    case {params["if_rev"], params["if_absent"]} do
      {nil, nil} -> {:ok, []}
      {rev, nil} when is_binary(rev) and rev != "" -> {:ok, [if_rev: rev]}
      {nil, "true"} -> {:ok, [if_absent: true]}
      _ -> :error
    end
  end

  defp do_restore_revision(rev_id, fence, socket) do
    type = socket.assigns[:editor_type]

    case restore_open_doc(socket, rev_id, type, fence) do
      {:ok, _doc} ->
        was = socket.assigns[:editor_form]

        # The restore replaced what the form held: nothing typed is left
        # unsaved, so the desk no longer asks before leaving (#28408 review).
        socket =
          socket
          |> assign(
            show_history: false,
            revisions: [],
            editor_dirty: false,
            editor_unsaved_keys: MapSet.new(),
            editor_refused: nil,
            editor_refused_clears: nil
          )
          |> put_flash(:info, gettext("Restored from history"))
          |> Shared.rebuild_panes()
          |> BarkparkWeb.Studio.StudioLive.Handlers.TextConfirmed.redrawn(socket)
          |> RichTextRemote.repaint(was)
          # The header names the restored title (task-42a6f063263338f6).
          |> Shared.assign_page_title()

        # The restore rewrote the draft's blocks and revision behind the open
        # Beta editors (task-494fc7f91abd01bd).
        {:noreply, Paper.push_stored_doc(socket, socket.assigns[:editor_doc], type)}

      {:error, {:halted, reason}} ->
        {:noreply,
         put_flash(socket, :error, gettext("Restore cancelled: %{reason}", reason: reason))}

      # The document moved on since the page was drawn: nothing was written. The
      # form and `editor_doc` are read again from the store, so the page shows
      # the newer words and its buttons name them; a second press is one made
      # against them. The edits a restore would have overwritten go too.
      {:error, {:rev_mismatch, _}} ->
        was = socket.assigns[:editor_form]

        socket =
          socket
          |> assign(
            show_history: false,
            revisions: [],
            editor_dirty: false,
            doc_conflict: false,
            editor_unsaved_keys: MapSet.new(),
            editor_refused_clears: nil
          )
          |> put_flash(
            :error,
            gettext("The document changed since you loaded it — reload and retry.")
          )
          |> Shared.rebuild_panes()
          |> BarkparkWeb.Studio.StudioLive.Handlers.TextConfirmed.redrawn(socket)
          |> RichTextRemote.repaint(was)
          |> Shared.assign_page_title()

        {:noreply, Paper.push_stored_doc(socket, socket.assigns[:editor_doc], type)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to restore"))}
    end
  end

  # A sheet's cells live in its session, which would overwrite a restored row
  # on its next persist. Session.restore/4 discards it around the write and
  # restarts it from the restored row (task-1eaa2c0dc6e60047).
  #
  # The discard drops the session's unflushed cells, so the restore's checks
  # run first, writing nothing (`Content.check_restore/4`): a press refused
  # there leaves the session and its cells alone (task-5b74471e6a2d6de8). The
  # write makes the same checks again, so a write landing in between is still
  # refused; the session then restarts from the stored row.
  defp restore_open_doc(socket, rev_id, "sheet", fence) do
    doc = socket.assigns.editor_doc
    dataset = socket.assigns.dataset
    opts = Shared.hook_opts(socket) ++ fence

    with :ok <- Content.check_restore(rev_id, "sheet", dataset, opts) do
      Session.restore(
        Content.published_id(doc.doc_id),
        dataset,
        GridData.session_scope(%{doc: doc}),
        fn -> Content.restore_revision(rev_id, "sheet", dataset, opts) end
      )
    end
  end

  defp restore_open_doc(socket, rev_id, type, fence),
    do:
      Content.restore_revision(
        rev_id,
        type,
        socket.assigns.dataset,
        Shared.hook_opts(socket) ++ fence
      )

  def show_profile(socket) do
    {:noreply, assign(socket, show_profile: true, profile_error: nil)}
  end

  def close_profile(socket) do
    {:noreply, assign(socket, show_profile: false, profile_error: nil)}
  end

  def preview_profile(%{"name" => name, "color" => color}, socket) do
    {:noreply, assign(socket, user_name: shown_name(name, socket), user_color: color)}
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
          |> assign(
            user_name: shown_name(name, socket),
            user_color: color,
            show_profile: false,
            profile_error: nil
          )
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

  # task-acae5df91728ca9d: the dialog shows the generated name as a
  # placeholder, so an untouched field arrives blank. Blank saves no display
  # name (Accounts stores nil) and the session keeps its generated name.
  defp shown_name(name, socket) do
    if String.trim(name) == "", do: socket.assigns[:user_name_fallback] || name, else: name
  end

  defp save_display_name(%Barkpark.Accounts.User{} = user, name),
    do: Barkpark.Accounts.update_display_name(user, %{display_name: name})

  defp save_display_name(_no_account, _name), do: {:ok, nil}
end
