defmodule Barkpark.Content.QueryTest do
  @moduledoc """
  Direct unit tests for `Barkpark.Content.Query` — the heavy read surface
  extracted from the Content facade.

  Covers:
  - Pure guard clauses that short-circuit before hitting the DB
    (`get_document/4` with nil args, `get_documents_by_ids/3` with [],
    `search_documents_by_title/5` with blank query)
  - `list_documents/3` limit/offset boundary opts (clamps to 1..1000)
  - `search_documents_by_title/5` real title-substring match + limit_n cap
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.Query

  @dataset "query_unit_test"
  @type_name "qpost"

  setup do
    Content.upsert_schema(
      %{"name" => @type_name, "title" => "QPost", "visibility" => "public", "fields" => []},
      @dataset
    )

    :ok
  end

  defp doc!(id, title) do
    {:ok, _} =
      Content.create_document(
        @type_name,
        %{"_id" => id, "title" => title},
        @dataset
      )

    {:ok, doc} = Content.publish_document(id, @type_name, @dataset)
    doc
  end

  # ── Pure guard clauses (no DB) ──────────────────────────────────────────────

  test "get_document/4 returns {:error, :not_found} when doc_id is nil" do
    assert {:error, :not_found} = Query.get_document(nil, @type_name, @dataset)
  end

  test "get_document/4 returns {:error, :not_found} when type is nil" do
    assert {:error, :not_found} = Query.get_document("some-id", nil, @dataset)
  end

  test "get_document/4 returns {:error, :not_found} when dataset is nil" do
    assert {:error, :not_found} = Query.get_document("some-id", @type_name, nil)
  end

  test "get_documents_by_ids/3 returns %{} immediately for an empty list" do
    assert %{} = Query.get_documents_by_ids([], @dataset, [])
  end

  test "search_documents_by_title/5 returns [] for a blank query" do
    doc!("q-blank-1", "Relevant Doc")
    assert [] = Query.search_documents_by_title("", @type_name, @dataset)
    assert [] = Query.search_documents_by_title("   ", @type_name, @dataset)
  end

  # ── DB-backed paths ─────────────────────────────────────────────────────────

  test "search_documents_by_title/5 returns case-insensitive substring matches, title-ordered" do
    doc!("q-alpha", "Alpha Intro")
    doc!("q-beta", "Beta intro Guide")
    doc!("q-gamma", "Gamma Unrelated")

    results = Query.search_documents_by_title("intro", @type_name, @dataset)
    titles = Enum.map(results, & &1.title)

    assert "Alpha Intro" in titles
    assert "Beta intro Guide" in titles
    refute "Gamma Unrelated" in titles
    # title-ordered (asc)
    assert titles == Enum.sort(titles)
  end

  test "search_documents_by_title/5 respects limit_n cap" do
    for i <- 1..5 do
      doc!("q-limit-#{i}", "Limit Test #{i}")
    end

    results = Query.search_documents_by_title("Limit Test", @type_name, @dataset, [], 3)
    assert length(results) == 3
  end

  test "list_documents/3 clamps :limit option (min 1, max 1000)" do
    for i <- 1..3 do
      doc!("q-clamp-#{i}", "Clamp #{i}")
    end

    # limit 0 is clamped to 1
    results_min = Query.list_documents(@type_name, @dataset, limit: 0)
    assert length(results_min) == 1

    # limit 9999 is clamped to 1000 (only 3 docs exist, so we get 3)
    results_max = Query.list_documents(@type_name, @dataset, limit: 9999)
    assert length(results_max) == 3
  end

  test "count_documents counts the typed/filtered set across every perspective" do
    doc!("c1", "A")
    doc!("c2", "B")
    doc!("c3", "A")

    # raw / published / drafts (the merge-count subquery) all run and agree here
    assert Query.count_documents(@type_name, @dataset, perspective: :raw) == 3
    assert Query.count_documents(@type_name, @dataset, perspective: :published) == 3
    assert Query.count_documents(@type_name, @dataset, perspective: :drafts) == 3

    # honours the filter, ignores limit/offset
    assert Query.count_documents(@type_name, @dataset,
             perspective: :raw,
             filter_map: %{"title" => "A"}
           ) == 2
  end
end
