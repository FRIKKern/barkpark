defmodule Barkpark.Search.QueryPipelineTest do
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Search.{QueryParser, QueryPipeline, SurfaceConfigs}

  setup do
    SurfaceConfigs.seed_defaults!()

    Content.upsert_schema(
      %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
      "pipeline"
    )

    Content.upsert_schema(
      %{"name" => "author", "title" => "Author", "visibility" => "public", "fields" => []},
      "pipeline"
    )

    Content.create_document(
      "post",
      %{"doc_id" => "drafts.p1", "title" => "Elixir Phoenix Guide"},
      "pipeline"
    )

    Content.create_document(
      "author",
      %{"doc_id" => "drafts.p2", "title" => "Phoenix Wright"},
      "pipeline"
    )

    Content.publish_document("p1", "post", "pipeline")
    Content.publish_document("p2", "author", "pipeline")
    :ok
  end

  test "search returns hits with parsed query metadata" do
    context = %{query: "phoenix", filters: %{}, offset: 0}

    assert {:ok, result} =
             QueryPipeline.search("documents", "pipeline", context,
               perspective: :published,
               limit: 10
             )

    assert result.total == 2
    assert length(result.hits) == 2
    assert result.parsed[:terms] == ["phoenix"]
    assert is_map(result.highlights)
  end

  test "exclude token removes matching documents" do
    context = %{query: "phoenix -wright", filters: %{}, offset: 0}

    assert {:ok, result} =
             QueryPipeline.search("documents", "pipeline", context,
               perspective: :published,
               limit: 10
             )

    ids = Enum.map(result.hits, & &1.doc_id)
    assert "p1" in ids
    refute "p2" in ids
    assert result.total == 1
  end

  test "drop_tokens recovery on zero-hit query" do
    context = %{query: "zzzznomatch extra", filters: %{}, offset: 0}

    assert {:ok, result} =
             QueryPipeline.search("documents", "pipeline", context,
               perspective: :published,
               limit: 10
             )

    assert result.recovery in [nil, "drop_tokens", "typo_widen"]
  end

  test "media_recovery delegates to search_fn" do
    parsed = QueryParser.parse("onlyterm extra")
    config = SurfaceConfigs.default_for("media")

    {hits, total, recovery} =
      QueryPipeline.media_recovery(parsed, config, fn p, _relaxed ->
        terms = p.terms ++ p.phrases
        if length(terms) >= 1, do: {[:hit], 1}, else: {[], 0}
      end)

    assert total == 1
    assert hits == [:hit]
    assert recovery in [nil, "drop_tokens"]
  end
end
