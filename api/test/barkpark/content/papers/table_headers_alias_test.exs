defmodule Barkpark.Content.Papers.TableHeadersAliasTest do
  @moduledoc """
  The `headers` (PLURAL) table-head spelling, and the block IDs the publish
  wall now names — task-50ea16eb76c8f5c9.

  THE CORPUS SHAPE, LIFTED VERBATIM. The row's own repro paper
  `pds-wave-35-2026-08-01` stores twelve table blocks, and every one of them
  keys its header row under `headers`:

      {"headers": [{"content": [{"type": "text", "value": "quantity"}]}, …],
       "id": "b12", "rows": [[…]], "type": "table"}

  `headers` was a spelling exactly ONE reader knew. The Bulldocs BPML printer
  has always accepted it (`printer.ex` — `alias_get(b, ["head", "header",
  "headers", "columns"])`), so the BPML export printed a header row. Nothing
  else did:

    * `compose.ex` resolves `head`, then `header`, then `columns`, then a
      legacy header ROW — never `headers`. The authored header row rendered as
      NOTHING, silently, behind a 200.
    * `render_block_errors/2` reads `head || header`, so no `headers` cell was
      ever validated: an unrenderable cell in one published clean and the wall
      named no path because it never looked.
    * `normalize_table_leaves/1` and `normalize_array_table/2` both key on
      `head`, so neither the TipTap text-keyed leaf rescue nor the bare-string
      cell rescue reached a `headers` cell.

  That is the row's "read-back is LOSSY" complaint at its own bisected block:
  `bp doc get` hands back a key the write path cannot round-trip into anything
  a reader renders. The fix canonicalizes the key ONCE at the write chokepoint,
  so all three surfaces inherit the dialect.

  ON THE ROW'S SECOND FIX ("make the wall NAME the offending block paths"):
  the server side of that was already true when the row was filed — the
  `blocks` messages carry a positional path (`blocks[0].rows[0].cells[1] has
  no renderable inline content`), and the CLI's loss of the `details` payload
  was repaired by #8809 (2026-08-01) and #13314 (2026-08-23). What was still
  missing is the token the reporter actually had to BISECT a 105-block Paper
  to recover: the authored block ID. `details.block_ids` now carries it.
  """

  use ExUnit.Case, async: true

  alias Barkpark.Content.Papers.BlockOps
  alias Barkpark.PortableDoc.Render

  # `pds-wave-35-2026-08-01` block `b12`, trimmed to two columns.
  @corpus_block %{
    "type" => "table",
    "id" => "b12",
    "headers" => [
      %{"content" => [%{"type" => "text", "value" => "quantity"}]},
      %{"content" => [%{"type" => "text", "value" => "verdict"}]}
    ],
    "rows" => [
      [
        [%{"type" => "text", "value" => "UNCLASSIFIED"}],
        [%{"type" => "text", "value" => "BOTH WRONG"}]
      ]
    ]
  }

  describe "the `headers` spelling reaches the readers" do
    test "the corpus header row RENDERS after normalization and did not before" do
      raw_html = Render.render_blocks([@corpus_block])
      normalized_html = Render.render_blocks(BlockOps.normalize_render_shapes([@corpus_block]))

      # non-vacuity: the BODY row renders in both, so a missing header is not
      # a "the whole block failed" artifact.
      assert raw_html =~ "UNCLASSIFIED"
      assert normalized_html =~ "UNCLASSIFIED"

      refute raw_html =~ "quantity"
      assert normalized_html =~ "quantity"
      assert normalized_html =~ "verdict"
    end

    test "the key is canonicalized to `head`, cell bytes untouched" do
      assert [block] = BlockOps.normalize_render_shapes([@corpus_block])

      refute Map.has_key?(block, "headers")

      assert block["head"] == [
               [%{"type" => "text", "value" => "quantity"}],
               [%{"type" => "text", "value" => "verdict"}]
             ]

      assert block["id"] == "b12"
    end

    test "the corpus block round-trips: read shape in, publish gate says :ok" do
      normalized = BlockOps.normalize_render_shapes([@corpus_block])
      assert BlockOps.validate_render_shapes(normalized) == :ok
    end

    test "the canonicalization is idempotent" do
      once = BlockOps.normalize_render_shapes([@corpus_block])
      assert BlockOps.normalize_render_shapes(once) == once
    end

    test "a text-keyed leaf inside `headers` inherits the inline-leaf rescue" do
      block = %{
        "type" => "table",
        "headers" => [[%{"type" => "text", "text" => "Quantity"}]],
        "rows" => [[[%{"type" => "text", "value" => "51"}]]]
      }

      assert [normalized] = blocks = BlockOps.normalize_render_shapes([block])
      assert normalized["head"] == [[%{"type" => "text", "value" => "Quantity"}]]
      assert BlockOps.validate_render_shapes(blocks) == :ok
      assert Render.render_blocks(blocks) =~ "Quantity"
    end

    test "a bare-string `headers` cell inherits the head cell rescue" do
      block = %{"type" => "table", "headers" => ["Name", "Age"], "rows" => [[["a", "1"]]]}

      assert [normalized] = blocks = BlockOps.normalize_render_shapes([block])

      assert normalized["head"] == [
               [%{"type" => "text", "value" => "Name"}],
               [%{"type" => "text", "value" => "Age"}]
             ]

      assert BlockOps.validate_render_shapes(blocks) == :ok
    end

    test "an unrenderable `headers` cell is now REFUSED with its path, not silently dropped" do
      block = %{
        "type" => "table",
        "id" => "b12",
        "headers" => [%{"no" => "content"}],
        "rows" => [[[%{"type" => "text", "value" => "a"}]]]
      }

      blocks = BlockOps.normalize_render_shapes([block])

      assert {:error, {:invalid_paper_structure, %{"blocks" => errors}}} =
               BlockOps.validate_render_shapes(blocks)

      assert errors == ["blocks[0].head.cells[0] has no renderable inline content"]
    end

    test "a block that already declares a non-empty `head` keeps `headers` verbatim" do
      block = %{
        "type" => "table",
        "head" => [[%{"type" => "text", "value" => "real head"}]],
        "headers" => [[%{"type" => "text", "value" => "shadowed"}]],
        "rows" => [[[%{"type" => "text", "value" => "a"}]]]
      }

      assert [normalized] = BlockOps.normalize_render_shapes([block])

      assert normalized["head"] == [[%{"type" => "text", "value" => "real head"}]]
      assert normalized["headers"] == [[%{"type" => "text", "value" => "shadowed"}]]
    end

    test "an empty `headers` is left alone (no phantom head key)" do
      block = %{"type" => "table", "headers" => [], "rows" => [[["a"]]]}

      assert [normalized] = BlockOps.normalize_render_shapes([block])
      refute Map.has_key?(normalized, "head")
      assert normalized["headers"] == []
    end
  end

  describe "the wall names the offending block by its authored id" do
    test "details.block_ids carries the ids the author greps for" do
      blocks = [
        %{"type" => "paragraph", "id" => "b0", "content" => []},
        %{"type" => "list", "id" => "b12", "items" => [%{"label" => "stranded prose"}]}
      ]

      assert {:error, {:invalid_paper_structure, details}} =
               BlockOps.validate_render_shapes(blocks)

      assert details["blocks"] == ["blocks[1].items[0] has no renderable inline content"]
      assert details["block_ids"] == ["b12"]
    end

    test "each offending block is named once, in first-refusal order" do
      blocks = [
        %{"type" => "list", "id" => "alpha", "items" => [%{"label" => "x"}, %{"label" => "y"}]},
        %{"type" => "paragraph", "id" => "fine", "content" => []},
        %{"type" => "list", "id" => "omega", "items" => [%{"label" => "z"}]}
      ]

      assert {:error, {:invalid_paper_structure, details}} =
               BlockOps.validate_render_shapes(blocks)

      assert length(details["blocks"]) == 3
      assert details["block_ids"] == ["alpha", "omega"]
    end

    test "an id-less block list stays byte-identical — the key is omitted, never empty" do
      blocks = [%{"type" => "list", "items" => [%{"label" => "stranded prose"}]}]

      assert {:error, {:invalid_paper_structure, details}} =
               BlockOps.validate_render_shapes(blocks)

      assert details == %{
               "blocks" => ["blocks[0].items[0] has no renderable inline content"]
             }
    end

    test "the non-list refusal is unchanged" do
      assert {:error, {:invalid_paper_structure, details}} =
               BlockOps.validate_render_shapes("not a list")

      assert details == %{
               "blocks" => ["must be an array when a Paper declares a block body"]
             }
    end
  end
end
