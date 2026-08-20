defmodule Barkpark.PortableDoc.BpmlDiffTest do
  @moduledoc """
  The differ's proof (masterplan W3): for any old/new pair, the derived op
  batch replays through `Patch.apply_patches/2` to exactly the new blocks —
  asserted directly on crafted cases and under a deterministic mutation storm
  (200 random edit sequences over kernel-shaped documents).
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Bpml.Diff
  alias Barkpark.PortableDoc.Patch

  defp block(id, text \\ nil) do
    %{
      "id" => id,
      "type" => "paragraph",
      "content" => [%{"type" => "text", "value" => text || id}]
    }
  end

  defp assert_derives!(old, new) do
    assert {:ok, minted, ops} = Diff.derive(old, new)
    assert {:ok, replayed} = Patch.apply_patches(old, ops)
    assert replayed == minted
    {minted, ops}
  end

  describe "crafted cases" do
    test "equal documents derive zero ops" do
      blocks = [block("a"), block("b")]
      assert {:ok, ^blocks, []} = Diff.derive(blocks, blocks)
    end

    test "pure content edit is one replace-block" do
      old = [block("a"), block("b")]
      new = [block("a"), block("b", "edited")]
      {_minted, ops} = assert_derives!(old, new)
      assert [%{"op" => "replace-block", "id" => "b"}] = ops
    end

    test "removal, insertion, and reorder each derive their op" do
      old = [block("a"), block("b"), block("c")]

      {_m, ops} = assert_derives!(old, [block("a"), block("c")])
      assert [%{"op" => "remove-block", "id" => "b"}] = ops

      {_m, ops} = assert_derives!(old, [block("a"), block("x"), block("b"), block("c")])
      assert [%{"op" => "insert-after", "afterId" => "a", "block" => %{"id" => "x"}}] = ops

      {_m, ops} = assert_derives!(old, [block("c"), block("a"), block("b")])
      assert [%{"op" => "move-block", "id" => "c", "after" => nil}] = ops
    end

    test "a new head block appends then moves to the front" do
      old = [block("a")]
      {_m, ops} = assert_derives!(old, [block("x"), block("a")])

      assert [
               %{"op" => "append-block", "block" => %{"id" => "x"}},
               %{"op" => "move-block", "id" => "x", "after" => nil}
             ] = ops
    end

    test "id-less new blocks get minted, collision-free ids" do
      old = [block("a")]

      new = [
        block("a"),
        %{"type" => "paragraph", "content" => [%{"type" => "text", "value" => "fresh"}]}
      ]

      {minted, _ops} = assert_derives!(old, new)
      fresh = List.last(minted)
      assert is_binary(fresh["id"]) and fresh["id"] != ""
      assert fresh["id"] != "a"
    end

    test "a full rewrite (disjoint ids) still replays exactly" do
      old = [block("a"), block("b")]
      new = [block("x"), block("y"), block("z")]
      assert_derives!(old, new)
    end
  end

  describe "mutation storm" do
    test "200 random edit sequences all replay exactly" do
      :rand.seed(:exsss, {2026, 8, 14})

      for n <- 1..200 do
        old = Enum.map(1..Enum.random(0..8)//1, &block("s#{&1}"))
        new = mutate(old, Enum.random(1..5))

        case Diff.derive(old, new) do
          {:ok, minted, ops} ->
            assert {:ok, replayed} = Patch.apply_patches(old, ops)

            assert replayed == minted,
                   "storm case #{n} diverged\nold: #{inspect(old)}\nnew: #{inspect(new)}\nops: #{inspect(ops)}"

          {:error, reason} ->
            flunk(
              "storm case #{n} refused: #{inspect(reason)}\nold: #{inspect(old)}\nnew: #{inspect(new)}"
            )
        end
      end
    end
  end

  # A random sequence of the edits a working-copy user actually makes.
  defp mutate(blocks, 0), do: blocks

  defp mutate(blocks, n) do
    blocks =
      case Enum.random(1..5) do
        # edit a block's content
        1 when blocks != [] ->
          i = Enum.random(0..(length(blocks) - 1))

          List.update_at(
            blocks,
            i,
            &put_in(&1["content"], [%{"type" => "text", "value" => "edit#{n}"}])
          )

        # remove one
        2 when blocks != [] ->
          List.delete_at(blocks, Enum.random(0..(length(blocks) - 1)))

        # insert a new block (sometimes id-less)
        3 ->
          fresh =
            if Enum.random(1..3) == 1 do
              %{"type" => "paragraph", "content" => [%{"type" => "text", "value" => "new#{n}"}]}
            else
              block("n#{n}#{System.unique_integer([:positive])}")
            end

          List.insert_at(blocks, Enum.random(0..length(blocks)), fresh)

        # move one block elsewhere
        4 when length(blocks) > 1 ->
          i = Enum.random(0..(length(blocks) - 1))
          {b, rest} = List.pop_at(blocks, i)
          List.insert_at(rest, Enum.random(0..length(rest)), b)

        _ ->
          blocks
      end

    mutate(blocks, n - 1)
  end
end
