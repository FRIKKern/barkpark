defmodule Barkpark.Plugins.Sheets.SessionSetCellMetaTest do
  @moduledoc """
  Locks for the `set_cell_meta` op — the DISPLAY-ONLY number-format + cell-
  style write behind the Studio toolbar apply-UI.

  The invariants: it stamps "fmt"/"s" onto the EXISTING cell without touching
  "v"/"f" (never re-parses raw — a stored string stays a string); "fmt" is
  validated against `Fmt.vocabulary`; "s" is validated by a STRICT grammar
  (b/i boolean, al left|center|right, bg #rrggbb) with an empty map clearing
  "s"; formatting an empty cell is refused (`empty_cell`); a merge-covered ref
  is refused (`merged_cell`); and the inverse restores the exact prior cell so
  undo/redo round-trips.

  `async: false` — sessions are globally registered processes, same as
  `Barkpark.Plugins.Sheets.SessionTest`.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Plugins.Sheets.Session

  @dataset "sheets_set_cell_meta_test"

  setup do
    stop_all_sessions()

    on_exit(fn ->
      stop_all_sessions()
      Application.delete_env(:barkpark, Barkpark.Plugins.Sheets.Session)
    end)

    put_cfg(debounce_ms: 60_000, idle_stop_ms: 60_000)
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

  defp create_sheet(slug, cells) do
    {:ok, doc} =
      Content.create_document(
        "sheet",
        %{"doc_id" => slug, "content" => %{"tabs" => [%{"name" => "T0", "cells" => cells}]}},
        @dataset
      )

    doc
  end

  defp set_cell(ref, raw, user \\ "u"),
    do: %{"op" => "set_cell", "tab" => 0, "ref" => ref, "raw" => raw, "user" => user}

  defp set_meta(ref, extra, user \\ "u"),
    do: Map.merge(%{"op" => "set_cell_meta", "tab" => 0, "ref" => ref, "user" => user}, extra)

  defp undo(user), do: %{"op" => "undo", "user" => user}
  defp redo(user), do: %{"op" => "redo", "user" => user}

  defp apply!(slug, ops) do
    {:ok, reply} = Session.apply_ops(slug, @dataset, ops)
    reply
  end

  defp cell(slug, ref, tab \\ 0) do
    {:ok, content} = Session.peek(slug, @dataset)
    get_in(content, ["tabs", Access.at(tab), "cells", ref])
  end

  # ── fmt set / clear / invalid ───────────────────────────────────────────────

  test "set_cell_meta stamps a fmt onto an existing cell, leaving v untouched" do
    create_sheet("m-fmt", %{"A1" => %{"v" => 1234.5}})

    assert %{applied: 1, errors: []} = apply!("m-fmt", [set_meta("A1", %{"fmt" => "currency"})])
    assert cell("m-fmt", "A1") == %{"v" => 1234.5, "fmt" => "currency"}
  end

  test "a nil fmt CLEARS the format" do
    create_sheet("m-clear", %{"A1" => %{"v" => 0.25, "fmt" => "percent"}})

    assert %{applied: 1, errors: []} = apply!("m-clear", [set_meta("A1", %{"fmt" => nil})])
    assert cell("m-clear", "A1") == %{"v" => 0.25}
  end

  test "an unknown fmt is rejected (invalid_fmt) and the cell is untouched" do
    create_sheet("m-badfmt", %{"A1" => %{"v" => 5}})

    assert %{applied: 0, errors: [%{index: 0, code: "invalid_fmt"}]} =
             apply!("m-badfmt", [set_meta("A1", %{"fmt" => "money"})])

    assert cell("m-badfmt", "A1") == %{"v" => 5}
  end

  # ── the anti-mutation guarantee: raw is NEVER re-parsed ──────────────────────

  test "formatting a string that looks numeric does NOT coerce it to a number" do
    # set_cell stores "0123" as the STRING "0123"; a formatting gesture must
    # never round-trip it through build_cell and turn it into 123.
    create_sheet("m-noparse", %{})
    assert %{applied: 1, errors: []} = apply!("m-noparse", [set_cell("A1", "0123")])
    assert %{"v" => "0123"} = cell("m-noparse", "A1")

    assert %{applied: 1, errors: []} = apply!("m-noparse", [set_meta("A1", %{"fmt" => "fixed"})])
    assert cell("m-noparse", "A1") == %{"v" => "0123", "fmt" => "fixed"}
  end

  # ── s validation ────────────────────────────────────────────────────────────

  test "a valid style map is stored; an empty map clears the style" do
    create_sheet("m-style", %{"A1" => %{"v" => "hi"}})

    assert %{applied: 1, errors: []} =
             apply!("m-style", [set_meta("A1", %{"s" => %{"b" => true, "al" => "center"}})])

    assert cell("m-style", "A1") == %{"v" => "hi", "s" => %{"b" => true, "al" => "center"}}

    assert %{applied: 1, errors: []} = apply!("m-style", [set_meta("A1", %{"s" => %{}})])
    assert cell("m-style", "A1") == %{"v" => "hi"}
  end

  test "the strict style grammar rejects bad align, bg, and boolean values" do
    create_sheet("m-badstyle", %{"A1" => %{"v" => "x"}})

    for bad <- [%{"al" => "middle"}, %{"bg" => "red"}, %{"b" => "yes"}, %{"unknown" => 1}] do
      assert %{applied: 0, errors: [%{index: 0, code: "invalid_style"}]} =
               apply!("m-badstyle", [set_meta("A1", %{"s" => bad})])
    end

    # None of the rejects mutated the cell.
    assert cell("m-badstyle", "A1") == %{"v" => "x"}
  end

  test "a valid #rrggbb bg is accepted" do
    create_sheet("m-bg", %{"A1" => %{"v" => 1}})

    assert %{applied: 1, errors: []} =
             apply!("m-bg", [set_meta("A1", %{"s" => %{"bg" => "#fde68a"}})])

    assert cell("m-bg", "A1") == %{"v" => 1, "s" => %{"bg" => "#fde68a"}}
  end

  # ── empty-cell refusal ──────────────────────────────────────────────────────

  test "formatting an EMPTY cell is refused (empty_cell) and creates no cell" do
    create_sheet("m-empty", %{})

    assert %{applied: 0, errors: [%{index: 0, code: "empty_cell"}]} =
             apply!("m-empty", [set_meta("B9", %{"fmt" => "currency"})])

    assert cell("m-empty", "B9") == nil
  end

  # ── merge-covered refusal ───────────────────────────────────────────────────

  test "a merge-covered ref is refused (merged_cell)" do
    create_sheet("m-cov", %{"A1" => %{"v" => 1}, "B1" => %{"v" => 2}})

    assert %{applied: 1, errors: []} =
             apply!("m-cov", [%{"op" => "merge_cells", "tab" => 0, "range" => "A1:B1"}])

    assert %{applied: 0, errors: [%{index: 0, code: "merged_cell"}]} =
             apply!("m-cov", [set_meta("B1", %{"fmt" => "currency"})])
  end

  # ── formula cells keep their formula ────────────────────────────────────────

  test "formatting a formula cell keeps f and its computed v" do
    create_sheet("m-formula", %{})
    assert %{applied: 1, errors: []} = apply!("m-formula", [set_cell("A1", "=1+1")])
    assert %{"f" => "1+1", "v" => 2} = cell("m-formula", "A1")

    assert %{applied: 1, errors: []} = apply!("m-formula", [set_meta("A1", %{"fmt" => "fixed"})])
    assert %{"f" => "1+1", "v" => 2, "fmt" => "fixed"} = cell("m-formula", "A1")
  end

  # ── undo / redo restores the exact prior cell ───────────────────────────────

  test "undo restores the prior (unformatted) cell; redo re-applies the meta" do
    create_sheet("m-undo", %{"A1" => %{"v" => 5}})

    assert %{applied: 1, errors: []} = apply!("m-undo", [set_meta("A1", %{"fmt" => "currency"})])
    assert cell("m-undo", "A1") == %{"v" => 5, "fmt" => "currency"}

    assert %{applied: 1, errors: []} = apply!("m-undo", [undo("u")])
    assert cell("m-undo", "A1") == %{"v" => 5}

    assert %{applied: 1, errors: []} = apply!("m-undo", [redo("u")])
    assert cell("m-undo", "A1") == %{"v" => 5, "fmt" => "currency"}
  end
end
