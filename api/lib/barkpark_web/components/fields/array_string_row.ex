defmodule BarkparkWeb.Components.Fields.ArrayStringRow do
  @moduledoc """
  A row of an array of strings in the desk's form, as the TanStack Studio
  draws it (`ArrayInputs.tsx` `StringArrayInput`, `SortableRows.tsx`): the
  drag handle, the value's input, and the item's "…" menu (Remove, Copy,
  Duplicate, Add item before and Add item after).

  Only the desk draws a row this way (`ArrayField` hands a string row here
  when the array has a desk path, `id_base`); the old Studio keeps its row
  buttons.

  A string has no `_key`, so the item is named by its place, as Sanity's
  names it: the input is `highlights[1]` and the menu's button
  `highlights[1]-menuButton`.

  THE SAME WRITES AS AN OBJECT ITEM. The handle (`ArrayItemDialog.handle/1`)
  and the menu (`ArrayItemMenu`) are the object item's own, so a move, a
  Remove, a Duplicate and the two adds are the same `array_op` presses,
  with the document's mark. The list stays a list of plain strings: a
  copy of a string is that string, and an added item is the empty string
  Add item makes.

  Where the focus goes: after Remove, to the row now in that place, else
  the last row, else Add item (`bp-array-focus.js`); after an add before or
  after, into the new row's input (`bp-desk-array-menu.js`, on
  `desk:item-open`); after a drop, to the moved row's handle.
  """
  use Phoenix.Component

  alias BarkparkWeb.Components.Fields.{ArrayItemDialog, ArrayItemMenu}

  attr :stem, :string, required: true, doc: "the item's path, `highlights[1]`"
  attr :idx, :integer, required: true
  attr :count, :integer, required: true, doc: "how many items the array has"
  attr :field, :string, required: true
  attr :path, :string, required: true
  attr :readonly, :boolean, default: false
  attr :on_reorder, :string, default: "array_op"
  attr :target, :any, default: nil
  attr :help_id, :string, required: true, doc: "the array's keyboard help, for the handle"
  attr :body, :any, required: true, doc: "the value's input"
  attr :errors, :list, default: []
  attr :warnings, :list, default: []

  @doc "One string row: handle, input and menu."
  def row(assigns) do
    # `ArrayField` calls this with a plain map, as it calls its own rows.
    assigns = Map.put_new(assigns, :__changed__, nil)

    ~H"""
    <li class="bp-array-row dk-array-row dk-string-row" data-row-index={@idx} data-item-path={@stem}>
      <ArrayItemDialog.handle
        idx={@idx}
        count={@count}
        field={@field}
        path={@path}
        readonly={@readonly}
        on_reorder={@on_reorder}
        help_id={@help_id}
      />
      <div class="dk-string-value">{@body}</div>
      <ArrayItemMenu.menu
        stem={@stem}
        field={@field}
        path={@path}
        index={@idx}
        readonly={@readonly}
        on_reorder={@on_reorder}
        target={@target}
        opens_copy={false}
      />
      <span :for={err <- @errors} class="error" data-error-for-row={@idx}>{err}</span>
      <span :for={warn <- @warnings} class="warning" role="note" data-warning-for-row={@idx}>{warn}</span>
    </li>
    """
  end
end
