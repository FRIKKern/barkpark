defmodule BarkparkWeb.Studio.Desk.FieldLock do
  @moduledoc """
  A field made read-only by a condition (`"readOnly" => %{"field" => "stage",
  "operator" => "eq", "value" => "done"}`), as the desk draws it.

  While the condition holds the field is locked for every viewer, admin or
  not, as in the TanStack Studio and Sanity: it is editor behaviour, and the
  way to unlock it is to change the field the condition reads.

  HOW A LOCKED FIELD POSTS. On purpose, two ways:

    * A text field (#{inspect(~w(string text url email slug number))}) keeps its
      input and gets the `readonly` attribute. A `readonly` input still posts,
      and it posts the value the form drew, so the save writes the stored
      value back unchanged. The text stays focusable and selectable.
    * Any other type is drawn display-only with no input at all
      (`FieldInputs`' read-only clause). Nothing is posted and the save keeps
      the stored value. A checkbox or a select ignores `readonly`, and
      `disabled` on a switch would drop its hidden `false`.

  A field that declares `"readOnly" => true` is not touched here: an admin
  keeps its input and a non-admin sees it display-only, as the server's write
  rule (`Barkpark.Content.ReadOnlyFields`) has it.

  The marker is the render-time key `"lockedByRule"`. It is never stored.
  """

  alias Barkpark.Content.ReadOnlyFields

  @text_types ~w(string text url email slug number)

  @doc """
  `field` with a conditional `readOnly` resolved against `form`.

  Outside the desk this is `ReadOnlyFields.resolve_for/2`. In the desk a held
  condition also sets `"lockedByRule" => true`; a text field then keeps its
  input (`"readOnly" => false`), any other type is display-only
  (`"readOnly" => true`).
  """
  @spec resolve(map(), map() | nil, boolean()) :: map()
  def resolve(%{"readOnly" => %{} = rule} = field, form, true) when map_size(rule) > 0 do
    case ReadOnlyFields.resolve_for(field, form) do
      %{"readOnly" => true} = locked ->
        locked
        |> Map.put("lockedByRule", true)
        |> Map.put("readOnly", not text?(field))

      open ->
        open
    end
  end

  def resolve(field, form, _desk?), do: ReadOnlyFields.resolve_for(field, form)

  @doc "Whether `field` is locked by its condition (set by `resolve/3`)."
  @spec locked?(map()) :: boolean()
  def locked?(%{"lockedByRule" => true}), do: true
  def locked?(_field), do: false

  defp text?(%{"type" => type}), do: type in @text_types
  defp text?(_field), do: false
end
