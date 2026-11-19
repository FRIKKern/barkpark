defmodule BarkparkWeb.Studio.Desk.NavDrawer do
  @moduledoc """
  The desk navbar's drawer, as the TanStack Studio's (`Navbar.tsx`
  `NavDrawer`, Sanity's phone navbar, J46): below 900 px the tools and the
  user menu give way in the bar, and "Open menu" before the logo opens a
  drawer from the left with who you are, the tools, Help and resources, the
  appearance and Sign out.

  The drawer is a modal `<dialog>` named "Menu": Tab stays inside, Escape or
  "Close menu" shuts it and the focus goes back to "Open menu", and picking
  a tool closes it. `bp-desk-navbar.js` opens and closes it, keeps
  `aria-expanded` on the button, and switches the appearance as the user
  menu's radios do (here they are pressed buttons, as TanStack's).

  The tools are `Desk.Navbar`'s, the same list in the same order, each with
  `aria-current` on the page's own. Help and resources closes the drawer and
  opens the navbar's own help menu (`Desk.HelpMenu`), so there is one of
  it. Who you are is `UserMenu.me/1`. Network shares, a Barkpark tool the
  bar has for a shares admin, gives way on a phone and is here too.

  The wrapper is `phx-update="ignore"`: a patch keeps the dialog open and
  what the script set. What it draws does not change on the desk's own
  patches (the tools, the principal).

  TanStack's drawer also has Tasks, its Tasks sidebar's button; the desk
  has no such sidebar, so the drawer has no Tasks.
  """
  use Phoenix.Component
  use Gettext, backend: BarkparkWeb.Gettext

  alias BarkparkWeb.Studio.Desk.Navbar
  alias BarkparkWeb.Studio.Desk.UserMenu

  attr :dataset, :string, required: true
  attr :desk_base, :string, required: true
  attr :scope_prefix, :string, default: ""
  attr :current_path, :string, default: nil
  attr :admin?, :boolean, default: false

  attr :shares?, :boolean,
    default: false,
    doc: "the bar's Network shares, which gives way on a phone"

  attr :current_user, :any, default: nil
  attr :api_token, :any, default: nil
  attr :workspace, :any, default: nil

  @doc "The menu button and its drawer."
  def drawer(assigns) do
    {main, more} = Navbar.split(assigns)

    assigns =
      assign(assigns,
        tools: main ++ more,
        me: UserMenu.me(assigns),
        signed_in?: assigns.current_user != nil or assigns.api_token != nil
      )

    ~H"""
    <div class="dk nav-drawer-wrap" id="dk-drawer-wrap" phx-update="ignore">
      <button
        id="dk-drawer-open"
        type="button"
        class="icon-btn nav-drawer-btn"
        aria-label={gettext("Open menu")}
        data-tip={gettext("Open menu")}
        aria-haspopup="dialog"
        aria-expanded="false"
        aria-controls="dk-drawer"
        data-desk-drawer-open
      >
        <BarkparkWeb.Icons.desk_icon name="menu" size={21} />
      </button>
      <dialog id="dk-drawer" class="nav-drawer" aria-label={gettext("Menu")}>
        <header>
          <span :if={@me} class="avatar" aria-hidden="true">{UserMenu.initials(@me.name)}</span>
          <span :if={!@me} class="logo" aria-hidden="true">B</span>
          <span class="drawer-who">{if @me, do: @me.name, else: "Barkpark Studio"}</span>
          <button type="button" class="icon-btn" aria-label={gettext("Close menu")} data-desk-drawer-close>
            <BarkparkWeb.Icons.desk_icon name="close" size={21} />
          </button>
        </header>
        <nav aria-label={gettext("Tools")}>
          <%= for tool <- @tools do %>
            <span
              :if={tool.disabled}
              class="drawer-item"
              role="link"
              aria-disabled="true"
              title={"#{tool.label} — #{tool.reason}"}
            >{tool.label}</span>
            <a
              :if={!tool.disabled}
              href={tool.href}
              class={["drawer-item", tool.active && "on"]}
              aria-current={tool.active && "page"}
              data-desk-drawer-pick
            >{tool.label}</a>
          <% end %>
        </nav>
        <div class="drawer-foot">
          <button :if={@shares?} type="button" class="drawer-item" phx-click="shares-open" data-desk-drawer-pick>
            <span class="menu-icon-text">
              <BarkparkWeb.Icons.desk_icon name="share-2" size={21} />{gettext("Network shares")}
            </span>
          </button>
          <button type="button" class="drawer-item" data-desk-drawer-help>
            <span class="menu-icon-text">
              <BarkparkWeb.Icons.desk_icon name="help-circle" size={21} />{gettext("Help and resources")}
            </span>
          </button>
          <hr />
          <button
            :for={{value, label, icon} <- appearances()}
            type="button"
            class="drawer-item check"
            aria-pressed="false"
            aria-label={appearance_name(value)}
            data-desk-appearance={value}
          >
            <span class="menu-icon-text"><BarkparkWeb.Icons.desk_icon name={icon} size={21} />{label}</span>
          </button>
          <%= if @signed_in? do %>
            <hr />
            <.form :let={_f} for={%{}} as={:session} action="/logout" method="post" class="drawer-signout">
              <button type="submit" class="drawer-item">
                <span class="menu-icon-text">{gettext("Sign out")}<BarkparkWeb.Icons.desk_icon name="leave" size={21} /></span>
              </button>
            </.form>
          <% end %>
        </div>
      </dialog>
    </div>
    """
  end

  defp appearances do
    [
      {"system", gettext("System"), "desktop"},
      {"dark", gettext("Dark"), "moon"},
      {"light", gettext("Light"), "sun"}
    ]
  end

  defp appearance_name("system"), do: gettext("Use system appearance")
  defp appearance_name("dark"), do: gettext("Use dark appearance")
  defp appearance_name("light"), do: gettext("Use light appearance")
end
