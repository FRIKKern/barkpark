defmodule BarkparkWeb.Studio.StudioLive.KeptCodes do
  @moduledoc """
  A top-level codelist whose stored value is not a code keeps it until the
  person changes that field (task-244b9a6f67d38779).

  A codelist stores a code, a string. A document can hold something else
  there (a number, an object, a list), written by an import or the API. The
  flat select and the combobox can only show a string, so they show "Not a
  code" (`CodelistField`, `:kept`) and post "" for the field with every
  change of the form; that "" took the key off the document on an edit to any
  other field.

  `only_touched/3` drops the field's posted value unless this post is a
  change of that field (`_target` names it). So an edit elsewhere, or the
  Save button's post (which names no field), leaves the stored value as it
  is, and a pick or a clear in the field itself is written as before. A field
  whose stored value is a string, or none, is not touched here.
  """

  @doc """
  `params` (the event's params, `doc` folded) with each posted top-level
  codelist value dropped whose stored value in `form` (the form buffer) is
  not a string and whose field this post did not change. `schema` is the
  editor's schema (its `fields`).
  """
  def only_touched(%{"doc" => %{} = doc} = params, form, schema) when is_map(form) do
    changed = changed_key(params)

    kept =
      for %{"type" => "codelist", "name" => name} when is_binary(name) <- fields(schema),
          name != changed,
          Map.has_key?(doc, name),
          stored <- [Map.get(form, name)],
          not is_nil(stored) and not is_binary(stored),
          do: name

    Map.put(params, "doc", Map.drop(doc, kept))
  end

  def only_touched(params, _form, _schema), do: params

  # The top-level field this change came from: `doc[flat]` arrives as
  # `["doc", "flat"]`.
  defp changed_key(%{"_target" => ["doc", key | _]}) when is_binary(key), do: key
  defp changed_key(_params), do: nil

  defp fields(%{fields: fields}) when is_list(fields), do: fields
  defp fields(%{"fields" => fields}) when is_list(fields), do: fields
  defp fields(_schema), do: []
end
