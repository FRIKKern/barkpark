defmodule Barkpark.PortableDoc.DuplicateIdsKeysTest do
  @moduledoc """
  task-c91fbd0c5c7bb4a6 and task-42d085f7431b8417 criterion 2: what each editor
  contract sent for a real drop between sections and a real Enter inside a
  section, step or tab, recorded in headless Chromium by
  `api/assets/paper-editor/src/__duplicate_ids_keys.mjs`. A drop saves on every
  contract; an old editor's split repeats an id and is refused; the tree's
  split never repeats one.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.Papers.BlockOps
  alias Barkpark.PortableDoc.Patch

  @fixture Path.expand("../../support/fixtures/paper-editor/duplicate_ids_keys.json", __DIR__)
  @external_resource @fixture
  @scenes @fixture |> File.read!() |> Jason.decode!() |> Map.fetch!("scenes")

  test "every contract from 1.14 and the tree is recorded for every scene" do
    keys = Enum.map(@scenes, &{&1["contract"], &1["scene"]})

    for contract <- ~w(1.14 1.15 1.16 1.17 1.18 1.19 1.20 1.21 tree),
        scene <- ~w(move-up move-down nested-enter-keep-typing steps-enter tabs-enter) do
      assert {contract, scene} in keys
    end
  end

  for scene <- @scenes do
    @scene scene
    @name "#{scene["contract"]} #{scene["scene"]}"

    if scene["contract"] != "tree" and scene["scene"] not in ["move-up", "move-down"] do
      test "#{@name}: the old editor's split repeats an id, so its batch is refused and writes nothing" do
        %{"before" => before, "batches" => [batch | _]} = @scene
        slug = seed!(before)
        content = Content.get_paper(slug).content

        assert {:error, {:duplicate_id, _id, _kind}} =
                 Content.apply_paper_block_ops(slug, batch, "production", if_rev: content["rev"])

        assert Content.get_paper(slug).content == content
      end
    else
      test "#{@name}: every batch saves through the batch write and a reload shows every typed line" do
        %{"before" => before, "batches" => batches, "echoes" => echoes, "seen" => seen} = @scene
        slug = seed!(before)

        for {batch, echo} <- Enum.zip(batches, echoes) do
          rev = get_in(Content.get_paper(slug).content, ["rev"])

          assert {:ok, _receipt} =
                   Content.apply_paper_block_ops(slug, batch, "production", if_rev: rev)

          assert Content.paper_blocks(slug) == echo
        end

        stored = Content.paper_blocks(slug)
        assert ids(stored) == Enum.uniq(ids(stored))
        assert lines(stored) == seen
      end

      test "#{@name}: every batch folds through Patch to the echo" do
        Enum.zip(@scene["batches"], @scene["echoes"])
        |> Enum.reduce(@scene["before"], fn {batch, echo}, blocks ->
          lowered =
            Enum.map_reduce(batch, blocks, fn op, acc ->
              {:ok, op} = BlockOps.lower_editor_op(acc, op)
              {:ok, next} = Patch.apply_patch(acc, op, duplicates: {:batch, blocks})
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

  defp seed!(blocks) do
    slug = "keys-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.upsert_paper(Barkpark.LabelFixtures.paper_attrs(%{slug: slug, blocks: blocks}))

    slug
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
