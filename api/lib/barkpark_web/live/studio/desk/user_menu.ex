defmodule BarkparkWeb.Studio.Desk.UserMenu do
  @moduledoc """
  The desk navbar's user menu, as the TanStack Studio's (`Navbar.tsx`
  `Editor`, Sanity's, top right): `#user-menu` opens who you are, the
  appearance (System, Dark, Light, checked like radios, named "Use system
  appearance" and so on) and Sign out.

  Who you are is this socket's own principal and nothing else: an account's
  name, email and its role in the workspace the page is in, or a token's own
  name. Sign out is the Studio's: a POST to `/logout` with the form's CSRF
  token, as the old bar's button.

  The appearance is the browser's (`barkpark_theme` in localStorage, as the
  old bar's toggle; none stored is System). `bp-desk-navbar.js` checks the
  one in use and switches it, so the menu is `phx-update="ignore"`: a patch
  keeps what the script set.
  """
  use Phoenix.Component
  use Gettext, backend: BarkparkWeb.Gettext

  alias Barkpark.Accounts.User
  alias Barkpark.Auth.ApiToken
  alias BarkparkWeb.Studio.Desk.Menu

  attr :current_user, :any, default: nil
  attr :api_token, :any, default: nil
  attr :workspace, :any, default: nil

  @doc "The avatar button and its menu."
  def menu(assigns) do
    assigns = assign(assigns, :me, me(assigns))

    ~H"""
    <div class="editor dk" id="dk-user" phx-update="ignore">
      <div class="menu-wrap">
        <button
          id="user-menu"
          type="button"
          class="icon-btn user-btn"
          popovertarget="dk-user-menu"
          aria-label={gettext("Open user menu")}
          aria-haspopup="menu"
          style="anchor-name: --dk-user-menu"
        >
          <span :if={@me} class="avatar" aria-hidden="true">{initials(@me.name)}</span>
          <BarkparkWeb.Icons.desk_icon :if={!@me} name="user" size={21} />
        </button>
        <div
          id="dk-user-menu"
          popover
          role="menu"
          aria-labelledby="user-menu"
          class="dk-menu user-menu"
          style="position-anchor: --dk-user-menu; inset: auto; top: anchor(bottom); right: anchor(right); margin: 4px 0 0"
        >
          <div :if={@me} class="user-head">
            <span class="avatar" aria-hidden="true">{initials(@me.name)}</span>
            <span class="user-who">
              <span class="user-name">{@me.name}</span>
              <span :if={@me.email} class="user-email">{@me.email}</span>
              <span :if={@me.role} class="user-role">{@me.role}</span>
            </span>
          </div>
          <div :if={!@me} class="user-head">Barkpark Studio</div>
          <Menu.separator />
          <Menu.item
            :for={{value, label, icon} <- appearances()}
            role="menuitemradio"
            aria-checked="false"
            tabindex="-1"
            icon={icon}
            class="check"
            data-desk-appearance={value}
            aria-label={appearance_name(value)}
          >{label}</Menu.item>
          <%= if @current_user || @api_token do %>
            <Menu.separator />
            <.form :let={_f} for={%{}} as={:session} action="/logout" method="post" class="dk-user-signout">
              <button type="submit" role="menuitem" tabindex="-1" class="dk-menu-item spread">
                {gettext("Sign out")}<span class="dk-signout-icon" aria-hidden="true"><BarkparkWeb.Icons.desk_icon name="leave" size={21} /></span>
              </button>
            </.form>
          <% end %>
        </div>
      </div>
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

  @doc """
  Who this socket is, for the menu's head: an account's name, email and
  role in the page's workspace, or a token's own name. nil with neither.
  """
  @spec me(map()) :: %{name: String.t(), email: String.t() | nil, role: String.t() | nil} | nil
  def me(%{current_user: %User{} = user} = assigns) do
    name = present(user.display_name) || user.email

    %{
      name: name,
      email: if(name != user.email, do: user.email),
      role: role(user, assigns[:workspace])
    }
  end

  def me(%{api_token: %ApiToken{} = token} = assigns) do
    %{
      name: present(token.name) || present(token.label) || gettext("API token"),
      email: nil,
      role: role(token, assigns[:workspace])
    }
  end

  def me(_assigns), do: nil

  defp role(principal, %{id: ws_id}) when is_binary(ws_id) do
    case Barkpark.Tenancy.Auth.membership(principal, ws_id) do
      %{role: role} when is_binary(role) and role != "" -> String.capitalize(role)
      _ -> nil
    end
  end

  defp role(_principal, _workspace), do: nil

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil

  @doc "An avatar's letters: the first of up to two words."
  def initials(name) when is_binary(name) do
    name
    |> String.split(~r/[\s@._-]+/u, trim: true)
    |> Enum.take(2)
    |> Enum.map_join(&(&1 |> String.first() |> String.upcase()))
  end

  def initials(_name), do: ""
end
