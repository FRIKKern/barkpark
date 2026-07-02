defmodule BarkparkWeb.Studio.StudioLiveSheetGridTest do
  @moduledoc """
  Sheets M2 — the Studio grid editor (`BarkparkWeb.Studio.SheetGrid`).

  Proves the editing surface end-to-end through the real spine: a
  `type:"sheet"` document opens as the grid (NOT the field form); every
  edit event becomes a `Barkpark.Plugins.Sheets.Session.apply_ops/3` op; the
  session's `{:sheets_op,…}` delta broadcast re-renders THIS pane and any
  OTHER LiveView open on the same sheet (two LiveViewTest processes).
  Covers cell edits, the formula bar, keyboard navigation + rectangular
  selection, batch clear, TSV paste, row insertion via the header menu,
  the tab strip (switch/add/rename/delete), engine error styling and the
  row pager (paging past the 500-row window + the >64-column clip notice).

  `async: false` — sheet sessions are globally registered processes that
  read/persist through the SQL sandbox (shared mode), same as
  `Barkpark.Plugins.Sheets.SessionTest`.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias Barkpark.Plugins.Sheets.Session
  alias BarkparkWeb.Studio.SheetGrid.Ops

  @dataset "production"

  setup do
    stop_all_sessions()

    on_exit(fn ->
      stop_all_sessions()
      Application.delete_env(:barkpark, Barkpark.Plugins.Sheets.Session)
    end)

    # Keep the production debounce/idle timers out of test timing.
    put_cfg(debounce_ms: 60_000, idle_stop_ms: 60_000)
    seed_sheet_schema!()
    :ok
  end

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

  defp one_tab(cells), do: [%{"name" => "Data", "cells" => cells}]

  defp open!(conn, slug) do
    {:ok, view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/sheet/#{slug}"))
    {view, with_target(view, "#sheet-grid-#{slug}"), html}
  end

  defp peek_cells(slug, tab_idx \\ 0) do
    {:ok, content} = Session.peek(slug, @dataset)
    get_in(content, ["tabs", Access.at(tab_idx), "cells"]) || %{}
  end

  defp peek_merges(slug, tab_idx \\ 0) do
    {:ok, content} = Session.peek(slug, @dataset)
    get_in(content, ["tabs", Access.at(tab_idx), "merges"]) || []
  end

  defp namebox(view) do
    view |> element(~s([data-test-id="sheet-namebox"])) |> render()
  end

  # ── mount ──────────────────────────────────────────────────────────────────

  test "a sheet doc opens as the grid editor, rendered from the stored doc", %{conn: conn} do
    create_sheet!("sg-mount", one_tab(%{"A1" => %{"v" => "hello"}, "B2" => %{"v" => 7}}))
    {_view, _target, html} = open!(conn, "sg-mount")

    # The desk structure stays visible and the editor pane is the GRID,
    # not the generic field form.
    assert html =~ "Sheets"
    assert html =~ ~s(data-test-id="studio-sheet-editor")
    assert html =~ ~s(data-test-id="sheet-table")
    refute html =~ ~s(id="editor-form")

    # Cells render from the doc content; row numbers + column letters +
    # the thin JS hook + formula bar are all present.
    assert html =~ ~s(data-ref="A1")
    assert html =~ ~s(data-v="hello")
    assert html =~ ~s(data-v="7")
    assert html =~ ~s(phx-hook="SheetGrid")
    assert html =~ ~s(data-test-id="sheet-formula-bar")
    assert html =~ ~s(data-test-id="sheet-tabs")
  end

  # ── cell editing ───────────────────────────────────────────────────────────

  test "a cell edit becomes a session op and re-renders with the new value", %{conn: conn} do
    create_sheet!("sg-edit", one_tab(%{}))
    {view, target, _html} = open!(conn, "sg-edit")

    render_hook(target, "cell-click", %{"ref" => "A1", "shift" => false})
    render_hook(target, "edit-commit", %{"value" => "42", "move" => "down"})

    html = render(view)
    assert html =~ ~s(data-v="42")
    # Excel muscle memory: Enter committed and moved DOWN to A2.
    assert namebox(view) =~ ~s(value="A2")

    # The op went through the real session (numeric coercion included).
    assert %{"A1" => %{"v" => 42}} = peek_cells("sg-edit")
  end

  test "a formula entered in the bar computes in the grid and reads back as f in the bar",
       %{conn: conn} do
    create_sheet!("sg-formula", one_tab(%{"A1" => %{"v" => 2}, "A2" => %{"v" => 3}}))
    {view, target, _html} = open!(conn, "sg-formula")

    render_hook(target, "cell-click", %{"ref" => "A3", "shift" => false})
    render_submit(target, "bar-commit", %{"value" => "=SUM(A1:A2)"})

    html = render(view)
    # The grid shows the COMPUTED v…
    assert html =~ ~s(data-v="5")
    # …and the bar shows the formula for the still-active A3.
    bar = view |> element(~s([data-test-id="sheet-formula-bar"])) |> render()
    assert bar =~ ~s{value="=SUM(A1:A2)"}

    assert %{"A3" => %{"f" => "SUM(A1:A2)", "v" => 5}} = peek_cells("sg-formula")
  end

  test "bar-commit with a move writes the cell AND advances the active cell", %{conn: conn} do
    create_sheet!("sg-bar-move", one_tab(%{"A1" => %{"v" => 1}}))
    {view, target, _html} = open!(conn, "sg-bar-move")

    render_hook(target, "cell-click", %{"ref" => "B2", "shift" => false})
    assert namebox(view) =~ ~s(value="B2")

    # Tab in the bar commits to B2 and moves one column right → C2.
    render_hook(target, "bar-commit", %{"value" => "7", "move" => "right"})
    assert namebox(view) =~ ~s(value="C2")
    assert %{"B2" => %{"v" => 7}} = peek_cells("sg-bar-move")

    # Enter in the bar (no move) commits and leaves the active cell put.
    render_hook(target, "cell-click", %{"ref" => "A3", "shift" => false})
    render_hook(target, "bar-commit", %{"value" => "8"})
    assert namebox(view) =~ ~s(value="A3")
    assert %{"A3" => %{"v" => 8}} = peek_cells("sg-bar-move")
  end

  # The hook's Cmd/Ctrl+Z / Cmd/Ctrl+Shift+Z arrive as "undo"/"redo" events;
  # send_ops stamps THIS studio identity onto every op, so the session pops
  # this user's per-user inverse stack (Sheets M4).
  test "undo/redo via the grid events round-trips an edit", %{conn: conn} do
    create_sheet!("sg-undo", one_tab(%{"A1" => %{"v" => "before"}}))
    {view, target, _html} = open!(conn, "sg-undo")

    render_hook(target, "cell-click", %{"ref" => "A1", "shift" => false})
    render_hook(target, "edit-commit", %{"value" => "after", "move" => "down"})
    assert render(view) =~ ~s(data-v="after")

    render_hook(target, "undo", %{})
    assert render(view) =~ ~s(data-v="before")
    assert %{"A1" => %{"v" => "before"}} = peek_cells("sg-undo")

    render_hook(target, "redo", %{})
    assert render(view) =~ ~s(data-v="after")
    assert %{"A1" => %{"v" => "after"}} = peek_cells("sg-undo")

    # An empty stack surfaces as the transient notice, not a crash.
    render_hook(target, "redo", %{})
    assert render(view) =~ "redo stack"
  end

  test "engine error values render with the error styling", %{conn: conn} do
    create_sheet!("sg-err", one_tab(%{}))
    {view, target, _html} = open!(conn, "sg-err")

    render_hook(target, "cell-click", %{"ref" => "A1", "shift" => false})
    render_hook(target, "edit-commit", %{"value" => "=1/0", "move" => "none"})

    html = render(view)
    assert html =~ "#DIV/0!"
    assert html =~ "sheet-err"
  end

  # ── keyboard navigation + selection ────────────────────────────────────────

  test "arrow-key nav events move the active cell; shift extends a selection", %{conn: conn} do
    create_sheet!("sg-nav", one_tab(%{"A1" => %{"v" => "x"}}))
    {view, target, _html} = open!(conn, "sg-nav")

    assert namebox(view) =~ ~s(value="A1")

    render_hook(target, "nav", %{"key" => "ArrowDown", "shift" => false})
    assert namebox(view) =~ ~s(value="A2")

    render_hook(target, "nav", %{"key" => "ArrowRight", "shift" => false})
    assert namebox(view) =~ ~s(value="B2")

    # Shift+Arrow extends a rectangular selection from the anchor.
    html = render_hook(target, "nav", %{"key" => "ArrowRight", "shift" => true})
    assert namebox(view) =~ ~s(value="C2")
    assert html =~ "sheet-sel"
  end

  test "a multi-cell selection surfaces SUM/AVG/COUNT in the status bar", %{conn: conn} do
    create_sheet!(
      "sg-stats",
      one_tab(%{"A1" => %{"v" => 10}, "A2" => %{"v" => 30}, "A3" => %{"v" => "x"}})
    )

    {view, target, _html} = open!(conn, "sg-stats")

    # A single cell shows nothing — no aggregate to report.
    render_hook(target, "cell-click", %{"ref" => "A1", "shift" => false})
    refute render(view) =~ ~s(data-test-id="sheet-statsbar")

    # Extend A1:A3 (two numbers + one text) — text is excluded from the stats.
    render_hook(target, "nav", %{"key" => "ArrowDown", "shift" => true})
    html = render_hook(target, "nav", %{"key" => "ArrowDown", "shift" => true})

    assert html =~ ~s(data-test-id="sheet-statsbar")
    assert html =~ "Sum: 40"
    assert html =~ "Avg: 20"
    assert html =~ "Count: 2"
  end

  test "Delete batch-clears the rectangular selection", %{conn: conn} do
    cells = %{
      "A1" => %{"v" => "x1"},
      "B1" => %{"v" => "x2"},
      "A2" => %{"v" => "x3"},
      "B2" => %{"v" => "x4"},
      "C3" => %{"v" => "keep"}
    }

    create_sheet!("sg-clear", one_tab(cells))
    {view, target, _html} = open!(conn, "sg-clear")

    render_hook(target, "cell-click", %{"ref" => "A1", "shift" => false})
    render_hook(target, "nav", %{"key" => "ArrowRight", "shift" => true})
    render_hook(target, "nav", %{"key" => "ArrowDown", "shift" => true})
    render_hook(target, "clear-selection", %{})

    html = render(view)
    refute html =~ ~s(data-v="x1")
    refute html =~ ~s(data-v="x4")
    assert html =~ ~s(data-v="keep")

    assert peek_cells("sg-clear") == %{"C3" => %{"v" => "keep"}}
  end

  # ── clipboard ──────────────────────────────────────────────────────────────

  test "pasting TSV applies a batch of set_cell ops from the active cell", %{conn: conn} do
    create_sheet!("sg-paste", one_tab(%{}))
    {view, target, _html} = open!(conn, "sg-paste")

    render_hook(target, "cell-click", %{"ref" => "B2", "shift" => false})
    render_hook(target, "paste", %{"tsv" => "p\t9\nr\ts\n"})

    html = render(view)
    assert html =~ ~s(data-v="p")
    assert html =~ ~s(data-v="9")

    assert %{
             "B2" => %{"v" => "p"},
             "C2" => %{"v" => 9},
             "B3" => %{"v" => "r"},
             "C3" => %{"v" => "s"}
           } = peek_cells("sg-paste")
  end

  test "a paste larger than the session's per-call batch cap chunks and fully applies", %{
    conn: conn
  } do
    create_sheet!("sg-paste-big", one_tab(%{}))
    {view, target, _html} = open!(conn, "sg-paste-big")

    # 101 rows x 10 cols = 1_010 cells — one op over the 1_000-op cap, so
    # send_ops must chunk (an unchunked call would be refused whole as
    # batch_too_large and surface the "edit failed" notice).
    cap = Session.max_ops_per_call()
    tsv = Enum.map_join(1..101, "\n", fn r -> Enum.map_join(1..10, "\t", &"r#{r}c#{&1}") end)

    render_hook(target, "cell-click", %{"ref" => "A1", "shift" => false})
    render_hook(target, "paste", %{"tsv" => tsv})

    refute render(view) =~ "edit failed"

    cells = peek_cells("sg-paste-big")
    assert map_size(cells) == 1_010
    assert map_size(cells) > cap
    assert cells["A1"] == %{"v" => "r1c1"}
    assert cells["J101"] == %{"v" => "r101c10"}
  end

  # ── structure ops ──────────────────────────────────────────────────────────

  test "inserting a row via the header menu shifts the grid", %{conn: conn} do
    create_sheet!("sg-insrow", one_tab(%{"A1" => %{"v" => "first"}, "A2" => %{"v" => "second"}}))
    {view, _target, _html} = open!(conn, "sg-insrow")

    # The row-header dropdown is the Studio affordance for row ops.
    view |> element(~s(th[data-r="1"] button.sheet-head-menu-btn)) |> render_click()
    view |> element("div.sheet-menu button", "Insert above") |> render_click()

    render(view)
    cells = peek_cells("sg-insrow")
    assert cells["A2"] == %{"v" => "first"}
    assert cells["A3"] == %{"v" => "second"}
    refute Map.has_key?(cells, "A1")

    # The re-render reflects the shifted refs.
    html = render(view)
    assert html =~ ~s(data-ref="A2" data-r="2" data-c="1" data-v="first")
  end

  test "Cmd/Ctrl+Alt+= inserts rows over the selection; +- deletes them", %{conn: conn} do
    create_sheet!(
      "sg-key-struct",
      one_tab(%{
        "A1" => %{"v" => "first"},
        "A2" => %{"v" => "second"},
        "A3" => %{"v" => "third"}
      })
    )

    {view, target, _html} = open!(conn, "sg-key-struct")

    # Select rows 1-2 (cell-click A1, then shift-nav down), then the keyboard
    # insert lands two rows BEFORE the selection — A1's value shifts to A3.
    render_hook(target, "cell-click", %{"ref" => "A1", "shift" => false})
    render_hook(target, "nav", %{"key" => "ArrowDown", "shift" => true})
    render_hook(target, "rowcol-key", %{"kind" => "row", "action" => "insert"})

    render(view)
    cells = peek_cells("sg-key-struct")
    assert cells["A3"] == %{"v" => "first"}
    assert cells["A4"] == %{"v" => "second"}
    assert cells["A5"] == %{"v" => "third"}
    refute Map.has_key?(cells, "A1")

    # Re-select the two inserted rows and delete — the grid round-trips.
    render_hook(target, "cell-click", %{"ref" => "A1", "shift" => false})
    render_hook(target, "nav", %{"key" => "ArrowDown", "shift" => true})
    render_hook(target, "rowcol-key", %{"kind" => "row", "action" => "delete"})

    render(view)

    assert peek_cells("sg-key-struct") == %{
             "A1" => %{"v" => "first"},
             "A2" => %{"v" => "second"},
             "A3" => %{"v" => "third"}
           }
  end

  # ── merge / unmerge ────────────────────────────────────────────────────────

  test "merging a selection spans the anchor td and covers the rest; unmerge restores",
       %{conn: conn} do
    create_sheet!("sg-merge", one_tab(%{"A1" => %{"v" => "x"}, "B2" => %{"v" => "y"}}))
    {view, target, _html} = open!(conn, "sg-merge")

    # Select A1:B2, then merge.
    render_hook(target, "cell-click", %{"ref" => "A1", "shift" => false})
    render_hook(target, "nav", %{"key" => "ArrowRight", "shift" => true})
    render_hook(target, "nav", %{"key" => "ArrowDown", "shift" => true})
    view |> element(~s([data-test-id="sheet-merge-btn"])) |> render_click()

    assert peek_merges("sg-merge") == ["A1:B2"]

    a1 = view |> element(~s(td[data-ref="A1"])) |> render()
    assert a1 =~ ~s(colspan="2")
    assert a1 =~ ~s(rowspan="2")
    # The covered corner renders no td of its own.
    refute render(view) =~ ~s(data-ref="B2")

    # Unmerge (a single active cell inside the span is a valid target).
    render_hook(target, "cell-click", %{"ref" => "A1", "shift" => false})
    view |> element(~s([data-test-id="sheet-unmerge-btn"])) |> render_click()

    assert peek_merges("sg-merge") == []
    html = render(view)
    assert html =~ ~s(data-ref="B2")
    assert html =~ ~s(data-v="y")
  end

  test "merging a single cell is refused with a notice", %{conn: conn} do
    create_sheet!("sg-merge1", one_tab(%{}))
    {view, target, _html} = open!(conn, "sg-merge1")

    render_hook(target, "cell-click", %{"ref" => "A1", "shift" => false})
    view |> element(~s([data-test-id="sheet-merge-btn"])) |> render_click()

    # The guard refuses before any op is sent, so no session even starts.
    assert render(view) =~ "select at least two cells to merge"
  end

  test "a fill over a merged rect skips the covered cells (no phantom data)", %{conn: conn} do
    create_sheet!("sg-merge-fill", one_tab(%{"A1" => %{"v" => "src"}}))
    {view, target, _html} = open!(conn, "sg-merge-fill")

    render_hook(target, "cell-click", %{"ref" => "A1", "shift" => false})
    render_hook(target, "nav", %{"key" => "ArrowDown", "shift" => true})
    view |> element(~s([data-test-id="sheet-merge-btn"])) |> render_click()
    assert peek_merges("sg-merge-fill") == ["A1:A2"]

    # Fill down from A1 over the merged span — A2 is merge-COVERED, so the
    # fill fence skips it: a value there would never render in the grid but
    # would leak into CSV/exports/formulas (the cycle-6 phantom-data fix,
    # which supersedes the v1 "cells are independent of the merge" policy).
    render_hook(target, "cell-click", %{"ref" => "A1", "shift" => false})
    render_hook(target, "nav", %{"key" => "ArrowDown", "shift" => true})
    render_hook(target, "fill", %{"dir" => "down"})

    refute Map.has_key?(peek_cells("sg-merge-fill"), "A2")
    assert peek_merges("sg-merge-fill") == ["A1:A2"]
  end

  # ── live convergence (two LiveViews) ───────────────────────────────────────

  test "a second LiveView on the same sheet receives the delta and re-renders", %{conn: conn} do
    create_sheet!("sg-two", one_tab(%{}))
    {_view1, target1, _html} = open!(conn, "sg-two")
    {view2, _target2, html2} = open!(Phoenix.ConnTest.build_conn(), "sg-two")

    refute html2 =~ ~s(data-v="live!")

    render_hook(target1, "cell-click", %{"ref" => "A1", "shift" => false})
    render_hook(target1, "edit-commit", %{"value" => "live!", "move" => "none"})

    # The session broadcast reached BOTH LiveView processes.
    assert render(view2) =~ ~s(data-v="live!")
  end

  # ── tab strip ──────────────────────────────────────────────────────────────

  test "tab switch, add, rename and delete", %{conn: conn} do
    tabs = [
      %{"name" => "T0", "cells" => %{"A1" => %{"v" => "alpha"}}},
      %{"name" => "T1", "cells" => %{"A1" => %{"v" => "beta"}}}
    ]

    create_sheet!("sg-tabs", tabs)
    {view, target, html} = open!(conn, "sg-tabs")

    assert html =~ ~s(data-v="alpha")
    refute html =~ ~s(data-v="beta")

    # Switch.
    view |> element(~s([data-test-id="sheet-tab-1"])) |> render_click()
    html = render(view)
    assert html =~ ~s(data-v="beta")
    refute html =~ ~s(data-v="alpha")

    # Add — the new tab appears via the session delta.
    view |> element(~s([data-test-id="sheet-tab-add"])) |> render_click()
    assert render(view) =~ "Sheet 3"

    # Rename (double-click opens the inline form; the event is the contract).
    render_click(target, "tab-rename-start", %{"tab" => "0"})
    assert render(view) =~ ~s(data-test-id="sheet-tab-rename-input")
    render_submit(target, "tab-rename", %{"tab" => "0", "name" => "Budget"})
    assert render(view) =~ "Budget"

    # Delete the added tab.
    render_click(target, "tab-delete", %{"tab" => "2"})
    refute render(view) =~ "Sheet 3"

    {:ok, content} = Session.peek("sg-tabs", @dataset)
    assert content["tabs"] |> Enum.map(& &1["name"]) == ["Budget", "T1"]
  end

  # ── tab strip: reorder / duplicate / a11y / follow-the-tab ──────────────────

  # The whole point of the slice: a structural reorder re-indexes the tab list,
  # so `Ops.apply_delta` must remap @tab (via `refetch/3`) BEFORE the length
  # clamp, or the viewer silently swaps to whatever tab now sits at the old
  # index. `move_tab`/`duplicate_tab` wire+session ops land with the tab-ops
  # slice, so the client remap is proven directly against the structure delta.
  defp remap_tab_via_delta(post_tabs, viewer_tab, structure) do
    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        content: %{"tabs" => post_tabs},
        tab: viewer_tab,
        rev: 1,
        epoch: 1,
        read_only: true
      }
    }

    Ops.apply_delta(socket, %{rev: 2, epoch: 1, tab: 0, changed: %{}, structure: structure}).assigns.tab
  end

  test "move_tab remaps @tab so every viewer follows the moved tab", %{conn: _conn} do
    # A (idx 0) moved to idx 2 → post order [B, C, A].
    post = [%{"name" => "B"}, %{"name" => "C"}, %{"name" => "A"}]
    structure = %{op: "move_tab", from: 0, to: 2}

    # The viewer ON the moved tab follows it to its new slot…
    assert remap_tab_via_delta(post, 0, structure) == 2
    # …and a viewer the move shifted past slides the other way (B: 1 → 0).
    assert remap_tab_via_delta(post, 1, structure) == 0
    # A viewer outside the moved range is untouched by index arithmetic.
    assert remap_tab_via_delta(post, 2, structure) == 1
  end

  test "duplicate_tab keeps the viewer on the source and shifts later tabs", %{conn: _conn} do
    # Duplicate idx 0 → post order [A, Copy of A, B].
    post = [%{"name" => "A"}, %{"name" => "Copy of A"}, %{"name" => "B"}]
    structure = %{op: "duplicate_tab", at: 0}

    # The duplicator STAYS on the source (auto-switch to the copy is skipped).
    assert remap_tab_via_delta(post, 0, structure) == 0
    # A viewer after the source slides down past the inserted copy (B: 1 → 2).
    assert remap_tab_via_delta(post, 1, structure) == 2
  end

  test "a remote delete of an earlier tab keeps this viewer on its own tab", %{conn: conn} do
    tabs = [
      %{"name" => "T0", "cells" => %{"A1" => %{"v" => "zero"}}},
      %{"name" => "T1", "cells" => %{"A1" => %{"v" => "one"}}},
      %{"name" => "T2", "cells" => %{"A1" => %{"v" => "two"}}},
      %{"name" => "T3", "cells" => %{"A1" => %{"v" => "three"}}}
    ]

    create_sheet!("sg-del-follow", tabs)
    {_view1, target1, _html} = open!(conn, "sg-del-follow")
    {view2, _target2, _html} = open!(Phoenix.ConnTest.build_conn(), "sg-del-follow")

    # Viewer 2 sits on tab 2 (T2 / "two").
    view2 |> element(~s([data-test-id="sheet-tab-2"])) |> render_click()
    assert render(view2) =~ ~s(data-v="two")

    # Viewer 1 deletes tab 0 from under everyone. Its index (2) no longer
    # points at T2 — without the remap the clamp leaves @tab=2 → the old-index
    # swap shows T3. The remap slides @tab to 1 (where T2 now lives).
    render_click(target1, "tab-delete", %{"tab" => "0"})

    html2 = render(view2)
    assert html2 =~ ~s(data-v="two")
    refute html2 =~ ~s(data-v="three")
  end

  test "the tab strip exposes tablist/tab a11y plus reorder + duplicate buttons", %{conn: conn} do
    create_sheet!("sg-tabui", [
      %{"name" => "T0", "cells" => %{}},
      %{"name" => "T1", "cells" => %{}}
    ])

    {view, _target, html} = open!(conn, "sg-tabui")

    assert html =~ ~s(role="tablist")
    assert html =~ ~s(aria-label="Sheet tabs")

    # role=tab + aria-selected reflect the active tab.
    assert view |> element(~s([data-test-id="sheet-tab-0"])) |> render() =~ ~s(role="tab")

    assert view |> element(~s([data-test-id="sheet-tab-0"])) |> render() =~
             ~s(aria-selected="true")

    assert view |> element(~s([data-test-id="sheet-tab-1"])) |> render() =~
             ~s(aria-selected="false")

    # ◀ disabled on the first tab, ▶ enabled; Duplicate present.
    assert view |> element(~s([data-test-id="sheet-tab-move-left"])) |> render() =~ "disabled"
    refute view |> element(~s([data-test-id="sheet-tab-move-right"])) |> render() =~ "disabled"
    assert has_element?(view, ~s([data-test-id="sheet-tab-duplicate"]))

    # Switching flips aria-selected, disables ▶ on the last tab, and announces.
    view |> element(~s([data-test-id="sheet-tab-1"])) |> render_click()

    assert view |> element(~s([data-test-id="sheet-tab-1"])) |> render() =~
             ~s(aria-selected="true")

    assert view |> element(~s([data-test-id="sheet-tab-0"])) |> render() =~
             ~s(aria-selected="false")

    assert view |> element(~s([data-test-id="sheet-tab-move-right"])) |> render() =~ "disabled"
    assert render(view) =~ "Sheet 2 of 2: T1"
  end

  test "F2 starts an inline rename and Escape cancels it back to the button", %{conn: conn} do
    create_sheet!("sg-rename-key", [%{"name" => "Sheet 1", "cells" => %{}}])
    {view, target, _html} = open!(conn, "sg-rename-key")

    # The tab button is wired to F2 for rename-start.
    tab0 = view |> element(~s([data-test-id="sheet-tab-0"])) |> render()
    assert tab0 =~ ~s(phx-keydown="tab-rename-start")
    assert tab0 =~ ~s(phx-key="F2")

    # F2 opens the labelled, Escape-wired inline input.
    render_keydown(target, "tab-rename-start", %{"tab" => "0", "key" => "F2"})
    input = render(view)
    assert input =~ ~s(data-test-id="sheet-tab-rename-input")
    assert input =~ ~s(phx-key="Escape")
    assert input =~ ~s(aria-label="Rename Sheet 1")

    # Escape cancels — the button is back and no rename op was sent.
    render_keydown(target, "tab-rename-cancel", %{"key" => "Escape"})
    refute render(view) =~ ~s(data-test-id="sheet-tab-rename-input")
    assert has_element?(view, ~s([data-test-id="sheet-tab-0"]))
  end

  test "the reorder / duplicate buttons announce the action on the polite region", %{conn: conn} do
    create_sheet!("sg-tab-announce", [
      %{"name" => "T0", "cells" => %{}},
      %{"name" => "T1", "cells" => %{}}
    ])

    {view, target, _html} = open!(conn, "sg-tab-announce")

    # The announce is emitted client-side before the op dispatches, so it is
    # observable in isolation (the move_tab/duplicate_tab session ops land with
    # the tab-ops slice; here they no-op through the reject path).
    render_click(target, "tab-move", %{"dir" => "right"})
    assert render(view) =~ "Moved T0 right"

    render_click(target, "tab-duplicate", %{})
    assert render(view) =~ "Duplicated as Copy of T0"
  end

  # ── row paging + column clip ─────────────────────────────────────────────

  test "the pager replaces the hard cap: rows past 500 page into view", %{conn: conn} do
    create_sheet!("sg-page", one_tab(%{"A1" => %{"v" => "top"}, "A600" => %{"v" => "deep"}}))
    {view, _target, html} = open!(conn, "sg-page")

    # Page 0: a live pager (not a dead cap notice), only the first window.
    assert html =~ ~s(data-test-id="sheet-pager")
    refute html =~ ~s(data-test-id="sheet-cap-notice")
    assert html =~ ~s(data-ref="A1")
    refute html =~ ~s(data-ref="A600")

    # Flip forward — the deep row is now reachable, the first window is gone.
    html = view |> element(~s([data-test-id="sheet-pager-next"])) |> render_click()
    assert html =~ ~s(data-ref="A600")
    refute html =~ ~s(data-ref="A1")
    assert html =~ "Showing rows 501"
  end

  test "an edit commits onto a paged-in row via its stable absolute data-ref",
       %{conn: conn} do
    create_sheet!("sg-page-edit", one_tab(%{"A1" => %{"v" => "top"}, "A600" => %{"v" => "deep"}}))
    {view, target, _html} = open!(conn, "sg-page-edit")

    # Page to the window holding row 501 — the active cell resets to its top.
    html = view |> element(~s([data-test-id="sheet-pager-next"])) |> render_click()
    assert html =~ ~s(data-ref="A501")

    # A commit lands on A501 (the reset active) by its ABSOLUTE ref — no
    # window-relative index leaked into the addressing.
    render_hook(target, "edit-commit", %{"value" => "paged-edit", "move" => "none"})
    assert peek_cells("sg-page-edit")["A501"]["v"] == "paged-edit"
    assert render(view) =~ ~s(data-ref="A501")
  end

  test "a column overflow past 64 is surfaced in the pager text", %{conn: conn} do
    wide = Barkpark.Plugins.Sheets.Core.format_ref({70, 1})
    create_sheet!("sg-wide", one_tab(%{"A1" => %{"v" => "x"}, wide => %{"v" => "edge"}}))
    {view, _target, html} = open!(conn, "sg-wide")

    # One screen of rows but 70 columns → the columns-only sentence, no buttons.
    assert html =~ "first 64 of 70 columns"
    refute has_element?(view, ~s([data-test-id="sheet-pager-next"]))
  end
end
