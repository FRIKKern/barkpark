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
      documents whose `cells` map carries a non-A1 key or a cell descriptor
      that is not a map.

  The grid machinery itself is CORE, not plugin: A1 helpers and snapshot
  synthesis live in `Barkpark.Sheets`, the `"sheet"` portable-doc embed block
  composes in `Barkpark.PortableDoc.Render`, and snapshot write-through rides
  the save path in `Barkpark.Content` — so existing embeds keep rendering and
  refreshing with this plugin off (fresh-install invariant).

  Routes, import/export workers, and the collaborative engine are deferred to
  later milestones. The xlsx import/export deps (`xlsx_reader`, `elixlsx`) are
  declared in `mix.exs` and compiled but wired in a later phase.
  """

  use Barkpark.Plugin, manifest_path: "../../../priv/plugins/sheets/plugin.json"

  alias Barkpark.Content.SchemaDefinition
  alias Barkpark.Sheets, as: SheetCore

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

  @impl Barkpark.Plugin
  def lifecycle_hooks do
    %{before_save: [&validate_sheet_doc/1]}
  end

  # before_save: reject a sheet document whose cells are structurally
  # malformed — a `cells` that is not a map, a non-A1 cell key, or a cell
  # descriptor that is not a map. A STRUCTURAL gate only: `v` and `f` stay
  # free-form until the formula engine lands (M1). Non-sheet documents pass
  # untouched.
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
    case Map.get(tab, "cells") do
      nil -> []
      cells when is_map(cells) -> Enum.flat_map(cells, &cell_errors(&1, idx))
      _ -> ["tab #{idx}: cells must be a map"]
    end
  end

  defp tab_errors({_tab, idx}), do: ["tab #{idx}: tab must be a map"]

  defp cell_errors({addr, cell}, idx) do
    cond do
      SheetCore.parse_ref(addr) == :error ->
        ["tab #{idx}: invalid cell address #{inspect(addr)} (expected A1-style, e.g. A1, AA3)"]

      not is_map(cell) ->
        ["tab #{idx}: cell #{inspect(addr)} must be a map"]

      true ->
        []
    end
  end
end
