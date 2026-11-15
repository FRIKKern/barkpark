defmodule BarkparkWeb.Studio.Desk.FieldSlots do
  @moduledoc """
  The two places every field of the desk's form holds for later work, under
  the names the TanStack Studio gives them (`Fields.tsx` `FieldActions`,
  `ChangeBar`):

  - `.change-bar`: where the mark of a changed field is drawn. Empty and
    hidden.
  - `.field-actions` with a button named "Field actions": where the field's
    menu (copy, paste) opens from. The menu does not exist yet, so the
    button is disabled: it is not in the tab order and a click does nothing.
    It is not drawn either (`Desk.Style`), and its holder is `aria-hidden`
    until the menu exists, so a screen reader does not meet one dimmed
    button per field.

  The form's field wrapper is shared with the old Studio and the plugin
  editors (`StudioComponents.Editor.editor_field/1`); it draws these in the
  desk only.
  """
  use Phoenix.Component
  use Gettext, backend: BarkparkWeb.Gettext

  @doc "The change bar's place and the Field actions button, as children of a `.field`."
  def slots(assigns) do
    ~H"""
    <span class="change-bar" data-desk-change-bar hidden></span>
    <div class="field-actions" data-desk-field-actions aria-hidden="true">
      <button type="button" class="icon-btn" aria-label={gettext("Field actions")} disabled>
        <span aria-hidden="true">…</span>
      </button>
    </div>
    """
  end
end
