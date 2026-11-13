defmodule BarkparkWeb.Studio.StudioPublishButtonSwapTest do
  @moduledoc """
  task-964a7fb95408ca3f: in the old Studio toolbar, Publish pressed by Enter
  became Unpublish and kept the focus, so a second Enter unpublished.

  Publish and Unpublish were one `<button>` with no id at one place in the
  header, so the patch after a publish MORPHED that element in place: same
  node, new `phx-click`, focus kept. They now carry different ids
  (`doc-action-publish`, `doc-action-unpublish`), so LiveView's DOM patch
  swaps the element. The focused Publish leaves the page with its focus, and a
  second Enter reaches nothing. A browser check pressed Enter twice on both
  (see the PR); these tests pin the ids the swap rests on.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  @dataset "production"

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "pubswap",
          "title" => "Pub swap",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    {:ok, _} =
      Content.create_document(
        "pubswap",
        %{"doc_id" => "pubswap-1", "title" => "One", "content" => %{"title" => "One"}},
        @dataset
      )

    :ok
  end

  test "Classic: Publish and the Unpublish that replaces it are different elements", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/pubswap/pubswap-1"))

    assert has_element?(view, ~s(button#doc-action-publish[phx-click="publish"]))
    refute has_element?(view, "#doc-action-unpublish")

    view |> element("#doc-action-publish") |> render_click()

    assert {:ok, _published} = Content.get_document("pubswap-1", "pubswap", @dataset)
    assert has_element?(view, ~s(button#doc-action-unpublish[phx-click="unpublish"]))
    refute has_element?(view, "#doc-action-publish")
  end

  # The swap takes the focused Publish off the page, so the focus fell to
  # <body>. A publish that lands asks the client to focus the document header
  # (tabindex=-1, not an action); a refused one leaves Publish and its focus.
  test "Classic: a publish that lands sends the focus to the document header", %{conn: conn} do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/pubswap/pubswap-1"))

    view |> element("#doc-action-publish") |> render_click()

    assert_push_event(view, "bp:focus-doc-header", %{})
    assert has_element?(view, ~s(.pane-header.editor-header[tabindex="-1"]))
  end

  test "Classic: a publish the validation refuses moves no focus", %{conn: conn} do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "pubswap",
          "title" => "Pub swap",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{
              "name" => "body",
              "title" => "Body",
              "type" => "string",
              "validation" => %{"required" => true}
            }
          ]
        },
        @dataset
      )

    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/pubswap/pubswap-1"))

    html = view |> element("#doc-action-publish") |> render_click()

    assert html =~ "Fix validation errors before publishing"
    assert has_element?(view, "#doc-action-publish")
    refute_push_event(view, "bp:focus-doc-header", %{})
  end

  test "Beta: the same ids, so its header swaps the element too", %{conn: conn} do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/pubswap/pubswap-1"))
    view |> element(~s([data-test-id="editor-mode-beta"])) |> render_click()

    assert has_element?(
             view,
             ~s([data-test-id="studio-beta-doc-actions"] button#doc-action-publish)
           )

    view |> element("#doc-action-publish") |> render_click()

    assert has_element?(
             view,
             ~s([data-test-id="studio-beta-doc-actions"] button#doc-action-unpublish)
           )
  end
end
