defmodule SanityApiWeb.Studio.DashboardLive do
  use SanityApiWeb, :live_view

  alias SanityApi.Content

  @dataset "production"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(SanityApi.PubSub, "documents:#{@dataset}")
    end

    schemas = Content.list_schemas(@dataset)

    schema_counts =
      Enum.map(schemas, fn s ->
        count = length(Content.list_documents(s.name, @dataset, perspective: :drafts))
        {s.name, count}
      end)
      |> Map.new()

    {:ok, assign(socket, schemas: schemas, counts: schema_counts, page_title: "Dashboard")}
  end

  @impl true
  def handle_info({:document_changed, _}, socket) do
    counts =
      Enum.map(socket.assigns.schemas, fn s ->
        count = length(Content.list_documents(s.name, @dataset, perspective: :drafts))
        {s.name, count}
      end)
      |> Map.new()

    {:noreply, assign(socket, counts: counts)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="page-header">
      <div>
        <h1 class="page-title">Dashboard</h1>
        <p class="page-subtitle">Manage your content</p>
      </div>
    </div>

    <div class="schema-grid">
      <%= for schema <- @schemas do %>
        <a href={"/studio/#{schema.name}"} class="schema-card">
          <div class="schema-icon"><%= schema.icon %></div>
          <div class="schema-name"><%= schema.title %></div>
          <div style="display:flex; gap:8px; align-items:center; margin-top:4px;">
            <span class={"badge badge-#{schema.visibility}"}><%= schema.visibility %></span>
            <span style="color:var(--text-dim); font-size:13px;"><%= Map.get(@counts, schema.name, 0) %> docs</span>
          </div>
        </a>
      <% end %>
    </div>
    """
  end
end
