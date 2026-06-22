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
  500-row render cap notice.

  `async: false` — sheet sessions are globally registered processes that
  read/persist through the SQL sandbox (shared mode), same as
  `Barkpark.Plugins.Sheets.SessionTest`.
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

    # Keep the production debounce/idle timers out of test timing.
    put_cfg(debounce_ms: 60_000, idle_stop_ms: 60_000)
    seed_sheet_schema!()
    :ok
  end

  defp put_cfg(overrides) do
    base = Application.get_env(:barkpark, Barkpark.Plugins.Sheets.Session, [])
    Application.put_env(:barkpark, Barkpark.Plugins.Sheets.Session, Keyword.merge(base, overrides))
  end

  defp stop_all_sessions do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(Barkpark.Plugins.Sheets.SessionSupervisor),
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

  test "a paste larger than the session's per-call batch cap chunks and fully applies", %{conn: conn} do
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

  # ── render cap ─────────────────────────────────────────────────────────────

  test "a big sheet renders only the first 500 rows with a cap notice", %{conn: conn} do
    create_sheet!("sg-big", one_tab(%{"A1" => %{"v" => "top"}, "A600" => %{"v" => "deep"}}))
    {_view, _target, html} = open!(conn, "sg-big")

    assert html =~ ~s(data-test-id="sheet-cap-notice")
    assert html =~ "Showing the first 500 of 600 rows"
    assert html =~ ~s(data-ref="A1")
    refute html =~ ~s(data-ref="A600")
  end
end
