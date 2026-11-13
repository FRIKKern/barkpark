defmodule BarkparkWeb.Studio.Desk.PaneComponent do
  @moduledoc """
  One pane of the desk slice (`BarkparkWeb.Studio.DeskLive`). Each pane owns
  its own data, so a click builds only the pane it opens: the panes that
  stay keep what they read, and the new one draws its frame at once and
  fills in when its read lands.

  A desk list or the root needs no read (the tree is in memory). A document
  list and a document read in a task (`start_async/3`); a read that fails is
  this pane's to show, with a Retry, and the other panes stay up.

  Every read emits `[:barkpark, :desk, :pane_load]` with `%{kind, key}`, so
  a test or the scorecard can count what a click cost.
  """

  use BarkparkWeb, :live_component

  alias Barkpark.Content
  alias Barkpark.Content.TitleDerivation
  alias Barkpark.Structure
  alias BarkparkWeb.Studio.Desk.ListMenu
  alias BarkparkWeb.Studio.Desk.ListSearch
  alias BarkparkWeb.Studio.Desk.Panes
  alias BarkparkWeb.Studio.Desk.Refs
  alias BarkparkWeb.Studio.Desk.Rows
  alias BarkparkWeb.Studio.Desk.Tree
  alias BarkparkWeb.Studio.PaneBuilder
  alias Phoenix.LiveView.AsyncResult

  @page 100

  # The page says this pane's data changed under it (someone saved): read
  # again, keeping what is on screen until the new read lands. A read still
  # out is let land (a storm of saves would otherwise restart it for ever,
  # and the pane would never fill); one more read follows it.
  @impl true
  def update(%{refresh: _}, socket) do
    if socket.assigns[:in_flight],
      do: {:ok, assign(socket, :again, true)},
      else: {:ok, load(socket)}
  end

  # A pane with this pane's key (a split sibling) asks for its read rather
  # than reading too: answered now, or when the read under way lands.
  def update(%{share_with: id}, socket) do
    socket = assign(socket, :sharers, Enum.uniq([id | socket.assigns.sharers]))
    {:ok, if(socket.assigns.data.loading, do: socket, else: share(socket))}
  end

  def update(%{shared: {key, data}}, socket) do
    cond do
      key != socket.assigns.data_key -> {:ok, socket}
      # A failure is for a pane still waiting; one that has read since keeps it.
      data.failed && !socket.assigns.in_flight -> {:ok, socket}
      data.failed -> {:ok, socket |> assign(:data, data) |> landed()}
      true -> {:ok, socket |> adopt(data.result) |> landed()}
    end
  end

  # Typing in the list's search box paused (`ListSearch`).
  def update(%{list_search_due: due}, socket), do: {:ok, ListSearch.due(socket, due, &load/1)}

  def update(assigns, socket) do
    socket =
      socket
      |> assign(
        Map.take(
          assigns,
          ~w(id pane index panes base dataset scope node follows orderings sorts)a
        )
      )
      |> assign_new(:sharers, fn -> [] end)
      |> assign_new(:orderings, fn -> [] end)
      |> assign_new(:sorts, fn -> [] end)
      |> assign_new(:limit, fn -> Rows.page() end)
      # The sort this editor keeps for the type (`ListMenu`), at first.
      |> assign_new(:sort, fn -> assigns[:list_sort] end)
      |> assign_new(:in_flight, fn -> false end)
      |> assign_new(:again, fn -> false end)
      |> assign_new(:more_out, fn -> false end)
      |> ListSearch.init()

    key = data_key(assigns.pane, assigns.dataset, assigns.node)
    same? = socket.assigns[:data_key] == key
    # `loading` is nil once the read has landed, so `&&`, not `and`.
    waiting? = same? && socket.assigns.data.loading
    warm = assigns[:warm]

    cond do
      # What a hover already read: the pane opens with its data. A pane that
      # shows rows and reads again (a search, a sort) keeps its newer read:
      # any hover re-draws the page and hands the old page back.
      warm && ((waiting? && !socket.assigns.data.ok?) || not same?) ->
        socket = socket |> assign(:data_key, key) |> cancel_async(:load) |> adopt(warm)
        {:ok, assign(socket, in_flight: false, again: false)}

      # Loading with no read out and no editor coming: the pane was drawn on
      # hold for the editor and is a read-only parent now. Nothing else
      # would ever fill it.
      waiting? && !socket.assigns.in_flight && !assigns[:hold] ->
        {:ok, load(socket)}

      same? ->
        {:ok, socket}

      # The page is about to put the Studio's editor here: draw the frame and
      # leave the read to it.
      assigns[:hold] ->
        {:ok, socket |> assign(:data_key, key) |> assign(:data, AsyncResult.loading())}

      true ->
        {:ok, socket |> assign(:data_key, key) |> load()}
    end
  end

  @doc "What a pane's data depends on: two panes with one key show one read."
  @spec data_key(Panes.pane(), String.t(), struct() | nil) :: term()
  def data_key(pane, dataset, node),
    do: {Panes.pane_key(pane), pane[:type], dataset, node && node.filter}

  @doc """
  One pane's read, as the pane itself runs it. `DeskLive` runs it ahead of a
  click when a row is hovered (`source: :warm`), and a list's first page in
  the page's first render (`source: :first`, `ListFirst`).
  """
  @spec read_pane(Panes.pane(), struct() | nil, String.t(), keyword(), :pane | :warm | :first) ::
          map()
  def read_pane(pane, node, dataset, scope, source \\ :pane) do
    meta = %{kind: pane.kind, key: data_key(pane, dataset, node), source: source}
    :telemetry.execute([:barkpark, :desk, :pane_load], %{count: 1}, meta)
    reader().(pane, node, dataset, scope, provisional_title(pane, node))
  end

  @impl true
  def handle_event("retry", _params, socket), do: {:noreply, read_async(socket)}

  # A list's own controls. They are this pane's state, not the URL's.
  #
  # The list scrolled to its last row (`phx-viewport-bottom`): the rest, read
  # after the rows it holds and added below them, up to `Rows.max_rows/0`.
  def handle_event("more", _params, socket),
    do: {:noreply, if(more?(socket), do: read_more(socket), else: socket)}

  # A pick in the list menu (`ListMenu`); the page keeps it for the type.
  # "" is Default sort; anything else must be one the type offers, or the
  # pick is ignored: nothing read, nothing kept.
  def handle_event("sort", %{"sort" => name}, socket) when is_binary(name) do
    sort = if name != "", do: ListMenu.pick(name, socket.assigns.sorts)

    if name != "" and is_nil(sort) do
      {:noreply, socket}
    else
      send(self(), {:desk_list_sort, socket.assigns.pane.type, sort})
      {:noreply, socket |> assign(:sort, sort) |> load()}
    end
  end

  # The list's own search box (`ListSearch`): typing, its keys, Enter, Clear.
  def handle_event("list-search" <> _ = event, params, socket),
    do: ListSearch.handle(event, params, socket, &load/1)

  @impl true
  def handle_async(:load, {:ok, data}, socket),
    do: {:noreply, socket |> adopt(data) |> ListSearch.landed() |> landed()}

  # Cancelled because the pane took a hover's read instead: not a failure.
  def handle_async(:load, {:exit, {:shutdown, :cancel}}, socket),
    do: {:noreply, assign(socket, :in_flight, false)}

  # The page reads a failed pane again by itself (`LiveRefresh`, J50).
  def handle_async(:load, {:exit, reason}, socket) do
    send(self(), {:desk_pane_failed, socket.assigns.id})
    data = AsyncResult.failed(socket.assigns.data, reason)
    {:noreply, socket |> assign(:data, data) |> share() |> landed()}
  end

  # The next page is back. A whole read started since then answers for it.
  def handle_async(:more, {:ok, %{entries: [_ | _] = rows, more?: more?}}, socket) do
    %{data: %AsyncResult{result: held}, limit: limit, in_flight: in_flight} = socket.assigns
    socket = assign(socket, :more_out, false)

    if in_flight do
      {:noreply, socket}
    else
      data = AsyncResult.ok(%{held | entries: held.entries ++ rows, more?: more?})
      {:noreply, assign(socket, data: data, limit: limit + length(rows))}
    end
  end

  # Nothing more after all, a failed page, or one a whole read cancelled: the
  # rows on screen stay, and the next scroll to the bottom asks again.
  def handle_async(:more, _result, socket), do: {:noreply, assign(socket, :more_out, false)}

  defp more?(%{assigns: %{data: data} = assigns}) do
    data.ok? and !data.loading and !assigns.in_flight and !assigns.more_out and
      is_nil(assigns[:reading]) and data.result[:more?] == true and
      assigns.limit < Rows.max_rows()
  end

  # The list holds all it ever will and there are more.
  defp capped?(%{data: data, limit: limit}),
    do: data.result[:more?] == true and limit >= Rows.max_rows()

  # The rest up to the most in one read, as the TanStack Studio's list grows
  # (`setLimit(LIST_MAX)`): a page a read was a round trip per 100 rows, and a
  # fast scroll on guerrilla reached about 300 rows, never the end.
  defp read_more(socket) do
    %{pane: pane, node: node, dataset: dataset, scope: scope} = socket.assigns
    %{panes: panes, index: index, limit: held, sort: sort} = socket.assigns
    step = Rows.max_rows() - held
    pane = Map.put(pane, :query, Rows.query(panes, index, step, sort, held))

    socket
    |> assign(:more_out, true)
    |> start_async(:more, in_locale(fn -> read_pane(pane, node, dataset, scope) end))
  end

  # A read is back. A save that came while it was out is read now.
  defp landed(%{assigns: %{again: true}} = socket),
    do: socket |> assign(again: false) |> load()

  defp landed(socket), do: assign(socket, :in_flight, false)

  defp adopt(socket, data) do
    # The tab title follows the last pane; only the page can set it.
    send(self(), {:desk_pane_title, socket.assigns.id, data.title})
    data = Tree.tree_rows(data, socket.assigns.pane, socket.assigns.node)
    # Which key the result on screen was read for: while the pane reads for
    # another, the last result stays (`shown_key`).
    socket
    |> assign(:data, AsyncResult.ok(data))
    |> assign(:shown_key, socket.assigns.data_key)
    |> share()
  end

  # Hand this pane's read, landed or failed, to the panes that asked for it.
  # After a failure they stay on the list: the read that follows (Retry, or
  # the page's own) is theirs too.
  defp share(%{assigns: %{sharers: sharers, data_key: key, data: data}} = socket) do
    for id <- sharers, do: send_update(__MODULE__, id: id, shared: {key, data})
    if data.failed, do: socket, else: assign(socket, :sharers, [])
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section
      id={@id}
      class={["pane-column", "dk-pane", "pane", to_string(@pane.kind), @pane.kind == :doc && "dk-doc"]}
      data-pane-index={@index}
      data-pane-kind={@pane.kind}
      data-pane={@pane.kind == :types && "types"}
      aria-label={title(assigns)}
      aria-busy={@data.loading && "true"}
    >
      <div class="pane-header">
        <span class="pane-header-title" role="heading" aria-level="2">{title(assigns)}</span>
        <%!-- J18: the Studio's own "+" event, which the page hands to the
              Studio (`EditorHost`); the new document opens after this pane. --%>
        <button
          :if={@pane.kind == :list && @data.ok? && @data.result[:creatable]}
          type="button"
          class="dk-create-new"
          phx-click="new-document"
          phx-value-type={@pane.type}
          phx-value-desk-pane={@index}
          aria-label={
            gettext("Create new %{type}", type: @data.result[:type_title] || @pane.type)
          }
          title={gettext("Create new document")}
        >
          <span aria-hidden="true">+</span>
        </button>
        <ListMenu.menu
          :if={@pane.kind == :list}
          id={@id}
          index={@index}
          sort={@sort}
          orderings={@orderings}
          named={(@data.ok? && @data.result[:sorts]) || []}
          myself={@myself}
        />
        <.link
          :if={@index > 0}
          patch={Panes.close_from(@panes, @index, @base)}
          class="dk-close"
          aria-label={gettext("Close %{title}", title: title(assigns))}
        >
          <span aria-hidden="true">×</span>
        </.link>
      </div>
      <ListSearch.box
        :if={@pane.kind == :list}
        id={@id}
        q={@q}
        lit={@lit}
        searching={ListSearch.searching?(assigns)}
        myself={@myself}
      />
      <div class={["pane-body", @pane.kind == :list && "list-rows"]}>
        <div :if={@data.loading && !@data.ok?} class="dk-skeleton" aria-hidden="true">
          <div :for={_ <- 1..6} class="pane-item"><span class="dk-bone"></span></div>
        </div>
        <div :if={@data.failed} class="dk-note" role="alert">
          <p>{gettext("This pane could not be read.")}</p>
          <button type="button" class="btn" phx-click="retry" phx-target={@myself}>
            {gettext("Retry")}
          </button>
        </div>
        <%= if @data.ok? do %>
          <%!-- Not over a document that was not found: it has no current one.
               Nor over the one before, still shown while this one is read. --%>
          <p :for={note <- (@data.result[:fields] && assigns[:shown_key] == @data_key && left_out(@pane)) || []} class="dk-note" data-desk-left-out>{note}</p>
          <p :if={@data.result[:note]} class="dk-note">{@data.result.note}</p>
          <%!-- The TanStack Studio's names (ruling R1): a document list is a
               `role="list"` named after its pane, each row a `listitem` that
               knows its place; the link inside stays the thing with focus. --%>
          <div
            :if={(@data.result[:entries] || []) != []}
            id={@pane.kind == :list && ListSearch.rows_id(@id)}
            class="dk-rows"
            role={@pane.kind == :list && "list"}
            aria-label={@pane.kind == :list && title(assigns)}
            phx-viewport-bottom={@pane.kind == :list && "more"}
            phx-target={@pane.kind == :list && @myself}
          >
            <%= for {entry, pos} <- placed(@data.result.entries) do %>
              <div :if={entry == :divider} class="pane-divider"></div>
              <%!-- A titled divider, as the TanStack root's "Settings": no row,
                   so no Tab or arrow stop. --%>
              <div :if={match?({:divider, _}, entry)} class="desk-divider">{elem(entry, 1)}</div>
              <div
                :if={is_map(entry)}
                id={@pane.kind == :list && ListSearch.item_id(@id, pos - 1)}
                class={["dk-row", ListSearch.lit?(assigns, pos - 1) && "dk-lit"]}
                data-lit={ListSearch.lit?(assigns, pos - 1)}
                role={@pane.kind == :list && "listitem"}
                aria-posinset={@pane.kind == :list && pos}
              >
                <div :if={is_nil(entry.next)} class="pane-item">
                  <span class="pane-item-label">{entry.title}</span>
                </div>
                <.link
                  :if={entry.next}
                  patch={Panes.open_after(@panes, @index, entry.next, @base)}
                  class={["pane-item", selected?(@panes, @index, entry.next) && "selected"]}
                  aria-current={selected?(@panes, @index, entry.next) && "true"}
                  data-selected={selected?(@panes, @index, entry.next)}
                  data-desk-row
              data-desk-opens={entry.next.kind}
            >
              <%!-- The title is an element of its own, as the TanStack row's
                   `.t`: a spec finds a row by its title alone. --%>
              <span class="pane-item-label">
                <span class="dk-row-title">{entry.title}</span>
                <span :if={entry[:sub]} class="dk-row-sub">{entry.sub}</span>
              </span>
              <span :if={entry[:draft]} class="dk-draft" title={gettext("Draft")}>
                <span aria-hidden="true">○</span>
                <span class="sr-only">{gettext("Draft")}</span>
              </span>
              <%!-- A singleton on the root opens its document as a pane, so it
                   has the chevron too, as the TanStack root's. --%>
              <span
                :if={entry.next.kind != :doc or @pane.kind == :types}
                class="pane-item-chevron"
                aria-hidden="true"
              >
                <BarkparkWeb.Icons.icon name="chevron-right" size={16} />
              </span>
                </.link>
              </div>
            <% end %>
          </div>
          <%!-- Room below the last row while there are more. LiveView's scroll
               hook asks for more once the last row is wholly inside the pane,
               which it never is flush with the pane's bottom; and a pane
               scrolled to its very end hands a fast wheel to the page, so the
               rows read below would never be scrolled to. --%>
          <div
            :if={@pane.kind == :list && @data.result[:more?] == true && !capped?(assigns)}
            class="dk-list-more"
            aria-hidden="true"
            style="height: 480px"
          >
          </div>
          <%!-- As the TanStack Studio's list (and Sanity's): it holds 2,000;
               its search reaches the rest. --%>
          <p :if={capped?(assigns)} class="dk-note dk-list-max" role="status">
            {gettext("Displaying a maximum of %{count} documents", count: Rows.max_rows())}
          </p>
          <dl :if={@data.result[:fields]} class="dk-fields">
            <div :for={field <- @data.result.fields}>
              <dt>{field.title}</dt>
              <dd :if={!field[:refs]}>{field.value}</dd>
              <dd :if={field[:refs]} class="dk-refs">
                <span :if={field.refs == []}>—</span>
                <%= for ref <- field.refs do %>
                  <span :if={!ref.type} class="dk-ref-missing">{ref.title}</span>
                  <.link
                    :if={ref.type}
                    patch={Panes.open_after(@panes, @index, ref_pane(ref, field.path), @base)}
                    class="dk-ref"
                    aria-current={selected?(@panes, @index, ref_pane(ref, field.path)) && "true"}
                    data-desk-ref
                  >
                    {ref.title}
                  </.link>
                <% end %>
              </dd>
            </div>
          </dl>
        <% end %>
      </div>
    </section>
    """
  end

  # The title before the read lands: what the URL and the tree already say.
  defp title(%{data: %AsyncResult{ok?: true, result: %{title: title}}}), do: title
  defp title(%{pane: pane, node: node}), do: provisional_title(pane, node)

  @doc "A pane's title from the URL and the tree alone, before anything is read."
  @spec provisional_title(Panes.pane(), struct() | nil) :: String.t()
  def provisional_title(%{kind: :doc, id: id}, _node), do: id
  def provisional_title(pane, %{} = node), do: node.pane_title || node.title || fallback(pane)
  def provisional_title(pane, nil), do: fallback(pane)

  # What a link from the TanStack Studio or Sanity asks for that this desk does
  # not draw. Said in the pane, so the current document is not taken for an
  # old revision. From the URL, not the read: panes that differ only in these
  # share one read.
  @doc false
  def left_out(%{kind: :doc} = pane) do
    Enum.filter(
      [
        pane[:rev] &&
          gettext("This is the current document. Revision “%{rev}” is not shown here.",
            rev: pane.rev
          ),
        (pane[:view] || pane[:inspect]) &&
          gettext("Other views and inspectors are not shown here.")
      ],
      & &1
    )
  end

  def left_out(_pane), do: []

  defp fallback(%{kind: :types}), do: gettext("Content")
  defp fallback(%{kind: :menu, node: id}), do: id
  defp fallback(%{kind: :list, type: type}), do: type

  # A reference opens its target beside this document, as the TanStack Studio
  # writes it: `author-ada,type=author,parentRefPath=author`.
  defp ref_pane(ref, path), do: %{kind: :doc, id: ref.id, type: ref.type, parent_ref_path: path}

  defp selected?(panes, index, next), do: same?(Enum.at(panes, index + 1), next)

  # Each row with its place among the rows (a divider has none).
  defp placed(entries) do
    {placed, _} =
      Enum.map_reduce(entries, 1, fn
        :divider, pos -> {{:divider, nil}, pos}
        {:divider, _title} = divider, pos -> {{divider, nil}, pos}
        entry, pos -> {{entry, pos}, pos + 1}
      end)

    placed
  end

  defp same?(%{kind: :doc, id: id}, %{kind: :doc, id: id}), do: true

  defp same?(%{kind: kind, node: node} = open, %{kind: kind, node: node} = next)
       when kind != :doc,
       do: open[:tree_parent] == next[:tree_parent]

  defp same?(_open, _next), do: false

  # ── reading ────────────────────────────────────────────────────────────────

  defp load(%{assigns: %{pane: %{kind: kind}} = assigns} = socket) when kind in [:types, :menu] do
    data =
      case assigns.node do
        nil -> %{title: title(assigns), note: gettext("This list is not on the desk.")}
        node -> %{title: title(assigns), entries: node_entries(node)}
      end

    assign(socket, :data, AsyncResult.ok(data))
  end

  # An earlier pane reads the same thing: ask it, so the two cost one read.
  defp load(%{assigns: %{follows: leader}} = socket) when is_binary(leader) do
    send_update(__MODULE__, id: leader, share_with: socket.assigns.id)

    socket
    |> assign(:in_flight, true)
    |> assign(:data, AsyncResult.loading(socket.assigns[:data] || AsyncResult.loading()))
  end

  defp load(socket), do: read_async(socket)

  defp read_async(socket) do
    %{pane: pane, node: node, dataset: dataset, scope: scope} = socket.assigns
    %{panes: panes, index: index, limit: limit, sort: sort} = socket.assigns
    pane = with_query(pane, panes, index, limit, sort)
    # A list being searched reads the search instead of its rows.
    q = pane.kind == :list && ListSearch.term(socket.assigns.q)
    pane = if q, do: Map.put(pane, :search, q), else: pane

    # A list asked for another order keeps its rows on screen; a page on its
    # way below them is read with them.
    socket
    |> cancel_async(:more)
    |> assign(:more_out, false)
    |> assign(:reading, q || nil)
    |> assign(:in_flight, true)
    |> assign(:data, AsyncResult.loading(socket.assigns[:data] || AsyncResult.loading()))
    |> start_async(:load, in_locale(fn -> read_pane(pane, node, dataset, scope) end))
  end

  @doc """
  `read` as a task body that renders in this process's Gettext locale. A
  task has none of its own, so a read's notes came out English in an nb-NO
  workspace. Call it in the LiveView's process, where the locale is put.
  """
  @spec in_locale((-> result)) :: (-> result) when result: term()
  def in_locale(read) do
    locale = Gettext.get_locale(BarkparkWeb.Gettext)

    fn ->
      Gettext.put_locale(BarkparkWeb.Gettext, locale)
      read.()
    end
  end

  @doc """
  A list pane together with what it is asked for (`Rows.query/4`); any other
  pane as it is. The read needs the query; the URL grammar never sees it.
  """
  @spec with_query(Panes.pane(), [Panes.pane()], non_neg_integer(), pos_integer(), term()) ::
          map()
  def with_query(pane, panes, index, limit \\ Rows.page(), sort \\ nil)

  def with_query(%{kind: :list} = pane, panes, index, limit, sort),
    do: Map.put(pane, :query, Rows.query(panes, index, limit, sort))

  def with_query(pane, _panes, _index, _limit, _sort), do: pane

  # Test seam: `config :barkpark, #{inspect(__MODULE__)}, reader: fun` swaps the
  # read, so a test can hold it or fail it. Unset everywhere else.
  defp reader, do: Application.get_env(:barkpark, __MODULE__, [])[:reader] || (&read/5)

  defp node_entries(node) do
    for item <- Tree.rows(node) do
      case item do
        %{type: :divider, title: title} when is_binary(title) -> {:divider, title}
        %{type: :divider} -> :divider
        _ -> %{title: item.title || item.id, next: Tree.opens(item)}
      end
    end
  end

  @doc false
  def read(%{kind: :list, type: type, search: q}, node, dataset, scope, provisional)
      when is_binary(q),
      do: ListSearch.read(type, q, node, dataset, scope, provisional)

  def read(%{kind: :list, type: type} = pane, node, dataset, scope, provisional) do
    rows = pane[:query] && Rows.read(type, pane.query, dataset, scope, node)

    case rows || Content.resolve_schema(type, dataset, scope) do
      %{entries: entries} ->
        note =
          cond do
            is_binary(rows.refused) -> rows.refused
            rows.refused -> gettext("This list's filter could not be read.")
            entries == [] -> gettext("No documents here yet.")
            true -> nil
          end

        rows |> Map.put(:note, note) |> Map.put(:title, rows.title || provisional)

      {:ok, schema} ->
        title = if node, do: provisional, else: schema.title || type

        list(schema, node, dataset, scope)
        |> Map.put(:title, title)
        |> Map.put(:creatable, PaneBuilder.author_creatable?(schema))
        |> Map.put(:type_title, schema.title)

      _ ->
        note = gettext("There is no document type named “%{type}” here.", type: type)
        %{title: provisional, note: note}
    end
  end

  def read(%{kind: :doc, id: id, type: type} = pane, _node, dataset, scope, provisional) do
    # A followed document with no `type=` in the URL: its type is looked up.
    type = (pane[:untyped] && Refs.type_of(id, dataset, scope)) || type

    with {:ok, schema} <- Content.resolve_schema(type, dataset, scope),
         {%{} = doc, draft?, _published?} <-
           Content.fetch_doc_with_draft(type, id, dataset, scope) do
      status = if draft?, do: gettext("Draft"), else: gettext("Published")

      %{
        title: doc_title(doc, schema),
        fields: [
          %{title: gettext("Status"), value: status} | fields(doc, schema, dataset, scope)
        ]
      }
    else
      _ ->
        note = gettext("No document “%{id}” of type “%{type}” was found.", id: id, type: type)
        %{title: provisional, note: note}
    end
  end

  defp list(schema, node, dataset, scope) do
    opts =
      [
        perspective: :drafts,
        limit: @page,
        filter_map: Structure.parse_filter(node && node.filter),
        content_keys: [TitleDerivation.preview_title_field(schema) || "title"]
      ] ++ scope

    {docs, more?} = Content.list_documents_page(schema.name, dataset, opts)

    entries =
      for doc <- docs do
        next = %{kind: :doc, id: Content.published_id(doc.doc_id), type: schema.name}
        %{title: doc_title(doc, schema), next: next}
      end

    note =
      cond do
        entries == [] -> gettext("No documents here yet.")
        more? -> gettext("Showing the first %{count}.", count: @page)
        true -> nil
      end

    %{entries: entries, note: note}
  rescue
    # A desk filter the query layer refuses is this pane's to state.
    e in Barkpark.Content.InvalidFilterError -> %{entries: [], note: Exception.message(e)}
  end

  # ── a document, read-only ──────────────────────────────────────────────────

  defp doc_title(doc, schema) do
    presence(doc.title) || TitleDerivation.preview_title(doc, schema) ||
      Content.published_id(doc.doc_id)
  end

  defp fields(doc, schema, dataset, scope) do
    refs = Refs.resolve(doc, schema, dataset, scope)

    for %{"name" => name} = field <- schema.fields || [] do
      title = field["title"] || name

      case refs do
        %{^name => targets} ->
          %{title: title, refs: targets, path: name}

        _ ->
          value = if name == "title", do: doc.title, else: (doc.content || %{})[name]
          %{title: title, value: show(value)}
      end
    end
  end

  defp show(nil), do: "—"
  defp show(""), do: "—"
  defp show(value) when is_binary(value), do: value
  defp show(value) when is_number(value) or is_boolean(value), do: to_string(value)

  defp show(value) do
    json = Jason.encode!(value, pretty: true)
    if String.length(json) > 600, do: String.slice(json, 0, 600) <> " …", else: json
  end

  defp presence(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp presence(_value), do: nil
end
