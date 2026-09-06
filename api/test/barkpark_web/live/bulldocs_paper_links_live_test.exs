defmodule BarkparkWeb.BulldocsPaperLinksLiveTest do
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  @source "paper-links-source"
  @target "paper-links-target"

  defp paragraph(id, text) do
    %{
      "id" => id,
      "type" => "paragraph",
      "content" => [%{"type" => "text", "value" => text}]
    }
  end

  defp target_blocks(title) do
    [
      %{"id" => "title", "type" => "heading", "level" => 1, "text" => title},
      paragraph("body", "The details readers need before following this Paper.")
    ]
  end

  test "hydrates published Paper cards on mount and refreshes them after a relation change",
       %{conn: conn} do
    {:ok, _} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: @target,
          blocks: target_blocks("The concrete daily release"),
          description: "A readable account of what changed today.",
          event_type: "release"
        })
      )

    {:ok, _} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: @source,
          style: "article",
          blocks: [
            %{"id" => "title", "type" => "heading", "level" => 1, "text" => "Release index"},
            paragraph("body", "Choose a release to inspect."),
            %{
              "id" => "related",
              "type" => "paper-links",
              "title" => "Read the releases",
              "refs" => [%{"slug" => @target, "reason" => "Understand the day in full."}]
            }
          ]
        })
      )

    {:ok, view, html} = live(conn, "/papers/#{@source}")

    assert html =~ "Read the releases"
    assert html =~ "The concrete daily release"
    assert html =~ "Understand the day in full."
    assert html =~ "release"
    assert html =~ ~s(href="/papers/#{@target}")

    {:ok, _} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: @target,
          blocks: target_blocks("The daily release, clarified"),
          description: "The target changed after the source reader mounted.",
          event_type: "release-updated"
        })
      )

    send(view.pid, {:document_changed, %{type: "paper", doc_id: @target}})

    assert render(view) =~ "The daily release, clarified"
    assert render(view) =~ "release-updated"
    refute render(view) =~ "The concrete daily release"

    # Flat readers have no URL-derived scope. The post-save buffer refresh must
    # retain the mounted Paper's public metadata instead of clearing the map.
    socket = :sys.get_state(view.pid).socket
    assert is_nil(socket.assigns.reader_scope)
    synced = BarkparkWeb.BulldocsLive.Edit.sync(socket)
    assert synced.assigns.paper_link_details[@target].title == "The daily release, clarified"
  end

  test "an unresolved ref remains a useful authored link without invented metadata", %{conn: conn} do
    {:ok, _} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: @source,
          style: "article",
          blocks: [
            %{"id" => "title", "type" => "heading", "level" => 1, "text" => "Release index"},
            paragraph("body", "Choose a release to inspect."),
            %{
              "id" => "related",
              "type" => "paper-links",
              "refs" => [%{"slug" => "future-paper", "title" => "The next release"}]
            }
          ]
        })
      )

    {:ok, _view, html} = live(conn, "/papers/#{@source}")

    assert html =~ "The next release"
    assert html =~ ~s(href="/papers/future-paper")
    refute html =~ "rev "
  end
end
