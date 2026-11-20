defmodule BarkparkWeb.Studio.Desk.Navbar do
  @moduledoc """
  The Studio top bar's tabs on the desk, drawn as the TanStack Studio's navbar:
  four text tabs (Structure, Vision, Media, API) and every other tab in one
  "More" popover at the end of the bar.

  The tabs are the ones `BarkparkWeb.StudioComponents.Nav.top_menu_tabs/1`
  resolves for the old bar, the same list in the same order, so the nav-parity
  contract (one tab-label set on every Studio page) holds and every tab keeps
  `data-test-id="top-menu-tab"` and its name. Structure points at the desk
  itself. Vision (`Desk.Vision`, the query tool) is the desk's own, after
  Structure as in TanStack's bar; the old bar has no such tab, so it carries
  no `data-test-id`. A tab in the popover is a plain link: the popover is opened by its
  button, Tab moves from the button into it, Escape and a click outside close
  it (the browser's own popover).

  Under 900 px the bar has no room for the text tabs: they give way and the
  popover lists them first, as the TanStack Studio's bar puts its tools in its
  menu there (styles.css `@media (max-width: 899px)`). Those copies carry no
  `data-test-id`: the page's tab set stays one of each.

  The layout draws this only where `:desk_base` is set; every other page keeps
  `Nav.studio_tabs/1`.
  """
  use Phoenix.Component
  use Gettext, backend: BarkparkWeb.Gettext

  alias BarkparkWeb.Studio.StudioLive.Paths
  alias BarkparkWeb.StudioComponents.Nav

  attr :dataset, :string, required: true
  attr :desk_base, :string, required: true
  attr :scope_prefix, :string, default: ""
  attr :current_path, :string, default: nil
  attr :admin?, :boolean, default: false
  attr :ops?, :boolean, default: true
  attr :workspace_id, :string, default: nil

  def tabs(assigns) do
    {main, more} = split(assigns)
    assigns = assign(assigns, main: main, more: more)

    ~H"""
    <div class="studio-bar-tabs dk-nav" role="navigation" aria-label={gettext("Studio sections")}>
      <a
        :for={tab <- @main}
        href={tab.href}
        class={["studio-tab dk-nav-tab", tab.active && "active"]}
        aria-current={tab.active && "page"}
        data-test-id={tab.test_id}
      >{tab.label}</a>
      <button
        :if={@main != [] or @more != []}
        type="button"
        class="dk-nav-more"
        popovertarget="dk-nav-more"
        aria-label={gettext("More sections")}
        title={gettext("More sections")}
        style="anchor-name: --dk-nav-more"
      >
        <BarkparkWeb.Studio.Desk.Glyph.glyph name="ellipsis-horizontal" />
      </button>
      <div
        :if={@main != [] or @more != []}
        id="dk-nav-more"
        popover
        class="dk-nav-more-list"
        style="position-anchor: --dk-nav-more; inset: auto; top: anchor(bottom); right: anchor(right); margin: 4px 0 0"
      >
        <a
          :for={tab <- @main}
          href={tab.href}
          class={["studio-tab dk-nav-item dk-nav-narrow", tab.active && "active"]}
          aria-current={tab.active && "page"}
        >{tab.label}</a>
        <%= for tab <- @more do %>
          <span
            :if={tab.disabled}
            class="studio-tab studio-tab-disabled dk-nav-item"
            role="link"
            aria-disabled="true"
            title={"#{tab.label} — #{tab.reason}"}
            aria-label={"#{tab.label} — #{tab.reason}"}
            data-test-id="top-menu-tab-disabled"
          >{tab.label}</span>
          <a
            :if={!tab.disabled}
            href={tab.href}
            class={["studio-tab dk-nav-item", tab.active && "active"]}
            aria-current={tab.active && "page"}
            data-test-id="top-menu-tab"
          >{tab.label}</a>
        <% end %>
      </div>
    </div>
    """
  end

  @doc """
  The resolved tabs split in two: the built-in Structure, Media and API (in
  the bar, as text) and the rest (in the popover), each in its resolved order.
  Structure's link is the desk, and the desk's Vision follows it. A disabled
  built-in goes to the popover, where its reason can be read.
  """
  @spec split(map()) :: {[map()], [map()]}
  def split(assigns) do
    [structure, media, api | _] =
      Nav.default_top_menu_entries(
        assigns.dataset,
        assigns[:scope_prefix] || "",
        assigns[:admin?] == true,
        assigns[:current_path]
      )

    in_bar = %{
      structure.path => assigns.desk_base,
      media.path => media.path,
      api.path => api.path
    }

    vision = vision_path(assigns)
    on_vision? = assigns[:current_path] == vision

    {main, more} =
      assigns
      |> Nav.top_menu_tabs()
      |> Enum.map(&view(&1, in_bar, assigns[:current_path]))
      # Structure's pattern takes every Studio path but a few tools'.
      |> Enum.map(
        &%{&1 | active: &1.active and not (on_vision? and &1.href == assigns.desk_base)}
      )
      |> Enum.split_with(&(&1.in_bar and not &1.disabled))

    tool = %{
      label: gettext("Vision"),
      href: vision,
      in_bar: true,
      active: on_vision?,
      disabled: false,
      reason: nil,
      test_id: nil
    }

    case Enum.split_with(main, &(&1.href == assigns.desk_base)) do
      {[structure], rest} -> {[structure, tool | rest], more}
      _ -> {[tool | main], more}
    end
  end

  @doc "The desk's Vision tool, beside the desk: `…/studio/_desk/_tools/vision`."
  @spec vision_path(map()) :: String.t()
  def vision_path(assigns),
    do:
      Paths.studio_path(
        assigns[:scope_prefix] || "",
        ["_desk", "_tools", "vision"],
        assigns.dataset
      )

  defp view(tab, in_bar, current_path) do
    disabled = tab[:disabled] == true

    %{
      label: Nav.tab_label(tab.label),
      href: Map.get(in_bar, tab[:path], tab[:path]),
      in_bar: Map.has_key?(in_bar, tab[:path]),
      active: not disabled and Nav.plugin_tab_active?(tab, current_path),
      disabled: disabled,
      reason: if(disabled, do: Nav.disabled_reason(tab)),
      test_id: "top-menu-tab"
    }
  end
end
