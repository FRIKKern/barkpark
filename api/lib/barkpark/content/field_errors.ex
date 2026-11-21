defmodule Barkpark.Content.FieldErrors do
  @moduledoc """
  Findings onto the legacy field-keyed errors map a refused write answers
  with (`%{"meny" => ["…"]}`), beside the `findings` list. Used by
  `Barkpark.Content.Writer` for the schema's cross findings.
  """

  @doc """
  Adds each finding's message under its top-level field, after what `errors`
  already holds there, in finding order. A finding below its field (an item
  rule's `/meny/1/side`) carries its path in the message, as array validation
  messages do (`"/meny/1/side: …"`); one at the field itself does not.

  Grouped first, then each field's list appended once: linear in the
  findings (one `++` per finding made it quadratic for many broken items).
  """
  @spec add_findings(map(), [%{path: String.t(), message: String.t()}]) :: map()
  def add_findings(errors, findings) do
    findings
    |> Enum.reduce(%{}, fn f, by ->
      key = top_level_field(f.path)
      msg = if f.path == "/" <> (key || ""), do: f.message, else: "#{f.path}: #{f.message}"
      Map.update(by, key, [msg], &[msg | &1])
    end)
    |> Enum.reduce(errors, fn {key, rev}, acc ->
      msgs = Enum.reverse(rev)
      Map.update(acc, key, msgs, &(List.wrap(&1) ++ msgs))
    end)
  end

  defp top_level_field("/" <> rest), do: rest |> String.split("/") |> List.first()
  defp top_level_field(_), do: nil
end
