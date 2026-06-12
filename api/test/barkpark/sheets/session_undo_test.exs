defmodule Barkpark.Sheets.SessionUndoTest do
  @moduledoc """
  M4 locks for per-user undo/redo in `Barkpark.Sheets.Session`.

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
  `Barkpark.Sheets.SessionTest`.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Sheets.Session

  @dataset "sheets_m4_undo_test"

  setup do
    stop_all_sessions()

    on_exit(fn ->
      stop_all_sessions()
      Application.delete_env(:barkpark, Barkpark.Sheets.Session)
    end)

    put_cfg(debounce_ms: 60_000, idle_stop_ms: 60_000)
    :ok
  end

  defp put_cfg(overrides) do
    base = Application.get_env(:barkpark, Barkpark.Sheets.Session, [])
    Application.put_env(:barkpark, Barkpark.Sheets.Session, Keyword.merge(base, overrides))
  end

  defp stop_all_sessions do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(Barkpark.Sheets.SessionSupervisor),
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

  defp set_cell(ref, raw, user), do: %{"op" => "set_cell", "tab" => 0, "ref" => ref, "raw" => raw, "user" => user}
  defp clear_cell(ref, user), do: %{"op" => "clear_cell", "tab" => 0, "ref" => ref, "user" => user}
  defp undo(user), do: %{"op" => "undo", "user" => user}
  defp redo(user), do: %{"op" => "redo", "user" => user}

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
    %{applied: 2, errors: []} = apply!("u-own", [set_cell("A1", "alice", "alice"), set_cell("B1", "bob", "bob")])

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
    %{applied: 0, errors: [%{code: "invalid_user"}]} = apply!("u-nouser", [%{"op" => "redo", "user" => ""}])
    %{applied: 0, errors: [%{code: "nothing_to_undo"}]} = apply!("u-nouser", [undo("nobody")])
    %{applied: 0, errors: [%{code: "nothing_to_redo"}]} = apply!("u-nouser", [redo("nobody")])
  end

  test "ops without a user stamp record no history" do
    create_sheet("u-anon", %{})
    %{applied: 1} = apply!("u-anon", [%{"op" => "set_cell", "tab" => 0, "ref" => "A1", "raw" => 1}])
    %{applied: 0, errors: [%{code: "nothing_to_undo"}]} = apply!("u-anon", [undo("anyone")])
  end

  # ── inverse correctness: cell ops ───────────────────────────────────────────

  test "set_cell over an existing formula cell restores the exact prior map" do
    create_sheet("u-cell", %{"A1" => %{"v" => 2}, "B1" => %{"f" => "A1*10", "v" => 20, "t" => "n"}})

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
    create_sheet("u-insrow", %{"A1" => %{"v" => 5}, "A2" => %{"f" => "A1*2", "v" => 10, "t" => "n"}})

    %{applied: 1} =
      apply!("u-insrow", [%{"op" => "insert_rows", "tab" => 0, "at" => 1, "count" => 2, "user" => "alice"}])

    assert peek_cells("u-insrow") == %{"A3" => %{"v" => 5}, "A4" => %{"f" => "A3*2", "v" => 10, "t" => "n"}}

    %{applied: 1, errors: []} = apply!("u-insrow", [undo("alice")])
    assert peek_cells("u-insrow") == %{"A1" => %{"v" => 5}, "A2" => %{"f" => "A1*2", "v" => 10, "t" => "n"}}
  end

  test "delete_rows undoes to an insert restoring the captured span" do
    create_sheet("u-delrow", %{
      "A1" => %{"v" => "head"},
      "A2" => %{"v" => "gone-1"},
      "A3" => %{"v" => "gone-2"},
      "A4" => %{"v" => "tail"}
    })

    %{applied: 1} =
      apply!("u-delrow", [%{"op" => "delete_rows", "tab" => 0, "at" => 2, "count" => 2, "user" => "alice"}])

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
      apply!("u-cols", [%{"op" => "insert_cols", "tab" => 0, "at" => 2, "count" => 1, "user" => "alice"}])

    %{applied: 1} =
      apply!("u-cols", [%{"op" => "delete_cols", "tab" => 0, "at" => 1, "count" => 2, "user" => "alice"}])

    assert peek_cells("u-cols") == %{"A1" => %{"v" => "b"}, "B1" => %{"v" => "c"}}

    # Undo the delete (insert + captured span), then the insert (delete).
    %{applied: 1} = apply!("u-cols", [undo("alice")])
    assert peek_cells("u-cols") == %{"A1" => %{"v" => "a"}, "C1" => %{"v" => "b"}, "D1" => %{"v" => "c"}}

    %{applied: 1} = apply!("u-cols", [undo("alice")])
    assert peek_cells("u-cols") == %{"A1" => %{"v" => "a"}, "B1" => %{"v" => "b"}, "C1" => %{"v" => "c"}}
  end

  test "set_col_width and set_row_height undo to the prior px (nil clears)" do
    create_sheet("u-size", %{})

    %{applied: 1} =
      apply!("u-size", [%{"op" => "set_col_width", "tab" => 0, "col" => 2, "px" => 140, "user" => "alice"}])

    %{applied: 1} =
      apply!("u-size", [%{"op" => "set_col_width", "tab" => 0, "col" => 2, "px" => 200, "user" => "alice"}])

    assert peek_tab("u-size", 0)["col_widths"] == %{"2" => 200}

    %{applied: 1} = apply!("u-size", [undo("alice")])
    assert peek_tab("u-size", 0)["col_widths"] == %{"2" => 140}

    # The first op had no prior entry — its undo clears the width entirely.
    %{applied: 1} = apply!("u-size", [undo("alice")])
    assert peek_tab("u-size", 0)["col_widths"] == %{}

    %{applied: 1} =
      apply!("u-size", [%{"op" => "set_row_height", "tab" => 0, "row" => 3, "px" => 36, "user" => "alice"}])

    %{applied: 1} = apply!("u-size", [undo("alice")])
    assert peek_tab("u-size", 0)["row_heights"] == %{}
  end

  test "rename_tab, add_tab and delete_tab invert exactly" do
    create_sheet("u-tabs", %{"A1" => %{"v" => "x"}})

    %{applied: 1} = apply!("u-tabs", [%{"op" => "rename_tab", "tab" => 0, "name" => "Renamed", "user" => "alice"}])
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
      apply!("u-redostruct", [%{"op" => "delete_rows", "tab" => 0, "at" => 1, "count" => 1, "user" => "alice"}])

    %{applied: 1} = apply!("u-redostruct", [undo("alice")])
    assert peek_cells("u-redostruct") == %{"A1" => %{"v" => "x"}, "A2" => %{"v" => "y"}}

    %{applied: 1, errors: []} = apply!("u-redostruct", [redo("alice")])
    assert peek_cells("u-redostruct") == %{"A1" => %{"v" => "y"}}
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
    Phoenix.PubSub.subscribe(Barkpark.PubSub, Session.topic("u-delta", @dataset, doc.workspace_id))

    %{rev: 1} = apply!("u-delta", [set_cell("A1", "v1", "alice")])
    assert_receive {:sheets_op, %{rev: 1, changed: %{"A1" => %{"v" => "v1"}}}}, 1_000

    %{rev: 2, applied: 1} = apply!("u-delta", [undo("alice")])
    assert_receive {:sheets_op, %{rev: 2, changed: %{"A1" => nil}}}, 1_000

    %{rev: 3, applied: 1} = apply!("u-delta", [redo("alice")])
    assert_receive {:sheets_op, %{rev: 3, changed: %{"A1" => %{"v" => "v1"}}}}, 1_000
  end
end
