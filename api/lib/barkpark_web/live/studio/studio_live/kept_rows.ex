defmodule BarkparkWeb.Studio.StudioLive.KeptRows do
  @moduledoc """
  A kept row's `_json` counts only where the editor drew one
  (task-7655868c8b346c43, #26168 review).

  A stored object or list in a list of plain values has no input.
  `ArrayField` draws it as it is, with a hidden input `…[0][_json]` holding
  its JSON, and `Forms.coerce_params/2` saves that JSON back as the row.

  The hidden input is drawn only for a row that already holds a map or a
  list. `only_stored/2` holds a post to that: a `_json` posted at a place
  where the form buffer holds anything else (a string row, an empty row, no
  row) is not a kept row, and the buffer's own value is posted there instead.
  """

  @doc "`params` (the event's params, `doc` folded) checked against `form`, the form buffer."
  def only_stored(%{"doc" => %{} = doc} = params, form),
    do: Map.put(params, "doc", walk(doc, if(is_map(form), do: form, else: %{})))

  def only_stored(params, _form), do: params

  defp walk(%{"_json" => json} = posted, stored) when is_binary(json) do
    if is_map(stored) or is_list(stored), do: posted, else: stored
  end

  defp walk(%{} = posted, stored),
    do: Map.new(posted, fn {key, value} -> {key, walk(value, child(stored, key))} end)

  defp walk(posted, stored) when is_list(posted) do
    posted
    |> Enum.with_index()
    |> Enum.map(fn {value, index} -> walk(value, child(stored, index)) end)
  end

  defp walk(posted, _stored), do: posted

  defp child(%{} = stored, key), do: Map.get(stored, key)
  defp child(stored, index) when is_list(stored) and is_integer(index), do: Enum.at(stored, index)

  defp child(stored, key) when is_list(stored) and is_binary(key) do
    case Integer.parse(key) do
      {index, ""} when index >= 0 -> Enum.at(stored, index)
      _ -> nil
    end
  end

  defp child(_stored, _key), do: nil
end
