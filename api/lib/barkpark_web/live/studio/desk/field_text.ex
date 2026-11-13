defmodule BarkparkWeb.Studio.Desk.FieldText do
  @moduledoc """
  A field's value as a read-only document pane prints it.

  Rich text reads as its text, a paragraph per block: a PortableDoc value
  (`%{"blocks" => [...]}`, text nodes `%{"type" => "text", "value" => ...}`)
  and Sanity-style portable text (a list of `_type: "block"` with span
  `children`). Anything else structured prints as JSON, cut at 600 characters.
  """

  @max 600

  @doc "The text a read-only pane prints for `value`."
  @spec show(term()) :: String.t()
  def show(nil), do: "—"
  def show(""), do: "—"
  def show(value) when is_binary(value), do: value
  def show(value) when is_number(value) or is_boolean(value), do: to_string(value)

  def show(value) do
    case rich_text(value) do
      nil -> cut(Jason.encode!(value, pretty: true))
      "" -> "—"
      text -> cut(text)
    end
  end

  defp cut(text) do
    if String.length(text) > @max, do: String.slice(text, 0, @max) <> " …", else: text
  end

  defp rich_text(%{"blocks" => blocks}) when is_list(blocks), do: paragraphs(blocks)

  defp rich_text([%{"_type" => "block"} | _] = blocks), do: paragraphs(blocks)

  defp rich_text(_value), do: nil

  defp paragraphs(blocks) do
    blocks
    |> Enum.map(&(&1 |> inline() |> String.trim()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  # The text of one block, its leaves in order.
  defp inline(%{"type" => "text", "value" => value}) when is_binary(value), do: value
  defp inline(%{"_type" => "span", "text" => text}) when is_binary(text), do: text

  # A run of spans is one line of text (a bold word sits flush with the next);
  # nested blocks (list items, a card's body) are separate words.
  defp inline(%{} = node) do
    runs = join(Enum.flat_map(["content", "children"], &List.wrap(node[&1])), "")
    nested = join(Enum.flat_map(["items", "blocks"], &List.wrap(node[&1])), " ")
    join_text([runs, nested], " ")
  end

  defp inline(_other), do: ""

  defp join(nodes, sep), do: nodes |> Enum.map(&inline/1) |> join_text(sep)

  defp join_text(parts, sep), do: parts |> Enum.reject(&(&1 == "")) |> Enum.join(sep)
end
