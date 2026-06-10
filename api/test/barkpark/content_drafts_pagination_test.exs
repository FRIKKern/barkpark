defmodule Barkpark.ContentDraftsPaginationTest do
  use Barkpark.DataCase, async: true
  alias Barkpark.Content
  alias Barkpark.Content.Document

  # Deterministic timestamp base for the order_by test. Setup used to rely on
  # wall-clock `inserted_at` autogeneration, which flaked two ways on CI:
  #   1. ties — rows inserted in the same microsecond order arbitrarily;
  #   2. the old `Enum.sort(inserted_ats)` was STRUCTURAL term order, which
  #      compares DateTime's :microsecond field before :second/:minute, so a
  #      setup run straddling a second boundary with descending microseconds
  #      sorted "later" before "earlier" and failed the monotonicity assert.
  # We now pin distinct, explicit timestamps (no sleeps) and compare with the
  # DateTime comparator. Same discipline as the CompactorTest de-flake.
  @t0 ~U[2026-01-01 12:00:00.000000Z]

  defp pin_inserted_at!(doc_id, ts) do
    {1, _} =
      Repo.update_all(
        from(d in Document, where: d.doc_id == ^doc_id and d.dataset == "dp"),
        set: [inserted_at: ts]
      )
  end

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
        Content.upsert_document(
          "post",
          %{"_id" => "dp-#{i}", "title" => "Doc #{i} (edited)"},
          "dp"
        )
    end

    # Pin explicit, distinct inserted_at values on the rows the drafts merge
    # will surface (the winning draft row per published id). Evens (never
    # published) get the oldest stamps; odds (published then re-drafted) get
    # the newest — the same shape wall-clock autogeneration produced, minus
    # the ties and second-boundary nondeterminism.
    for {i, idx} <- Enum.with_index([2, 4, 6, 8, 10]) do
      pin_inserted_at!("drafts.dp-#{i}", DateTime.add(@t0, idx, :second))
    end

    for {i, idx} <- Enum.with_index([1, 3, 5, 7, 9]) do
      pin_inserted_at!("drafts.dp-#{i}", DateTime.add(@t0, 100 + idx, :second))
    end

    :ok
  end

  test "drafts perspective with limit=5 returns exactly 5 rows" do
    docs = Content.list_documents("post", "dp", perspective: :drafts, limit: 5)

    assert length(docs) == 5
  end

  test "drafts perspective with limit=100 returns 10 merged rows (not 15)" do
    docs = Content.list_documents("post", "dp", perspective: :drafts, limit: 100)

    ids = Enum.map(docs, &Content.published_id(&1.doc_id)) |> Enum.sort()
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

    # Even-numbered docs (2,4,6,8,10) were never published; their draft rows
    # carry the oldest (pinned) inserted_at. Odd-numbered docs were published
    # then re-drafted; their winning draft rows carry the newest. With
    # created_at_asc the timestamps are pinned and distinct, so the FULL order
    # is deterministic — assert it exactly.
    assert length(docs) == 10

    ids = Enum.map(docs, &Content.published_id(&1.doc_id))
    assert ids == ~w(dp-2 dp-4 dp-6 dp-8 dp-10 dp-1 dp-3 dp-5 dp-7 dp-9)

    # Order is monotonically non-decreasing by inserted_at — CHRONOLOGICAL
    # comparison (Enum.sort/2 with the DateTime module), never structural
    # Enum.sort/1, which orders by the :microsecond field before :second.
    inserted_ats = Enum.map(docs, & &1.inserted_at)
    assert inserted_ats == Enum.sort(inserted_ats, DateTime)
  end
end
