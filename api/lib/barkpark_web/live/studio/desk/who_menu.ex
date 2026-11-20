defmodule BarkparkWeb.Studio.Desk.WhoMenu do
  @moduledoc """
  The desk navbar's "who is here", as the TanStack Studio's (`Presence.tsx`
  `WhoIsOnline`, Sanity's): one icon button, with a positive dot when
  anyone else is here (a dot, not a count), that opens a menu of the others.
  The bar draws no avatar of theirs, so it keeps its width at any number of
  people: on a phone their avatars sat over the search button.

  A row names the person and the document they are in, and opens it
  (`jump-to-user`, as the old bar's avatar did). Someone in no document has
  a disabled row. With nobody else here the menu says so.

  The rows keep `presence-user-wrap`, the old bar's class, so a page's
  "who's online" count reads the same in both Studios. The menu is the
  browser's own popover (`Desk.Menu`'s look): the button opens it, Escape
  and a click outside close it. `NavbarStyle` draws it.
  """
  use Phoenix.Component
  use Gettext, backend: BarkparkWeb.Gettext

  alias BarkparkWeb.Studio.Desk.Glyph

  attr :people, :list,
    required: true,
    doc: "the others here: presence maps, each with `:doc_title` (nil outside a document)"

  @doc "The button and its menu."
  def menu(assigns) do
    ~H"""
    <div class="menu-wrap dk dk-who">
      <button
        id="dk-who"
        type="button"
        class="icon-btn who"
        popovertarget="dk-who-menu"
        aria-label={gettext("Global presence")}
        data-tip={gettext("Who is here")}
        aria-haspopup="menu"
        style="anchor-name: --dk-who-menu"
      >
        <Glyph.glyph name="users" />
        <span :if={@people != []} class="who-dot" aria-hidden="true"></span>
      </button>
      <div
        id="dk-who-menu"
        popover
        role="menu"
        aria-labelledby="dk-who"
        class="dk-menu who-menu"
        style="position-anchor: --dk-who-menu; inset: auto; top: anchor(bottom); right: anchor(right); margin: 4px 0 0"
      >
        <div :if={@people == []} class="who-empty">
          <p>{gettext("No one else is here")}</p>
          <p class="muted">{gettext("Invite people to the project to see their online status.")}</p>
        </div>
        <button
          :for={p <- @people}
          type="button"
          role="menuitem"
          tabindex="-1"
          class="dk-menu-item who-row presence-user-wrap"
          phx-click={p.doc_title && "jump-to-user"}
          phx-value-type={p.doc_title && p.type}
          phx-value-doc-id={p.doc_title && p.doc_id}
          disabled={is_nil(p.doc_title)}
          title={if is_nil(p.doc_title), do: gettext("Not in a document")}
        >
          <span class="avatar" style={"background: #{p.color}"} aria-hidden="true">
            {initial(p)}
          </span>
          <span class="who-name">{name(p)}</span>
          <span class="who-doc">{p.doc_title || gettext("Not in a document")}</span>
        </button>
      </div>
    </div>
    """
  end

  defp name(p), do: Map.get(p, :name) || gettext("User")

  defp initial(p), do: p |> name() |> String.first() |> String.upcase()
end
