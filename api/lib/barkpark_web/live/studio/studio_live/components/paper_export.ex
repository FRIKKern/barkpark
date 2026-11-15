defmodule BarkparkWeb.Studio.StudioLive.Components.PaperExport do
  @moduledoc """
  The Export button in the Studio paper header (task-a5ba0a62b64635ac).

  A paper left the Studio only as JSON (`bp paper export`). The button opens a
  menu with Download Markdown, Copy as Markdown and Print / Save as PDF. The
  menu itself is `priv/static/assets/bp-paper-export.js`; this component renders
  the button and what that script reads:

      data-paper-export-editor   the editor root's id, where the canvases are
      data-paper-export-file     the file name, without `.md` (the published id)
      data-paper-export-title    the paper's title, the file's H1
      data-paper-export-blocks   the blocks no canvas holds, in order, as saved
      data-paper-export-print    the reader page Print opens; absent when the
                                 paper was never published
      data-paper-export-print-state  "published" | "draft"

  Each canvas converts its own run of prose in the browser, unsaved typing
  included. A block between runs (a table, steps, tabs, a figure) keeps its own
  editor and is in no canvas, so it rides `data-paper-export-blocks`:
  `PaperCanvas.partition_runs/2` decides which, as it does for the editor. With
  the canvas switched off there are no runs and every block rides it.

  The wrapper is `phx-update="ignore"` so a LiveView patch does not reset the
  button's `aria-expanded`; LiveView still updates the wrapper's own `data-*`
  attributes, which is where everything that changes lives.

  It only reads. The export holds what this viewer already sees in the editor,
  and Print opens the same reader page as "Open standalone". A Table the table
  editor can edit rides as that editor's projection, so its cells carry no
  inline source metadata (`_key`, producer fields) the editor keeps off the
  page either (`Barkpark.PortableDoc.TableEditing.project/1`).
  """
  use BarkparkWeb, :html

  alias Barkpark.Content
  alias Barkpark.PortableDoc.TableEditing
  alias BarkparkWeb.Studio.StudioLive.{PaperCanvas, Paths}

  attr(:slug, :string, required: true)
  attr(:title, :string, default: "")
  attr(:blocks, :list, default: [])
  attr(:retained, :any, default: nil)
  attr(:scope_prefix, :string, default: "")
  attr(:draft, :boolean, default: false)
  attr(:has_published, :boolean, default: false)

  def export_button(assigns) do
    published_id = Content.published_id(assigns.slug)

    assigns =
      assign(assigns,
        file: published_id,
        kept:
          Jason.encode!(blocks_outside_canvases(assigns.blocks, assigns.retained, assigns.slug)),
        print_href:
          if(not assigns.draft or assigns.has_published,
            do: Paths.paper_path(assigns.scope_prefix, published_id)
          ),
        print_state: if(assigns.draft, do: "draft", else: "published")
      )

    ~H"""
    <div
      id={"paper-export-#{@slug}"}
      class="bp-paper-export"
      phx-update="ignore"
      data-paper-export
      data-paper-export-editor={"paper-editor-#{@slug}"}
      data-paper-export-file={@file}
      data-paper-export-title={@title}
      data-paper-export-blocks={@kept}
      data-paper-export-print={@print_href}
      data-paper-export-print-state={@print_state}
    >
      <button
        type="button"
        class="btn btn-ghost btn-sm"
        aria-haspopup="menu"
        aria-expanded="false"
        data-paper-export-toggle
        data-test-id="paper-export"
      >
        <.icon name="download" size={14} /> {gettext("Export")}
      </button>
    </div>
    """
  end

  @doc """
  The top-level blocks the editor renders outside every canvas, in document
  order, each as the export may hold it (`export_block/1`).
  """
  @spec blocks_outside_canvases([map()], term(), String.t()) :: [map()]
  def blocks_outside_canvases(blocks, retained, slug) when is_list(blocks) do
    if PaperCanvas.paper_canvas_enabled?() do
      retained_ids = PaperCanvas.retained_ids(retained, slug)

      for {:block, block} <- PaperCanvas.partition_runs(blocks, retained_ids),
          do: export_block(block)
    else
      Enum.map(blocks, &export_block/1)
    end
  end

  def blocks_outside_canvases(_blocks, _retained, _slug), do: []

  @doc """
  A block as the export holds it. A Table the table editor projects keeps its
  id, its head and rows and each cell's `align`, with each cell's inline as the
  projection has it; any other block is as saved.
  """
  @spec export_block(term()) :: term()
  def export_block(%{"type" => "table", "rows" => rows} = table) do
    case TableEditing.project(table) do
      {:ok, %{head: head, rows: projected}} ->
        %{
          "id" => table["id"],
          "type" => "table",
          "rows" => Enum.zip_with(rows, projected, &row/2)
        }
        |> put_head(table["head"], head)

      {:error, _} ->
        table
    end
  end

  def export_block(block), do: block

  defp put_head(block, _saved, nil), do: block
  defp put_head(block, saved, head), do: Map.put(block, "head", cells(saved, head))

  defp row(%{"cells" => saved}, inline), do: %{"cells" => cells(saved, inline)}
  defp row(saved, inline), do: cells(saved, inline)

  defp cells(saved, inline), do: Enum.zip_with(saved, inline, &cell/2)

  defp cell(%{"align" => align}, inline) when align in ["center", "right"],
    do: %{"content" => inline, "align" => align}

  defp cell(_saved, inline), do: inline
end
