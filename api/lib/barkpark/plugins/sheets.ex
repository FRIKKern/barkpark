defmodule Barkpark.Plugins.Sheets do
  @moduledoc """
  Sheets — collaborative spreadsheet surface, as a first-party plugin.

  Sheets stores multi-tab spreadsheet documents as type-`"sheet"` documents.
  Each sheet carries a title, a locale (for number/date formatting), and an
  ordered list of tabs. Each tab holds grid-layout metadata (frozen rows/cols,
  column widths, row heights) and a sparse cell map keyed by cell address
  (e.g. `"A1"`). Cell descriptors carry the raw value (`v`), an optional
  formula string (`f`), a type discriminator (`t`: `"s"` string, `"n"`
  number, `"b"` boolean, `"e"` error), a format string (`fmt`), and a
  stale flag (`stale`) indicating the formula cache needs recomputation.

  ## What this module contributes

    * `register_schemas/1` — the `sheet` document type (read from
      `priv/plugins/sheets/schemas/sheet.json`). Auto-registers on every boot
      via `Barkpark.Plugins.Bootstrap.register_all_schemas/0`, idempotent on
      `(name, dataset)`.

    * `lifecycle_hooks/0` — a `before_save` structural gate that rejects sheet
      documents whose `cells` map carries a non-A1 key, a cell descriptor
      that is not a map, or a ref beyond the Excel grid bounds (column
      XFD/16,384, row 1,048,576), and whose `merges` list carries a
      malformed range, a range covering more than `merge_area_cap/0` cells,
      or a corner beyond the same grid bounds.

    * `register_routes/1` (M5) — the conversion API on the `:ingest` bucket
      (shared-secret bearer via `RequireIngestToken`, like Bulldocs):
      `POST /v1/plugins/sheets/import` (multipart xlsx/csv/tsv → sheet doc)
      and `GET /v1/plugins/sheets/:slug/export.{xlsx,csv,tsv,md,html}`.
      Conversion modules live under `Barkpark.Plugins.Sheets.*`
      (`XlsxImport`, `XlsxExport`, `Csv`, `Markdown`, `Html`, `Fmt`) — the
      core stays conversion-free (the Bulldocs split: core keeps the
      reusable machinery, the plugin is the wiring).

  The grid machinery itself is CORE, not plugin: A1 helpers and snapshot
  synthesis live in `Barkpark.Sheets`, the `"sheet"` portable-doc embed block
  composes in `Barkpark.PortableDoc.Render`, and snapshot write-through rides
  the save path in `Barkpark.Content` — so existing embeds keep rendering and
  refreshing with this plugin off (fresh-install invariant).

  The collaborative engine is deferred to later milestones.
  """

  use Barkpark.Plugin, manifest_path: "../../../priv/plugins/sheets/plugin.json"

  alias Barkpark.Content.SchemaDefinition
  alias Barkpark.Sheets, as: SheetCore

  @schemas_dir Path.expand("../../../priv/plugins/sheets/schemas", __DIR__)

  @cell_cap 50_000
  @merge_area_cap 10_000

  # Excel's grid bounds — column XFD, row 1_048_576. Enforced at the gate
  # AFTER parse (see bounds_errors/3), not inside `Barkpark.Sheets.parse_ref/1`:
  # parse_ref stays a pure, total A1 parser (the engine, snapshot synthesis
  # and the importers all call it), and `Barkpark.Sheets.Engine` keeps its
  # own copy of the same bounds for its `#REF!` semantics.
  @grid_max_col 16_384
  @grid_max_row 1_048_576

  @doc "Cap on non-empty cells per sheet import — enforced incrementally by the converters."
  @spec cell_cap() :: pos_integer()
  def cell_cap, do: @cell_cap

  @doc "Cap on a single merge range's area in cells — enforced on save and import."
  @spec merge_area_cap() :: pos_integer()
  def merge_area_cap, do: @merge_area_cap

  @doc "Largest legal column (XFD, the Excel grid bound) — enforced on save and import."
  @spec grid_max_col() :: pos_integer()
  def grid_max_col, do: @grid_max_col

  @doc "Largest legal row (the Excel grid bound) — enforced on save and import."
  @spec grid_max_row() :: pos_integer()
  def grid_max_row, do: @grid_max_row

  @doc """
  Declares the `sheet` document type. Reads `priv/plugins/sheets/schemas/sheet.json`
  at compile time and upserts via Bootstrap on every boot — idempotent on
  `(name, dataset)`, matching the bulldocs pattern.
  """
  @impl Barkpark.Plugin
  def register_schemas(_opts) do
    raw =
      @schemas_dir
      |> Path.join("sheet.json")
      |> File.read!()
      |> Jason.decode!()

    [
      %SchemaDefinition{
        name: Map.fetch!(raw, "name"),
        title: Map.get(raw, "title"),
        icon: Map.get(raw, "icon"),
        visibility: Map.get(raw, "visibility", "private"),
        fields: Map.get(raw, "fields", []),
        dataset: "production"
      }
    ]
  end

  @impl Barkpark.Plugin
  def lifecycle_hooks do
    %{before_save: [&validate_sheet_doc/1]}
  end

  @doc """
  Mounts the M5 conversion API through the plugin route highway
  (`BarkparkWeb.Router.Plugins`), all on the `:ingest` bucket — token-gated
  by `RequireIngestToken`, mounted under `/v1/plugins/sheets/…`:

    * `POST /v1/plugins/sheets/import` — multipart file (`.xlsx`, `.csv`,
      `.tsv`) + optional `slug`/`title`/`dataset` → creates/updates a
      `"sheet"` document (engine recompute + embed write-through ride the
      save path); imports above 50_000 non-empty cells reject with 413.
    * `GET /v1/plugins/sheets/:slug/export.xlsx|csv|tsv|md|html` — sends
      the converted artifact (csv/tsv take `?tab=`, 0-based, default 0).

  Route changes need a forced router recompile — the router macro reads the
  registry at compile time (`MIX_ENV=test mix compile --force`).
  """
  @impl Barkpark.Plugin
  def register_routes(_ctx) do
    import_controller = Barkpark.Plugins.Sheets.Web.ImportController
    export_controller = Barkpark.Plugins.Sheets.Web.ExportController

    [
      {:post, "/sheets/import", import_controller, :create, auth: :ingest},
      {:get, "/sheets/:slug/export.xlsx", export_controller, :export_xlsx, auth: :ingest},
      {:get, "/sheets/:slug/export.csv", export_controller, :export_csv, auth: :ingest},
      {:get, "/sheets/:slug/export.tsv", export_controller, :export_tsv, auth: :ingest},
      {:get, "/sheets/:slug/export.md", export_controller, :export_md, auth: :ingest},
      {:get, "/sheets/:slug/export.html", export_controller, :export_html, auth: :ingest}
    ]
  end

  # before_save: reject a sheet document whose cells or merges are
  # structurally malformed — a `cells` that is not a map, a non-A1 cell key,
  # a cell descriptor that is not a map, a cell ref or merge corner beyond
  # the Excel grid bounds, a `merges` that is not a list, a non-A1:B2 merge
  # range, or a merge whose area exceeds the cap (a hostile range must not
  # reach storage via plain mutate — the snapshot clips as
  # defense in depth, the gate keeps it out altogether). A STRUCTURAL gate
  # only: `v` and `f` stay free-form here — the formula engine
  # (`Barkpark.Sheets.Engine`) recomputes `v` on the core save path.
  # Non-sheet documents pass untouched.
  defp validate_sheet_doc(%{doc: %{"type" => "sheet"} = doc}) do
    tabs =
      case doc do
        %{"content" => %{"tabs" => tabs}} -> List.wrap(tabs)
        _ -> []
      end

    tabs
    |> Enum.with_index()
    |> Enum.flat_map(&tab_errors/1)
    |> case do
      [] -> :ok
      errors -> {:halt, "sheet validation failed: " <> Enum.join(errors, "; ")}
    end
  end

  defp validate_sheet_doc(_payload), do: :ok

  defp tab_errors({tab, idx}) when is_map(tab) do
    cells_errors =
      case Map.get(tab, "cells") do
        nil -> []
        cells when is_map(cells) -> Enum.flat_map(cells, &cell_errors(&1, idx))
        _ -> ["tab #{idx}: cells must be a map"]
      end

    merges_errors =
      case Map.get(tab, "merges") do
        nil -> []
        merges when is_list(merges) -> Enum.flat_map(merges, &merge_errors(&1, idx))
        _ -> ["tab #{idx}: merges must be a list"]
      end

    cells_errors ++ merges_errors
  end

  defp tab_errors({_tab, idx}), do: ["tab #{idx}: tab must be a map"]

  defp cell_errors({addr, cell}, idx) do
    case SheetCore.parse_ref(addr) do
      :error ->
        ["tab #{idx}: invalid cell address #{inspect(addr)} (expected A1-style, e.g. A1, AA3)"]

      {:ok, pos} ->
        if is_map(cell) do
          bounds_errors("cell #{inspect(addr)}", pos, idx)
        else
          ["tab #{idx}: cell #{inspect(addr)} must be a map"]
        end
    end
  end

  defp merge_errors(merge, idx) when is_binary(merge) do
    with [a, b] <- String.split(merge, ":"),
         {:ok, {c1, r1} = corner_a} <- SheetCore.parse_ref(a),
         {:ok, {c2, r2} = corner_b} <- SheetCore.parse_ref(b) do
      area = (abs(c2 - c1) + 1) * (abs(r2 - r1) + 1)

      area_errors =
        if area > @merge_area_cap do
          ["tab #{idx}: merge #{inspect(merge)} covers #{area} cells; the cap is #{@merge_area_cap}"]
        else
          []
        end

      area_errors ++
        bounds_errors("merge #{inspect(merge)} corner #{inspect(a)}", corner_a, idx) ++
        bounds_errors("merge #{inspect(merge)} corner #{inspect(b)}", corner_b, idx)
    else
      _ -> ["tab #{idx}: invalid merge #{inspect(merge)} (expected an A1:B2-style range)"]
    end
  end

  defp merge_errors(merge, idx),
    do: ["tab #{idx}: invalid merge #{inspect(merge)} (expected an A1:B2-style range)"]

  # The engine already treats a ref beyond XFD/1_048_576 as #REF! — the
  # data layer agrees: nothing addressed off the grid reaches storage.
  defp bounds_errors(what, {col, row}, idx) do
    cond do
      col > @grid_max_col ->
        ["tab #{idx}: #{what} is beyond the grid bounds (column #{col} > #{@grid_max_col}/XFD)"]

      row > @grid_max_row ->
        ["tab #{idx}: #{what} is beyond the grid bounds (row #{row} > #{@grid_max_row})"]

      true ->
        []
    end
  end
end
