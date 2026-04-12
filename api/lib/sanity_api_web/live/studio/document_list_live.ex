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
      |> assign(page_title: schema && schema.title || type)
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
    <div class="page-header">
      <div>
        <h1 class="page-title">
          <%= if @schema, do: "#{@schema.icon} #{@schema.title}", else: @type %>
        </h1>
        <p class="page-subtitle"><%= length(@documents) %> documents</p>
      </div>
      <div class="toolbar">
        <div class="toolbar" style="margin-right:12px;">
          <%= for p <- [:published, :drafts, :raw] do %>
            <button
              class={"btn btn-sm #{if @perspective == p, do: "btn-primary"}"}
              phx-click="set-perspective"
              phx-value-perspective={p}
            ><%= p %></button>
          <% end %>
        </div>
        <button class="btn btn-primary" phx-click="new-document">+ New</button>
      </div>
    </div>

    <div class="card">
      <ul class="doc-list">
        <%= for doc <- @documents do %>
          <li class="doc-item" style="justify-content:space-between;">
            <a href={"/studio/#{@type}/#{Content.published_id(doc.doc_id)}"} style="display:flex; align-items:center; gap:12px; flex:1; color:var(--text);">
              <.status_badge status={if Content.draft?(doc.doc_id), do: "draft", else: doc.status} />
              <div>
                <div class="doc-title"><%= doc.title || "Untitled" %></div>
                <div class="doc-meta"><%= doc.doc_id %></div>
              </div>
            </a>
            <button
              class="btn btn-sm btn-danger"
              phx-click="delete-doc"
              phx-value-id={Content.published_id(doc.doc_id)}
              phx-value-type={@type}
              data-confirm="Delete this document?"
            >Delete</button>
          </li>
        <% end %>
        <%= if @documents == [] do %>
          <li style="padding:32px; text-align:center; color:var(--text-dim);">
            No documents yet. Click "+ New" to create one.
          </li>
        <% end %>
      </ul>
    </div>
    """
  end
end
