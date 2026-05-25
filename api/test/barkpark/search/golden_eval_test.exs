defmodule Barkpark.Search.GoldenEvalTest do
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Search.{GoldenEval, SurfaceConfigs}

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

  test "golden eval passes for pipeline dataset" do
    metrics = GoldenEval.run("documents", "pipeline")

    assert metrics.queries >= 4
    assert metrics.failures == []
    assert metrics.mrr > 0
  end
end
