defmodule Barkpark.Plugins.Sheets.Markdown do
  @moduledoc """
  Sheet-document content → GitHub-flavored Markdown tables (M5) — one table
  per tab, LOSSY BY DESIGN: values only. Formulas flatten to their cached
  value, and merges / styles / number formats / column widths do not travel
  (a GitHub table has nowhere to put them).

  The grid is the same dense projection every other read surface uses
  (`Barkpark.Plugins.Sheets.Core.snapshot_for/2`): a frozen first row becomes the table
  header; without one the header is synthesized column letters (A, B, …) —
  a GitHub table requires a header row. Pipes escape as `\\|`; embedded
  line breaks flatten to spaces. Tab headings (`## name`) appear when a tab
  is named or when the document has several tabs.
  """

  alias Barkpark.Plugins.Sheets.Core, as: Core

  @doc "Render every tab as a Markdown section."
  @spec export(map()) :: String.t()
  def export(content) do
    tabs =
      case content do
        %{"tabs" => tabs} when is_list(tabs) -> tabs
        _ -> []
      end

    tabs
    |> Enum.with_index()
    |> Enum.map(fn {tab, index} -> section(content, tab, index, length(tabs)) end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp section(content, tab, index, tab_count) do
    snapshot = Core.snapshot_for(content, index)

    {head, rows} =
      case snapshot do
        %{"head" => head} -> {head, Map.get(snapshot, "rows", [])}
        %{"rows" => [first | _] = rows} -> {column_letters(length(first)), rows}
        _ -> {[], []}
      end

    table = if head == [], do: "", else: table(head, rows)

    case heading(tab, index, tab_count) do
      "" -> table
      heading when table == "" -> heading
      heading -> heading <> "\n" <> table
    end
  end

  defp heading(tab, index, tab_count) do
    case is_map(tab) and Map.get(tab, "name") do
      name when is_binary(name) and name != "" -> "## #{escape(name)}\n"
      _ when tab_count > 1 -> "## Sheet#{index + 1}\n"
      _ -> ""
    end
  end

  defp table(head, rows) do
    header = "| " <> Enum.map_join(head, " | ", &escape/1) <> " |"
    divider = "| " <> Enum.map_join(head, " | ", fn _ -> "---" end) <> " |"
    body = Enum.map(rows, fn row -> "| " <> Enum.map_join(row, " | ", &escape/1) <> " |" end)

    Enum.join([header, divider | body], "\n") <> "\n"
  end

  defp column_letters(count) when count >= 1 do
    Enum.map(1..count, fn col ->
      {col, 1} |> Core.format_ref() |> String.trim_trailing("1")
    end)
  end

  defp column_letters(_), do: []

  defp escape(value) do
    value
    |> String.replace("|", "\\|")
    |> String.replace(["\r\n", "\n", "\r"], " ")
  end
end
