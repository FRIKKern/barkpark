defmodule BarkparkWeb.Studio.Desk.IncomingRefs do
  # The most rows the panel draws.
  @cap 100

  @moduledoc """
  Sanity's "Incoming references" inspector for the document in the desk's
  edit pane, as the TanStack Studio draws it (`IncomingReferences.tsx`):
  every document that refers to this one, grouped by type, any time and not
  only when deleting. A row opens the referring document in the next pane, at
  the field that refers.

  It is open while the pane's URL says so
  (`inspect=sanity/structure/incoming-references`, Sanity's own name, so a
  link copied from either studio opens it in the other). The document menu's
  "Incoming references" puts it there and the panel's close button takes it
  out; both are patches, so Back closes or reopens it.

  The rows are `Content.Graph.backlinks/2`, the read behind
  `GET /v1/data/backlinks`: one row per referring document (a draft and its
  published version are one), under the page's own scope and caller, so a
  document this caller may not read is not listed. They are read when the
  panel opens and again after someone saves (`:desk_refresh`, the desk's one
  debounced tick): a document that starts to refer shows up, one that stops
  goes. A re-read that fails (the database is out) keeps the list it had.

  At most #{@cap} rows are drawn; past that a line says how many there are.

  Opening it puts the focus on its close button. Escape on that button or
  on a row, or a press of the button, closes it and gives the focus back to
  the "…" button. The key is bound on those elements themselves: LiveView
  runs a `phx-keydown` only for the element the key was pressed on, and
  Escape while typing in the form must leave the panel open.

  `EditorHost` owns the `desk_incoming` assign: `nil` while the panel is
  closed, else `%{groups: groups, total: n}`.
  """
  use Phoenix.Component
  use Gettext, backend: BarkparkWeb.Gettext

  require Logger

  alias Barkpark.Content
  alias BarkparkWeb.Studio.Desk.Panes
  alias BarkparkWeb.Studio.DocTitle
  alias Phoenix.LiveView.JS

  # Sanity's name for this inspector in the URL (`DocumentPane.tsx` INCOMING).
  @inspect_param "sanity/structure/incoming-references"

  @typedoc "One type's referring documents."
  @type group :: %{type: String.t(), title: String.t(), rows: [map()]}

  @doc "The most rows the panel draws."
  def cap, do: @cap

  @doc "The pane's `inspect` value that opens this inspector."
  def param, do: @inspect_param

  @doc "Whether `pane` asks for this inspector."
  def open?(%{kind: :doc, inspect: @inspect_param}), do: true
  def open?(_pane), do: false

  @doc """
  The document menu's item: a patch that opens the inspector on pane `index`.
  A button, so the menu's popover closes on the press.
  """
  def menu_item(chain, index, base, perspective \\ :drafts) do
    to =
      chain
      |> Panes.with_params(index, %{inspect: @inspect_param}, base)
      |> Panes.keep_perspective(perspective)

    %{label: gettext("Incoming references"), name: "incoming-references", event: JS.patch(to)}
  end

  @doc """
  Reads the referring documents when the last pane is the edited document
  and asks for the inspector; `nil` otherwise.
  """
  def load(%{assigns: %{editing: {dataset, _type, id}, chain: [_ | _] = chain}} = socket) do
    if open?(List.last(chain)),
      do: Phoenix.Component.assign(socket, :desk_incoming, read(id, dataset, socket.assigns)),
      else: Phoenix.Component.assign(socket, :desk_incoming, nil)
  end

  def load(socket), do: Phoenix.Component.assign(socket, :desk_incoming, nil)

  @doc """
  A `handle_info` hook (`EditorHost.mount/3`): on the desk's refresh tick the
  open panel reads again. The message goes on to the page either way.
  """
  def on_info(:desk_refresh, %{assigns: %{desk_incoming: %{}}} = socket) do
    {:cont, load(socket)}
  rescue
    # The database is out: the panel keeps its list, the page stays up, and
    # the next tick reads again.
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      Logger.warning("desk: incoming references were not read again: #{Exception.message(error)}")
      {:cont, socket}
  end

  def on_info(_message, socket), do: {:cont, socket}

  @doc """
  Every document that refers to `id`, one row each: `Content.Graph.backlinks/2`
  under the page's own scope and caller. A referrer that exists only as a
  draft is in it; a draft and its published version are one row; the
  document itself is not. The desk's delete and unpublish dialogs list the
  same rows (`DocDialog`).
  """
  @spec referrers(String.t(), String.t(), map()) :: [map()]
  def referrers(id, dataset, assigns) do
    # The page's scope, always set before a document is edited: without it
    # the read would not be fenced, so its absence raises.
    scope = Map.fetch!(assigns, :scope)
    here = Content.published_id(id)

    here
    |> Content.Graph.backlinks([dataset: dataset] ++ scope)
    |> Enum.reject(&(Content.published_id(&1.from_doc_id) == here))
    |> Enum.uniq_by(&Content.published_id(&1.from_doc_id))
  end

  # One row per referring document, grouped by type in the order the types
  # first appear, each group under its schema's title.
  @spec read(String.t(), String.t(), map()) :: %{groups: [group()], total: non_neg_integer()}
  defp read(id, dataset, assigns) do
    scope = Map.fetch!(assigns, :scope)
    all = referrers(id, dataset, assigns)
    rows = Enum.take(all, @cap)

    groups =
      for type <- rows |> Enum.map(& &1.type) |> Enum.uniq() do
        %{
          type: type,
          title: type_title(type, dataset, scope),
          rows: Enum.filter(rows, &(&1.type == type))
        }
      end

    %{groups: groups, total: length(all)}
  end

  defp type_title(type, dataset, scope) do
    case Content.get_schema(type, dataset, scope) do
      {:ok, %{title: title}} when is_binary(title) and title != "" -> title
      _ -> type
    end
  end

  attr :id, :string, required: true, doc: "the holder's id (`<pane>-inspector`)"
  attr :panel, :any, required: true, doc: "`desk_incoming`: nil while closed"
  attr :inspect, :string, default: nil, doc: "the pane's `inspect`, whatever it names"
  attr :chain, :list, required: true
  attr :index, :integer, required: true
  attr :base, :string, required: true
  attr :menu_button, :string, required: true, doc: "the \"…\" button the close gives the focus to"
  attr :perspective, :atom, default: :drafts, doc: "the page's, kept by the close button's patch"

  @doc """
  The edit pane's inspector holder, filled while this inspector is open. The
  holder is always in the page (hidden while nothing fills it), so opening
  and closing moves nothing around it.
  """
  def holder(assigns) do
    panel = assigns.panel

    assigns =
      assign(assigns,
        open: is_map(panel),
        groups: (panel && panel.groups) || [],
        total: (panel && panel.total) || 0,
        close:
          assigns.chain
          |> Panes.with_params(assigns.index, %{inspect: nil}, assigns.base)
          |> Panes.keep_perspective(assigns.perspective)
          |> JS.patch()
          |> JS.focus(to: ~s([id="#{assigns.menu_button}"]))
      )

    ~H"""
    <aside
      id={@id}
      class={["dk-inspector", @open && "inspector incoming"]}
      data-desk-inspector
      data-inspect={@inspect}
      aria-label={@open && gettext("Incoming references")}
      hidden={!@open}
    >
      <%= if @open do %>
        <.sheet />
        <header class="dk-inspector-head">
          <h2>{gettext("Incoming references")}</h2>
          <button
            type="button"
            class="dk-inspector-close icon-btn"
            aria-label={gettext("Close incoming references")}
            phx-click={@close}
            phx-keydown={@close}
            phx-key="escape"
            phx-mounted={JS.focus()}
            data-desk-inspector-close
          >
            <BarkparkWeb.Icons.desk_icon name="close" size={21} />
          </button>
        </header>
        <p :if={@groups == []} class="incoming-card dk-incoming-empty">
          {gettext("No incoming references found.")}
        </p>
        <p :if={@total > cap()} class="dk-incoming-more" role="status" data-desk-incoming-more>
          {gettext("Showing the first %{shown} of %{total}.", shown: cap(), total: @total)}
        </p>
        <section :for={group <- @groups} class="incoming-group" aria-label={group.title}>
          <h3>{group.title}</h3>
          <ul class="incoming-card">
            <li :for={row <- group.rows}>
              <.link
                patch={row_path(row, @chain, @index, @base)}
                class="preview dk-incoming-row"
                phx-keydown={@close}
                phx-key="escape"
                data-desk-incoming-row={row.from_doc_id}
              >
                <span class="media" aria-hidden="true">
                  <BarkparkWeb.Icons.desk_icon name="document" size={21} />
                </span>
                <span class="text"><span class="t">{row_title(row)}</span></span>
              </.link>
            </li>
          </ul>
        </section>
      <% end %>
    </aside>
    """
  end

  # The referring document in the next pane, at the field that refers.
  defp row_path(row, chain, index, base) do
    next = %{kind: :doc, id: row.from_doc_id, type: row.type}
    next = if row[:via_field] in [nil, ""], do: next, else: Map.put(next, :path, row.via_field)
    Panes.open_after(chain, index, next, base)
  end

  defp row_title(row), do: DocTitle.shown(row.title) || gettext("Untitled")

  # The TanStack Studio's `.inspector` (barkpark-studio `styles.css`): a third
  # of the document pane and never under 320 px, a line on its left, its
  # groups as bordered cards. The form keeps the rest: the pane body makes
  # room with padding, because the Studio's shell is several elements in a
  # column and cannot share a row. Under 600 px the inspector covers the form,
  # as TanStack's. Drawn with the panel, so a closed inspector costs nothing.
  defp sheet(assigns) do
    ~H"""
    <style>
      .dk .dk-edit-body:has(> .dk-inspector:not([hidden])) { position: relative; padding-right: max(320px, 33.333%) !important; }
      .dk .dk-edit-body > .dk-inspector:not([hidden]) { position: absolute; top: 0; right: 0; bottom: 0; box-sizing: border-box; width: max(320px, 33.333%); overflow: auto; padding: 11px 12px 12px; border-left: 1px solid var(--dk-border); background: var(--dk-bg); color: var(--dk-fg); font-size: 13px; line-height: 19px; }
      @media (max-width: 599px) {
        .dk .dk-edit-body:has(> .dk-inspector:not([hidden])) { padding-right: 0 !important; }
        .dk .dk-edit-body > .dk-inspector:not([hidden]) { left: 0; width: auto; border-left: 0; z-index: 2; }
      }
      .dk .dk-inspector-head { display: flex; align-items: center; justify-content: space-between; padding: 0 0 12px 8px; }
      .dk .dk-inspector-head h2 { margin: 0; font-size: 13px; line-height: 19px; font-weight: 500; color: var(--dk-fg); }
      .dk .dk-inspector-close { display: grid; place-items: center; width: 25px; height: 25px; padding: 0; border: 0; border-radius: 3px; background: none; color: var(--dk-icon-muted); cursor: pointer; }
      .dk .dk-inspector-close:hover { background: var(--dk-icon-btn-hover); color: var(--dk-fg); }
      .dk .dk-inspector-close:focus-visible, .dk .dk-incoming-row:focus-visible { outline: 2px solid var(--dk-focus-ring); outline-offset: -2px; }
      .dk .dk-inspector ul { list-style: none; margin: 0 8px; padding: 4px; display: flex; flex-direction: column; gap: 0; border: 1px solid var(--dk-border); border-radius: 4px; }
      .dk .dk-inspector .dk-incoming-empty { margin: 12px 0 0; padding: 11px 12px; border: 1px solid var(--dk-border); border-radius: 4px; color: var(--dk-muted); }
      .dk .dk-inspector .dk-incoming-more { margin: 0 8px 4px 16px; color: var(--dk-muted); }
      .dk .dk-inspector .incoming-group + .incoming-group { margin-top: 16px; }
      .dk .dk-inspector .incoming-group h3 { margin: 23px 8px 15px 16px; font-size: 13px; line-height: 19px; font-weight: 500; color: var(--dk-fg); }
      .dk .dk-incoming-row { display: flex; align-items: center; gap: 8px; box-sizing: border-box; min-height: 33px; margin-bottom: 2px; padding: 5px 8px 5px 12px; border-radius: 3px; color: var(--dk-fg); text-decoration: none; }
      .dk .dk-incoming-row:hover { background: var(--dk-card-hover); }
      .dk .dk-incoming-row .media { flex: none; display: grid; place-items: center; color: var(--dk-icon-muted); }
      .dk .dk-incoming-row .text { flex: 1; min-width: 0; }
      .dk .dk-incoming-row .t { display: block; font-weight: 500; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      @media (pointer: coarse) { .dk .dk-inspector-close { min-width: 44px; min-height: 44px; } }
    </style>
    """
  end
end
