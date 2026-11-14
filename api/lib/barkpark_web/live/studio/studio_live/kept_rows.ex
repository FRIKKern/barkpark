defmodule BarkparkWeb.Studio.StudioLive.KeptRows do
  @moduledoc """
  A kept row's `_json` counts only for a row the form buffer holds
  (task-7655868c8b346c43, #26168 review).

  A stored object or list in a list of plain values has no input.
  `ArrayField` draws it as it is, with a hidden input `…[0][_json]` holding
  its JSON, and `Forms.coerce_params/2` saves that JSON back as the row.

  `only_stored/2` checks each posted `_json` against the form buffer's list
  it sits in:

  1. The buffer holds that row, at any index (another editor's save may have
     moved it since the page drew it): the post stands.
  2. The buffer holds a row with the same `_key` and other content: the
     buffer's row is posted in its place.
  3. Neither, and the buffer holds a row at that index: the buffer's row is
     posted there (a string row stays the string).
  4. Neither, and the buffer has no row there (another editor removed it):
     the element is dropped. No empty row is written.

  So a `_json` can only ever write a value the buffer already holds.
  """

  @doc "`params` (the event's params, `doc` folded) checked against `form`, the form buffer."
  def only_stored(%{"doc" => %{} = doc} = params, form),
    do: Map.put(params, "doc", rows(doc, if(is_map(form), do: form, else: %{})))

  def only_stored(params, _form), do: params

  defp walk(%{"_json" => json}, stored, siblings) when is_binary(json) do
    row =
      case Jason.decode(json) do
        {:ok, row} when is_map(row) or is_list(row) -> row
        _ -> nil
      end

    cond do
      row != nil and row in siblings -> %{"_json" => json}
      same = row != nil && same_key(siblings, row) -> %{"_json" => Jason.encode!(same)}
      is_map(stored) or is_list(stored) -> %{"_json" => Jason.encode!(stored)}
      is_nil(stored) -> :drop
      true -> stored
    end
  end

  defp walk(posted, stored, _siblings) when is_map(posted) or is_list(posted),
    do: rows(posted, stored)

  defp walk(posted, _stored, _siblings), do: posted

  # The rows of a posted map (index-keyed for a list) or list, against the
  # buffer's value at the same place.
  defp rows(%{} = posted, stored) do
    siblings = if is_list(stored), do: stored, else: []

    for {key, value} <- posted,
        kept = walk(value, child(stored, key), siblings),
        kept != :drop,
        into: %{},
        do: {key, kept}
  end

  defp rows(posted, stored) when is_list(posted) do
    siblings = if is_list(stored), do: stored, else: []

    posted
    |> Enum.with_index()
    |> Enum.map(fn {value, index} -> walk(value, child(stored, index), siblings) end)
    |> Enum.reject(&(&1 == :drop))
  end

  defp same_key(siblings, %{"_key" => key}) when is_binary(key),
    do: Enum.find(siblings, &match?(%{"_key" => ^key}, &1))

  defp same_key(_siblings, _row), do: nil

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
