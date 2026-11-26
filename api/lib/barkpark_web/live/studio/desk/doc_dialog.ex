defmodule BarkparkWeb.Studio.Desk.DocDialog do
  @moduledoc """
  What the desk's own document dialogs share (`DeleteDialog`,
  `UnpublishDialog`): the dialog's frame, the "used in" list of the documents
  that refer to the open one, and their look.

  The Studio's handlers still open, close and confirm these dialogs
  (`Handlers.Delete`, `Handlers.Doc`): they set `show_delete` or
  `show_unpublish_guard`. The desk draws its own dialog from those assigns
  and keeps the old Studio's modal out of its page (`EditorHost.pane/2`).
  Nothing here writes.

  `follow/1` reads who refers to the open document once, when a dialog
  opens: the rows of the Incoming references panel
  (`IncomingRefs.referrers/3`, `Content.Graph.backlinks/2` under the page's
  scope and caller), so the dialog and the panel name the same documents.
  One row per referring document, with its type's title and the field that
  refers ("Post / author"); a referrer that exists only as a draft is
  listed. The handler's own list (`Content.Graph.reverse_referencers/2`,
  the edge index, which has no row for such a draft) is not drawn; what a
  confirm disconnects is the handler's business, read again when it runs.
  As the panel, at most `IncomingRefs.cap/0` rows are drawn and a line under
  them says how many there are; the count above says them all.
  `EditorHost` calls `follow/1` after every Studio event and owns the
  `desk_used_in` assign: `nil` while no dialog is open.

  The frame is a `role="dialog"` with the shared `ModalFocus` hook: the focus
  starts on Cancel (`data-modal-focus`), Tab stays inside, Escape closes it
  and the focus goes back to where it was. The names and words are the
  TanStack Studio's (`DeleteDialog.tsx`, `UnpublishDialog.tsx`), which its
  e2e specs find them by.
  """
  use Phoenix.Component
  use Gettext, backend: BarkparkWeb.Gettext

  alias Barkpark.Content
  alias BarkparkWeb.Studio.Desk.IncomingRefs
  alias BarkparkWeb.Studio.Desk.Panes
  alias BarkparkWeb.Studio.DocTitle

  @typedoc "One referring document and the field it refers from."
  @type row :: %{id: String.t(), type: String.t(), kind: String.t(), title: term(), field: term()}

  @doc """
  Keeps `desk_used_in` in step with the Studio's dialogs: the rows while the
  delete dialog or the unpublish dialog is open, `nil` otherwise. The rows
  are read when a dialog opens, and again only when the handler's own
  referrers changed under an open one.
  """
  def follow(socket) do
    assigns = socket.assigns

    source =
      cond do
        assigns[:show_delete] == true -> {:delete, assigns[:delete_refs] || []}
        assigns[:show_unpublish_guard] == true -> {:unpublish, assigns[:unpublish_refs] || []}
        true -> nil
      end

    case {source, assigns[:desk_used_in]} do
      {nil, nil} ->
        socket

      {nil, _open} ->
        assign(socket, :desk_used_in, nil)

      {source, %{source: source}} ->
        socket

      {source, _stale} ->
        assign(socket, :desk_used_in, %{source: source, rows: read(assigns)})
    end
  end

  @doc "The open dialog's rows (`desk_used_in`); none while it is closed."
  def rows(%{rows: rows}), do: rows
  def rows(_closed), do: []

  @doc "How many documents refer: one row each."
  def count(rows), do: length(rows)

  @doc "The warning's words: how many documents refer to the one titled `title`."
  def refers(count, title) do
    ngettext(
      "1 document refers to “%{title}”",
      "%{count} documents refer to “%{title}”",
      count,
      title: title
    )
  end

  # The open document's referrers, as the dialog's rows. Read when a dialog
  # opens: the handler has just read the edge index for the same document,
  # so the database is there.
  defp read(%{editor_doc: %{doc_id: doc_id}, dataset: dataset} = assigns)
       when is_binary(dataset),
       do: assigns |> then(&rows_for([doc_id], &1)) |> Map.get(doc_id, [])

  defp read(_assigns), do: []

  @doc """
  The rows of each of `ids`, by id: who refers to it. The bulk unpublish
  dialog (`Bulk`) asks for every ticked document at once; each type's title
  is read once for all of them.
  """
  @spec rows_for([String.t()], map()) :: %{String.t() => [row()]}
  def rows_for(ids, %{dataset: dataset} = assigns) when is_list(ids) and is_binary(dataset) do
    scope = Map.fetch!(assigns, :scope)

    found =
      for id <- ids, into: %{} do
        rows =
          for ref <- IncomingRefs.referrers(id, dataset, assigns) do
            %{
              id: Content.published_id(ref.from_doc_id),
              type: ref.type,
              title: ref[:title],
              field: ref[:via_field]
            }
          end

        {id, rows}
      end

    types = found |> Map.values() |> List.flatten() |> Enum.map(& &1.type) |> Enum.uniq()
    kinds = Map.new(types, &{&1, kind(&1, dataset, scope)})
    Map.new(found, fn {id, rows} -> {id, Enum.map(rows, &Map.put(&1, :kind, kinds[&1.type]))} end)
  end

  defp kind(type, dataset, scope) do
    case Content.get_schema(type, dataset, scope) do
      {:ok, %{title: title}} when is_binary(title) and title != "" -> title
      _ -> type
    end
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :close, :string, required: true, doc: "the Studio's event that closes it"
  attr :name, :string, required: true, doc: "which dialog (`data-desk-dialog`)"
  slot :inner_block, required: true
  slot :actions, required: true

  @doc "The dialog: a dim layer, a card with its title and close button, a body and its buttons."
  def frame(assigns) do
    ~H"""
    <.sheet />
    <div class="dk-dialog-backdrop" style="position: fixed; inset: 0" phx-click={@close}></div>
    <div
      id={@id}
      class="dk-dialog dialog delete-dialog"
      role="dialog"
      aria-modal="true"
      aria-labelledby={"#{@id}-title"}
      data-desk-dialog={@name}
      phx-hook="ModalFocus"
      phx-window-keydown={@close}
      phx-key="escape"
    >
      <header class="dk-dialog-head">
        <h2 id={"#{@id}-title"}>{@title}</h2>
        <button type="button" class="dk-dialog-close icon-btn" aria-label={gettext("Close")} phx-click={@close}>
          <BarkparkWeb.Icons.desk_icon name="close" size={21} />
        </button>
      </header>
      <div class="dk-dialog-body dialog-body">{render_slot(@inner_block)}</div>
      <footer class="dk-dialog-foot">{render_slot(@actions)}</footer>
    </div>
    """
  end

  attr :rows, :list, required: true
  attr :base, :string, required: true, doc: "the desk's base path"

  attr :field, :boolean,
    default: false,
    doc: "say the type and the field that refers under each title"

  @doc """
  The documents that refer to the open one, each a link that opens it in a
  new tab: the first `IncomingRefs.cap/0`, and a line for the rest.
  """
  def used_in(assigns) do
    assigns =
      assign(assigns,
        shown: Enum.take(assigns.rows, IncomingRefs.cap()),
        total: length(assigns.rows)
      )

    ~H"""
    <ul class={["used-in dk-used-in", !@field && "compact"]}>
      <li :for={row <- @shown}>
        <a
          class="preview"
          href={path(row, @base)}
          target="_blank"
          rel="noreferrer"
          title={gettext("Open in a new tab (%{type})", type: row.kind)}
        >
          <span class="media" aria-hidden="true">
            <BarkparkWeb.Icons.desk_icon name="document" size={21} />
          </span>
          <span class="text">
            <span class="t">{DocTitle.shown(row.title) || gettext("Untitled")}</span>
            <span :if={@field and row.field not in [nil, ""]} class="s">{row.kind} / {row.field}</span>
            <span :if={@field and row.field in [nil, ""]} class="s">{row.kind}</span>
          </span>
        </a>
      </li>
    </ul>
    <p :if={@total > length(@shown)} class="dk-used-in-more" data-desk-used-in-more>
      {gettext("Showing the first %{shown} of %{total}.", shown: length(@shown), total: @total)}
    </p>
    """
  end

  # The referring document from its type's list, as a desk URL.
  defp path(row, base) do
    Panes.to_path(
      [
        %{kind: :types},
        %{kind: :list, type: row.type},
        %{kind: :doc, id: row.id, type: row.type}
      ],
      base
    )
  end

  # The TanStack Studio's `.dialog` (barkpark-studio `styles.css`), in the
  # desk's own colours, so it follows light and dark with the rest of the
  # desk. Drawn with the dialog, so a closed one costs nothing. Studio's
  # leave question (`.studio-leave`, `LeaveAsk.dialog/1`) takes its place
  # from here and its colours from Studio's own tokens.
  defp sheet(assigns) do
    ~H"""
    <style>
      .dk .dk-dialog-backdrop { z-index: 200; background: var(--dk-backdrop); }
      .dk .dk-dialog, .studio-leave .dk-dialog { position: fixed; top: 50%; left: 50%; transform: translate(-50%, -50%); box-sizing: border-box; width: min(420px, calc(100vw - 32px)); max-height: calc(100vh - 64px); display: flex; flex-direction: column; }
      .dk .dk-dialog { z-index: 201; border-radius: 6px; background: var(--dk-bg); color: var(--dk-fg); box-shadow: var(--dk-popover-shadow); font-size: 13px; line-height: 19px; }
      .dk .dk-dialog-head { display: flex; align-items: center; gap: 8px; padding: 12px 12px 0 20px; }
      .dk .dk-dialog-head h2 { flex: 1 1 auto; min-width: 0; margin: 0; font-size: 13px; line-height: 19px; font-weight: 600; color: var(--dk-fg); }
      .dk .dk-dialog-close { display: grid; place-items: center; width: 25px; height: 25px; padding: 0; border: 0; border-radius: 3px; background: none; color: var(--dk-icon-muted); cursor: pointer; }
      .dk .dk-dialog-close:hover { background: var(--dk-icon-hover); color: var(--dk-fg); }
      .dk .dk-dialog-body { flex: 1 1 auto; min-height: 0; overflow: auto; padding: 12px 20px 4px; }
      .dk .dk-dialog-body p { margin: 0 0 12px; overflow-wrap: anywhere; }
      .dk .dk-dialog-body hr { margin: 4px 0 12px; border: 0; border-top: 1px solid var(--dk-border); }
      .dk .dk-dialog-body [role="status"] { padding: 7px 12px; border-radius: 3px; background: var(--dk-fill-soft); color: var(--dk-fg); font-weight: 500; }
      .dk .dk-dialog-preview { display: flex; align-items: center; gap: 8px; margin: 0 0 12px; padding: 7px 12px; border-radius: 3px; box-shadow: inset 0 0 0 1px var(--dk-border); font-weight: 500; }
      .dk .dk-dialog-preview .t { flex: 1 1 auto; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      .dk .dk-dialog-preview .s { flex: none; color: var(--dk-muted); font-weight: 400; }
      .dk .dk-used-in { list-style: none; margin: 0 0 12px; padding: 4px; display: flex; flex-direction: column; gap: 2px; max-height: 240px; overflow: auto; border-radius: 4px; box-shadow: inset 0 0 0 1px var(--dk-border); }
      .dk .dk-used-in .preview { display: flex; align-items: center; gap: 8px; box-sizing: border-box; min-height: 33px; padding: 5px 8px; border-radius: 3px; color: var(--dk-fg); text-decoration: none; }
      .dk .dk-used-in .preview:hover { background: var(--dk-card-hover); }
      .dk .dk-used-in .media { flex: none; display: grid; place-items: center; color: var(--dk-icon-muted); }
      .dk .dk-used-in .text { flex: 1 1 auto; min-width: 0; display: flex; flex-direction: column; }
      .dk .dk-used-in .t { font-weight: 500; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      .dk .dk-used-in .s { color: var(--dk-muted); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      .dk .dk-dialog-body .dk-used-in-more { margin-top: -4px; color: var(--dk-muted); }
      .dk .dk-dialog-foot { display: flex; flex-wrap: wrap; justify-content: flex-end; gap: 8px; padding: 12px 20px 16px; }
      .dk .dk-dialog-btn { box-sizing: border-box; min-height: 33px; padding: 6px 12px; border: 0; border-radius: 3px; background: var(--dk-bg); color: var(--dk-fg); box-shadow: inset 0 0 0 1px var(--dk-border); font: inherit; font-weight: 500; cursor: pointer; }
      .dk .dk-dialog-btn:hover { background: var(--dk-card-hover); }
      .dk .dk-dialog-btn.danger { background: var(--dk-menu-danger-hover); color: var(--dk-bg); box-shadow: none; }
      .dk .dk-dialog-btn.danger:hover { background: var(--dk-menu-danger); }
      .dk .dk-dialog-btn:focus-visible, .dk .dk-dialog-close:focus-visible, .dk .dk-used-in .preview:focus-visible { outline: 2px solid var(--dk-focus-ring); outline-offset: 2px; }
      @media (pointer: coarse) { .dk .dk-dialog-btn, .dk .dk-dialog-close { min-width: 44px; min-height: 44px; } }
    </style>
    """
  end
end
