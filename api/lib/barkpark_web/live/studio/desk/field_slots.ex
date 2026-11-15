defmodule BarkparkWeb.Studio.Desk.FieldSlots do
  @moduledoc """
  The two places every field of the desk's form holds, under the names the
  TanStack Studio gives them (`Fields.tsx` `FieldActions`, `ChangeBar`):

  - `.change-bar`: where the mark of a changed field is drawn. Empty and
    hidden.
  - `.field-actions` with a button named "Field actions": the field's menu
    (`FieldActions`: copy, paste). Drawn for a field with a name.

  The form's field wrapper is shared with the old Studio and the plugin
  editors (`StudioComponents.Editor.editor_field/1`); it draws these in the
  desk only.
  """
  use Phoenix.Component

  alias BarkparkWeb.Studio.Desk.FieldActions

  attr :field, :any, default: nil, doc: "the schema field the menu is for; none draws no menu"

  @doc "The change bar's place and the Field actions menu, as children of a `.field`."
  def slots(assigns) do
    assigns = assign(assigns, :name, name(assigns.field))

    ~H"""
    <span class="change-bar" data-desk-change-bar hidden></span>
    <FieldActions.menu :if={@name} name={@name} />
    """
  end

  defp name(%{"name" => name}) when is_binary(name) and name != "", do: name
  defp name(_field), do: nil
end
