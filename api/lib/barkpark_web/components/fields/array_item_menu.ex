defmodule BarkparkWeb.Components.Fields.ArrayItemMenu do
  @moduledoc """
  An array item's "…" menu in the desk's form, as the TanStack Studio's
  (`SortableRows.tsx` `ItemMenu`): Remove, Copy, Duplicate, Add item before
  and Add item after.

  The button is named "Item actions" and its id is the item's path with
  `-menuButton`, `links[_key=="l1"]-menuButton`, as Sanity's Studio names
  it. The menu is an HTML popover of the desk's menu look (`Desk.Menu`):
  Enter or a click opens it, Escape or a click outside closes it.
  `bp-desk-array-menu.js` places it by its button, keeps `aria-expanded`,
  focuses the first item and moves the focus with the arrow keys. A patch
  leaves those attributes alone.

  WHAT EACH ITEM SENDS. Remove, Duplicate and the two adds are the list's
  own `array_op` presses, with the same `field`, `path` and `index` as the
  old row buttons, so they carry the document's mark (`PostIdentity`) and
  are written by `Handlers.Fields.array_op/2` (`Handlers.ArrayItems` for
  the new ones). `open` asks the server to open the new item's dialog (a
  string row's input takes the caret instead; a string's Duplicate opens
  nothing, `opens_copy`).

  Copy writes nothing: it sends `desk-item-copy` and the server answers
  with the item as a clipboard item, as a field's Copy field is answered
  (`Desk.FieldActions`). The menu carries what `bp-desk-field-actions.js`
  reads for that (`data-desk-field`, `data-desk-copy-failed`), and the item
  carries `data-desk-field-copy`, so the clipboard write starts in the click
  as it does for a field.
  """
  use Phoenix.Component
  use Gettext, backend: BarkparkWeb.Gettext

  alias BarkparkWeb.Studio.Desk.Menu
  alias Phoenix.LiveView.JS

  attr :stem, :string, required: true, doc: ~s(the item's path, `links[_key=="l1"]`)
  attr :field, :string, required: true, doc: "the array field's name"
  attr :path, :string, required: true, doc: "the array's input path, `doc[links]`"
  attr :index, :integer, required: true
  attr :readonly, :boolean, default: false
  attr :on_reorder, :string, default: "array_op"
  attr :target, :any, default: nil

  attr :opens_copy, :boolean,
    default: true,
    doc: "whether Duplicate opens the copy (an object item's dialog); a string's copy does not"

  @doc "The item's \"…\" button and its menu."
  def menu(assigns) do
    assigns =
      assign(assigns,
        button_id: assigns.stem <> "-menuButton",
        menu_id: assigns.stem <> "-menu"
      )

    ~H"""
    <div class="dk-item-actions">
      <button
        type="button"
        id={@button_id}
        class="icon-btn dk-item-menu-button"
        popovertarget={@menu_id}
        aria-haspopup="menu"
        aria-expanded="false"
        aria-label={gettext("Item actions")}
        data-tip={gettext("Show more")}
        data-tip-side="right"
        disabled={@readonly}
        phx-mounted={JS.ignore_attributes(["aria-expanded", "style"])}
      ><BarkparkWeb.Icons.desk_icon name="ellipsis-horizontal" size={21} /></button>
      <div
        id={@menu_id}
        popover
        role="menu"
        aria-labelledby={@button_id}
        class="dk-item-menu dk-menu"
        data-desk-item-menu
        data-desk-field={@field}
        data-desk-copy-failed={gettext("Could not copy to the clipboard")}
        data-desk-unavailable={gettext("Copy and paste did not load. Reload the page.")}
      >
        <Menu.item
          role="menuitem"
          tabindex="-1"
          icon="trash"
          danger
          popovertarget={@menu_id}
          popovertargetaction="hide"
          phx-click={@on_reorder}
          phx-target={@target}
          phx-value-action="remove_row"
          phx-value-field={@field}
          phx-value-path={@path}
          phx-value-index={@index}
          data-desk-item-action="remove"
        >{gettext("Remove")}</Menu.item>
        <Menu.item
          role="menuitem"
          tabindex="-1"
          icon="copy"
          popovertarget={@menu_id}
          popovertargetaction="hide"
          phx-click="desk-item-copy"
          phx-value-path={@path}
          phx-value-index={@index}
          data-desk-field-copy
          data-desk-item-action="copy"
        >{gettext("Copy")}</Menu.item>
        <Menu.item
          role="menuitem"
          tabindex="-1"
          icon="add-document"
          popovertarget={@menu_id}
          popovertargetaction="hide"
          phx-click={@on_reorder}
          phx-target={@target}
          phx-value-action="duplicate_row"
          phx-value-field={@field}
          phx-value-path={@path}
          phx-value-index={@index}
          phx-value-open={@opens_copy && "item"}
          data-desk-item-action="duplicate"
        >{gettext("Duplicate")}</Menu.item>
        <Menu.item
          role="menuitem"
          tabindex="-1"
          icon="insert-above"
          popovertarget={@menu_id}
          popovertargetaction="hide"
          phx-click={@on_reorder}
          phx-target={@target}
          phx-value-action="insert_row"
          phx-value-field={@field}
          phx-value-path={@path}
          phx-value-index={@index}
          phx-value-open="item"
          data-desk-item-action="add-before"
        >{gettext("Add item before")}</Menu.item>
        <Menu.item
          role="menuitem"
          tabindex="-1"
          icon="insert-below"
          popovertarget={@menu_id}
          popovertargetaction="hide"
          phx-click={@on_reorder}
          phx-target={@target}
          phx-value-action="insert_row"
          phx-value-field={@field}
          phx-value-path={@path}
          phx-value-index={@index + 1}
          phx-value-open="item"
          data-desk-item-action="add-after"
        >{gettext("Add item after")}</Menu.item>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true, doc: "the button's id"
  attr :types, :list, required: true, doc: "`%{value, title}` of each item type"
  attr :field, :string, required: true
  attr :path, :string, required: true
  attr :count, :integer, required: true, doc: "how many items the array has"
  attr :readonly, :boolean, default: false
  attr :on_reorder, :string, default: "array_op"
  attr :target, :any, default: nil

  @doc """
  "Add item" of an array whose items are of several types
  (`ArrayField.member_typing/1`): a menu of the types, as Sanity's insert
  menu. The item added is of the type chosen, at the end, and opens.
  """
  def add_menu(assigns) do
    assigns = assign(assigns, :menu_id, assigns.id <> "-menu")

    ~H"""
    <div class="dk-add-item">
      <button
        type="button"
        id={@id}
        class="bp-array-btn bp-array-btn-add"
        popovertarget={@menu_id}
        aria-haspopup="menu"
        aria-expanded="false"
        disabled={@readonly}
        phx-mounted={JS.ignore_attributes(["aria-expanded", "style"])}
      ><span aria-hidden="true">+ </span>{gettext("Add item")}</button>
      <div
        id={@menu_id}
        popover
        role="menu"
        aria-labelledby={@id}
        class="dk-item-menu dk-menu"
        data-desk-item-menu
      >
        <Menu.item
          :for={type <- @types}
          role="menuitem"
          tabindex="-1"
          popovertarget={@menu_id}
          popovertargetaction="hide"
          phx-click={@on_reorder}
          phx-target={@target}
          phx-value-action="insert_row"
          phx-value-field={@field}
          phx-value-path={@path}
          phx-value-index={@count}
          phx-value-kind={type.value}
          phx-value-open="item"
        >{type.title}</Menu.item>
      </div>
    </div>
    """
  end
end
