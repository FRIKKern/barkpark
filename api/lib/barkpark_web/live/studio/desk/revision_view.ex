defmodule BarkparkWeb.Studio.Desk.RevisionView do
  @moduledoc """
  An old revision of the document in the desk's edit pane, shown read-only
  in the form's place, as the TanStack Studio shows one (`DocumentPane.tsx`,
  `RevisionFooter`): the pane's URL names it (`rev=<id>`, which the History
  inspector's rows put there, `HistoryPanel`), so the deep URL survives a
  reload.

  - The form is the Studio's own, drawn from the revision's title and
    content in a disabled fieldset: nothing in it can be typed in or
    pressed. The editor keeps the document as it is now. Every write the
    form or its fields could send is dropped while a revision is shown
    (`EditorHost`), so no autosave writes the revision.
  - The footer says when the revision is from and offers "Revert to
    revision". It asks first ("Are you sure you want to restore this
    document?"); Confirm sends the Studio's own `restore-revision`, which
    writes the revision back as the draft through `PostIdentity.pressed/3`
    and the Studio's own check that the revision is the open document's
    (`Handlers.History`). Once it is written the URL drops `rev`.
  - A revision that is not the open document's, or that cannot be read,
    is not shown: the pane says so, as TanStack's does.

  The deleted document's "Restore most recent revision" (J32) is here too:
  `latest/1` reads the newest revision that is the document itself, and
  its button sends the same `restore-revision`.

  `EditorHost` owns the `desk_revision` assign: `nil` when the URL names no
  revision, `%{id: id, missing: true}` for one that is not shown, else
  `%{id: id, at: at, doc: doc, form: form}`; and `desk_gone_latest`, the id
  the deleted document's restore writes back, or `nil`.
  """
  use Phoenix.Component
  use Gettext, backend: BarkparkWeb.Gettext

  alias Barkpark.Content
  alias BarkparkWeb.ScopeHelpers
  alias BarkparkWeb.Studio.Desk.HistoryPanel
  alias BarkparkWeb.Studio.Desk.LiveRefresh
  alias BarkparkWeb.Studio.StudioLive.PostIdentity

  @doc """
  Reads the revision the last pane names, when it is the edited document;
  `nil` otherwise. The one already read is kept.
  """
  def load(%{assigns: %{editing: {dataset, type, id}, chain: [_ | _] = chain}} = socket) do
    rev = List.last(chain)[:rev]

    case socket.assigns[:desk_revision] do
      %{id: ^rev} when is_binary(rev) ->
        socket

      _ when is_binary(rev) ->
        assign(socket, :desk_revision, read(socket, rev, dataset, type, id))

      _ ->
        assign(socket, :desk_revision, nil)
    end
  end

  def load(socket), do: assign(socket, :desk_revision, nil)

  defp read(socket, rev_id, dataset, type, id) do
    with {:ok, rev} <- Content.get_revision(rev_id, dataset, ScopeHelpers.scope_opts(socket)),
         true <- rev.type == type and Content.published_id(rev.doc_id) == Content.published_id(id),
         %{} = doc <- socket.assigns[:editor_doc] do
      shown = %{doc | title: rev.title, content: rev.content || %{}}
      schema = socket.assigns[:editor_schema]
      %{id: rev_id, at: rev.inserted_at, doc: shown, form: Content.doc_to_form(shown, schema)}
    else
      _ -> %{id: rev_id, missing: true}
    end
  end

  @doc "Whether the pane shows an old revision in the form's place."
  def shown?(assigns), do: match?(%{form: _}, assigns[:desk_revision])

  @doc "Whether the URL names a revision that is not shown."
  def missing?(assigns), do: match?(%{missing: true}, assigns[:desk_revision])

  @doc """
  The page's assigns for drawing the Studio's form over the revision: its
  values, no findings, the classic form with every field and no dialog.
  """
  def shell_assigns(%{desk_revision: %{doc: doc, form: form}} = assigns) do
    assigns
    |> assign(
      editor_doc: doc,
      editor_form: form,
      editor_mode: :classic,
      validation_errors: %{},
      validation_warnings: %{},
      cross_violations: [],
      show_delete: false,
      show_unpublish_guard: false
    )
    |> HistoryPanel.waiting()
  end

  @doc """
  After an event the Studio answered: a revert that wrote the revision back
  (the editor now holds a newer document) takes `rev` out of the URL.
  """
  def restored(socket, "restore-revision", before) do
    with %{desk_revision: %{id: _}, chain: chain, base: base} <- socket.assigns,
         true <- newer?(before, socket.assigns[:editor_doc]) do
      index = length(chain) - 1
      perspective = BarkparkWeb.Studio.Desk.Panes.perspective(socket.assigns[:desk_uri])

      Phoenix.LiveView.push_patch(socket,
        to: HistoryPanel.path(chain, index, base, perspective, %{rev: nil})
      )
    else
      _ -> socket
    end
  end

  def restored(socket, _event, _before), do: socket

  defp newer?(%{updated_at: a}, %{updated_at: b}), do: a != b
  defp newer?(_before, %{}), do: true
  defp newer?(_before, _after), do: false

  @doc """
  A `handle_info` hook step: on the desk's refresh tick (which follows every
  change it is told of), the newest revision of a deleted open document is
  read, for its restore; `nil` while it is not deleted.
  """
  def on_info(:desk_refresh, socket), do: assign(socket, :desk_gone_latest, latest(socket))
  def on_info(_message, socket), do: socket

  @doc "The newest revision of the deleted open document that is the document itself."
  def latest(%{assigns: %{editing: {dataset, type, id}} = assigns} = socket) do
    if LiveRefresh.gone?(assigns, type, id) do
      id
      |> Content.list_revisions(type, dataset, [limit: 10] ++ ScopeHelpers.scope_opts(socket))
      |> Enum.find_value(&(&1.action != "delete" && &1.id))
    end
  end

  def latest(_socket), do: nil

  attr :id, :string, required: true
  attr :revision, :map, required: true

  @doc "The footer while a revision is shown: when it is from, and its revert."
  def footer(assigns) do
    ~H"""
    <footer id={@id} class="dk-edit-footer doc-footer revision-footer" data-desk-revision-footer>
      <span class="save-state" role="status">
        <BarkparkWeb.Icons.desk_icon name="restore" size={21} />
        {gettext("Revision from")} <strong>{stamp(@revision.at)}</strong>
      </span>
      <div class="dk-revert">
        <button
          type="button"
          id={"#{@id}-revert"}
          class="dk-publish publish caution"
          popovertarget={"#{@id}-confirm"}
          style="anchor-name: --dk-revert"
        >
          <BarkparkWeb.Icons.desk_icon name="undo" size={21} />
          {gettext("Revert to revision")}
        </button>
        <div
          id={"#{@id}-confirm"}
          popover
          role="dialog"
          aria-label={gettext("Restore this document?")}
          class="dk-confirm dk-menu"
          style="position-anchor: --dk-revert; inset: auto; bottom: anchor(top); right: anchor(right); margin: 0 0 4px"
        >
          <p>{gettext("Are you sure you want to restore this document?")}</p>
          <div class="confirm-actions">
            <button
              type="button"
              class="btn"
              popovertarget={"#{@id}-confirm"}
              popovertargetaction="hide"
              autofocus
            >
              {gettext("Cancel")}
            </button>
            <button
              type="button"
              class="btn danger"
              phx-click="restore-revision"
              phx-value-id={@revision.id}
              popovertarget={"#{@id}-confirm"}
              popovertargetaction="hide"
              data-desk-revert-confirm
            >
              {gettext("Confirm")}
            </button>
          </div>
        </div>
      </div>
      <style>
        .dk .revision-footer { margin: 4px; padding: 8px 8px 8px 12px; align-items: center; border-radius: 3px; background: var(--dk-caution-card-bg); }
        .dk .revision-footer .save-state { display: inline-flex; align-items: center; gap: 8px; color: var(--dk-warn-fg); }
        .dk .revision-footer .save-state strong { color: var(--dk-caution-card-fg); }
        .dk .revision-footer .save-state svg { flex: none; color: var(--dk-caution-dot); }
        .dk .revision-footer .dk-revert { margin-left: auto; }
        .dk .dk-confirm { width: 320px; padding: 0; }
        .dk .dk-confirm p { margin: 0; padding: 16px; font-size: 13px; border-bottom: 1px solid var(--dk-border); }
        .dk .dk-confirm .confirm-actions { display: grid; grid-template-columns: 1fr 1fr; gap: 8px; padding: 8px; }
        @media (pointer: coarse) { .dk .dk-confirm .btn { min-height: 44px; } }
      </style>
    </footer>
    """
  end

  attr :doc, :string, default: nil, doc: "the open document's mark (`PostIdentity.of/1`)"
  attr :revision, :string, default: nil, doc: "`desk_gone_latest`"

  @doc """
  The deleted document's "Restore most recent revision", with the page's
  copy of the document's mark: the deleted document has no form to read it from.
  """
  def restore_latest(assigns) do
    ~H"""
    <PostIdentity.holder doc={@doc} />
    <button
      :if={@revision}
      type="button"
      class="btn"
      phx-click="restore-revision"
      phx-value-id={@revision}
      data-desk-restore-latest
    >
      {gettext("Restore most recent revision")}
    </button>
    """
  end

  # Sanity's revision date: "Oct 6, 2026 @ 2:29:19 AM" (the server's clock, UTC).
  defp stamp(%DateTime{} = at), do: Calendar.strftime(at, "%b %-d, %Y @ %-I:%M:%S %p")
  defp stamp(_at), do: "…"
end
