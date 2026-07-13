defmodule Barkpark.Content.TagDistributionTest do
  @moduledoc """
  Per-type tag-count distribution (authoring-excellence D45).

  Proves `TagDistribution.per_type/2` counts BOTH tag shapes — the wave-2
  weighted object `{"tag": name, …}` AND the legacy flat string `"name"` — and
  collapses a flat string and its weighted twin onto the same tag name, grouped
  and counted per type. Also proves the daily heartbeat worker
  `Workers.TagDistribution.perform/1` runs green over the seeded corpus.
  """

  use Barkpark.DataCase, async: true

  alias Barkpark.Content.{Document, TagDistribution}
  alias Barkpark.Repo
  alias Barkpark.Workers.TagDistribution, as: Worker

  @dataset "tagdist-test-#{System.unique_integer([:positive])}"

  # Insert a PUBLISHED document row directly (bypassing the publish wall — this
  # suite is about the read shape, not the wall). `tags` is whatever the caller
  # hands in: a list of weighted objects, a list of flat strings, or a mix.
  defp seed_doc(doc_id, type, tags) do
    now = DateTime.utc_now()

    {1, _} =
      Repo.insert_all(Document, [
        %{
          doc_id: doc_id,
          type: type,
          dataset: @dataset,
          title: doc_id,
          status: "published",
          content: %{"tags" => tags},
          rev: Barkpark.Content.Writer.generate_rev(),
          inserted_at: now,
          updated_at: now
        }
      ])

    :ok
  end

  defp weighted(name, strength),
    do: %{
      "tag" => name,
      "strength" => strength,
      "rationale" => "Seeded for the distribution test."
    }

  defp count_for(rows, type, tag) do
    Enum.find_value(rows, 0, fn
      %{type: ^type, tag: ^tag, count: c} -> c
      _ -> nil
    end)
  end

  setup do
    # paper corpus — "search" appears on THREE papers across both shapes:
    #   p1 weighted {search, elixir}, p2 weighted {search, docs},
    #   p3 legacy flat ["search", "legacy"]
    :ok = seed_doc("p1", "paper", [weighted("search", 90), weighted("elixir", 50)])
    :ok = seed_doc("p2", "paper", [weighted("search", 80), weighted("docs", 40)])
    :ok = seed_doc("p3", "paper", ["search", "legacy"])

    # task corpus — one flat, one weighted; "search" appears once as a flat
    # string, proving the flat shape is counted for a second type too.
    :ok = seed_doc("t1", "task", ["search"])
    :ok = seed_doc("t2", "task", [weighted("ops", 70)])

    # Noise the query MUST exclude: a DRAFT paper (status != published) and a
    # doc with a non-array `tags` value.
    now = DateTime.utc_now()

    {1, _} =
      Repo.insert_all(Document, [
        %{
          doc_id: "p-draft",
          type: "paper",
          dataset: @dataset,
          title: "p-draft",
          status: "draft",
          content: %{"tags" => [weighted("search", 60)]},
          rev: Barkpark.Content.Writer.generate_rev(),
          inserted_at: now,
          updated_at: now
        }
      ])

    :ok = seed_doc("p-notags", "paper", nil)

    :ok
  end

  describe "per_type/2" do
    test "counts BOTH weighted-object and legacy flat-string shapes, grouped per type" do
      rows = TagDistribution.per_type(["paper", "task"], @dataset)

      # "search" spans two weighted papers (p1, p2) AND one flat-string paper
      # (p3) — all three collapse onto the one tag name.
      assert count_for(rows, "paper", "search") == 3
      assert count_for(rows, "paper", "elixir") == 1
      assert count_for(rows, "paper", "docs") == 1
      # Purely legacy flat-string tag is counted.
      assert count_for(rows, "paper", "legacy") == 1

      # Second type: the flat-string "search" (t1) and the weighted "ops" (t2).
      assert count_for(rows, "task", "search") == 1
      assert count_for(rows, "task", "ops") == 1
    end

    test "excludes drafts and non-array tags — a draft 'search' paper does not inflate the count" do
      rows = TagDistribution.per_type("paper", @dataset)

      # p-draft carries a weighted "search" but is status=draft → still 3, not 4.
      assert count_for(rows, "paper", "search") == 3
      # p-notags (tags: nil) contributes zero rows, no phantom group.
      refute Enum.any?(rows, &(&1.type != "paper"))
    end

    test "a single binary type argument scopes to that type only" do
      rows = TagDistribution.per_type("task", @dataset)

      assert Enum.all?(rows, &(&1.type == "task"))
      assert count_for(rows, "task", "search") == 1
      assert count_for(rows, "task", "ops") == 1
      # No paper rows leak in.
      assert count_for(rows, "paper", "search") == 0
    end

    test "orders by count descending" do
      rows = TagDistribution.per_type("paper", @dataset)
      counts = Enum.map(rows, & &1.count)
      assert counts == Enum.sort(counts, :desc)
      # The most-used tag ("search", 3) leads.
      assert %{tag: "search", count: 3} = hd(rows)
    end

    test "empty type list and empty corpus both return []" do
      assert TagDistribution.per_type([], @dataset) == []
      assert TagDistribution.per_type("paper", "no-such-dataset-#{System.unique_integer()}") == []
    end
  end

  describe "Workers.TagDistribution.perform/1" do
    test "runs green over the seeded corpus" do
      assert :ok = Worker.perform(%Oban.Job{args: %{"dataset" => @dataset}})
    end

    test "runs green over an empty dataset" do
      assert :ok =
               Worker.perform(%Oban.Job{
                 args: %{"dataset" => "empty-#{System.unique_integer([:positive])}"}
               })
    end
  end
end
