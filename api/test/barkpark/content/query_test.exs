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

  test "list_documents/3 clamps :offset option (min 0, max 100_000)" do
    for i <- 1..3 do
      doc!("q-off-#{i}", "Off #{i}")
    end

    # A negative offset is floored to 0 → the full page comes back, no Postgrex
    # "OFFSET must not be negative" error.
    results_neg = Query.list_documents(@type_name, @dataset, offset: -5)
    assert length(results_neg) == 3

    # A giant offset is capped at 100_000 — Postgres never walks/discards a
    # billion rows (a free DoS amplifier on the anon-reachable query endpoint),
    # and past the corpus the page is simply empty, no database error.
    results_giant = Query.list_documents(@type_name, @dataset, offset: 999_999_999_999)
    assert results_giant == []
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

  test "_createdAt / _updatedAt filter on the timestamp columns" do
    doc!("t1", "A")
    doc!("t2", "B")

    future = "2099-01-01T00:00:00Z"
    past = "2000-01-01T00:00:00Z"

    count = fn fm ->
      Query.count_documents(@type_name, @dataset, perspective: :raw, filter_map: fm)
    end

    # Both docs were created just now → all are < a far-future bound, none > it.
    # (Before the timestamp-column mapping these fell to the JSONB handler, which
    #  found no `content->>'_createdAt'` key and returned 0 — so `== 2` failed.)
    assert count.(%{"_createdAt" => %{"lt" => future}}) == 2
    assert count.(%{"_createdAt" => %{"gt" => future}}) == 0
    assert count.(%{"_createdAt" => %{"gt" => past}}) == 2

    # bare date (→ midnight UTC) parses without a time component
    assert count.(%{"_createdAt" => %{"lt" => "2099-01-01"}}) == 2

    # _updatedAt maps to the updated_at column
    assert count.(%{"_updatedAt" => %{"gt" => past}}) == 2

    # an unparseable date is a no-op (no raise, no filtering) → all rows
    assert count.(%{"_createdAt" => %{"gt" => "not-a-date"}}) == 2
  end

  test "pagination ordering is total — title ties are broken by the id PK" do
    ids = for i <- 1..5, do: "pg#{i}"
    # All five share the same title, so ordering by title is a total tie. Only the
    # id tiebreaker gives a total, repeatable order — without it the tie order is
    # whatever Postgres happens to pick, so LIMIT/OFFSET pages can skip/duplicate.
    for id <- ids, do: doc!(id, "SAME")

    full =
      Query.list_documents(@type_name, @dataset,
        perspective: :raw,
        order: {:field, "title", :asc},
        limit: 5,
        offset: 0
      )

    # With the tiebreaker the rows come back ALREADY sorted by the (random uuid)
    # id PK; re-sorting by id is then a no-op. Without it the tie order is
    # arbitrary, so re-sorting by id reorders them and this fails.
    assert Enum.map(full, & &1.doc_id) ==
             full |> Enum.sort_by(& &1.id) |> Enum.map(& &1.doc_id)

    # And the total order makes LIMIT/OFFSET partition the set — no skip, no dup.
    page = fn off ->
      Query.list_documents(@type_name, @dataset,
        perspective: :raw,
        order: {:field, "title", :asc},
        limit: 2,
        offset: off
      )
      |> Enum.map(& &1.doc_id)
    end

    seen = page.(0) ++ page.(2) ++ page.(4)
    assert Enum.sort(seen) == Enum.sort(ids)
    assert Enum.uniq(seen) == seen
  end

  test "drafts-perspective pagination ordering is total — title ties broken by id" do
    ids = for i <- 1..5, do: "dp#{i}"
    # The drafts-merged read takes a different code path (a DISTINCT subquery);
    # it had the same missing-tiebreaker gap as the linear path.
    for id <- ids, do: doc!(id, "SAME")

    full =
      Query.list_documents(@type_name, @dataset,
        perspective: :drafts,
        order: {:field, "title", :asc},
        limit: 5,
        offset: 0
      )

    # With the tiebreaker the rows come back already sorted by the (random uuid)
    # id PK; without it the tie order is arbitrary and re-sorting reorders them.
    assert Enum.map(full, & &1.doc_id) ==
             full |> Enum.sort_by(& &1.id) |> Enum.map(& &1.doc_id)
  end

  test "doc_id starts_with treats %, _ and a trailing backslash literally (no wildcard, no crash)" do
    # Each decoy differs from its hit ONLY where a raw LIKE metacharacter would
    # bleed: `_` (any one char) and `%` (any run) must match themselves, not act
    # as wildcards; a lone trailing `\` must not 500 ("LIKE pattern must not end
    # with escape character"). The doc_id column carries these ids verbatim.
    doc!("p%cent-hit", "pct")
    doc!("pXcent-miss", "pct")
    doc!("u_score-hit", "us")
    doc!("uZscore-miss", "us")
    doc!("bs\\end-hit", "bs")

    count = fn v ->
      Query.count_documents(@type_name, @dataset,
        perspective: :raw,
        filter_map: %{"doc_id" => %{"starts_with" => v}}
      )
    end

    # `%` is a literal — matches only "p%cent-hit", not "pXcent-miss"
    assert count.("p%cent") == 1
    # `_` is a literal — matches only "u_score-hit", not "uZscore-miss"
    assert count.("u_score") == 1
    # a lone trailing backslash escapes cleanly and matches literally (no crash)
    assert count.("bs\\") == 1

    # not_starts_with is the exact complement (5 rows total, 1 literal hit → 4)
    refute_starts = fn v ->
      Query.count_documents(@type_name, @dataset,
        perspective: :raw,
        filter_map: %{"doc_id" => %{"not_starts_with" => v}}
      )
    end

    assert refute_starts.("p%cent") == 4
  end
end
