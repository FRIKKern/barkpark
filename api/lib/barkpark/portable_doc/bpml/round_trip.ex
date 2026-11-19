defmodule Barkpark.PortableDoc.Bpml.RoundTrip do
  @moduledoc """
  The printer checks itself: a print stands only when parsing it back gives the
  blocks that were printed.

  `Printer.print_blocks/1` and `Printer.print_paper/1` hand every finished print
  here. When the parse of the print equals `Canonical.normalize(blocks)` (the
  blocks with the printer's five rewrites made), the print is returned as it
  was. When it does not, the first place where the two part is named by its
  block path (`blocks[2].items[0].children`) and the print is refused with an
  `UnprintableError` of kind `:round_trip`, so no caller writes or serves a text
  that holds less than the document.

  There is no list of shapes here. The parser is the only judge of what the
  text carries.
  """

  alias Barkpark.PortableDoc.Bpml.{Canonical, Parser, UnprintableError}

  @doc "The print, or a refusal naming the block path the text does not carry."
  @spec check!([map()], String.t(), :blocks | :paper) :: String.t()
  def check!(blocks, printed, form) do
    case first_loss(blocks, printed, form) do
      nil -> printed
      path -> raise UnprintableError.new(:round_trip, path)
    end
  end

  @doc """
  `nil` when parsing `printed` gives back `blocks` (after the five rewrites),
  else the block path of the first difference.
  """
  @spec first_loss([map()], String.t(), :blocks | :paper) :: String.t() | nil
  def first_loss(blocks, printed, form) do
    expected = Canonical.normalize(blocks)

    case parse(printed, form) do
      {:ok, ^expected} -> nil
      {:ok, parsed} -> diff_path(expected, parsed, "blocks")
      {:error, _errors} -> "blocks"
    end
  end

  defp parse(printed, :blocks), do: Parser.parse_blocks(printed)

  defp parse(printed, :paper) do
    with {:ok, paper} <- Parser.parse_paper(printed), do: {:ok, Map.get(paper, "blocks", [])}
  end

  @doc false
  # The first path where `a` (the document) and `b` (its parsed print) part.
  @spec diff_path(term(), term(), String.t()) :: String.t() | nil
  def diff_path(same, same, _path), do: nil

  def diff_path(a, b, path) when is_list(a) and is_list(b) do
    pairs = Enum.zip(a, b)

    Enum.find_value(Enum.with_index(pairs), fn {{x, y}, i} ->
      diff_path(x, y, "#{path}[#{i}]")
    end) || "#{path}[#{length(pairs)}]"
  end

  def diff_path(a, b, path) when is_map(a) and is_map(b) do
    (Map.keys(a) ++ Map.keys(b))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.find_value(fn key ->
      case {Map.fetch(a, key), Map.fetch(b, key)} do
        {same, same} -> nil
        {{:ok, x}, {:ok, y}} -> diff_path(x, y, "#{path}.#{key}")
        _ -> "#{path}.#{key}"
      end
    end)
  end

  def diff_path(_a, _b, path), do: path
end
