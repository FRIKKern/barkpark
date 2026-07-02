defmodule BarkparkWeb.SheetsGridProofTest do
  @moduledoc """
  PROOF story for the Sheets Studio grid editor — one continuous editing
  session, independent of the builders' suites, told through the exact
  events the thin DOM hook (`priv/static/assets/bp-sheet-grid.js`) emits:
  a click on a `td` pushes `cell-click`, the first printable keydown
  pushes `edit-start` with that key as the seed, Enter in the cell input
  pushes `edit-commit` with `move: "down"`, the formula-bar form submits
  `bar-commit`, and Cmd/Ctrl+V pushes `paste` with the clipboard TSV.

  The story: an editor opens the Q3 budget sheet in Studio while a
  colleague holds the same sheet open in a second LiveView. The editor
  types three monthly figures, enters `=SUM(B1:B3)` through the formula
  bar (the computed total appears in the grid, the formula reads back in
  the bar), inserts a row above the data (the SUM's refs shift and still
  compute), then shift-click-selects a 2x2 range and pastes a TSV block
  exactly over it. The colleague's pane shows every change without
  emitting a single event of its own. After the debounce the persisted
  draft row matches the screen cell-for-cell, and a paper created fresh
  AFTERWARDS embedding the sheet (M0a ingest hydration) renders the final
  total in its HTML on the first read.

  `async: false` — sheet sessions are globally registered processes that
  persist through the shared-mode SQL sandbox.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias Barkpark.Plugins.Sheets.Session

  @dataset "production"
  @slug "q3-budget-proof"
  @paper_slug "2026-06-12-q3-budget-readout-proof"

  setup do
    stop_all_sessions()

    on_exit(fn ->
      stop_all_sessions()
      Application.delete_env(:barkpark, Barkpark.Plugins.Sheets.Session)
    end)

    # A SHORT debounce — this story proves the debounced persist itself
    # (the builders' suites park it at 60s and flush by hand).
    put_cfg(debounce_ms: 80, idle_stop_ms: 60_000)

    # Seed the Default scope BEFORE any write so the sheet, the Studio
    # mount and the paper all land in the SAME tenancy scope — the M0a
    # hydration query is scope-laddered.
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

  # Every non-empty cell the grid currently shows, as `%{ref => shown}` —
  # scraped from the `data-ref`/`data-v` attributes the renderer stamps on
  # each td (the same attributes the hook's clipboard copy reads).
  defp screen_cells(html) do
    ~r/data-ref="([^"]+)"[^>]*?data-v="([^"]*)"/
    |> Regex.scan(html)
    |> Enum.reject(fn [_, _ref, v] -> v == "" end)
    |> Map.new(fn [_, ref, v] -> {ref, v} end)
  end

  # The persisted draft row's cells projected to their shown values.
  defp persisted_screen do
    case Content.get_document(Content.draft_id(@slug), "sheet", @dataset) do
      {:ok, doc} ->
        (get_in(doc.content, ["tabs", Access.at(0), "cells"]) || %{})
        |> Map.new(fn {ref, cell} -> {ref, to_string(Map.get(cell, "v"))} end)

      _ ->
        %{}
    end
  end

  defp namebox(view) do
    view |> element(~s([data-test-id="sheet-namebox"])) |> render()
  end

  # The A1 ref stamped on the td the renderer marks `.sheet-active` — the
  # authoritative "where's the cursor" read straight off the grid DOM.
  defp active_ref(html) do
    case Regex.run(~r/sheet-active[^>]*data-ref="([^"]+)"/, html) do
      [_, ref] -> ref
      _ -> nil
    end
  end

  # The space-joined function vocabulary the hook element stamps as data-fns.
  defp data_fns(html) do
    case Regex.run(~r/data-fns="([^"]*)"/, html) do
      [_, names] -> String.split(names, " ", trim: true)
      _ -> []
    end
  end

  # Every "=NAME(" option value in the formula-bar datalist.
  defp datalist_options(html) do
    Regex.scan(~r/<option[^>]*value="(=[A-Za-z0-9]+\()"/, html) |> Enum.map(&Enum.at(&1, 1))
  end

  defp wait_until(fun, timeout \\ 3_000) do
    do_wait_until(fun, System.monotonic_time(:millisecond) + timeout)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition not met in time")

      true ->
        Process.sleep(20)
        do_wait_until(fun, deadline)
    end
  end

  test "grid a11y: aria-activedescendant tracks the active cell and the selected cell is marked",
       %{conn: conn} do
    {:ok, _doc} =
      Content.create_document(
        "sheet",
        %{
          "doc_id" => @slug,
          "content" => %{"tabs" => [%{"name" => "Q3", "cells" => %{"A1" => %{"v" => "x"}}}]}
        },
        @dataset
      )

    path = scoped_studio("/d/#{@dataset}/studio/sheet/#{@slug}")
    {:ok, editor, html} = live(conn, path)
    grid = with_target(editor, "#sheet-grid-#{@slug}")
    base = "sheet-grid-#{@slug}"

    # Active starts at A1 (col 1, row 1): the wrapper points at that cell's
    # id and that cell (its own 1x1 selection) is aria-selected="true".
    assert html =~ ~s(aria-activedescendant="#{base}-cell-1-1")
    assert html =~ ~r/id="#{base}-cell-1-1"[^>]*aria-selected="true"/

    # ArrowDown walks the active cell down one row; the AT pointer follows.
    html = render_hook(grid, "nav", %{"key" => "ArrowDown", "shift" => false})
    assert html =~ ~s(aria-activedescendant="#{base}-cell-1-2")
    assert html =~ ~r/id="#{base}-cell-1-2"[^>]*aria-selected="true"/
    refute html =~ ~s(aria-activedescendant="#{base}-cell-1-1")
  end

  test "grid a11y: SR status region, accessible input names, and a keyboard focus ring",
       %{conn: conn} do
    {:ok, _doc} =
      Content.create_document(
        "sheet",
        %{"doc_id" => @slug, "content" => %{"tabs" => [%{"name" => "Q3", "cells" => %{}}]}},
        @dataset
      )

    path = scoped_studio("/d/#{@dataset}/studio/sheet/#{@slug}")
    {:ok, editor, html} = live(conn, path)
    grid = with_target(editor, "#sheet-grid-#{@slug}")

    # The always-on polite status region and the accessible names on the
    # name box + formula bar (the latter tracks the active cell) are all in
    # the initial render.
    assert html =~ ~s(data-test-id="sheet-status")
    assert html =~ ~s(aria-live="polite")
    assert html =~ ~s(aria-label="Formula bar for A1")
    assert html =~ ~s{aria-label="Cell reference (name box)"}
    # The Studio layout ships the keyboard focus-ring rule. Text-presence
    # gate only — a Chrome contrast check is the true verification (manual,
    # noted in the PR).
    assert html =~ ".sheet-grid-wrap:focus-visible"

    # A formula committed through the bar announces its COMPUTED result on
    # the status region, not the "=..." source.
    html = render_submit(grid, "bar-commit", %{"value" => "=1+1"})
    assert html =~ ~r/data-test-id="sheet-status"[^>]*>[^<]*A1: 2/

    # Navigation re-labels the formula bar for the new active cell.
    html = render_hook(grid, "nav", %{"key" => "ArrowDown", "shift" => false})
    assert html =~ ~s(aria-label="Formula bar for A2")

    # The in-cell editor names itself for the cell being edited.
    render_hook(grid, "cell-click", %{"ref" => "A1", "shift" => false})
    render_hook(grid, "edit-start", %{"seed" => "x"})

    assert editor |> element(~s([data-test-id="sheet-cell-input"])) |> render() =~
             ~s(aria-label="Edit cell A1")
  end

  test "grid a11y: an empty-stack undo fires an assertive role=alert", %{conn: conn} do
    {:ok, _doc} =
      Content.create_document(
        "sheet",
        %{"doc_id" => @slug, "content" => %{"tabs" => [%{"name" => "Q3", "cells" => %{}}]}},
        @dataset
      )

    {:ok, editor, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/sheet/#{@slug}"))
    grid = with_target(editor, "#sheet-grid-#{@slug}")

    # Nothing on the undo stack: the per-op rejection surfaces as a
    # role="alert" notice (an assertive live region), so an SR user hears
    # the failure instead of silence.
    html = render_hook(grid, "undo", %{})
    assert html =~ ~s(role="alert")
    assert html =~ "undo stack"
  end

  test "function autocomplete: hook carries data-fns, the datalist mirrors it as =NAME(, the cell input is a combobox",
       %{conn: conn} do
    {:ok, _doc} =
      Content.create_document(
        "sheet",
        %{"doc_id" => @slug, "content" => %{"tabs" => [%{"name" => "Q3", "cells" => %{}}]}},
        @dataset
      )

    {:ok, editor, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/sheet/#{@slug}"))
    grid = with_target(editor, "#sheet-grid-#{@slug}")

    # The phx-hook element carries the whole function vocabulary, space-joined.
    # Representative names prove it flows from the Engine's supported set — a
    # base function (SUM/IF) AND a wave-added one (COUNTIFS) are both present.
    fns = data_fns(html)
    assert "SUM" in fns
    assert "IF" in fns
    assert "COUNTIFS" in fns

    # The native datalist mirrors data-fns EXACTLY, one option per name, each
    # shaped "=NAME(" (a datalist matches the whole value, so "=SU" matches
    # "=SUM(" while a bare "SUM" never would after the "=").
    assert html =~ ~s(data-test-id="sheet-fns-list")
    for name <- fns, do: assert(html =~ ~s(value="=#{name}("))
    assert length(datalist_options(html)) == length(fns)

    # Editing a cell exposes the combobox ARIA the JS dropdown toggles.
    render_hook(grid, "cell-click", %{"ref" => "A1", "shift" => false})
    render_hook(grid, "edit-start", %{"seed" => "="})
    input_html = editor |> element(~s([data-test-id="sheet-cell-input"])) |> render()
    assert input_html =~ ~s(role="combobox")
    assert input_html =~ ~s(aria-autocomplete="list")
    assert input_html =~ ~s(aria-expanded="false")

    # NOT-editable (the View toggle and the read-only reader share the ONE
    # `@editable` gate — see GridData.derive_editable/1) renders neither the
    # hook's data-fns nor the datalist: no autocomplete surface for a viewer.
    view_html = render_hook(grid, "toggle-mode", %{})
    refute view_html =~ ~s(phx-hook="SheetGrid")
    refute view_html =~ "data-fns="
    refute view_html =~ ~s(data-test-id="sheet-fns-list")
  end

  test "the Q3 budget story: type, sum, insert a row, paste a block — colleague live, debounce persists, the paper embeds",
       %{conn: conn} do
    # The quarterly budget sheet exists with its row labels; the figures
    # are what the editor is about to type.
    {:ok, _doc} =
      Content.create_document(
        "sheet",
        %{
          "doc_id" => @slug,
          "content" => %{
            "locale" => "nb-NO",
            "tabs" => [
              %{
                "name" => "Q3",
                "cells" => %{
                  "A1" => %{"v" => "Jul"},
                  "A2" => %{"v" => "Aug"},
                  "A3" => %{"v" => "Sep"},
                  "A4" => %{"v" => "Total"}
                }
              }
            ]
          }
        },
        @dataset
      )

    # ── the editor and the colleague both open the sheet in Studio ────────
    path = scoped_studio("/d/#{@dataset}/studio/sheet/#{@slug}")

    {:ok, editor, html} = live(conn, path)
    grid = with_target(editor, "#sheet-grid-#{@slug}")
    assert html =~ ~s(data-test-id="studio-sheet-editor")
    assert html =~ ~s(phx-hook="SheetGrid")
    assert html =~ ~s(data-v="Jul")

    {:ok, colleague, colleague_html} = live(Phoenix.ConnTest.build_conn(), path)
    assert colleague_html =~ ~s(data-v="Jul")
    refute colleague_html =~ ~s(data-v="1200")

    # ── three numbers, typed the way the DOM emits them ───────────────────
    # Click B1; first keystroke opens the in-cell input seeded with the
    # typed character; Enter commits and moves down (Excel muscle memory).
    render_hook(grid, "cell-click", %{"ref" => "B1", "shift" => false})

    render_hook(grid, "edit-start", %{"seed" => "1"})
    assert editor |> element(~s([data-test-id="sheet-cell-input"])) |> render() =~ ~s(value="1")
    render_hook(grid, "edit-commit", %{"value" => "1200", "move" => "down"})

    render_hook(grid, "edit-start", %{"seed" => "3"})
    render_hook(grid, "edit-commit", %{"value" => "3400", "move" => "down"})

    render_hook(grid, "edit-start", %{"seed" => "2"})
    render_hook(grid, "edit-commit", %{"value" => "2150", "move" => "down"})

    # Enter walked the active cell down to B4 — the Total row.
    assert namebox(editor) =~ ~s(value="B4")

    # ── the =SUM formula through the formula bar ──────────────────────────
    render_submit(grid, "bar-commit", %{"value" => "=SUM(B1:B3)"})

    html = render(editor)
    # The grid shows the COMPUTED total on B4…
    assert html =~ ~s(data-ref="B4" data-r="4" data-c="2" data-v="6750")
    # …and the bar reads back the formula for the still-active B4.
    assert editor |> element(~s([data-test-id="sheet-formula-bar"])) |> render() =~
             ~s{value="=SUM(B1:B3)"}

    # The colleague sees the total without lifting a finger.
    wait_until(fn -> render(colleague) =~ ~s(data-v="6750") end)

    # ── insert a row above the data: the SUM shifts and still computes ────
    editor |> element(~s(th[data-r="1"] button.sheet-head-menu-btn)) |> render_click()
    editor |> element("div.sheet-menu button", "Insert above") |> render_click()

    html = render(editor)
    assert html =~ ~s(data-ref="A2" data-r="2" data-c="1" data-v="Jul")
    assert html =~ ~s(data-ref="B5" data-r="5" data-c="2" data-v="6750")

    # The session rewrote the formula's refs and recomputed.
    {:ok, content} = Session.peek(@slug, @dataset)

    assert %{"f" => "SUM(B2:B4)", "v" => 6750} =
             get_in(content, ["tabs", Access.at(0), "cells", "B5"])

    wait_until(fn ->
      render(colleague) =~ ~s(data-ref="B5" data-r="5" data-c="2" data-v="6750")
    end)

    # ── select a 2x2 range, paste TSV exactly over it ──────────────────────
    # Click the bottom-right corner, shift-click the top-left: the selection
    # is B2:C3 and the ACTIVE cell is its top-left — pasting a 2x2 TSV block
    # (which the hook reads off the clipboard and applies from the active
    # cell) lands exactly over the selection.
    render_hook(grid, "cell-click", %{"ref" => "C3", "shift" => false})
    html = render_hook(grid, "cell-click", %{"ref" => "B2", "shift" => true})
    assert length(String.split(html, "sheet-sel")) - 1 == 4

    render_hook(grid, "paste", %{"tsv" => "1300\t1500\n3500\t3600\n"})

    html = render(editor)
    assert html =~ ~s(data-ref="B2" data-r="2" data-c="2" data-v="1300")
    assert html =~ ~s(data-ref="C3" data-r="3" data-c="3" data-v="3600")
    # The total recomputed over the pasted figures: 1300 + 3500 + 2150.
    assert html =~ ~s(data-ref="B5" data-r="5" data-c="2" data-v="6950")

    # ── the colleague's pane converged on the whole story, hands off ──────
    expected_screen = %{
      "A2" => "Jul",
      "A3" => "Aug",
      "A4" => "Sep",
      "A5" => "Total",
      "B2" => "1300",
      "C2" => "1500",
      "B3" => "3500",
      "C3" => "3600",
      "B4" => "2150",
      "B5" => "6950"
    }

    assert screen_cells(render(editor)) == expected_screen
    wait_until(fn -> screen_cells(render(colleague)) == expected_screen end)

    # ── after the debounce, the persisted doc matches the screen ──────────
    wait_until(fn -> persisted_screen() == expected_screen end)

    {:ok, doc} = Content.get_document(Content.draft_id(@slug), "sheet", @dataset)
    persisted = get_in(doc.content, ["tabs", Access.at(0), "cells"])
    assert Enum.sort(Map.keys(persisted)) == Enum.sort(Map.keys(expected_screen))
    assert %{"f" => "SUM(B2:B4)", "v" => 6950} = persisted["B5"]

    # ── M0a: a paper created fresh AFTER the sheet embeds the final total ─
    {:ok, _paper} =
      Content.upsert_paper(%{
        slug: @paper_slug,
        title: "Q3 budget readout",
        blocks: [%{"id" => "grid", "type" => "sheet", "ref" => @slug, "tab" => 0}]
      })

    {:ok, _view, paper_html} = live(Phoenix.ConnTest.build_conn(), "/papers/#{@paper_slug}")
    assert paper_html =~ "<table"
    assert paper_html =~ "Total"
    assert paper_html =~ "6950"
    assert paper_html =~ "1300"
    refute paper_html =~ "6750"
  end

  # Opens a small sheet in Studio, returns the LiveView + its grid target.
  defp open_grid(conn) do
    {:ok, _doc} =
      Content.create_document(
        "sheet",
        %{
          "doc_id" => @slug,
          "content" => %{
            "locale" => "nb-NO",
            "tabs" => [%{"name" => "Q3", "cells" => %{"B2" => %{"v" => "seed"}}}]
          }
        },
        @dataset
      )

    {:ok, editor, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/sheet/#{@slug}"))
    {editor, with_target(editor, "#sheet-grid-#{@slug}")}
  end

  test "Shift+Enter commits and moves the active cell UP", %{conn: conn} do
    {editor, grid} = open_grid(conn)

    # Land on B3, type, then Shift+Enter (the hook sends move: "up").
    render_hook(grid, "cell-click", %{"ref" => "B3", "shift" => false})
    render_hook(grid, "edit-start", %{"seed" => "x"})
    render_hook(grid, "edit-commit", %{"value" => "42", "move" => "up"})

    html = render(editor)
    # The value committed on B3…
    assert html =~ ~s(data-ref="B3" data-r="3" data-c="2" data-v="42")
    # …and the active cell walked UP to B2.
    assert active_ref(html) == "B2"
    assert namebox(editor) =~ ~s(value="B2")
  end

  test "move: \"up\" at row 1 clamps — the active cell stays put", %{conn: conn} do
    {editor, grid} = open_grid(conn)

    render_hook(grid, "cell-click", %{"ref" => "C1", "shift" => false})
    render_hook(grid, "edit-start", %{"seed" => "z"})
    render_hook(grid, "edit-commit", %{"value" => "9", "move" => "up"})

    html = render(editor)
    assert html =~ ~s(data-ref="C1" data-r="1" data-c="3" data-v="9")
    # Row 1 has no cell above — the move clamps and C1 stays active.
    assert active_ref(html) == "C1"
    assert namebox(editor) =~ ~s(value="C1")
  end

  test "freeze-panes freezes above/left of the active cell and re-toggles to unfreeze",
       %{conn: conn} do
    {editor, grid} = open_grid(conn)

    # Active on B3 (col 2, row 3): Excel freezes the 2 rows above and the 1
    # column to the left.
    render_hook(grid, "cell-click", %{"ref" => "B3", "shift" => false})
    render_hook(grid, "freeze-panes", %{})

    {:ok, content} = Session.peek(@slug, @dataset)
    tab = get_in(content, ["tabs", Access.at(0)])
    assert Map.get(tab, "frozen_rows") == 2
    assert Map.get(tab, "frozen_cols") == 1

    # The grid never applies to its own assigns — the frozen band rides the
    # session broadcast back into this LiveView; render/1 drains it. The
    # frozen column head then carries the sticky offset from
    # Cells.col_head_style, and the toolbar button flips to Unfreeze.
    wait_until(fn -> render(editor) =~ ~s(style="left: 44px; z-index: 5;" data-c="1") end)
    html = render(editor)
    assert html =~ ~s(data-test-id="sheet-freeze-toggle")
    assert html =~ "Unfreeze"

    # A second toggle unfreezes: both bands clear (keys deleted, sparse).
    render_hook(grid, "freeze-panes", %{})
    {:ok, content} = Session.peek(@slug, @dataset)
    tab = get_in(content, ["tabs", Access.at(0)])
    refute Map.has_key?(tab, "frozen_rows")
    refute Map.has_key?(tab, "frozen_cols")

    wait_until(fn -> render(editor) =~ ~r/sheet-freeze-toggle">\s*Freeze\s*<\/button>/ end)
  end

  test "Tab nav round-trip: ArrowRight then ArrowLeft returns to the origin cell", %{conn: conn} do
    {_editor, grid} = open_grid(conn)

    render_hook(grid, "cell-click", %{"ref" => "B2", "shift" => false})

    # Exactly the payloads the new Tab / Shift+Tab handler emits.
    html = render_hook(grid, "nav", %{"key" => "ArrowRight", "shift" => false})
    assert active_ref(html) == "C2"

    html = render_hook(grid, "nav", %{"key" => "ArrowLeft", "shift" => false})
    assert active_ref(html) == "B2"
  end

  # Seeds a sheet with the given cells map and opens it in Studio.
  defp open_grid_with(conn, cells) do
    {:ok, _doc} =
      Content.create_document(
        "sheet",
        %{
          "doc_id" => @slug,
          "content" => %{"tabs" => [%{"name" => "Q3", "cells" => cells}]}
        },
        @dataset
      )

    {:ok, editor, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/sheet/#{@slug}"))
    {editor, with_target(editor, "#sheet-grid-#{@slug}")}
  end

  defp cell(ref),
    do: get_in(elem(Session.peek(@slug, @dataset), 1), ["tabs", Access.at(0), "cells", ref])

  test "Ctrl+D fill down rebases the source row's formula per step; $-anchors stay pinned",
       %{conn: conn} do
    {_editor, grid} =
      open_grid_with(conn, %{
        "B2" => %{"f" => "A2*2"},
        "C2" => %{"f" => "$A$2*2"}
      })

    # Select B2:C4 (source row is row 2), then fill down.
    render_hook(grid, "cell-click", %{"ref" => "B2", "shift" => false})
    render_hook(grid, "cell-click", %{"ref" => "C4", "shift" => true})
    render_hook(grid, "fill", %{"dir" => "down"})

    # Relative refs walk one row per step…
    assert %{"f" => "A3*2"} = cell("B3")
    assert %{"f" => "A4*2"} = cell("B4")
    # …the fully-anchored ref never moves.
    assert %{"f" => "$A$2*2"} = cell("C3")
    assert %{"f" => "$A$2*2"} = cell("C4")
    # The source cell itself is untouched.
    assert %{"f" => "A2*2"} = cell("B2")
  end

  test "Ctrl+R fill right rebases the source column's formula per step", %{conn: conn} do
    {_editor, grid} = open_grid_with(conn, %{"A2" => %{"f" => "A1+1"}})

    render_hook(grid, "cell-click", %{"ref" => "A2", "shift" => false})
    render_hook(grid, "cell-click", %{"ref" => "C2", "shift" => true})
    render_hook(grid, "fill", %{"dir" => "right"})

    assert %{"f" => "B1+1"} = cell("B2")
    assert %{"f" => "C1+1"} = cell("C2")
  end

  test "fill down copies a scalar source verbatim", %{conn: conn} do
    {_editor, grid} = open_grid_with(conn, %{"B2" => %{"v" => 42}})

    render_hook(grid, "cell-click", %{"ref" => "B2", "shift" => false})
    render_hook(grid, "cell-click", %{"ref" => "B4", "shift" => true})
    render_hook(grid, "fill", %{"dir" => "down"})

    assert %{"v" => 42} = cell("B3")
    assert %{"v" => 42} = cell("B4")
  end

  test "fill down from a blank source CLEARS the target cells", %{conn: conn} do
    # B2 (the source row) is blank; B3/B4 carry values.
    {_editor, grid} =
      open_grid_with(conn, %{"B3" => %{"v" => "old"}, "B4" => %{"v" => "stale"}})

    render_hook(grid, "cell-click", %{"ref" => "B2", "shift" => false})
    render_hook(grid, "cell-click", %{"ref" => "B4", "shift" => true})
    render_hook(grid, "fill", %{"dir" => "down"})

    assert cell("B3") == nil
    assert cell("B4") == nil
  end

  # Seeds a sheet from a full tab map (so a test can pin "merges") and opens it.
  defp open_grid_with_tab(conn, tab) do
    {:ok, _doc} =
      Content.create_document(
        "sheet",
        %{"doc_id" => @slug, "content" => %{"tabs" => [tab]}},
        @dataset
      )

    {:ok, editor, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/sheet/#{@slug}"))
    {editor, with_target(editor, "#sheet-grid-#{@slug}")}
  end

  test "fill down never writes into a merge-covered cell (no phantom data)", %{conn: conn} do
    # A1:B2 merged, A1 the anchor holds the source. Filling A1:B3 down would
    # otherwise target B1/B2 — both covered — so those cells must stay empty.
    {_editor, grid} =
      open_grid_with_tab(conn, %{
        "name" => "Q3",
        "cells" => %{"A1" => %{"v" => "top"}},
        "merges" => ["A1:B2"]
      })

    render_hook(grid, "cell-click", %{"ref" => "A1", "shift" => false})
    render_hook(grid, "cell-click", %{"ref" => "B3", "shift" => true})
    render_hook(grid, "fill", %{"dir" => "down"})

    # The merge covers B1/B2 — the fill plants no value the grid never renders.
    assert cell("B1") == nil
    assert cell("B2") == nil
    # A3 (uncovered, source A1 uncovered) still fills.
    assert %{"v" => "top"} = cell("A3")
  end

  test "fill stamps the source cell's fmt onto the target (Excel parity)", %{conn: conn} do
    # Source B2 is currency, target B3 was percent — after fill B3 reads
    # currency (a stale format is overwritten, not left behind).
    {_editor, grid} =
      open_grid_with_tab(conn, %{
        "name" => "Q3",
        "cells" => %{
          "B2" => %{"v" => 100, "fmt" => "currency"},
          "B3" => %{"v" => 5, "fmt" => "percent"}
        }
      })

    render_hook(grid, "cell-click", %{"ref" => "B2", "shift" => false})
    render_hook(grid, "cell-click", %{"ref" => "B3", "shift" => true})
    render_hook(grid, "fill", %{"dir" => "down"})

    assert %{"v" => 100, "fmt" => "currency"} = cell("B3")
  end

  test "undo after a fill restores the target cell exactly, fmt included", %{conn: conn} do
    {_editor, grid} =
      open_grid_with_tab(conn, %{
        "name" => "Q3",
        "cells" => %{
          "B2" => %{"v" => 100, "fmt" => "currency"},
          "B3" => %{"v" => 5, "fmt" => "percent"}
        }
      })

    render_hook(grid, "cell-click", %{"ref" => "B2", "shift" => false})
    render_hook(grid, "cell-click", %{"ref" => "B3", "shift" => true})
    render_hook(grid, "fill", %{"dir" => "down"})
    assert %{"fmt" => "currency"} = cell("B3")

    render_hook(grid, "undo", %{})
    assert cell("B3") == %{"v" => 5, "fmt" => "percent"}
  end

  # Every td's (data-c, aria-selected) pair, scraped in render order — the
  # renderer stamps aria-selected BEFORE data-c on each cell.
  defp col_selection(html) do
    ~r/aria-selected="([^"]*)"[^>]*data-c="(\d+)"/
    |> Regex.scan(html)
    |> Enum.map(fn [_, sel, c] -> {String.to_integer(c), sel == "true"} end)
  end

  # Which columns have at least one selected td (the whole-column gesture
  # selects EVERY rendered row of the column, so this reads as "column N is
  # picked").
  defp selected_cols(html) do
    col_selection(html)
    |> Enum.filter(fn {_c, sel?} -> sel? end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
    |> Enum.sort()
  end

  test "header click selects the whole rendered column; shift-click extends the span",
       %{conn: conn} do
    {_editor, grid} = open_grid(conn)

    # Plain click on column 2's header selects EVERY rendered cell in col 2,
    # nothing else, and lands the active cell at the column's top (B1).
    html = render_hook(grid, "head-click", %{"kind" => "col", "index" => 2, "shift" => false})

    col2 = col_selection(html) |> Enum.filter(fn {c, _} -> c == 2 end)
    assert col2 != []
    assert Enum.all?(col2, fn {_c, sel?} -> sel? end)
    assert selected_cols(html) == [2]
    assert active_ref(html) == "B1"

    # Shift-clicking column 4's header extends from the prior active column
    # (2) through 4 — the whole 2..4 band, no more.
    html = render_hook(grid, "head-click", %{"kind" => "col", "index" => 4, "shift" => true})
    assert selected_cols(html) == [2, 3, 4]
  end

  test "header click on a row + wave-5 rowcol-key delete removes that row (the idiom composes)",
       %{conn: conn} do
    # Three labelled rows so a delete is observable by the shift-up.
    {editor, grid} =
      open_grid_with(conn, %{
        "A1" => %{"v" => "r1"},
        "A2" => %{"v" => "r2"},
        "A3" => %{"v" => "r3"}
      })

    # Click row 2's header — the whole row selects and the active cell lands
    # at its left edge (A2), which is exactly what rowcol-key targets.
    html = render_hook(grid, "head-click", %{"kind" => "row", "index" => 2, "shift" => false})
    assert active_ref(html) == "A2"

    # The Excel whole-row delete idiom: header-select then Cmd/Ctrl+Alt+-.
    render_hook(grid, "rowcol-key", %{"kind" => "row", "action" => "delete"})

    # Row 2 is gone; row 3 shifted up into row 2. Proven on the SESSION, not
    # just the render — the slices genuinely compose end to end.
    {:ok, content} = Session.peek(@slug, @dataset)
    cells = get_in(content, ["tabs", Access.at(0), "cells"])
    assert %{"v" => "r1"} = Map.get(cells, "A1")
    assert %{"v" => "r3"} = Map.get(cells, "A2")
    assert Map.get(cells, "A3") == nil

    # The rendered grid agrees.
    html = render(editor)
    assert screen_cells(html) == %{"A1" => "r1", "A2" => "r3"}
  end

  test "click-away mid-edit COMMITS the draft (Excel semantics, not silent discard)",
       %{conn: conn} do
    {:ok, _doc} =
      Content.create_document(
        "sheet",
        %{
          "doc_id" => @slug,
          "content" => %{"tabs" => [%{"name" => "Q3", "cells" => %{"A1" => %{"v" => "old"}}}]}
        },
        @dataset
      )

    path = scoped_studio("/d/#{@dataset}/studio/sheet/#{@slug}")
    {:ok, editor, _html} = live(conn, path)
    grid = with_target(editor, "#sheet-grid-#{@slug}")

    # Start editing A1, then click B2 with the hook's draft riding along.
    render_hook(grid, "cell-click", %{"ref" => "A1", "shift" => false})
    render_hook(grid, "edit-start", %{})

    html =
      render_hook(grid, "cell-click", %{"ref" => "B2", "shift" => false, "commit" => "typed-away"})

    # The cursor moves synchronously; the committed value arrives as a
    # session delta (the component never applies its own ops).
    assert active_ref(html) == "B2"
    wait_until(fn -> screen_cells(render(editor))["A1"] == "typed-away" end)
    assert screen_cells(render(editor))["A1"] == "typed-away"

    # A plain cell-click (no commit param) moves the cursor and discards
    # nothing it shouldn't — the grid is unchanged.
    render_hook(grid, "edit-start", %{})
    html = render_hook(grid, "cell-click", %{"ref" => "C3", "shift" => false})
    assert active_ref(html) == "C3"
    assert screen_cells(render(editor)) == %{"A1" => "typed-away"}

    # A forged commit param with NO editor open mutates nothing.
    render_hook(grid, "cell-click", %{"ref" => "A1", "shift" => false, "commit" => "forged"})
    assert screen_cells(render(editor)) == %{"A1" => "typed-away"}
  end
end
