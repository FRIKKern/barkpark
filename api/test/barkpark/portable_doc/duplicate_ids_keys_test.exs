defmodule Barkpark.PortableDoc.DuplicateIdsKeysTest do
  @moduledoc """
  task-c91fbd0c5c7bb4a6 and task-42d085f7431b8417 criterion 2: what each editor
  contract sent for a real drop between sections and a real Enter inside one,
  recorded in headless Chromium by
  `api/assets/paper-editor/src/__duplicate_ids_keys.mjs`, with the host
  answering each batch with the echo the batch write stores.
  """
  use Barkpark.DataCase, async: false

  import ExUnit.CaptureLog

  alias Barkpark.Content
  alias Barkpark.Content.Papers.BlockOps
  alias Barkpark.PortableDoc.Patch

  @fixture Path.expand("../../support/fixtures/paper-editor/duplicate_ids_keys.json", __DIR__)
  @external_resource @fixture
  @scenes @fixture |> File.read!() |> Jason.decode!() |> Map.fetch!("scenes")

  test "every contract from 1.14 and the open canvas fix is recorded, both echo orders for each Enter" do
    keys = Enum.map(@scenes, &{&1["contract"], &1["scene"], &1["order"]})

    for contract <- ~w(1.14 1.15 1.16 1.17 1.18 1.19 1.20 1.21 tree pr-25040),
        scene <-
          ~w(nested-enter-keep-typing nested-enter-back-up nested-enter-retype-line nested-enter-pause-type-above nested-enter-line-start steps-enter tabs-enter),
        order <- ~w(reply-first echo-first) do
      assert {contract, scene, order} in keys
    end

    assert {"1.14", "move-up", "reply-first"} in keys
    assert {"pr-25040", "move-down", "reply-first"} in keys
  end

  for scene <- @scenes do
    @scene scene
    @name "#{scene["contract"]} #{scene["scene"]} #{scene["order"]}"

    test "#{@name}: every batch saves through the batch write and a reload shows every typed line" do
      %{"before" => before, "batches" => batches, "echoes" => echoes, "seen" => seen} = @scene
      slug = "keys-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Content.upsert_paper(Barkpark.LabelFixtures.paper_attrs(%{slug: slug, blocks: before}))

      doubt? =
        @scene["scene"] == "nested-enter-retype-line" and
          @scene["contract"] not in ["tree", "pr-25040"]

      for {batch, echo} <- Enum.zip(batches, echoes) do
        rev = get_in(Content.get_paper(slug).content, ["rev"])

        log =
          capture_log(fn ->
            assert {:ok, _receipt} =
                     Content.apply_paper_block_ops(slug, batch, "production",
                       if_rev: rev,
                       remint_writer: "lv:keys"
                     )
          end)

        refute log =~ "Mist."
        unless doubt?, do: assert(Content.paper_blocks(slug) == echo)
      end

      stored = Content.paper_blocks(slug)
      assert ids(stored) == Enum.uniq(ids(stored))
      assert Enum.all?(@scene["typed"], &(&1 in lines(stored)))

      if doubt? do
        assert lines(stored) == List.insert_at(seen, 1, "Fog by eight.")
      else
        assert lines(stored) == seen
      end
    end

    if scene["scene"] in ["move-up", "move-down"] or scene["contract"] == "pr-25040" do
      test "#{@name}: every batch folds through Patch to the echo" do
        Enum.zip(@scene["batches"], @scene["echoes"])
        |> Enum.reduce(@scene["before"], fn {batch, echo}, blocks ->
          lowered =
            Enum.map_reduce(batch, blocks, fn op, acc ->
              {:ok, op} = BlockOps.lower_editor_op(acc, op)
              {:ok, next} = Patch.apply_patch(acc, op, duplicates: :batch)
              {op, next}
            end)
            |> elem(0)

          assert {:ok, folded} = Patch.apply_patches(blocks, lowered)
          assert folded == echo
          folded
        end)
      end
    end
  end

  defp ids(blocks) do
    Enum.flat_map(blocks, fn block ->
      [block["id"] | ids(Map.get(block, "blocks", []))] ++
        Enum.flat_map(rows(block), &[&1["id"] | ids(&1["blocks"])])
    end)
  end

  defp rows(block), do: Map.get(block, "steps", []) ++ Map.get(block, "tabs", [])

  defp lines(blocks) do
    Enum.flat_map(blocks, fn
      %{"type" => "section", "blocks" => children} ->
        lines(children)

      %{"type" => type} = block when type in ["steps", "tabs"] ->
        rows(block) |> Enum.flat_map(&lines(&1["blocks"]))

      %{"content" => content} ->
        [Enum.map_join(content, &(&1["value"] || ""))]

      %{"text" => text} ->
        [text]
    end)
  end
end
