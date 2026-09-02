defmodule Barkpark.SheetsParityTest do
  @moduledoc """
  The executable parity contract for the Sheets rendering surfaces — a sheet
  must look the SAME everywhere its grid renders. ONE canonical sheet
  exercising every feature (every value type, fmt hints, a computed formula,
  an engine error, a stale cell, single- and multi-row merges, col widths,
  row heights, frozen panes, all four `"s"` styles, two tabs) renders BY
  EXECUTION through:

    * A — the Studio grid editor (`BarkparkWeb.Studio.SheetGrid`, edit mode)
    * A′ — the SAME Studio surface for a WRITE-DENIED member (the wave-42
          `write_capable` arm: same session, same bytes, no write affordances)
    * B — Studio read-only View mode (the header toggle)
    * C — the public reader `/sheets/:slug` (the `chrome: :reader` grid)
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

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Plugins.Sheets.Engine
  alias Barkpark.Plugins.Sheets.Html, as: HtmlExport
  alias Barkpark.Plugins.Sheets.Markdown, as: MarkdownExport

  @dataset "production"
  @slug "parity-canonical"
  @paper_slug "2026-06-12-sheets-parity-embed"
  # Arm D's principal: an authenticated member whose permission array is
  # ["read"] — `Caps.write_capable?/2` is false for it, so the Studio callsite
  # passes `write_capable={false}`. Not anonymous, not the public reader.
  @denied_token "parity-write-denied"

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
          "C7" => %{"v" => 1_000_000.0, "t" => "n"},
          # fmt-class rendering: an imported 0.25 shows "25.00%" and 1234.5
          # shows "$1,234.50" on EVERY surface (Core.display_value + Cells.display
          # both go through Fmt.display). The raw values stay in data-v.
          "A8" => %{"v" => 0.25, "t" => "n", "fmt" => "percent"},
          "B8" => %{"v" => 1234.5, "t" => "n", "fmt" => "currency"}
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
    "B2" => "1,200",
    "C2" => "3.50",
    "A3" => "Active?",
    "B3" => "TRUE",
    "A4" => "Note",
    "B4" => "spans",
    "A5" => "2400",
    "A6" => "#DIV/0!",
    "B6" => "old",
    "C6" => "FALSE",
    "A7" => "2026-06-12",
    "C7" => "1000000",
    "A8" => "25.00%",
    "B8" => "$1,234.50"
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

  # Engine-error cells that must read as errors on EVERY surface — the grid via
  # the `sheet-err` class, the embed/html via inline `color:#dc2626` + bold.
  # A6 is `=1/0` → `#DIV/0!`, the canonical error cell.
  @expected_errors MapSet.new(["A6"])

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
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: @paper_slug,
          blocks: [
            %{"id" => "s0", "type" => "sheet", "ref" => @slug, "tab" => 0},
            %{"id" => "s1", "type" => "sheet", "ref" => @slug, "tab" => 1}
          ]
        })
      )

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

    {values, spans, styles, errors} =
      table
      |> LazyHTML.query("td[data-ref]")
      |> Enum.reduce({%{}, %{}, %{}, MapSet.new()}, fn td, {values, spans, styles, errors} ->
        ref = attr(td, "data-ref")
        # The VISIBLE display string — `data-v` now carries the RAW value for
        # TSV copy (fmt cells: data-v="0.25", span="25.00%"), so parity must
        # compare the rendered span text, which is what every other surface
        # shows too.
        v = text(td)
        values = if v == "", do: values, else: Map.put(values, ref, v)

        span = {int_attr(td, "colspan", 1), int_attr(td, "rowspan", 1)}
        spans = if span == {1, 1}, do: spans, else: Map.put(spans, ref, span)

        style = style_markers(attr(td, "style") || "")
        styles = if style == %{}, do: styles, else: Map.put(styles, ref, style)

        # The grid marks errors with the `sheet-err` CSS class (Cells.cell_class).
        errors =
          if String.contains?(attr(td, "class") || "", "sheet-err"),
            do: MapSet.put(errors, ref),
            else: errors

        {values, spans, styles, errors}
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

    %{values: values, spans: spans, widths: widths, styles: styles, errors: errors}
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
      # the snapshot drops head-row cell styles by documented design. Error
      # cells carry red/bold error chrome (not a cell style) — excluded here
      # and compared on the dedicated `:errors` axis instead.
      styles:
        for(
          {{c, r}, _v, _span, style} <- cells,
          not error_style?(style),
          markers = style_markers(style),
          markers != %{},
          into: %{}
        ) do
          {Barkpark.Plugins.Sheets.Core.format_ref({c, r}), markers}
        end,
      # The embed/html surfaces mark errors with inline `color:#dc2626` + bold.
      errors:
        for(
          {{c, r}, _v, _span, style} <- cells,
          error_style?(style),
          into: MapSet.new()
        ) do
          Barkpark.Plugins.Sheets.Core.format_ref({c, r})
        end
    }
  end

  defp error_style?(style), do: String.contains?(style, "color:#dc2626")

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

    assert %{surface: surface, axis: :errors, data: semantics.errors} ==
             %{surface: surface, axis: :errors, data: @expected_errors}
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

  # ── A↔A′: the write-denied member (pds-bl-w41-readonly-member-sees-published-only)
  #
  # The wave-41 component gate passed ONE overloaded flag (`read_only`) into the
  # grid for any principal `Caps` denies write. That flag also chose the CONTENT
  # SOURCE, so a member entitled to READ a sheet was served `@doc.content` — the
  # published perspective — while a colleague with write held the live draft
  # session open. Two people, one sheet, different numbers.
  #
  # The arm is named A′ rather than "D": D is already the paper embed on this
  # suite's own surface list (the slice brief's "arm D" is this arm).
  #
  # FALSIFIABILITY: revert `live_session` at the Studio callsite (or re-key the
  # content-source branch in `SheetGrid.update/2` onto write capability) and the
  # `d == a` assertion prints C1 => "Q4" against C1 => "DRAFT-ONLY".
  test "A↔A′: a write-denied member reads the SAME live session as a write-capable one, in a read-only STUDIO",
       %{conn: conn} do
    {:ok, _} = Auth.create_token(@denied_token, "parity write-denied", @dataset, ["read"])

    # A — the write-capable member commits an edit that is NEVER published, so
    # the live session and the published row now disagree by construction.
    {:ok, studio, _} = live(conn, scoped_studio("/d/#{@dataset}/studio/sheet/#{@slug}"))
    target = with_target(studio, "#sheet-grid-#{@slug}")
    render_hook(target, "cell-click", %{"ref" => "C1", "shift" => false})
    render_hook(target, "edit-commit", %{"value" => "DRAFT-ONLY", "move" => "none"})

    html_a = render(studio)
    a = extract_grid(html_a)

    assert a.values["C1"] == "DRAFT-ONLY",
           "the dirty session never took — arm A′ would be vacuous"

    # A′ — the write-denied member, same sheet, same open session.
    {:ok, denied, _} =
      conn
      |> Plug.Test.init_test_session(%{"api_token" => @denied_token})
      |> live(scoped_studio("/d/#{@dataset}/studio/sheet/#{@slug}"))

    html_d = render(denied)
    d = extract_grid(html_d)

    # The whole point: the same grid, cell for cell.
    assert d == a

    # …in a read-only STUDIO, not the public reader: the document header is
    # back and the container never flips to the reader's identity.
    assert html_d =~ ~s(data-test-id="studio-sheet-editor")
    refute html_d =~ ~s(data-test-id="sheet-reader")
    assert html_d =~ "pane-header editor-header"

    # …with every write affordance still gone (the capability half of the split).
    refute html_d =~ ~s(data-test-id="sheet-toolbar")
    assert html_a =~ ~s(data-test-id="sheet-toolbar")

    # …AND no dead affordance left behind by restoring the header: `toggle-mode`
    # flips @mode, but @editable is `mode == :edit and write_capable`, so for
    # this member the button would change nothing at all — label, toolbar and
    # grid identical before and after the click. It is not rendered. (Removing
    # the `:if={@write_capable}` on the toggle reds this line.)
    refute html_d =~ ~s(data-test-id="sheet-mode-toggle")
    assert html_a =~ ~s(data-test-id="sheet-mode-toggle")
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

  # ── single-source lock ───────────────────────────────────────────────────────
  #
  # The web grid's error vocabulary (`ENGINE_ERRORS` in web/lib/sheets.ts) is
  # LOCKED to `Engine.error_values/0` by a fixture generated from the engine.
  # Add a code to the engine but not regenerate the fixture → this reds; the
  # sibling vitest (web/__tests__/sheets-errors.test.ts) reds if sheets.ts then
  # fails to learn the regenerated code. Neither surface can drift one-sided.
  test "errors axis single-source: the web fixture equals Engine.error_values/0" do
    fixture =
      Path.expand("../../../web/__tests__/fixtures/engine-errors.json", __DIR__)
      |> File.read!()
      |> Jason.decode!()

    assert fixture == Engine.error_values(),
           "web/__tests__/fixtures/engine-errors.json drifted from Engine.error_values/0 — regenerate it from the engine list"
  end

  # DRIFT GUARD — CORE PortableDoc render (walk.ex) and Studio's sheet grid
  # (cells.ex) no longer read `Engine.error_values/0` at COMPILE time (that was a
  # core→plugin compile edge that broke the fresh-install invariant and forced a
  # recompile on every engine touch). Each now mirrors the vocabulary LOCALLY.
  # These two assertions lock each mirror EQUAL to the canonical engine list, so
  # a code added to / removed from the engine that the mirror doesn't follow
  # reds HERE — the duplication is a CHECKED invariant, never a silent fork.
  test "walk.ex error-vocab mirror equals Engine.error_values/0" do
    assert Barkpark.PortableDoc.Render.Walk.error_vocab() == Engine.error_values(),
           "walk.ex @error_values drifted from Engine.error_values/0 — update the local mirror"
  end

  test "cells.ex error-vocab mirror equals Engine.error_values/0" do
    assert BarkparkWeb.Studio.SheetGrid.Cells.error_vocab() == Engine.error_values(),
           "cells.ex @engine_errors drifted from Engine.error_values/0 — update the local mirror"
  end

  # ── THE TYPESCRIPT MIRRORS, LOCKED FROM A CONTEXT THAT CAN BLOCK ─────────────
  #
  # The two TS surfaces below cannot call `Engine.error_values/0`, so each keeps
  # a local `ERROR_VALUES` set. Each already has a guard in its OWN suite — the
  # react one in `js/packages/react/tests/sheet-error-vocabulary.test.ts`, the
  # mobile one in `apps/mobile/__tests__/sheetErrorVocabulary.test.ts` — and
  # those guards are good: they read the shared fixture and assert both
  # directions.
  #
  # They are also not enough on their own, and this is not a hypothesis. On
  # 2026-09-02 PR #15374 added `#NAME?` engine-side, the react guard went RED on
  # main (run 33650238539: 2 failed of 617, `missing '#NAME?'`), and the merge
  # landed anyway — because `js-tests.yml` publishes no context in
  # `.github/required-checks.json`. For about a day `#NAME?` rendered as plain
  # black text through @barkpark/react. The guard fired and could not stop it.
  #
  # These two assertions close the direction that actually bit. A PR that adds a
  # code engine-side touches `api/`, so `mix test` runs, so the REQUIRED and
  # deliberately-unfiltered Elixir gate goes red here — on a context that CAN
  # block. The opposite direction (someone edits only the .ts file) stays covered
  # by each package's own guard, which always triggers because its own tree is in
  # its workflow's paths filter.
  #
  # Deliberately a source read, not an import: Elixir cannot evaluate TypeScript,
  # and a mirror that a build step could satisfy is not the thing being locked.
  # `error_values_literal!/1` REFUSES rather than returning [] when it cannot
  # find the set — an extractor that silently yields nothing would make this
  # whole lock vacuous the first time someone reformats the file.
  # The two paths are LITERAL on purpose. An earlier draft built them by
  # concatenating a module attribute onto Path.expand/2, and
  # scripts/elixir-path-escape-check.sh could not resolve them — it reported OK
  # while two undeclared cross-tree reads sat in the suite. A read the ratchet
  # cannot see is worse than one it rejects, so both are spelled out here and
  # both are declared in ELIXIR_TEST_ONLY_PATHS. Declaring them also makes the
  # lock bidirectional: editing either .ts file now dispatches the Elixir suite,
  # so the mirror cannot drift from EITHER side without a required context going
  # red. Two exact files, not globs — the whole tree would be far more CI than
  # this buys.
  test "the @barkpark/react ERROR_VALUES mirror equals Engine.error_values/0" do
    codes =
      Path.expand("../../../js/packages/react/src/blocks/sheet.ts", __DIR__)
      |> error_values_literal!("js/packages/react/src/blocks/sheet.ts")

    assert_mirror_equals_engine(codes, "js/packages/react/src/blocks/sheet.ts")
  end

  test "the mobile sheet block's ERROR_VALUES mirror equals Engine.error_values/0" do
    codes =
      Path.expand("../../../apps/mobile/src/papers/portabledoc/blocks/sheet.tsx", __DIR__)
      |> error_values_literal!("apps/mobile/src/papers/portabledoc/blocks/sheet.tsx")

    assert_mirror_equals_engine(codes, "apps/mobile/src/papers/portabledoc/blocks/sheet.tsx")
  end

  defp assert_mirror_equals_engine(codes, rel) do
    assert Enum.sort(codes) == Enum.sort(Engine.error_values()),
           "#{rel} ERROR_VALUES drifted from Engine.error_values/0.\n" <>
             "  only in the TS mirror: #{inspect(codes -- Engine.error_values())}\n" <>
             "  only in the engine:    #{inspect(Engine.error_values() -- codes)}\n" <>
             "Update the mirror in the SAME PR as the engine change."
  end

  # Pull the `ERROR_VALUES = new Set([...])` members out of a TS source file.
  # REFUSES with the path when the shape it depends on is gone, so a refactor
  # that moves the literal fails LOUDLY instead of quietly matching nothing — a
  # silently-empty extractor is how a lock of this kind rots.
  defp error_values_literal!(path, rel) do
    src = File.read!(path)

    body =
      case Regex.run(~r/ERROR_VALUES\s*=\s*new Set\(\s*\[(.*?)\]/s, src) do
        [_, body] ->
          body

        _ ->
          flunk(
            "#{rel}: could not find an `ERROR_VALUES = new Set([...])` literal. " <>
              "If it was renamed or restructured, update this extractor — do NOT " <>
              "delete the assertion, it is the only lock on this mirror that runs " <>
              "in a required context."
          )
      end

    codes =
      ~r/['"]([^'"]+)['"]/
      |> Regex.scan(body)
      |> Enum.map(fn [_, code] -> code end)

    if codes == [],
      do:
        flunk(
          "#{rel}: found the ERROR_VALUES literal but extracted zero codes — " <>
            "the extractor is broken and this lock would be vacuous."
        )

    codes
  end

  # Behavioural half of the same lock: the marks each surface actually stamps
  # (walk.ex → red/bold inline; cells.ex → `sheet-err` class) cover exactly the
  # engine vocabulary. This proves the mirror is WIRED, not merely present.
  test "cells.ex marks exactly the engine's error vocabulary" do
    for code <- Engine.error_values() do
      cell = %{"v" => code}
      cls = BarkparkWeb.Studio.SheetGrid.Cells.cell_class(nil, nil, nil, {0, 0}, cell)
      assert cls =~ "sheet-err", "cells.ex failed to mark engine error #{code}"
    end

    refute BarkparkWeb.Studio.SheetGrid.Cells.cell_class(nil, nil, nil, {0, 0}, %{"v" => "plain"}) =~
             "sheet-err"
  end

  test "walk.ex renders every engine error code red/bold and leaves plain text unmarked" do
    for code <- Engine.error_values() do
      html =
        Barkpark.PortableDoc.Render.render_html(
          %{"kind" => "PdSheet", "rows" => [[code]]},
          %{doctype: false}
        )

      assert html =~ "color:#dc2626;font-weight:bold",
             "walk.ex failed to mark engine error #{code} red/bold"
    end

    plain =
      Barkpark.PortableDoc.Render.render_html(
        %{"kind" => "PdSheet", "rows" => [["plain"]]},
        %{doctype: false}
      )

    refute plain =~ "color:#dc2626;font-weight:bold"
  end
end
