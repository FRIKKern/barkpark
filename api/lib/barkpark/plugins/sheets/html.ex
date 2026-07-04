defmodule Barkpark.Plugins.Sheets.Html do
  @moduledoc """
  Sheet-document content → a standalone minimal HTML page (M5).

  Every tab renders through the SAME path the reader uses: the tab's
  snapshot (`Barkpark.Plugins.Sheets.Core.snapshot_for/2`) composed as a `"sheet"`
  portable-doc block and walked by `Barkpark.PortableDoc.Render` in the
  article palette — so merges (colspan/rowspan) and basic styles paint
  exactly as they do at `/papers/:slug`, with zero renderer duplication.
  The page is self-contained: inline styles only, no external CSS, no
  scripts.
  """

  alias Barkpark.PortableDoc.Render
  alias Barkpark.PortableDoc.Render.Stylesheet
  alias Barkpark.Plugins.Sheets.Core, as: Core

  @doc "Render the content as a full standalone HTML page."
  @spec export(map(), String.t() | nil) :: String.t()
  def export(content, title \\ nil) do
    tabs =
      case content do
        %{"tabs" => tabs} when is_list(tabs) -> tabs
        _ -> []
      end

    sections =
      tabs
      |> Enum.with_index()
      |> Enum.map_join("", fn {tab, index} -> section(content, tab, index, length(tabs)) end)

    title = escape(title_or_default(title))

    # The canonical paper-surface stylesheet is inlined here so the standalone
    # export is self-contained (no <link>). Additive today — the sheet renders
    # via inline article styles — and load-bearing once the sheet chrome goes
    # class-based (wave 2), when these `.bp-paper-surface` rules drive it.
    ~s(<!doctype html><html><head><meta charset="utf-8"><title>#{title}</title>) <>
      ~s(<style>#{Stylesheet.css()}</style></head>) <>
      ~s(<body style="margin:2rem auto;max-width:960px;padding:0 1rem;) <>
      ~s(font-family:Georgia,'Source Serif 4',serif;color:#1a1a1a;background:#fbfaf6">) <>
      ~s(<h1 style="font-size:1.6rem">#{title}</h1>) <>
      sections <> "</body></html>"
  end

  defp section(content, tab, index, tab_count) do
    block = %{
      "id" => "tab-#{index}",
      "type" => "sheet",
      "snapshot" => Core.snapshot_for(content, index)
    }

    # Stage-2 wave 2: the sheet CHROME (band/cell rules, mono font) is now
    # class-based (`.bp-paper-surface .bp-sheet__*`), so the standalone export
    # must place the table INSIDE `.bp-paper-surface` for those rules — inlined
    # in <head> above — to resolve. The wrapper is scoped to the table alone so
    # the export's own <h1>/<h2> chrome is untouched. Author DATA (widths,
    # b/i/bg/al, error mark) still rides inline and works with no stylesheet.
    table =
      ~s(<div class="bp-paper-surface">) <>
        Render.render_block(block, %{style: :article}) <> "</div>"

    case heading(tab, index, tab_count) do
      "" -> table
      heading -> heading <> table
    end
  end

  defp heading(tab, index, tab_count) do
    case is_map(tab) and Map.get(tab, "name") do
      name when is_binary(name) and name != "" ->
        ~s(<h2 style="font-size:1.1rem;margin:1.6rem 0 0.6rem">#{escape(name)}</h2>)

      _ when tab_count > 1 ->
        ~s(<h2 style="font-size:1.1rem;margin:1.6rem 0 0.6rem">Sheet#{index + 1}</h2>)

      _ ->
        ""
    end
  end

  defp title_or_default(title) when is_binary(title) and title != "", do: title
  defp title_or_default(_), do: "Sheet"

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
