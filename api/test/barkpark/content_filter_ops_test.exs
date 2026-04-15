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
