defmodule Barkpark.StructureTodayTest do
  @moduledoc """
  `"$today"` on the server (task-f78a513602faee55): a desk list's filter
  compares a date field with today, and an API create of a type whose
  `initial_values` say `"$today"` stores the workspace's date. HSO's
  «Kommende» / «Gjennomførte» split `arrangement.sluttdato` on today; Sanity
  writes those as `sluttdato >= now()` and `initialValue: () => new Date()`.
  """
  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Content
  alias Barkpark.Content.Schema
  alias Barkpark.Structure
  alias Barkpark.Tenancy

  @dataset "today-#{System.unique_integer([:positive])}"

  @arrangement %{
    "name" => "arrangement",
    "title" => "Arrangement",
    "visibility" => "public",
    "fields" => [
      %{"name" => "title", "type" => "string"},
      %{"name" => "sluttdato", "type" => "date"},
      %{"name" => "publisert", "type" => "date"}
    ],
    "initial_values" => %{"publisert" => "$today"}
  }

  defp desk!(items) do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "deskStructure",
          "title" => "Desk",
          "singleton" => true,
          "visibility" => "private",
          "fields" => [%{"name" => "items", "type" => "array"}]
        },
        @dataset
      )

    {:ok, _} =
      Content.create_document(
        "deskStructure",
        %{"doc_id" => "deskStructure", "title" => "Desk", "content" => %{"items" => items}},
        @dataset
      )

    {:ok, _} = Content.publish_document("deskStructure", "deskStructure", @dataset)
  end

  defp event!(id, content) do
    {:ok, _} =
      Content.create_document(
        "arrangement",
        %{"doc_id" => id, "title" => id, "content" => content},
        @dataset
      )
  end

  test "a desk list filtered on sluttdato gte $today drops yesterday's event" do
    {:ok, _} = Content.upsert_schema(@arrangement, @dataset)

    desk!([
      %{
        "kind" => "documentTypeList",
        "type" => "arrangement",
        "title" => "Kommende",
        "filter" => %{"content.sluttdato" => %{"gte" => "$today"}}
      },
      %{
        "kind" => "documentTypeList",
        "type" => "arrangement",
        "title" => "Gjennomførte",
        "filter" => %{"content.sluttdato" => %{"lt" => "$today"}},
        "initialValues" => %{"publisert" => "$today"}
      }
    ])

    event!("i-gar", %{"sluttdato" => "2026-11-19"})
    event!("i-dag", %{"sluttdato" => "2026-11-20"})
    event!("uten-dato", %{})

    tree = Structure.build(@dataset, now: ~U[2026-11-20 10:00:00Z])
    by_title = Map.new(tree.items, &{&1.title, &1})

    list = fn title ->
      "arrangement"
      |> Content.list_documents(@dataset,
        perspective: :drafts,
        filter_map: by_title[title].filter
      )
      |> Enum.map(& &1.title)
      |> Enum.sort()
    end

    assert by_title["Kommende"].filter == %{"content.sluttdato" => %{"gte" => "2026-11-20"}}
    assert list.("Kommende") == ["i-dag"]
    # No date: GROQ's comparison with null is false, so neither list has it.
    assert list.("Gjennomførte") == ["i-gar"]
    # The "+" preset keeps the token; the Studio resolves it when it starts a document.
    assert by_title["Gjennomførte"].initial_values == %{"publisert" => "$today"}
  end

  test "an API create stores today's date in the workspace time zone" do
    ws = create_workspace!("today-#{System.unique_integer([:positive])}")
    project = create_project!(ws)
    {:ok, _} = Tenancy.set_workspace_time_zone(ws.id, "Europe/Oslo")
    scope = [workspace_id: ws.id, project_id: project.id]
    {:ok, schema} = Content.upsert_schema(@arrangement, @dataset, scope)

    {:ok, doc} =
      Content.create_document(
        "arrangement",
        %{"doc_id" => "ny", "title" => "ny"},
        @dataset,
        scope ++ [now: ~U[2026-11-20 23:30:00Z]]
      )

    # 23:30 UTC is already the 21st in Oslo.
    assert doc.content["publisert"] == "2026-11-21"
    # The served schema keeps the token as written.
    assert Schema.serialize_schema_for_sdk(schema).initialValues == %{"publisert" => "$today"}
  end
end
