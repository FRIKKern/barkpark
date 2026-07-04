defmodule BarkparkWeb.Studio.SheetGrid.SortToolbarTest do
  @moduledoc """
  Sheets Sort & Filter — SF-W: the sort TOOLBAR wire (SF-AM2), server-side.

  The sort ENGINE (`Structure.sort_rows` + the `sort_range` op + the
  `{:permute}` undo) shipped in #1087; the funnel in #1088. This suite pins
  the WIRE that makes sort reachable by hand: the toolbar A→Z / Z→A buttons
  and the column ▾ "Sort A→Z / Z→A" items, both pure-LiveView dispatchers of
  ONE `sort_range` op with ALL clipping done caller-side (SF-D5 / SF-AM2).

  Grammar pinned here:

    * THE WISH-BAR GOLDEN — a whole-column selection (the head-click shape)
      sorts the USED DATA RECT; a moved formula travels VERBATIM (`f` never
      rewritten — SF-D1) while its `v` refreshes on the post-sort recompute;
      undo restores the exact prior order (SF-D6).
    * IN-PLACE — any non-whole-column selection sorts only its rect, keyed by
      the ACTIVE cell's column; whole rows travel together.
    * FROZEN-BAND CLIP — with `frozen_rows` set, the dispatched rect starts
      below the band, so the header path never trips `sort_frozen_overlap`.
    * FILTER-ACTIVE REFUSAL — a viewer with an active filter is refused with a
      notice, never dispatched (SF-D8 corruption class).
    * NOTHING TO SORT — a <2-row rect is refused with a notice.
    * COLUMN MENU — a "Sort A→Z" menu item SELECTS the column AND sorts.

  `async: false` — sheet sessions are globally registered processes reading /
  persisting through the SQL sandbox, same discipline as
  `BarkparkWeb.Studio.FormulaAcceptanceTest`, on which this harness is modelled
  (setup + helpers copied minimally; that file untouched).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias Barkpark.Plugins.Sheets.Session

  @dataset "production"

  setup do
    stop_all_sessions()

    on_exit(fn ->
      stop_all_sessions()
      Application.delete_env(:barkpark, Barkpark.Plugins.Sheets.Session)
    end)

    put_cfg(debounce_ms: 60_000, idle_stop_ms: 60_000)
    seed_sheet_schema!()
    :ok
  end

  # ── harness (copied minimally from FormulaAcceptanceTest) ────────────────────

  defp put_cfg(overrides) do
    base = Application.get_env(:barkpark, Barkpark.Plugins.Sheets.Session, [])

    Application.put_env(
      :barkpark,
      Barkpark.Plugins.Sheets.Session,
      Keyword.merge(base, overrides)
    )
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

  defp seed_sheet_schema! do
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
  end

  defp create_sheet!(slug, tabs) do
    {:ok, doc} =
      Content.create_document(
        "sheet",
        %{"doc_id" => slug, "content" => %{"locale" => "nb-NO", "tabs" => tabs}},
        @dataset
      )

    doc
  end

  defp one_tab(cells, extra \\ %{}), do: [Map.merge(%{"name" => "Data", "cells" => cells}, extra)]

  defp open!(conn, slug) do
    {:ok, view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/sheet/#{slug}"))
    {view, with_target(view, "#sheet-grid-#{slug}"), html}
  end

  defp peek_cells(slug, tab_idx \\ 0) do
    {:ok, content} = Session.peek(slug, @dataset)
    get_in(content, ["tabs", Access.at(tab_idx), "cells"]) || %{}
  end

  defp namebox(view) do
    view |> element(~s([data-test-id="sheet-namebox"])) |> render()
  end

  # Select a whole rendered column via the head-click path (the shape the JS
  # hook pushes on a column-header click / Ctrl+Space).
  defp select_column!(target, index) do
    render_hook(target, "head-click", %{"kind" => "col", "index" => index, "shift" => false})
  end

  # ── THE WISH-BAR GOLDEN ──────────────────────────────────────────────────────

  test "select B:B, Sort ↓ (asc) → rows reorder, the moved formula travels verbatim, undo restores",
       %{conn: conn} do
    # A1:A3 = 3/1/2 with B1 = =A1 (stored `f` carries no leading "=", the
    # session convention). B1's cached v is 3 (A1 is 3).
    create_sheet!(
      "st-wish",
      one_tab(%{
        "A1" => %{"v" => 3},
        "A2" => %{"v" => 1},
        "A3" => %{"v" => 2},
        "B1" => %{"f" => "A1", "v" => 3, "t" => "n"}
      })
    )

    {view, target, html} = open!(conn, "st-wish")
    # The toolbar carries both sort buttons, edit-only.
    assert html =~ ~s(data-test-id="sheet-sort-asc")
    assert html =~ ~s(data-test-id="sheet-sort-desc")

    # Head-click column A selects the rendered window (a whole-column shape),
    # then Sort ↓ (asc) dispatches the used-data-rect sort keyed by column A.
    select_column!(target, 1)
    view |> element(~s([data-test-id="sheet-sort-asc"])) |> render_click()

    cells = peek_cells("st-wish")

    # Rows reordered by the comparator: 3/1/2 → 1/2/3 down column A.
    assert %{"A1" => %{"v" => 1}, "A2" => %{"v" => 2}, "A3" => %{"v" => 3}} = cells

    # The formula cell travelled with A1's row (old row 1, value 3 → new row 3):
    # its `f` is byte-identical "A1" (SF-D1, never rewritten) and its `v`
    # refreshed on the recompute — A1 now holds 1, so =A1 recomputes to 1.
    assert %{"B3" => %{"f" => "A1", "v" => 1}} = cells
    # It is no longer at B1 (it moved, verbatim — not copied).
    refute Map.has_key?(cells, "B1")

    # Undo restores the EXACT prior order + the formula's original home/value.
    render_hook(target, "undo", %{})
    restored = peek_cells("st-wish")

    assert %{"A1" => %{"v" => 3}, "A2" => %{"v" => 1}, "A3" => %{"v" => 2}} = restored
    assert %{"B1" => %{"f" => "A1", "v" => 3}} = restored
    refute Map.has_key?(restored, "B3")

    # The grid reflects the restored top value too (delta processed on render).
    assert render(view) =~ ~s(data-ref="A1")
  end

  # ── IN-PLACE, keyed by the ACTIVE column, whole rows travel ──────────────────

  test "a partial selection sorts IN PLACE keyed by the active cell's column, rows travelling",
       %{conn: conn} do
    # Two columns B/C over rows 2..4, plus untouched sentinels at row 1 and 5
    # that must NOT move (proves the rect — not the whole used range — sorted).
    create_sheet!(
      "st-inplace",
      one_tab(%{
        "B1" => %{"v" => "keep-top"},
        "B2" => %{"v" => "x"},
        "C2" => %{"v" => 3},
        "B3" => %{"v" => "y"},
        "C3" => %{"v" => 1},
        "B4" => %{"v" => "z"},
        "C4" => %{"v" => 2},
        "B5" => %{"v" => "keep-bot"}
      })
    )

    {_view, target, _html} = open!(conn, "st-inplace")

    # Build a B2:C4 selection with the ACTIVE cell in column C: click B4 first,
    # then shift-click C2 → active = C2 (column C), anchor = B4.
    render_hook(target, "cell-click", %{"ref" => "B4", "shift" => false})
    render_hook(target, "cell-click", %{"ref" => "C2", "shift" => true})

    render_hook(target, "sort-selection", %{"dir" => "asc"})

    cells = peek_cells("st-inplace")

    # Sorted by column C (the active column) asc: C 3/1/2 → 1/2/3; each row's
    # B travels with its C. Rows 1 and 5 are untouched (outside the rect).
    assert %{
             "B1" => %{"v" => "keep-top"},
             "B2" => %{"v" => "y"},
             "C2" => %{"v" => 1},
             "B3" => %{"v" => "z"},
             "C3" => %{"v" => 2},
             "B4" => %{"v" => "x"},
             "C4" => %{"v" => 3},
             "B5" => %{"v" => "keep-bot"}
           } = cells
  end

  # ── FROZEN-BAND CLIP (the header path clips, never refuses) ───────────────────

  test "with a frozen header row the whole-column sort clips to row 2 — no sort_frozen_overlap",
       %{conn: conn} do
    create_sheet!(
      "st-frozen",
      one_tab(
        %{
          "A1" => %{"v" => "Header"},
          "A2" => %{"v" => 3},
          "A3" => %{"v" => 1},
          "A4" => %{"v" => 2}
        },
        %{"frozen_rows" => 1}
      )
    )

    {view, target, _html} = open!(conn, "st-frozen")

    select_column!(target, 1)
    view |> element(~s([data-test-id="sheet-sort-asc"])) |> render_click()

    cells = peek_cells("st-frozen")

    # The frozen header stayed put; the data band (rows 2..4) sorted asc.
    assert %{
             "A1" => %{"v" => "Header"},
             "A2" => %{"v" => 1},
             "A3" => %{"v" => 2},
             "A4" => %{"v" => 3}
           } = cells

    # The caller clipped below the band, so the engine's frozen guard never
    # fired — no refusal notice reached the operator.
    refute render(view) =~ ~s(data-test-id="sheet-notice")
    refute render(view) =~ "sort_frozen_overlap"
  end

  # ── FILTER-ACTIVE REFUSAL ─────────────────────────────────────────────────────

  test "sorting while a column filter is active is refused with a notice, never dispatched",
       %{conn: conn} do
    create_sheet!(
      "st-filtered",
      one_tab(%{"A1" => %{"v" => 3}, "A2" => %{"v" => 1}, "A3" => %{"v" => 2}})
    )

    {view, target, _html} = open!(conn, "st-filtered")

    # Apply a column-A filter (pure view-state, no op). `nonblank` keeps every
    # occupied row — the point is only that the filters map is now non-empty.
    render_click(target, "filter-open", %{"col" => "1"})

    view
    |> element(~s([data-test-id="sheet-filter-form"]))
    |> render_submit(%{"col" => "1", "op" => "nonblank"})

    # Now attempt a sort — refused before any op is built.
    select_column!(target, 1)
    html = view |> element(~s([data-test-id="sheet-sort-asc"])) |> render_click()

    assert html =~ "Clear the column filters before sorting"

    # No op was dispatched — the sort was refused BEFORE send_ops, so no session
    # ever started (the strongest proof the stored order is untouched).
    assert Session.peek("st-filtered", @dataset) == {:error, :no_session}
  end

  # ── NOTHING TO SORT (<2-row rect) ─────────────────────────────────────────────

  test "a single-cell selection refuses with 'Nothing to sort'", %{conn: conn} do
    create_sheet!("st-nothing", one_tab(%{"A1" => %{"v" => 1}}))
    {view, target, _html} = open!(conn, "st-nothing")

    render_hook(target, "cell-click", %{"ref" => "A1", "shift" => false})
    html = view |> element(~s([data-test-id="sheet-sort-desc"])) |> render_click()

    assert html =~ "Nothing to sort"
  end

  # ── COLUMN MENU — selects AND sorts in one action ─────────────────────────────

  test "the column ▾ 'Sort A→Z' item SELECTS the column and sorts by it", %{conn: conn} do
    # Labels in A, the sort key in B — sorting by B must reorder whole rows and
    # leave the selection on column B (the wish's 'clicking a header selects').
    create_sheet!(
      "st-colmenu",
      one_tab(%{
        "A1" => %{"v" => "x"},
        "B1" => %{"v" => 3},
        "A2" => %{"v" => "y"},
        "B2" => %{"v" => 1},
        "A3" => %{"v" => "z"},
        "B3" => %{"v" => 2}
      })
    )

    {view, target, _html} = open!(conn, "st-colmenu")

    render_hook(target, "sort-column", %{"col" => "2", "dir" => "asc"})

    # Sorted by column B asc, whole rows travelling: B 3/1/2 → 1/2/3.
    assert %{
             "A1" => %{"v" => "y"},
             "B1" => %{"v" => 1},
             "A2" => %{"v" => "z"},
             "B2" => %{"v" => 2},
             "A3" => %{"v" => "x"},
             "B3" => %{"v" => 3}
           } = peek_cells("st-colmenu")

    # …and column B is now selected (active cell B1) so the user sees B:B.
    assert namebox(view) =~ ~s(value="B1")
  end

  # ── EMPTY KEY COLUMN — identity, never a silent re-key ───────────────────────

  test "sorting by an empty rendered column is a true no-op — never a silent re-key",
       %{conn: conn} do
    # Data lives in A:B (used_cols = 2); the grid renders ≥ 8 columns, so
    # column E is a real, clickable header with NO data. Keying the sort on it
    # must NOT fall back to the last occupied column (that would reorder the
    # user's data by a column they never picked — B here is deliberately in a
    # DIFFERENT order than A, so a re-key would show): the rect widens to
    # include the blank key column, every row ranks equal, and the stable sort
    # is the identity — Excel's semantics, no notice, nothing dirty.
    create_sheet!(
      "st-emptykey",
      one_tab(%{
        "A1" => %{"v" => 3},
        "B1" => %{"v" => "c"},
        "A2" => %{"v" => 1},
        "B2" => %{"v" => "a"},
        "A3" => %{"v" => 2},
        "B3" => %{"v" => "b"}
      })
    )

    {view, target, _html} = open!(conn, "st-emptykey")

    # Both wires: the column ▾ menu item on E…
    html = render_hook(target, "sort-column", %{"col" => "5", "dir" => "asc"})
    refute html =~ "rejected"

    # …and the head-click + toolbar path keyed by the empty active column.
    select_column!(target, 5)
    html = view |> element(~s([data-test-id="sheet-sort-asc"])) |> render_click()
    refute html =~ "rejected"

    # Byte-identical cells: nothing moved on either path.
    assert %{
             "A1" => %{"v" => 3},
             "B1" => %{"v" => "c"},
             "A2" => %{"v" => 1},
             "B2" => %{"v" => "a"},
             "A3" => %{"v" => 2},
             "B3" => %{"v" => "b"}
           } = peek_cells("st-emptykey")
  end
end
