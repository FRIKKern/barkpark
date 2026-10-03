defmodule BarkparkWeb.Studio.ClassicBodyInBlocksTest do
  @moduledoc """
  task-310e40394d3b83da — Studio Classic must not offer a body input it
  cannot save.

  Found dogfooding: Post > + (a layout schema, so the post is born with
  top-level blocks), type into Body, publish — the published post's body is
  empty. `Content.Forms.classic_save_content` re-projects `content["body"]`
  from the free blocks on every Classic save (deliberately: a Classic save
  must not clobber Beta-authored blocks), so the typed HTML was discarded
  with no word. The form now says the body is written in blocks and offers
  Beta; a document WITHOUT blocks keeps its editable rich-text body.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  @dataset "production"

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "story",
          "title" => "Story",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "body", "title" => "Body", "type" => "richText"}
          ],
          "layout" => [
            %{"kind" => "field", "name" => "title", "max" => 1, "enforce" => true},
            %{"kind" => "region", "name" => "body"}
          ]
        },
        @dataset
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "memo",
          "title" => "Memo",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "body", "title" => "Body", "type" => "richText"}
          ]
        },
        @dataset
      )

    {:ok, story} =
      Content.create_document("story", %{"doc_id" => "s1", "title" => "Story"}, @dataset)

    {:ok, _} = Content.create_document("memo", %{"doc_id" => "m1", "title" => "Memo"}, @dataset)
    %{story: story}
  end

  test "a blocks document's body is not an input; the form names Beta instead", %{
    conn: conn,
    story: story
  } do
    assert is_list(story.content["blocks"]), "a layout schema births top-level blocks"

    {:ok, view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/story/s1"))

    refute html =~ ~s(name="doc[body]")
    assert html =~ "This body is written in blocks"

    html = view |> element(~s([data-test-id="classic-body-edit-in-beta"])) |> render_click()
    # Beta took over the pane: the Classic notice is gone and the block editor
    # (its "Add block" control) is rendered.
    refute html =~ "This body is written in blocks"
    assert html =~ "Add block"
  end

  test "a document without blocks keeps its editable rich-text body", %{conn: conn} do
    {:ok, _view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/memo/m1"))

    assert html =~ ~s(name="doc[body]")
    refute html =~ "This body is written in blocks"
  end
end
