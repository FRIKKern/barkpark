defmodule Barkpark.ContentFilterOpsTest do
  use Barkpark.DataCase, async: true
  alias Barkpark.Content

  setup do
    Content.upsert_schema(
      %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
      "fops"
    )

    for {id, title, status, count} <- [
          {"fo-1", "Alpha", "published", 3},
          {"fo-2", "Beta", "draft", 5},
          {"fo-3", "Gamma", "published", 7},
          {"fo-4", "Delta", "draft", 2}
        ] do
      {:ok, _} =
        Content.create_document(
          "post",
          %{"_id" => id, "title" => title, "status" => status, "count" => to_string(count)},
          "fops"
        )

      {:ok, _} = Content.publish_document(id, "post", "fops")
    end

    :ok
  end

  test "eq operator matches exact value" do
    docs =
      Content.list_documents("post", "fops",
        perspective: :published,
        filter_map: %{"title" => %{"eq" => "Alpha"}}
      )

    assert length(docs) == 1
    assert hd(docs).title == "Alpha"
  end

  test "in operator matches any value in the list" do
    docs =
      Content.list_documents("post", "fops",
        perspective: :published,
        filter_map: %{"title" => %{"in" => ["Alpha", "Gamma"]}}
      )

    titles = Enum.map(docs, & &1.title) |> Enum.sort()
    assert titles == ["Alpha", "Gamma"]
  end

  test "contains operator matches substring on top-level fields" do
    docs =
      Content.list_documents("post", "fops",
        perspective: :published,
        filter_map: %{"title" => %{"contains" => "a"}}
      )

    # Alpha, Beta, Gamma, Delta all contain "a" (case-insensitive via ILIKE)
    titles = Enum.map(docs, & &1.title) |> Enum.sort()
    assert titles == ["Alpha", "Beta", "Delta", "Gamma"]
  end

  test "gte/lte operators match on content fields stringly" do
    # Content fields are stored as strings in JSONB, so lexicographic.
    docs =
      Content.list_documents("post", "fops",
        perspective: :published,
        filter_map: %{"count" => %{"gte" => "5"}}
      )

    counts = Enum.map(docs, fn d -> d.content["count"] end) |> Enum.sort()
    assert counts == ["5", "7"]
  end

  test "gt/lt compare numerically on JSON-number fields (multi-digit, not lexical)" do
    # Stored as real JSON numbers (not to_string), with multi-digit values a
    # lexical compare gets WRONG: "10" > "5" is false, "100" < "20" is true.
    for {id, rank} <- [{"num-2", 2}, {"num-10", 10}, {"num-100", 100}] do
      {:ok, _} =
        Content.create_document("post", %{"_id" => id, "title" => id, "rank" => rank}, "fops")

      {:ok, _} = Content.publish_document(id, "post", "fops")
    end

    gt5 =
      Content.list_documents("post", "fops",
        perspective: :published,
        filter_map: %{"rank" => %{"gt" => "5"}}
      )
      |> Enum.map(& &1.content["rank"])
      |> Enum.sort()

    # numeric: 10 and 100 are > 5; 2 is not. (Lexically "10"/"100" would be excluded.)
    assert gt5 == [10, 100]

    lt20 =
      Content.list_documents("post", "fops",
        perspective: :published,
        filter_map: %{"rank" => %{"lt" => "20"}}
      )
      |> Enum.map(& &1.content["rank"])
      |> Enum.sort()

    # numeric: 2 and 10 are < 20; 100 is not. (Lexically "100" < "20" is TRUE — the bug.)
    assert lt20 == [2, 10]
  end

  test "order by a numeric content field sorts numerically, not lexically" do
    for {id, rank} <- [{"ord-2", 2}, {"ord-10", 10}, {"ord-100", 100}] do
      {:ok, _} =
        Content.create_document("post", %{"_id" => id, "title" => id, "rank" => rank}, "fops")

      {:ok, _} = Content.publish_document(id, "post", "fops")
    end

    only_ords = %{"title" => %{"in" => ["ord-2", "ord-10", "ord-100"]}}

    asc =
      Content.list_documents("post", "fops",
        perspective: :published,
        filter_map: only_ords,
        order: {:field, "rank", :asc}
      )
      |> Enum.map(& &1.content["rank"])

    # numeric asc: 2, 10, 100. (Lexically it would be "10","100","2".)
    assert asc == [2, 10, 100]

    desc =
      Content.list_documents("post", "fops",
        perspective: :published,
        filter_map: only_ords,
        order: {:field, "rank", :desc}
      )
      |> Enum.map(& &1.content["rank"])

    assert desc == [100, 10, 2]
  end

  test "order by a nested numeric path sorts numerically" do
    # Inserted scrambled so the numeric sort is distinguishable from insertion order.
    for {id, score} <- [{"os-10", 10}, {"os-2", 2}, {"os-100", 100}] do
      {:ok, _} =
        Content.create_document(
          "post",
          %{"_id" => id, "title" => id, "meta" => %{"score" => score}},
          "fops"
        )

      {:ok, _} = Content.publish_document(id, "post", "fops")
    end

    asc =
      Content.list_documents("post", "fops",
        perspective: :published,
        filter_map: %{"title" => %{"in" => ["os-10", "os-2", "os-100"]}},
        order: {:field, "meta.score", :asc}
      )
      |> Enum.map(& &1.content["meta"]["score"])

    # Before, ordering looked up a literal key "meta.score" → all NULL → no
    # effective order. Now it descends and sorts numerically.
    assert asc == [2, 10, 100]
  end

  test "range ops descend into nested dot-paths (and stay numeric)" do
    for {id, score} <- [{"n-2", 2}, {"n-10", 10}, {"n-100", 100}] do
      {:ok, _} =
        Content.create_document(
          "post",
          %{"_id" => id, "title" => id, "meta" => %{"score" => score}},
          "fops"
        )

      {:ok, _} = Content.publish_document(id, "post", "fops")
    end

    gt5 =
      Content.list_documents("post", "fops",
        perspective: :published,
        filter_map: %{"meta.score" => %{"gt" => "5"}}
      )
      |> Enum.map(& &1.content["meta"]["score"])
      |> Enum.sort()

    # Nested numeric: 10 and 100 > 5; 2 not. Before, the range op looked up a
    # literal key "meta.score" → NULL → it silently matched nothing.
    assert gt5 == [10, 100]
  end

  test "contains and has descend into nested dot-paths" do
    {:ok, _} =
      Content.create_document(
        "post",
        %{
          "_id" => "nest-1",
          "title" => "nest-1",
          "meta" => %{"title" => "Hello World", "tags" => ["alpha", "beta"]}
        },
        "fops"
      )

    {:ok, _} = Content.publish_document("nest-1", "post", "fops")

    {:ok, _} =
      Content.create_document(
        "post",
        %{
          "_id" => "nest-2",
          "title" => "nest-2",
          "meta" => %{"title" => "Goodbye", "tags" => ["gamma"]}
        },
        "fops"
      )

    {:ok, _} = Content.publish_document("nest-2", "post", "fops")

    # contains on a nested string path (was: literal-key miss → no match)
    contains =
      Content.list_documents("post", "fops",
        perspective: :published,
        filter_map: %{"meta.title" => %{"contains" => "world"}}
      )
      |> Enum.map(& &1.title)

    assert contains == ["nest-1"]

    # has on a nested array path (was: literal-key miss → not an array → no match)
    has =
      Content.list_documents("post", "fops",
        perspective: :published,
        filter_map: %{"meta.tags" => %{"has" => "beta"}}
      )
      |> Enum.map(& &1.title)

    assert has == ["nest-1"]
  end

  test "contains escapes LIKE wildcards (% and _ are treated as literals)" do
    for {id, title} <- [
          {"w-1", "50% off"},
          {"w-2", "5000 items"},
          {"w-3", "a_c"},
          {"w-4", "abc"}
        ] do
      {:ok, _} = Content.create_document("post", %{"_id" => id, "title" => title}, "fops")
      {:ok, _} = Content.publish_document(id, "post", "fops")
    end

    # `50%` matches only the literal "50% off", NOT "5000 items" (% is not a wildcard).
    pct =
      Content.list_documents("post", "fops",
        perspective: :published,
        filter_map: %{"title" => %{"contains" => "50%"}}
      )
      |> Enum.map(& &1.title)

    assert pct == ["50% off"]

    # `a_c` matches only the literal "a_c", NOT "abc" (_ is not a single-char wildcard).
    under =
      Content.list_documents("post", "fops",
        perspective: :published,
        filter_map: %{"title" => %{"contains" => "a_c"}}
      )
      |> Enum.map(& &1.title)

    assert under == ["a_c"]
  end

  test "is null / is notnull match absent+null vs present (eq/neq null from the SDK)" do
    {:ok, _} =
      Content.create_document(
        "post",
        %{"_id" => "has-cat", "title" => "has-cat", "category" => "tech"},
        "fops"
      )

    {:ok, _} =
      Content.create_document(
        "post",
        %{"_id" => "null-cat", "title" => "null-cat", "category" => nil},
        "fops"
      )

    # absent: no "category" key at all
    {:ok, _} =
      Content.create_document("post", %{"_id" => "no-cat", "title" => "no-cat"}, "fops")

    for id <- ["has-cat", "null-cat", "no-cat"], do: Content.publish_document(id, "post", "fops")

    only = %{"title" => %{"in" => ["has-cat", "null-cat", "no-cat"]}}

    is_null =
      Content.list_documents("post", "fops",
        perspective: :published,
        filter_map: Map.merge(only, %{"category" => %{"is" => "null"}})
      )
      |> Enum.map(& &1.title)
      |> Enum.sort()

    # both the explicit-null and the absent doc; NOT the one with "tech"
    assert is_null == ["no-cat", "null-cat"]

    is_notnull =
      Content.list_documents("post", "fops",
        perspective: :published,
        filter_map: Map.merge(only, %{"category" => %{"is" => "notnull"}})
      )
      |> Enum.map(& &1.title)

    assert is_notnull == ["has-cat"]
  end

  test "startsWith / endsWith — anchored prefix/suffix match (case-insensitive, % literal)" do
    for {id, slug} <- [
          {"sw-1", "2024-jan"},
          {"sw-2", "2024-feb"},
          {"sw-3", "2023-dec"},
          {"sw-4", "50%-off"}
        ] do
      {:ok, _} =
        Content.create_document("post", %{"_id" => id, "title" => id, "slug" => slug}, "fops")

      {:ok, _} = Content.publish_document(id, "post", "fops")
    end

    starts =
      Content.list_documents("post", "fops",
        perspective: :published,
        filter_map: %{"slug" => %{"startsWith" => "2024-"}}
      )
      |> Enum.map(& &1.content["slug"])
      |> Enum.sort()

    assert starts == ["2024-feb", "2024-jan"]

    ends =
      Content.list_documents("post", "fops",
        perspective: :published,
        filter_map: %{"slug" => %{"endsWith" => "-DEC"}}
      )
      |> Enum.map(& &1.content["slug"])

    # case-insensitive (ILIKE): "-DEC" matches "...-dec"
    assert ends == ["2023-dec"]

    # the `%` in "50%-off" is a literal, not a wildcard
    pct =
      Content.list_documents("post", "fops",
        perspective: :published,
        filter_map: %{"slug" => %{"startsWith" => "50%"}}
      )
      |> Enum.map(& &1.content["slug"])

    assert pct == ["50%-off"]
  end

  test "_id eq / in — filter by the id field clients see (aliased to doc_id)" do
    for id <- ["bid-1", "bid-2", "bid-3"] do
      {:ok, _} = Content.create_document("post", %{"_id" => id, "title" => id}, "fops")
      {:ok, _} = Content.publish_document(id, "post", "fops")
    end

    # batch-fetch a known id-list in ONE request, using `_id` (not `doc_id`)
    got =
      Content.list_documents("post", "fops",
        perspective: :published,
        filter_map: %{"_id" => %{"in" => ["bid-1", "bid-3"]}}
      )
      |> Enum.map(& &1.doc_id)
      |> Enum.sort()

    assert got == ["bid-1", "bid-3"]

    # single `_id` eq also resolves through the alias
    one =
      Content.list_documents("post", "fops",
        perspective: :published,
        filter_map: %{"_id" => %{"eq" => "bid-2"}}
      )
      |> Enum.map(& &1.doc_id)

    assert one == ["bid-2"]
  end

  test "bare value (no operator map) still works as eq" do
    docs =
      Content.list_documents("post", "fops",
        perspective: :published,
        filter_map: %{"title" => "Beta"}
      )

    assert length(docs) == 1
    assert hd(docs).title == "Beta"
  end
end
