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

    wait_until(fn -> render(colleague) =~ ~s(data-ref="B5" data-r="5" data-c="2" data-v="6750") end)

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
end
