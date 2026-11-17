defmodule BarkparkWeb.Components.Fields.ArrayItemDialog do
  @moduledoc """
  An object item of an array in the desk's form, as the TanStack Studio
  draws it (`ObjectArrayInput.tsx`, `SortableRows.tsx`): a drag handle, the
  item's preview as a button, its "…" menu (`ArrayItemMenu`), and the
  item's fields in a dialog the preview opens ("Links / #1 Sanity docs").

  Only the desk draws an item this way (`ArrayField` hands an object row
  here when the array has a desk path, `id_base`); the old Studio keeps its
  open-in-place rows.

  THE FIELDS STAY IN THE FORM. The dialog is a `<dialog>` inside the row,
  so its inputs are the form's inputs wherever the dialog is drawn, open or
  shut: the form posts every item's fields on every change exactly as it
  did when they sat in an open-in-place row. Nothing about what is posted,
  or how it is saved, changes here; only where the inputs are shown.

  Whether a dialog is open is the browser's (`bp-desk-array-menu.js` opens
  it with `showModal()` and keeps the focus inside); a patch leaves `open`
  alone. Escape, the close button and the crumb close it, and the focus
  goes back to the item's preview. A press that adds an item (Add item,
  Duplicate, Add item before or after) is answered with the event
  `desk:item-open`, which opens the new item's dialog, as Sanity's does.

  The drag handle moves the item: Space or Enter picks it up, the arrows
  move it, Space or Enter drops it and Escape puts it back. The script sends
  one `array_op` `move_row` on the drop.
  """
  use Phoenix.Component
  use Gettext, backend: BarkparkWeb.Gettext

  alias BarkparkWeb.Components.Fields.ArrayItemMenu
  alias Phoenix.LiveView.JS

  attr :stem, :string, required: true, doc: ~s(the item's path, `links[_key=="l1"]`)
  attr :row_id, :string, required: true, doc: "the row's DOM id, kept with its `_key`"
  attr :idx, :integer, required: true
  attr :key, :string, default: nil
  attr :count, :integer, required: true, doc: "how many items the array has"
  attr :field, :string, required: true
  attr :field_title, :string, required: true
  attr :path, :string, required: true
  attr :preview, :map, required: true
  attr :finding, :boolean, default: false
  attr :readonly, :boolean, default: false
  attr :on_reorder, :string, default: "array_op"
  attr :target, :any, default: nil
  attr :help_id, :string, required: true, doc: "the array's keyboard help, for the handle"
  attr :body, :any, required: true, doc: "the item's fields"
  attr :errors, :list, default: [], doc: "the row's own errors, under it"
  attr :warnings, :list, default: [], doc: "the row's own warnings, under it"

  @doc "One object item: handle, preview, menu and its dialog."
  def row(assigns) do
    # `ArrayField` calls this with a plain map, as it calls its own rows.
    assigns =
      assigns
      |> Map.put_new(:__changed__, nil)
      |> assign(
        dialog_id: assigns.row_id <> "-dialog",
        label: "#{assigns.field_title} / #{assigns.preview.title}"
      )

    ~H"""
    <li
      class="bp-array-row bp-array-row-item dk-array-row"
      id={@row_id}
      data-row-index={@idx}
      data-row-key={@key}
      data-row-finding={@finding}
      data-item-path={@stem}
    >
      <button
        type="button"
        class="icon-btn dk-drag-handle"
        aria-roledescription={gettext("sortable")}
        aria-label={gettext("Move item %{n}", n: @idx + 1)}
        aria-describedby={@help_id}
        aria-pressed="false"
        data-tip={gettext("Drag to re-order")}
        disabled={@readonly or @count < 2}
        phx-mounted={JS.ignore_attributes(["aria-pressed"])}
        data-desk-item-handle
        data-move-event={@on_reorder}
        data-move-field={@field}
        data-move-path={@path}
        data-move-index={@idx}
      ><BarkparkWeb.Icons.desk_icon name="drag-handle" size={21} /></button>
      <button type="button" class="dk-item-preview" aria-haspopup="dialog" data-desk-item-open={@dialog_id}>
        <span :if={@preview.media} class="media has-image" aria-hidden="true">
          <img src={@preview.media} alt="" loading="lazy" />
        </span>
        <span :if={!@preview.media} class="media" aria-hidden="true">
          <BarkparkWeb.Icons.desk_icon name={@preview[:icon] || "document"} size={21} />
        </span>
        <span class="text">
          <span class="title">{@preview.title}</span>
          <span :if={@preview.subtitle} class="subtitle">{@preview.subtitle}</span>
        </span>
      </button>
      <ArrayItemMenu.menu
        stem={@stem}
        field={@field}
        path={@path}
        index={@idx}
        readonly={@readonly}
        on_reorder={@on_reorder}
        target={@target}
      />
      <dialog
        id={@dialog_id}
        class="dk-item-dialog"
        aria-label={@label}
        data-desk-item-dialog
        phx-mounted={JS.ignore_attributes(["open"])}
      >
        <header class="dk-item-head">
          <nav class="dk-crumbs" aria-label={gettext("Breadcrumb")}>
            <button type="button" class="dk-crumb" data-desk-item-close>{@field_title}</button>
            <span aria-hidden="true">/</span>
            <span class="dk-crumb current">
              <span class="place">#{@idx + 1}</span>
              <span class="crumb-title">{@preview.title}</span>
            </span>
          </nav>
          <button type="button" class="icon-btn dk-item-close" aria-label={gettext("Close dialog")} data-desk-item-close>
            <BarkparkWeb.Icons.desk_icon name="close" size={21} />
          </button>
        </header>
        <div class="dk-item-body">{@body}</div>
      </dialog>
      <span :for={err <- @errors} class="error" data-error-for-row={@idx}>{err}</span>
      <span :for={warn <- @warnings} class="warning" role="note" data-warning-for-row={@idx}>{warn}</span>
    </li>
    """
  end

  attr :id, :string, required: true

  @doc "The array's keyboard help for its handles, read by a screen reader."
  def help(assigns) do
    ~H"""
    <p id={@id} hidden>
      {gettext(
        "To pick up an item, press Space or Enter on its handle. Use the arrow keys to move it, Space or Enter to drop, Escape to cancel."
      )}
    </p>
    """
  end
end
