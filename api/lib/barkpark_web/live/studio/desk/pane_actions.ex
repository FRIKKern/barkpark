defmodule BarkparkWeb.Studio.Desk.PaneActions do
  @moduledoc """
  A document pane's own controls on the desk slice (J26), in the TanStack
  Studio's names so its e2e specs find them (`DocumentPane.tsx`,
  `Structure.tsx` in barkpark-studio):

    * "Split pane right": a link to `Panes.split_right/3`, the same
      document again beside it (`…;post-26|,`).
    * "Close split pane": on a side of a split, a button that patches to
      `Panes.close_split/3`. Like Sanity's, closing one side of a split is a
      button, closing a pane a link.
    * "Enter focus mode (hide navigation)" and "Exit focus mode (show
      navigation)": one button, whose press `DeskLive` keeps (`desk-focus`).
      It is the same element in both states, so the keyboard focus a press
      gave it stays on it.
    * In focus mode the title line is a breadcrumb: a button for each pane
      it hides, which goes to that pane's URL (and so ends focus mode).

  Pure function components: the pane hands over its chain, its index, the
  desk's base path and the page's focus mode (`nil`, or the focused index
  and its crumbs, `DeskLive.focus_view/1`).
  """

  use BarkparkWeb, :html

  alias BarkparkWeb.Studio.Desk.Panes
  alias Phoenix.LiveView.JS

  attr :chain, :list, required: true
  attr :index, :integer, required: true
  attr :base, :string, required: true

  attr :focus, :map,
    default: nil,
    doc: "nil, or %{index: focused index, crumbs: [%{title, href}]}"

  @doc """
  The controls, as two children of the pane's header row: the breadcrumb
  (drawn before the title, `order: -1`) and the buttons (pushed to the end).
  """
  def doc(assigns) do
    assigns =
      assign(assigns,
        on?: is_map(assigns.focus) and assigns.focus.index == assigns.index,
        split?: Panes.split?(assigns.chain, assigns.index)
      )

    ~H"""
    <nav
      :if={@on?}
      class="focus-crumbs"
      aria-label={gettext("Breadcrumb")}
      style="order: -1; display: flex; align-items: center; gap: 4px; min-width: 0; margin-right: 4px"
    >
      <%= for crumb <- @focus.crumbs do %>
        <button type="button" class="crumb btn btn-ghost btn-sm" phx-click={JS.patch(crumb.href)}>
          {crumb.title}
        </button>
        <span aria-hidden="true">/</span>
      <% end %>
    </nav>
    <span
      class="dk-pane-actions"
      style="margin-left: auto; display: flex; align-items: center; gap: 2px; flex: none"
    >
      <.link
        patch={Panes.split_right(@chain, @index, @base)}
        class="btn btn-ghost btn-sm btn-icon"
        aria-label={gettext("Split pane right")}
        title={gettext("Split pane right")}
      >
        <.glyph d="M10.5 5.5V19.5M13 12.5H15.5M18 12.5H15.5M15.5 12.5V15M15.5 12.5V10M4.5 5.5H20.5V19.5H4.5V5.5Z" />
      </.link>
      <button
        type="button"
        id={"desk-focus-#{@index}"}
        class="btn btn-ghost btn-sm btn-icon"
        aria-label={
          if @on?,
            do: gettext("Exit focus mode (show navigation)"),
            else: gettext("Enter focus mode (hide navigation)")
        }
        title={if @on?, do: gettext("Exit focus mode"), else: gettext("Enter focus mode")}
        aria-pressed={to_string(@on?)}
        phx-click={JS.push("desk-focus", value: %{index: @index}) |> JS.focus()}
      >
        <.glyph :if={!@on?} d="M14 6.5H18.5V11M11 18.5H6.5V14M18.5 6.5L14 11M6.5 18.5L11 14" />
        <.glyph :if={@on?} d="M6 14.5L10.5 14.5V19M19 10.5H14.5L14.5 6M10.5 14.5L6 19M14.5 10.5L19 6" />
      </button>
      <button
        :if={@split?}
        type="button"
        class="btn btn-ghost btn-sm btn-icon"
        aria-label={gettext("Close split pane")}
        title={gettext("Close split pane")}
        phx-click={JS.patch(Panes.close_split(@chain, @index, @base))}
      >
        <.glyph d="M18 7L7 18M7 7L18 18" />
      </button>
    </span>
    """
  end

  @doc """
  Focus mode puts a pane away rather than closing it: it stays mounted (a
  list keeps its rows, its sort and its page), out of sight and out of
  `#desk-panes > [data-pane-index]`, the panes `bp-desk.js` lays out.
  """
  attr :hidden, :boolean, required: true
  slot :inner_block, required: true

  def put_away(%{hidden: true} = assigns) do
    ~H"""
    <div hidden data-desk-put-away>{render_slot(@inner_block)}</div>
    """
  end

  def put_away(assigns) do
    ~H"""
    {render_slot(@inner_block)}
    """
  end

  # Sanity's icons, as the TanStack Studio draws them (`icons.tsx`).
  attr :d, :string, required: true

  defp glyph(assigns) do
    ~H"""
    <svg
      width="25"
      height="25"
      viewBox="0 0 25 25"
      fill="none"
      stroke="currentColor"
      stroke-width="1.2"
      stroke-linejoin="round"
      aria-hidden="true"
    >
      <path d={@d} />
    </svg>
    """
  end
end
