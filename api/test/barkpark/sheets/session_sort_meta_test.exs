defmodule Barkpark.Plugins.Sheets.SessionSortMetaTest do
  @moduledoc """
  SF-AM3 / SF-D6 — the sort_range structure broadcast must carry `rect` + the
  permutation ACTUALLY APPLIED so a remote collaborator can remap a selection
  or open editor inside the sorted rect (closing the stale-coordinate clobber
  the sort-engine perfecter flagged). Forward sort broadcasts its perm; undo
  broadcasts the INVERSE over the same rect; redo the original again — each
  frame carries its own correct rect+perm (SF-D6, both emit sites).

  `async: false` for the same reason SessionTest is: sessions are globally
  registered processes that read/persist through the SQL sandbox.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Plugins.Sheets.Session

  @dataset "sheets_sort_meta_test"

  setup do
    stop_all_sessions()

    on_exit(fn ->
      stop_all_sessions()
      Application.delete_env(:barkpark, Barkpark.Plugins.Sheets.Session)
    end)

    base = Application.get_env(:barkpark, Barkpark.Plugins.Sheets.Session, [])

    Application.put_env(
      :barkpark,
      Barkpark.Plugins.Sheets.Session,
      Keyword.merge(base, debounce_ms: 60_000, idle_stop_ms: 60_000)
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

  defp create_sheet(slug, cells) do
    {:ok, doc} =
      Content.create_document(
        "sheet",
        %{
          "doc_id" => slug,
          "content" => %{"locale" => "nb-NO", "tabs" => [%{"name" => "T0", "cells" => cells}]}
        },
        @dataset
      )

    doc
  end

  test "forward/undo/redo sort broadcasts each carry rect + the applied perm" do
    # A1=3, A2=1, A3=2 ascending sorts to 1,2,3. As an old-offset → new-position
    # permutation that is [2, 0, 1] (A1 last, A2 first, A3 middle); its inverse
    # is [1, 2, 0]. These are the exact frames a remote viewer must remap by.
    doc =
      create_sheet("sort-meta", %{
        "A1" => %{"v" => 3},
        "A2" => %{"v" => 1},
        "A3" => %{"v" => 2}
      })

    Phoenix.PubSub.subscribe(
      Barkpark.PubSub,
      Session.topic("sort-meta", @dataset, doc.workspace_id)
    )

    sort = %{
      "op" => "sort_range",
      "tab" => 0,
      "range" => "A1:A3",
      "keys" => [%{"col" => 0, "dir" => "asc"}],
      "user" => "u"
    }

    {:ok, %{applied: 1, errors: []}} = Session.apply_ops("sort-meta", @dataset, [sort])

    assert_receive {:sheets_op, %{structure: fwd}}, 1_000
    assert fwd.op == "sort_range"
    assert fwd.tab == 0
    assert fwd.at == nil
    assert fwd.count == nil
    assert fwd.rect == {1, 1, 1, 3}
    assert fwd.perm == [2, 0, 1]

    # Undo re-applies the INVERSE permutation over the SAME rect.
    {:ok, %{applied: 1, errors: []}} =
      Session.apply_ops("sort-meta", @dataset, [%{"op" => "undo", "user" => "u"}])

    assert_receive {:sheets_op, %{structure: undo}}, 1_000
    assert undo.op == "sort_range"
    assert undo.rect == {1, 1, 1, 3}
    assert undo.perm == [1, 2, 0]

    # Redo re-applies the ORIGINAL permutation again.
    {:ok, %{applied: 1, errors: []}} =
      Session.apply_ops("sort-meta", @dataset, [%{"op" => "redo", "user" => "u"}])

    assert_receive {:sheets_op, %{structure: redo}}, 1_000
    assert redo.op == "sort_range"
    assert redo.rect == {1, 1, 1, 3}
    assert redo.perm == [2, 0, 1]
  end
end
