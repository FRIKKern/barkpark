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

  Routes, import/export workers, and the collaborative engine are deferred to
  later milestones. The xlsx import/export deps (`xlsx_reader`, `elixlsx`) are
  declared in `mix.exs` and compiled but wired in a later phase.
  """

  use Barkpark.Plugin, manifest_path: "../../../priv/plugins/sheets/plugin.json"

  alias Barkpark.Content.SchemaDefinition

  @schemas_dir Path.expand("../../../priv/plugins/sheets/schemas", __DIR__)

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
end
