defmodule Barkpark.Content.PublishEmptyListRowsTest do
  @moduledoc """
  Owner ruling #47 (task-fe2dcfc7cb681922): publish refuses a scalar or
  reference list that holds an empty row, with a field-level message naming
  the row. Before, publish copied the draft's `null` to the public API and
  sites that loop over the list crashed on it. The draft keeps its empty row
  (Studio needs it to survive the next autosave).
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.EmptyListMembers

  @dataset "empty_rows_test"
  @type_name "event"

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => "Event",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{
              "name" => "keywords",
              "title" => "Keywords",
              "type" => "arrayOf",
              "of" => %{"type" => "string"}
            },
            %{"name" => "speakers", "type" => "arrayOf", "of" => %{"type" => "reference"}},
            %{
              "name" => "rows",
              "type" => "arrayOf",
              "of" => %{
                "type" => "composite",
                "fields" => [%{"name" => "label", "type" => "string"}]
              }
            },
            %{
              "name" => "seo",
              "title" => "SEO",
              "type" => "composite",
              "fields" => [
                %{
                  "name" => "tags",
                  "title" => "Tags",
                  "type" => "arrayOf",
                  "of" => %{"type" => "string"}
                }
              ]
            }
          ]
        },
        @dataset
      )

    :ok
  end

  defp draft!(id, content) do
    {:ok, doc} =
      Content.create_document(
        @type_name,
        %{"doc_id" => id, "title" => "Event #{id}", "content" => content},
        @dataset
      )

    doc
  end

  test "an empty scalar row refuses publish and names the row" do
    draft!("ev3", %{"keywords" => ["k1", "k2", nil]})

    assert {:error, {:empty_list_members, errors}} =
             Content.publish_document("ev3", @type_name, @dataset)

    assert errors == %{"keywords" => ["Keywords row 3 is empty, fill it in or remove it"]}

    # Nothing published; the draft keeps its row.
    assert {:error, :not_found} = Content.get_document("ev3", @type_name, @dataset)
    assert {:ok, draft} = Content.get_document("drafts.ev3", @type_name, @dataset)
    assert draft.content["keywords"] == ["k1", "k2", nil]
  end

  test "a blank string row and a reference with no target are empty too" do
    draft!("ev4", %{
      "keywords" => ["  "],
      "speakers" => [%{"_ref" => "a1"}, %{"_ref" => ""}, "a2"]
    })

    assert {:error, {:empty_list_members, errors}} =
             Content.publish_document("ev4", @type_name, @dataset)

    assert errors["keywords"] == ["Keywords row 1 is empty, fill it in or remove it"]
    assert errors["speakers"] == ["Speakers row 2 is empty, fill it in or remove it"]
  end

  test "a list inside a composite is checked and named through its parent" do
    draft!("ev5", %{"seo" => %{"tags" => ["a", nil]}})

    assert {:error, {:empty_list_members, %{"seo" => ["SEO › Tags row 2 is empty" <> _]}}} =
             Content.publish_document("ev5", @type_name, @dataset)
  end

  test "full lists, an absent list, an empty list and object rows publish as before" do
    draft!("ev6", %{
      "keywords" => ["k1", "k2"],
      "speakers" => ["a1", %{"_ref" => "a2"}],
      "rows" => [nil],
      "seo" => %{"tags" => []}
    })

    assert {:ok, published} = Content.publish_document("ev6", @type_name, @dataset)
    assert published.content["keywords"] == ["k1", "k2"]
  end

  test "false and zero are values, not empty rows" do
    assert EmptyListMembers.findings(
             %{"flags" => [false], "scores" => [0]},
             %{
               "fields" => [
                 %{"name" => "flags", "type" => "arrayOf", "of" => %{"type" => "boolean"}},
                 %{"name" => "scores", "type" => "array", "of" => [%{"type" => "number"}]}
               ]
             }
           ) == []
  end

  test "the refusal renders as a 422 validation_failed with per-field details" do
    env =
      Barkpark.Content.Errors.to_envelope(
        {:error, {:empty_list_members, %{"keywords" => ["Keywords row 3 is empty"]}}}
      )

    assert env.status == 422
    assert env.code == "validation_failed"
    assert env.details == %{"keywords" => ["Keywords row 3 is empty"]}
  end
end
