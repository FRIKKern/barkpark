defmodule Barkpark.Groq.PortableText do
  @moduledoc """
  `pt::text()`: the plain text of Portable Text blocks, ported from groq-js
  `evaluator/pt.ts`. Blocks are joined with a blank line; only `span` children
  with string `text` contribute.
  """

  @spec text(term()) :: String.t() | nil
  def text(%{} = block), do: block_text(block)

  def text(list) when is_list(list) do
    case array_text(list, []) do
      [] -> nil
      texts -> texts |> Enum.reverse() |> Enum.join("\n\n")
    end
  end

  def text(_), do: nil

  defp array_text(list, acc) do
    Enum.reduce(list, acc, fn
      nested, acc when is_list(nested) ->
        array_text(nested, acc)

      %{} = block, acc ->
        case block_text(block) do
          nil -> acc
          text -> [text | acc]
        end

      _, acc ->
        acc
    end)
  end

  defp block_text(%{"_type" => type, "children" => children})
       when is_binary(type) and is_list(children) do
    Enum.map_join(children, fn
      %{"_type" => "span", "text" => text} when is_binary(text) -> text
      _ -> ""
    end)
  end

  defp block_text(_), do: nil
end
