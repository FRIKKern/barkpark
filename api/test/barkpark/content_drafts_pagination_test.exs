defmodule Barkpark.ContentDraftsPaginationTest do
  use Barkpark.DataCase, async: true
  alias Barkpark.Content

  setup do
    Content.upsert_schema(
      %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
      "dp"
    )

    for i <- 1..10 do
      {:ok, _} =
        Content.create_document(
          "post",
          %{"_id" => "dp-#{i}", "title" => "Doc #{i}"},
          "dp"
        )
    end

    for i <- [1, 3, 5, 7, 9] do
      {:ok, _} = Content.publish_document("dp-#{i}", "post", "dp")
    end

    for i <- [1, 3, 5, 7, 9] do
      {:ok, _} =
        Content.upsert_document("post", %{"_id" => "dp-#{i}", "title" => "Doc #{i} (edited)"}, "dp")
    end

    :ok
  end

  test "drafts perspective with limit=5 returns exactly 5 rows" do
    docs =
      Content.list_documents("post", "dp", perspective: :drafts, limit: 5)

    assert length(docs) == 5
  end

  test "drafts perspective with limit=100 returns 10 merged rows (not 15)" do
    docs =
      Content.list_documents("post", "dp", perspective: :drafts, limit: 100)

    ids = Enum.map(docs, & Content.published_id(&1.doc_id)) |> Enum.sort()
    assert length(docs) == 10
    assert ids == Enum.sort(Enum.map(1..10, &"dp-#{&1}"))
  end

  test "drafts perspective honors user-provided order_by across the merge" do
    docs =
      Content.list_documents("post", "dp",
        perspective: :drafts,
        limit: 10,
        order: :created_at_asc
      )

    # Even-numbered docs (2,4,6,8,10) were never published, so their draft
    # rows have the oldest inserted_at (from create_document in setup).
    # Odd-numbered docs were published then re-drafted, so their winning draft
    # rows have the newest inserted_at. With created_at_asc, evens come first.
    assert length(docs) == 10

    ids = Enum.map(docs, &Content.published_id(&1.doc_id))
    first_id = hd(ids)
    last_id = List.last(ids)

    # The first row must be an even-numbered doc (oldest timestamps)
    assert first_id in ~w(dp-2 dp-4 dp-6 dp-8 dp-10)
    # The last row must be an odd-numbered doc (newest timestamps — re-drafted after publish)
    assert last_id in ~w(dp-1 dp-3 dp-5 dp-7 dp-9)
    # Order is monotonically non-decreasing by inserted_at
    inserted_ats = Enum.map(docs, & &1.inserted_at)
    assert inserted_ats == Enum.sort(inserted_ats)
  end
end
