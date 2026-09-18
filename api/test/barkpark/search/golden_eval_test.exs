defmodule Barkpark.Search.GoldenEvalTest do
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Search.{GoldenEval, SurfaceConfigs}

  # One more than the largest budget any committed fixture declares (10), so the
  # tightest declared window is violable. Asserted, not assumed, by
  # "the golden corpus can violate the largest declared budget" below.
  @filler_count 11
  @filler_q "haystack"
  @absent_id "__no_document_has_this_id__"

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

    # THE CORPUS MUST BE BIGGER THAN THE BIGGEST BUDGET. With only p1 and p2 seeded,
    # rank 3 was unreachable, so a `"max_rank": 3` fixture could not have been
    # violated even by a harness that honoured it — a second, independent reason
    # every budget was inert (task-edebad9d62514545). These fillers share one token
    # ("haystack") that NO committed fixture query uses, so they are rankable in bulk
    # for the budget arms below while leaving the four real golden queries — phoenix,
    # phoenix -wright, react, elixir — and the committed baseline.json untouched.
    for i <- 1..@filler_count do
      id = "h#{i}"

      Content.create_document(
        "post",
        %{"doc_id" => "drafts.#{id}", "title" => "Haystack Straw #{i}"},
        "pipeline"
      )

      Content.publish_document(id, "post", "pipeline")
    end

    :ok
  end

  # ---------------------------------------------------------------- budget arms

  # Every arm below derives its expectations from the fixtures ON DISK and from a
  # live probe run — never from a list retyped here. A budget added to, removed
  # from or edited in any test/search_golden/*/test.jsonl is picked up with no
  # edit to this file.

  defp declared_max_ranks do
    ranks =
      [File.cwd!(), "test", "search_golden", "*", "test.jsonl"]
      |> Path.join()
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        path
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&(Jason.decode!(&1)["max_rank"] || 10))
      end)
      |> Enum.uniq()
      |> Enum.sort()

    # A zero-length read here would make every arm below vacuously true.
    assert ranks != [], "no max_rank declared by any test/search_golden/*/test.jsonl"
    ranks
  end

  defp write_fixtures(entries) do
    dir = Path.join(System.tmp_dir!(), "golden_eval_budget_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "documents"))

    File.write!(
      Path.join([dir, "documents", "test.jsonl"]),
      Enum.map_join(entries, "\n", &Jason.encode!/1) <> "\n"
    )

    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  # Runs ONE synthetic query at the given budget. `expect_ids` names an id the
  # corpus cannot contain, so the entry always lands in `failures` and the harness
  # hands back `got_ids` — which IS the scoring window, observed rather than assumed.
  defp window_for(q, max_rank) do
    dir = write_fixtures([%{"q" => q, "expect_ids" => [@absent_id], "max_rank" => max_rank}])
    metrics = GoldenEval.run("documents", "pipeline", fixtures_dir: dir)

    assert [%{q: ^q, got_ids: got}] = metrics.failures
    got
  end

  test "an expected id one position past its max_rank is a failure" do
    ranking = window_for(@filler_q, @filler_count * 2)
    assert length(ranking) >= 2, "probe returned #{length(ranking)} hits; cannot address rank 2"

    # The id that actually ranks SECOND for this query, read off the live ranking.
    rank_two = Enum.at(ranking, 1)

    inside =
      GoldenEval.run("documents", "pipeline",
        fixtures_dir:
          write_fixtures([%{"q" => @filler_q, "expect_ids" => [rank_two], "max_rank" => 2}])
      )

    assert inside.failures == [],
           "rank-2 id inside a max_rank:2 window must pass, got #{inspect(inside.failures)}"

    outside =
      GoldenEval.run("documents", "pipeline",
        fixtures_dir:
          write_fixtures([%{"q" => @filler_q, "expect_ids" => [rank_two], "max_rank" => 1}])
      )

    # bind first, then assert on a boolean: a message on `assert pattern = expr`
    # is unreachable (MatchError fires before assert/2 can read it).
    assert match?([%{q: @filler_q, got_ids: _}], outside.failures),
           "a rank-2 id one position past a max_rank:1 budget must FAIL; it did not. " <>
             "The window was widened past the declared budget. got: #{inspect(outside.failures)}"

    [%{got_ids: got}] = outside.failures
    assert length(got) == 1, "the max_rank:1 window held #{length(got)} ids"
  end

  test "every budget declared on disk is the scoring window, not a floor of 10" do
    corpus = length(window_for(@filler_q, @filler_count * 2))

    for max_rank <- declared_max_ranks() do
      got = window_for(@filler_q, max_rank)

      assert length(got) == min(max_rank, corpus),
             "max_rank #{max_rank} scored #{length(got)} ids out of #{corpus} available; " <>
               "the declared budget is not the window."
    end
  end

  test "the golden corpus can violate the largest declared budget" do
    largest = Enum.max(declared_max_ranks())
    corpus = length(window_for(@filler_q, largest * 10))

    assert corpus > largest,
           "the golden setup seeds only #{corpus} rankable documents but the largest " <>
             "declared max_rank is #{largest}; rank #{largest + 1} is unreachable, so no " <>
             "budget can ever be violated."
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
