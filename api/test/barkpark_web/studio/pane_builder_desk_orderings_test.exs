defmodule BarkparkWeb.Studio.PaneBuilderDeskOrderingsTest do
  @moduledoc """
  Gyldendal parity stage E3.1 — the desk list honours the declared sort:
  a desk group's own `orderings` first, else the schema's `desk.orderings`
  (Sanity's `orderings`, first entry = default). And a desk-group filter with
  `is: null` on a nested path lists exactly the documents missing that field
  (the agency's «Med mangler» lists).
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias BarkparkWeb.Studio.PaneBuilder

  @dataset "desk-order-#{System.unique_integer([:positive])}"

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "publication",
          "title" => "Utgivelse",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Tittel", "type" => "string"},
            %{"name" => "year", "title" => "År", "type" => "number"},
            %{"name" => "cover", "title" => "Omslag", "type" => "image"}
          ],
          "desk" => %{"orderings" => [%{"field" => "title", "direction" => "desc"}]},
          "desk_groups" => [
            %{"name" => "all", "title" => "Alle"},
            %{
              "name" => "by-year",
              "title" => "Etter år",
              "orderings" => [%{"field" => "year", "direction" => "asc"}]
            },
            %{
              "name" => "uten-omslag",
              "title" => "Uten omslag",
              "filter" => %{"content.cover" => %{"is" => "null"}}
            }
          ]
        },
        @dataset
      )

    for {id, title, year, cover} <- [
          {"p-b", "Bravo", 2001, %{"url" => "/b.png"}},
          {"p-a", "Alpha", 2003, nil},
          {"p-c", "Charlie", 2002, %{"url" => "/c.png"}}
        ] do
      content = if cover, do: %{"year" => year, "cover" => cover}, else: %{"year" => year}

      {:ok, _} =
        Content.create_document(
          "publication",
          %{"doc_id" => id, "title" => title, "content" => content},
          @dataset
        )
    end

    :ok
  end

  defp titles(panes), do: panes |> List.last() |> Map.get(:items) |> Enum.map(& &1.title)

  test "the schema's desk.orderings sorts the list (title desc)" do
    {panes, _} = PaneBuilder.build(@dataset, ["publication"])
    assert titles(panes) == ["Charlie", "Bravo", "Alpha"]
  end

  test "a desk group's own orderings win over the schema's (year asc)" do
    {panes, _} = PaneBuilder.build(@dataset, ["publication"], desk: "by-year")
    assert titles(panes) == ["Bravo", "Charlie", "Alpha"]
  end

  test "a desk group with an is:null filter on a nested path lists exactly the documents missing the field" do
    {panes, _} = PaneBuilder.build(@dataset, ["publication"], desk: "uten-omslag")
    assert titles(panes) == ["Alpha"]
    refute List.last(panes)[:filter_error]
  end
end
