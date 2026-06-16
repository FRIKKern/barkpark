defmodule Barkpark.Search.IndxRetrieverRerankTest do
  @moduledoc """
  Unit cover for the Indx retriever's title-affinity re-rank
  (`Barkpark.Plugins.Indx.Retriever.rerank_by_title/2`).

  Indx returns a flat BM25F order; this pass gives it the Postgres ranker's
  decisive "title wins" behaviour while preserving the engine's order within
  each tier. Pure over (hits, parsed) — no DB, no live engine — so it runs
  async and pins the exact ranking contract.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Content.Document
  alias Barkpark.Plugins.Indx.Retriever
  alias Barkpark.Search.QueryParser

  defp doc(id, title), do: %Document{doc_id: id, title: title}
  defp ids(hits), do: Enum.map(hits, & &1.doc_id)
  defp rerank(hits, q), do: Retriever.rerank_by_title(hits, QueryParser.parse(q))

  test "the documented regression: an exact title match is promoted over a body-heavy engine winner" do
    # Engine order: a long CLI paper first (body term-frequency), the titled
    # paper buried below it — exactly the q=\"fork\" failure @body_max guards.
    hits = [
      doc("cli", "Barkpark CLI Guide"),
      doc("misc", "Random notes"),
      doc("fork", "Fork reconciliation")
    ]

    assert ids(rerank(hits, "fork")) == ["fork", "cli", "misc"]
  end

  test "title matches outrank body-only matches; engine order kept within a tier" do
    hits = [
      doc("body1", "Deploy notes"),
      doc("t1", "Phoenix Guide"),
      doc("body2", "Runtime internals"),
      doc("t2", "Using Phoenix")
    ]

    # Both title hits float up (tier 1) keeping their relative engine order;
    # the body-only hits stay below, also in engine order.
    assert ids(rerank(hits, "phoenix")) == ["t1", "t2", "body1", "body2"]
  end

  test "an exact title beats a mere title-contains match" do
    hits = [doc("contains", "Using Phoenix Today"), doc("exact", "Phoenix")]
    assert ids(rerank(hits, "phoenix")) == ["exact", "contains"]
  end

  test "all query terms in the title (tier 1) beats only-some-terms (tier 2)" do
    hits = [
      doc("some", "Phoenix in production"),
      doc("all", "Elixir Phoenix Guide")
    ]

    # "all" has both tokens in its title (tier 1); "some" has only one (tier 2).
    assert ids(rerank(hits, "elixir phoenix")) == ["all", "some"]
  end

  test "a prefix token matches a title word prefix" do
    hits = [doc("body", "Deploy steps"), doc("t", "Phoenix Guide")]
    # "phoen" is a term that prefix-matches the title word "phoenix".
    assert ids(rerank(hits, "phoen")) == ["t", "body"]
  end

  test "browse (empty query) leaves the engine order untouched" do
    hits = [doc("a", "Alpha"), doc("b", "Beta"), doc("c", "Gamma")]
    assert ids(rerank(hits, "")) == ["a", "b", "c"]
  end

  test "no title signal at all preserves the engine order" do
    hits = [doc("a", "Alpha"), doc("b", "Beta")]
    assert ids(rerank(hits, "kumquat")) == ["a", "b"]
  end

  test "is a no-op on an empty hit list" do
    assert Retriever.rerank_by_title([], QueryParser.parse("anything")) == []
  end
end
