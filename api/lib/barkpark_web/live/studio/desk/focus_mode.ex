defmodule BarkparkWeb.Studio.Desk.FocusMode do
  @moduledoc """
  J26, Sanity's focus mode: the document pane's header button hides the
  navigation (every other pane) so the document has the whole width, and the
  pane's title line becomes a breadcrumb of the panes it hides.

  The page keeps it, as the TanStack Studio's pane area does (its
  `Structure.tsx` state, not the URL and not a preference): a reload or any
  navigation shows the panes again. The hidden panes stay in the page, so
  leaving is instant; `bp-desk.js` lays out the focused pane alone.

  `DeskLive` holds the focused pane's index in `:desk_focus`; the edit pane
  (`EditorHost.pane/2`) draws the button and the breadcrumb from here.
  """
  use Phoenix.Component
  use Gettext, backend: BarkparkWeb.Gettext

  alias BarkparkWeb.Studio.Desk.Panes
  alias Phoenix.LiveView.JS

  @doc """
  The focus kept after a navigation: none. Focus mode is for the panes it was
  turned on over; the same splat (a patch that changes nothing) keeps it.
  """
  def follow(socket, splat) do
    keep = socket.assigns[:desk_focus_splat] == splat

    Phoenix.Component.assign(socket,
      desk_focus: if(keep, do: socket.assigns[:desk_focus]),
      desk_focus_splat: splat
    )
  end

  @doc """
  The button's click: the pane at `index` alone, or the panes back. Only the
  edit pane has the button, so any other index is refused.
  """
  def toggle(socket, index) do
    case Integer.parse(to_string(index)) do
      {i, ""} when i == socket.assigns.active ->
        focus = if socket.assigns[:desk_focus] == i, do: nil, else: i
        Phoenix.Component.assign(socket, :desk_focus, focus)

      _ ->
        socket
    end
  end

  attr :id, :string, required: true
  attr :index, :integer, required: true
  attr :on, :boolean, required: true

  @doc """
  Sanity's "Enter focus mode (hide navigation)", and the way out. One button
  by one id either way, so the browser keeps the focus on it.
  """
  def button(assigns) do
    ~H"""
    <button
      type="button"
      id={@id}
      class="dk-split dk-focus icon-btn"
      phx-click="desk-focus"
      phx-value-index={@index}
      aria-pressed={to_string(@on)}
      aria-label={
        if @on,
          do: gettext("Exit focus mode (show navigation)"),
          else: gettext("Enter focus mode (hide navigation)")
      }
      data-tip={if @on, do: gettext("Exit focus mode"), else: gettext("Enter focus mode")}
    >
      <%!-- Sanity's CollapseIcon and ExpandIcon. --%>
      <svg width="14" height="14" viewBox="0 0 25 25" fill="none" stroke="currentColor"
        stroke-width="1.6" stroke-linejoin="round" aria-hidden="true">
        <%= if @on do %>
          <path d="M6 14.5L10.5 14.5V19M19 10.5H14.5L14.5 6" />
          <path d="M10.5 14.5L6 19M14.5 10.5L19 6" />
        <% else %>
          <path d="M14 6.5H18.5V11M11 18.5H6.5V14" />
          <path d="M18.5 6.5L14 11M6.5 18.5L11 14" />
        <% end %>
      </svg>
    </button>
    """
  end

  attr :views, :list, required: true, doc: "the page's panes, in chain order"
  attr :titles, :map, required: true, doc: "the titles the panes read, by pane id"
  attr :index, :integer, required: true
  attr :chain, :list, required: true
  attr :base, :string, required: true
  attr :title, :string, required: true, doc: "this document's title"

  @doc """
  The title line in focus mode: each hidden pane a crumb that opens it (which
  ends focus mode), then this document.
  """
  def crumbs(assigns) do
    ~H"""
    <nav class="dk-focus-crumbs" aria-label={gettext("Breadcrumb")}>
      <%= for view <- Enum.take(@views, @index) do %>
        <button
          type="button"
          class="dk-crumb"
          phx-click={JS.patch(Panes.to_path(Enum.take(@chain, view.index + 1), @base))}
        >
          {@titles[view.id] || view.title}
        </button>
        <span aria-hidden="true">/</span>
      <% end %>
      <span class="dk-crumb current" aria-current="page">{@title}</span>
    </nav>
    """
  end
end
