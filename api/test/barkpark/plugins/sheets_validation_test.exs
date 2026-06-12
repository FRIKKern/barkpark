defmodule Barkpark.Plugins.SheetsValidationTest do
  @moduledoc """
  Locks the Sheets plugin's `before_save` structural gate: a sheet document
  whose cells map is malformed (non-A1 key, cell descriptor not a map, cells
  not a map) halts the save with `{:error, {:halted, reason}}`; well-formed
  sheets and non-sheet documents pass untouched.

  The plugin is wired in via the `:plugins` env so `Barkpark.Plugins.Hooks`
  fires its hooks deterministically; RegistryCase restores the baseline.
  """
  use Barkpark.DataCase, async: false
  use Barkpark.RegistryCase

  alias Barkpark.Content

  @dataset "sheets_validation_test"

  setup do
    Application.put_env(:barkpark, :plugins, [Barkpark.Plugins.Sheets])
    # RegistryCase + DataCase both restore the env baseline on exit.
    :ok
  end

  defp create_sheet_with_cells(id, cells), do: create_sheet_with_tab(id, %{"cells" => cells})

  defp create_sheet_with_tab(id, tab) do
    Content.create_document(
      "sheet",
      %{"doc_id" => id, "content" => %{"tabs" => [tab]}},
      @dataset
    )
  end

  test "a non-A1 cell key halts the save" do
    assert {:error, {:halted, msg}} =
             create_sheet_with_cells("val-1", %{"NOTANADDRESS" => %{"v" => "x"}})

    assert msg =~ "invalid cell address"
    assert msg =~ "NOTANADDRESS"
  end

  test "a cell descriptor that is not a map halts the save" do
    assert {:error, {:halted, msg}} =
             create_sheet_with_cells("val-2", %{"A1" => "not-a-map"})

    assert msg =~ ~s(cell "A1" must be a map)
  end

  test "cells that is not a map halts the save" do
    assert {:error, {:halted, msg}} = create_sheet_with_cells("val-3", "not-a-map-at-all")
    assert msg =~ "cells must be a map"
  end

  test "errors across tabs aggregate with tab indexes" do
    {:error, {:halted, msg}} =
      Content.create_document(
        "sheet",
        %{
          "doc_id" => "val-4",
          "content" => %{
            "tabs" => [
              %{"cells" => %{"A1" => %{"v" => "ok"}}},
              %{"cells" => %{"bogus" => %{"v" => "x"}}}
            ]
          }
        },
        @dataset
      )

    assert msg =~ "tab 1"
    refute msg =~ "tab 0"
  end

  test "a halted save writes nothing" do
    {:error, {:halted, _}} = create_sheet_with_cells("val-5", %{"A 1" => %{"v" => "x"}})
    assert {:error, :not_found} = Content.get_document("drafts.val-5", "sheet", @dataset)
  end

  test "a well-formed sheet passes (v and f stay free-form)" do
    assert {:ok, _} =
             create_sheet_with_cells("val-ok", %{
               "A1" => %{"v" => "ok"},
               "AA99" => %{"v" => 123, "f" => "=SUM(A1:A2)", "t" => "n", "stale" => true}
             })
  end

  test "a cell beyond column XFD halts the save" do
    assert {:error, {:halted, msg}} =
             create_sheet_with_cells("val-b1", %{"ZZZZ1" => %{"v" => "x"}})

    assert msg =~ ~s(cell "ZZZZ1" is beyond the grid bounds)
    assert msg =~ "column 475254 > 16384/XFD"
  end

  test "a cell beyond row 1_048_576 halts the save" do
    assert {:error, {:halted, msg}} =
             create_sheet_with_cells("val-b2", %{"A1048577" => %{"v" => "x"}})

    assert msg =~ ~s(cell "A1048577" is beyond the grid bounds)
    assert msg =~ "row 1048577 > 1048576"
  end

  test "a merge corner beyond column XFD halts the save (area within the cap)" do
    assert {:error, {:halted, msg}} =
             create_sheet_with_tab("val-b3", %{
               "cells" => %{"A1" => %{"v" => "x"}},
               "merges" => ["XFE1:XFF2"]
             })

    assert msg =~ ~s(merge "XFE1:XFF2" corner "XFE1" is beyond the grid bounds)
    assert msg =~ "column 16385 > 16384/XFD"
    refute msg =~ "covers"
  end

  test "the grid corner XFD1048576 passes the gate" do
    assert {:ok, _} = create_sheet_with_cells("val-b4", %{"XFD1048576" => %{"v" => "corner"}})
  end

  test "a malformed merge halts the save" do
    assert {:error, {:halted, msg}} =
             create_sheet_with_tab("val-m1", %{
               "cells" => %{"A1" => %{"v" => "x"}},
               "merges" => ["A1:B2", "bogus"]
             })

    assert msg =~ "invalid merge"
    assert msg =~ "bogus"
  end

  test "a merge whose area exceeds the cap halts the save" do
    assert {:error, {:halted, msg}} =
             create_sheet_with_tab("val-m2", %{
               "cells" => %{"A1" => %{"v" => "x"}},
               "merges" => ["A1:ZZZ1000000"]
             })

    assert msg =~ "covers"
    assert msg =~ "the cap is 10000"
  end

  test "merges that is not a list halts the save" do
    assert {:error, {:halted, msg}} = create_sheet_with_tab("val-m3", %{"merges" => "A1:B2"})
    assert msg =~ "merges must be a list"
  end

  test "well-formed merges within the area cap pass (reversed corners too)" do
    assert {:ok, _} =
             create_sheet_with_tab("val-m4", %{
               "cells" => %{"A1" => %{"v" => "x"}},
               "merges" => ["A1:B2", "B2:A1"]
             })
  end

  test "a sheet with no cells key passes" do
    assert {:ok, _} =
             Content.create_document(
               "sheet",
               %{"doc_id" => "val-nocells", "content" => %{"tabs" => [%{"name" => "T"}]}},
               @dataset
             )
  end

  test "non-sheet documents are not gated" do
    assert {:ok, _} =
             Content.create_document(
               "post",
               %{"doc_id" => "val-post", "content" => %{"tabs" => [%{"cells" => "junk"}]}},
               @dataset
             )
  end

  test "the validation also gates the upsert path" do
    {:ok, doc} = create_sheet_with_cells("val-upd", %{"A1" => %{"v" => "fine"}})

    assert {:error, {:halted, _}} =
             Content.upsert_document(
               "sheet",
               %{"doc_id" => doc.doc_id, "content" => %{"tabs" => [%{"cells" => %{"x" => %{}}}]}},
               @dataset
             )
  end
end
