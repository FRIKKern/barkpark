defmodule Barkpark.Content.TagIndexTest do
  @moduledoc """
  `Content.papers_with_tag/3` — the tag-index read: papers carrying a `#tag` in
  `content["tags"]`, via the JSONB scalar-membership containment. Exact match
  (Obsidian-parity), title-ordered, blank/miss → [].
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content

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

  defp paper!(id, title, attrs \\ %{}) do
    {:ok, _} =
      Content.create_document(
        "paper",
        Map.merge(%{"_id" => id, "title" => title}, attrs),
        @dataset
      )

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
end
