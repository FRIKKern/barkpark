defmodule BarkparkWeb.Studio.StudioLive.KeptCodes do
  @moduledoc """
  A codelist whose stored value is not a code keeps it until the person
  changes that field, or that row (task-244b9a6f67d38779,
  task-63404d06a6b5259d).

  A codelist stores a code, a string. A document can hold something else
  there (a number, an object, a list), written by an import or the API. The
  flat select and the combobox can only show a string, so they show "Not a
  code" (`CodelistField`, `:kept`) and post "" for the field with every
  change of the form; that "" took the key off the document on an edit to any
  other field. An array of codelist values has one such control per row, and
  turned `[7, {o: 1}, "A1"]` into `["", "", "A1"]` the same way.

  `only_touched/3`, for a top-level codelist and a top-level array of
  codelist values:

    * A codelist: its posted value is dropped unless this post is a change
      of that field (`_target` names it).
    * An array: each posted row whose stored row is not a code is posted as
      the stored row, unless this post is a change of that row. A write of
      the whole field (`_target` names the field and no row: Review
      changes' Revert, Paste) is its own change, written as posted.

  A top-level `datetime` stored as something other than a string (a number
  of epoch ms) is kept the same way as a codelist: the desk's date box shows
  it empty and posts "".

  So an edit elsewhere, or the Save button's post (which names no field),
  leaves the stored value as it is, and a pick or a clear in the field or the
  row itself is written as before. A value or row that is a string, or none,
  is not touched here.
  """

  @doc """
  `params` (the event's params, `doc` folded) with each posted top-level
  codelist value, and each posted row of a top-level array of codelist
  values, put back to what `form` (the form buffer) holds where that is not
  a string and this post did not change it. `schema` is the editor's schema
  (its `fields`).
  """
  def only_touched(%{"doc" => %{} = doc} = params, form, schema) when is_map(form) do
    changed = changed_path(params)
    doc = Enum.reduce(fields(schema), doc, &keep(&1, &2, form, changed))
    Map.put(params, "doc", doc)
  end

  def only_touched(params, _form, _schema), do: params

  # A datetime holds a string. One stored as something else (a number of
  # epoch ms, from an import or the API) is drawn as an empty box
  # (`DeskDatetime`), which posts "", so it is kept the same way.
  defp keep(%{"type" => type, "name" => name}, doc, form, changed)
       when type in ["codelist", "datetime"] and is_binary(name) do
    if Map.has_key?(doc, name) and not match?([^name | _], changed) and
         kept?(Map.get(form, name)),
       do: Map.delete(doc, name),
       else: doc
  end

  defp keep(
         %{"type" => "arrayOf", "name" => name, "of" => %{"type" => "codelist"}},
         doc,
         form,
         changed
       )
       when is_binary(name) do
    stored = Map.get(form, name)
    row = with [^name, index | _] <- changed, do: index, else: (_ -> nil)

    case Map.get(doc, name) do
      # The whole field written at once (Review changes' Revert, Paste,
      # Paste document): that write is the field's own change. No browser
      # post names an array without a row.
      _ when changed == [name] ->
        doc

      posted when is_list(stored) and (is_map(posted) or is_list(posted)) ->
        Map.put(doc, name, rows(posted, stored, row))

      _ ->
        doc
    end
  end

  defp keep(_field, doc, _form, _changed), do: doc

  # The posted rows (index-keyed, as `doc[codes][1]` arrives, or a list),
  # each that holds no code in the buffer and is not the changed row put back
  # to the buffer's row.
  defp rows(%{} = posted, stored, changed) do
    Map.new(posted, fn {key, value} -> {key, row(value, key, stored, changed)} end)
  end

  defp rows(posted, stored, changed) when is_list(posted) do
    posted
    |> Enum.with_index()
    |> Enum.map(fn {value, index} -> row(value, to_string(index), stored, changed) end)
  end

  defp row(value, key, _stored, key), do: value

  defp row(value, key, stored, _changed) do
    held =
      case Integer.parse(key) do
        {index, ""} when index >= 0 -> Enum.at(stored, index)
        _ -> nil
      end

    if kept?(held), do: held, else: value
  end

  defp kept?(value), do: not is_nil(value) and not is_binary(value)

  # The path this change came from, under `doc`: `doc[flat]` arrives as
  # `["doc", "flat"]`, a row `doc[codes][1]` as `["doc", "codes", "1"]`.
  defp changed_path(%{"_target" => ["doc" | path]}) when is_list(path), do: path
  defp changed_path(_params), do: []

  defp fields(%{fields: fields}) when is_list(fields), do: fields
  defp fields(%{"fields" => fields}) when is_list(fields), do: fields
  defp fields(_schema), do: []
end
