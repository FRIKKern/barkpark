defmodule Barkpark.Search.StrengthRankingTest do
  @moduledoc """
  Weighted-tag strength moves search rank (authoring-excellence D8/D21).

  `DocumentsRetriever.order_rank/3` key #2 adds `0.1 · max(strength)/100` for
  weighted tags whose NAME matches a query term. These tests pin the three
  contracted behaviours:

    * strength ORDERS: same registered tag, strength 90 vs 20 → the strong doc
      ranks first even though the weak doc is more recent (recency is only the
      #3 tiebreak — the boost must decide at key #2);
    * legacy flat-string tags (grandfathered via the exemption ledger) get
      ZERO boost and never error — the `jsonb_typeof(e)='object'` guard skips
      them;
    * a malformed object tag (non-integer `strength`) on an unwalled type is
      skipped by the digits guard instead of blowing up the `::int` cast —
      search never crashes on junk content.

  Docs match the query through the tag string itself (the generated
  search_vector indexes content strings at band D), so ts_rank is identical
  across fixtures by construction and ONLY the boost separates them.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.LabelFixtures

  @dataset "strength-rank"
  # The query term AND the tag name — deliberately absent from every title and
  # description so full-text rank is identical across docs and the strength
  # boost is the only rank signal under test.
  @tag_name "kelvarite"

  setup do
    Content.upsert_schema(
      %{"name" => "paper", "title" => "Paper", "visibility" => "public", "fields" => []},
      @dataset
    )

    Content.upsert_schema(
      %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
      @dataset
    )

    LabelFixtures.register_tags!(@dataset, [@tag_name])
    :ok
  end

  # A wall-compliant paper draft carrying ONE weighted tag (@tag_name) at the
  # given strength. Description rides LabelFixtures (unique tokens per call —
  # the E4 dedup token-bag gotcha); titles are caller-chosen disjoint tokens,
  # so the two fixture papers share only the single tag token, far under the
  # dedup refuse floor.
  defp weighted_paper!(id, title, strength) do
    content =
      LabelFixtures.with_labels(%{
        "tags" => [
          %{
            "tag" => @tag_name,
            "strength" => strength,
            "rationale" => "Strength #{strength} fixture — the ranking axis under test."
          }
        ]
      })

    {:ok, _} =
      Content.create_document(
        "paper",
        %{"_id" => id, "title" => title, "content" => content},
        @dataset
      )

    {:ok, _} = Content.publish_document(id, "paper", @dataset)
    :ok
  end

  defp result_ids(query) do
    {hits, _total, _meta} = Content.search_documents(query, @dataset)
    Enum.map(hits, & &1.doc_id)
  end

  test "strength moves rank: strength-90 outranks strength-20 for the same matching tag" do
    # Strong doc FIRST, weak doc SECOND — recency (order key #3) favors the
    # weak doc, so this ordering can only come from the strength boost.
    weighted_paper!("strength-strong", "Vantar ridge survey", 90)
    weighted_paper!("strength-weak", "Molvik harbor census", 20)

    ids = result_ids(@tag_name)

    strong_idx = Enum.find_index(ids, &(&1 == "strength-strong"))
    weak_idx = Enum.find_index(ids, &(&1 == "strength-weak"))

    assert strong_idx, "strong doc missing from results: #{inspect(ids)}"
    assert weak_idx, "weak doc missing from results: #{inspect(ids)}"
    assert strong_idx < weak_idx
  end

  test "legacy flat-string tags: zero boost, no crash — ranks below any boosted doc" do
    weighted_paper!("strength-strong", "Vantar ridge survey", 90)

    # A grandfathered legacy paper (exemption ledger row, charter D6) whose
    # tags are the pre-wall flat-string shape. The object guard must skip the
    # element — zero boost — and the query must not error.
    LabelFixtures.exempt!(["flat-legacy"], @dataset, "paper")

    {:ok, _} =
      Content.create_document(
        "paper",
        %{
          "_id" => "flat-legacy",
          "title" => "Skarn valley almanac",
          "content" => %{"tags" => [@tag_name]}
        },
        @dataset
      )

    {:ok, _} = Content.publish_document("flat-legacy", "paper", @dataset)

    ids = result_ids(@tag_name)

    strong_idx = Enum.find_index(ids, &(&1 == "strength-strong"))
    flat_idx = Enum.find_index(ids, &(&1 == "flat-legacy"))

    assert strong_idx, "strong doc missing from results: #{inspect(ids)}"
    assert flat_idx, "flat-tagged legacy doc missing from results: #{inspect(ids)}"
    # Identical full-text rank, but +0.09 vs +0: the boosted doc wins.
    assert strong_idx < flat_idx
  end

  test "an object tag with a non-integer strength is skipped, not a query crash" do
    # Unwalled type — nothing validates its tags, so junk shapes are reachable
    # in real content. The digits guard must skip the element BEFORE the ::int
    # cast; without it this query raises Postgrex invalid_text_representation.
    {:ok, _} =
      Content.create_document(
        "post",
        %{
          "_id" => "junk-strength",
          "title" => "Brenna coast register",
          "content" => %{
            "tags" => [
              %{
                "tag" => @tag_name,
                "strength" => "very-high",
                "rationale" => "Malformed on purpose — strength is not an integer."
              }
            ]
          }
        },
        @dataset
      )

    {:ok, _} = Content.publish_document("junk-strength", "post", @dataset)

    ids = result_ids(@tag_name)
    assert "junk-strength" in ids
  end
end
