defmodule BarkparkWeb.Studio.DashboardLive do
  use BarkparkWeb, :live_view

  alias Barkpark.{Content, Structure}

  @impl true
  def mount(params, _session, socket) do
    dataset = params["dataset"] || "production"

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Barkpark.PubSub, "documents:#{dataset}")
    end

    structure = Structure.build(dataset)
    counts = build_counts(structure, dataset)

    {:ok,
     assign(socket,
       structure: structure,
       counts: counts,
       page_title: "Structure",
       dataset: dataset
     )}
  end

  @impl true
  def handle_info({:document_changed, _}, socket) do
    counts = build_counts(socket.assigns.structure, socket.assigns.dataset)
    {:noreply, assign(socket, counts: counts)}
  end

  defp build_counts(structure, dataset) do
    structure.items
    |> Enum.filter(& &1.type_name)
    |> Enum.map(fn node ->
      count = length(Content.list_documents(node.type_name, dataset, perspective: :drafts))
      {node.type_name, count}
    end)
    |> Map.new()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div style="margin-bottom: 24px;">
      <h1 class="h1">Structure</h1>
      <p class="text-sm text-muted" style="margin-top: 4px;">Content types and settings</p>
    </div>

    <div class="card">
      <%= for node <- @structure.items do %>
        <%= render_node(assigns, node) %>
      <% end %>
    </div>
    """
  end

  defp render_node(assigns, %{type: :divider}) do
    ~H"""
    <div style="border-top: 1px solid var(--border-muted);"></div>
    """
  end

  defp render_node(assigns, %{type: :list} = node) do
    assigns = assign(assigns, node: node)

    ~H"""
    <div style="padding: 8px 0;">
      <div style="padding: 8px 20px;">
        <span class="text-xs text-dim" style="text-transform: uppercase; letter-spacing: 0.06em; font-weight: 600;">
          <%= @node.icon %> <%= @node.title %>
        </span>
      </div>
      <%= for child <- @node.items do %>
        <%= render_node(assigns, child) %>
      <% end %>
    </div>
    """
  end

  defp render_node(assigns, %{type: type} = node) when type in [:document_type_list, :document] do
    count = Map.get(assigns.counts, node.type_name, 0)
    assigns = assign(assigns, node: node, count: count)

    ~H"""
    <a href={"/studio/#{@node.type_name}"} class="doc-list-item" style="padding: 10px 20px;">
      <span style="font-size: 20px; width: 28px; text-align: center;"><%= @node.icon %></span>
      <div style="flex: 1;">
        <div class="doc-title"><%= @node.title %></div>
        <div class="doc-meta">
          <%= if @node.type == :document, do: "Singleton", else: "#{@count} documents" %>
        </div>
      </div>
      <span style="color: var(--fg-dim); font-size: 18px;">&#8250;</span>
    </a>
    """
  end

  defp render_node(_, _), do: ""
end
