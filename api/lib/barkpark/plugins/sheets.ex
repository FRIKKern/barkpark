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
      or a corner beyond the same grid bounds. The same gate strictly
      validates each tab's `cond_formats` rule list (CF-D6): exact
      `id`/`range`/`when`/`style` keys, the `gt|lt|eq|between|contains` op
      whitelist with per-op value typing, a required `#rrggbb` `bg`,
      single-rule-per-normalized-range, and `cond_format_cap/0` rules per tab.
      A present per-tab `color` (QL-D2) must be `#rrggbb` (case-insensitive);
      absent is fine.

    * `register_routes/1` (M5 + M1 + M4) — the conversion API on the
      `:ingest` bucket (shared-secret bearer via `RequireIngestToken`, like
      Bulldocs): `POST /v1/plugins/sheets/import` (multipart xlsx/csv/tsv →
      sheet doc), `GET /v1/plugins/sheets/:slug/export.{xlsx,csv,tsv,md,html}`,
      and `POST /v1/plugins/sheets/:slug/ops` (cell-granular wire ops, applied
      through the core `Barkpark.Plugins.Sheets.Session`); plus the live public
      reader `GET /sheets/:slug` on the `:public_root` bucket (the Bulldocs
      `/papers/:slug` precedent — published-only, read-only grid, live
      deltas; the reader LiveView `BarkparkWeb.SheetsReaderLive` stays
      core). Conversion modules live under `Barkpark.Plugins.Sheets.*`
      (`XlsxImport`, `XlsxExport`, `Csv`, `Markdown`, `Html`, `Fmt`) — the
      core stays conversion-free (the Bulldocs split: core keeps the
      reusable machinery, the plugin is the wiring).

  The grid machinery itself is CORE, not plugin: A1 helpers and snapshot
  synthesis live in `Barkpark.Plugins.Sheets.Core`, the `"sheet"` portable-doc embed block
  composes in `Barkpark.PortableDoc.Render`, and snapshot write-through rides
  the save path in `Barkpark.Content` — so existing embeds keep rendering and
  refreshing with this plugin off (fresh-install invariant).

  The collaborative session itself (`Barkpark.Plugins.Sheets.Session`, M1) is CORE —
  with this plugin off, sessions and direct mutate both keep working; only
  the wire-op HTTP route goes away.
  """

  use Barkpark.Plugin, manifest_path: "../../../priv/plugins/sheets/plugin.json"

  # Sheets is core content — surfaced in the MAIN tier of the Desk Structure.
  @impl Barkpark.Plugin
  def structure_placement, do: :main

  alias Barkpark.Content.SchemaDefinition
  alias Barkpark.Plugins.Sheets.CondFormat
  alias Barkpark.Plugins.Sheets.Core, as: SheetCore

  # Resolved at RUNTIME, deliberately not frozen into an attribute.
  # `Application.app_dir/2` finds priv under BOTH deploy models: the source-tree
  # one (Barkpark compiles + runs in place under /opt/barkpark, where Mix
  # symlinks _build/<env>/lib/barkpark/priv at ./priv) and an OTP release, where
  # priv lives at lib/barkpark-<vsn>/priv. The previous
  # `Path.expand("../../../priv/...", __DIR__)` attribute served only the first:
  # it froze the BUILD machine's absolute path, so every released build raised
  # File.Error enoent here and this plugin's schemas never registered.
  # Precedent: the plugin loader already resolves priv this way — see
  # registry/discovery.ex default_paths/0.
  @schemas_subdir "priv/plugins/sheets/schemas"
  defp schemas_dir, do: Application.app_dir(:barkpark, @schemas_subdir)

  @cell_cap 50_000
  @merge_area_cap 10_000
  @cond_format_cap 200

  # Excel's grid bounds — column XFD, row 1_048_576. Enforced at the gate
  # AFTER parse (see bounds_errors/3), not inside `Barkpark.Plugins.Sheets.Core.parse_ref/1`:
  # parse_ref stays a pure, total A1 parser (the engine, snapshot synthesis
  # and the importers all call it), and `Barkpark.Plugins.Sheets.Engine` keeps its
  # own copy of the same bounds for its `#REF!` semantics.
  @grid_max_col 16_384
  @grid_max_row 1_048_576

  @doc "Cap on non-empty cells per sheet import — enforced incrementally by the converters."
  @spec cell_cap() :: pos_integer()
  def cell_cap, do: @cell_cap

  @doc "Cap on a single merge range's area in cells — enforced on save and import."
  @spec merge_area_cap() :: pos_integer()
  def merge_area_cap, do: @merge_area_cap

  @doc "Cap on conditional-formatting rules per tab — enforced on save."
  @spec cond_format_cap() :: pos_integer()
  def cond_format_cap, do: @cond_format_cap

  @doc "Largest legal column (XFD, the Excel grid bound) — enforced on save and import."
  @spec grid_max_col() :: pos_integer()
  def grid_max_col, do: @grid_max_col

  @doc "Largest legal row (the Excel grid bound) — enforced on save and import."
  @spec grid_max_row() :: pos_integer()
  def grid_max_row, do: @grid_max_row

  @doc """
  Declares the `sheet` document type. Reads `priv/plugins/sheets/schemas/sheet.json`
  at runtime (resolved via `schemas_dir/0`, which works in a release as well as
  the source tree) and upserts via Bootstrap on every boot — idempotent on
  `(name, dataset)`, matching the bulldocs pattern.
  """
  @impl Barkpark.Plugin
  # Reachability: the only path read is the runtime-resolved schemas dir joined
  # with a compile-time literal filename — no runtime input reaches `File.read!/1`.
  # Inline rather than a `.sobelow-skips` row on purpose: a baseline entry is
  # pinned to a LINE, so any edit above the call silently kills the waiver and the
  # finding returns as new. The annotation binds by AST adjacency and survives moves.
  # sobelow_skip ["Traversal.FileModule"]
  def register_schemas(_opts) do
    raw =
      schemas_dir()
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
    * `POST /v1/plugins/sheets/:slug/ops` (M1) — `{"ops": [ … ]}` applied
      through the core `Barkpark.Plugins.Sheets.Session` (the session validates,
      serializes, recomputes, broadcasts deltas and debounces persistence).

  Route changes need a forced router recompile — the router macro reads the
  registry at compile time (`MIX_ENV=test mix compile --force`).
  """
  @impl Barkpark.Plugin
  def register_routes(_ctx) do
    import_controller = Barkpark.Plugins.Sheets.Web.ImportController
    export_controller = Barkpark.Plugins.Sheets.Web.ExportController
    ops_controller = Barkpark.Plugins.Sheets.Web.OpsController

    [
      # The live public reader (M4) — the Bulldocs `/papers/:slug` precedent:
      # `:public_root` mounts the CORE BarkparkWeb.SheetsReaderLive at the
      # host's top level with its own full-document `:sheets` root layout.
      # Published-only; draft-only slugs 404. With this plugin off, only
      # this route goes away (the reader module, session, grid stay core).
      {:live, "/sheets/:slug", BarkparkWeb.SheetsReaderLive, :index,
       auth: :public_root, root_layout: {BarkparkWeb.Layouts, :sheets}},
      {:post, "/sheets/import", import_controller, :create, auth: :ingest},
      {:post, "/sheets/:slug/ops", ops_controller, :apply_ops, auth: :ingest},
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
  # (`Barkpark.Plugins.Sheets.Engine`) recomputes `v` on the core save path.
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

    cond_formats_errors =
      case Map.get(tab, "cond_formats") do
        nil -> []
        cfs when is_list(cfs) -> cond_format_list_errors(cfs, idx)
        _ -> ["tab #{idx}: cond_formats must be a list"]
      end

    color_errors =
      case Map.get(tab, "color") do
        nil -> []
        color when is_binary(color) -> color_format_errors(color, idx)
        other -> ["tab #{idx}: color must be a #rrggbb string, got #{inspect(other)}"]
      end

    cells_errors ++ merges_errors ++ cond_formats_errors ++ color_errors
  end

  defp tab_errors({_tab, idx}), do: ["tab #{idx}: tab must be a map"]

  # A present tab `"color"` must be `#rrggbb` (case-insensitive) — the strict
  # gate for QL-D2's per-tab color, beside cells/merges/cond_formats. Absent is
  # fine (handled by the `nil` clause above); anything malformed halts the save
  # (409), so a junk color can never reach storage via plain mutate (synthesis
  # stays lenient and simply drops one that slipped in — the merges precedent).
  # Routes through the canonical `#rrggbb` sanitizer (CondFormat.valid_bg?/1 —
  # the sheets-bg-sanitizer capability) rather than a fourth copy of the regex,
  # so the tab color is accepted on EXACTLY the bytes a cell/CF bg is: `\z`-
  # anchored, so a stowaway trailing newline (`#ffffff\n`) is rejected here and
  # can never reach the xlsx `<tabColor>` round-trip.
  defp color_format_errors(color, idx) do
    if CondFormat.valid_bg?(color) do
      []
    else
      # lit-allow-next-line: example hex in a user-facing error STRING (color DATA, not chrome)
      ["tab #{idx}: invalid color #{inspect(color)} (expected #rrggbb, e.g. #1a2b3c)"]
    end
  end

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
          [
            "tab #{idx}: merge #{inspect(merge)} covers #{area} cells; the cap is #{@merge_area_cap}"
          ]
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

  # ── conditional-formatting rules ─────────────────────────────────────────
  #
  # Gate strict / synthesis lenient (the merges precedent): validated
  # locally here beside merge_errors — the CondFormat evaluator parses the
  # same shape leniently. A rule a server cannot evaluate must not be
  # stored, so unknown keys anywhere (rule / when / style) are rejected
  # (CF-D6, SERVER-EVAL integrity).
  @doc """
  Validate a tab's `cond_formats` rule list with the SAME strictness the
  `before_save` gate applies (CF-D6) — returns a list of human-readable error
  strings (empty when the list is valid). PUBLIC so the core session's
  `set_cond_format` op validates a session-authored list identically to the
  persist gate: a rule the session admits but the gate would reject strands the
  debounced persist forever (CF-AM1). `idx` is the tab index, only for message
  context. This is the ONE shared validator — no fourth copy (parked hygiene).
  """
  @spec cond_format_list_errors([map()], non_neg_integer()) :: [String.t()]
  def cond_format_list_errors(cfs, idx) when is_list(cfs) do
    cap_errors =
      if length(cfs) > @cond_format_cap do
        ["tab #{idx}: cond_formats has #{length(cfs)} rules; the cap is #{@cond_format_cap}"]
      else
        []
      end

    rule_errors = Enum.flat_map(cfs, &cond_format_errors(&1, idx))

    cap_errors ++ rule_errors ++ cond_format_dup_errors(cfs, idx)
  end

  def cond_format_list_errors(_cfs, idx), do: ["tab #{idx}: cond_formats must be a list"]

  defp cond_format_errors(rule, idx) when is_map(rule) do
    prefix = "tab #{idx}: cond_format #{cf_label(rule)}: "

    exact_key_errors(rule, ["id", "range", "when", "style"], prefix, "rule") ++
      cf_id_errors(rule, prefix) ++
      cf_range_errors(rule, idx, prefix) ++
      cf_when_errors(rule, prefix) ++
      cf_style_errors(rule, prefix)
  end

  defp cond_format_errors(rule, idx),
    do: ["tab #{idx}: cond_format #{inspect(rule)}: rule must be a map"]

  defp cf_label(%{"id" => id}) when is_binary(id) and id != "", do: id
  defp cf_label(rule), do: inspect(rule)

  # Exactly the expected keys — no missing, no unknown. Used at the rule
  # level where all of id/range/when/style are required (SERVER-EVAL: a key
  # the evaluator cannot honor must not reach storage).
  defp exact_key_errors(map, expected, prefix, what) do
    actual = MapSet.new(Map.keys(map))
    want = MapSet.new(expected)

    unknown = actual |> MapSet.difference(want) |> MapSet.to_list()
    missing = want |> MapSet.difference(actual) |> MapSet.to_list()

    unknown_err =
      if unknown == [], do: [], else: [prefix <> "#{what} has unknown key(s) #{inspect(unknown)}"]

    missing_err =
      if missing == [], do: [], else: [prefix <> "#{what} is missing key(s) #{inspect(missing)}"]

    unknown_err ++ missing_err
  end

  # Only reject keys OUTSIDE the allowed set — for `when`/`style`, whose
  # optional keys (value2, b, i) are presence-driven by the op/bg checks.
  defp unknown_key_errors(map, allowed, prefix, what) do
    case MapSet.new(Map.keys(map))
         |> MapSet.difference(MapSet.new(allowed))
         |> MapSet.to_list() do
      [] -> []
      unknown -> [prefix <> "#{what} has unknown key(s) #{inspect(unknown)}"]
    end
  end

  defp cf_id_errors(rule, prefix) do
    case Map.fetch(rule, "id") do
      {:ok, id} when is_binary(id) and id != "" -> []
      {:ok, _} -> [prefix <> "id must be a non-empty string"]
      :error -> []
    end
  end

  # No area cap on the range — CF-D8: eval is occupied-only, so even a
  # hostile A1:XFD1048576 range costs nothing (blank cells never match).
  defp cf_range_errors(rule, idx, prefix) do
    case Map.fetch(rule, "range") do
      {:ok, range} ->
        case cf_range_corners(range) do
          {:ok, {_lc, _lr, hc, hr}} ->
            bounds_errors("cond_format #{cf_label(rule)} range #{inspect(range)}", {hc, hr}, idx)

          :error ->
            [prefix <> "range #{inspect(range)} is not a single A1 cell or A1:B2 range"]
        end

      :error ->
        []
    end
  end

  defp cf_when_errors(rule, prefix) do
    case Map.fetch(rule, "when") do
      {:ok, w} when is_map(w) ->
        unknown_key_errors(w, ["op", "value", "value2"], prefix, "when") ++
          cf_op_errors(w, prefix)

      {:ok, _} ->
        [prefix <> "when must be a map"]

      :error ->
        []
    end
  end

  defp cf_op_errors(w, prefix) do
    op = Map.get(w, "op")
    value = Map.get(w, "value")
    has_v2 = Map.has_key?(w, "value2")
    value2 = Map.get(w, "value2")

    case op do
      op when op in ["gt", "lt"] ->
        forbid_value2(op, has_v2, prefix) ++ num_value_error(op, value, prefix)

      "between" ->
        v_err =
          if is_number(value), do: [], else: [prefix <> "when.value must be a number for between"]

        v2_err =
          cond do
            not has_v2 -> [prefix <> "when.value2 is required for between"]
            is_number(value2) -> []
            true -> [prefix <> "when.value2 must be a number for between"]
          end

        v_err ++ v2_err

      "eq" ->
        forbid_value2("eq", has_v2, prefix) ++
          if eq_value?(value),
            do: [],
            else: [prefix <> "when.value must be a number, non-empty string, or boolean for eq"]

      "contains" ->
        forbid_value2("contains", has_v2, prefix) ++
          if is_binary(value) and value != "",
            do: [],
            else: [prefix <> "when.value must be a non-empty string for contains"]

      _ ->
        [prefix <> "when.op must be one of gt|lt|eq|between|contains, got #{inspect(op)}"]
    end
  end

  defp num_value_error(op, value, prefix) do
    if is_number(value), do: [], else: [prefix <> "when.value must be a number for #{op}"]
  end

  defp forbid_value2(op, true, prefix), do: [prefix <> "when.value2 is not allowed for #{op}"]
  defp forbid_value2(_op, false, _prefix), do: []

  defp eq_value?(v), do: is_number(v) or is_boolean(v) or (is_binary(v) and v != "")

  defp cf_style_errors(rule, prefix) do
    case Map.fetch(rule, "style") do
      {:ok, s} when is_map(s) ->
        unknown_key_errors(s, ["bg", "b", "i"], prefix, "style") ++
          cf_bg_errors(s, prefix) ++
          cf_bool_flag_errors(s, "b", prefix) ++
          cf_bool_flag_errors(s, "i", prefix)

      {:ok, _} ->
        [prefix <> "style must be a map"]

      :error ->
        []
    end
  end

  # The `#rrggbb` validator is single-sourced in CondFormat (arc-2 parked
  # hygiene) — `valid_bg?/1` is byte-identical in acceptance to the manual
  # sanitizer, so a gate-accepted bg is exactly one the snapshot keeps.
  defp cf_bg_errors(s, prefix) do
    case Map.fetch(s, "bg") do
      {:ok, bg} ->
        if CondFormat.valid_bg?(bg),
          do: [],
          else: [prefix <> "style.bg must be a #rrggbb color, got #{inspect(bg)}"]

      :error ->
        [prefix <> "style.bg is required"]
    end
  end

  defp cf_bool_flag_errors(s, key, prefix) do
    case Map.fetch(s, key) do
      :error ->
        []

      {:ok, true} ->
        []

      {:ok, other} ->
        [prefix <> "style.#{key} must be literal true when present, got #{inspect(other)}"]
    end
  end

  # Duplicate id and duplicate NORMALIZED range within a tab (CF-D4: single
  # rule per range; "B2" == "B2:B2", corners reordered top-left, uppercased).
  defp cond_format_dup_errors(cfs, idx) do
    ids =
      for rule <- cfs,
          is_map(rule),
          {:ok, id} <- [Map.fetch(rule, "id")],
          is_binary(id),
          id != "" do
        id
      end

    id_errors =
      for id <- Enum.uniq(ids -- Enum.uniq(ids)) do
        "tab #{idx}: cond_format #{id}: duplicate id"
      end

    ranges =
      for rule <- cfs,
          is_map(rule),
          {:ok, range} <- [Map.fetch(rule, "range")],
          {:ok, norm} <- [cf_range_corners(range)] do
        norm
      end

    range_errors =
      for norm <- Enum.uniq(ranges -- Enum.uniq(ranges)) do
        "tab #{idx}: cond_format range #{inspect(cf_format_range(norm))}: duplicate normalized range"
      end

    id_errors ++ range_errors
  end

  # Normalize an A1 cell/range to {lo_col, lo_row, hi_col, hi_row} (corners
  # reordered top-left, uppercased by parse_ref). Single cell "B2" folds to
  # the same tuple as "B2:B2".
  defp cf_range_corners(range) when is_binary(range) do
    case String.split(range, ":") do
      [a] -> cf_corner_pair(a, a)
      [a, b] -> cf_corner_pair(a, b)
      _ -> :error
    end
  end

  defp cf_range_corners(_), do: :error

  defp cf_corner_pair(a, b) do
    with {:ok, {c1, r1}} <- SheetCore.parse_ref(a),
         {:ok, {c2, r2}} <- SheetCore.parse_ref(b) do
      {:ok, {min(c1, c2), min(r1, r2), max(c1, c2), max(r1, r2)}}
    else
      _ -> :error
    end
  end

  defp cf_format_range({lc, lr, hc, hr}) do
    tl = SheetCore.format_ref({lc, lr})
    if lc == hc and lr == hr, do: tl, else: tl <> ":" <> SheetCore.format_ref({hc, hr})
  end

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
