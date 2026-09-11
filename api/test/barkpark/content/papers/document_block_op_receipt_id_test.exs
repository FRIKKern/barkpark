defmodule Barkpark.Content.Papers.DocumentBlockOpReceiptIdTest do
  use Barkpark.DataCase, async: false

  alias Barkpark.Content

  @dataset "production"
  @doc_type "beta_receipt_id_post"

  setup do
    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => @doc_type,
          "title" => "Beta receipt id post",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "body", "title" => "Body", "type" => "richText"}
          ],
          "layout" => [
            %{"kind" => "field", "name" => "title"},
            %{"kind" => "region", "name" => "body"}
          ]
        },
        @dataset
      )

    doc_id = "beta-receipt-id-#{System.unique_integer([:positive])}"

    {:ok, doc} =
      Content.create_document(
        @doc_type,
        %{"doc_id" => doc_id, "title" => "Original title"},
        @dataset
      )

    {:ok, doc: doc}
  end

  defp stored_block_ids(doc_id) do
    {:ok, doc} = Content.get_document(doc_id, @doc_type, @dataset)
    blocks = get_in(doc.content || %{}, ["blocks"]) || []
    Enum.map(blocks, &Map.get(&1, "id"))
  end

  test "an id-less append on a DOCUMENT reports the block id it persisted", %{doc: doc} do
    op = %{"op" => "append-block", "block" => %{"type" => "paragraph", "text" => "appended"}}

    {:ok, receipt} = Content.apply_document_block_op(doc.doc_id, @doc_type, op, @dataset)

    block_id = receipt.block_id
    ids = stored_block_ids(doc.doc_id)

    # CONTROL: the write really landed the appended block with a minted id, so a
    # nil receipt id is a WITHHELD id, not an absent block.
    last_stored = List.last(ids)
    assert is_binary(last_stored) and last_stored != ""

    assert block_id == last_stored
    assert is_binary(block_id) and block_id != ""
    assert Map.get(receipt.block, "id") == last_stored
  end

  test "an id-less insert-after on a DOCUMENT reports the block id it persisted", %{doc: doc} do
    seed = %{
      "op" => "append-block",
      "block" => %{"id" => "anchor", "type" => "paragraph", "text" => "anchor"}
    }

    {:ok, _} = Content.apply_document_block_op(doc.doc_id, @doc_type, seed, @dataset)

    op = %{
      "op" => "insert-after",
      "afterId" => "anchor",
      "block" => %{"type" => "paragraph", "text" => "inserted"}
    }

    {:ok, receipt} = Content.apply_document_block_op(doc.doc_id, @doc_type, op, @dataset)

    block_id = receipt.block_id
    ids = stored_block_ids(doc.doc_id)

    anchor_idx = Enum.find_index(ids, &(&1 == "anchor"))
    assert is_integer(anchor_idx)
    inserted_stored = Enum.at(ids, anchor_idx + 1)
    assert is_binary(inserted_stored) and inserted_stored != ""

    assert block_id == inserted_stored
    assert is_binary(block_id) and block_id != ""
    assert receipt.position == anchor_idx + 1
  end

  # The filing's LOWER-CONFIDENCE second concern, MEASURED rather than reasoned.
  # It feared the hoist changes WHEN positional ids are minted, so an id-less
  # append (minting `block-N`) followed by an append carrying the LITERAL id
  # `block-N` would newly refuse as duplicate_id where it used to succeed. This
  # test reads the minted id out of STORAGE, never out of the receipt, so it runs
  # identically with and without the hoist — and it returns the same
  # `{:error, {:duplicate_id, ...}}` on both sides. The concern does not apply to
  # this surface: the document path persists one op at a time through
  # `upsert_document`, whose own chokepoint had ALREADY minted that positional id
  # into storage before the second op was lowered. The hoist changes the receipt,
  # not the stored list the next op is validated against.
  test "an append of a previously minted literal id refuses identically with and without the hoist",
       %{doc: doc} do
    first = %{"op" => "append-block", "block" => %{"type" => "paragraph", "text" => "first"}}

    {:ok, _first_receipt} =
      Content.apply_document_block_op(doc.doc_id, @doc_type, first, @dataset)

    minted = List.last(stored_block_ids(doc.doc_id))
    assert is_binary(minted) and minted != ""

    second = %{
      "op" => "append-block",
      "block" => %{"id" => minted, "type" => "paragraph", "text" => "second"}
    }

    result = Content.apply_document_block_op(doc.doc_id, @doc_type, second, @dataset)
    assert result == {:error, {:duplicate_id, minted, "append-block"}}
  end
end
