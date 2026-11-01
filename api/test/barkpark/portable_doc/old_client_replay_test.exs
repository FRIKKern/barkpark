defmodule Barkpark.PortableDoc.OldClientReplayTest do
  @moduledoc """
  task-bd639a133641c5c3 (R2.2): an editor still open on an older contract keeps
  saving. Each fixture under `test/fixtures/portable_doc/old_client_replay/` is
  what one contract's editor tree sent for the same synthetic edits, recorded by
  `api/assets/paper-editor/scripts/record-replay.mjs` from that tree's source at
  the commit the fixture names. Every batch must apply through today's `Patch`
  and through the canvas's batch write, and land as the client believed it did.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.Papers.BlockOps
  alias Barkpark.PortableDoc.Patch

  @dir Path.expand("../../fixtures/portable_doc/old_client_replay", __DIR__)
  @contracts ~w(1.14 1.15 1.16 1.17 1.18 1.19)

  test "a recording exists for every contract and nothing else" do
    recorded =
      @dir |> Path.join("*.json") |> Path.wildcard() |> Enum.map(&Path.basename(&1, ".json"))

    assert Enum.sort(recorded) == @contracts
  end

  test "each recording links [[Title]] through exactly the doors its contract opened" do
    doors =
      Map.new(@contracts, fn contract ->
        scenes =
          Path.join(@dir, "#{contract}.json")
          |> File.read!()
          |> Jason.decode!()
          |> Map.fetch!("scenes")

        sent = fn name ->
          scenes |> Enum.find(&(&1["scene"] == name)) |> Map.fetch!("batches") |> Jason.encode!()
        end

        linked =
          for {door, scene, mark} <- [
                {"typed", "wikilink-typed", ~s("docId")},
                {"pasted", "wikilink-pasted", ~s("docId")},
                {"alias", "wikilink-alias", ~s("alias")}
              ],
              String.contains?(sent.(scene), mark),
              do: door

        {contract, linked}
      end)

    assert doors == %{
             "1.14" => [],
             "1.15" => [],
             "1.16" => [],
             "1.17" => ["typed"],
             "1.18" => ["typed", "pasted"],
             "1.19" => ["typed", "pasted", "alias"]
           }
  end

  for contract <- @contracts do
    path = Path.join(@dir, "#{contract}.json")
    @external_resource path
    recording = path |> File.read!() |> Jason.decode!()

    describe "contract #{contract}" do
      test "the recording is that contract's editor, every scene recorded" do
        recording = unquote(Macro.escape(recording))
        assert recording["contract"] == unquote(contract) <> ".0"
        assert recording["commit"] =~ ~r/^[0-9a-f]{10}$/
        assert Enum.all?(recording["scenes"], &(is_binary(&1["scene"]) and &1["batches"] != []))
      end

      for scene <- recording["scenes"] do
        @scene scene

        test "#{scene["scene"]}: every batch applies through Patch" do
          blocks =
            Enum.reduce(Enum.concat(@scene["batches"]), @scene["before"], fn op, blocks ->
              assert {:ok, lowered} = BlockOps.lower_editor_op(blocks, op)
              assert {:ok, next} = Patch.apply_patch(blocks, lowered)
              next
            end)

          assert_landed(@scene, blocks)
        end

        test "#{scene["scene"]}: every batch applies through the canvas batch write" do
          slug = "replay-#{System.unique_integer([:positive])}"

          {:ok, _} =
            Content.upsert_paper(
              Barkpark.LabelFixtures.paper_attrs(%{slug: slug, blocks: @scene["before"]})
            )

          for batch <- @scene["batches"] do
            rev = get_in(Content.get_paper(slug).content, ["rev"])

            assert {:ok, _receipt} =
                     Content.apply_paper_block_ops(slug, batch, "production", if_rev: rev)
          end

          assert_landed(@scene, Content.paper_blocks(slug))
        end
      end
    end
  end

  defp assert_landed(%{"client_after" => expected}, blocks), do: assert(blocks == expected)

  defp assert_landed(%{"batches" => batches}, blocks) do
    for [op] <- batches, do: assert_intent(op, Enum.find(blocks, &(&1["id"] == op["id"])))
  end

  defp assert_intent(%{"op" => "patch-card-body", "content" => content}, card),
    do: assert([%{"type" => "paragraph", "content" => ^content}] = card["slots"]["body"])

  defp assert_intent(%{"op" => "patch-table-cells", "cells" => cells}, table) do
    for %{"area" => area, "row" => row, "column" => column, "content" => content} <- cells do
      cells = if area == "head", do: table["head"], else: Enum.at(table["rows"], row)
      assert Enum.at(cells, column) == content
    end
  end

  defp assert_intent(
         %{"op" => "patch-table-structure", "action" => "add-row", "shape" => shape},
         table
       ),
       do: assert(length(table["rows"]) == length(shape["rows"]) + 1)
end
