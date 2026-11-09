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
  alias BarkparkWeb.Studio.Desk.Tree
  alias Phoenix.LiveView.AsyncResult

  @page 100

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, Map.take(assigns, ~w(id pane index panes base dataset scope node)a))
    key = {Panes.pane_key(assigns.pane), assigns.dataset, assigns.node && assigns.node.filter}

    if socket.assigns[:data_key] == key,
      do: {:ok, socket},
      else: {:ok, socket |> assign(:data_key, key) |> load()}
  end

  @impl true
  def handle_event("retry", _params, socket), do: {:noreply, load(socket)}

  @impl true
  def handle_async(:load, {:ok, data}, socket) do
    # The tab title follows the last pane; only the page can set it.
    send(self(), {:desk_pane_title, socket.assigns.index, data.title})
    {:noreply, assign(socket, :data, AsyncResult.ok(data))}
  end

  def handle_async(:load, {:exit, reason}, socket),
    do: {:noreply, assign(socket, :data, AsyncResult.failed(socket.assigns.data, reason))}

  @impl true
  def render(assigns) do
    ~H"""
    <section
      id={@id}
      class={["pane-column", "dk-pane", @pane.kind == :doc && "dk-doc"]}
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
      <div class="pane-body">
        <div :if={@data.loading} class="dk-skeleton" aria-hidden="true">
          <div :for={_ <- 1..6} class="pane-item"><span class="dk-bone"></span></div>
        </div>
        <div :if={@data.failed} class="dk-note" role="alert">
          <p>{gettext("This pane could not be read.")}</p>
          <button type="button" class="btn" phx-click="retry" phx-target={@myself}>
            {gettext("Retry")}
          </button>
        </div>
        <%= if @data.ok? do %>
          <p :if={@data.result[:note]} class="dk-note">{@data.result.note}</p>
          <%= for entry <- @data.result[:entries] || [] do %>
            <div :if={entry == :divider} class="pane-divider"></div>
            <div :if={is_map(entry) and is_nil(entry.next)} class="pane-item">
              <span class="pane-item-label">{entry.title}</span>
            </div>
            <.link
              :if={is_map(entry) and entry.next}
              patch={Panes.open_after(@panes, @index, entry.next, @base)}
              class={["pane-item", selected?(@panes, @index, entry.next) && "selected"]}
              aria-current={selected?(@panes, @index, entry.next) && "true"}
              data-desk-row
            >
              <span class="pane-item-label">{entry.title}</span>
              <span :if={entry.next.kind != :doc} class="pane-item-chevron" aria-hidden="true">
                ›
              </span>
            </.link>
          <% end %>
          <dl :if={@data.result[:fields]} class="dk-fields">
            <div :for={field <- @data.result.fields}>
              <dt>{field.title}</dt>
              <dd>{field.value}</dd>
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

  defp selected?(panes, index, next), do: same?(Enum.at(panes, index + 1), next)

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
    %{pane: pane, node: node, dataset: dataset, scope: scope, data_key: key} = socket.assigns
    provisional = provisional_title(pane, node)
    reader = reader()

    socket
    |> assign(:data, AsyncResult.loading())
    |> start_async(:load, fn ->
      :telemetry.execute([:barkpark, :desk, :pane_load], %{count: 1}, %{kind: pane.kind, key: key})

      reader.(pane, node, dataset, scope, provisional)
    end)
  end

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
  def read(%{kind: :list, type: type}, node, dataset, scope, provisional) do
    case Content.resolve_schema(type, dataset, scope) do
      {:ok, schema} ->
        title = if node, do: provisional, else: schema.title || type
        Map.put(list(schema, node, dataset, scope), :title, title)

      _ ->
        note = gettext("There is no document type named “%{type}” here.", type: type)
        %{title: provisional, note: note}
    end
  end

  def read(%{kind: :doc, id: id, type: type}, _node, dataset, scope, provisional) do
    with {:ok, schema} <- Content.resolve_schema(type, dataset, scope),
         {%{} = doc, draft?, _published?} <-
           Content.fetch_doc_with_draft(type, id, dataset, scope) do
      status = if draft?, do: gettext("Draft"), else: gettext("Published")

      %{
        title: doc_title(doc, schema),
        fields: [%{title: gettext("Status"), value: status} | fields(doc, schema)]
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

  defp fields(doc, schema) do
    for %{"name" => name} = field <- schema.fields || [] do
      value = if name == "title", do: doc.title, else: (doc.content || %{})[name]
      %{title: field["title"] || name, value: show(value)}
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
