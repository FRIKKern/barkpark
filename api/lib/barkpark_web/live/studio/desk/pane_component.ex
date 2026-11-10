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
  alias BarkparkWeb.Studio.Desk.Panes
  alias BarkparkWeb.Studio.Desk.Refs
  alias BarkparkWeb.Studio.Desk.Rows
  alias BarkparkWeb.Studio.Desk.Tree
  alias Phoenix.LiveView.AsyncResult

  @page 100

  # The page says this pane's data changed under it (someone saved): read
  # again, keeping what is on screen until the new read lands.
  @impl true
  def update(%{refresh: _}, socket), do: {:ok, load(socket)}

  def update(assigns, socket) do
    socket =
      socket
      |> assign(Map.take(assigns, ~w(id pane index panes base dataset scope node)a))
      |> assign_new(:limit, fn -> Rows.page() end)
      |> assign_new(:sort, fn -> nil end)

    key = data_key(assigns.pane, assigns.dataset, assigns.node)
    same? = socket.assigns[:data_key] == key
    # `loading` is nil once the read has landed, so `&&`, not `and`.
    waiting? = same? && socket.assigns.data.loading
    warm = assigns[:warm]

    cond do
      # What a hover already read: the pane opens with its data.
      warm && (waiting? || not same?) ->
        {:ok, socket |> assign(:data_key, key) |> cancel_async(:load) |> adopt(warm)}

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
  click when a row is hovered (`source: :warm`).
  """
  @spec read_pane(Panes.pane(), struct() | nil, String.t(), keyword(), :pane | :warm) :: map()
  def read_pane(pane, node, dataset, scope, source \\ :pane) do
    meta = %{kind: pane.kind, key: data_key(pane, dataset, node), source: source}
    :telemetry.execute([:barkpark, :desk, :pane_load], %{count: 1}, meta)
    reader().(pane, node, dataset, scope, provisional_title(pane, node))
  end

  @impl true
  def handle_event("retry", _params, socket), do: {:noreply, load(socket)}

  # A list's own controls. They are this pane's state, not the URL's.
  def handle_event("more", _params, socket),
    do: {:noreply, socket |> assign(:limit, socket.assigns.limit + Rows.page()) |> load()}

  def handle_event("sort", %{"sort" => name}, socket),
    do: {:noreply, socket |> assign(:sort, if(name == "", do: nil, else: name)) |> load()}

  @impl true
  def handle_async(:load, {:ok, data}, socket), do: {:noreply, adopt(socket, data)}

  def handle_async(:load, {:exit, reason}, socket),
    do: {:noreply, assign(socket, :data, AsyncResult.failed(socket.assigns.data, reason))}

  defp adopt(socket, data) do
    # The tab title follows the last pane; only the page can set it.
    send(self(), {:desk_pane_title, socket.assigns.index, data.title})
    assign(socket, :data, AsyncResult.ok(data))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section
      id={@id}
      class={["pane-column", "dk-pane", "pane", to_string(@pane.kind), @pane.kind == :doc && "dk-doc"]}
      data-pane-index={@index}
      data-pane-kind={@pane.kind}
      aria-label={title(assigns)}
      aria-busy={@data.loading && "true"}
    >
      <div class="pane-header">
        <span class="pane-header-title">{title(assigns)}</span>
        <.link
          :if={@index > 0}
          patch={Panes.close_from(@panes, @index, @base)}
          class="dk-close"
          aria-label={gettext("Close %{title}", title: title(assigns))}
        >
          <span aria-hidden="true">×</span>
        </.link>
      </div>
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
          <form
            :if={(@data.result[:sorts] || []) != []}
            class="dk-sort"
            phx-change="sort"
            phx-target={@myself}
          >
            <label for={@id <> "-sort"}>{gettext("Sort by")}</label>
            <select id={@id <> "-sort"} name="sort" class="form-input">
              <option value="">{gettext("Default")}</option>
              <option
                :for={sort <- @data.result.sorts}
                value={sort.name}
                selected={sort.name == @data.result[:sort]}
              >
                {sort.title}
              </option>
            </select>
          </form>
          <p :if={@data.result[:note]} class="dk-note">{@data.result.note}</p>
          <%!-- The TanStack Studio's names (ruling R1): a document list is a
               `role="list"` named after its pane, each row a `listitem` that
               knows its place; the link inside stays the thing with focus. --%>
          <div
            :if={(@data.result[:entries] || []) != []}
            class="dk-rows"
            role={@pane.kind == :list && "list"}
            aria-label={@pane.kind == :list && title(assigns)}
          >
            <%= for {entry, pos} <- placed(@data.result.entries) do %>
              <div :if={entry == :divider} class="pane-divider"></div>
              <div
                :if={is_map(entry)}
                class="dk-row"
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
              <span class="pane-item-label">
                {entry.title}
                <span :if={entry[:sub]} class="dk-row-sub">{entry.sub}</span>
              </span>
              <span :if={entry[:draft]} class="dk-draft" title={gettext("Draft")}>
                <span aria-hidden="true">○</span>
                <span class="sr-only">{gettext("Draft")}</span>
              </span>
              <span :if={entry.next.kind != :doc} class="pane-item-chevron" aria-hidden="true">
                ›
              </span>
                </.link>
              </div>
            <% end %>
          </div>
          <button
            :if={@data.result[:more?]}
            type="button"
            class="btn dk-more"
            phx-click="more"
            phx-target={@myself}
            disabled={@data.loading}
          >
            {gettext("Show more")}
          </button>
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
        entry, pos -> {{entry, pos}, pos + 1}
      end)

    placed
  end

  defp same?(%{kind: :doc, id: id}, %{kind: :doc, id: id}), do: true
  defp same?(%{kind: kind, node: node}, %{kind: kind, node: node}) when kind != :doc, do: true
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

  defp load(socket) do
    %{pane: pane, node: node, dataset: dataset, scope: scope} = socket.assigns
    %{panes: panes, index: index, limit: limit, sort: sort} = socket.assigns
    pane = with_query(pane, panes, index, limit, sort)

    # A list asked for more rows or another order keeps its rows on screen.
    socket
    |> assign(:data, AsyncResult.loading(socket.assigns[:data] || AsyncResult.loading()))
    |> start_async(:load, fn -> read_pane(pane, node, dataset, scope) end)
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
      if item.type == :divider,
        do: :divider,
        else: %{title: item.title || item.id, next: Tree.opens(item)}
    end
  end

  @doc false
  def read(%{kind: :list, type: type} = pane, node, dataset, scope, provisional) do
    rows = pane[:query] && Rows.read(type, pane.query, dataset, scope)

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
        Map.put(list(schema, node, dataset, scope), :title, title)

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
