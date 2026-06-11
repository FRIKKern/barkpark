defmodule BarkparkWeb.BulldocsLiveIdlessBlocksTest do
  @moduledoc """
  Regression for e2e residual R2: a paper ingested with blocks that lack an
  "id" rendered ONLY the LAST block in the live LiveView, because the stream
  keyed every id-less block on the same constant DOM id (`blocks-`) and
  Phoenix's stream dedupes on it.

  Two-pronged proof:

    * Option A (ingest) — `Content.upsert_paper/1` assigns a UNIQUE positional
      id to every stored block that lacked one, so the persisted block list has
      N blocks with N distinct, non-blank ids.
    * Option B (render) — the live `/papers/:slug` stream renders ALL blocks,
      not just the last.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  defp seed_idless_paper(slug, blocks) do
    {:ok, paper} = Content.upsert_paper(%{slug: slug, blocks: blocks, style: "article"})
    paper
  end

  describe "id-less blocks (R2)" do
    test "ingest assigns a unique id to every id-less block (Option A)" do
      slug = "r2-idless-store-#{System.unique_integer([:positive])}"

      blocks = [
        %{"type" => "heading", "level" => 1, "text" => "Heading line"},
        %{"type" => "paragraph", "text" => "First paragraph"},
        %{"type" => "paragraph", "text" => "Second paragraph"}
      ]

      seed_idless_paper(slug, blocks)

      stored = Content.paper_blocks(slug)
      assert is_list(stored)
      assert length(stored) == 3

      ids = Enum.map(stored, &Map.get(&1, "id"))

      assert Enum.all?(ids, &(is_binary(&1) and &1 != "")),
             "every stored block must carry a non-blank id"

      assert Enum.uniq(ids) == ids, "stored block ids must be unique, got: #{inspect(ids)}"
    end

    test "an author/op-supplied block id is preserved (DocPatchOp stability)" do
      slug = "r2-idless-mixed-#{System.unique_integer([:positive])}"

      blocks = [
        %{"type" => "heading", "level" => 1, "text" => "Has id", "id" => "keepme"},
        %{"type" => "paragraph", "text" => "No id here"}
      ]

      seed_idless_paper(slug, blocks)

      stored = Content.paper_blocks(slug)
      [first, second] = stored

      # The supplied id survives byte-identical so ops addressing "keepme" still resolve.
      assert Map.get(first, "id") == "keepme"
      # The id-less block got a distinct, non-blank fallback id.
      assert is_binary(Map.get(second, "id")) and Map.get(second, "id") != ""
      assert Map.get(second, "id") != "keepme"
    end

    test "an assigned id is addressable by a DocPatchOp (block-addressing stays stable)" do
      slug = "r2-idless-ops-#{System.unique_integer([:positive])}"

      blocks = [
        %{"type" => "heading", "level" => 1, "text" => "Heading"},
        %{"type" => "paragraph", "text" => "Target me"}
      ]

      seed_idless_paper(slug, blocks)

      # The second (id-less) block was assigned a positional id at ingest.
      [_h, para] = Content.paper_blocks(slug)
      assigned_id = Map.get(para, "id")
      assert is_binary(assigned_id) and assigned_id != ""

      # A patch-block op targeting the ASSIGNED id must resolve (not block_not_found),
      # proving ops still address ingest-assigned blocks.
      patch = %{"op" => "patch-block", "id" => assigned_id, "patch" => %{"text" => "Patched"}}
      assert {:ok, result} = Content.apply_paper_block_op(slug, patch)
      assert result.block_id == assigned_id

      # And a re-ingest of the SAME structure keeps the positional ids stable.
      seed_idless_paper(slug, blocks)
      assert Enum.map(Content.paper_blocks(slug), &Map.get(&1, "id")) == ["block-0", "block-1"]
    end

    test "the live /papers/:slug stream renders ALL id-less blocks (Option B)", %{conn: conn} do
      slug = "r2-idless-render-#{System.unique_integer([:positive])}"

      # Paragraph text lives in the `content` inline-node array (render.ex
      # compose_block(paragraph) reads "content", NOT a bare "text"). The
      # heading reads "text". None carry an "id" — the exact R2 shape.
      blocks = [
        %{"type" => "heading", "level" => 1, "text" => "Heading line"},
        %{
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "First paragraph"}]
        },
        %{
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "Second paragraph"}]
        }
      ]

      seed_idless_paper(slug, blocks)

      {:ok, view, _dead_html} = live(conn, "/papers/#{slug}")

      # Assert on the CONNECTED render — the static/dead render of a
      # Phoenix stream is not the source of truth (it omits interior stream
      # items), so we mirror what a real browser sees (connected socket).
      # Before the fix only "Second paragraph" (the last block) survived,
      # because all id-less blocks collapsed to the constant `paper_blocks-`
      # DOM id and the stream dedupes on it.
      rendered = render(view)

      assert rendered =~ "Heading line"
      assert rendered =~ "First paragraph"
      assert rendered =~ "Second paragraph"

      # Each block streams under its OWN distinct DOM id — the dedup that
      # collapsed every id-less block onto the constant `blocks-` id is gone.
      assert rendered =~ ~s(data-block-id="block-0")
      assert rendered =~ ~s(data-block-id="block-1")
      assert rendered =~ ~s(data-block-id="block-2")
    end
  end
end
