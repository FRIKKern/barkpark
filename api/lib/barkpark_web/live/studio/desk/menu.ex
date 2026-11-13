defmodule BarkparkWeb.Studio.Desk.Menu do
  @moduledoc """
  The desk's menu look, one for all three popover menus (a list's "List
  options", the edit pane's "Show document actions" and "Share document"):
  the TanStack Studio's `.popover.menu` (barkpark-studio
  `app/src/styles.css`, `.popover.menu`, `.menu-item`, `.menu-icon-text`).
  Each menu's popover carries `class="dk-menu"`; `Style` draws it.

  An item is a button with its words and, after them in the markup, a 21 px
  icon from `BarkparkWeb.Icons.desk_icon/1` (Barkpark's own glyph of that
  name, else the vendored Sanity one that TanStack draws). The style puts the
  icon first; in the markup the words come first, so an item's text is its
  label. A radio item in use carries a check (`aria-checked`, drawn by the
  style). Nothing here opens, closes or moves the focus: the popover and
  `bp-desk.js` do, as before.
  """
  use Phoenix.Component

  attr :icon, :string, default: nil, doc: "a `desk_icon/1` name; nil draws none"
  attr :danger, :boolean, default: false, doc: "a destructive action, in the menu's red"
  attr :class, :string, default: nil

  attr :rest, :global,
    include: ~w(popovertarget popovertargetaction disabled),
    doc: "role, aria-checked, phx-click and the rest, as the menu gives them"

  slot :inner_block, required: true

  @doc "One menu item: its words, then its icon."
  def item(assigns) do
    ~H"""
    <button type="button" class={["dk-menu-item", @danger && "danger", @class]} {@rest}>{render_slot(@inner_block)}<.glyph :if={@icon} name={@icon} /></button>
    """
  end

  attr :name, :string, required: true

  defp glyph(assigns) do
    ~H"""
    <span class="dk-menu-icon" aria-hidden="true"><BarkparkWeb.Icons.desk_icon name={@name} size={21} /></span>
    """
  end

  slot :inner_block, required: true

  @doc "A group's small label (TanStack's \"Actions\")."
  def label(assigns) do
    ~H"""
    <div class="menu-label dk-menu-label">{render_slot(@inner_block)}</div>
    """
  end

  @doc "The line between two groups."
  def separator(assigns) do
    ~H"""
    <hr class="dk-menu-sep" />
    """
  end
end
