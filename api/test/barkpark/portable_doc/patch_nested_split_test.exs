defmodule Barkpark.PortableDoc.PatchNestedSplitTest do
  @moduledoc """
  task-42d085f7431b8417: Enter inside a section, expandable, step or tab paragraph
  used to send the container with two children sharing one id, and Patch refused
  the batch (duplicate_id). A copy or move of a block across depths, by paste or
  drop, did the same or patched an id the server no longer held.
  `test/support/fixtures/paper-editor/nested_split.json` holds what today's canvas
  sends for those edits, recorded by
  `api/assets/paper-editor/src/canvas/__nested_split_id_mounted.test.mjs` (real Enter
  keydowns, pastes, then typing), and `nested_split_keys.json`, recorded by
  `api/assets/paper-editor/src/__nested_split_keys.mjs` (Playwright's keyboard and
  mouse in Chromium: splits, a copy-drop and a move-drop). Every batch must apply through `Patch` and through
  the canvas batch write and land as the client believed it did: every typed
  string (the scene's `typed`), no repeated id.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.Papers.BlockOps
  alias Barkpark.PortableDoc.Patch

  @path Path.expand("../../support/fixtures/paper-editor/nested_split.json", __DIR__)
  @keys_path Path.expand("../../support/fixtures/paper-editor/nested_split_keys.json", __DIR__)
  @external_resource @path
  @external_resource @keys_path
  @scenes Enum.flat_map(
            [@path, @keys_path],
            &(&1 |> File.read!() |> Jason.decode!() |> Map.fetch!("scenes"))
          )

  test "the recording covers every container a paragraph can be split in, and every copy and move door" do
    assert Enum.map(@scenes, & &1["scene"]) ==
             ~w(section expandable steps tabs section-heading copy-to-top copy-in-section move-to-top paste-above paste-into-column paste-into-section) ++
               ~w(keys-section keys-expandable keys-steps keys-tabs keys-copy-drop keys-move-drop)
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

  defp assert_landed(%{"client_after" => expected, "typed" => typed}, blocks) do
    assert Enum.map(blocks, &without_column_child_ids/1) == expected
    ids = ids(blocks)
    assert ids == Enum.uniq(ids)
    assert typed -- words(blocks) == []
  end

  # The batch write names a column's children (col1-column-0-0); the canvas keeps
  # none for them, so its after-state has no such ids.
  defp without_column_child_ids(%{"columns" => columns} = block) when is_list(columns) do
    %{
      block
      | "columns" => Enum.map(columns, fn column -> Enum.map(column, &Map.delete(&1, "id")) end)
    }
  end

  defp without_column_child_ids(block), do: block

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
