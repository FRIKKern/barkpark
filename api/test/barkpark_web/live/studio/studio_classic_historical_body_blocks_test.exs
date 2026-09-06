defmodule BarkparkWeb.Studio.StudioClassicHistoricalBodyBlocksTest do
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  @dataset "production"
  @doc_type "classic_historical_body_blocks"
  @doc_id "classic-historical-card-body"

  setup do
    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => @doc_type,
          "title" => "Classic historical body blocks",
          "visibility" => "private",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "body", "title" => "Body", "type" => "richText"}
          ]
        },
        @dataset
      )

    blocks = [section_with_card()]

    body = %{
      "blocks" => blocks,
      "html" => "<p>stale fixture derivative</p>",
      "unknownBodyMetadata" => %{"keep" => [1, 2, 3]}
    }

    {:ok, _doc} =
      Content.upsert_document(
        @doc_type,
        %{
          "doc_id" => @doc_id,
          "title" => "Historical Card fixture",
          "content" => %{"body" => body, "unknownContent" => true}
        },
        @dataset
      )

    %{blocks: blocks, body: body}
  end

  test "Classic mounts a nested-only Card body and autosave preserves its block authority", %{
    conn: conn,
    blocks: blocks,
    body: body
  } do
    path = scoped_studio("/d/#{@dataset}/studio/#{@doc_type}/#{@doc_id}")
    {:ok, view, html} = live(conn, path)

    assert html =~ ~s(id="editor-form")
    assert has_element?(view, ~s(#bp-rt-hidden-body[value*="Card body from nested fixture"]))
    refute has_element?(view, ~s(#bp-rt-hidden-body[value*="stale fixture derivative"]))

    saved_html =
      render_hook(view, "autosave", %{
        "doc" => %{
          "title" => "Historical Card saved in Classic",
          "body" => "<p>raw scalar must not replace blocks</p>",
          "status" => "draft"
        }
      })

    refute saved_html =~ "Save failed"

    {:ok, saved} = Content.get_document("drafts.#{@doc_id}", @doc_type, @dataset)
    assert saved.title == "Historical Card saved in Classic"
    assert saved.content["body"]["blocks"] == blocks
    assert saved.content["body"]["unknownBodyMetadata"] == body["unknownBodyMetadata"]
    assert saved.content["unknownContent"] == true
    refute Map.has_key?(saved.content, "blocks")

    {:ok, _reloaded, reloaded_html} = live(recycle(conn), path)
    assert reloaded_html =~ "Historical Card saved in Classic"
    assert reloaded_html =~ "Card body from nested fixture"
  end

  defp section_with_card do
    %{
      "id" => "section-card-grid",
      "type" => "section",
      "unknownSection" => "keep",
      "blocks" => [
        %{
          "id" => "card-one",
          "type" => "card",
          "unknownCard" => %{"keep" => true},
          "slots" => %{
            "title" => [%{"type" => "heading", "text" => "Historical Card", "level" => 3}],
            "body" => [
              %{
                "id" => "card-body",
                "type" => "paragraph",
                "content" => [
                  %{"type" => "text", "value" => "Card body from nested fixture"}
                ]
              }
            ],
            "unknownSlot" => %{"keep" => "opaque"}
          }
        }
      ]
    }
  end
end
