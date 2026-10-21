defmodule Barkpark.Content.PreviewTextCountTest do
  @moduledoc """
  task-394a39576c8fb399: `|count` shows the number of items in a list, the
  way a Sanity `prepare` shows `items.length`.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.PreviewText
  alias BarkparkWeb.Studio.PaneBuilder

  @dataset "preview-count-#{System.unique_integer([:positive])}"

  defp nobody, do: fn _id -> nil end

  test "|count shows the number of items in a list" do
    root = %{"questions" => [%{"q" => "a"}, %{"q" => "b"}, %{"q" => "c"}], "rules" => []}

    assert PreviewText.format("questions|count", root, nobody()) == "3"
    assert PreviewText.format("{questions|count} questions", root, nobody()) == "3 questions"
    assert PreviewText.format("{rules|count} rules", root, nobody()) == "0 rules"
    assert PreviewText.format("{missing|count} rules", root, nobody()) == "0 rules"
    assert PreviewText.format("{questions.0.q|count} rules", root, nobody()) == nil

    spec = %{"parts" => ["title", "{questions|count} questions"], "join" => " · "}

    assert PreviewText.format(spec, Map.put(root, "title", "Help"), nobody()) ==
             "Help · 3 questions"

    # Counting a list of references loads none of them.
    assert PreviewText.ref_ids("items|count", %{"items" => ["a", %{"_ref" => "b"}]}) == []
  end

  test "a desk row's subtitle counts the items of a list" do
    dataset = @dataset

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "faq_set",
          "title" => "FAQ set",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{
              "name" => "questions",
              "title" => "Questions",
              "type" => "array",
              "of" => [%{"type" => "string"}]
            }
          ],
          "list_preview" => %{"subtitle" => "{questions|count} questions"}
        },
        dataset
      )

    for {id, title, content} <- [
          {"faq-a", "Shipping", %{"questions" => ["one", "two"]}},
          {"faq-b", "Returns", %{}}
        ] do
      {:ok, _} =
        Content.create_document(
          "faq_set",
          %{"doc_id" => id, "title" => title, "content" => content},
          dataset
        )
    end

    {panes, _editor} = PaneBuilder.build(dataset, ["faq_set"])

    rows =
      for %{type: :doc} = item <- List.last(panes).items, into: %{}, do: {item.title, item.meta}

    assert rows["Shipping"] == "2 questions"
    assert rows["Returns"] == "0 questions"
  end
end
