defmodule BarkparkWeb.Studio.Desk.DocMenu do
  @moduledoc """
  The edit pane's "…" menu, Sanity's document actions: Publish or Unpublish,
  History, Discard draft (Sanity's "Discard changes": a draft over a
  published document), Duplicate and Delete, as the Studio offers them for
  the open document (`DocActions.resolved_doc_actions/1`, so a singleton has
  no Unpublish, Duplicate or Delete, and a plugin's resolver applies). Discard
  asks first: the Studio's own dialog, with the published version kept. Each item
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
  @events ~w(publish unpublish show-history discard-draft duplicate-doc delete-doc)

  @doc "The open document's menu items, in the Studio's order; none without a document."
  @spec items(map()) :: [%{label: String.t(), event: String.t()}]
  def items(%{editor_doc: %{}} = assigns) do
    for %{"name" => name} = action <- DocActions.resolved_doc_actions(with_twin(assigns)),
        name in @events,
        do: %{label: action["label"], event: name}
  end

  def items(_assigns), do: []

  # The Studio offers Discard draft when it holds the published twin
  # (`published_doc`), which it reads only when the document opens: a draft
  # made by typing in a published document has a twin and no `published_doc`
  # until it is opened again. The Discard handler's own guard reads
  # `editor_is_draft` and `editor_has_published`, which the save keeps; so
  # does the menu. `published_doc` is read here for being there, nothing else
  # (the plugins' context does not carry it).
  defp with_twin(%{published_doc: nil, editor_is_draft: true, editor_has_published: true} = a),
    do: Map.put(a, :published_doc, a.editor_doc)

  defp with_twin(assigns), do: assigns

  # Two places draw it, with Sanity's two names: the header's "Show document
  # actions" (DocHeaderMenu) and the footer's "Open document actions"
  # (DocumentPane). `icon-btn` and `data-tip` are the names Sanity's specs
  # count header icon buttons by (previews-tips J57), so only the header's
  # carries `icon-btn`; no style rides it here. One edit pane is open at a
  # time, so one anchor name per place will do; a pane id
  # (`desk-pane-2-doc:post;x`) is not a CSS name. The footer's menu opens
  # upwards.
  attr :id, :string, required: true
  attr :items, :list, required: true
  attr :place, :atom, default: :header, values: [:header, :footer]

  @doc "The \"…\" button and its menu."
  def menu(assigns) do
    assigns = assign(assigns, place(assigns.place))

    ~H"""
    <div :if={@items != []} class="dk-doc-menu">
      <button
        type="button"
        id={"#{@id}-button"}
        class={@button_class}
        popovertarget={@id}
        aria-haspopup="menu"
        aria-expanded="false"
        aria-label={@label}
        data-tip={@label}
        style={"anchor-name: #{@anchor}"}
      >
        <span aria-hidden="true">…</span>
      </button>
      <div
        id={@id}
        popover
        role="menu"
        aria-labelledby={"#{@id}-button"}
        class="dk-doc-menu-list"
        style={"position-anchor: #{@anchor}; inset: auto; #{@at}; right: anchor(right); #{@margin}"}
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

  defp place(:header),
    do: %{
      label: gettext("Show document actions"),
      button_class: "dk-doc-menu-button icon-btn",
      anchor: "--dk-doc-menu",
      at: "top: anchor(bottom)",
      margin: "margin: 4px 0 0"
    }

  defp place(:footer),
    do: %{
      label: gettext("Open document actions"),
      button_class: "dk-doc-menu-button",
      anchor: "--dk-doc-menu-footer",
      at: "bottom: anchor(top)",
      margin: "margin: 0 0 4px"
    }
end
