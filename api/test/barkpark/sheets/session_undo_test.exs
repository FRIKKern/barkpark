defmodule Barkpark.Plugins.Sheets.SessionUndoTest do
  @moduledoc """
  M4 locks for per-user undo/redo in `Barkpark.Plugins.Sheets.Session`.

  The matrix: undo is OWN-OP only (per-user inverse stacks keyed by the
  op's `"user"` stamp); inverse correctness per op type — cell ops restore
  the exact prior cell map, insert_* invert to delete_*, delete_* invert to
  insert_* + the captured span, set_col_width/set_row_height restore the
  prior px, rename_tab the prior name, add_tab/delete_tab round-trip the
  tab; redo mirrors undo and is CLEARED by any new own-op; stacks bind at
  depth 100; undo racing another user's overwrite just applies the inverse
  (Google Sheets semantics — it may overwrite their newer value,
  documented); undo deltas broadcast like normal ops.

  `async: false` — sessions are globally registered processes, same as
  `Barkpark.Plugins.Sheets.SessionTest`.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Plugins.Sheets.Session

  @dataset "sheets_m4_undo_test"

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

  defp set_cell(ref, raw, user),
    do: %{"op" => "set_cell", "tab" => 0, "ref" => ref, "raw" => raw, "user" => user}

  defp clear_cell(ref, user),
    do: %{"op" => "clear_cell", "tab" => 0, "ref" => ref, "user" => user}

  defp undo(user), do: %{"op" => "undo", "user" => user}
  defp redo(user), do: %{"op" => "redo", "user" => user}

  defp create_tabs(slug, names) do
    tabs = Enum.map(names, &%{"name" => &1, "cells" => %{}})

    {:ok, doc} =
      Content.create_document(
        "sheet",
        %{"doc_id" => slug, "content" => %{"tabs" => tabs}},
        @dataset
      )

    doc
  end

  defp set_cell_on(tab, ref, raw, user),
    do: %{"op" => "set_cell", "tab" => tab, "ref" => ref, "raw" => raw, "user" => user}

  defp delete_tab(tab, user), do: %{"op" => "delete_tab", "tab" => tab, "user" => user}

  defp apply!(slug, ops) do
    {:ok, reply} = Session.apply_ops(slug, @dataset, ops)
    reply
  end

  defp peek_cells(slug, tab \\ 0) do
    {:ok, content} = Session.peek(slug, @dataset)
    get_in(content, ["tabs", Access.at(tab), "cells"])
  end

  defp peek_tab(slug, tab) do
    {:ok, content} = Session.peek(slug, @dataset)
    get_in(content, ["tabs", Access.at(tab)])
  end

  # ── own-op only ─────────────────────────────────────────────────────────────

  test "undo pops the CALLER's stack only — two users, two histories" do
    create_sheet("u-own", %{})

    %{applied: 2, errors: []} =
      apply!("u-own", [set_cell("A1", "alice", "alice"), set_cell("B1", "bob", "bob")])

    # Alice's undo reverts A1 and leaves Bob's B1 standing.
    %{applied: 1, errors: []} = apply!("u-own", [undo("alice")])
    assert peek_cells("u-own") == %{"B1" => %{"v" => "bob"}}

    # Alice has nothing further; Bob still has his op.
    %{applied: 0, errors: [%{code: "nothing_to_undo"}]} = apply!("u-own", [undo("alice")])
    %{applied: 1, errors: []} = apply!("u-own", [undo("bob")])
    assert peek_cells("u-own") == %{}
  end

  test "undo without a user is rejected; an unknown user has an empty stack" do
    create_sheet("u-nouser", %{})

    %{applied: 0, errors: [%{code: "invalid_user"}]} = apply!("u-nouser", [%{"op" => "undo"}])

    %{applied: 0, errors: [%{code: "invalid_user"}]} =
      apply!("u-nouser", [%{"op" => "redo", "user" => ""}])

    %{applied: 0, errors: [%{code: "nothing_to_undo"}]} = apply!("u-nouser", [undo("nobody")])
    %{applied: 0, errors: [%{code: "nothing_to_redo"}]} = apply!("u-nouser", [redo("nobody")])
  end

  test "ops without a user stamp record no history" do
    create_sheet("u-anon", %{})

    %{applied: 1} =
      apply!("u-anon", [%{"op" => "set_cell", "tab" => 0, "ref" => "A1", "raw" => 1}])

    %{applied: 0, errors: [%{code: "nothing_to_undo"}]} = apply!("u-anon", [undo("anyone")])
  end

  # ── inverse correctness: cell ops ───────────────────────────────────────────

  test "set_cell over an existing formula cell restores the exact prior map" do
    create_sheet("u-cell", %{
      "A1" => %{"v" => 2},
      "B1" => %{"f" => "A1*10", "v" => 20, "t" => "n"}
    })

    %{applied: 1} = apply!("u-cell", [set_cell("B1", "plain", "alice")])
    assert peek_cells("u-cell")["B1"] == %{"v" => "plain"}

    %{applied: 1, errors: []} = apply!("u-cell", [undo("alice")])
    assert peek_cells("u-cell")["B1"] == %{"f" => "A1*10", "v" => 20, "t" => "n"}
  end

  test "set_cell on an empty cell undoes to absent; clear_cell undoes to the prior cell" do
    create_sheet("u-clear", %{"A1" => %{"v" => "keep"}})

    %{applied: 1} = apply!("u-clear", [set_cell("C3", 7, "alice")])
    %{applied: 1} = apply!("u-clear", [undo("alice")])
    refute Map.has_key?(peek_cells("u-clear"), "C3")

    %{applied: 1} = apply!("u-clear", [clear_cell("A1", "alice")])
    refute Map.has_key?(peek_cells("u-clear"), "A1")
    %{applied: 1} = apply!("u-clear", [undo("alice")])
    assert peek_cells("u-clear")["A1"] == %{"v" => "keep"}
  end

  test "undoing a formula edit recomputes dependents back" do
    create_sheet("u-dep", %{"A1" => %{"v" => 3}, "B1" => %{"f" => "A1*2", "v" => 6, "t" => "n"}})

    %{applied: 1} = apply!("u-dep", [set_cell("A1", 10, "alice")])
    assert peek_cells("u-dep")["B1"]["v"] == 20

    %{applied: 1} = apply!("u-dep", [undo("alice")])
    assert peek_cells("u-dep")["A1"] == %{"v" => 3}
    assert peek_cells("u-dep")["B1"]["v"] == 6
  end

  # ── inverse correctness: structural ops ─────────────────────────────────────

  test "insert_rows undoes to a delete that shifts keys and formulas back" do
    create_sheet("u-insrow", %{
      "A1" => %{"v" => 5},
      "A2" => %{"f" => "A1*2", "v" => 10, "t" => "n"}
    })

    %{applied: 1} =
      apply!("u-insrow", [
        %{"op" => "insert_rows", "tab" => 0, "at" => 1, "count" => 2, "user" => "alice"}
      ])

    assert peek_cells("u-insrow") == %{
             "A3" => %{"v" => 5},
             "A4" => %{"f" => "A3*2", "v" => 10, "t" => "n"}
           }

    %{applied: 1, errors: []} = apply!("u-insrow", [undo("alice")])

    assert peek_cells("u-insrow") == %{
             "A1" => %{"v" => 5},
             "A2" => %{"f" => "A1*2", "v" => 10, "t" => "n"}
           }
  end

  test "delete_rows undoes to an insert restoring the captured span" do
    create_sheet("u-delrow", %{
      "A1" => %{"v" => "head"},
      "A2" => %{"v" => "gone-1"},
      "A3" => %{"v" => "gone-2"},
      "A4" => %{"v" => "tail"}
    })

    %{applied: 1} =
      apply!("u-delrow", [
        %{"op" => "delete_rows", "tab" => 0, "at" => 2, "count" => 2, "user" => "alice"}
      ])

    assert peek_cells("u-delrow") == %{"A1" => %{"v" => "head"}, "A2" => %{"v" => "tail"}}

    %{applied: 1, errors: []} = apply!("u-delrow", [undo("alice")])

    assert peek_cells("u-delrow") == %{
             "A1" => %{"v" => "head"},
             "A2" => %{"v" => "gone-1"},
             "A3" => %{"v" => "gone-2"},
             "A4" => %{"v" => "tail"}
           }
  end

  test "insert_cols and delete_cols round-trip through undo on the column axis" do
    create_sheet("u-cols", %{"A1" => %{"v" => "a"}, "B1" => %{"v" => "b"}, "C1" => %{"v" => "c"}})

    %{applied: 1} =
      apply!("u-cols", [
        %{"op" => "insert_cols", "tab" => 0, "at" => 2, "count" => 1, "user" => "alice"}
      ])

    %{applied: 1} =
      apply!("u-cols", [
        %{"op" => "delete_cols", "tab" => 0, "at" => 1, "count" => 2, "user" => "alice"}
      ])

    assert peek_cells("u-cols") == %{"A1" => %{"v" => "b"}, "B1" => %{"v" => "c"}}

    # Undo the delete (insert + captured span), then the insert (delete).
    %{applied: 1} = apply!("u-cols", [undo("alice")])

    assert peek_cells("u-cols") == %{
             "A1" => %{"v" => "a"},
             "C1" => %{"v" => "b"},
             "D1" => %{"v" => "c"}
           }

    %{applied: 1} = apply!("u-cols", [undo("alice")])

    assert peek_cells("u-cols") == %{
             "A1" => %{"v" => "a"},
             "B1" => %{"v" => "b"},
             "C1" => %{"v" => "c"}
           }
  end

  test "set_col_width and set_row_height undo to the prior px (nil clears)" do
    create_sheet("u-size", %{})

    %{applied: 1} =
      apply!("u-size", [
        %{"op" => "set_col_width", "tab" => 0, "col" => 2, "px" => 140, "user" => "alice"}
      ])

    %{applied: 1} =
      apply!("u-size", [
        %{"op" => "set_col_width", "tab" => 0, "col" => 2, "px" => 200, "user" => "alice"}
      ])

    assert peek_tab("u-size", 0)["col_widths"] == %{"2" => 200}

    %{applied: 1} = apply!("u-size", [undo("alice")])
    assert peek_tab("u-size", 0)["col_widths"] == %{"2" => 140}

    # The first op had no prior entry — its undo clears the width entirely.
    %{applied: 1} = apply!("u-size", [undo("alice")])
    assert peek_tab("u-size", 0)["col_widths"] == %{}

    %{applied: 1} =
      apply!("u-size", [
        %{"op" => "set_row_height", "tab" => 0, "row" => 3, "px" => 36, "user" => "alice"}
      ])

    %{applied: 1} = apply!("u-size", [undo("alice")])
    assert peek_tab("u-size", 0)["row_heights"] == %{}
  end

  test "rename_tab, add_tab and delete_tab invert exactly" do
    create_sheet("u-tabs", %{"A1" => %{"v" => "x"}})

    %{applied: 1} =
      apply!("u-tabs", [
        %{"op" => "rename_tab", "tab" => 0, "name" => "Renamed", "user" => "alice"}
      ])

    %{applied: 1} = apply!("u-tabs", [undo("alice")])
    assert peek_tab("u-tabs", 0)["name"] == "T0"

    %{applied: 1} = apply!("u-tabs", [%{"op" => "add_tab", "name" => "Extra", "user" => "alice"}])
    assert peek_tab("u-tabs", 1)["name"] == "Extra"
    %{applied: 1} = apply!("u-tabs", [undo("alice")])
    assert peek_tab("u-tabs", 1) == nil

    # delete_tab undoes to the captured tab back at its index, cells intact.
    %{applied: 1} = apply!("u-tabs", [%{"op" => "add_tab", "name" => "Keep", "user" => "alice"}])
    %{applied: 1} = apply!("u-tabs", [%{"op" => "delete_tab", "tab" => 0, "user" => "alice"}])
    assert peek_tab("u-tabs", 0)["name"] == "Keep"

    %{applied: 1} = apply!("u-tabs", [undo("alice")])
    assert peek_tab("u-tabs", 0)["name"] == "T0"
    assert peek_cells("u-tabs", 0) == %{"A1" => %{"v" => "x"}}
    assert peek_tab("u-tabs", 1)["name"] == "Keep"
  end

  # ── redo ────────────────────────────────────────────────────────────────────

  test "undo then redo restores the op; the redone op is undoable again" do
    create_sheet("u-redo", %{"A1" => %{"v" => "base"}})

    %{applied: 1} = apply!("u-redo", [set_cell("A1", "edited", "alice")])
    %{applied: 1} = apply!("u-redo", [undo("alice")])
    assert peek_cells("u-redo")["A1"] == %{"v" => "base"}

    %{applied: 1, errors: []} = apply!("u-redo", [redo("alice")])
    assert peek_cells("u-redo")["A1"] == %{"v" => "edited"}

    %{applied: 1} = apply!("u-redo", [undo("alice")])
    assert peek_cells("u-redo")["A1"] == %{"v" => "base"}
  end

  test "a new own-op clears the redo stack; another user's op does not" do
    create_sheet("u-redoclear", %{})

    %{applied: 1} = apply!("u-redoclear", [set_cell("A1", 1, "alice")])
    %{applied: 1} = apply!("u-redoclear", [undo("alice")])

    # Bob's op leaves Alice's redo intact…
    %{applied: 1} = apply!("u-redoclear", [set_cell("B1", 2, "bob")])
    %{applied: 1, errors: []} = apply!("u-redoclear", [redo("alice")])
    assert peek_cells("u-redoclear")["A1"] == %{"v" => 1}

    # …but Alice's own new op clears it.
    %{applied: 1} = apply!("u-redoclear", [undo("alice")])
    %{applied: 1} = apply!("u-redoclear", [set_cell("C1", 3, "alice")])
    %{applied: 0, errors: [%{code: "nothing_to_redo"}]} = apply!("u-redoclear", [redo("alice")])
  end

  test "redo of a structural undo restores the structure" do
    create_sheet("u-redostruct", %{"A1" => %{"v" => "x"}, "A2" => %{"v" => "y"}})

    %{applied: 1} =
      apply!("u-redostruct", [
        %{"op" => "delete_rows", "tab" => 0, "at" => 1, "count" => 1, "user" => "alice"}
      ])

    %{applied: 1} = apply!("u-redostruct", [undo("alice")])
    assert peek_cells("u-redostruct") == %{"A1" => %{"v" => "x"}, "A2" => %{"v" => "y"}}

    %{applied: 1, errors: []} = apply!("u-redostruct", [redo("alice")])
    assert peek_cells("u-redostruct") == %{"A1" => %{"v" => "y"}}
  end

  test "merge_cells and unmerge_cells invert exactly through undo/redo" do
    create_sheet("u-merge", %{"A1" => %{"v" => "x"}, "B2" => %{"v" => "y"}})

    %{applied: 1} =
      apply!("u-merge", [
        %{"op" => "merge_cells", "tab" => 0, "range" => "A1:B2", "user" => "alice"}
      ])

    assert peek_tab("u-merge", 0)["merges"] == ["A1:B2"]

    # Undo restores the prior (empty) merges list; the covered cell is intact.
    %{applied: 1} = apply!("u-merge", [undo("alice")])
    assert (peek_tab("u-merge", 0)["merges"] || []) == []
    assert peek_cells("u-merge")["B2"] == %{"v" => "y"}

    # Redo reapplies the merge.
    %{applied: 1, errors: []} = apply!("u-merge", [redo("alice")])
    assert peek_tab("u-merge", 0)["merges"] == ["A1:B2"]

    # Unmerge then undo brings the span back.
    %{applied: 1} =
      apply!("u-merge", [
        %{"op" => "unmerge_cells", "tab" => 0, "range" => "A1:A1", "user" => "alice"}
      ])

    assert (peek_tab("u-merge", 0)["merges"] || []) == []

    %{applied: 1} = apply!("u-merge", [undo("alice")])
    assert peek_tab("u-merge", 0)["merges"] == ["A1:B2"]
  end

  test "undo of a merge removes ONLY that range — a disjoint merge by another user survives" do
    create_sheet("u-merge-disjoint", %{})

    %{applied: 2, errors: []} =
      apply!("u-merge-disjoint", [
        %{"op" => "merge_cells", "tab" => 0, "range" => "A1:B2", "user" => "alice"},
        %{"op" => "merge_cells", "tab" => 0, "range" => "D4:E5", "user" => "bob"}
      ])

    assert peek_tab("u-merge-disjoint", 0)["merges"] == ["A1:B2", "D4:E5"]

    # Alice undoes HER merge; Bob's disjoint merge MUST survive. The old
    # whole-list snapshot inverse silently deleted it (it restored the merges
    # list as it stood when Alice merged — before Bob's op existed).
    %{applied: 1, errors: []} = apply!("u-merge-disjoint", [undo("alice")])
    assert peek_tab("u-merge-disjoint", 0)["merges"] == ["D4:E5"]

    # Redo re-adds Alice's range alongside Bob's, still non-overlapping.
    %{applied: 1, errors: []} = apply!("u-merge-disjoint", [redo("alice")])
    assert Enum.sort(peek_tab("u-merge-disjoint", 0)["merges"]) == ["A1:B2", "D4:E5"]
  end

  test "a row-delete re-keys a third user's merge; undo of an unrelated merge leaves the SHIFTED range" do
    create_sheet("u-merge-shift", %{})

    %{applied: 2, errors: []} =
      apply!("u-merge-shift", [
        %{"op" => "merge_cells", "tab" => 0, "range" => "A1:B2", "user" => "alice"},
        %{"op" => "merge_cells", "tab" => 0, "range" => "A10:B11", "user" => "carol"}
      ])

    # Deleting rows 5..7 shifts Carol's merge up by 3 (A1:B2 is above the cut,
    # untouched). Carol's merge is now re-keyed off its original coordinates.
    %{applied: 1, errors: []} =
      apply!("u-merge-shift", [
        %{"op" => "delete_rows", "tab" => 0, "at" => 5, "count" => 3, "user" => "carol"}
      ])

    shifted = peek_tab("u-merge-shift", 0)["merges"]
    assert "A1:B2" in shifted
    carol_shifted = Enum.find(shifted, &(&1 != "A1:B2"))
    refute carol_shifted == "A10:B11"

    # Alice undoes HER merge only. Carol's re-keyed merge must stay exactly
    # where the shift put it — the snapshot inverse would resurrect A10:B11
    # (pre-shift coords) and drop the shifted range.
    %{applied: 1, errors: []} = apply!("u-merge-shift", [undo("alice")])
    assert peek_tab("u-merge-shift", 0)["merges"] == [carol_shifted]
  end

  test "undo of an unmerge SKIPS a range a later merge re-covered — never writes an overlap" do
    create_sheet("u-merge-overlap", %{})

    %{applied: 1, errors: []} =
      apply!("u-merge-overlap", [
        %{"op" => "merge_cells", "tab" => 0, "range" => "A1:B2", "user" => "alice"}
      ])

    # Alice unmerges A1:B2 (inverse: re-add A1:B2 on undo).
    %{applied: 1, errors: []} =
      apply!("u-merge-overlap", [
        %{"op" => "unmerge_cells", "tab" => 0, "range" => "A1:B2", "user" => "alice"}
      ])

    assert (peek_tab("u-merge-overlap", 0)["merges"] || []) == []

    # Bob merges an OVERLAPPING range before Alice can undo.
    %{applied: 1, errors: []} =
      apply!("u-merge-overlap", [
        %{"op" => "merge_cells", "tab" => 0, "range" => "A1:A3", "user" => "bob"}
      ])

    # Alice's undo is consumed cleanly, but re-adding A1:B2 is SKIPPED — it
    # would overlap Bob's A1:A3. The persisted list stays valid (no overlap).
    %{applied: 1, errors: []} = apply!("u-merge-overlap", [undo("alice")])
    assert peek_tab("u-merge-overlap", 0)["merges"] == ["A1:A3"]
  end

  # ── depth bound ─────────────────────────────────────────────────────────────

  test "the undo stack binds at depth 100 — older entries drop" do
    create_sheet("u-depth", %{})

    for i <- 1..103 do
      %{applied: 1} = apply!("u-depth", [set_cell("A1", i, "alice")])
    end

    undone =
      Enum.count(1..103, fn _ ->
        match?(%{applied: 1, errors: []}, apply!("u-depth", [undo("alice")]))
      end)

    assert undone == 100
    # The 100 undos walked back to op 3's prior value (op 4 overwrote 3, …);
    # entries 1..3's inverses had dropped off the bounded stack.
    assert peek_cells("u-depth")["A1"] == %{"v" => 3}
  end

  # ── racing another user ─────────────────────────────────────────────────────

  test "undo racing another user's overwrite applies the inverse anyway (documented LWW)" do
    create_sheet("u-race", %{"A1" => %{"v" => "base"}})

    %{applied: 1} = apply!("u-race", [set_cell("A1", "alice-v", "alice")])
    %{applied: 1} = apply!("u-race", [set_cell("A1", "bob-v", "bob")])

    # Alice undoes HER op: the inverse (restore "base") applies even though
    # Bob has since overwritten the cell — Google Sheets semantics, Bob's
    # newer value is overwritten.
    %{applied: 1, errors: []} = apply!("u-race", [undo("alice")])
    assert peek_cells("u-race")["A1"] == %{"v" => "base"}
  end

  # ── deltas + rev ────────────────────────────────────────────────────────────

  test "an undo broadcasts a normal delta and bumps rev" do
    doc = create_sheet("u-delta", %{})

    Phoenix.PubSub.subscribe(
      Barkpark.PubSub,
      Session.topic("u-delta", @dataset, doc.workspace_id)
    )

    %{rev: 1} = apply!("u-delta", [set_cell("A1", "v1", "alice")])
    assert_receive {:sheets_op, %{rev: 1, changed: %{"A1" => %{"v" => "v1"}}}}, 1_000

    %{rev: 2, applied: 1} = apply!("u-delta", [undo("alice")])
    assert_receive {:sheets_op, %{rev: 2, changed: %{"A1" => nil}}}, 1_000

    %{rev: 3, applied: 1} = apply!("u-delta", [redo("alice")])
    assert_receive {:sheets_op, %{rev: 3, changed: %{"A1" => %{"v" => "v1"}}}}, 1_000
  end

  # ── a failed entry is consumed, never jams the stack ─────────────────────────
  #
  # A cell inverse pins the ABSOLUTE tab index, so an edit to the LAST tab whose
  # tab is then deleted has no valid target on undo. The apply must POP and DROP
  # that dead entry (not re-try it forever) — the regression the fix pins.

  describe "failed entry is consumed" do
    test "a dead undo consumes its entry — the next undo is NOT the same error forever" do
      create_tabs("u-jam", ["T0", "T1", "T2"])

      # Alice edits the last tab; her inverse pins tab index 2.
      %{applied: 1} = apply!("u-jam", [set_cell_on(2, "A1", "alice-v", "alice")])

      # Bob deletes tab 2 — Alice's undo target vanishes.
      %{applied: 1} = apply!("u-jam", [delete_tab(2, "bob")])

      # Undo #1 fails (tab gone) but does not apply and consumes the entry.
      %{applied: 0, errors: [%{code: dead_code}]} = apply!("u-jam", [undo("alice")])
      refute dead_code == "nothing_to_undo"

      # Undo #2 differs from #1 — the stack advanced past the dead entry
      # instead of re-serving the same error (the pre-fix jam).
      %{applied: 0, errors: [%{code: "nothing_to_undo"}]} = apply!("u-jam", [undo("alice")])
    end

    test "history behind a dead entry is reachable — undo #2 reverts the older edit" do
      create_tabs("u-layer", ["T0", "T1", "T2"])

      %{applied: 1} = apply!("u-layer", [set_cell_on(0, "A1", "old-a1", "alice")])
      %{applied: 1} = apply!("u-layer", [set_cell_on(2, "B1", "old-b1", "alice")])

      %{applied: 1} = apply!("u-layer", [delete_tab(2, "bob")])

      # Undo #1 targets the vanished tab-2 edit: fails, consumed.
      %{applied: 0, errors: [%{code: dead_code}]} = apply!("u-layer", [undo("alice")])
      refute dead_code == "nothing_to_undo"

      # Undo #2 reaches the tab-0 edit behind the dead entry and reverts it.
      %{applied: 1, errors: []} = apply!("u-layer", [undo("alice")])
      refute Map.has_key?(peek_cells("u-layer", 0), "A1")
    end

    test "a consumed failed undo does not land on the redo stack" do
      create_tabs("u-noredo", ["T0", "T1", "T2"])

      %{applied: 1} = apply!("u-noredo", [set_cell_on(2, "A1", "v", "alice")])
      %{applied: 1} = apply!("u-noredo", [delete_tab(2, "bob")])

      %{applied: 0, errors: [%{code: _}]} = apply!("u-noredo", [undo("alice")])

      # The dead entry was dropped, not mirrored onto the redo stack.
      %{applied: 0, errors: [%{code: "nothing_to_redo"}]} = apply!("u-noredo", [redo("alice")])
    end
  end

  # ── tab-reorder / duplicate remap the undo+redo stacks ───────────────────────
  #
  # Every inverse entry pins an ABSOLUTE tab index. A reorder or insert by ANY
  # user must re-permute EVERY user's stacks, or a later undo restores on the
  # WRONG tab — a silent cross-user corruption. These pin that remap.

  defp move_tab(from, to, user),
    do: %{"op" => "move_tab", "from" => from, "to" => to, "user" => user}

  describe "move_tab / duplicate_tab remap the stacks" do
    test "move_tab remaps another user's undo — the inverse lands on the same LOGICAL tab" do
      create_tabs("u-move-remap", ["T0", "T1"])

      # Alice writes A1 on tab 1 (her inverse pins index 1).
      %{applied: 1} = apply!("u-move-remap", [set_cell_on(1, "A1", "alice-v", "alice")])
      assert peek_cells("u-move-remap", 1)["A1"] == %{"v" => "alice-v"}

      # Bob moves tab 1 to the front — the logical tab Alice wrote is now index 0.
      %{applied: 1} = apply!("u-move-remap", [move_tab(1, 0, "bob")])
      assert peek_cells("u-move-remap", 0)["A1"] == %{"v" => "alice-v"}

      # Alice's undo must clear A1 on the LOGICAL tab (now index 0), not the
      # stale index 1 (which is now the OTHER tab). Without the remap this
      # undo would clear the wrong tab and leave A1 standing at index 0.
      %{applied: 1, errors: []} = apply!("u-move-remap", [undo("alice")])
      refute Map.has_key?(peek_cells("u-move-remap", 0), "A1")
      assert peek_cells("u-move-remap", 1) == %{}
    end

    test "move_tab remaps a user's redo stack too" do
      create_tabs("u-move-redo", ["T0", "T1"])

      %{applied: 1} = apply!("u-move-redo", [set_cell_on(1, "A1", "v1", "alice")])
      # Undo parks the redo entry pinning index 1.
      %{applied: 1} = apply!("u-move-redo", [undo("alice")])

      # Bob reorders — Alice's REDO entry must move with the logical tab.
      %{applied: 1} = apply!("u-move-redo", [move_tab(1, 0, "bob")])

      %{applied: 1, errors: []} = apply!("u-move-redo", [redo("alice")])
      assert peek_cells("u-move-redo", 0)["A1"] == %{"v" => "v1"}
      assert peek_cells("u-move-redo", 1) == %{}
    end

    test "duplicate_tab undo deletes the copy; redo restores it" do
      create_tabs("u-dup-undo", ["T0", "T1"])

      %{applied: 1} =
        apply!("u-dup-undo", [%{"op" => "duplicate_tab", "tab" => 0, "user" => "alice"}])

      assert peek_tab("u-dup-undo", 1)["name"] == "Copy of T0"
      assert length(peek_all_tabs("u-dup-undo")) == 3

      %{applied: 1, errors: []} = apply!("u-dup-undo", [undo("alice")])
      assert length(peek_all_tabs("u-dup-undo")) == 2
      assert peek_tab("u-dup-undo", 1)["name"] == "T1"

      %{applied: 1, errors: []} = apply!("u-dup-undo", [redo("alice")])
      assert peek_tab("u-dup-undo", 1)["name"] == "Copy of T0"
    end

    test "stacked move_tab inverse remaps after another user's duplicate_tab" do
      create_tabs("u-move-dup-remap", ["TA", "TB", "TC"])

      # Alice moves TA to the back: [TB, TC, TA]; her inverse pins from=2, to=0.
      %{applied: 1} = apply!("u-move-dup-remap", [move_tab(0, 2, "alice")])
      assert tab_names("u-move-dup-remap") == ["TB", "TC", "TA"]

      # Bob duplicates tab 0 → copy at index 1: [TB, Copy of TB, TC, TA].
      # TA slid to index 3; Alice's stacked inverse "from" must follow it (2 → 3).
      %{applied: 1} =
        apply!("u-move-dup-remap", [%{"op" => "duplicate_tab", "tab" => 0, "user" => "bob"}])

      assert tab_names("u-move-dup-remap") == ["TB", "Copy of TB", "TC", "TA"]

      # Alice's undo must bring TA back to the front — not move TC (the tab
      # now sitting at the stale index 2).
      %{applied: 1, errors: []} = apply!("u-move-dup-remap", [undo("alice")])
      assert tab_names("u-move-dup-remap") == ["TA", "TB", "Copy of TB", "TC"]
    end

    test "stacked move_tab inverse remaps after another user's move_tab" do
      create_tabs("u-move-move-remap", ["TA", "TB", "TC"])

      # Alice moves TA to the back: [TB, TC, TA]; her inverse pins from=2, to=0.
      %{applied: 1} = apply!("u-move-move-remap", [move_tab(0, 2, "alice")])
      assert tab_names("u-move-move-remap") == ["TB", "TC", "TA"]

      # Bob moves TA (index 2) to index 1: [TB, TA, TC]. Alice's stacked
      # inverse "from" must follow TA (2 → 1).
      %{applied: 1} = apply!("u-move-move-remap", [move_tab(2, 1, "bob")])
      assert tab_names("u-move-move-remap") == ["TB", "TA", "TC"]

      # Undo restores the original order — not [TC, TB, TA], which is what
      # moving whatever now sits at the stale index 2 would produce.
      %{applied: 1, errors: []} = apply!("u-move-move-remap", [undo("alice")])
      assert tab_names("u-move-move-remap") == ["TA", "TB", "TC"]
    end

    test "duplicate_tab shifts another user's stack entry pinned at or after the insert slot" do
      create_tabs("u-dup-shift", ["T0", "T1"])

      # Bob writes A1 on tab 1 (inverse pins index 1).
      %{applied: 1} = apply!("u-dup-shift", [set_cell_on(1, "A1", "bob-v", "bob")])

      # Alice duplicates tab 0 → copy inserted at index 1; the logical tab Bob
      # wrote slides to index 2. Bob's stacked index (1 >= 1) must shift to 2.
      %{applied: 1} =
        apply!("u-dup-shift", [%{"op" => "duplicate_tab", "tab" => 0, "user" => "alice"}])

      assert peek_cells("u-dup-shift", 2)["A1"] == %{"v" => "bob-v"}

      # Bob's undo clears A1 on the LOGICAL tab (now index 2), not the copy at 1.
      %{applied: 1, errors: []} = apply!("u-dup-shift", [undo("bob")])
      refute Map.has_key?(peek_cells("u-dup-shift", 2), "A1")
      assert peek_cells("u-dup-shift", 1) == %{}
    end
  end

  # ── delete_tab / tab_restore remap the stacks ────────────────────────────────
  #
  # The delete-side mirror of the insert/reorder remaps above: removing a tab
  # (directly, or as the undo of an add_tab/duplicate_tab) slides every LATER
  # index down by one, and restoring it (the undo of a delete_tab) slides
  # every index at/after the restored slot back up. Entries pinned to the
  # deleted tab ITSELF keep the dead-entry contract of the "failed entry is
  # consumed" describe above — these cases are about SHIFTED entries only.

  describe "delete_tab / tab_restore remap the stacks" do
    test "undo of a duplicate_tab (delete path) shifts a stacked entry back to the LOGICAL tab" do
      create_tabs("u-del-shift", ["T0", "T1", "T2", "T3"])

      # Carol parks a value on T3 that must survive alice's later undo.
      %{applied: 1} = apply!("u-del-shift", [set_cell_on(3, "A1", "keep-v", "carol")])
      # Alice writes on T2 — her inverse pins index 2.
      %{applied: 1} = apply!("u-del-shift", [set_cell_on(2, "A1", "alice-v", "alice")])

      # Bob duplicates tab 0 → copy at index 1; T2 slides to 3 (the merged
      # insert remap follows it).
      %{applied: 1} =
        apply!("u-del-shift", [%{"op" => "duplicate_tab", "tab" => 0, "user" => "bob"}])

      assert peek_cells("u-del-shift", 3)["A1"] == %{"v" => "alice-v"}

      # Bob undoes his dup — the copy at index 1 is DELETED; T2 slides back
      # to 2. Alice's stacked index must follow it (3 → 2).
      %{applied: 1, errors: []} = apply!("u-del-shift", [undo("bob")])
      assert tab_names("u-del-shift") == ["T0", "T1", "T2", "T3"]
      assert peek_cells("u-del-shift", 2)["A1"] == %{"v" => "alice-v"}

      # Alice's undo clears A1 on the LOGICAL T2 (index 2) — not on T3, the
      # tab now sitting at her stale index 3, whose value must survive.
      %{applied: 1, errors: []} = apply!("u-del-shift", [undo("alice")])
      refute Map.has_key?(peek_cells("u-del-shift", 2), "A1")
      assert peek_cells("u-del-shift", 3)["A1"] == %{"v" => "keep-v"}
    end

    test "undo of a duplicate_tab keeps a trailing-tab entry alive — it previously died tab_not_found" do
      create_tabs("u-del-edge", ["T0", "T1"])

      # Alice writes on T1 (index 1); bob's dup at 0 slides it to index 2.
      %{applied: 1} = apply!("u-del-edge", [set_cell_on(1, "A1", "alice-v", "alice")])

      %{applied: 1} =
        apply!("u-del-edge", [%{"op" => "duplicate_tab", "tab" => 0, "user" => "bob"}])

      assert peek_cells("u-del-edge", 2)["A1"] == %{"v" => "alice-v"}

      %{applied: 1, errors: []} = apply!("u-del-edge", [undo("bob")])

      # Alice's entry followed T1 back down (2 → 1); without the delete
      # remap it kept pointing at the vanished index 2 and died tab_not_found.
      %{applied: 1, errors: []} = apply!("u-del-edge", [undo("alice")])
      refute Map.has_key?(peek_cells("u-del-edge", 1), "A1")
    end

    test "an entry written between a delete_tab and its undo follows the logical tab after restore" do
      create_tabs("u-restore-shift", ["T0", "T1", "T2"])

      # Bob deletes T0 — tabs are now [T1, T2].
      %{applied: 1} = apply!("u-restore-shift", [delete_tab(0, "bob")])

      # Alice writes on index 1 (logical T2) — her inverse pins index 1.
      %{applied: 1} = apply!("u-restore-shift", [set_cell_on(1, "A1", "alice-v", "alice")])

      # Bob undoes his delete — T0 re-inserts at slot 0; T2 slides back to
      # index 2. Alice's stacked index must shift with it (1 → 2).
      %{applied: 1, errors: []} = apply!("u-restore-shift", [undo("bob")])
      assert tab_names("u-restore-shift") == ["T0", "T1", "T2"]
      assert peek_cells("u-restore-shift", 2)["A1"] == %{"v" => "alice-v"}

      # A value on T1 — alice's STALE index 1 — that must survive her undo.
      %{applied: 1} = apply!("u-restore-shift", [set_cell_on(1, "A1", "keep-v", "carol")])

      # Alice's undo clears A1 on the LOGICAL T2 (index 2), not on T1.
      %{applied: 1, errors: []} = apply!("u-restore-shift", [undo("alice")])
      refute Map.has_key?(peek_cells("u-restore-shift", 2), "A1")
      assert peek_cells("u-restore-shift", 1)["A1"] == %{"v" => "keep-v"}
    end
  end

  defp peek_all_tabs(slug) do
    {:ok, content} = Session.peek(slug, @dataset)
    content["tabs"]
  end

  defp tab_names(slug), do: Enum.map(peek_all_tabs(slug), & &1["name"])

  # ── sort_range: {:permute, …} inverse (SF-D6) ───────────────────────────────

  test "sort_range undo restores the EXACT prior row order; redo re-sorts" do
    # Plain value cells (no formulas → no recompute), so the pre-sort map is
    # exactly what was created.
    original = %{"A1" => %{"v" => 3}, "A2" => %{"v" => 1}, "A3" => %{"v" => 2}}
    create_sheet("u-sort", original)

    sort = %{
      "op" => "sort_range",
      "tab" => 0,
      "range" => "A1:A3",
      "keys" => [%{"col" => 0, "dir" => "asc"}],
      "user" => "u"
    }

    %{applied: 1, errors: []} = apply!("u-sort", [sort])

    assert peek_cells("u-sort") == %{
             "A1" => %{"v" => 1},
             "A2" => %{"v" => 2},
             "A3" => %{"v" => 3}
           }

    # Undo re-applies the EXACT inverse permutation — byte-identical to the
    # pre-sort cells (verbatim moves both ways, loss-free).
    %{applied: 1, errors: []} = apply!("u-sort", [undo("u")])
    assert peek_cells("u-sort") == original

    # Redo re-sorts to the post-op order.
    %{applied: 1, errors: []} = apply!("u-sort", [redo("u")])

    assert peek_cells("u-sort") == %{
             "A1" => %{"v" => 1},
             "A2" => %{"v" => 2},
             "A3" => %{"v" => 3}
           }
  end

  test "sort_range undo survives a later tab delete (remap_entry clause)" do
    # Two tabs; sort tab 1, then delete tab 0 — the pending sort undo entry
    # must remap its absolute tab index (or undo crashes, the #843 contract).
    create_tabs("u-sort-remap", ["T0", "T1"])

    %{applied: 2, errors: []} =
      apply!("u-sort-remap", [set_cell_on(1, "A1", 2, "u"), set_cell_on(1, "A2", 1, "u")])

    sort = %{
      "op" => "sort_range",
      "tab" => 1,
      "range" => "A1:A2",
      "keys" => [%{"col" => 0, "dir" => "asc"}],
      "user" => "u"
    }

    %{applied: 1, errors: []} = apply!("u-sort-remap", [sort])
    assert peek_cells("u-sort-remap", 1) == %{"A1" => %{"v" => 1}, "A2" => %{"v" => 2}}

    # Delete tab 0: the sorted tab is now index 0; the sort undo entry remaps.
    %{applied: 1, errors: []} = apply!("u-sort-remap", [delete_tab(0, "someone-else")])

    # Undo the sort on its new index — no crash, exact prior order restored.
    %{applied: 1, errors: []} = apply!("u-sort-remap", [undo("u")])
    assert peek_cells("u-sort-remap", 0) == %{"A1" => %{"v" => 2}, "A2" => %{"v" => 1}}
  end

  # ── bg-tighten regression (SF-1 caveat 4): the op-layer bg validator is now
  # CondFormat.valid_bg?/1 (`\z`-anchored), so a trailing-newline bg — which the
  # old `$`-anchored regex admitted — is rejected at the op layer, not stored.
  test "a set_cell_meta bg with a trailing newline is rejected at the op layer" do
    create_sheet("u-bg-nl", %{"A1" => %{"v" => "x"}})

    meta = fn bg ->
      %{"op" => "set_cell_meta", "tab" => 0, "ref" => "A1", "s" => %{"bg" => bg}, "user" => "u"}
    end

    # The `\z` boundary rejects the newline-suffixed color (old `$` accepted it).
    %{applied: 0, errors: [%{code: "invalid_style"}]} = apply!("u-bg-nl", [meta.("#ff0000\n")])
    assert peek_cells("u-bg-nl") == %{"A1" => %{"v" => "x"}}

    # A clean color still applies — the tighten didn't over-reject.
    %{applied: 1, errors: []} = apply!("u-bg-nl", [meta.("#ff0000")])
    assert peek_cells("u-bg-nl") == %{"A1" => %{"v" => "x", "s" => %{"bg" => "#ff0000"}}}
  end

  # ── lossless delete_* undo (task-bb0b8faf5a9a2a37) ────────────────────────
  #
  # A delete_rows/delete_cols rewrites every dead ref to the literal `#REF!`
  # (own tab) and every dead CROSS-TAB ref in other tabs' formulas. That
  # rewrite used to be documented "lossy by design": undo gave the span back
  # and left the `#REF!`s standing — data loss by a keyboard shortcut. The
  # structural inverse now carries the PRE-rewrite cells of exactly the
  # formulas the pass touched, and undo overlays them before the recompute.

  test "undo of a delete_cols restores a formula the rewrite turned into #REF!" do
    create_sheet("u-refloss", %{
      "A1" => %{"v" => 1},
      "A2" => %{"v" => 2},
      "A3" => %{"v" => 3}
    })

    %{applied: 1, errors: []} = apply!("u-refloss", [set_cell("C1", "=SUM(A1:A3)", "alice")])

    total = peek_cells("u-refloss")["C1"]
    assert total["f"] == "SUM(A1:A3)"
    assert total["v"] == 6

    %{applied: 1, errors: []} =
      apply!("u-refloss", [
        %{"op" => "delete_cols", "tab" => 0, "at" => 1, "count" => 1, "user" => "alice"}
      ])

    # The lossy step: the formula shifted to B1 and its range died.
    assert peek_cells("u-refloss")["B1"]["f"] == "SUM(#REF!)"

    %{applied: 1, errors: []} = apply!("u-refloss", [undo("alice")])

    # Formula TEXT and computed VALUE both back — the pre-change session left
    # `SUM(#REF!)` standing here.
    assert peek_cells("u-refloss")["C1"] == total

    # Redo re-deletes and re-rewrites; a second undo restores again (the redo
    # counter re-captures, so the round trip is stable).
    %{applied: 1, errors: []} = apply!("u-refloss", [redo("alice")])
    assert peek_cells("u-refloss")["B1"]["f"] == "SUM(#REF!)"

    %{applied: 1, errors: []} = apply!("u-refloss", [undo("alice")])
    assert peek_cells("u-refloss")["C1"] == total
  end

  test "undo of a delete_cols restores a CROSS-TAB formula the sweep turned into #REF!" do
    create_tabs("u-refloss-ct", ["Sheet1", "Sheet2"])

    %{applied: 2, errors: []} =
      apply!("u-refloss-ct", [
        set_cell_on(1, "A1", 42, "alice"),
        set_cell_on(0, "B1", "=Sheet2!A1", "alice")
      ])

    dependent = peek_cells("u-refloss-ct", 0)["B1"]
    assert dependent["f"] == "Sheet2!A1"

    # Delete Sheet2's column A — the cross-tab sweep rewrites Sheet1's formula.
    %{applied: 1, errors: []} =
      apply!("u-refloss-ct", [
        %{"op" => "delete_cols", "tab" => 1, "at" => 1, "count" => 1, "user" => "alice"}
      ])

    assert peek_cells("u-refloss-ct", 0)["B1"]["f"] == "#REF!"

    %{applied: 1, errors: []} = apply!("u-refloss-ct", [undo("alice")])

    # The OTHER tab's formula is restored too — this is the capture the
    # own-tab inverse could not carry.
    assert peek_cells("u-refloss-ct", 0)["B1"] == dependent
    assert peek_cells("u-refloss-ct", 1)["A1"]["v"] == 42
  end

  test "the delete_* capture is BOUNDED — 1000 cells, 3 rewritten formulas, 3 captured" do
    # 997 plain values in column A (untouched by a delete of column B) plus 3
    # formulas in column D that read the EMPTY column B. Deleting B kills no
    # cell (the span is empty) and rewrites exactly 3 formulas.
    values = for r <- 1..997, into: %{}, do: {"A#{r}", %{"v" => r}}

    formulas =
      for r <- 1..3, into: %{}, do: {"D#{r}", %{"f" => "B#{r}"}}

    create_sheet("u-refloss-bound", Map.merge(values, formulas))

    %{applied: 1, errors: []} =
      apply!("u-refloss-bound", [
        %{"op" => "delete_cols", "tab" => 0, "at" => 2, "count" => 1, "user" => "alice"}
      ])

    # The tab is a thousand cells wide and the delete killed none of them
    # (column B was empty) — only the 3 formulas reading B were rewritten.
    assert map_size(peek_cells("u-refloss-bound")) == 1000

    assert peek_cells("u-refloss-bound")["C1"]["f"] == "#REF!"

    state = :sys.get_state(Session.whereis("u-refloss-bound", @dataset))
    [entry] = Map.fetch!(state.undo, "alice")
    {:structural_restore, op_map, captured, cross} = entry

    assert op_map["op"] == "insert_cols"
    # Proportional to REWRITTEN cells, never a tab snapshot: 3, not 1000.
    assert map_size(captured) == 3
    assert Map.keys(captured) |> Enum.sort() == ["D1", "D2", "D3"]
    assert cross == %{}

    %{applied: 1, errors: []} = apply!("u-refloss-bound", [undo("alice")])
    # The formula text is back (the `#REF!` is gone); the recompute settles its
    # value against the restored — still empty — column B.
    assert peek_cells("u-refloss-bound")["D1"]["f"] == "B1"
  end
end
