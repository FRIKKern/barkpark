defmodule SanityApiWeb.Studio.DocumentListLive do
  use SanityApiWeb, :live_view

  alias SanityApi.Content

  @dataset "production"

  @impl true
  def mount(%{"type" => type}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(SanityApi.PubSub, "documents:#{@dataset}")
    end

    schema = case Content.get_schema(type, @dataset) do
      {:ok, s} -> s
      _ -> nil
    end

    socket =
      socket
      |> assign(type: type, schema: schema, perspective: :drafts)
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
    perspective = String.to_existing_atom(p)
    {:noreply, socket |> assign(perspective: perspective) |> load_documents()}
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
    docs = Content.list_documents(socket.assigns.type, @dataset, perspective: socket.assigns.perspective)
    assign(socket, documents: docs)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="main-header" style="margin: -24px -24px 24px; padding: 0 24px;">
      <div class="main-header-left">
        <h1 class="h1">
          <%= if @schema, do: "#{@schema.icon} #{@schema.title}", else: @type %>
        </h1>
        <span class="text-sm text-muted"><%= length(@documents) %> documents</span>
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
        <button class="btn btn-primary btn-sm" phx-click="new-document">+ New document</button>
      </div>
    </div>

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
            data-confirm="Delete this document and all its versions?"
          >Delete</button>
        </div>
      <% end %>
      <%= if @documents == [] do %>
        <div class="empty-state">
          <div class="empty-state-icon">&#128196;</div>
          <div class="empty-state-text">No documents yet</div>
          <button class="btn btn-primary" phx-click="new-document">Create your first document</button>
        </div>
      <% end %>
    </div>
    """
  end
end
