defmodule Barkpark.Content.TagSearchTest do
  @moduledoc """
  `Content.search_tags/3` — the `#tag` typeahead candidate read: DISTINCT tag
  NAMES across papers in a dataset matching `query` (case-insensitive
  substring), via a LATERAL unnest of `content["tags"]`. DUAL-SHAPE
  (authoring-excellence D10/D19): weighted entries read as their tag NAME
  (never the raw JSON blob, never a rationale-text ILIKE false positive);
  legacy flat strings read as themselves; a tag present in both shapes dedups
  to ONE row. The inverse of `papers_with_tag/3`. Name-ordered, distinct,
  capped, blank → top distinct tags.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content

  @dataset "tag_search_test"

  setup do
    Content.upsert_schema(
      %{
        "name" => "paper",
        "title" => "Paper",
        "visibility" => "public",
        "fields" => [%{"name" => "tags", "type" => "arrayOf", "of" => %{"type" => "string"}}]
      },
      @dataset
    )

    :ok
  end

  defp paper!(id, title, attrs) do
    {:ok, _} =
      Content.create_document(
        "paper",
        Map.merge(%{"_id" => id, "title" => title}, attrs),
        @dataset
      )

    # LEGACY flat-string tags are the shape under test — these docs represent
    # pre-wall papers, so they ride the exemption ledger exactly like prod's
    # migration-seeded corpus (content stays untouched by the label spine).
    Barkpark.LabelFixtures.exempt!(id, @dataset)
    {:ok, doc} = Content.publish_document(id, "paper", @dataset)
    doc
  end

  test "returns DISTINCT matching tag names across papers, name-ordered" do
    paper!("p-a", "Alpha", %{"tags" => ["design", "obsidian"]})
    paper!("p-b", "Beta", %{"tags" => ["design", "draft"]})
    paper!("p-c", "Gamma", %{"tags" => ["other"]})

    # "design" appears on two papers but is returned ONCE (DISTINCT).
    assert Content.search_tags("des", @dataset) == ["design"]

    # substring "d" matches design + draft + obsi(d)ian, distinct + name-ordered
    assert Content.search_tags("d", @dataset) == ["design", "draft", "obsidian"]

    # a substring that hits exactly two distinct names
    assert Content.search_tags("ra", @dataset) == ["draft"]
  end

  test "match is case-insensitive substring" do
    paper!("p-x", "X", %{"tags" => ["Obsidian", "Design"]})

    assert Content.search_tags("OBSIDIAN", @dataset) == ["Obsidian"]
    assert Content.search_tags("sign", @dataset) == ["Design"]
  end

  test "no-match yields []; blank query yields the top distinct tags" do
    paper!("p-1", "One", %{"tags" => ["alpha", "beta"]})
    paper!("p-2", "Two", %{"tags" => ["beta", "gamma"]})

    assert Content.search_tags("zzzz", @dataset) == []

    # blank → top distinct tags (no ilike filter), distinct + ordered
    assert Content.search_tags("", @dataset) == ["alpha", "beta", "gamma"]
    assert Content.search_tags("   ", @dataset) == ["alpha", "beta", "gamma"]
  end

  test "results are capped (a large tag vocabulary can't flood a typeahead)" do
    tags = for i <- 1..25, do: "tag#{String.pad_leading(to_string(i), 2, "0")}"
    paper!("p-many", "Many", %{"tags" => tags})

    results = Content.search_tags("tag", @dataset)
    assert length(results) == 20
  end

  test "tags are scoped by dataset (no cross-dataset leak)" do
    Content.upsert_schema(
      %{
        "name" => "paper",
        "title" => "Paper",
        "visibility" => "public",
        "fields" => [%{"name" => "tags", "type" => "arrayOf", "of" => %{"type" => "string"}}]
      },
      "tag_search_other"
    )

    paper!("p-here", "Here", %{"tags" => ["scopedtag"]})

    {:ok, _} =
      Content.create_document(
        "paper",
        %{"_id" => "p-there", "title" => "There", "tags" => ["leaktag"]},
        "tag_search_other"
      )

    Barkpark.LabelFixtures.exempt!("p-there", "tag_search_other")
    {:ok, _} = Content.publish_document("p-there", "paper", "tag_search_other")

    assert Content.search_tags("tag", @dataset) == ["scopedtag"]
    assert Content.search_tags("leak", @dataset) == []
  end

  # WEIGHTED docs ride the REAL publish path (the wall stamps prod's weighted
  # rows): registered tags + compliant description via LabelFixtures.
  defp weighted_paper!(id, title, names) do
    content = Barkpark.LabelFixtures.with_named_labels(%{}, @dataset, names)

    {:ok, _} =
      Content.create_document(
        "paper",
        Map.merge(%{"_id" => id, "title" => title}, content),
        @dataset
      )

    {:ok, _} = Content.publish_document(id, "paper", @dataset)
    :ok
  end

  describe "dual-shape typeahead (D10/D19)" do
    test "weighted tags surface as NAMES — never a JSON blob, never a rationale false positive" do
      weighted_paper!("pw-1", "Weighted One", ["obsidian-w", "unrelated-w"])

      assert Content.search_tags("obsidian", @dataset) == ["obsidian-w"]

      # The OLD reader unnested the raw element text, so the weighted object's
      # rationale ILIKE-matched typeahead queries. Names only now.
      assert Content.search_tags("exercises", @dataset) == []
      assert Content.search_tags("dual-shape", @dataset) == []

      # And the blank-query top list carries no serialized-object noise.
      results = Content.search_tags("", @dataset)
      assert results == ["obsidian-w", "unrelated-w"]
      refute Enum.any?(results, &String.contains?(&1, "{"))
    end

    test "mixed corpus: a tag present in BOTH shapes dedups to ONE row (DISTINCT)" do
      paper!("p-flat", "Flat Half", %{"tags" => ["design"]})
      weighted_paper!("p-weighted", "Weighted Half", ["design", "wextra"])

      assert Content.search_tags("des", @dataset) == ["design"]
      assert Content.search_tags("", @dataset) == ["design", "wextra"]
    end
  end
end
