defmodule BarkparkWeb.Studio.DocumentListLive do
  use BarkparkWeb, :live_view

  alias Barkpark.{Content, Structure}

  @dataset "production"

  @impl true
  def mount(%{"type" => type}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Barkpark.PubSub, "documents:#{@dataset}")
    end

    schema = case Content.get_schema(type, @dataset) do
      {:ok, s} -> s
      _ -> nil
    end

    type_node = Structure.type_node(type, @dataset)

    socket =
      socket
      |> assign(
        type: type,
        schema: schema,
        type_node: type_node,
        perspective: :drafts,
        active_filter: nil
      )
      |> assign(page_title: (schema && schema.title) || type)
      |> load_documents()

    {:ok, socket}
  end

  @impl true
  def handle_info({:document_changed, %{type: type}}, socket) do
    if type == socket.assigns.type do
      {:noreply, load_documents(socket)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("set-perspective", %{"perspective" => p}, socket) do
    {:noreply, socket |> assign(perspective: String.to_existing_atom(p)) |> load_documents()}
  end

  def handle_event("set-filter", %{"filter" => filter}, socket) do
    f = if filter == "", do: nil, else: filter
    {:noreply, socket |> assign(active_filter: f) |> load_documents()}
  end

  def handle_event("new-document", _params, socket) do
    type = socket.assigns.type
    id = "#{type}-#{:rand.uniform(999_999)}"

    case Content.create_document(type, %{"doc_id" => id, "title" => "Untitled"}, @dataset) do
      {:ok, doc} ->
        {:noreply, push_navigate(socket, to: "/studio/#{type}/#{Content.published_id(doc.doc_id)}")}
      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to create document")}
    end
  end

  def handle_event("delete-doc", %{"id" => doc_id, "type" => type}, socket) do
    Content.delete_document(doc_id, type, @dataset)
    {:noreply, load_documents(socket)}
  end

  defp load_documents(socket) do
    opts = [perspective: socket.assigns.perspective]
    opts = if socket.assigns.active_filter, do: opts ++ [filter_map: parse_filter_string(socket.assigns.active_filter)], else: opts
    docs = Content.list_documents(socket.assigns.type, @dataset, opts)
    assign(socket, documents: docs)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="main-header" style="margin: -24px -24px 0; padding: 0 24px;">
      <div class="main-header-left">
        <a href="/studio" class="btn btn-ghost btn-sm">&larr;</a>
        <h1 class="h1">
          <%= if @schema, do: "#{@schema.icon} #{@schema.title}", else: @type %>
        </h1>
        <span class="text-sm text-muted"><%= length(@documents) %></span>
      </div>
      <div class="main-header-right">
        <div class="perspective-tabs">
          <%= for p <- [:published, :drafts, :raw] do %>
            <button
              class={"perspective-tab #{if @perspective == p, do: "active"}"}
              phx-click="set-perspective"
              phx-value-perspective={p}
            ><%= p %></button>
          <% end %>
        </div>
        <div class="toolbar-sep"></div>
        <button class="btn btn-primary btn-sm" phx-click="new-document">+ New</button>
      </div>
    </div>

    <div style="display: flex; gap: 16px; margin-top: 16px;">
      <!-- Sub-navigation (like TUI's pane drill-down) -->
      <%= if @type_node && length(@type_node.items) > 1 do %>
        <div style="width: 200px; flex-shrink: 0;">
          <div class="card">
            <%= for node <- @type_node.items do %>
              <%= if node.type == :divider do %>
                <div style="border-top: 1px solid var(--border-muted);"></div>
              <% else %>
                <button
                  class={"doc-list-item #{if match_filter?(node.filter, @active_filter), do: "active"}"}
                  phx-click="set-filter"
                  phx-value-filter={node.filter || ""}
                  style={"padding: 8px 14px; width: 100%; text-align: left; border: none; background: #{if match_filter?(node.filter, @active_filter), do: "var(--bg-accent)", else: "transparent"}; cursor: pointer;"}
                >
                  <span style="font-size: 12px; width: 16px;"><%= node.icon %></span>
                  <span class="text-sm"><%= node.title %></span>
                </button>
              <% end %>
            <% end %>
          </div>
        </div>
      <% end %>

      <!-- Document list -->
      <div style="flex: 1;">
        <div class="card">
          <%= for doc <- @documents do %>
            <div class="doc-list-item">
              <a href={"/studio/#{@type}/#{Content.published_id(doc.doc_id)}"}>
                <span class={"badge badge-#{if Content.draft?(doc.doc_id), do: "draft", else: doc.status}"}>
                  <%= if Content.draft?(doc.doc_id), do: "draft", else: doc.status %>
                </span>
                <div>
                  <div class="doc-title"><%= doc.title || "Untitled" %></div>
                  <div class="doc-id"><%= doc.doc_id %></div>
                </div>
              </a>
              <button
                class="btn btn-destructive btn-sm"
                phx-click="delete-doc"
                phx-value-id={Content.published_id(doc.doc_id)}
                phx-value-type={@type}
                data-confirm="Delete this document?"
              >Delete</button>
            </div>
          <% end %>
          <%= if @documents == [] do %>
            <div class="empty-state">
              <div class="empty-state-icon">&#128196;</div>
              <div class="empty-state-text">No documents found</div>
              <button class="btn btn-primary" phx-click="new-document">Create document</button>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp match_filter?(nil, nil), do: true
  defp match_filter?(node_filter, active_filter), do: node_filter == active_filter

  # Parse a "field=value" filter string into a map for list_documents/3 :filter_map.
  defp parse_filter_string(nil), do: %{}
  defp parse_filter_string(""), do: %{}
  defp parse_filter_string(s) do
    case String.split(s, "=", parts: 2) do
      [field, value] -> %{field => value}
      _ -> %{}
    end
  end
end
