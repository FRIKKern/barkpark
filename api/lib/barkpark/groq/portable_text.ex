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

  @doc """
  `pt::text()` of a declared richText field stored as PortableDoc
  (`%{"blocks" => [...]}` or the bare block list), read as Sanity reads the
  Portable Text it maps from: its text blocks (`paragraph`, `heading`,
  `pullquote`, `blockquote`, and each `list` item as its own block) joined
  with a blank line. Inline `text` values count, and the text inside marks
  and links; an inline object counts as "", as a non-span child does in
  Sanity. A custom object block (a callout, a chart) counts as nothing, as
  Sanity's non-`block` blocks do.
  """
  @spec doc_text(term()) :: String.t() | nil
  def doc_text(%{"blocks" => blocks}), do: doc_text(blocks)

  def doc_text(blocks) when is_list(blocks) do
    case Enum.flat_map(blocks, &doc_block_texts/1) do
      [] -> nil
      texts -> Enum.join(texts, "\n\n")
    end
  end

  def doc_text(_), do: nil

  @prose ~w(paragraph heading pullquote blockquote)

  defp doc_block_texts(%{"type" => type, "content" => content}) when type in @prose,
    do: [inline_text(content)]

  defp doc_block_texts(%{"type" => "list", "items" => items}) when is_list(items),
    do: Enum.map(items, &list_item_text/1)

  defp doc_block_texts(_block), do: []

  defp list_item_text(%{"content" => content}), do: inline_text(content)
  defp list_item_text(content), do: inline_text(content)

  defp inline_text(nodes) when is_list(nodes), do: Enum.map_join(nodes, &inline_text/1)
  defp inline_text(%{"type" => "text", "value" => v}) when is_binary(v), do: v
  defp inline_text(%{"children" => children}) when is_list(children), do: inline_text(children)
  defp inline_text(_node), do: ""
end
