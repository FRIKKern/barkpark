defmodule BarkparkWeb.Studio.SheetGrid.FormulaAcceptanceTest do
  @moduledoc """
  Sheets formula-UX epic — S8 acceptance golden, server-side.

  This is the ExUnit twin of the wish's Done-bar: type `=sum(`, mark
  B3:B5, hit Enter — get `=SUM(B3:B5)` and a 6. The flagship wiring
  (point-mode, ghost predictor, rainbow outlines) is 100% CLIENT-owned
  (charter Decision 1): the server only ever sees the final
  `edit-commit` / `bar-commit` payload. So this file drives exactly
  those two events through the real Studio grid + `Sheets.Session` spine
  and pins the server contract the client wiring rides on:

    * THE WISH GOLDEN — seed 1/2/3 → commit `=SUM(B3:B5)` from B6 with a
      down move → the grid shows 6 and the cursor lands on B7.
    * VERBATIM ROUND-TRIP (Decision 11) — canonicalization is CLIENT-side;
      no server write path rewrites formula text. A committed formula
      re-renders byte-identical to what was pushed, INCLUDING a lowercase
      `=sum(b3:b5)` staying lowercase in its raw / bar-prefill form.
    * LOWERCASE EVAL PARITY — that same lowercase formula still evaluates
      to 6 (the Engine upcases fn-names + refs at eval only), documenting
      the charter's accepted "API-lowercase stays lowercase" gap.
    * BAR PATH — the wish golden again via `bar-commit`.
    * STAMP GUARDS (Decisions 8, 9) — the editable grid carries
      `data-fn-sigs` and numeric tds carry `data-t="n"` (a text cell does
      not), the wave-1 stamps the client wiring reads.

  `async: false` — sheet sessions are globally registered processes that
  read/persist through the SQL sandbox (shared mode), same discipline as
  `BarkparkWeb.Studio.StudioLiveSheetGridTest`, on which this harness is
  modelled (setup + private helpers copied minimally, that file untouched).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias Barkpark.Plugins.Sheets.Engine
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

  # ── harness (copied minimally from StudioLiveSheetGridTest) ──────────────────

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

  defp namebox(view) do
    view |> element(~s([data-test-id="sheet-namebox"])) |> render()
  end

  defp bar(view) do
    view |> element(~s([data-test-id="sheet-formula-bar"])) |> render()
  end

  # The visible v of a single td by its absolute ref — scopes the "6 in B6"
  # check to the ONE cell so a stray "6" elsewhere can't fake a green.
  defp cell_v(view, ref) do
    [_, v] =
      Regex.run(
        ~r/data-ref="#{ref}"[^>]*data-v="([^"]*)"/,
        view |> element(~s(td[data-ref="#{ref}"])) |> render()
      )

    v
  end

  # Decode the HTML-attribute entity encoding HEEx applies to an attribute
  # value (matches StudioLiveSheetGridTest.unescape_attr).
  defp unescape_attr(s) do
    s
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&amp;", "&")
  end

  # Seed a vertical run of numbers from `top` downward, exactly the way an
  # operator types a column: click the top cell, then commit each value with
  # a down move so the cursor walks the column (Excel muscle memory). Returns
  # the target: the active cell after the last down move (one below the run).
  defp seed_column!(target, top, values) do
    render_hook(target, "cell-click", %{"ref" => top, "shift" => false})

    for v <- values do
      render_hook(target, "edit-commit", %{"value" => to_string(v), "move" => "down"})
    end

    :ok
  end

  # ── THE WISH GOLDEN ─────────────────────────────────────────────────────────

  test "type the column, commit =SUM(B3:B5) from B6 with Enter → 6 lands, cursor drops to B7",
       %{conn: conn} do
    create_sheet!("fa-wish", one_tab(%{}))
    {view, target, _html} = open!(conn, "fa-wish")

    # Type 1/2/3 down B3:B5; the down-walk parks the cursor on B6.
    seed_column!(target, "B3", [1, 2, 3])
    assert namebox(view) =~ ~s(value="B6")

    # Numbers coerced to real integers through the session (numeric truth).
    assert %{"B3" => %{"v" => 1}, "B4" => %{"v" => 2}, "B5" => %{"v" => 3}} =
             peek_cells("fa-wish")

    # The wish keystroke: the completed formula + Enter (a down move).
    render_hook(target, "cell-click", %{"ref" => "B6", "shift" => false})
    render_hook(target, "edit-commit", %{"value" => "=SUM(B3:B5)", "move" => "down"})

    # The grid shows a 6 in B6 (scoped to that td)…
    assert cell_v(view, "B6") == "6"
    # …and the FORMULA cell re-stamps data-t="n" (Decision 8's second branch:
    # a formula whose cached value is numeric feeds the ghost predictor exactly
    # like a typed number, so a later =SUM( can chain off computed cells)…
    assert view |> element(~s(td[data-ref="B6"])) |> render() =~ ~s(data-t="n")
    # …the session cached both the (un-`=`-prefixed) formula and its value…
    assert %{"B6" => %{"f" => "SUM(B3:B5)", "v" => 6}} = peek_cells("fa-wish")
    # …and Enter dropped the cursor one row down to B7 (Excel commit-move).
    assert namebox(view) =~ ~s(value="B7")
  end

  # ── VERBATIM ROUND-TRIP (Decision 11: server never rewrites formula text) ───

  test "an uppercase formula re-renders byte-identical to what was pushed", %{conn: conn} do
    create_sheet!(
      "fa-verbatim-up",
      one_tab(%{"B3" => %{"v" => 1}, "B4" => %{"v" => 2}, "B5" => %{"v" => 3}})
    )

    {view, target, _html} = open!(conn, "fa-verbatim-up")

    render_hook(target, "cell-click", %{"ref" => "B6", "shift" => false})
    render_hook(target, "edit-commit", %{"value" => "=SUM(B3:B5)", "move" => "none"})

    # Stored as `f` WITHOUT the leading "="; the bar prefill / data-raw
    # reconstructs the exact "=SUM(B3:B5)" that was pushed.
    assert %{"B6" => %{"f" => "SUM(B3:B5)"}} = peek_cells("fa-verbatim-up")
    assert bar(view) =~ ~s{value="=SUM(B3:B5)"}
    assert bar(view) =~ ~s{data-raw="=SUM(B3:B5)"}
  end

  test "a LOWERCASE =sum(b3:b5) stays lowercase in the stored + re-rendered raw form",
       %{conn: conn} do
    create_sheet!(
      "fa-verbatim-low",
      one_tab(%{"B3" => %{"v" => 1}, "B4" => %{"v" => 2}, "B5" => %{"v" => 3}})
    )

    {view, target, _html} = open!(conn, "fa-verbatim-low")

    render_hook(target, "cell-click", %{"ref" => "B6", "shift" => false})
    # Canonicalization is CLIENT-side (Decision 11): the raw payload the server
    # receives is never uppercased by any write path. A lowercase commit that
    # skips the client normalizer (an API/scripted push) stays lowercase.
    render_hook(target, "edit-commit", %{"value" => "=sum(b3:b5)", "move" => "none"})

    # Byte-identical: stored `f` keeps the lowercase text, bar prefill mirrors it.
    assert %{"B6" => %{"f" => "sum(b3:b5)"}} = peek_cells("fa-verbatim-low")
    assert bar(view) =~ ~s{value="=sum(b3:b5)"}
    assert bar(view) =~ ~s{data-raw="=sum(b3:b5)"}
    # And the server did NOT sneak an uppercase copy in anywhere.
    refute bar(view) =~ "=SUM(B3:B5)"
  end

  # ── LOWERCASE EVAL PARITY (Engine case-insensitivity) ───────────────────────

  test "the lowercase =sum(b3:b5) still evaluates to 6 despite staying lowercase in raw",
       %{conn: conn} do
    create_sheet!(
      "fa-low-eval",
      one_tab(%{"B3" => %{"v" => 1}, "B4" => %{"v" => 2}, "B5" => %{"v" => 3}})
    )

    {view, target, _html} = open!(conn, "fa-low-eval")

    render_hook(target, "cell-click", %{"ref" => "B6", "shift" => false})
    render_hook(target, "edit-commit", %{"value" => "=sum(b3:b5)", "move" => "none"})

    # The Engine upcases fn-names + refs at eval time only, so the lowercase
    # formula computes 6 — the raw text staying lowercase (asserted above) is a
    # display concern, not an evaluation one.
    assert cell_v(view, "B6") == "6"
    assert %{"B6" => %{"f" => "sum(b3:b5)", "v" => 6}} = peek_cells("fa-low-eval")
  end

  # ── BAR PATH ─────────────────────────────────────────────────────────────────

  test "the wish golden via the formula bar: bar-commit =SUM(B3:B5) → 6", %{conn: conn} do
    create_sheet!(
      "fa-bar",
      one_tab(%{"B3" => %{"v" => 1}, "B4" => %{"v" => 2}, "B5" => %{"v" => 3}})
    )

    {view, target, _html} = open!(conn, "fa-bar")

    render_hook(target, "cell-click", %{"ref" => "B6", "shift" => false})
    render_hook(target, "bar-commit", %{"value" => "=SUM(B3:B5)"})

    assert cell_v(view, "B6") == "6"
    assert %{"B6" => %{"f" => "SUM(B3:B5)", "v" => 6}} = peek_cells("fa-bar")
    # A bar Enter with no move leaves the active cell put (the bar still reads B6).
    assert namebox(view) =~ ~s(value="B6")
    assert bar(view) =~ ~s{value="=SUM(B3:B5)"}
  end

  # ── STAMP GUARDS (Decisions 8, 9 — the wave-1 stamps the client reads) ──────

  test "the editable grid stamps data-fn-sigs; numeric tds carry data-t=n, text tds don't",
       %{conn: conn} do
    create_sheet!("fa-stamps", one_tab(%{"A1" => %{"v" => "hello"}, "B2" => %{"v" => 7}}))
    {_view, _target, html} = open!(conn, "fa-stamps")

    # Decision 9: server-owned signatures, stamped once as a NAME-keyed JSON
    # object whose key set is exactly Engine.function_names/0 — the client's
    # O(1) signature index for the dropdown + signature strip.
    [_, encoded] = Regex.run(~r/data-fn-sigs="([^"]*)"/, html)
    {:ok, sigs} = Jason.decode(unescape_attr(encoded))
    assert MapSet.new(Map.keys(sigs)) == MapSet.new(Engine.function_names())
    assert %{"args" => [_ | _], "doc" => doc} = sigs["SUM"]
    assert is_binary(doc) and doc != ""

    # Decision 8: numeric truth is server-stamped, not display-parsed. The
    # number cell carries data-t="n"; the text cell omits the attribute (nil →
    # no attribute), so the ghost predictor never mistakes text for a number.
    [b2_td] = Regex.run(~r/<td[^>]*data-ref="B2"[^>]*>/, html)
    assert b2_td =~ ~s(data-t="n")
    [a1_td] = Regex.run(~r/<td[^>]*data-ref="A1"[^>]*>/, html)
    refute a1_td =~ "data-t="
  end
end
