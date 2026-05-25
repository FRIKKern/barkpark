defmodule Barkpark.Search.GoldenEval do
  @moduledoc """
  Golden-query evaluation harness (Phase 7). Loads JSONL fixtures and scores retrieval.
  """

  alias Barkpark.Content
  alias Barkpark.Media

  @type metrics :: %{
          queries: non_neg_integer(),
          zero_hit_rate: float(),
          mrr: float(),
          ndcg_at_10: float(),
          failures: [map()]
        }

  @spec run(String.t(), String.t(), keyword()) :: metrics()
  def run(surface, scope, opts \\ []) when surface in ["documents", "media"] do
    path = fixture_path(surface, Keyword.get(opts, :fixtures_dir))

    queries =
      path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    results = Enum.map(queries, &eval_query(surface, scope, &1))

    total = length(results)
    zero_hits = Enum.count(results, & &1.zero_hit?)
    mrr = avg(Enum.map(results, & &1.mrr))
    ndcg = avg(Enum.map(results, & &1.ndcg_at_10))
    failures = Enum.filter(results, & &1.failure?)

    %{
      queries: total,
      zero_hit_rate: if(total > 0, do: Float.round(zero_hits / total, 3), else: 0.0),
      mrr: Float.round(mrr, 3),
      ndcg_at_10: Float.round(ndcg, 3),
      failures: Enum.map(failures, &Map.take(&1, [:q, :reason, :got_ids]))
    }
  end

  @spec compare(metrics(), metrics()) :: :ok | {:error, [String.t()]}
  def compare(current, baseline) do
    regressions = []

    regressions =
      if current.ndcg_at_10 + 0.001 < baseline.ndcg_at_10 do
        ["NDCG@10 regressed #{baseline.ndcg_at_10} -> #{current.ndcg_at_10}" | regressions]
      else
        regressions
      end

    regressions =
      if current.mrr + 0.001 < baseline.mrr do
        ["MRR regressed #{baseline.mrr} -> #{current.mrr}" | regressions]
      else
        regressions
      end

    if regressions == [], do: :ok, else: {:error, Enum.reverse(regressions)}
  end

  defp eval_query("documents", scope, spec) do
    q = spec["q"]

    {docs, _count, _meta} =
      Content.search_documents(q, scope, perspective: :published, limit: 50)

    ids = Enum.map(docs, & &1.doc_id)
    score(spec, q, ids)
  end

  defp eval_query("media", scope, spec) do
    q = spec["q"]

    {files, _total, _facets, _meta} =
      Media.search_files(scope, q: q, limit: 50, offset: 0, sort: "relevance")

    ids = Enum.map(files, & &1.id)
    score(spec, q, ids)
  end

  defp score(spec, q, ids) do
    expect = spec["expect_ids"] || []
    exclude = spec["must_exclude"] || []
    max_rank = spec["max_rank"] || 10
    ranked = Enum.take(ids, max(10, max_rank))

    missing =
      expect
      |> Enum.reject(&(&1 in ranked))

    excluded_present =
      exclude
      |> Enum.filter(&(&1 in ranked))

    mrr = reciprocal_rank(expect, ranked)
    ndcg = ndcg_at_k(expect, ranked, 10)
    zero_hit? = ranked == []

    failure? = missing != [] or excluded_present != []

    reason =
      cond do
        excluded_present != [] ->
          "must_exclude present: #{inspect(excluded_present)}"

        missing != [] ->
          "missing expected ids #{inspect(missing)} in #{inspect(ranked)}"

        true ->
          nil
      end

    %{
      q: q,
      got_ids: ranked,
      mrr: mrr,
      ndcg_at_10: ndcg,
      zero_hit?: zero_hit?,
      failure?: failure?,
      reason: reason
    }
  end

  defp reciprocal_rank(expect, ranked) do
    case first_rank(expect, ranked) do
      nil -> 0.0
      rank -> 1.0 / rank
    end
  end

  defp first_rank(expect, ranked) do
    expect
    |> Enum.map(fn id -> Enum.find_index(ranked, &(&1 == id)) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&(&1 + 1))
    |> Enum.min(fn -> nil end)
  end

  defp ndcg_at_k(expect, ranked, k) do
    ranked = Enum.take(ranked, k)

    dcg =
      ranked
      |> Enum.with_index()
      |> Enum.reduce(0.0, fn {id, pos}, acc ->
        if id in expect do
          acc + 1.0 / :math.log2(pos + 2)
        else
          acc
        end
      end)

    idcg =
      expect
      |> Enum.take(k)
      |> Enum.with_index(1)
      |> Enum.reduce(0.0, fn {_id, i}, acc -> acc + 1.0 / :math.log2(i + 1) end)

    if idcg > 0, do: dcg / idcg, else: 0.0
  end

  defp avg([]), do: 0.0
  defp avg(nums), do: Enum.sum(nums) / length(nums)

  defp fixture_path(surface, nil) do
    Path.join([File.cwd!(), "test", "search_golden", surface, "test.jsonl"])
  end

  defp fixture_path(surface, dir), do: Path.join(dir, "#{surface}/test.jsonl")
end
