defmodule Barkpark.SheetsParityTest do
  @moduledoc """
  The executable parity contract for the Sheets rendering surfaces — a sheet
  must look the SAME everywhere its grid renders. ONE canonical sheet
  exercising every feature (every value type, fmt hints, a computed formula,
  an engine error, a stale cell, single- and multi-row merges, col widths,
  row heights, frozen panes, all four `"s"` styles, two tabs) renders BY
  EXECUTION through:

    * A — the Studio grid editor (`BarkparkWeb.Studio.SheetGrid`, edit mode)
    * B — Studio read-only View mode (the header toggle)
    * C — the public reader `/sheets/:slug` (`read_only` grid)
    * D — a paper embedding the sheet (`PortableDoc.Render` of the snapshot
          at `/papers/:slug`)
    * F — the html / markdown exports (`Plugins.Sheets.{Html,Markdown}`)

  and the SEMANTIC content — cell values by A1 ref, colspan/rowspan spans,
  explicit column widths, and the b/i/bg/al style markers — is extracted
  from each surface's HTML and diffed. A↔B↔C must be identical (same
  renderer); A↔D must agree on values/merges/widths/styles; D↔F-html must
  agree by construction (same walker).

  Documented, deliberately-uncompared losses: row heights and frozen-pane
  bands do not travel into the snapshot (medium limitation — a paper table
  has no scroll viewport); the frozen first row becomes the embed's `<thead>`
  (values compared, chrome not); markdown is values-only by design (its
  moduledoc says so — locked below); the TUI renders values-at-anchor with
  no styles (locked Go-side in `internal/pdrender/sheet_test.go`).

  `async: false` — sheet sessions are globally registered processes, same as
  the other sheet LiveView suites.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias Barkpark.Plugins.Sheets.Html, as: HtmlExport
  alias Barkpark.Plugins.Sheets.Markdown, as: MarkdownExport

  @dataset "production"
  @slug "parity-canonical"
  @paper_slug "2026-06-12-sheets-parity-embed"

  # ── the canonical sheet ─────────────────────────────────────────────────────
  #
  # Tab 0 "Data" (frozen head row + frozen first col):
  #
  #        A (120px)        B (64px)      C (default)
  #   1 │ Metric          │ Q3          │ Q4            ← frozen head row
  #   2 │ Revenue (b)     │ 1200 (fmt)  │ 3.5 (fmt,i)     row height 40px
  #   3 │ Active? (bg)    │ TRUE  ───merged B3:C3─── (al center)
  #   4 │ Note (all four) │ spans ──┐
  #   5 │ =B2*2 → 2400    │   B4:C5 ┘ (multi-row merge)
  #   6 │ #DIV/0! (error) │ old (stale) │ FALSE
  #   7 │ 2026-06-12 (date fmt)
  #
  # Tab 1 "Extra": a single cell — locks multi-tab traversal on every surface.
  @content %{
    "tabs" => [
      %{
        "name" => "Data",
        "frozen_rows" => 1,
        "frozen_cols" => 1,
        "col_widths" => %{"1" => 120, "2" => 64},
        "row_heights" => %{"2" => 40},
        "merges" => ["B3:C3", "B4:C5"],
        "cells" => %{
          "A1" => %{"v" => "Metric"},
          "B1" => %{"v" => "Q3"},
          "C1" => %{"v" => "Q4"},
          "A2" => %{"v" => "Revenue", "s" => %{"b" => true}},
          "B2" => %{"v" => 1200, "t" => "n", "fmt" => "thousands"},
          "C2" => %{"v" => 3.5, "t" => "n", "fmt" => "fixed", "s" => %{"i" => true}},
          "A3" => %{"v" => "Active?", "s" => %{"bg" => "#ffee00"}},
          "B3" => %{"v" => true, "t" => "b", "s" => %{"al" => "center"}},
          "A4" => %{
            "v" => "Note",
            "s" => %{"b" => true, "i" => true, "bg" => "#e0f0ff", "al" => "right"}
          },
          "B4" => %{"v" => "spans"},
          "A5" => %{"f" => "=B2*2", "v" => 2400, "t" => "n"},
          "A6" => %{"f" => "=1/0", "v" => "#DIV/0!", "t" => "e"},
          "B6" => %{"v" => "old", "stale" => true},
          "C6" => %{"v" => false, "t" => "b"},
          "A7" => %{"v" => "2026-06-12", "t" => "date", "fmt" => "date"},
          # A whole float ≥ 1e6 — `to_string/1` would render "1.0e6"; the
          # shared formatter must keep it plain on EVERY surface (this locks
          # the scientific-notation fix across A↔B↔C↔D↔F).
          "C7" => %{"v" => 1_000_000.0, "t" => "n"}
        }
      },
      %{"name" => "Extra", "cells" => %{"A1" => %{"v" => "tab2"}}}
    ]
  }

  # Every shown value of tab 0 by A1 ref — what ALL surfaces must agree on.
  @expected_values %{
    "A1" => "Metric",
    "B1" => "Q3",
    "C1" => "Q4",
    "A2" => "Revenue",
    "B2" => "1200",
    "C2" => "3.5",
    "A3" => "Active?",
    "B3" => "TRUE",
    "A4" => "Note",
    "B4" => "spans",
    "A5" => "2400",
    "A6" => "#DIV/0!",
    "B6" => "old",
    "C6" => "FALSE",
    "A7" => "2026-06-12",
    "C7" => "1000000"
  }

  # Merge anchors → {colspan, rowspan}.
  @expected_spans %{"B3" => {2, 1}, "B4" => {2, 2}}

  # Explicit column widths (1-based col → px). Default-width cols compare as
  # absent — the grid paints its 88px default, the embed auto-sizes (medium).
  @expected_widths %{1 => 120, 2 => 64}

  # Body-cell style markers (head-row styles are dropped from the snapshot —
  # the head band has its own fixed style — so none are placed on row 1).
  @expected_styles %{
    "A2" => %{b: true},
    "C2" => %{i: true},
    "A3" => %{bg: "#ffee00"},
    "B3" => %{al: "center"},
    "A4" => %{b: true, i: true, bg: "#e0f0ff", al: "right"}
  }

  setup do
    stop_all_sessions()
    on_exit(&stop_all_sessions/0)

    Barkpark.TenancyFixtures.ensure_default_scope!()

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "sheet",
          "title" => "Sheets",
          "icon" => "grid",
          "visibility" => "private",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    {:ok, _} =
      Content.create_document(
        "sheet",
        %{"doc_id" => @slug, "title" => "Parity Canonical", "content" => @content},
        @dataset
      )

    {:ok, _} = Content.publish_document(@slug, "sheet", @dataset)

    # The paper embeds BOTH tabs — ingest hydrates each block's snapshot (M0a).
    {:ok, _} =
      Content.upsert_paper(%{
        slug: @paper_slug,
        blocks: [
          %{"id" => "s0", "type" => "sheet", "ref" => @slug, "tab" => 0},
          %{"id" => "s1", "type" => "sheet", "ref" => @slug, "tab" => 1}
        ]
      })

    :ok
  end

  defp stop_all_sessions do
    for {_, pid, _, _} <-
          DynamicSupervisor.which_children(Barkpark.Plugins.Sheets.SessionSupervisor),
        is_pid(pid) do
      try do
        GenServer.stop(pid, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  # ── semantic extraction ─────────────────────────────────────────────────────
  #
  # Both extractors produce the same shape:
  #   %{values: %{ref => string}, spans: %{ref => {colspan, rowspan}},
  #     widths: %{col => px}, styles: %{ref => %{b:, i:, bg:, al:}}}

  # The live grid (surfaces A/B/C) — `td[data-ref]` carries everything.
  defp extract_grid(html) do
    doc = LazyHTML.from_fragment(html)
    table = LazyHTML.query(doc, ~s(table[data-test-id="sheet-table"]))

    {values, spans, styles} =
      table
      |> LazyHTML.query("td[data-ref]")
      |> Enum.reduce({%{}, %{}, %{}}, fn td, {values, spans, styles} ->
        ref = attr(td, "data-ref")
        v = attr(td, "data-v") || ""
        values = if v == "", do: values, else: Map.put(values, ref, v)

        span = {int_attr(td, "colspan", 1), int_attr(td, "rowspan", 1)}
        spans = if span == {1, 1}, do: spans, else: Map.put(spans, ref, span)

        style = style_markers(attr(td, "style") || "")
        styles = if style == %{}, do: styles, else: Map.put(styles, ref, style)

        {values, spans, styles}
      end)

    # colgroup: first <col> is the 44px row-head gutter; grid cols follow.
    widths =
      table
      |> LazyHTML.query("colgroup col")
      |> Enum.drop(1)
      |> Enum.with_index(1)
      |> Enum.reduce(%{}, fn {col, idx}, acc ->
        case Regex.run(~r/width:\s*(\d+)px/, attr(col, "style") || "") do
          [_, px] -> Map.put(acc, idx, String.to_integer(px))
          _ -> acc
        end
      end)

    %{values: values, spans: spans, widths: widths, styles: styles}
  end

  # The snapshot embed (surfaces D / F-html) — one `<table role="presentation">`
  # walked positionally: `<thead>` is body row 1 (the frozen head), `<tbody>`
  # rows continue from row 2; colspan/rowspan project covered positions so
  # every cell lands back on its A1 ref.
  defp extract_embed(table) do
    head_cells = LazyHTML.query(table, "thead th")
    body_rows = LazyHTML.query(table, "tbody tr")

    head =
      head_cells
      |> Enum.with_index(1)
      |> Enum.map(fn {th, c} -> {{c, 1}, text(th), {1, 1}, attr(th, "style") || ""} end)

    # No frozen head row → no <thead> → the body grid starts at row 1.
    body_start = if head == [], do: 1, else: 2

    {cells, _covered} =
      body_rows
      |> Enum.with_index(body_start)
      |> Enum.reduce({[], MapSet.new()}, fn {tr, r}, {cells, covered} ->
        tr
        |> LazyHTML.query("td")
        |> Enum.reduce({cells, covered, 1}, fn td, {cells, covered, c} ->
          c = next_free_col(covered, r, c)
          cs = int_attr(td, "colspan", 1)
          rs = int_attr(td, "rowspan", 1)

          covered =
            for(rr <- r..(r + rs - 1), cc <- c..(c + cs - 1), into: covered, do: {rr, cc})

          cell = {{c, r}, text(td), {cs, rs}, attr(td, "style") || ""}
          {[cell | cells], covered, c + cs}
        end)
        |> then(fn {cells, covered, _c} -> {cells, covered} end)
      end)

    all = head ++ cells

    %{
      values:
        for({{c, r}, v, _span, _style} <- all, v != "", into: %{}) do
          {Barkpark.Plugins.Sheets.Core.format_ref({c, r}), v}
        end,
      spans:
        for({{c, r}, _v, span, _style} <- all, span != {1, 1}, into: %{}) do
          {Barkpark.Plugins.Sheets.Core.format_ref({c, r}), span}
        end,
      widths:
        for(
          {{c, 1}, _v, _span, style} <- head,
          [_, px] <- [Regex.run(~r/width:(\d+)px/, style)],
          into: %{}
        ) do
          {c, String.to_integer(px)}
        end,
      # Body cells only — the `<thead>` band carries the palette's own chrome
      # (bold/left-aligned `th`), which is head-band styling, not cell styles;
      # the snapshot drops head-row cell styles by documented design.
      styles:
        for(
          {{c, r}, _v, _span, style} <- cells,
          markers = style_markers(style),
          markers != %{},
          into: %{}
        ) do
          {Barkpark.Plugins.Sheets.Core.format_ref({c, r}), markers}
        end
    }
  end

  defp next_free_col(covered, r, c),
    do: if(MapSet.member?(covered, {r, c}), do: next_free_col(covered, r, c + 1), else: c)

  # Normalize the two surfaces' inline styles to one marker vocabulary:
  # the grid writes `font-weight: 600` / `background: #hex` (spaced), the
  # embed writes `font-weight:bold` / `background:#hex` — same semantics.
  defp style_markers(style) do
    %{}
    |> put_if(:b, Regex.match?(~r/font-weight:\s*(600|bold)/, style))
    |> put_if(:i, Regex.match?(~r/font-style:\s*italic/, style))
    |> then(fn m ->
      case Regex.run(~r/background:\s*(#[0-9a-fA-F]{6})/, style) do
        [_, hex] -> Map.put(m, :bg, String.downcase(hex))
        _ -> m
      end
    end)
    |> then(fn m ->
      case Regex.run(~r/text-align:\s*(left|center|right)/, style) do
        [_, al] -> Map.put(m, :al, al)
        _ -> m
      end
    end)
  end

  defp put_if(map, key, true), do: Map.put(map, key, true)
  defp put_if(map, _key, false), do: map

  defp attr(node, name), do: node |> LazyHTML.attribute(name) |> List.first()

  defp int_attr(node, name, default) do
    case attr(node, name) do
      nil -> default
      s -> String.to_integer(s)
    end
  end

  defp text(node), do: node |> LazyHTML.text() |> String.trim()

  defp assert_semantics(semantics, surface) do
    # One comparison per axis — an ExUnit diff names the diverging cells; the
    # `surface` rides in the map so the failing surface is unambiguous.
    assert %{surface: surface, axis: :values, data: semantics.values} ==
             %{surface: surface, axis: :values, data: @expected_values}

    assert %{surface: surface, axis: :spans, data: semantics.spans} ==
             %{surface: surface, axis: :spans, data: @expected_spans}

    assert %{surface: surface, axis: :styles, data: semantics.styles} ==
             %{surface: surface, axis: :styles, data: @expected_styles}

    assert %{
             surface: surface,
             axis: :widths,
             data: Map.take(semantics.widths, Map.keys(@expected_widths))
           } ==
             %{surface: surface, axis: :widths, data: @expected_widths}
  end

  # ── the contract ────────────────────────────────────────────────────────────

  test "A↔B↔C: the Studio editor, Studio View mode and the public reader render identical grid semantics",
       %{conn: conn} do
    # A — Studio edit mode.
    {:ok, studio, html_a} = live(conn, scoped_studio("/d/#{@dataset}/studio/sheet/#{@slug}"))
    assert html_a =~ ~s(data-test-id="studio-sheet-editor")
    a = extract_grid(html_a)
    assert_semantics(a, "A (Studio edit)")

    # B — the View toggle drops the affordances, never the content.
    html_b = studio |> element(~s(button[data-test-id="sheet-mode-toggle"])) |> render_click()
    refute html_b =~ ~s(data-test-id="sheet-toolbar")
    assert extract_grid(html_b) == a

    # C — the public reader strips editing server-side too; same semantics.
    {:ok, _reader, html_c} = live(conn, "/sheets/#{@slug}")
    assert html_c =~ ~s(data-test-id="sheet-reader")
    refute html_c =~ ~s(data-test-id="sheet-toolbar")
    assert extract_grid(html_c) == a

    # Both tabs reach every grid surface (the strip keeps its switchers).
    for html <- [html_a, html_b, html_c] do
      tabs =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s([data-test-id="sheet-tabs"] button))
        |> Enum.map(&text/1)

      assert ["Data", "Extra"] = Enum.take(tabs, 2)
    end
  end

  test "A↔D: the paper embed renders the same values, merges, widths and styles as the grid",
       %{conn: conn} do
    {:ok, _view, html} = live(conn, "/papers/#{@paper_slug}")

    [tab0, tab1] =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s(table[role="presentation"]))
      |> Enum.to_list()

    assert_semantics(extract_embed(tab0), "D (paper embed)")

    # The second tab travels through its own block.
    assert extract_embed(tab1).values == %{"A1" => "tab2"}
  end

  test "D↔F-html: the standalone html export walks the same renderer — same semantics, one section per tab" do
    html = HtmlExport.export(@content, "Parity Canonical")

    [tab0, tab1] =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query(~s(table[role="presentation"]))
      |> Enum.to_list()

    assert_semantics(extract_embed(tab0), "F (html export)")
    assert extract_embed(tab1).values == %{"A1" => "tab2"}
    assert html =~ "<h2" and html =~ "Data" and html =~ "Extra"
  end

  test "F-md: values-only by documented design — every value present, merges/styles/widths absent, and the moduledoc says so" do
    md = MarkdownExport.export(@content)

    # Every canonical value lands in the table (the frozen row is the header).
    for {_ref, value} <- @expected_values do
      assert md =~ value, "markdown export lost value #{inspect(value)}"
    end

    assert md =~ "## Data" and md =~ "## Extra"

    # The documented loss really is documented where a user looks.
    {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(MarkdownExport)
    assert moduledoc =~ "LOSSY BY DESIGN"
    assert moduledoc =~ "merges / styles / number formats / column widths do not travel"
  end
end
