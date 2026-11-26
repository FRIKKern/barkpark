defmodule Barkpark.Content.PublicPaperSameSlugProjectTest do
  @moduledoc """
  task-ebee9b54706a692b: with same-slug published papers in two projects of
  the Default workspace, the public resolver picked whichever row came first
  in heap order, and an update moves a row. The pick is now fixed: the oldest
  row (`inserted_at`, then `id`) wins, at mount and on every refetch.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  setup do
    {ws, p1} = Barkpark.TenancyFixtures.ensure_default_scope!()
    p2 = Barkpark.TenancyFixtures.create_project!(ws)
    ds = Content.paper_default_dataset()

    for p <- [p1, p2] do
      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => "paper",
            "title" => "Papers",
            "visibility" => "public",
            "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
          },
          ds,
          workspace_id: ws.id,
          project_id: p.id
        )
    end

    Barkpark.LabelFixtures.register_tags!(ds)
    %{ws: ws, p1: p1, p2: p2, ds: ds, slug: "ppsp-#{System.unique_integer([:positive])}"}
  end

  defp paper!(c, p, text) do
    {:ok, doc} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          "slug" => c.slug,
          "title" => "T",
          "dataset" => c.ds,
          "workspace_id" => c.ws.id,
          "project_id" => p.id,
          "blocks" => [
            %{"id" => "h-1", "type" => "heading", "text" => "Title"},
            %{
              "id" => "b-1",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => text}]
            }
          ]
        })
      )

    assert doc.project_id == p.id
  end

  defp picked(c), do: Content.get_public_paper(c.slug, c.ds).project_id

  test "the oldest of two same-slug rows is picked, before and after either is updated", c do
    paper!(c, c.p1, "P1 words")
    paper!(c, c.p2, "P2 words")
    assert picked(c) == c.p1.id

    for {p, text} <- [{c.p1, "P1 again"}, {c.p2, "P2 again"}, {c.p1, "P1 third"}] do
      paper!(c, p, text)
      assert picked(c) == c.p1.id, "after updating #{text}"
    end
  end

  test "the /papers reader mounts P1's paper after P1 was updated, and refetches it",
       %{
         conn: conn
       } = c do
    paper!(c, c.p1, "P1 words")
    paper!(c, c.p2, "P2 words")
    paper!(c, c.p1, "P1 updated")

    {:ok, view, html} = live(conn, "/papers/#{c.slug}")
    assert html =~ "P1 updated"
    refute html =~ "P2 words"

    paper!(c, c.p1, "P1 refetched")
    _ = :sys.get_state(view.pid)
    Process.sleep(150)
    out = render(view)

    assert out =~ "P1 refetched"
    refute out =~ "P2 words"
  end
end
