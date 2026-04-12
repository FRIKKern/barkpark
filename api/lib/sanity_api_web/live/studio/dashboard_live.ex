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
    counts =
      Enum.map(schemas, fn s ->
        {s.name, length(Content.list_documents(s.name, @dataset, perspective: :drafts))}
      end)
      |> Map.new()

    {:ok, assign(socket, schemas: schemas, counts: counts, page_title: "Dashboard")}
  end

  @impl true
  def handle_info({:document_changed, _}, socket) do
    counts =
      Enum.map(socket.assigns.schemas, fn s ->
        {s.name, length(Content.list_documents(s.name, @dataset, perspective: :drafts))}
      end)
      |> Map.new()

    {:noreply, assign(socket, counts: counts)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div style="margin-bottom: 32px;">
      <h1 class="h1">Dashboard</h1>
      <p class="text-sm text-muted" style="margin-top: 4px;">Manage your content and settings</p>
    </div>

    <div class="schema-grid">
      <%= for schema <- @schemas do %>
        <a href={"/studio/#{schema.name}"} class="schema-card">
          <div class="schema-card-icon"><%= schema.icon %></div>
          <div class="schema-card-name"><%= schema.title %></div>
          <div class="schema-card-meta">
            <span class={"badge badge-#{schema.visibility}"}><%= schema.visibility %></span>
            <span class="text-xs text-muted"><%= Map.get(@counts, schema.name, 0) %> documents</span>
          </div>
        </a>
      <% end %>
    </div>
    """
  end
end
