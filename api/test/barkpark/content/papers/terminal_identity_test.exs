defmodule Barkpark.Content.Papers.TerminalIdentityTest do
  use ExUnit.Case, async: true

  alias Barkpark.Content.Papers.BlockOps

  test "projects ids only through canonical children and preserves nested metadata" do
    blocks = [
      %{"id" => "term-0", "type" => "paragraph", "text" => "Reserved"},
      %{
        "id" => "term",
        "type" => "terminal",
        "title" => "Shell",
        "unknown" => %{"keep" => true},
        "children" => [
          %{
            "type" => "section",
            "section-meta" => 7,
            "blocks" => [%{"type" => "paragraph", "text" => "Visible"}]
          }
        ]
      }
    ]

    [outside, projected] = BlockOps.ensure_block_ids(blocks)
    [section] = projected["children"]

    assert outside == hd(blocks)
    assert section["id"] == "term-0-1"
    assert section["section-meta"] == 7
    assert hd(section["blocks"])["id"] == "term-0-1-0"
    assert projected["title"] == "Shell"
    assert projected["unknown"] == %{"keep" => true}
    assert BlockOps.ensure_block_ids([outside, projected]) == [outside, projected]
  end

  test "legacy blocks-only, dual aliases, and malformed children stay opaque and byte-identical" do
    hidden = [%{"type" => "paragraph", "text" => "Hidden"}]

    terminals = [
      %{"id" => "blocks-only", "type" => "terminal", "blocks" => hidden},
      %{"id" => "dual", "type" => "terminal", "children" => [], "blocks" => hidden},
      %{"id" => "nil", "type" => "terminal", "children" => nil},
      %{"id" => "scalar", "type" => "terminal", "children" => "legacy"},
      %{"id" => "missing", "type" => "terminal", "unknown" => %{"keep" => true}}
    ]

    assert BlockOps.ensure_block_ids(terminals) == terminals
    assert {:ok, ^terminals} = BlockOps.project_block_ids_safely(terminals)
  end

  test "both terminal aliases reserve authored ids and reject hidden collisions" do
    legacy = %{
      "id" => "legacy",
      "type" => "terminal",
      "blocks" => [%{"id" => "term-0", "type" => "paragraph"}]
    }

    canonical = %{
      "id" => "term",
      "type" => "terminal",
      "children" => [%{"type" => "paragraph", "text" => "Visible"}]
    }

    [same_legacy, projected] = BlockOps.ensure_block_ids([legacy, canonical])
    assert same_legacy == legacy
    assert hd(projected["children"])["id"] == "term-0-1"

    outside_collision = [
      %{"id" => "hidden", "type" => "paragraph"},
      %{
        "id" => "terminal",
        "type" => "terminal",
        "blocks" => [%{"id" => "hidden", "type" => "paragraph"}]
      }
    ]

    assert {:error, {:duplicate_id, "hidden"}} =
             BlockOps.project_block_ids_safely(outside_collision)

    dual_collision = [
      %{
        "id" => "terminal",
        "type" => "terminal",
        "children" => [%{"id" => "same", "type" => "paragraph"}],
        "blocks" => [%{"id" => "same", "type" => "paragraph"}]
      }
    ]

    assert {:error, {:duplicate_id, "same"}} =
             BlockOps.project_block_ids_safely(dual_collision)
  end
end
