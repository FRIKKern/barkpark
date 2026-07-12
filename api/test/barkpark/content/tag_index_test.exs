defmodule Barkpark.Content.TagIndexTest do
  @moduledoc """
  `Content.papers_with_tag/3` — the tag-index read: papers carrying a `#tag` in
  `content["tags"]`. DUAL-SHAPE (authoring-excellence D10/D19): weighted
  `{tag, strength, rationale}` entries post-wall AND legacy flat strings under
  the exemption ratchet, both matched exactly (Obsidian-parity) by one EXISTS
  read. Title-ordered, blank/miss → []. Plus the `hasStrong` filter op (D20)
  — weighted membership with a strength floor — and the `filter[main_tag]`
  equality over the publish-stamped argmax.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.Query

  @dataset "tag_index_test"

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

  test "returns the papers carrying a tag, title-ordered" do
    paper!("p-b", "Beta", %{"tags" => ["epic", "draft"]})
    paper!("p-a", "Alpha", %{"tags" => ["epic"]})
    paper!("p-c", "Gamma", %{"tags" => ["other"]})

    assert Content.papers_with_tag("epic", @dataset) == [
             %{id: "p-a", title: "Alpha"},
             %{id: "p-b", title: "Beta"}
           ]

    assert Content.papers_with_tag("draft", @dataset) == [%{id: "p-b", title: "Beta"}]
  end

  test "tag match is exact (no case-fold); blank or missing tag → []" do
    paper!("p-x", "X", %{"tags" => ["epic"]})

    assert Content.papers_with_tag("Epic", @dataset) == []
    assert Content.papers_with_tag("nope", @dataset) == []
    assert Content.papers_with_tag("", @dataset) == []
    assert Content.papers_with_tag("   ", @dataset) == []
  end

  # WEIGHTED docs ride the REAL publish path (the wall stamps prod's weighted
  # rows, so the fixture mirrors their birth): registered tags + compliant
  # description via LabelFixtures, then create → publish.
  defp weighted_paper!(id, title, names) do
    content = Barkpark.LabelFixtures.with_named_labels(%{}, @dataset, names)

    {:ok, _} =
      Content.create_document(
        "paper",
        Map.merge(%{"_id" => id, "title" => title}, content),
        @dataset
      )

    {:ok, doc} = Content.publish_document(id, "paper", @dataset)
    doc
  end

  describe "dual-shape membership (D10/D19)" do
    test "weighted tags match; strength/rationale text never leaks into membership" do
      weighted_paper!("pw-a", "Weighted Alpha", ["epic", "pwa-only"])
      weighted_paper!("pw-b", "Weighted Beta", ["pwb-only"])

      assert Content.papers_with_tag("epic", @dataset) == [
               %{id: "pw-a", title: "Weighted Alpha"}
             ]

      # The weighted entry's OTHER leaves are not membership: neither the
      # strength number nor rationale words match as a "tag".
      assert Content.papers_with_tag("99", @dataset) == []
      assert Content.papers_with_tag("exercises", @dataset) == []
    end

    test "mixed corpus: flat and weighted shapes both answer ONE tag query" do
      paper!("pf", "Flat Doc", %{"tags" => ["epic"]})
      weighted_paper!("pw", "Weighted Doc", ["epic", "pw-extra"])

      assert Content.papers_with_tag("epic", @dataset) == [
               %{id: "pf", title: "Flat Doc"},
               %{id: "pw", title: "Weighted Doc"}
             ]
    end
  end

  describe "filter[tags][hasStrong] — weighted membership with a strength floor (D20)" do
    test "matches at/above the floor, misses below, ignores flat elements" do
      weighted_paper!("hs-hi", "Strong Doc", [{"epic", 90}, {"strongx", 30}])
      weighted_paper!("hs-lo", "Weak Doc", [{"weakx", 80}, {"epic", 20}])
      paper!("hs-flat", "Flat Sibling", %{"tags" => ["epic"]})

      ids = fn filter ->
        "paper"
        |> Content.list_documents(@dataset, filter_map: filter)
        |> Enum.map(& &1.doc_id)
        |> Enum.sort()
      end

      assert ids.(%{"tags" => %{"hasStrong" => "epic:50"}}) == ["hs-hi"]
      assert ids.(%{"tags" => %{"hasStrong" => "epic:20"}}) == ["hs-hi", "hs-lo"]
      assert ids.(%{"tags" => %{"hasStrong" => "epic:95"}}) == []
      # An unknown tag name at any floor matches nothing.
      assert ids.(%{"tags" => %{"hasStrong" => "nope:1"}}) == []
    end

    test "value grammar: LAST-colon split; malformed values are :error (controller 400s them)" do
      assert Query.parse_has_strong("epic:50") == {:ok, "epic", 50}
      assert Query.parse_has_strong("ns:sub:50") == {:ok, "ns:sub", 50}
      assert Query.parse_has_strong("epic") == :error
      assert Query.parse_has_strong("epic:") == :error
      assert Query.parse_has_strong(":50") == :error
      assert Query.parse_has_strong("epic:high") == :error
      assert Query.parse_has_strong(50) == :error
    end
  end

  describe "filter[main_tag] — the publish-stamped argmax (D20, generic eq)" do
    test "equality finds exactly the doc whose strongest tag matches" do
      weighted_paper!("mt-a", "Argmax Alpha", [{"mta-top", 90}, {"mshared", 10}])
      weighted_paper!("mt-b", "Argmax Beta", [{"mtb-top", 80}, {"nshared", 15}])

      docs = Content.list_documents("paper", @dataset, filter_map: %{"main_tag" => "mta-top"})
      assert Enum.map(docs, & &1.doc_id) == ["mt-a"]

      # A NON-max tag name is not the main tag.
      assert Content.list_documents("paper", @dataset, filter_map: %{"main_tag" => "mshared"}) ==
               []
    end
  end
end
