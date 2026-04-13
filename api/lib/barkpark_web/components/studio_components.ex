defmodule BarkparkWeb.StudioComponents do
  @moduledoc "Reusable components for the Barkpark Studio."
  use Phoenix.Component

  attr :status, :string, required: true
  def status_badge(assigns) do
    ~H"""
    <span class={"status status-#{@status}"}>
      <span class="status-dot"></span>
      <%= @status %>
    </span>
    """
  end

  attr :schema, :map, required: true
  def schema_card(assigns) do
    ~H"""
    <a href={"/studio/#{@schema.name}"} class="schema-card">
      <div class="schema-icon"><%= @schema.icon %></div>
      <div class="schema-name"><%= @schema.title %></div>
      <span class={"badge badge-#{@schema.visibility}"}><%= @schema.visibility %></span>
    </a>
    """
  end
end
