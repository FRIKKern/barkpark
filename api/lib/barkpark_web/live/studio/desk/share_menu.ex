defmodule BarkparkWeb.Studio.Desk.ShareMenu do
  @moduledoc """
  The edit pane's "Share document" menu, as Sanity's: "Copy document ID" and
  "Copy document URL". The copy is the browser's: each item carries the text
  and the toast that confirms it, and `bp-desk.js` writes the text to the
  clipboard and shows the toast. Nothing goes to the server.

  It is the same popover as the "…" menu (`DocMenu`), and takes its classes,
  so `bp-desk.js` opens, closes and moves through it the same way; and the
  desk's one menu look (`Desk.Menu`), the URL first, as TanStack's.
  """
  use Phoenix.Component
  use Gettext, backend: BarkparkWeb.Gettext

  alias Barkpark.Content
  alias BarkparkWeb.Studio.Desk.Menu
  alias BarkparkWeb.Studio.Desk.Panes

  attr :id, :string, required: true
  attr :doc, :map, required: true, doc: "the open document (`editor_doc`)"
  attr :chain, :list, required: true
  attr :index, :integer, required: true
  attr :base, :string, required: true

  @doc "The share button, its menu, and the toast that says what was copied."
  def menu(assigns) do
    assigns =
      assign(assigns,
        doc_id: Content.published_id(assigns.doc.doc_id),
        url: url(assigns.chain, assigns.index, assigns.base)
      )

    ~H"""
    <div class="dk-doc-menu dk-share-menu">
      <button
        type="button"
        id={"#{@id}-button"}
        class="dk-doc-menu-button icon-btn"
        popovertarget={@id}
        aria-haspopup="menu"
        aria-expanded="false"
        aria-label={gettext("Share document")}
        data-tip={gettext("Share document")}
        style="anchor-name: --dk-share-menu"
      >
        <BarkparkWeb.Icons.icon name="link" size={14} />
      </button>
      <div
        id={@id}
        popover
        role="menu"
        aria-labelledby={"#{@id}-button"}
        class="dk-doc-menu-list dk-menu"
        style="position-anchor: --dk-share-menu; inset: auto; top: anchor(bottom); right: anchor(right); margin: 4px 0 0"
        data-desk-copy-failed={gettext("Could not copy to the clipboard")}
      >
        <Menu.item
          role="menuitem"
          tabindex="-1"
          icon="link"
          popovertarget={@id}
          popovertargetaction="hide"
          data-desk-copy={@url}
          data-desk-copy-origin
          data-desk-copied={gettext("Document URL copied to clipboard")}
        >{gettext("Copy document URL")}</Menu.item>
        <Menu.item
          role="menuitem"
          tabindex="-1"
          icon="target"
          popovertarget={@id}
          popovertargetaction="hide"
          data-desk-copy={@doc_id}
          data-desk-copied={gettext("Document ID copied to clipboard")}
        >{gettext("Copy document ID")}</Menu.item>
      </div>
      <%!-- Kept in the page, so a screen reader reads what is put in it. A
            popover, so it is over everything and no pane can box it in. --%>
      <div
        id={"#{@id}-toast"}
        class="dk-toast"
        popover="manual"
        role="status"
        aria-live="polite"
        phx-update="ignore"
      >
      </div>
    </div>
    """
  end

  @doc """
  The path that opens this document as it is open now: the panes left of its
  split group, then this pane alone. `bp-desk.js` puts the page's origin in
  front.
  """
  @spec url([Panes.pane()], non_neg_integer(), String.t()) :: String.t()
  def url(chain, index, base) do
    pane = Enum.at(chain, index)

    Panes.to_path(
      Enum.take(chain, group_start(chain, index)) ++ [Map.delete(pane, :sibling)],
      base
    )
  end

  defp group_start(chain, index) do
    case Enum.at(chain, index) do
      %{sibling: true} when index > 0 -> group_start(chain, index - 1)
      _ -> index
    end
  end
end
