defmodule BarkparkWeb.Studio.Desk.DocMenu do
  @moduledoc """
  The edit pane's "…" menu, Sanity's document actions: Publish or Unpublish,
  History, Duplicate and Delete, as the Studio offers them for the open
  document (`DocActions.resolved_doc_actions/1`, so a singleton has no
  Unpublish, Duplicate or Delete, and a plugin's resolver applies). Each item
  sends the Studio's own event to the page, which hands it to the editor
  (`EditorHost`): nothing here writes, and the Studio's toolbar is untouched.

  The menu is an HTML popover, as the list's "List options" is: Enter or a
  click opens it, Escape or a click outside closes it and the focus goes back
  to the button. `bp-desk.js` focuses the first item on open, keeps
  `aria-expanded` on the button and moves the focus with the arrow keys.
  """
  use Phoenix.Component
  use Gettext, backend: BarkparkWeb.Gettext

  alias BarkparkWeb.Studio.StudioLive.DocActions

  # The Studio events this menu may send (grant R21); every other action
  # stays where the Studio draws it.
  @events ~w(publish unpublish show-history duplicate-doc delete-doc)

  @doc "The open document's menu items, in the Studio's order; none without a document."
  @spec items(map()) :: [%{label: String.t(), event: String.t()}]
  def items(%{editor_doc: %{}} = assigns) do
    for %{"name" => name} = action <- DocActions.resolved_doc_actions(assigns),
        name in @events,
        do: %{label: action["label"], event: name}
  end

  def items(_assigns), do: []

  # `icon-btn` and `data-tip` are the names Sanity's specs count header icon
  # buttons by (previews-tips J57); no style rides them here.
  # One edit pane is open at a time, so one anchor name will do; a pane id
  # (`desk-pane-2-doc:post;x`) is not a CSS name.
  attr :id, :string, required: true
  attr :items, :list, required: true

  @doc "The \"…\" button and its menu."
  def menu(assigns) do
    ~H"""
    <div :if={@items != []} class="dk-doc-menu">
      <button
        type="button"
        id={"#{@id}-button"}
        class="dk-doc-menu-button icon-btn"
        popovertarget={@id}
        aria-haspopup="menu"
        aria-expanded="false"
        aria-label={gettext("Show document actions")}
        data-tip={gettext("Show document actions")}
        style="anchor-name: --dk-doc-menu"
      >
        <span aria-hidden="true">…</span>
      </button>
      <div
        id={@id}
        popover
        role="menu"
        aria-labelledby={"#{@id}-button"}
        class="dk-doc-menu-list"
        style="position-anchor: --dk-doc-menu; inset: auto; top: anchor(bottom); right: anchor(right); margin: 4px 0 0"
      >
        <button
          :for={item <- @items}
          type="button"
          role="menuitem"
          tabindex="-1"
          popovertarget={@id}
          popovertargetaction="hide"
          phx-click={item.event}
          data-desk-doc-action={item.event}
        >
          {item.label}
        </button>
      </div>
    </div>
    """
  end
end
