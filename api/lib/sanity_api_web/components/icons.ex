defmodule SanityApiWeb.Icons do
  @moduledoc "Maps schema icons to Lucide icon names."

  use Phoenix.Component

  @icon_map %{
    "📄" => "file-text",
    "📑" => "file",
    "👤" => "user",
    "🏷" => "tag",
    "💼" => "briefcase",
    "⚙" => "settings",
    "🧭" => "compass",
    "🎨" => "palette",
    "📁" => "folder",
    "📂" => "folder-open",
    "🖼" => "image",
    "✅" => "check-circle",
    "📝" => "edit",
    "🔽" => "chevron-down",
    "#" => "hash",
    "●" => "circle",
    "○" => "circle-dot",
    "◆" => "diamond",
    "◇" => "diamond",
    "✓" => "check",
    "▪" => "square",
  }

  attr :name, :string, required: true
  attr :size, :integer, default: 16
  attr :class, :string, default: ""

  def lucide(assigns) do
    icon_name = Map.get(@icon_map, assigns.name, assigns.name)
    assigns = assign(assigns, icon_name: icon_name)
    ~H"""
    <i data-lucide={@icon_name} style={"width:#{@size}px;height:#{@size}px;"} class={@class}></i>
    """
  end

  def icon_name(emoji) do
    Map.get(@icon_map, emoji, "file")
  end
end
