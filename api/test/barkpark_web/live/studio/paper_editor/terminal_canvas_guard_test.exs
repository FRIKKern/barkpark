defmodule BarkparkWeb.Studio.PaperEditor.TerminalCanvasGuardTest do
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Patch
  alias BarkparkWeb.Studio.StudioLive.Blocks

  @terminal %{
    "id" => "terminal",
    "type" => "terminal",
    "children" => [
      %{"id" => "child", "type" => "paragraph", "text" => "Original"}
    ]
  }
  @blocks [%{"id" => "section", "type" => "section", "blocks" => [@terminal]}]

  test "canvas-only parent patches and replacements are refused, including mixed batches" do
    for op <- [
          %{"op" => "patch-block", "id" => "terminal", "patch" => %{"title" => "Changed"}},
          %{
            "op" => "replace-block",
            "id" => "terminal",
            "block" => %{"type" => "paragraph", "text" => "Changed"}
          }
        ] do
      assert Blocks.canvas_run_context(%{"ops" => [op]}, @blocks) ==
               {:error, :outdated_terminal_canvas}

      assert Blocks.canvas_run_context(
               %{
                 "ops" => [
                   %{"op" => "patch-block", "id" => "child", "patch" => %{"text" => "Draft"}},
                   op
                 ]
               },
               @blocks
             ) == {:error, :outdated_terminal_canvas}

      # This is intentionally NOT a global core Patch prohibition.
      assert {:ok, _} = Patch.apply_patch(@blocks, op)
    end
  end

  test "old canvas insert and retype cannot introduce a coarse Terminal" do
    for kind <- ~w(append-block insert-after replace-block) do
      assert Blocks.canvas_run_context(
               %{
                 "ops" => [
                   %{"op" => kind, "id" => "child", "afterId" => "child", "block" => @terminal}
                 ]
               },
               @blocks
             ) == {:error, :outdated_terminal_canvas}
    end
  end

  test "child edits and non-reconstructing moves and removals retain their normal validation path" do
    for op <- [
          %{"op" => "patch-block", "id" => "child", "patch" => %{"text" => "Edited"}},
          %{"op" => "remove-block", "id" => "terminal"},
          %{"op" => "move-block", "id" => "terminal", "index" => 0},
          %{
            "op" => "append-block",
            "block" => %{"id" => "new", "type" => "paragraph", "text" => "New"}
          }
        ] do
      assert Blocks.canvas_run_context(%{"ops" => [op]}, @blocks) == {:ok, nil}
    end

    assert {:ok, %{container_kind: "terminal"}} =
             Blocks.canvas_run_context(
               %{
                 "ops" => [
                   %{"op" => "patch-block", "id" => "child", "patch" => %{"text" => "Edited"}}
                 ],
                 "container_kind" => "terminal",
                 "container_id" => "terminal",
                 "container_run_ids" => ["child"]
               },
               @blocks
             )
  end
end
