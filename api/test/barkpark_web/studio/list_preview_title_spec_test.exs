defmodule BarkparkWeb.Studio.ListPreviewTitleSpecTest do
  @moduledoc """
  task-394a39576c8fb399: `list_preview.title` as a text spec sets the desk row
  title, the way Sanity's `prepare` does, with the stored title as fallback.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias BarkparkWeb.Studio.PaneBuilder

  @dataset "list-preview-title-#{System.unique_integer([:positive])}"

  test "a list_preview title spec sets the desk row title, with a fallback" do
    dataset = @dataset

    upsert = fn name, fields, title ->
      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => name,
            "title" => name,
            "visibility" => "public",
            "fields" =>
              for(f <- ["title" | fields], do: %{"name" => f, "title" => f, "type" => "string"}),
            "list_preview" => %{"title" => title}
          },
          dataset
        )
    end

    upsert.("edition", ["displayTitle"], ["displayTitle", "title", %{"text" => "No title"}])

    upsert.("job", ["code", "group"], [
      "{title} ({code}) · {group.title}",
      "{title} ({code})",
      "title"
    ])

    upsert.("team", [], "title")

    doc = fn type, id, title, content ->
      {:ok, _} =
        Content.create_document(
          type,
          %{"doc_id" => id, "title" => title, "content" => content},
          dataset
        )
    end

    doc.("edition", "ed-1", "Stored", %{"displayTitle" => "Shown"})
    doc.("edition", "ed-2", "Only stored", %{})
    doc.("edition", "ed-3", nil, %{})
    doc.("team", "team-1", "Crew", %{})
    doc.("job", "job-1", "Editor", %{"code" => "ED", "group" => %{"_ref" => "team-1"}})
    doc.("job", "job-2", "Writer", %{"code" => "WR"})
    doc.("job", "job-3", "Reader", %{})

    titles = fn type ->
      {panes, _editor} = PaneBuilder.build(dataset, [type])
      for %{type: :doc} = item <- List.last(panes).items, into: %{}, do: {item.id, item.title}
    end

    assert titles.("edition") == %{
             "ed-1" => "Shown",
             "ed-2" => "Only stored",
             "ed-3" => "No title"
           }

    assert titles.("job") == %{
             "job-1" => "Editor (ED) · Crew",
             "job-2" => "Writer (WR)",
             "job-3" => "Reader"
           }

    # A bare field name keeps its old meaning: the stored title wins.
    assert titles.("team") == %{"team-1" => "Crew"}
  end
end
