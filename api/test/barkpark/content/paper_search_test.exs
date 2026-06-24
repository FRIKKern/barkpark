defmodule Barkpark.Content.PaperSearchTest do
  @moduledoc """
  `Content.search_papers/3` — the typeahead candidate read (papers by
  case-insensitive title substring) behind the `[[` autocomplete + quick-switcher.
  Title-ordered, capped, blank → [].
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content

  @dataset "paper_search_test"

  setup do
    Content.upsert_schema(
      %{"name" => "paper", "title" => "Paper", "visibility" => "public", "fields" => []},
      @dataset
    )

    :ok
  end

  defp paper!(id, title) do
    {:ok, _} = Content.create_document("paper", %{"_id" => id, "title" => title}, @dataset)
    {:ok, doc} = Content.publish_document(id, "paper", @dataset)
    doc
  end

  test "matches title by case-insensitive substring, title-ordered" do
    paper!("p-intro", "Intro to Graphs")
    paper!("p-adv", "Advanced Graphs")
    paper!("p-other", "Cooking")

    assert Content.search_papers("graph", @dataset) == [
             %{id: "p-adv", title: "Advanced Graphs"},
             %{id: "p-intro", title: "Intro to Graphs"}
           ]

    # case-insensitive
    assert Content.search_papers("INTRO", @dataset) == [%{id: "p-intro", title: "Intro to Graphs"}]
  end

  test "blank query and a no-match both yield []" do
    paper!("p-x", "Something")

    assert Content.search_papers("", @dataset) == []
    assert Content.search_papers("   ", @dataset) == []
    assert Content.search_papers("zzzz", @dataset) == []
  end

  test "results are capped (limit guards a typeahead against a large corpus)" do
    for i <- 1..25, do: paper!("p-#{i}", "Match #{String.pad_leading(to_string(i), 2, "0")}")

    results = Content.search_papers("Match", @dataset)
    assert length(results) == 20
  end
end
