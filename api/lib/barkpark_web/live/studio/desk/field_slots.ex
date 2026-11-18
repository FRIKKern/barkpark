defmodule BarkparkWeb.Studio.Desk.FieldSlots do
  @moduledoc """
  The two places every field of the desk's form holds, under the names the
  TanStack Studio gives them (`Fields.tsx` `FieldActions`, `ChangeBar`):

  - `.change-bar`: the mark of a top-level field the draft changed since
    it was published, a button named "Review changes" that opens Review
    changes (`ReviewChanges.bar/2`). An unchanged field keeps the place,
    empty and hidden.
  - `.field-actions` with a button named "Field actions": the field's menu
    (`FieldActions`: copy, paste). Drawn for a field with a name. `of/2`
    is what the shared wrapper is handed: the field and the editor's
    capabilities in one value.

  And in the field's label, `mark/1`: the mark of a slug already in use
  (`SlugInUse`), TanStack's `ProblemMark` beside the title.

  The form's field wrapper is shared with the old Studio and the plugin
  editors (`StudioComponents.Editor.editor_field/1`); it draws these in the
  desk only.
  """
  use Phoenix.Component
  use Gettext, backend: BarkparkWeb.Gettext

  alias BarkparkWeb.Studio.Desk.FieldActions
  alias BarkparkWeb.Studio.Desk.ReviewChanges
  alias BarkparkWeb.Studio.Desk.SlugInUse

  attr :field, :any, default: nil, doc: "the schema field the menu is for; none draws no menu"

  attr :caps, :any,
    default: nil,
    doc: "the editor's capabilities: who may paste into a read-only field"

  attr :problem, :map, default: nil, doc: "the field's taken slug (`SlugInUse.problem/2`)"

  attr :review, :string,
    default: nil,
    doc: "where the change bar leads; nil: the field is unchanged"

  @doc "The change bar's place and the Field actions menu, as children of a `.field`."
  def slots(assigns) do
    assigns = assign(assigns, :name, name(assigns.field))

    ~H"""
    <button
      :if={@review}
      type="button"
      class="change-bar"
      aria-label={pgettext("change bar", "Review changes")}
      title={pgettext("change bar", "Review changes")}
      phx-click={Phoenix.LiveView.JS.patch(@review)}
      data-desk-change-bar
    >
    </button>
    <span :if={!@review} class="change-bar" data-desk-change-bar hidden></span>
    <FieldActions.menu :if={@name} name={@name} paste={FieldActions.paste?(@field, @caps)} />
    """
  end

  attr :field, :any, default: nil
  attr :caps, :any, default: nil
  attr :problem, :map, default: nil
  attr :review, :string, default: nil

  @doc "The mark in the field's label, when its slug is in use."
  def mark(assigns), do: SlugInUse.mark(assigns)

  @doc "The field with the editor's capabilities on it, for `editor_field/1`'s `slots`."
  @spec of(map(), map()) :: map()
  def of(field, parent_assigns) do
    %{
      field: field,
      caps: Map.get(parent_assigns, :caps),
      problem: SlugInUse.problem(parent_assigns, name(field)),
      review: ReviewChanges.bar(parent_assigns, name(field))
    }
  end

  defp name(%{"name" => name}) when is_binary(name) and name != "", do: name
  defp name(_field), do: nil
end
