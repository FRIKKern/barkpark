defmodule Barkpark.Content.PaperStructurePublishGateTest do
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Repo

  @dataset "paper_structure_publish_gate_test"

  setup do
    Barkpark.LabelFixtures.register_tags!(@dataset)
    :ok
  end

  defp insert_draft!(id, blocks) do
    content =
      Barkpark.LabelFixtures.with_registered_labels(%{"blocks" => blocks}, @dataset)

    %Document{}
    |> Document.changeset(%{
      "doc_id" => "drafts." <> id,
      "type" => "paper",
      "dataset" => @dataset,
      "title" => "Structure gate #{id}",
      "status" => "draft",
      "content" => content,
      "rev" => "source-rev-" <> id
    })
    |> Repo.insert!()
  end

  test "publish normalizes a lossless producer dialect before copying the draft" do
    insert_draft!("normalizes", [
      %{
        "type" => "expandable",
        "children" => [
          %{
            "type" => "bulletList",
            "items" => [
              Jason.encode!([%{"type" => "text", "value" => "visible alias item"}])
            ]
          },
          %{
            "type" => "list",
            "content" => [
              %{
                "type" => "listItem",
                "content" => [%{"type" => "text", "value" => "visible content item"}]
              }
            ]
          },
          %{
            "type" => "table",
            "content" => %{
              "header" => ["Surface"],
              "rows" => [["visible content cell"]]
            }
          }
        ]
      },
      %{"type" => "callout", "text" => "visible callout"},
      %{
        "type" => "table",
        "columns" => [%{"text" => "Surface"}],
        "rows" => [[%{"text" => "visible cell"}]]
      }
    ])

    assert {:ok, published} =
             Content.publish_document("normalizes", "paper", @dataset)

    [expandable, callout, table] = published.content["blocks"]
    [alias_list, content_list, content_table] = expandable["children"]

    assert alias_list == %{
             "type" => "list",
             "ordered" => false,
             "items" => [[%{"type" => "text", "value" => "visible alias item"}]]
           }

    assert content_list == %{
             "type" => "list",
             "ordered" => false,
             "items" => [[%{"type" => "text", "value" => "visible content item"}]]
           }

    assert content_table["head"] == [[%{"type" => "text", "value" => "Surface"}]]

    assert content_table["rows"] == [
             [[%{"type" => "text", "value" => "visible content cell"}]]
           ]

    refute Map.has_key?(content_table, "content")
    assert callout["content"] == [%{"type" => "text", "value" => "visible callout"}]
    refute Map.has_key?(callout, "text")
    assert table["head"] == [[%{"type" => "text", "value" => "Surface"}]]
    assert table["rows"] == [[[%{"type" => "text", "value" => "visible cell"}]]]
    refute Map.has_key?(table, "columns")

    assert {:error, :not_found} =
             Content.get_document("drafts.normalizes", "paper", @dataset)
  end

  test "publish rejects content no reader can interpret and preserves the draft" do
    insert_draft!("rejects", [
      %{"type" => "list", "items" => [%{"label" => "stranded prose"}]}
    ])

    assert {:error,
            {:invalid_paper_structure,
             %{
               "blocks" => [
                 "blocks[0].items[0] has no renderable inline content"
               ]
             }}} =
             Content.publish_document("rejects", "paper", @dataset)

    assert {:ok, _draft} =
             Content.get_document("drafts.rejects", "paper", @dataset)

    assert {:error, :not_found} =
             Content.get_document("rejects", "paper", @dataset)
  end
end
