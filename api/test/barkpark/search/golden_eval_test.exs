defmodule Barkpark.Search.GoldenEvalTest do
  use Barkpark.DataCase, async: true

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

  test "compare/2 accepts a JSON round-tripped (string-keyed) baseline" do
    # Regression guard: a disk-loaded baseline carries STRING keys. The old
    # atom dot-access (`baseline.ndcg_at_10`) raised KeyError at golden_eval.ex:49.
    metrics = GoldenEval.run("documents", "pipeline")
    baseline = metrics |> Jason.encode!() |> Jason.decode!()

    # atom-keyed current vs string-keyed baseline (identical → no regression)
    assert GoldenEval.compare(metrics, baseline) == :ok
    # both sides string-keyed (as CI would load two saved snapshots)
    assert GoldenEval.compare(baseline, baseline) == :ok
  end

  test "compare/2 flags a regression across the string/atom key boundary" do
    metrics = GoldenEval.run("documents", "pipeline")
    baseline = metrics |> Jason.encode!() |> Jason.decode!()
    worse = %{metrics | mrr: metrics.mrr - 0.5, ndcg_at_10: metrics.ndcg_at_10 - 0.5}

    assert {:error, msgs} = GoldenEval.compare(worse, baseline)
    assert Enum.any?(msgs, &String.contains?(&1, "MRR regressed"))
    assert Enum.any?(msgs, &String.contains?(&1, "NDCG@10 regressed"))
  end

  test "committed baseline.json is a valid floor for the pipeline reference corpus" do
    # Pins the serialized snapshot (test/search_golden/baseline.json) against a
    # live run: exercises the string-key path end-to-end and proves the checked-in
    # numbers are a real floor, not aspirational.
    baseline =
      Path.join([File.cwd!(), "test", "search_golden", "baseline.json"])
      |> File.read!()
      |> Jason.decode!()

    metrics = GoldenEval.run("documents", "pipeline")
    assert GoldenEval.compare(metrics, baseline) == :ok
  end
end
