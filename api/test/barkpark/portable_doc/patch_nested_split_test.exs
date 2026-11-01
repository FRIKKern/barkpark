defmodule Barkpark.PortableDoc.PatchNestedSplitTest do
  @moduledoc """
  task-42d085f7431b8417: Enter inside a section, expandable, step or tab paragraph
  used to send the container with two children sharing one id, and Patch refused
  the batch (duplicate_id). `test/support/fixtures/paper-editor/nested_split.json` holds
  what today's canvas sends for that edit, recorded by
  `api/assets/paper-editor/src/canvas/__nested_split_id_mounted.test.mjs` (real Enter
  keydowns, then typing). Every batch must apply through `Patch` and through the
  canvas batch write and land as the client believed it did: every typed
  character, no repeated id.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.Papers.BlockOps
  alias Barkpark.PortableDoc.Patch

  @path Path.expand("../../support/fixtures/paper-editor/nested_split.json", __DIR__)
  @external_resource @path
  @scenes @path |> File.read!() |> Jason.decode!() |> Map.fetch!("scenes")

  test "the recording covers every container a paragraph can be split in" do
    assert Enum.map(@scenes, & &1["scene"]) ==
             ~w(section expandable steps tabs section-heading)
  end

  for scene <- @scenes do
    @scene scene

    test "#{scene["scene"]}: every batch applies through Patch" do
      assert {:ok, blocks} = through_patch(@scene)
      assert_landed(@scene, blocks)
    end

    test "#{scene["scene"]}: every batch applies through the canvas batch write" do
      assert {:ok, blocks} = through_batch_write(@scene)
      assert_landed(@scene, blocks)
    end
  end

  defp through_patch(%{"before" => before, "batches" => batches}) do
    batches
    |> Enum.concat()
    |> Enum.reduce_while({:ok, before}, fn op, {:ok, blocks} ->
      with {:ok, lowered} <- BlockOps.lower_editor_op(blocks, op),
           {:ok, next} <- Patch.apply_patch(blocks, lowered) do
        {:cont, {:ok, next}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp through_batch_write(%{"before" => before, "batches" => batches}) do
    slug = "nested-split-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.upsert_paper(Barkpark.LabelFixtures.paper_attrs(%{slug: slug, blocks: before}))

    Enum.reduce_while(batches, {:ok, nil}, fn batch, _ ->
      rev = get_in(Content.get_paper(slug).content, ["rev"])

      case Content.apply_paper_block_ops(slug, batch, "production", if_rev: rev) do
        {:ok, _receipt} -> {:cont, {:ok, Content.paper_blocks(slug)}}
        error -> {:halt, error}
      end
    end)
  end

  defp assert_landed(%{"client_after" => expected}, blocks) do
    assert blocks == expected
    ids = ids(blocks)
    assert ids == Enum.uniq(ids)
    assert ["Left", "Late at six.", "Fog lifted.", "", "Rain."] -- words(blocks) == []
  end

  defp ids(blocks) do
    Enum.flat_map(blocks, fn block ->
      [block["id"] | Enum.flat_map(~w(blocks children steps tabs), &ids(block[&1] || []))]
    end)
  end

  defp words(blocks) do
    Enum.flat_map(blocks, fn block ->
      own =
        case block do
          %{"content" => content} when is_list(content) ->
            [Enum.map_join(content, &(&1["value"] || ""))]

          %{"text" => text} when is_binary(text) ->
            [text]

          _ ->
            []
        end

      own ++ Enum.flat_map(~w(blocks children steps tabs), &words(block[&1] || []))
    end)
  end
end
